-- classroom org안 검사: 다른 조직 접근 0 · anon 표·함수 0 · 역할별 읽기(학생 개인정보 최소 노출)·쓰기 범위 · 강사 평가 시작 규칙
--   · 복합 FK 조직·과정 일치 · 자료 경로 CHECK · Storage 정책 · 구독 끊김(쓰기 잠금·읽기 유지) · 조직 비활성. 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/classroom/run_check.sh

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
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u6 admin, u3 editor=강사(A1 배정), u5 viewer=참관(A1 배정), u7 editor 미배정, 플랜 A 구독)
--      조직 B(u2 owner, 구독 없음 = C), u4 = 어느 조직에도 없음 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test'), ('00000000-0000-0000-0000-0000000000a6', 'u6@example.test'),
  ('00000000-0000-0000-0000-0000000000a7', 'u7@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a6', 'admin'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a7', 'editor'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'classroom', 'A', 'active');

-- ==== 0. 서버(service_role): 과정 A1·A2·B1 과 하위 데이터 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_classroom.courses (id, organization_id, subject, name, first_day, day_count, access_start, access_end) values
  ('00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-00000000000a', 'fusion', 'A1', '2026-12-01', 3, '2026-11-01', '2027-01-01'),
  ('00000000-0000-0000-0000-000000000ca2', '00000000-0000-0000-0000-00000000000a', 'rhino', 'A2', '2026-12-01', 3, '2026-11-01', '2027-01-01'),
  ('00000000-0000-0000-0000-000000000cb1', '00000000-0000-0000-0000-00000000000b', 'vibe', 'B1', '2026-12-01', 3, '2026-11-01', '2027-01-01');
insert into nomad_classroom.course_instructors (organization_id, course_id, user_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-0000000000a5');
-- 다른 조직 멤버 배정 거부(memberships 복합 FK)
select zz_check.fails_with($$insert into nomad_classroom.course_instructors (organization_id, course_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-0000000000a2')$$, '23503');
-- 과정과 조직이 다르면 거부(courses 복합 FK)
select zz_check.fails_with($$insert into nomad_classroom.course_days (organization_id, course_id, no, title) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000ca1', 9, 'x')$$, '23503');
insert into nomad_classroom.course_days (id, organization_id, course_id, no, title) values
  ('00000000-0000-0000-0000-000000000da1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 1, '1일차'),
  ('00000000-0000-0000-0000-000000000da2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca2', 1, '1일차'),
  ('00000000-0000-0000-0000-000000000db1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', 1, '1일차');
insert into nomad_classroom.quizzes (id, organization_id, course_id, title, kind) values
  ('00000000-0000-0000-0000-000000000fa1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '퀴즈 A1', 'manual'),
  ('00000000-0000-0000-0000-000000000fb1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', '퀴즈 B1', 'generated');
insert into nomad_classroom.quiz_questions (organization_id, course_id, quiz_id, prompt, options, answer) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000fa1', '정면도?', '[{"id":"a","label":"A"}]', 'a');
-- 같은 과정의 일차·퀴즈만(복합 FK)
select zz_check.fails_with($$insert into nomad_classroom.materials (organization_id, course_id, day_id, audience, type, label) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000da2', 'student', 'link', 'x')$$, '23503');
select zz_check.fails_with($$insert into nomad_classroom.materials (organization_id, course_id, audience, type, label, quiz_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca2', 'student', 'quiz', 'x', '00000000-0000-0000-0000-000000000fa1')$$, '23503');
-- 자료 경로: 자기 조직·과정 접두만(CHECK)
select zz_check.fails_with($$insert into nomad_classroom.materials (organization_id, course_id, audience, type, label, storage_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'student', 'file', 'x', '00000000-0000-0000-0000-00000000000b/classroom/00000000-0000-0000-0000-000000000ca1/00000000-0000-0000-0000-000000000001.pdf')$$, '23514');
select zz_check.fails_with($$insert into nomad_classroom.materials (organization_id, course_id, audience, type, label, storage_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'student', 'file', 'x', '00000000-0000-0000-0000-000000000ca1/../x.pdf')$$, '23514');
insert into nomad_classroom.materials (organization_id, course_id, day_id, audience, type, label, storage_path) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000da1', 'student', 'file', '도면 1',
   '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca1/00000000-0000-0000-0000-000000000001.pdf');
-- 참관 차단 대상: 교사용 파일 자료 · 연습풀이(solution) 자료
insert into nomad_classroom.materials (organization_id, course_id, audience, type, label, storage_path, bundle) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'teacher', 'file', '교사용',
   '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca1/00000000-0000-0000-0000-000000000007.pdf', null),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'both', 'link', '풀이', null, 'solution');
insert into nomad_classroom.student_codes (code, organization_id, course_id, label) values
  ('AAAA-2222', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '학생 1'),
  ('AAAA-3333', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca2', '학생 2'),
  ('BBBB-2222', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', '학생 B');
insert into nomad_classroom.quiz_attempts (organization_id, course_id, quiz_id, code, level, mode, phase, score, answers) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000fa1', 'AAAA-2222', 1, 'main', 'pre', 80, '[]');
-- 다른 과정 코드로 응시 기록 거부(복합 FK)
select zz_check.fails_with($$insert into nomad_classroom.quiz_attempts (organization_id, course_id, quiz_id, code, level, mode, phase, score, answers) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000fa1', 'AAAA-3333', 1, 'main', 'pre', 80, '[]')$$, '23503');
-- 조직 B(C, 구독 없음): 응시 기록 잠김(pre_post_assessment)
select zz_check.fails_with($$insert into nomad_classroom.quiz_attempts (organization_id, course_id, quiz_id, code, level, mode, phase, score, answers) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', '00000000-0000-0000-0000-000000000fb1', 'BBBB-2222', 1, 'main', 'pre', 80, '[]')$$, 'CL001');
insert into nomad_classroom.surveys (id, organization_id, course_id, audience) values
  ('00000000-0000-0000-0000-000000000ea1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'student'),
  ('00000000-0000-0000-0000-000000000ea2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'teacher');
insert into nomad_classroom.survey_responses (organization_id, course_id, survey_id, code, profile_id, answers) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea1', 'AAAA-2222', null, '{}'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea2', null, '00000000-0000-0000-0000-0000000000a1', '{}');
reset role;
insert into storage.objects (bucket_id, name) values
  ('classroom-materials', '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca1/00000000-0000-0000-0000-000000000001.pdf'),
  ('classroom-materials', '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca1/00000000-0000-0000-0000-000000000007.pdf'),
  ('classroom-materials', '00000000-0000-0000-0000-00000000000b/classroom/00000000-0000-0000-0000-000000000cb1/00000000-0000-0000-0000-000000000002.pdf');
select zz_check.expect($$select count(*) from storage.buckets where id = 'classroom-materials' and not public$$, 1);

-- ==== 1. anon: 스키마·표·함수 전부 거부 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_classroom.courses');
select zz_check.denied('select count(*) from nomad_classroom.student_codes');
select zz_check.denied('select count(*) from nomad_classroom.quiz_questions');
select zz_check.denied($$select nomad_classroom.course_role('00000000-0000-0000-0000-000000000ca1')$$);
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'classroom-materials'$$, 0);
reset role;
-- anon 에게 남은 표·스키마 권한 0
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_classroom' and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from pg_namespace where nspname = 'nomad_classroom' and has_schema_privilege('anon', oid, 'usage')$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'nomad_classroom' and has_function_privilege('anon', p.oid, 'execute')$$, 0);
-- 모든 표 RLS
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_classroom' and c.relkind = 'r' and not c.relrowsecurity$$, 0);

-- ==== 2. 조직 A owner(u1, manager): 전체 읽기·쓰기 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 2);
select zz_check.expect('select count(*) from nomad_classroom.student_codes', 2);
select zz_check.expect('select count(*) from nomad_classroom.quiz_attempts', 1);
select zz_check.expect('select count(*) from nomad_classroom.survey_responses', 2);
select zz_check.expect('select count(*) from nomad_classroom.quiz_questions', 1);
insert into nomad_classroom.course_days (organization_id, course_id, no, title) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 2, '2일차');
insert into nomad_classroom.quizzes (organization_id, course_id, title, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '퀴즈 A1-2', 'generated');
-- 학생 코드는 RPC 가 난수 발급(사용자가 code 를 지정하면 남의 조직 코드 존재 오라클 → 42501)
select zz_check.fails_with($$insert into nomad_classroom.student_codes (code, organization_id, course_id, label) values ('AAAA-4444', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'x')$$, '42501');
select zz_check.fails_with($$insert into nomad_classroom.student_codes (code, organization_id, course_id, label) values ('BBBB-2222', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'x')$$, '42501');
select zz_check.expect($$select count(*) from nomad_classroom.issue_student_codes('00000000-0000-0000-0000-000000000ca1', array['학생 3'])$$, 1);
select zz_check.expect($$select count(*) from nomad_classroom.student_codes where label = '학생 3' and code ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'$$, 1);
update nomad_classroom.student_codes set revoked_at = now() where label = '학생 3';
-- 입장 시각·id 는 사용자 grant 없음
select zz_check.denied($$update nomad_classroom.student_codes set first_entered_at = now() where label = '학생 3'$$);
select zz_check.denied($$insert into nomad_classroom.course_days (id, organization_id, course_id, no, title) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 3, 'x')$$);
select zz_check.denied($$delete from nomad_classroom.courses where id = '00000000-0000-0000-0000-000000000ca2'$$);
select zz_check.denied($$delete from nomad_classroom.student_codes where label = '학생 3'$$);
-- 다른 조직 과정·조직에 쓰기 거부
select zz_check.fails_with($$insert into nomad_classroom.courses (organization_id, subject, name, first_day, day_count, access_start, access_end) values ('00000000-0000-0000-0000-00000000000b', 'vibe', 'x', '2026-12-01', 1, '2026-11-01', '2027-01-01')$$, '42501');
select zz_check.fails_with($$insert into nomad_classroom.course_days (organization_id, course_id, no, title) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', 9, 'x')$$, '42501');
select zz_check.expect($$with u as (update nomad_classroom.courses set name = 'x' where id = '00000000-0000-0000-0000-000000000cb1' returning 1) select count(*) from u$$, 0);
-- Storage: 자기 과정 경로 올리기 가능, 다른 조직 과정·형식 밖 경로 거부
insert into storage.objects (bucket_id, name) values ('classroom-materials', '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca2/00000000-0000-0000-0000-000000000003.pdf');
select zz_check.denied($$insert into storage.objects (bucket_id, name) values ('classroom-materials', '00000000-0000-0000-0000-00000000000b/classroom/00000000-0000-0000-0000-000000000cb1/00000000-0000-0000-0000-000000000004.pdf')$$);
select zz_check.denied($$insert into storage.objects (bucket_id, name) values ('classroom-materials', '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000cb1/00000000-0000-0000-0000-000000000005.pdf')$$);
select zz_check.denied($$insert into storage.objects (bucket_id, name) values ('classroom-materials', '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca1/evil.svg')$$);
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'classroom-materials'$$, 3);
reset role;

-- ==== 3. 조직 A admin(u6): 과정 만들기·강사 배정 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a6","role":"authenticated"}', true);
select zz_check.expect($$with i as (insert into nomad_classroom.courses (organization_id, subject, name, first_day, day_count, access_start, access_end)
  values ('00000000-0000-0000-0000-00000000000a', 'vibe', 'A3', '2026-12-01', 1, '2026-11-01', '2027-01-01') returning id) select count(*) from i$$, 1);
insert into nomad_classroom.course_instructors (organization_id, course_id, user_id)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca2', '00000000-0000-0000-0000-0000000000a7');
delete from nomad_classroom.course_instructors where course_id = '00000000-0000-0000-0000-000000000ca2' and user_id = '00000000-0000-0000-0000-0000000000a7';
select zz_check.expect('select count(*) from nomad_classroom.courses', 3);
reset role;

-- ==== 4. 강사(u3, A1 배정 editor): 배정 과정만, 학생 정보 읽기, 쓰기는 평가 시작·본인 설문만 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 1);
select zz_check.expect('select count(*) from nomad_classroom.student_codes', 2);   -- A1 의 2개(A2 코드 안 보임)
select zz_check.expect('select count(*) from nomad_classroom.quiz_attempts', 1);
select zz_check.expect('select count(*) from nomad_classroom.quiz_questions', 1);
select zz_check.expect('select count(*) from nomad_classroom.survey_responses', 1);   -- 학생 응답만, 관리자(u1) 응답 안 보임
select zz_check.expect('select count(*) from nomad_classroom.course_instructors', 1);   -- 본인 배정만
select zz_check.fails_with($$insert into nomad_classroom.course_days (organization_id, course_id, no, title) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 5, 'x')$$, '42501');
select zz_check.fails_with($$insert into nomad_classroom.quizzes (organization_id, course_id, title, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'x', 'manual')$$, '42501');
select zz_check.fails_with($$insert into nomad_classroom.student_codes (code, organization_id, course_id) values ('CCCC-2222', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1')$$, '42501');
select zz_check.fails_with($$select nomad_classroom.issue_student_codes('00000000-0000-0000-0000-000000000ca1', array['x'])$$, '42501');
select zz_check.expect('select count(*) from nomad_classroom.materials', 3);   -- 강사는 교사용·풀이 포함
select zz_check.expect($$with u as (update nomad_classroom.student_codes set label = 'x' where code = 'AAAA-2222' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (update nomad_classroom.materials set label = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$update nomad_classroom.courses set name = 'x' where id = '00000000-0000-0000-0000-000000000ca1'$$, '42501');
select zz_check.fails_with($$update nomad_classroom.courses set post_eval_from = now() where id = '00000000-0000-0000-0000-000000000ca1'$$, 'pre evaluation must start');
update nomad_classroom.courses set pre_eval_from = now() where id = '00000000-0000-0000-0000-000000000ca1';
select zz_check.fails_with($$update nomad_classroom.courses set pre_eval_from = null where id = '00000000-0000-0000-0000-000000000ca1'$$, 'cannot be changed once set');
select zz_check.expect($$with u as (update nomad_classroom.courses set pre_eval_from = now() where id = '00000000-0000-0000-0000-000000000ca2' returning 1) select count(*) from u$$, 0);
-- 강사 설문: teacher 설문에 본인 이름으로 1회만
insert into nomad_classroom.survey_responses (organization_id, course_id, survey_id, profile_id, answers)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea2', '00000000-0000-0000-0000-0000000000a3', '{}');
select zz_check.fails_with($$insert into nomad_classroom.survey_responses (organization_id, course_id, survey_id, profile_id, answers) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea2', '00000000-0000-0000-0000-0000000000a3', '{}')$$, '23505');
select zz_check.fails_with($$insert into nomad_classroom.survey_responses (organization_id, course_id, survey_id, profile_id, answers) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea1', '00000000-0000-0000-0000-0000000000a3', '{}')$$, '42501');
select zz_check.fails_with($$insert into nomad_classroom.survey_responses (organization_id, course_id, survey_id, profile_id, answers) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea2', '00000000-0000-0000-0000-0000000000a5', '{}')$$, '42501');
select zz_check.expect('select count(*) from nomad_classroom.survey_responses', 2);
-- Storage: 배정 과정 파일 읽기(교사용 포함), 올리기 거부
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'classroom-materials'$$, 2);
select zz_check.denied($$insert into storage.objects (bucket_id, name) values ('classroom-materials', '00000000-0000-0000-0000-00000000000a/classroom/00000000-0000-0000-0000-000000000ca1/00000000-0000-0000-0000-000000000006.pdf')$$);
reset role;

-- ==== 5. 참관(u5, A1 배정 viewer): 과정 구조만, 학생 개인정보·정답 0, 쓰기 0 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 1);
select zz_check.expect('select count(*) from nomad_classroom.course_days', 2);
select zz_check.expect('select count(*) from nomad_classroom.materials', 1);   -- 교사용·풀이 자료 차단
select zz_check.expect('select count(*) from nomad_classroom.quizzes', 2);
select zz_check.expect('select count(*) from nomad_classroom.student_codes', 0);
select zz_check.expect('select count(*) from nomad_classroom.quiz_attempts', 0);
select zz_check.expect('select count(*) from nomad_classroom.quiz_questions', 0);
select zz_check.expect('select count(*) from nomad_classroom.survey_responses', 0);
select zz_check.expect($$with u as (update nomad_classroom.courses set post_eval_from = now() returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$insert into nomad_classroom.survey_responses (organization_id, course_id, survey_id, profile_id, answers) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-000000000ea2', '00000000-0000-0000-0000-0000000000a5', '{}')$$, '42501');
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'classroom-materials'$$, 1);
reset role;

-- ==== 6. 미배정 editor(u7)·무소속(u4): 0 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 0);
select zz_check.expect('select count(*) from nomad_classroom.materials', 0);
select zz_check.expect('select count(*) from nomad_classroom.student_codes', 0);
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'classroom-materials'$$, 0);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 0);
select zz_check.expect('select count(*) from nomad_classroom.survey_responses', 0);
reset role;

-- ==== 7. 조직 B owner(u2, C 무료): A 데이터 0, A 쓰기 거부, 퀴즈 쓰기 잠김 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 1);
select zz_check.expect($$select count(*) from nomad_classroom.courses where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_classroom.student_codes where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_classroom.quiz_attempts where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_classroom.survey_responses where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_classroom.course_instructors$$, 0);
select zz_check.fails_with($$insert into nomad_classroom.materials (organization_id, course_id, audience, type, label) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'student', 'link', 'x')$$, '42501');
select zz_check.fails_with($$insert into nomad_classroom.course_instructors (organization_id, course_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', '00000000-0000-0000-0000-0000000000a2')$$, '42501');
select zz_check.expect($$with u as (update nomad_classroom.student_codes set label = 'x' where code = 'AAAA-2222' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'classroom-materials'$$, 1);   -- B 파일만
select zz_check.expect($$select (nomad_classroom.course_role('00000000-0000-0000-0000-000000000ca1') is null)::int$$, 1);
select zz_check.expect($$select nomad_classroom.is_teacher_survey('00000000-0000-0000-0000-000000000ea2', '00000000-0000-0000-0000-000000000ca1')::int$$, 0);
select zz_check.fails_with($$select nomad_classroom.issue_student_codes('00000000-0000-0000-0000-000000000ca1', array['x'])$$, '42501 not allowed');
select zz_check.fails_with($$select nomad_classroom.issue_student_codes(gen_random_uuid(), array['x'])$$, '42501 not allowed');   -- 없는 과정과 같은 오류
-- C: course_core 쓰기는 되고 퀴즈·평가 시작은 잠김
insert into nomad_classroom.course_days (organization_id, course_id, no, title) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', 2, '2일차');
select zz_check.fails_with($$insert into nomad_classroom.quizzes (organization_id, course_id, title, kind) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000cb1', 'x', 'manual')$$, '42501');
select zz_check.fails_with($$update nomad_classroom.courses set pre_eval_from = now() where id = '00000000-0000-0000-0000-000000000cb1'$$, 'CL001');
reset role;

-- ==== 8. 구독 끊김(A inactive → C): 퀴즈 쓰기·평가 시작·응시 기록 잠김, 읽기 유지 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'classroom';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.quizzes', 2);
select zz_check.expect('select count(*) from nomad_classroom.quiz_questions', 1);
select zz_check.expect('select count(*) from nomad_classroom.quiz_attempts', 1);
select zz_check.expect('select count(*) from nomad_classroom.student_codes', 3);
select zz_check.fails_with($$insert into nomad_classroom.quizzes (organization_id, course_id, title, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 'x', 'manual')$$, '42501');
select zz_check.expect($$with u as (update nomad_classroom.quizzes set title = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (update nomad_classroom.quiz_questions set prompt = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (delete from nomad_classroom.quiz_questions returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$update nomad_classroom.courses set post_eval_from = now() where id = '00000000-0000-0000-0000-000000000ca1'$$, 'CL001');
insert into nomad_classroom.course_days (organization_id, course_id, no, title) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000ca1', 3, '3일차');   -- C 기능은 유지
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$update nomad_classroom.courses set post_eval_from = now() where id = '00000000-0000-0000-0000-000000000ca1'$$, 'CL001');
select zz_check.expect('select count(*) from nomad_classroom.quiz_attempts', 1);
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$update nomad_classroom.quiz_attempts set score = 90 where code = 'AAAA-2222'$$, 'CL001');
reset role;

-- ==== 9. 조직 비활성: 멤버도 0 ====
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_classroom.courses', 0);
select zz_check.expect('select count(*) from nomad_classroom.student_codes', 0);
reset role;
