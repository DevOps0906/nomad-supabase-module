-- school org안 검사: 학교(조직) 2곳 교차 접근 거부 · 역할별(admin/teacher/student/무역할) 권한 · 한도 · 출석 규칙 · 함수 권한. 합성 데이터만, 마지막에 rollback.
-- 실행(저장소 루트에서; org 파일의 begin/commit을 빼고 한 트랜잭션으로 합친다):
--   { sed '/^-- @@APPLY/,$d' products/school/check_org.sql
--     sed '/^begin;$/d;/^commit;$/d' products/school/org/0001_school.sql
--     sed -n '/^-- @@APPLY/,$p' products/school/check_org.sql
--     sed '/^begin;$/d;/^commit;$/d' products/school/org/0002_ai.sql
--     echo 'rollback;'; } | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1
begin;
drop schema if exists nomad_school cascade;
drop schema if exists nomad_school_private cascade;

-- core 20261119000100 이 들어가기 전까지의 임시 정의(검사 트랜잭션 안에서만).
create or replace function nomad_core.touch_updated_at() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end $$;

-- ---- 검사 도우미 ----
create schema zz_check;
grant usage on schema zz_check to anon, authenticated;
create function zz_check.denied(q text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin execute q; ok := true; exception when others then null; end;
  if ok then raise exception 'NOT DENIED: %', q; end if;
end $$;
create function zz_check.fails_with(q text, msg text) returns void language plpgsql as $$
declare got text;
begin
  begin execute q; got := null; exception when others then got := sqlerrm; end;
  if got is null then raise exception 'NOT DENIED: %', q; end if;
  if got not like '%' || msg || '%' then raise exception 'wrong error for %: got [%], want [%]', q, got, msg; end if;
end $$;
create function zz_check.expect(q text, want bigint) returns void language plpgsql as $$
declare r bigint; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
grant execute on all functions in schema zz_check to anon, authenticated;

-- @@APPLY
-- ---- 합성 데이터 ----
-- 학교 A: a1 owner(admin) · a6 admin · a3 교사 · a4·a5 학생 · a7 (학생 후보, 코어 viewer) · a9 editor(학교 역할 없음)
-- 학교 B: a2 owner
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test'), ('00000000-0000-0000-0000-0000000000a6', 'u6@example.test'),
  ('00000000-0000-0000-0000-0000000000a7', 'u7@example.test'), ('00000000-0000-0000-0000-0000000000a9', 'u9@example.test');
insert into nomad_core.organizations (id, name) values
  ('00000000-0000-0000-0000-00000000000a', 'school A'), ('00000000-0000-0000-0000-00000000000b', 'school B');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a6', 'admin'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a9', 'editor'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
-- 검사용 임시 한도(제품 시드 아님, rollback됨): 학급 2 · 활성 학생 2 · 추이 31일
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('school', 'C', 'max_classes', 2), ('school', 'C', 'max_students', 2), ('school', 'C', 'attendance_trend_days', 31)
  on conflict (product_code, plan_code, limit_key) do update set limit_value = excluded.limit_value;

-- 서버: 작업공간 등록·기초 데이터
select nomad_school.register_workspace('00000000-0000-0000-0000-00000000000a', 'School A');
select nomad_school.register_workspace('00000000-0000-0000-0000-00000000000b', 'School B');
insert into nomad_school.classes (id, organization_id, name, grade) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', '1-1', 1),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-00000000000b', '1-1', 1);
insert into nomad_school.subjects (id, organization_id, class_id, name) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1', 'Math'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c2', 'Math');
select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'teacher', 'T3');
select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'student', 'S4', '00000000-0000-0000-0000-0000000000c1', '2026-01');
select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'student', 'S5', '00000000-0000-0000-0000-0000000000c1', '2026-02');
select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', (now() at time zone 'Asia/Seoul')::date, 'present');
select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a5', (now() at time zone 'Asia/Seoul')::date, 'late');
-- 서버도 한도를 지킨다(학생 3번째 거부)
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'student', 'S7')$$, 'SCHOOL_STUDENT_LIMIT_REACHED');

-- ==== 1. 학교 B(a2) 시점: 학교 A 데이터 전부 안 보이고 쓰기 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.classes', 1);
select zz_check.expect('select count(*) from nomad_school.workspaces', 1);
select zz_check.expect('select count(*) from nomad_school.subjects where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_school.members where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_school.attendance where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.denied($$insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000a', 'x', 1)$$);
select zz_check.denied($$insert into nomad_school.subjects (organization_id, class_id, name) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1', 'x')$$);
-- 학교 B 소속으로 위장해 학교 A 학급 참조(복합 FK 거부)
select zz_check.denied($$insert into nomad_school.subjects (organization_id, class_id, name) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c1', 'x')$$);
-- 구성원·출석 직접 쓰기는 grant 없음
select zz_check.denied($$insert into nomad_school.members (organization_id, user_id, school_role) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'teacher')$$);
select zz_check.denied($$insert into nomad_school.attendance (organization_id, class_id, subject_id, student_id, attend_date, status) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', current_date, 'present')$$);
-- RPC 교차 거부
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', current_date, 'absent')$$, 'admin/teacher only');
select zz_check.fails_with($$select nomad_school.dashboard_stats('00000000-0000-0000-0000-00000000000a')$$, 'admin/teacher only');
select zz_check.fails_with($$select * from nomad_school.attendance_trend('00000000-0000-0000-0000-00000000000a', (now() at time zone 'Asia/Seoul')::date - 1, (now() at time zone 'Asia/Seoul')::date)$$, 'admin/teacher only');
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'teacher', 'x')$$, 'admin only');
select zz_check.fails_with($$select nomad_school.update_workspace_settings('00000000-0000-0000-0000-00000000000a', 'hacked', null, null)$$, 'admin only');
select zz_check.fails_with($$select nomad_school.student_summary('00000000-0000-0000-0000-00000000000a')$$, 'no access');
-- 학교 B 학급에 학교 A 학생 출석 위장 거부
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a4', current_date, 'absent')$$, 'not an active member');
-- 수정·삭제는 0행
update nomad_school.classes set name = 'hacked' where id = '00000000-0000-0000-0000-0000000000c1';
delete from nomad_school.subjects where organization_id = '00000000-0000-0000-0000-00000000000a';
reset role;
select zz_check.expect($$select count(*) from nomad_school.classes where name = 'hacked'$$, 0);
select zz_check.expect($$select count(*) from nomad_school.subjects where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 1);

-- ==== 2. 학교 A admin(a1 owner) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.classes', 1);
select zz_check.expect('select count(*) from nomad_school.members', 3);
select zz_check.expect('select count(*) from nomad_school.attendance', 2);
select zz_check.expect($$select count(*) from nomad_school.classes where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 0);
select zz_check.denied($$insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000b', 'x', 1)$$);
-- 학급 한도 2: 두 번째 가능, 세 번째 거부
insert into nomad_school.classes (id, organization_id, name, grade) values ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-00000000000a', '1-2', 1);
select zz_check.fails_with($$insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000a', '1-3', 1)$$, 'SCHOOL_CLASS_LIMIT_REACHED');
-- 소프트 삭제 후 같은 이름 재사용(부분 유니크) + 한도 회복
update nomad_school.classes set deleted_at = now() where id = '00000000-0000-0000-0000-0000000000c3';
insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000a', '1-2', 1);
-- 구성원 등록 규칙
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'student', 'S7')$$, 'SCHOOL_STUDENT_LIMIT_REACHED');
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'teacher', 'x')$$, 'accept the nomad_core invitation first');
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a6', 'teacher', 'x')$$, 'target is an admin');
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'teacher', 'x')$$, 'cannot register yourself');
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'teacher', 'x', '00000000-0000-0000-0000-0000000000c1')$$, 'teacher has no class_id');
-- 교사로는 가능(학생 한도 대상 아님), 다른 학교 학급 지정 거부
select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'teacher', 'T7');
select zz_check.fails_with($$select nomad_school.assign_class('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000c2')$$, 'class not in organization');
select zz_check.fails_with($$select nomad_school.assign_class('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000c1')$$, 'only students have a class');
select zz_check.fails_with($$select nomad_school.set_member_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'teacher')$$, 'cannot change your own role');
select zz_check.fails_with($$select nomad_school.set_member_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a6', 'teacher')$$, 'member not found');
select zz_check.fails_with($$select nomad_school.set_member_status('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'suspended')$$, 'cannot change your own');
-- 통계·추이
select zz_check.expect($$select (nomad_school.dashboard_stats('00000000-0000-0000-0000-00000000000a') ->> 'records')::bigint$$, 2);
select zz_check.expect($$select (nomad_school.dashboard_stats('00000000-0000-0000-0000-00000000000a') ->> 'late')::bigint$$, 1);
select zz_check.expect($$select count(*) from nomad_school.attendance_trend('00000000-0000-0000-0000-00000000000a', (now() at time zone 'Asia/Seoul')::date - 30, (now() at time zone 'Asia/Seoul')::date)$$, 1);
select zz_check.fails_with($$select * from nomad_school.attendance_trend('00000000-0000-0000-0000-00000000000a', (now() at time zone 'Asia/Seoul')::date - 32, (now() at time zone 'Asia/Seoul')::date)$$, 'invalid range');
-- 관리자는 날짜 제한 없이 과거 출석 가능, 미래는 불가
select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', current_date - 60, 'absent');
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', current_date + 2, 'absent')$$, 'future date');
-- 직접 쓰기 grant 없음(관리자도 RPC로만)
select zz_check.denied($$update nomad_school.members set school_role = 'teacher' where user_id = '00000000-0000-0000-0000-0000000000a4'$$);
select zz_check.denied($$insert into nomad_school.attendance (organization_id, class_id, subject_id, student_id, attend_date, status) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', current_date - 5, 'present')$$);
-- 역할 변경: 교사로 바꾸면 학급·학번 비움
select zz_check.expect($$select count(*) from nomad_school.members where school_role = 'teacher' and class_id is null and student_no is null$$, 2);
select nomad_school.set_member_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'teacher');
select zz_check.expect($$select count(*) from nomad_school.members where user_id = '00000000-0000-0000-0000-0000000000a5' and class_id is null and student_no is null$$, 1);
select nomad_school.set_member_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'student');
select nomad_school.assign_class('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000c1', '2026-02');
reset role;

-- ==== 3. 교사(a3, 코어 viewer + 학교 teacher) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.classes where deleted_at is null', 2);
select zz_check.expect('select count(*) from nomad_school.members', 4);
select zz_check.expect('select count(*) from nomad_school.attendance', 3);
select zz_check.denied($$insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000a', 't', 1)$$);
select zz_check.denied($$insert into nomad_school.subjects (organization_id, class_id, name) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000c1', 't')$$);
select zz_check.fails_with($$select nomad_school.invite_school_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'student', 'x')$$, 'admin only');
select zz_check.fails_with($$select nomad_school.set_member_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'teacher')$$, 'admin only');
select zz_check.fails_with($$select nomad_school.assign_class('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000c1')$$, 'admin only');
select zz_check.fails_with($$select nomad_school.update_workspace_settings('00000000-0000-0000-0000-00000000000a', 'x', null, null)$$, 'admin only');
-- 출석: 오늘 가능, 7일 초과 과거·미래 거부, 학급 밖 학생 거부
select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', (now() at time zone 'Asia/Seoul')::date, 'early_leave', 'note');
select zz_check.expect($$select count(*) from nomad_school.attendance where status = 'early_leave'$$, 1);
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', (now() at time zone 'Asia/Seoul')::date - 8, 'absent')$$, 'requires admin');
select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', (now() at time zone 'Asia/Seoul')::date - 7, 'absent');
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', (now() at time zone 'Asia/Seoul')::date + 1, 'absent')$$, 'future date');
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a3', current_date, 'present')$$, 'not an active member');
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', current_date, 'sick')$$, 'invalid status');
select zz_check.expect($$select nomad_school.mark_attendance_bulk('00000000-0000-0000-0000-0000000000d1', (now() at time zone 'Asia/Seoul')::date - 1, '[{"student_id":"00000000-0000-0000-0000-0000000000a4","status":"present"},{"student_id":"00000000-0000-0000-0000-0000000000a5","status":"late"}]'::jsonb)::bigint$$, 2);
select zz_check.denied($$update nomad_school.attendance set status = 'present'$$);
select zz_check.denied($$delete from nomad_school.attendance$$);
select zz_check.expect($$select (nomad_school.dashboard_stats('00000000-0000-0000-0000-00000000000a') ->> 'records')::bigint$$, 2);
reset role;

-- ==== 4. 학생(a4): 본인 행·본인 출석만 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.members', 1);
select zz_check.expect($$select count(*) from nomad_school.members where user_id <> '00000000-0000-0000-0000-0000000000a4'$$, 0);
select zz_check.expect('select count(*) from nomad_school.attendance', 4);
select zz_check.expect($$select count(*) from nomad_school.attendance where student_id <> '00000000-0000-0000-0000-0000000000a4'$$, 0);
select zz_check.expect('select count(*) from nomad_school.classes where deleted_at is null', 2);
select zz_check.denied($$insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000a', 's', 1)$$);
select zz_check.fails_with($$select nomad_school.mark_attendance('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4', current_date, 'present')$$, 'admin/teacher only');
select zz_check.fails_with($$select nomad_school.dashboard_stats('00000000-0000-0000-0000-00000000000a')$$, 'admin/teacher only');
select zz_check.fails_with($$select nomad_school.set_member_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'teacher')$$, 'admin only');
select zz_check.denied($$update nomad_school.members set school_role = 'teacher', class_id = null where user_id = '00000000-0000-0000-0000-0000000000a4'$$);
-- 이번 달(KST) 본인 출석 수와 같아야 한다(날짜에 따라 -7·-1일이 지난달일 수 있어 고정값 대신 비교)
select zz_check.expect($$select (nomad_school.student_summary('00000000-0000-0000-0000-00000000000a') ->> 'records')::bigint
  - (select count(*) from nomad_school.attendance where date_trunc('month', attend_date) = date_trunc('month', (now() at time zone 'Asia/Seoul')::date))$$, 0);
select zz_check.expect($$select jsonb_array_length(nomad_school.student_summary('00000000-0000-0000-0000-00000000000a') -> 'today_subjects')::bigint$$, 1);
reset role;

-- ==== 5. 학교 역할 없는 editor(a9) · 정지 학생(a5) · 중지된 작업공간 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a9","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.classes', 0);
select zz_check.expect('select count(*) from nomad_school.workspaces', 0);
select zz_check.expect('select count(*) from nomad_school.attendance', 0);
select zz_check.denied($$insert into nomad_school.classes (organization_id, name, grade) values ('00000000-0000-0000-0000-00000000000a', 'e', 1)$$);
reset role;
select nomad_school.set_member_status('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'suspended');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.classes', 0);
select zz_check.expect('select count(*) from nomad_school.attendance', 0);
reset role;
update nomad_school.workspaces set status = 'suspended' where organization_id = '00000000-0000-0000-0000-00000000000a';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_school.classes', 0);
reset role;
update nomad_school.workspaces set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a';

-- ==== 6. anon · 함수 권한 · 동기화 컬럼 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_school.classes');
select zz_check.denied('select count(*) from nomad_school.members');
select zz_check.denied($$select nomad_school.has_access('00000000-0000-0000-0000-00000000000a')$$);
reset role;
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_school', 'nomad_school_private') and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('public', p.oid, 'execute'))$$, 0);
-- register_workspace 는 서버 전용
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.denied($$select nomad_school.register_workspace('00000000-0000-0000-0000-00000000000a', 'x')$$);
reset role;
select zz_check.expect($$select count(*) from pg_trigger where tgname in ('classes_touch','subjects_touch','members_touch','attendance_touch','workspaces_touch') and not tgisinternal$$, 5);
insert into nomad_school.classes (organization_id, name, grade, updated_at) values ('00000000-0000-0000-0000-00000000000b', 'sync', 2, '2000-01-01');
update nomad_school.classes set grade = 3 where name = 'sync';
select zz_check.expect($$select count(*) from nomad_school.classes where name = 'sync' and updated_at > '2000-01-02'$$, 1);

-- ==== 7. 0002_ai.sql 은 core AI 표가 없으면 건너뛴다(아래에 이어 붙여 적용) ====
