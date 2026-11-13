-- humscore org안 교차 접근 검사 (합성 데이터, 마지막에 rollback)
-- 실행: 아래 마커 줄 위치에 org/0001_humscore.sql 의 begin;/commit; 를 뺀 본문을 끼워 한 번에 넣는다.
--   F=products/humscore; { sed -n '1,/^-- @@APPLY@@/p' $F/check_org.sql; sed '/^begin;$/d;/^commit;$/d' $F/org/0001_humscore.sql; sed -n '/^-- @@APPLY@@/,$p' $F/check_org.sql; } \
--     | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1
begin;

-- nomad_core.touch_updated_at 이 core 에 들어오기 전 임시 정의(rollback 으로 사라진다)
create or replace function nomad_core.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := pg_catalog.now(); return new; end; $$;

drop schema if exists nomad_humscore cascade;   -- 청사진(같은 이름)
-- @@APPLY@@

create schema humchk;
grant usage on schema humchk to anon, authenticated;
create function humchk.expect_fail(q text, state_prefix text) returns void language plpgsql as $$
begin
  begin
    execute q;
  exception when others then
    if sqlstate like state_prefix || '%' then return; end if;
    raise exception 'wrong error % (% ) for: %', sqlstate, sqlerrm, q;
  end;
  raise exception 'EXPECTED FAILURE but succeeded: %', q;
end $$;
create function humchk.expect_count(q text, want bigint) returns void language plpgsql as $$
declare n bigint;
begin
  execute q into n;
  if n is distinct from want then raise exception 'expected % got % for: %', want, n, q; end if;
end $$;
grant execute on all functions in schema humchk to anon, authenticated;

-- 사용자 A(조직 OA), B(조직 OB) — 가입 트리거가 1인 조직을 만든다. C 는 OA 의 viewer, D 는 OA 의 editor.
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@example.test'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@example.test'),
  ('cccccccc-0000-0000-0000-000000000003', 'c@example.test'),
  ('dddddddd-0000-0000-0000-000000000004', 'd@example.test');
create temp table orgs as
  select m.user_id, m.organization_id as org from nomad_core.memberships m
  where m.user_id in ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002');
grant select on orgs to authenticated, anon;
insert into nomad_core.memberships (organization_id, user_id, role)
  select org, 'cccccccc-0000-0000-0000-000000000003', 'viewer' from orgs where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into nomad_core.memberships (organization_id, user_id, role)
  select org, 'dddddddd-0000-0000-0000-000000000004', 'editor' from orgs where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
select set_config('humchk.oa', (select org::text from orgs where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), false);
select set_config('humchk.ob', (select org::text from orgs where user_id = 'bbbbbbbb-0000-0000-0000-000000000002'), false);

-- ===== A (OA owner) =====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into nomad_humscore.scores (id, organization_id, title, data) values
  ('11111111-0000-0000-0000-000000000001', current_setting('humchk.oa')::uuid, 'A곡', '{"n":1}');
insert into nomad_humscore.setlists (organization_id, title, service_date, items) values
  (current_setting('humchk.oa')::uuid, 'A콘티', '2026-11-15',
   '[{"scoreId":"11111111-0000-0000-0000-000000000001","transpose":0,"bpm":null}]');
insert into nomad_humscore.transcription_jobs (organization_id, kind) values (current_setting('humchk.oa')::uuid, 'separate');
select nomad_humscore.reissue_share_link('11111111-0000-0000-0000-000000000001',
  encode(sha256(convert_to('tokentokentokentokentokentokentokentokento1', 'UTF8')), 'hex'));
select humchk.expect_count('select count(*) from nomad_humscore.scores', 1);
select humchk.expect_count('select count(*) from nomad_humscore.share_links', 1);
-- 조직 이전 금지, 다른 조직(OB)에 쓰기 금지
select humchk.expect_fail($q$update nomad_humscore.scores set organization_id = current_setting('humchk.ob')::uuid$q$, '42501');
select humchk.expect_fail($q$insert into nomad_humscore.scores (id, organization_id, title, data) values (gen_random_uuid(), current_setting('humchk.ob')::uuid, 'x', '{}')$q$, '42501');
select humchk.expect_fail($q$insert into nomad_humscore.transcription_jobs (organization_id, kind, status) values (current_setting('humchk.oa')::uuid,'arrange','done')$q$, '42501');
select humchk.expect_fail($q$update nomad_humscore.transcription_jobs set status = 'done'$q$, '42501');
select humchk.expect_count($q$with x as (update nomad_humscore.scores set title = 'stale', updated_at = now() - interval '1 day' returning 1) select count(*) from x$q$, 0);
select humchk.expect_fail($q$insert into nomad_humscore.setlists (organization_id, title, service_date, items) values (current_setting('humchk.oa')::uuid,'x','2026-11-15','[{"scoreId":"11111111-0000-0000-0000-000000000001","transpose":99}]')$q$, '23514');

-- ===== D (OA editor): 읽기·쓰기 가능 =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-000000000004","role":"authenticated"}', true);
select humchk.expect_count('select count(*) from nomad_humscore.scores', 1);
insert into nomad_humscore.scores (id, organization_id, title, data) values
  ('11111111-0000-0000-0000-000000000002', current_setting('humchk.oa')::uuid, 'D곡', '{}');

-- ===== C (OA viewer): 읽기만 =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-000000000003","role":"authenticated"}', true);
select humchk.expect_count('select count(*) from nomad_humscore.scores', 2);
select humchk.expect_count('select count(*) from nomad_humscore.share_links', 1);
select humchk.expect_fail($q$insert into nomad_humscore.scores (id, organization_id, title, data) values (gen_random_uuid(), current_setting('humchk.oa')::uuid, 'x', '{}')$q$, '42501');
select humchk.expect_count($q$with x as (update nomad_humscore.scores set title = 'hack', updated_at = now() + interval '1 minute' returning 1) select count(*) from x$q$, 0);
select humchk.expect_count($q$with x as (delete from nomad_humscore.scores returning 1) select count(*) from x$q$, 0);
select humchk.expect_fail($q$insert into nomad_humscore.setlists (organization_id, title, service_date) values (current_setting('humchk.oa')::uuid,'x','2026-11-15')$q$, '42501');
select humchk.expect_fail($q$insert into nomad_humscore.transcription_jobs (organization_id, kind) values (current_setting('humchk.oa')::uuid,'separate')$q$, '42501');
select humchk.expect_fail($q$select nomad_humscore.reissue_share_link('11111111-0000-0000-0000-000000000001', repeat('b',64))$q$, '42501');

-- ===== B (OB owner): 다른 조직 교차 거부 =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}', true);
select humchk.expect_count('select count(*) from nomad_humscore.scores', 0);
select humchk.expect_count('select count(*) from nomad_humscore.setlists', 0);
select humchk.expect_count('select count(*) from nomad_humscore.share_links', 0);
select humchk.expect_count('select count(*) from nomad_humscore.transcription_jobs', 0);
select humchk.expect_count($q$with x as (update nomad_humscore.scores set title = 'hack', updated_at = now() + interval '1 minute' returning 1) select count(*) from x$q$, 0);
select humchk.expect_count($q$with x as (delete from nomad_humscore.scores returning 1) select count(*) from x$q$, 0);
select humchk.expect_fail($q$insert into nomad_humscore.scores (id, organization_id, title, data) values (gen_random_uuid(), current_setting('humchk.oa')::uuid, 'x', '{}')$q$, '42501');
-- OB 콘티가 OA 악보를 담을 수 없다
select humchk.expect_fail($q$insert into nomad_humscore.setlists (organization_id, title, service_date, items) values (current_setting('humchk.ob')::uuid,'x','2026-11-15','[{"scoreId":"11111111-0000-0000-0000-000000000001","transpose":0}]')$q$, '23514');
-- OB 가 OA 악보를 가리키는 링크를 자기 조직으로 만들 수 없다(FK 는 통과해도 정책이 거부)
select humchk.expect_fail($q$insert into nomad_humscore.share_links (organization_id, score_id, token_hash) values (current_setting('humchk.ob')::uuid,'11111111-0000-0000-0000-000000000001', repeat('a',64))$q$, '42501');
select humchk.expect_fail($q$select nomad_humscore.reissue_share_link('11111111-0000-0000-0000-000000000001', repeat('b',64))$q$, '42501');
select humchk.expect_fail($q$insert into nomad_humscore.transcription_jobs (organization_id, kind) values (current_setting('humchk.oa')::uuid,'separate')$q$, '42501');

-- ===== anon: 테이블 직접 접근 거부, RPC 만 =====
reset role;
set local role anon;
select humchk.expect_fail('select * from nomad_humscore.scores', '42501');
select humchk.expect_fail('select * from nomad_humscore.share_links', '42501');
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('tokentokentokentokentokentokentokentokento1')$q$, 1);
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('wrongwrongwrongwrongwrongwrongwrongwrongwr1')$q$, 0);

-- ===== A 삭제 → 링크 회수 =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
update nomad_humscore.scores set deleted_at = now(), updated_at = now() + interval '1 second' where id = '11111111-0000-0000-0000-000000000001';
select humchk.expect_count($q$select count(*) from nomad_humscore.share_links where revoked_at is not null$q$, 1);
reset role;
set local role anon;
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('tokentokentokentokentokentokentokentokento1')$q$, 0);

reset role;
select 'humscore org checks passed' as result;
rollback;
