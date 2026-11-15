-- personal user안 검사: 사용자 2명 교차 접근 0 · anon 표 접근 0 · 복합 FK(남의 풀이·여행 참조 불가) · PDF 경로 접두
-- · 기능 잠금(C=풀이만, A=리포트·여행) · 잠김(구독 끊김·개인 조직 비활성)에도 본인 삭제 가능. 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/personal/run_check.sh user

create schema zz_check;
grant usage on schema zz_check to anon, authenticated, service_role;
create function zz_check.denied(q text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin execute q; ok := true; exception when others then null; end;
  if ok then raise exception 'NOT DENIED: %', q; end if;
end $$;
create function zz_check.fails_with(q text, msg text) returns void language plpgsql as $$
declare got text;
begin
  begin execute q; got := null; exception when others then got := sqlstate || ' ' || sqlerrm; end;
  if got is null then raise exception 'NOT DENIED: %', q; end if;
  if got not like '%' || msg || '%' then raise exception 'wrong error for %: got [%], want [%]', q, got, msg; end if;
end $$;
create function zz_check.expect(q text, want bigint) returns void language plpgsql as $$
declare r bigint; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
create function zz_check.login(u text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function zz_check.as_role(r text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', r)::text, true);
  perform set_config('role', r, true);
end $$;
create function zz_check.porg(u text) returns uuid language sql as $$
  select m.organization_id from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
   where m.user_id = u::uuid and m.role = 'owner' and o.kind = 'personal' limit 1 $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: u1(개인 조직 구독 없음 = C), u2(개인 조직 플랜 A). 개인 조직은 가입 트리거가 만든다 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  (zz_check.porg('00000000-0000-0000-0000-0000000000a2'), 'personal', 'A', 'active');

-- ==== 0. 서버(service_role) ====
select zz_check.as_role('service_role');
-- 암호문은 합성 base64(실제 암호화 아님). 서버가 앱 계층에서 암호화해 넣는다
insert into nomad_personal.readings (id, user_id, kind, input_ciphertext, key_version, result_md) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a1', 'dream', repeat('QUJD', 12), 1, '풀이 a'),
  ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000a2', 'saju', repeat('REVG', 11) || 'RA==', 1, '풀이 b');
insert into nomad_personal.birth_profiles (user_id, birth_ciphertext, key_version, gender) values
  ('00000000-0000-0000-0000-0000000000a1', repeat('QUJD', 10), 1, 'female'),
  ('00000000-0000-0000-0000-0000000000a2', repeat('REVG', 10), 1, 'male');
insert into nomad_personal.saved_reports (id, user_id, reading_id, pdf_path) values
  ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000a2/personal/r1.pdf');
insert into nomad_personal.trips (id, user_id, title) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a1', '합성 여행 a1'),
  ('00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-0000000000a1', '합성 여행 a2'),
  ('00000000-0000-0000-0000-0000000007b1', '00000000-0000-0000-0000-0000000000a2', '합성 여행 b');
insert into nomad_personal.trip_days (user_id, trip_id, day) values
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000007b1', 'day1');
-- 복합 FK: 남의 풀이·여행 참조 불가, PDF 경로는 소유자 폴더만, 날짜 역전 불가
select zz_check.fails_with($$insert into nomad_personal.saved_reports (user_id, reading_id) values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006b1')$$, '23503');
select zz_check.fails_with($$insert into nomad_personal.trip_days (user_id, trip_id) values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007b1')$$, '23503');
select zz_check.fails_with($$insert into nomad_personal.saved_reports (user_id, reading_id, pdf_path) values ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000a1/personal/x.pdf')$$, '23514');
select zz_check.fails_with($$insert into nomad_personal.trips (user_id, title, start_date, end_date) values ('00000000-0000-0000-0000-0000000000a2', 't', '2026-02-02', '2026-02-01')$$, '23514');
-- 암호문 형식(task-018): 평문 생년월일·사주 입력은 CHECK가 거부, 암호문에는 key_version 필수
select zz_check.fails_with($$insert into nomad_personal.birth_profiles (user_id, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-0000000000a1', '1990-01-01 07:30', 1)$$, '23514');
select zz_check.fails_with($$insert into nomad_personal.readings (user_id, kind, input_ciphertext, key_version) values ('00000000-0000-0000-0000-0000000000a1', 'saju', '{"birth":"2000-01-01"}', 1)$$, '23514');
select zz_check.fails_with($$insert into nomad_personal.readings (user_id, kind, input_ciphertext) values ('00000000-0000-0000-0000-0000000000a1', 'saju', repeat('QUJD', 12))$$, '23514');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 1. anon: 표·함수 접근 0 ====
select zz_check.as_role('anon');
select zz_check.denied('select count(*) from nomad_personal.readings');
select zz_check.denied('select count(*) from nomad_personal.saved_reports');
select zz_check.denied('select count(*) from nomad_personal.birth_profiles');
select zz_check.denied('select count(*) from nomad_personal.trips');
select zz_check.denied('select count(*) from nomad_personal.trip_days');
select zz_check.denied($$select nomad_personal.has_access('00000000-0000-0000-0000-0000000000a1', 'divination')$$);
select zz_check.denied('select * from nomad_personal.erase_my_data()');
reset role;

-- ==== 2. u1(C): 본인 풀이·생년월일만, 리포트·여행 잠김, 남의 행 0 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_personal.readings', 1);
select zz_check.expect('select count(*) from nomad_personal.birth_profiles', 1);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 0);
select zz_check.expect('select count(*) from nomad_personal.trips', 0);
select zz_check.expect('select count(*) from nomad_personal.trip_days', 0);
select zz_check.expect($$select nomad_personal.has_access('00000000-0000-0000-0000-0000000000a1', 'divination')::int$$, 1);
select zz_check.expect($$select nomad_personal.has_access('00000000-0000-0000-0000-0000000000a2', 'divination')::int$$, 0);
select zz_check.denied($$select nomad_personal.personal_organization('00000000-0000-0000-0000-0000000000a1')$$);
insert into nomad_personal.readings (kind, result_md) values ('dream', '풀이 a2');
-- 암호문 컬럼은 본인도 읽기·쓰기 불가(서버만), 생년월일 쓰기는 서버만
select zz_check.denied('select input_ciphertext from nomad_personal.readings');
select zz_check.denied('select birth_ciphertext from nomad_personal.birth_profiles');
select zz_check.denied($$insert into nomad_personal.readings (kind, input_ciphertext, key_version) values ('saju', repeat('QUJD', 12), 1)$$);
select zz_check.denied($$update nomad_personal.readings set input_ciphertext = repeat('QUJD', 12)$$);
select zz_check.denied($$insert into nomad_personal.birth_profiles (birth_ciphertext, key_version) values (repeat('QUJD', 12), 1)$$);
select zz_check.denied($$update nomad_personal.birth_profiles set birth_ciphertext = repeat('QUJD', 12)$$);
select zz_check.denied($$update nomad_personal.birth_profiles set gender = 'male'$$);
select zz_check.expect('select count(*) from nomad_personal.readings where key_version = 1', 1);
select zz_check.expect('select count(*) from nomad_personal.readings', 2);
select zz_check.denied($$insert into nomad_personal.readings (user_id, kind) values ('00000000-0000-0000-0000-0000000000a2', 'dream')$$);
select zz_check.denied($$insert into nomad_personal.readings (id, kind) values (gen_random_uuid(), 'dream')$$);
select zz_check.denied($$update nomad_personal.readings set user_id = '00000000-0000-0000-0000-0000000000a2'$$);
select zz_check.expect($$with u as (update nomad_personal.readings set result_md = 'x' where user_id = '00000000-0000-0000-0000-0000000000a2' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with d as (delete from nomad_personal.readings where id = '00000000-0000-0000-0000-0000000006b1' returning 1) select count(*) from d$$, 0);
select zz_check.expect($$with d as (delete from nomad_personal.birth_profiles where user_id = '00000000-0000-0000-0000-0000000000a2' returning 1) select count(*) from d$$, 0);
select zz_check.denied($$insert into nomad_personal.saved_reports (reading_id) values ('00000000-0000-0000-0000-0000000006a1')$$);
select zz_check.denied($$insert into nomad_personal.trips (title) values ('잠긴 여행')$$);
-- 잠긴 행은 직접 삭제도 0행(보이지 않음) → 삭제는 erase_my_data(4절)
select zz_check.expect($$with d as (delete from nomad_personal.trips where id = '00000000-0000-0000-0000-0000000007a1' returning 1) select count(*) from d$$, 0);
reset role;

-- ==== 3. u2(A): 본인 행 전부, 남의 여행에 일자·남의 풀이로 리포트 불가 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_personal.readings', 1);
select zz_check.expect('select count(*) from nomad_personal.birth_profiles', 1);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 1);
select zz_check.expect('select count(*) from nomad_personal.trips', 1);
select zz_check.expect('select count(*) from nomad_personal.trip_days', 1);
select zz_check.expect($$select count(*) from nomad_personal.readings where id = '00000000-0000-0000-0000-0000000006a1'$$, 0);
insert into nomad_personal.trips (title, start_date, end_date) values ('새 여행', '2026-03-01', '2026-03-03');
insert into nomad_personal.trip_days (trip_id, day, tools) values ('00000000-0000-0000-0000-0000000007b1', 'day2', '{"weather":"맑음"}');
insert into nomad_personal.saved_reports (reading_id, pdf_path) values ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000a2/personal/r2.pdf');
select zz_check.denied($$insert into nomad_personal.trip_days (trip_id, day) values ('00000000-0000-0000-0000-0000000007a2', 'x')$$);
select zz_check.denied($$insert into nomad_personal.saved_reports (reading_id) values ('00000000-0000-0000-0000-0000000006a1')$$);
select zz_check.denied($$insert into nomad_personal.saved_reports (reading_id, pdf_path) values ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000a1/personal/x.pdf')$$);
select zz_check.expect($$with u as (update nomad_personal.trips set title = 'x' where id = '00000000-0000-0000-0000-0000000007a2' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with d as (delete from nomad_personal.trips where id = '00000000-0000-0000-0000-0000000007a2' returning 1) select count(*) from d$$, 0);
reset role;

-- ==== 4. 잠김 회귀 ====
-- 4.1 u2 구독 끊김(C 취급) → 리포트·여행 읽기·쓰기 잠김, 풀이는 열림
update nomad_core.subscriptions set status = 'inactive' where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a2') and product_code = 'personal';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_personal.readings', 1);
select zz_check.expect('select count(*) from nomad_personal.trips', 0);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 0);
select zz_check.denied($$insert into nomad_personal.trips (title) values ('잠긴 여행')$$);
select zz_check.expect($$with u as (update nomad_personal.trips set title = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with d as (delete from nomad_personal.saved_reports returning 1) select count(*) from d$$, 0);
reset role;
-- 4.2 기능 판정은 개인 조직만: owner인 팀 조직에 플랜 A가 있어도 개인 조직이 C면 여행 잠김
insert into nomad_core.organizations (id, name, kind) values ('00000000-0000-0000-0000-00000000000e', 'team E', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values ('00000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values ('00000000-0000-0000-0000-00000000000e', 'personal', 'A', 'active');
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_personal.trips', 0);
-- 4.3 잠겨도 개인정보 삭제는 된다: 본인 행 전부(풀이 1·리포트 2·여행 2·일자 2·생년월일 1)
-- 반환은 지운 리포트의 pdf_path 목록(서버가 스토리지 정리)
select zz_check.expect($$select count(*) from nomad_personal.erase_my_data() p where p like '00000000-0000-0000-0000-0000000000a2/personal/%'$$, 2);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select (select count(*) from nomad_personal.readings where user_id = '00000000-0000-0000-0000-0000000000a2') + (select count(*) from nomad_personal.saved_reports where user_id = '00000000-0000-0000-0000-0000000000a2') + (select count(*) from nomad_personal.trips where user_id = '00000000-0000-0000-0000-0000000000a2') + (select count(*) from nomad_personal.trip_days where user_id = '00000000-0000-0000-0000-0000000000a2') + (select count(*) from nomad_personal.birth_profiles where user_id = '00000000-0000-0000-0000-0000000000a2')$$, 0);
select zz_check.expect($$select count(*) from nomad_personal.readings where user_id = '00000000-0000-0000-0000-0000000000a1'$$, 2);
-- 4.4 u1 개인 조직 비활성 → 0행·쓰기 거부, 전체 삭제는 된다(풀이 2·여행 2·생년월일 1)
update nomad_core.organizations set active = false where id = zz_check.porg('00000000-0000-0000-0000-0000000000a1');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_personal.readings', 0);
select zz_check.expect('select count(*) from nomad_personal.birth_profiles', 0);
select zz_check.denied($$insert into nomad_personal.readings (kind) values ('dream')$$);
select zz_check.expect('select count(*) from nomad_personal.erase_my_data()', 0);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_personal.birth_profiles$$, 0);
select zz_check.expect($$select (select count(*) from nomad_personal.readings) + (select count(*) from nomad_personal.trips)$$, 0);

-- ==== 5. 정적 검사 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_personal'$$, 5);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_personal' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_personal' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_personal' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE') and column_name in ('id', 'user_id', 'created_at', 'updated_at')$$, 0);
-- 평문 생년월일·사주 입력 컬럼 없음, 암호문 컬럼은 authenticated 권한 없음(쓰기·복호화는 서버만)
select zz_check.expect($$select count(*) from information_schema.columns where table_schema = 'nomad_personal' and column_name in ('birth_date', 'birth_time', 'input_json')$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_personal' and grantee = 'authenticated' and column_name like '%ciphertext'$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'nomad_personal' and p.prosecdef and not coalesce(array_to_string(p.proconfig, ',') like '%search_path=""%', false)$$, 0);
