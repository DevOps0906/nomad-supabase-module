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

select 'CHECK_ORG_OK' as result;
rollback;
