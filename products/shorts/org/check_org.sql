-- check_org.sql — shorts org안 교차 접근 검사(합성 데이터만, 끝에서 rollback)
-- 실행(저장소 루트에서, 0001 의 begin/commit 줄을 빼고 APPLY 표식 줄 자리에 끼워 넣는다):
--   awk -v f=products/shorts/org/0001_shorts.sql '/^-- @@APPLY@@$/{while((getline l < f)>0) if(l!~/^(begin|commit);$/) print l; next}1' \
--     products/shorts/org/check_org.sql | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q
-- 통과하면 마지막에 'CHECK_ORG_OK' 가 나온다. 하나라도 틀리면 예외로 중단된다.
begin;

-- core 가 touch_updated_at 을 추가하기 전까지 임시 정의(rollback 으로 사라진다)
create or replace function nomad_core.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- 청사진에 같은 이름이 있으면 지우고 시작
drop schema if exists nomad_shorts cascade;
drop schema if exists nomad_shorts_private cascade;

-- @@APPLY@@

-- ── 합성 사용자 3명 + 조직 2곳(org1: A 소유자·C 조회자, org2: B 소유자) ──
insert into auth.users (id, instance_id, aud, role, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'shorts-a@example.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'shorts-b@example.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'shorts-c@example.invalid');
create temp table _org (k text primary key, id uuid);
grant all on _org to authenticated;
insert into _org values
  ('org1', nomad_core.create_personal_organization('aaaaaaaa-0000-0000-0000-00000000000a', '합성 조직 1')),
  ('org2', nomad_core.create_personal_organization('bbbbbbbb-0000-0000-0000-00000000000b', '합성 조직 2'));
insert into nomad_core.memberships (organization_id, user_id, role)
  select id, 'cccccccc-0000-0000-0000-00000000000c', 'viewer' from _org where k = 'org1';

-- ── 시드(소유자 권한) ───────────────────────────────────────
insert into nomad_shorts.accounts (id, organization_id, platform, channel_name)
  select 'a1000000-0000-0000-0000-000000000001', id, 'youtube', '조직1 채널' from _org where k = 'org1';
insert into nomad_shorts.accounts (id, organization_id, platform, channel_name)
  select 'b1000000-0000-0000-0000-000000000001', id, 'youtube', '조직2 채널' from _org where k = 'org2';
insert into nomad_shorts.projects (id, organization_id, account_id, name, step_status)
  select 'a2000000-0000-0000-0000-000000000001', id, 'a1000000-0000-0000-0000-000000000001', '조직1 프로젝트',
         '{"1": "approved", "2": "idle", "3": "idle", "4": "idle", "5": "idle", "6": "idle"}' from _org where k = 'org1';
insert into nomad_shorts.projects (id, organization_id, account_id, name)
  select 'b2000000-0000-0000-0000-000000000001', id, 'b1000000-0000-0000-0000-000000000001', '조직2 프로젝트' from _org where k = 'org2';
insert into nomad_shorts.topics (project_id, name) values
  ('a2000000-0000-0000-0000-000000000001', '조직1 주제'),
  ('b2000000-0000-0000-0000-000000000001', '조직2 주제');
insert into nomad_shorts.credit_ledger (organization_id, kind, delta, idempotency_key)
  select id, 'charge', 10, 'seed-' || k from _org;
insert into nomad_shorts.categories (name) values ('합성 카테고리');

-- ── A(조직1 소유자) ────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-00000000000a', true);
do $$
declare n int; o2 uuid := (select id from _org where k = 'org2'); o1 uuid := (select id from _org where k = 'org1');
begin
  select count(*) into n from nomad_shorts.projects;
  if n <> 1 then raise exception 'FAIL projects: A 가 본 행 %', n; end if;
  select count(*) into n from nomad_shorts.accounts where organization_id = o2;
  if n <> 0 then raise exception 'FAIL accounts 교차 노출 %', n; end if;
  select count(*) into n from nomad_shorts.topics;
  if n <> 1 then raise exception 'FAIL topics(간접 소유): %', n; end if;
  select count(*) into n from nomad_shorts.credit_ledger;
  if n <> 1 then raise exception 'FAIL credit_ledger: %', n; end if;
  select count(*) into n from nomad_shorts.categories;
  if n < 1 then raise exception 'FAIL categories 공용 읽기'; end if;

  update nomad_shorts.projects set name = 'hack' where id = 'b2000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 조직2 프로젝트 수정됨'; end if;
  delete from nomad_shorts.projects where id = 'b2000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 조직2 프로젝트 삭제됨'; end if;

  begin
    insert into nomad_shorts.accounts (organization_id, platform, channel_name) values (o2, 'youtube', '침입');
    raise exception 'FAIL 다른 조직에 accounts 삽입 허용됨';
  exception when insufficient_privilege then null;
  end;
  -- 자기 조직 쓰기는 허용
  insert into nomad_shorts.accounts (organization_id, platform, channel_name) values (o1, 'instagram', '조직1 추가 채널');

  if (nomad_shorts.create_job('a2000000-0000-0000-0000-000000000001', 'collect', 'idem-own-00001') ->> 'created') is distinct from 'true' then
    raise exception 'FAIL 자기 조직 프로젝트 create_job 실패';
  end if;
  begin
    perform nomad_shorts.create_job('b2000000-0000-0000-0000-000000000001', 'tts', 'idem-cross-0001');
    raise exception 'FAIL 다른 조직 프로젝트 create_job 허용됨';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ── B(조직2 소유자): 대칭 ──────────────────────────────────
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-00000000000b', true);
do $$
declare n int;
begin
  select count(*) into n from nomad_shorts.projects where id = 'a2000000-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL B 가 조직1 프로젝트를 봄'; end if;
  select count(*) into n from nomad_shorts.topics where project_id = 'a2000000-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL B 가 조직1 주제를 봄'; end if;
  select count(*) into n from nomad_shorts.credit_ledger where organization_id = (select id from _org where k = 'org1');
  if n <> 0 then raise exception 'FAIL B 가 조직1 크레딧을 봄'; end if;
end $$;

-- ── C(조직1 조회자): 읽기만 ────────────────────────────────
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-00000000000c', true);
do $$
declare n int;
begin
  select count(*) into n from nomad_shorts.projects;
  if n <> 1 then raise exception 'FAIL 조회자가 조직1 프로젝트를 못 봄: %', n; end if;
  update nomad_shorts.projects set name = 'viewer-edit' where id = 'a2000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 조회자가 프로젝트를 수정함'; end if;
  begin
    perform nomad_shorts.create_job('a2000000-0000-0000-0000-000000000001', 'tts', 'idem-viewer-001');
    raise exception 'FAIL 조회자 create_job 허용됨';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ── anon: 아무것도 못 본다 ─────────────────────────────────
reset role;
set local role anon;
do $$
begin
  begin
    perform 1 from nomad_shorts.projects;
    raise exception 'FAIL anon 이 projects 를 읽음';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ── user_settings 는 개인 소유(user_id) 그대로 ─────────────
insert into nomad_shorts.user_settings (user_id) values
  ('aaaaaaaa-0000-0000-0000-00000000000a'), ('bbbbbbbb-0000-0000-0000-00000000000b');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-00000000000a', true);
do $$
begin
  if (select count(*) from nomad_shorts.user_settings) <> 1 then raise exception 'FAIL user_settings 격리'; end if;
end $$;
reset role;
update nomad_shorts.user_settings set updated_at = now() - interval '1 day' where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
update nomad_shorts.user_settings set default_len = 20 where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
do $$
begin
  if (select updated_at from nomad_shorts.user_settings where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a') < now() - interval '1 minute' then
    raise exception 'FAIL touch_updated_at 트리거 미동작';
  end if;
end $$;

-- ── 0003: 큐 상한·미룸·순번, 확장 토큰·보고, 속도 제한 ───────
insert into nomad_shorts.jobs (id, project_id, step, type, status, idempotency_key, started_at) values
  ('a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', nomad_shorts_private.job_step('tts'), 'tts', 'running', 'chk-run-a', now()),
  ('a3000000-0000-0000-0000-000000000002', 'a2000000-0000-0000-0000-000000000001', nomad_shorts_private.job_step('tts'), 'tts', 'queued', 'chk-q-a', null),
  ('b3000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001', nomad_shorts_private.job_step('tts'), 'tts', 'queued', 'chk-q-b', null);
create temp table _ext (k text primary key, id uuid);
do $$
declare o1 uuid := (select id from _org where k = 'org1'); o2 uuid := (select id from _org where k = 'org2'); v record; e uuid;
begin
  if nomad_shorts_private.job_queue_limit('shorts_analyze') <> 5 then raise exception 'FAIL job_queue_limit 큐 기준'; end if;
  if not nomad_shorts_private.job_user_busy('a3000000-0000-0000-0000-000000000002', 'shorts_tts') then
    raise exception 'FAIL job_user_busy: 같은 소유자 running 을 못 봄';
  end if;
  if nomad_shorts_private.job_user_busy('b3000000-0000-0000-0000-000000000001', 'shorts_tts') then
    raise exception 'FAIL job_user_busy: 다른 소유자 running 을 셈';
  end if;
  select * into v from nomad_shorts.queue_health() where queue_name = 'shorts_tts';
  if v.queued < 2 or v.running < 1 then raise exception 'FAIL queue_health 집계 %', v; end if;

  -- 속도 제한
  if not nomad_shorts.extension_rate_hit('ext:chk', 1, 60) or nomad_shorts.extension_rate_hit('ext:chk', 1, 60) then
    raise exception 'FAIL rate_hit 한도';
  end if;
  begin
    perform nomad_shorts.extension_rate_hit('bad:chk', 1, 60);
    raise exception 'FAIL rate_hit 접두어 허용됨';
  exception when invalid_parameter_value then null;
  end;

  -- 토큰 발급·검사·회전·재사용 폐기
  select extension_id into e from nomad_shorts.extension_issue(o1, repeat('a', 64), repeat('b', 64));
  select * into v from nomad_shorts.extension_authenticate(repeat('a', 64));
  if v.extension_id is distinct from e or v.organization_id is distinct from o1 then raise exception 'FAIL extension_authenticate'; end if;
  if (select result from nomad_shorts.extension_rotate(repeat('b', 64), repeat('c', 64), repeat('d', 64))) <> 'ok' then
    raise exception 'FAIL extension_rotate ok';
  end if;
  if (select result from nomad_shorts.extension_rotate(repeat('b', 64), repeat('e', 64), repeat('f', 64))) <> 'reused' then
    raise exception 'FAIL extension_rotate 재사용 감지';
  end if;
  if exists (select 1 from nomad_shorts.extension_authenticate(repeat('c', 64))) then
    raise exception 'FAIL 재사용 뒤 행이 폐기되지 않음';
  end if;
  select extension_id into e from nomad_shorts.extension_issue(o1, repeat('1', 64), repeat('2', 64));
  if nomad_shorts.extension_revoke(e, o2) then raise exception 'FAIL 다른 소유자가 확장을 폐기함'; end if;
  select extension_id into e from nomad_shorts.extension_issue(o1, repeat('3', 64), repeat('4', 64));
  insert into _ext values ('o1', e);
  select extension_id into e from nomad_shorts.extension_issue(o2, repeat('5', 64), repeat('6', 64));
  insert into _ext values ('o2', e);

  -- 확장 수집 기록(서버 경로, auth.uid 없음): 토큰 조직 = 프로젝트 조직만, 다른 조직 확장은 42501
  insert into nomad_shorts.jobs (id, project_id, step, type, status, idempotency_key, started_at, extension_id) values
    ('a3000000-0000-0000-0000-000000000004', 'a2000000-0000-0000-0000-000000000001', nomad_shorts_private.job_step('collect'),
     'collect', 'running', 'chk-col-a', now(), (select id from _ext where k = 'o1'));
  begin
    perform nomad_shorts.extension_collect_list((select id from _ext where k = 'o2'), 'a3000000-0000-0000-0000-000000000004',
      '[{"url": "https://www.tiktok.com/@chk/video/1", "author": "chk"}]');
    raise exception 'FAIL 다른 조직 확장의 collect_list 허용됨';
  exception when insufficient_privilege then null;
  end;
  if (nomad_shorts.extension_collect_list((select id from _ext where k = 'o1'), 'a3000000-0000-0000-0000-000000000004',
        '[{"url": "https://www.tiktok.com/@chk/video/1", "author": "chk"}]') ->> 'inserted')::int <> 1 then
    raise exception 'FAIL extension_collect_list 기록';
  end if;
  update nomad_shorts.sources set checked = true where project_id = 'a2000000-0000-0000-0000-000000000001';
  insert into nomad_shorts.jobs (id, project_id, step, type, status, idempotency_key, started_at, extension_id) values
    ('a3000000-0000-0000-0000-000000000003', 'a2000000-0000-0000-0000-000000000001', nomad_shorts_private.job_step('collect_download'),
     'collect_download', 'running', 'chk-dl-a', now(), (select id from _ext where k = 'o1'));
  begin
    perform nomad_shorts.extension_collect_download((select id from _ext where k = 'o2'), 'a3000000-0000-0000-0000-000000000003',
      jsonb_build_array(jsonb_build_object('id', (select id from nomad_shorts.sources where project_id = 'a2000000-0000-0000-0000-000000000001'),
                                           'file_path', o1::text || '/a2000000-0000-0000-0000-000000000001/v1.mp4')));
    raise exception 'FAIL 다른 조직 확장의 collect_download 허용됨';
  exception when insufficient_privilege then null;
  end;
  if nomad_shorts.extension_collect_download((select id from _ext where k = 'o1'), 'a3000000-0000-0000-0000-000000000003',
       jsonb_build_array(jsonb_build_object('id', (select id from nomad_shorts.sources where project_id = 'a2000000-0000-0000-0000-000000000001'),
                                            'file_path', o1::text || '/a2000000-0000-0000-0000-000000000001/v1.mp4'))) <> 1 then
    raise exception 'FAIL extension_collect_download 기록';
  end if;

  -- 보고: 그 확장이 claim 한 running collect_download 만(위 a3..03)
  begin
    perform nomad_shorts.extension_report_complete((select id from _ext where k = 'o2'), 'a3000000-0000-0000-0000-000000000003');
    raise exception 'FAIL 다른 소유자 확장의 완료 보고 허용됨';
  exception when insufficient_privilege then null;
  end;
  if nomad_shorts.extension_report_complete((select id from _ext where k = 'o1'), 'a3000000-0000-0000-0000-000000000003') <> 'rechecking'
     or nomad_shorts.extension_report_complete((select id from _ext where k = 'o1'), 'a3000000-0000-0000-0000-000000000003') <> 'already_reported' then
    raise exception 'FAIL extension_report_complete 상태';
  end if;
  if (select count(*) from pgmq.q_shorts_sources) <> 1 then raise exception 'FAIL shorts_sources 재검사 메시지 수'; end if;
  begin
    perform nomad_shorts.extension_report_abort((select id from _ext where k = 'o1'), 'a3000000-0000-0000-0000-000000000003', 'captcha');
    raise exception 'FAIL 완료 보고 뒤 중단 허용됨';
  exception when sqlstate 'EX409' then null;
  end;
  begin
    insert into nomad_shorts.jobs (project_id, step, type, status, idempotency_key) values
      ('a2000000-0000-0000-0000-000000000001', nomad_shorts_private.job_step('collect_download'), 'collect_download', 'queued', 'chk-dl-a2');
    raise exception 'FAIL 활성 collect_download 2개 허용됨';
  exception when unique_violation then null;
  end;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-00000000000a', true);
do $$
declare s jsonb := nomad_shorts.job_queue_status();
begin
  if jsonb_array_length(s -> 'production') <> 2 then raise exception 'FAIL job_queue_status 행 수: %', s -> 'production'; end if;
  if exists (select 1 from jsonb_array_elements(s -> 'production') x where x ->> 'project_id' = 'b2000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL job_queue_status 교차 노출';
  end if;
  if (select x ->> 'state' from jsonb_array_elements(s -> 'production') x where x ->> 'job_id' = 'a3000000-0000-0000-0000-000000000002') <> 'deferred' then
    raise exception 'FAIL job_queue_status 미룸 상태';
  end if;
  begin
    perform nomad_shorts.create_job('a2000000-0000-0000-0000-000000000001', 'collect_download', 'idem-dl-00001');
    raise exception 'FAIL 확장 작업 진행 중 collect_download 생성 허용됨';
  exception when sqlstate 'EX001' then null;
  end;
  begin
    perform nomad_shorts.extension_issue(auth.uid(), repeat('9', 64), repeat('0', 64));
    raise exception 'FAIL authenticated 가 extension_issue 호출';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-00000000000b', true);
do $$
declare s jsonb := nomad_shorts.job_queue_status();
begin
  if jsonb_array_length(s -> 'production') <> 1 or (s -> 'production' -> 0 ->> 'position')::int <> 1 then
    raise exception 'FAIL B job_queue_status(미룸인 남의 작업은 앞 순번에서 빠져야 함): %', s -> 'production';
  end if;
end $$;
reset role;

-- ── 큐·버킷 이름 접두(shorts_) ─────────────────────────────
do $$
begin
  if (select count(*) from pgmq.meta where queue_name in ('shorts_render', 'shorts_tts', 'shorts_analyze')) <> 3 then
    raise exception 'FAIL pgmq 큐 이름';
  end if;
  if nomad_shorts_private.job_queue('tts') <> 'shorts_tts' or nomad_shorts_private.job_queue('select_sources') <> 'shorts_analyze' then
    raise exception 'FAIL job_queue 이름';
  end if;
end $$;

-- ── 0002 버킷: 비공개 · storage.objects 직접 정책 없음 · 남의 경로 객체 접근 0 ──
reset role;
do $$
begin
  if (select count(*) from storage.buckets
      where id in ('shorts-sources', 'shorts-voices', 'shorts-renders', 'shorts-thumbnails') and public = false
        and file_size_limit is not null and allowed_mime_types is not null) <> 4 then
    raise exception 'FAIL 버킷 4개 비공개·한도';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and (coalesce(qual, '') || coalesce(with_check, '')) like '%shorts-%') then
    raise exception 'FAIL storage.objects 에 shorts 버킷 직접 정책이 있음';
  end if;
end $$;
insert into storage.objects (bucket_id, name) values
  ('shorts-renders', (select id::text from _org where k = 'org1') || '/a2000000-0000-0000-0000-000000000001/a.mp4'),
  ('shorts-thumbnails', (select id::text from _org where k = 'org2') || '/b2000000-0000-0000-0000-000000000001/b.jpg');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from storage.objects where bucket_id like 'shorts-%' and name like (select id::text from _org where k = 'org2') || '/%') <> 0 then
    raise exception 'FAIL A 가 B 경로 객체를 읽음';
  end if;
  if (select count(*) from storage.objects where bucket_id like 'shorts-%') <> 0 then
    raise exception 'FAIL authenticated 직접 목록(서버 서명 URL 전용이어야 함)';
  end if;
  begin
    insert into storage.objects (bucket_id, name) values ('shorts-renders', (select id::text from _org where k = 'org2') || '/x/hack.mp4');
    raise exception 'FAIL A 가 B 경로에 업로드';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
do $$
declare n bigint;
begin
  if (select count(*) from storage.objects where bucket_id like 'shorts-%' and name like (select id::text from _org where k = 'org1') || '/%') <> 0 then
    raise exception 'FAIL B 가 A 경로 객체를 읽음';
  end if;
  update storage.objects set name = name || '.x' where bucket_id like 'shorts-%';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL B 가 객체를 수정';
  end if;
end $$;
reset role;
set local role anon;
do $$
begin
  if (select count(*) from storage.objects where bucket_id like 'shorts-%') <> 0 then
    raise exception 'FAIL anon 이 shorts 객체를 읽음';
  end if;
end $$;
reset role;
do $$
begin
  if (select count(*) from storage.objects where bucket_id like 'shorts-%') <> 2 then
    raise exception 'FAIL 객체가 바뀌었거나 사라짐';
  end if;
end $$;

select 'CHECK_ORG_OK' as result;
rollback;
