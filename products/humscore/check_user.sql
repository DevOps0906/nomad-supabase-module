-- humscore user안 교차 접근 검사 (합성 데이터, 마지막에 rollback)
-- 실행: 아래 마커 줄 위치에 user/0001_humscore.sql 의 begin;/commit; 를 뺀 본문을 끼워 한 번에 넣는다.
--   F=products/humscore; { sed -n '1,/^-- @@APPLY@@/p' $F/check_user.sql; sed '/^begin;$/d;/^commit;$/d' $F/user/0001_humscore.sql; sed -n '/^-- @@APPLY@@/,$p' $F/check_user.sql; } \
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

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@example.test'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@example.test');

-- ===== 사용자 A =====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
insert into nomad_humscore.scores (id, user_id, title, data) values
  ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'A곡', '{"n":1}');
insert into nomad_humscore.setlists (user_id, title, service_date, items) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'A콘티', '2026-11-15',
   '[{"scoreId":"11111111-0000-0000-0000-000000000001","transpose":0,"bpm":null}]');
insert into nomad_humscore.transcription_jobs (user_id, kind) values ('aaaaaaaa-0000-0000-0000-000000000001', 'separate');
select nomad_humscore.reissue_share_link('11111111-0000-0000-0000-000000000001',
  encode(sha256(convert_to('tokentokentokentokentokentokentokentokento1', 'UTF8')), 'hex'));
select humchk.expect_count('select count(*) from nomad_humscore.scores', 1);
select humchk.expect_count('select count(*) from nomad_humscore.share_links', 1);
-- A 자신의 정상 동작: 상태 위조 job 금지, update 금지
select humchk.expect_fail($q$insert into nomad_humscore.transcription_jobs (user_id, kind, status) values ('aaaaaaaa-0000-0000-0000-000000000001','arrange','done')$q$, '42501');
select humchk.expect_fail($q$update nomad_humscore.transcription_jobs set status = 'done'$q$, '42501');
-- 오래된 쓰기는 LWW 가드가 무시
select humchk.expect_count($q$with x as (update nomad_humscore.scores set title = 'stale', updated_at = now() - interval '1 day' returning 1) select count(*) from x$q$, 0);
-- 항목 한도 위반(transpose 범위)
select humchk.expect_fail($q$insert into nomad_humscore.setlists (user_id, title, service_date, items) values ('aaaaaaaa-0000-0000-0000-000000000001','x','2026-11-15','[{"scoreId":"11111111-0000-0000-0000-000000000001","transpose":99}]')$q$, '23514');

-- ===== 사용자 B: 교차 접근 거부 =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}', true);
select humchk.expect_count('select count(*) from nomad_humscore.scores', 0);
select humchk.expect_count('select count(*) from nomad_humscore.setlists', 0);
select humchk.expect_count('select count(*) from nomad_humscore.share_links', 0);
select humchk.expect_count('select count(*) from nomad_humscore.transcription_jobs', 0);
select humchk.expect_count($q$with x as (update nomad_humscore.scores set title = 'hack', updated_at = now() + interval '1 minute' returning 1) select count(*) from x$q$, 0);
select humchk.expect_count($q$with x as (delete from nomad_humscore.scores returning 1) select count(*) from x$q$, 0);
select humchk.expect_count($q$with x as (update nomad_humscore.setlists set title = 'hack' returning 1) select count(*) from x$q$, 0);
select humchk.expect_fail($q$insert into nomad_humscore.scores (id, user_id, title, data) values (gen_random_uuid(), 'aaaaaaaa-0000-0000-0000-000000000001', 'x', '{}')$q$, '42501');
-- B 콘티가 A 악보를 담을 수 없다(items 소유 트리거)
select humchk.expect_fail($q$insert into nomad_humscore.setlists (user_id, title, service_date, items) values ('bbbbbbbb-0000-0000-0000-000000000002','x','2026-11-15','[{"scoreId":"11111111-0000-0000-0000-000000000001","transpose":0}]')$q$, '23514');
-- B 가 A 악보 공유 링크를 만들 수 없다
select humchk.expect_fail($q$insert into nomad_humscore.share_links (score_id, owner_id, token_hash) values ('11111111-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002', repeat('a',64))$q$, '42501');
select humchk.expect_fail($q$select nomad_humscore.reissue_share_link('11111111-0000-0000-0000-000000000001', repeat('b',64))$q$, '42501');
select humchk.expect_fail($q$insert into nomad_humscore.transcription_jobs (user_id, kind) values ('aaaaaaaa-0000-0000-0000-000000000001','separate')$q$, '42501');

-- ===== anon: 테이블 직접 접근 거부, RPC 만 =====
reset role;
set local role anon;
select humchk.expect_fail('select * from nomad_humscore.scores', '42501');
select humchk.expect_fail('select * from nomad_humscore.share_links', '42501');
select humchk.expect_fail('select * from nomad_humscore.setlists', '42501');
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('tokentokentokentokentokentokentokentokento1')$q$, 1);
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('wrongwrongwrongwrongwrongwrongwrongwrongwr1')$q$, 0);
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('short')$q$, 0);
select humchk.expect_fail('select nomad_humscore_private.scores_row_cap()', '42501');

-- ===== A 삭제 → 링크 회수, anon 열람 불가 =====
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
update nomad_humscore.scores set deleted_at = now(), updated_at = now() + interval '1 second' where id = '11111111-0000-0000-0000-000000000001';
select humchk.expect_count($q$select count(*) from nomad_humscore.share_links where revoked_at is not null$q$, 1);
reset role;
set local role anon;
select humchk.expect_count($q$select count(*) from nomad_humscore.get_shared_score('tokentokentokentokentokentokentokentokento1')$q$, 0);

reset role;
select 'humscore user checks passed' as result;
rollback;
