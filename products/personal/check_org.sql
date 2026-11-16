-- personal org안 검사: 조직 2개 교차 접근 0 · 같은 조직 안에서도 민감 표(풀이·리포트·생년월일)는 작성자만 · anon 표 접근 0
-- · 복합 FK(다른 조직·다른 작성자 참조 불가) · 여행 공유(viewer 읽기만) · 잠김·탈퇴·조직 비활성에도 erase_personal_data 삭제. 합성 데이터만, rollback.
-- 실행: bash products/personal/run_check.sh org

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
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(team, 플랜 A: a1 owner · a3 editor · a4 admin · a5 viewer), 조직 B(personal, 구독 없음 = C: a2 owner) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'personal');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'admin'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
update nomad_core.organizations set active = false
 where id not in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'personal', 'A', 'active');

-- ==== 0. 서버(service_role) ====
select zz_check.as_role('service_role');
-- 암호문은 합성 base64(실제 암호화 아님). 서버가 앱 계층에서 암호화해 넣는다
insert into nomad_personal.readings (id, organization_id, created_by, kind, input_ciphertext, key_version, result_md) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'dream', repeat('QUJD', 12), 1, '풀이'),
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'dream', repeat('REVG', 12), 1, '풀이'),
  ('00000000-0000-0000-0000-0000000006b2', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'saju', repeat('R0hJ', 11) || 'Rw==', 1, '풀이');
insert into nomad_personal.birth_profiles (organization_id, user_id, birth_ciphertext, key_version) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', repeat('QUJD', 10), 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', repeat('REVG', 10), 1),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', repeat('SktM', 10), 1),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', repeat('R0hJ', 10), 1);
-- 암호문 형식(task-018): 평문 생년월일·사주 입력은 CHECK가 거부, 암호문에는 key_version 필수
select zz_check.fails_with($$insert into nomad_personal.birth_profiles (organization_id, user_id, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a5', '1990-01-01 07:30', 1)$$, '23514');
select zz_check.fails_with($$insert into nomad_personal.readings (organization_id, created_by, kind, input_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'saju', '{"birth":"2000-01-01"}', 1)$$, '23514');
select zz_check.fails_with($$insert into nomad_personal.readings (organization_id, created_by, kind, input_ciphertext) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'saju', repeat('QUJD', 12))$$, '23514');
insert into nomad_personal.saved_reports (id, organization_id, created_by, reading_id, pdf_path) values
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006a1',
   '00000000-0000-0000-0000-00000000000a/personal/00000000-0000-0000-0000-0000000000a1/r1.pdf');
insert into nomad_personal.trips (id, organization_id, created_by, title) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '팀 여행');
insert into nomad_personal.trip_days (organization_id, trip_id, day) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a1', 'day1');
-- 복합 FK: 다른 작성자·다른 조직의 풀이·여행 참조 불가, PDF 경로는 <조직>/personal/<작성자>/ 만
select zz_check.fails_with($$insert into nomad_personal.saved_reports (organization_id, created_by, reading_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000006a1')$$, '23503');
select zz_check.fails_with($$insert into nomad_personal.saved_reports (organization_id, created_by, reading_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006a1')$$, '23503');
select zz_check.fails_with($$insert into nomad_personal.trip_days (organization_id, trip_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000007a1')$$, '23503');
select zz_check.fails_with($$insert into nomad_personal.saved_reports (organization_id, created_by, reading_id, pdf_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000000b/personal/00000000-0000-0000-0000-0000000000a1/x.pdf')$$, '23514');
-- 같은 조직 다른 작성자 폴더·작성자 없는 경로 거부(서버도)
select zz_check.fails_with($$update nomad_personal.saved_reports set pdf_path = '00000000-0000-0000-0000-00000000000a/personal/00000000-0000-0000-0000-0000000000a3/x.pdf' where id = '00000000-0000-0000-0000-0000000009a1'$$, '23514');
select zz_check.fails_with($$update nomad_personal.saved_reports set pdf_path = '00000000-0000-0000-0000-00000000000a/personal/x.pdf' where id = '00000000-0000-0000-0000-0000000009a1'$$, '23514');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 1. anon: 표·함수 접근 0 ====
select zz_check.as_role('anon');
select zz_check.denied('select count(*) from nomad_personal.readings');
select zz_check.denied('select count(*) from nomad_personal.saved_reports');
select zz_check.denied('select count(*) from nomad_personal.birth_profiles');
select zz_check.denied('select count(*) from nomad_personal.trips');
select zz_check.denied('select count(*) from nomad_personal.trip_days');
select zz_check.denied($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1')$$);
reset role;

-- ==== 2. a1(owner A): 본인 민감 행만(같은 조직 a3 것도 0), 여행 공유 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_personal.readings', 1);
select zz_check.expect('select count(*) from nomad_personal.birth_profiles', 1);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 1);
select zz_check.expect('select count(*) from nomad_personal.trips', 1);
select zz_check.expect('select count(*) from nomad_personal.trip_days', 1);
select zz_check.fails_with($$update nomad_personal.readings set result_md = 'x' where id = '00000000-0000-0000-0000-0000000006a3'$$, '42501');
select zz_check.expect($$with d as (delete from nomad_personal.birth_profiles where user_id = '00000000-0000-0000-0000-0000000000a3' returning 1) select count(*) from d$$, 0);
-- readings 쓰기는 서버 전용(결정 1): 본인 행이라도 insert·update 42501 → 서버가 대신 쓴다
select zz_check.fails_with($$insert into nomad_personal.readings (organization_id, kind, result_md) values ('00000000-0000-0000-0000-00000000000a', 'tarot', '풀이')$$, '42501');
select zz_check.fails_with($$update nomad_personal.readings set result_md = 'x'$$, '42501');
reset role;
select zz_check.as_role('service_role');
insert into nomad_personal.readings (organization_id, created_by, kind, result_md) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'tarot', '풀이');
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
-- 암호문 컬럼은 작성자 본인도 읽기·쓰기 불가(서버만), 생년월일 쓰기는 서버만
select zz_check.denied('select input_ciphertext from nomad_personal.readings');
select zz_check.denied('select birth_ciphertext from nomad_personal.birth_profiles');
select zz_check.denied($$insert into nomad_personal.readings (organization_id, kind, input_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000a', 'saju', repeat('QUJD', 12), 1)$$);
select zz_check.denied($$update nomad_personal.readings set input_ciphertext = repeat('QUJD', 12)$$);
select zz_check.denied($$update nomad_personal.birth_profiles set birth_ciphertext = repeat('QUJD', 12)$$);
insert into nomad_personal.trips (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', '두 번째 여행');
select zz_check.denied($$insert into nomad_personal.readings (organization_id, kind) values ('00000000-0000-0000-0000-00000000000b', 'dream')$$);
select zz_check.denied($$insert into nomad_personal.readings (organization_id, created_by, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'dream')$$);
select zz_check.denied($$insert into nomad_personal.readings (id, organization_id, kind) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 'dream')$$);
select zz_check.denied($$update nomad_personal.readings set organization_id = '00000000-0000-0000-0000-00000000000b'$$);
select zz_check.denied($$update nomad_personal.trips set created_by = '00000000-0000-0000-0000-0000000000a3'$$);
-- 리포트 pdf_path는 사용자 권한 없음(다른 작성자 경로 지정 차단): 행 추가는 되고 경로는 서버만
insert into nomad_personal.saved_reports (organization_id, reading_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1');
select zz_check.denied($$insert into nomad_personal.saved_reports (organization_id, reading_id, pdf_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000000a/personal/00000000-0000-0000-0000-0000000000a3/x.pdf')$$);
select zz_check.denied($$update nomad_personal.saved_reports set pdf_path = '00000000-0000-0000-0000-00000000000a/personal/00000000-0000-0000-0000-0000000000a3/x.pdf'$$);
-- 현직 멤버 대상 삭제 거부(owner → editor)
select zz_check.fails_with($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3')$$, '42501');
reset role;
-- admin → owner 대상 삭제 거부(현직 멤버)
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.fails_with($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1')$$, '42501');
reset role;

-- ==== 3. a3(editor A): 본인 민감 행만, 여행 쓰기 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect('select count(*) from nomad_personal.readings', 1);
select zz_check.expect($$select count(*) from nomad_personal.readings where id = '00000000-0000-0000-0000-0000000006a1'$$, 0);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 0);
select zz_check.expect('select count(*) from nomad_personal.trips', 2);
select zz_check.expect($$with u as (update nomad_personal.trips set title = '수정' where id = '00000000-0000-0000-0000-0000000007a1' returning 1) select count(*) from u$$, 1);
insert into nomad_personal.trip_days (organization_id, trip_id, day) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a1', 'day2');
select zz_check.denied($$insert into nomad_personal.saved_reports (organization_id, reading_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1')$$);
select zz_check.fails_with($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1')$$, '42501');
reset role;

-- ==== 4. a5(viewer A): 여행 읽기만, 풀이·생년월일 쓰기는 서버만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect('select count(*) from nomad_personal.readings', 0);
select zz_check.expect('select count(*) from nomad_personal.trips', 2);
select zz_check.expect('select count(*) from nomad_personal.trip_days', 2);
select zz_check.denied($$insert into nomad_personal.trips (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'v')$$);
select zz_check.expect($$with u as (update nomad_personal.trips set title = 'v' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with d as (delete from nomad_personal.trip_days returning 1) select count(*) from d$$, 0);
select zz_check.fails_with($$insert into nomad_personal.readings (organization_id, kind) values ('00000000-0000-0000-0000-00000000000a', 'dream')$$, '42501');
select zz_check.fails_with($$insert into nomad_personal.birth_profiles (organization_id, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000a', repeat('QUJD', 12), 1)$$, '42501');
select zz_check.denied($$update nomad_personal.birth_profiles set gender = 'male'$$);
select zz_check.expect('select count(*) from nomad_personal.birth_profiles', 1);
reset role;

-- ==== 5. a2(owner B, C): 조직 A 0행, 리포트·여행 잠김 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_personal.readings', 1);
select zz_check.expect('select count(*) from nomad_personal.birth_profiles', 1);
select zz_check.expect('select count(*) from nomad_personal.trips', 0);
select zz_check.expect('select count(*) from nomad_personal.trip_days', 0);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 0);
select zz_check.denied($$insert into nomad_personal.trips (organization_id, title) values ('00000000-0000-0000-0000-00000000000b', 'c')$$);
select zz_check.denied($$insert into nomad_personal.saved_reports (organization_id, reading_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000006b2')$$);
select zz_check.denied($$insert into nomad_personal.trips (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'x')$$);
select zz_check.fails_with($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1')$$, '42501');
select zz_check.expect($$select count(*) from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a')$$, 0);
reset role;

-- ==== 6. 잠김·탈퇴·비활성 회귀 ====
-- 6.1 조직 A 구독 끊김(C 취급) → 리포트·여행 잠김(읽기·쓰기·직접 삭제 0), 풀이는 열림, 본인 전체 삭제는 RPC로
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'personal';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_personal.readings', 2);
select zz_check.expect('select count(*) from nomad_personal.trips', 0);
select zz_check.expect('select count(*) from nomad_personal.saved_reports', 0);
select zz_check.denied($$insert into nomad_personal.trips (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'x')$$);
select zz_check.expect($$with d as (delete from nomad_personal.saved_reports returning 1) select count(*) from d$$, 0);
select zz_check.expect($$with d as (delete from nomad_personal.trips returning 1) select count(*) from d$$, 0);
-- 풀이 2 · 리포트 2(경로 있는 것 1) · 생년월일 1 삭제, 반환은 pdf_path 목록
select zz_check.expect($$select count(*) from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a') p where p = '00000000-0000-0000-0000-00000000000a/personal/00000000-0000-0000-0000-0000000000a1/r1.pdf'$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select (select count(*) from nomad_personal.saved_reports where created_by = '00000000-0000-0000-0000-0000000000a1') + (select count(*) from nomad_personal.birth_profiles where user_id = '00000000-0000-0000-0000-0000000000a1')$$, 0);
select zz_check.expect($$select count(*) from nomad_personal.readings where created_by = '00000000-0000-0000-0000-0000000000a1'$$, 0);
select zz_check.expect($$select count(*) from nomad_personal.readings where created_by = '00000000-0000-0000-0000-0000000000a3'$$, 1);
select zz_check.expect($$select count(*) from nomad_personal.trips$$, 2);
-- 6.2 a3·a5 탈퇴 → 민감 행 0. owner가 a3 것을 열람 없이 삭제(감사 기록), a5는 탈퇴 후에도 본인 것 삭제
delete from nomad_core.memberships where organization_id = '00000000-0000-0000-0000-00000000000a'
   and user_id in ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a5');
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect('select count(*) from nomad_personal.readings', 0);
select zz_check.expect('select count(*) from nomad_personal.trips', 0);
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3')$$, 0);
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect($$select count(*) from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000a')$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_personal.readings where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_personal.birth_profiles where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000a' and action = 'personal.erase' and target_id = '00000000-0000-0000-0000-0000000000a3' and metadata = '{"result":"erased"}'::jsonb$$, 1);
-- 6.3 조직 B 비활성 → a2 0행·쓰기 거부, 비활성 조직 owner의 타인(탈퇴자) 삭제 거부, 본인 전체 삭제는 된다
insert into nomad_personal.readings (organization_id, created_by, kind) values
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a5', 'dream');
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000b';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_personal.readings', 0);
select zz_check.denied($$insert into nomad_personal.readings (organization_id, kind) values ('00000000-0000-0000-0000-00000000000b', 'dream')$$);
select zz_check.fails_with($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a5')$$, '42501');
select zz_check.expect($$select count(*) from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000b')$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_personal.readings where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 1);
select zz_check.expect($$select count(*) from nomad_personal.birth_profiles where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 0);
-- 6.4 서버(service_role): 대상 필수(22023), 비활성 조직의 탈퇴자 것도 삭제 + 감사
select zz_check.as_role('service_role');
select zz_check.fails_with($$select * from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000b')$$, '22023');
select zz_check.expect($$select count(*) from nomad_personal.erase_personal_data('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a5')$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_personal.readings where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000b' and action = 'personal.erase' and metadata = '{"result":"erased"}'::jsonb$$, 1);

-- ==== 7. 정적 검사 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_personal'$$, 5);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_personal' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_personal' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_personal' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE') and column_name in ('id', 'user_id', 'created_by', 'created_at', 'updated_at')$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_personal' and grantee = 'authenticated' and privilege_type = 'UPDATE' and column_name in ('organization_id', 'trip_id', 'reading_id')$$, 0);
-- readings 쓰기는 서버 전용: authenticated insert·update 권한·정책 0
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_personal' and table_name = 'readings' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE')$$, 0);
select zz_check.expect($$select count(*) from pg_policies where schemaname = 'nomad_personal' and tablename = 'readings' and cmd in ('INSERT', 'UPDATE')$$, 0);
-- 평문 생년월일·사주 입력 컬럼 없음, 암호문 컬럼은 authenticated 권한 없음(쓰기·복호화는 서버만)
select zz_check.expect($$select count(*) from information_schema.columns where table_schema = 'nomad_personal' and column_name in ('birth_date', 'birth_time', 'input_json')$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_personal' and grantee = 'authenticated' and column_name like '%ciphertext'$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'nomad_personal' and p.prosecdef and not coalesce(array_to_string(p.proconfig, ',') like '%search_path=""%', false)$$, 0);
