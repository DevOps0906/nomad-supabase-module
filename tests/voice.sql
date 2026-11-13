-- 음성(C7) 검증: 권한 표 · RLS · 저장·동의 제약 · 조직 격리(본인 행만) · anon 접근 0 · 만료 정리 서버 전용 (합성 데이터, 롤백)
\o /dev/null
begin;

create function pg_temp.expect_err(stmt text, pattern text) returns void
language plpgsql as $$
begin
  execute stmt;
  raise exception 'expected failure (%) but succeeded: %', pattern, stmt;
exception when others then
  if sqlerrm like 'expected failure%' or sqlerrm not like pattern then
    raise exception 'wrong error for [%]: got [%] want like [%]', stmt, sqlerrm, pattern;
  end if;
end;
$$;

create temp table t_ctx (k text primary key, v text);
grant all on t_ctx to authenticated, anon, service_role;

-- 1. 권한 표 · RLS: 테이블은 service_role만, 사용자 RPC는 authenticated만, 만료 정리는 service_role만
do $$
declare t text; f text;
begin
  foreach t in array array['nomad_core.voice_sessions', 'nomad_core.voice_jobs'] loop
    if has_table_privilege('authenticated', t, 'select,insert,update,delete')
       or has_table_privilege('anon', t, 'select,insert,update,delete')
    then raise exception 'table grant too wide: %', t; end if;
    if not has_table_privilege('service_role', t, 'select') or not has_table_privilege('service_role', t, 'insert')
    then raise exception 'service_role grant missing: %', t; end if;
    if not (select relrowsecurity from pg_class where oid = t::regclass) then raise exception 'RLS off: %', t; end if;
  end loop;
  foreach f in array array['nomad_core.expire_voice_audio(integer)', 'nomad_core.confirm_voice_audio_purged(uuid[])'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute')
    then raise exception 'grant wrong: %', f; end if;
  end loop;
  foreach f in array array['public.nomad_my_voice_sessions(uuid,integer)', 'public.nomad_my_voice_jobs(uuid,integer)'] loop
    if has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')
    then raise exception 'grant wrong: %', f; end if;
  end loop;
end $$;

-- 합성 사용자 3명 → 각자 personal 조직(owner). 사용자 3은 조직 1에 editor로 합류
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000e1', 'voice-a@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000e2', 'voice-b@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000e3', 'voice-c@example.test', now(), false, '{}');
insert into t_ctx
select 'org' || right(m.user_id::text, 1), m.organization_id::text
from nomad_core.memberships m
where m.user_id in ('00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-0000000000e2') and m.role = 'owner';
insert into nomad_core.memberships (organization_id, user_id, role)
select v::uuid, '00000000-0000-4000-8000-0000000000e3', 'editor' from t_ctx where k = 'org1';

-- 2. 서버 쓰기 · 제약
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare org1 uuid := (select v::uuid from t_ctx where k = 'org1'); org2 uuid := (select v::uuid from t_ctx where k = 'org2');
  s1 uuid; s2 uuid;
begin
  insert into nomad_core.voice_sessions (organization_id, product_code, user_id, stt_provider, tts_provider)
  values (org1, 'contentflow', '00000000-0000-4000-8000-0000000000e1', 'oss-voice', 'elevenlabs') returning id into s1;
  insert into nomad_core.voice_sessions (organization_id, product_code, user_id)
  values (org2, 'contentflow', '00000000-0000-4000-8000-0000000000e2') returning id into s2;
  insert into nomad_core.voice_sessions (organization_id, product_code, visitor_key) values (org1, 'contentflow', 'visitor-1');
  insert into nomad_core.voice_jobs (organization_id, product_code, user_id, session_id, kind, provider, credits)
  values (org1, 'contentflow', '00000000-0000-4000-8000-0000000000e1', s1, 'stt', 'oss-voice', 3),
         (org1, 'contentflow', '00000000-0000-4000-8000-0000000000e3', null, 'tts', 'elevenlabs', 1),
         (org2, 'contentflow', '00000000-0000-4000-8000-0000000000e2', s2, 'tts', 'elevenlabs', 2);
  -- 녹음 보관: 동의·만료 있는 것 1건(이미 만료), 아직 안 만료 1건
  insert into nomad_core.voice_jobs (organization_id, product_code, user_id, kind, provider, feature, store_audio,
                                     consent_at, consent_kind, notice_version, storage_path, expires_at)
  values (org1, 'contentflow', '00000000-0000-4000-8000-0000000000e1', 'stt', 'oss-voice', 'lecture_note', true,
          now(), 'third_party_notice', 'v1', org1 || '/old.webm', now() - interval '1 day'),
         (org1, 'contentflow', '00000000-0000-4000-8000-0000000000e1', 'stt', 'oss-voice', 'dictation', true,
          now(), 'self', 'v1', org1 || '/new.webm', now() + interval '1 day');
  insert into t_ctx values ('s1', s1::text), ('s2', s2::text);
end $$;

-- 제약: 소유자 없음 · 저장 시 경로·만료·동의 필수 · 미저장 시 경로 금지 · 다른 조직 세션 연결 금지 · 제공자 코드 형식
select pg_temp.expect_err(format($$insert into nomad_core.voice_sessions (organization_id, product_code) values (%L, 'contentflow')$$,
  (select v from t_ctx where k = 'org1')), '%voice_sessions_owner_check%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_jobs (organization_id, product_code, kind, provider, store_audio, storage_path, expires_at)
  values (%L, 'contentflow', 'stt', 'elevenlabs', true, 'p', now())$$, (select v from t_ctx where k = 'org1')), '%voice_jobs_consent_check%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_jobs (organization_id, product_code, kind, provider, store_audio, consent_at, consent_kind)
  values (%L, 'contentflow', 'stt', 'elevenlabs', true, now(), 'self')$$, (select v from t_ctx where k = 'org1')), '%voice_jobs_store_check%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_jobs (organization_id, product_code, kind, provider, storage_path)
  values (%L, 'contentflow', 'stt', 'elevenlabs', 'p')$$, (select v from t_ctx where k = 'org1')), '%voice_jobs_no_store_check%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_jobs (organization_id, product_code, session_id, kind, provider)
  values (%L, 'contentflow', %L, 'stt', 'elevenlabs')$$, (select v from t_ctx where k = 'org1'), (select v from t_ctx where k = 's2')), '%foreign key%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_jobs (organization_id, product_code, kind, provider)
  values (%L, 'contentflow', 'stt', 'no-such-provider')$$, (select v from t_ctx where k = 'org1')), '%voice_jobs_provider_fkey%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_sessions (organization_id, product_code, visitor_key, stt_provider)
  values (%L, 'contentflow', 'v', 'no-such-provider')$$, (select v from t_ctx where k = 'org1')), '%voice_sessions_stt_provider_fkey%');
select pg_temp.expect_err(format($$insert into nomad_core.voice_sessions (organization_id, product_code, visitor_key, tts_provider)
  values (%L, 'contentflow', 'v', 'no-such-provider')$$, (select v from t_ctx where k = 'org1')), '%voice_sessions_tts_provider_fkey%');

-- 대화 연결: 같은 조직 대화는 허용, 다른 조직 대화는 복합 FK로 거부, 대화 삭제 시 연결만 끊김
do $$
declare org1 uuid := (select v::uuid from t_ctx where k = 'org1'); org2 uuid := (select v::uuid from t_ctx where k = 'org2');
  c1 uuid; c2 uuid; s uuid;
begin
  insert into nomad_core.ai_conversations (organization_id, product_code, user_id, dify_user, channel)
  values (org1, 'contentflow', '00000000-0000-4000-8000-0000000000e1', 'voice-test-u1', 'voice') returning id into c1;
  insert into nomad_core.ai_conversations (organization_id, product_code, user_id, dify_user, channel)
  values (org2, 'contentflow', '00000000-0000-4000-8000-0000000000e2', 'voice-test-u2', 'voice') returning id into c2;
  insert into nomad_core.voice_sessions (organization_id, product_code, visitor_key, conversation_id)
  values (org1, 'contentflow', 'visitor-conv', c1) returning id into s;
  perform pg_temp.expect_err(format($q$insert into nomad_core.voice_sessions (organization_id, product_code, visitor_key, conversation_id)
    values (%L, 'contentflow', 'visitor-x', %L)$q$, org1, c2), '%voice_sessions_conversation_id_organization_id_fkey%');
  delete from nomad_core.ai_conversations where id = c1;
  if (select conversation_id from nomad_core.voice_sessions where id = s) is not null
     or (select organization_id from nomad_core.voice_sessions where id = s) <> org1
  then raise exception 'conversation delete should only unlink'; end if;
  delete from nomad_core.voice_sessions where id = s;
end $$;

-- 3. 만료 정리 2단계: 요청은 만료분 1건만 표시(아직 expired 아님), 확정 전 재호출은 같은 경로 재반환,
--    확정 후 expired·미반환, 확정 반복·요청 없던 행 확정은 0건
do $$
declare n integer; p text; jid uuid;
begin
  select count(*), max(storage_path), max(job_id::text)::uuid into n, p, jid from nomad_core.expire_voice_audio();
  if n <> 1 or p not like '%/old.webm' then raise exception 'expire first run % %', n, p; end if;
  if (select status from nomad_core.voice_jobs where id = jid) = 'expired'
     or (select audio_purge_requested_at from nomad_core.voice_jobs where id = jid) is null
  then raise exception 'expire must only request purge'; end if;
  select count(*), max(storage_path) into n, p from nomad_core.expire_voice_audio();
  if n <> 1 or p not like '%/old.webm' then raise exception 'unconfirmed purge not re-returned % %', n, p; end if;
  -- 아직 만료 안 된 녹음(new.webm)은 요청이 없어 확정되지 않는다
  if nomad_core.confirm_voice_audio_purged(array(select id from nomad_core.voice_jobs where storage_path like '%/new.webm')) <> 0
  then raise exception 'confirm without purge request'; end if;
  if nomad_core.confirm_voice_audio_purged(array[jid]) <> 1 then raise exception 'confirm failed'; end if;
  if (select status from nomad_core.voice_jobs where id = jid) <> 'expired' then raise exception 'not expired after confirm'; end if;
  if (select count(*) from nomad_core.expire_voice_audio()) <> 0 then raise exception 'confirmed purge re-returned'; end if;
  if nomad_core.confirm_voice_audio_purged(array[jid]) <> 0 then raise exception 'confirm not repeat-safe'; end if;
end $$;
reset role;

-- 4. 사용자 1: 본인 행만(같은 조직 동료 작업·방문자 세션 제외), 다른 조직은 forbidden, 테이블 직접 접근 거부
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000e1"}', true);
do $$
declare org1 uuid := (select v::uuid from t_ctx where k = 'org1'); org2 uuid := (select v::uuid from t_ctx where k = 'org2');
begin
  if (select count(*) from public.nomad_my_voice_sessions(org1)) <> 1 then raise exception 'user1 sessions'; end if;
  if (select count(*) from public.nomad_my_voice_jobs(org1)) <> 3 then raise exception 'user1 jobs'; end if;
  if (select count(*) from public.nomad_my_voice_jobs(org1) where status = 'expired') <> 1 then raise exception 'expired not visible'; end if;
  perform pg_temp.expect_err(format('select * from public.nomad_my_voice_jobs(%L)', org2), '%forbidden%');
  perform pg_temp.expect_err(format('select * from public.nomad_my_voice_sessions(%L)', org2), '%forbidden%');
end $$;
select pg_temp.expect_err('select * from nomad_core.voice_jobs', '%permission denied%');
select pg_temp.expect_err('select * from nomad_core.voice_sessions', '%permission denied%');
select pg_temp.expect_err('select * from nomad_core.expire_voice_audio()', '%permission denied%');

-- 사용자 3(조직 1 editor): 자기 작업 1건만, 세션 0건
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000e3"}', true);
do $$
declare org1 uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  if (select count(*) from public.nomad_my_voice_jobs(org1)) <> 1
     or (select count(*) from public.nomad_my_voice_sessions(org1)) <> 0
  then raise exception 'user3 isolation'; end if;
end $$;

-- 사용자 2: 자기 조직 1건, 조직 1은 forbidden
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000e2"}', true);
do $$
begin
  if (select count(*) from public.nomad_my_voice_jobs((select v::uuid from t_ctx where k = 'org2'))) <> 1
  then raise exception 'user2 jobs'; end if;
  perform pg_temp.expect_err(format('select * from public.nomad_my_voice_jobs(%L)', (select v from t_ctx where k = 'org1')), '%forbidden%');
end $$;
reset role;

-- 5. anon: 테이블·RPC·만료 정리 모두 거부
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.expect_err('select * from nomad_core.voice_jobs', '%permission denied%');
select pg_temp.expect_err('select * from nomad_core.voice_sessions', '%permission denied%');
select pg_temp.expect_err(format('select * from public.nomad_my_voice_jobs(%L)', (select v from t_ctx where k = 'org1')), '%permission denied%');
select pg_temp.expect_err(format('select * from public.nomad_my_voice_sessions(%L)', (select v from t_ctx where k = 'org1')), '%permission denied%');
select pg_temp.expect_err('select * from nomad_core.expire_voice_audio()', '%permission denied%');
select pg_temp.expect_err('select nomad_core.confirm_voice_audio_purged(''{}'')', '%permission denied%');
reset role;

-- 6. 사용자 삭제: 세션·작업이 있는 사용자도 삭제되고 그 사용자의 행은 cascade로 사라진다(다른 사용자·방문자 행은 남음)
do $$
declare org1 uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  delete from auth.users where id = '00000000-0000-4000-8000-0000000000e1';
  if exists (select 1 from nomad_core.voice_sessions where user_id = '00000000-0000-4000-8000-0000000000e1')
     or exists (select 1 from nomad_core.voice_jobs where user_id = '00000000-0000-4000-8000-0000000000e1')
     or exists (select 1 from nomad_core.voice_sessions where id = (select v::uuid from t_ctx where k = 's1'))
  then raise exception 'deleted user voice rows remain'; end if;
  if (select count(*) from nomad_core.voice_sessions where organization_id = org1 and visitor_key = 'visitor-1') <> 1
     or (select count(*) from nomad_core.voice_jobs where user_id = '00000000-0000-4000-8000-0000000000e3') <> 1
  then raise exception 'other rows removed by user delete'; end if;
end $$;

rollback;
\o
\echo 'voice: ok'
