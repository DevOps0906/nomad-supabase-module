-- check_user.sql — shorts user안 교차 접근 검사(합성 데이터만, 끝에서 rollback)
-- 실행(저장소 루트에서, 0001 의 begin/commit 줄을 빼고 APPLY 표식 줄 자리에 끼워 넣는다):
--   awk -v f=products/shorts/user/0001_shorts.sql '/^-- @@APPLY@@$/{while((getline l < f)>0) if(l!~/^(begin|commit);$/) print l; next}1' \
--     products/shorts/user/check_user.sql | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q
-- 통과하면 마지막에 'CHECK_USER_OK' 가 나온다. 하나라도 틀리면 예외로 중단된다.
begin;

-- core 가 touch_updated_at 을 추가하기 전까지 임시 정의(rollback 으로 사라진다)
create or replace function nomad_core.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- 청사진에 같은 이름이 있으면 지우고 시작
drop schema if exists nomad_shorts cascade;
drop schema if exists nomad_shorts_private cascade;

-- @@APPLY@@

-- ── 합성 사용자 2명 ─────────────────────────────────────────
insert into auth.users (id, instance_id, aud, role, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'shorts-a@example.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'shorts-b@example.invalid');

-- ── 시드(소유자 권한) ───────────────────────────────────────
insert into nomad_shorts.accounts (id, user_id, platform, channel_name) values
  ('a1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', 'youtube', 'A 채널'),
  ('b1000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-00000000000b', 'youtube', 'B 채널');
insert into nomad_shorts.projects (id, user_id, account_id, name) values
  ('a2000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001', 'A 프로젝트'),
  ('b2000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001', 'B 프로젝트');
update nomad_shorts.projects set step_status = '{"1": "approved", "2": "idle", "3": "idle", "4": "idle", "5": "idle", "6": "idle"}'
  where id = 'a2000000-0000-0000-0000-000000000001';
insert into nomad_shorts.topics (project_id, name) values
  ('a2000000-0000-0000-0000-000000000001', 'A 주제'),
  ('b2000000-0000-0000-0000-000000000001', 'B 주제');
insert into nomad_shorts.credit_ledger (user_id, kind, delta, idempotency_key) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'charge', 10, 'seed-a'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'charge', 10, 'seed-b');
insert into nomad_shorts.user_settings (user_id) values
  ('aaaaaaaa-0000-0000-0000-00000000000a'), ('bbbbbbbb-0000-0000-0000-00000000000b');
insert into nomad_shorts.categories (name) values ('합성 카테고리');

-- ── A 로 접속: 자기 것만 보이고 B 것은 안 보인다 ─────────────
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-00000000000a', true);
do $$
declare n int;
begin
  select count(*) into n from nomad_shorts.projects;
  if n <> 1 then raise exception 'FAIL projects: A 가 본 행 %', n; end if;
  select count(*) into n from nomad_shorts.accounts where user_id <> auth.uid();
  if n <> 0 then raise exception 'FAIL accounts 교차 노출 %', n; end if;
  select count(*) into n from nomad_shorts.topics;
  if n <> 1 then raise exception 'FAIL topics(간접 소유): A 가 본 행 %', n; end if;
  select count(*) into n from nomad_shorts.credit_ledger;
  if n <> 1 then raise exception 'FAIL credit_ledger: %', n; end if;
  select count(*) into n from nomad_shorts.user_settings;
  if n <> 1 then raise exception 'FAIL user_settings: %', n; end if;
  select count(*) into n from nomad_shorts.categories;
  if n < 1 then raise exception 'FAIL categories 공용 읽기'; end if;

  -- 남의 행 수정·삭제는 0행
  update nomad_shorts.projects set name = 'hack' where id = 'b2000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL B 프로젝트 수정됨'; end if;
  delete from nomad_shorts.projects where id = 'b2000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL B 프로젝트 삭제됨'; end if;

  -- 남의 user_id 로 쓰기는 RLS 거부
  begin
    insert into nomad_shorts.accounts (user_id, platform, channel_name)
    values ('bbbbbbbb-0000-0000-0000-00000000000b', 'youtube', '침입');
    raise exception 'FAIL accounts 대리 삽입 허용됨';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into nomad_shorts.user_settings (user_id) values ('bbbbbbbb-0000-0000-0000-00000000000b');
    raise exception 'FAIL user_settings 대리 삽입 허용됨';
  exception when insufficient_privilege or unique_violation then null;
  end;
  -- 클라이언트가 직접 못 쓰는 테이블
  begin
    insert into nomad_shorts.credit_ledger (user_id, kind, delta, idempotency_key)
    values ('aaaaaaaa-0000-0000-0000-00000000000a', 'charge', 999, 'hack');
    raise exception 'FAIL credit_ledger 직접 삽입 허용됨';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from nomad_shorts.api_keys;
    perform 1 from nomad_shorts.extension_connections;
  exception when insufficient_privilege then raise exception 'FAIL api_keys/extension_connections 읽기 권한 없음';
  end;
  -- 자기 프로젝트의 RPC 는 동작한다(수집 작업, 크레딧 예약)
  if (nomad_shorts.create_job('a2000000-0000-0000-0000-000000000001', 'collect', 'idem-own-00001') ->> 'created') is distinct from 'true' then
    raise exception 'FAIL 자기 프로젝트 create_job 실패';
  end if;
  -- B 의 프로젝트에 RPC 로 작업 만들기는 거부
  begin
    perform nomad_shorts.create_job('b2000000-0000-0000-0000-000000000001', 'tts', 'idem-cross-0001');
    raise exception 'FAIL 남의 프로젝트 create_job 허용됨';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ── B 로 접속: 대칭 확인 ────────────────────────────────────
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-00000000000b', true);
do $$
declare n int;
begin
  select count(*) into n from nomad_shorts.projects where id = 'a2000000-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL B 가 A 프로젝트를 봄'; end if;
  select count(*) into n from nomad_shorts.topics where project_id = 'a2000000-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL B 가 A 주제를 봄'; end if;
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

-- ── 동기화 컬럼: updated_at 이 갱신된다 ─────────────────────
update nomad_shorts.user_settings set updated_at = now() - interval '1 day' where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
update nomad_shorts.user_settings set default_len = 20 where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
do $$
begin
  if (select updated_at from nomad_shorts.user_settings where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a') < now() - interval '1 minute' then
    raise exception 'FAIL touch_updated_at 트리거 미동작';
  end if;
end $$;

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
  ('shorts-renders', 'aaaaaaaa-0000-0000-0000-00000000000a' || '/a2000000-0000-0000-0000-000000000001/a.mp4'),
  ('shorts-thumbnails', 'bbbbbbbb-0000-0000-0000-00000000000b' || '/b2000000-0000-0000-0000-000000000001/b.jpg');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from storage.objects where bucket_id like 'shorts-%' and name like 'bbbbbbbb-0000-0000-0000-00000000000b' || '/%') <> 0 then
    raise exception 'FAIL A 가 B 경로 객체를 읽음';
  end if;
  if (select count(*) from storage.objects where bucket_id like 'shorts-%') <> 0 then
    raise exception 'FAIL authenticated 직접 목록(서버 서명 URL 전용이어야 함)';
  end if;
  begin
    insert into storage.objects (bucket_id, name) values ('shorts-renders', 'bbbbbbbb-0000-0000-0000-00000000000b' || '/x/hack.mp4');
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
  if (select count(*) from storage.objects where bucket_id like 'shorts-%' and name like 'aaaaaaaa-0000-0000-0000-00000000000a' || '/%') <> 0 then
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

select 'CHECK_USER_OK' as result;
rollback;
