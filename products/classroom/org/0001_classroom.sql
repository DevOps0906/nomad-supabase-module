-- Classroom 이식 · 조직형(org안). 원본: D:\WorkSpace\DEV\nomad-classroom\supabase\migrations 7개(스키마 classroom, 표 12개, 버킷 course-materials).
-- 0004~0007(ALTER·create or replace)은 최종 모양으로 합쳤다. 청사진 supabase/migrations/*_classroom.sql 은 참고만(같은 스키마 이름이라 함께 설치하지 않는다).
-- classroom.organizations → nomad_core.organizations, classroom.profiles(admin·instructor) → nomad_core.memberships(owner·admin / editor) + nomad_core.profiles,
-- organizations.plan → nomad_core.subscriptions(A/B/C) + 기능 course_core·quiz_bank·pre_post_assessment. 대응표: products/classroom/existing.md
-- 역할(과정 단위, course_role): manager = owner·admin(조직 전체 과정) · instructor = 배정된 editor(원본 강사) · observer = 배정된 viewer(참관, 이식 추가).
--   학생 개인정보(student_codes·quiz_attempts·survey_responses)와 정답(quiz_questions)은 manager·instructor 만. observer·미배정 멤버·다른 조직·anon 은 0행.
-- 수강생(코드 입장)은 계정이 없다: 원본처럼 학생 요청은 서버(service_role)만 처리한다. anon 은 스키마 usage 도 없다.
-- 되돌림: drop schema nomad_classroom cascade; delete from storage.buckets where id = 'classroom-materials';
--   (products·plans·features·plan_features 'classroom' 행은 청사진과 같은 값이라 남겨도 무해)
-- SQLSTATE: 42501 권한·강사 수정 범위 · CL001 플랜 기능 잠김(구독 끊김 = C)
begin;

create schema nomad_classroom;
revoke all on schema nomad_classroom from public, anon, authenticated;
grant usage on schema nomad_classroom to authenticated, service_role;
alter default privileges in schema nomad_classroom revoke execute on functions from public;
comment on schema nomad_classroom is 'Classroom: 교육기관 과정·일차·자료·학생 코드·퀴즈(3면도)·설문';

insert into nomad_core.products (code, name) values ('classroom', 'Classroom') on conflict (code) do nothing;
-- 원본 plan 'basic'(단일) → A. 구독이 끊기면(없음·inactive·만료) C = course_core 만: 퀴즈 쓰기·평가 시작·응시 기록이 잠기고 읽기는 유지.
insert into nomad_core.plans (product_code, code, name) values ('classroom', 'A', '비즈니스'), ('classroom', 'B', '프로'), ('classroom', 'C', '무료')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('classroom', 'course_core', '강좌·회차·자료·수강 등록'),
  ('classroom', 'quiz_bank', '퀴즈 문항'),
  ('classroom', 'pre_post_assessment', '사전·사후 평가')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('classroom', 'A', 'course_core'), ('classroom', 'B', 'course_core'), ('classroom', 'C', 'course_core'),
  ('classroom', 'A', 'quiz_bank'), ('classroom', 'B', 'quiz_bank'),
  ('classroom', 'A', 'pre_post_assessment')
on conflict do nothing;

-- =====================================================================
-- 1. 표 (원본 12개 중 organizations·profiles 는 core 로 대체, 10개)
--    모든 하위 표는 organization_id + course_id 를 갖고 (course_id, organization_id) 복합 FK 로 조직 일치를 강제한다.
-- =====================================================================
create table nomad_classroom.courses (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  subject         text not null check (subject in ('fusion', 'rhino', 'vibe')),
  name            text not null,
  host            text,
  place           text,
  first_day       date not null,
  day_count       int not null check (day_count between 1 and 31),
  day_open_time   time not null default '09:00',
  access_start    timestamptz not null,
  access_end      timestamptz not null,
  preview_until   timestamptz,
  pre_eval_from   timestamptz,
  post_eval_from  timestamptz,
  programs        text[] not null default '{}',
  overview        jsonb check (
                    overview is null
                    or (jsonb_typeof(overview) = 'object'
                        and (not (overview ? 'summary') or jsonb_typeof(overview -> 'summary') = 'array'))),
  created_at      timestamptz not null default now(),
  check (access_end > access_start),
  unique (id, organization_id)
);
create index courses_org_idx on nomad_classroom.courses (organization_id, first_day desc);
comment on table nomad_classroom.courses is '과정 설정. owner·admin 쓰기, 배정 강사는 평가 시작 시각(pre/post_eval_from)만';
comment on column nomad_classroom.courses.pre_eval_from is '사전 평가 시작 시각 (null = 평가 잠금, 기능 pre_post_assessment)';
comment on column nomad_classroom.courses.post_eval_from is '사후 평가 시작 시각 (사전 평가 뒤에만, 한 번 정하면 강사는 못 바꿈)';
comment on column nomad_classroom.courses.overview is
  '과정 소개 {class_time, lunch, instructor_org, nature, method, summary string[]} — 모두 선택, 관리자만 수정';

-- 강사·참관 배정(원본 course_instructors.profile_id → user_id). 같은 조직 멤버만(memberships 복합 FK, 멤버 제거 시 배정도 삭제).
create table nomad_classroom.course_instructors (
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  user_id         uuid not null,
  primary key (course_id, user_id),
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade,
  foreign key (organization_id, user_id) references nomad_core.memberships (organization_id, user_id) on delete cascade
);
create index course_instructors_user_idx on nomad_classroom.course_instructors (user_id, course_id);
create index course_instructors_org_idx on nomad_classroom.course_instructors (organization_id);
comment on table nomad_classroom.course_instructors is '과정 배정: editor = 강사, viewer = 참관(과정 구조만, 학생 정보 없음)';

create table nomad_classroom.course_days (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  no              int not null check (no >= 1),
  title           text not null,
  summary         text,
  open_date       date,
  detail          jsonb check (
                    detail is null
                    or (jsonb_typeof(detail) = 'object'
                        and (not (detail ? 'learn') or jsonb_typeof(detail -> 'learn') = 'array')
                        and (not (detail ? 'activities') or jsonb_typeof(detail -> 'activities') = 'array'))),
  unique (course_id, no),
  unique (id, course_id),
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create index course_days_org_idx on nomad_classroom.course_days (organization_id);
comment on table nomad_classroom.course_days is '일차. detail = {learn string[], activities string[], outcome}';

create table nomad_classroom.quizzes (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  title           text not null,
  kind            text not null check (kind in ('manual', 'generated')),
  config          jsonb not null default '{}'::jsonb,  -- 정답·시드 비밀값 금지
  unique (id, course_id),
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create index quizzes_course_idx on nomad_classroom.quizzes (course_id);
create index quizzes_org_idx on nomad_classroom.quizzes (organization_id);
comment on table nomad_classroom.quizzes is '퀴즈 정의(manual · generated 3면도). 쓰기는 기능 quiz_bank';

-- storage_path 규칙: <organization_id>/classroom/<course_id>/<uuid>.<확장자> (자기 조직·과정 접두, 버킷 classroom-materials)
create table nomad_classroom.materials (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  day_id          uuid,
  audience        text not null check (audience in ('student', 'teacher', 'both')),
  type            text not null check (type in ('file', 'link', 'code', 'quiz')),
  label           text not null,
  storage_path    text,
  url             text,
  sort            int not null default 0,
  open_at         timestamptz,
  quiz_id         uuid,
  bundle          text check (bundle in ('solution')),
  constraint materials_storage_path_check check (
    storage_path is null
    or storage_path ~ ('^' || organization_id::text || '/classroom/' || course_id::text
                       || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,10}$')),
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade,
  foreign key (day_id, course_id) references nomad_classroom.course_days (id, course_id) on delete cascade,
  foreign key (quiz_id, course_id) references nomad_classroom.quizzes (id, course_id) on delete set null (quiz_id)
);
create index materials_course_idx on nomad_classroom.materials (course_id, sort);
create index materials_day_idx on nomad_classroom.materials (day_id);
create index materials_quiz_idx on nomad_classroom.materials (quiz_id);
create index materials_org_idx on nomad_classroom.materials (organization_id);
create index materials_storage_path_idx on nomad_classroom.materials (storage_path) where storage_path is not null;
comment on table nomad_classroom.materials is '자료 (storage_path·url 모두 null = 준비 중, bundle solution = 연습풀이 도면)';

-- 학생 코드: 코드 1개 = 학생 1명(계정 없음). label(학생 이름일 수 있음)·입장 시각은 manager·instructor 만 본다.
create table nomad_classroom.student_codes (
  code             text primary key check (code ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id        uuid not null,
  label            text,
  valid_until      timestamptz,
  revoked_at       timestamptz,
  first_entered_at timestamptz,
  last_entered_at  timestamptz,
  created_at       timestamptz not null default now(),
  unique (code, course_id),
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create index student_codes_course_idx on nomad_classroom.student_codes (course_id, created_at);
create index student_codes_org_idx on nomad_classroom.student_codes (organization_id);
comment on table nomad_classroom.student_codes is '학생 코드(개인정보: label·입장 시각). 발급은 issue_student_codes RPC(난수)·서버만, 폐기는 revoked_at, 삭제 없음. 입장 시각은 서버만';

-- 정답 포함: manager·instructor 만 읽는다(학생은 서버를 통해서만).
create table nomad_classroom.quiz_questions (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  quiz_id         uuid not null,
  prompt          text not null,
  options         jsonb not null,  -- [{id, label}]
  answer          text not null,   -- 정답 보기 id
  explanation     text,
  sort            int not null default 0,
  foreign key (quiz_id, course_id) references nomad_classroom.quizzes (id, course_id) on delete cascade,
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create index quiz_questions_quiz_idx on nomad_classroom.quiz_questions (quiz_id, sort);
create index quiz_questions_course_idx on nomad_classroom.quiz_questions (course_id);
create index quiz_questions_org_idx on nomad_classroom.quiz_questions (organization_id);
comment on table nomad_classroom.quiz_questions is '직접 등록형 문항(정답 포함). 쓰기는 기능 quiz_bank';

-- 응시 기록: 서버(service_role)만 쓴다. 코드·퀴즈가 같은 과정인지 복합 FK 로 강제(원본에 없던 강제).
create table nomad_classroom.quiz_attempts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  quiz_id         uuid not null,
  code            text not null,
  level           int not null,
  mode            text not null check (mode in ('main', 'hidden')),
  phase           text not null check (phase in ('pre', 'post')),
  score           int not null check (score >= 0),
  answers         jsonb not null,
  created_at      timestamptz not null default now(),
  unique (code, quiz_id, level, mode, phase),
  foreign key (quiz_id, course_id) references nomad_classroom.quizzes (id, course_id) on delete cascade,
  foreign key (code, course_id) references nomad_classroom.student_codes (code, course_id) on delete cascade,
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create index quiz_attempts_quiz_code_idx on nomad_classroom.quiz_attempts (quiz_id, code);
create index quiz_attempts_course_idx on nomad_classroom.quiz_attempts (course_id);
create index quiz_attempts_org_idx on nomad_classroom.quiz_attempts (organization_id);
comment on table nomad_classroom.quiz_attempts is '응시 기록(개인정보). service_role 만 INSERT·UPDATE, 기능 pre_post_assessment';

create table nomad_classroom.surveys (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  audience        text not null check (audience in ('student', 'teacher')),
  open_at         timestamptz,
  questions       jsonb not null default '[]'::jsonb,
  unique (id, course_id),
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create index surveys_course_idx on nomad_classroom.surveys (course_id);
create index surveys_org_idx on nomad_classroom.surveys (organization_id);
comment on table nomad_classroom.surveys is '설문(강사·수강생 공용 형식)';

-- 응답: 학생(code, 서버 기록) 또는 강사(profile_id = 본인). profile_id 는 원본 profiles → auth.users.
create table nomad_classroom.survey_responses (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id       uuid not null,
  survey_id       uuid not null,
  code            text,
  profile_id      uuid references auth.users(id) on delete cascade,
  answers         jsonb not null,
  created_at      timestamptz not null default now(),
  check (num_nonnulls(code, profile_id) = 1),
  unique (code, survey_id),
  foreign key (survey_id, course_id) references nomad_classroom.surveys (id, course_id) on delete cascade,
  foreign key (code, course_id) references nomad_classroom.student_codes (code, course_id) on delete cascade,
  foreign key (course_id, organization_id) references nomad_classroom.courses (id, organization_id) on delete cascade
);
create unique index survey_responses_profile_survey_key on nomad_classroom.survey_responses (profile_id, survey_id) where profile_id is not null;
create index survey_responses_survey_idx on nomad_classroom.survey_responses (survey_id);
create index survey_responses_course_idx on nomad_classroom.survey_responses (course_id);
create index survey_responses_org_idx on nomad_classroom.survey_responses (organization_id);
comment on table nomad_classroom.survey_responses is '설문 응답(개인정보). 학생 응답은 서버, 강사 응답은 본인 1회';

-- =====================================================================
-- 2. 판정 함수 (security definer, search_path '')
-- =====================================================================
-- 과정에서의 호출자 역할. 멤버십·조직 활성·course_core(모든 플랜) 포함. 과정이 없거나 무관하면 null.
create function nomad_classroom.course_role(p_course uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select case
           when r.role in ('owner', 'admin') then 'manager'
           when r.role = 'editor' and r.assigned then 'instructor'
           when r.role = 'viewer' and r.assigned then 'observer'
         end
  from (select nomad_core.organization_role(c.organization_id) as role,
               exists (select 1 from nomad_classroom.course_instructors ci
                       where ci.course_id = c.id and ci.user_id = (select auth.uid())) as assigned,
               c.organization_id
        from nomad_classroom.courses c where c.id = p_course) r
  where coalesce(nomad_core.has_feature(r.organization_id, 'classroom', 'course_core'), false)
$$;

-- 학생 개인정보·정답 읽기: manager · instructor
create function nomad_classroom.can_read_private(p_course uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_classroom.course_role(p_course) in ('manager', 'instructor'), false) $$;

-- 과정 쓰기: manager + (기능). 구독이 끊기면 유료 기능 쓰기만 잠긴다.
create function nomad_classroom.can_write(p_course uuid, p_feature text default null) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_classroom.course_role(p_course) = 'manager', false)
     and (p_feature is null or exists (
           select 1 from nomad_classroom.courses c
           where c.id = p_course and nomad_core.org_has_feature(c.organization_id, 'classroom', p_feature)))
$$;

-- 조직 단위 관리(과정 만들기): owner·admin + course_core
create function nomad_classroom.is_org_manager(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(p_org) in ('owner', 'admin'), false)
     and coalesce(nomad_core.has_feature(p_org, 'classroom', 'course_core'), false)
$$;

-- 강사 설문 응답: 그 과정의 teacher 설문인지(호출자가 그 과정의 manager·instructor 일 때만 참, 비멤버는 항상 거짓)
create function nomad_classroom.is_teacher_survey(p_survey uuid, p_course uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_classroom.can_read_private(p_course)
     and exists (select 1 from nomad_classroom.surveys s where s.id = p_survey and s.course_id = p_course and s.audience = 'teacher')
$$;

-- 자료 읽기: manager·instructor 는 전부, observer 는 교사용(audience teacher)·연습풀이(bundle solution) 제외
create function nomad_classroom.can_read_material(p_course uuid, p_audience text, p_bundle text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select case nomad_classroom.course_role(p_course)
           when 'manager' then true
           when 'instructor' then true
           when 'observer' then p_audience <> 'teacher' and p_bundle is null
           else false
         end
$$;

-- Storage: <organization_id>/classroom/<course_id>/<파일> 의 과정 역할(경로 조직 = 과정 조직일 때만)
create function nomad_classroom.storage_course_role(p_name text) returns text
language sql stable security definer set search_path = ''
as $$
  select nomad_classroom.course_role(c.id)
  from nomad_classroom.courses c
  where split_part(p_name, '/', 2) = 'classroom'
    and c.id = case when split_part(p_name, '/', 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    then split_part(p_name, '/', 3)::uuid end
    and c.organization_id = case when split_part(p_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                 then split_part(p_name, '/', 1)::uuid end
$$;

-- Storage 읽기: 과정 역할 + observer 는 읽을 수 있는 자료 행이 가리키는 파일만
create function nomad_classroom.storage_can_read(p_name text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select case nomad_classroom.storage_course_role(p_name)
           when 'manager' then true
           when 'instructor' then true
           when 'observer' then exists (select 1 from nomad_classroom.materials m
                                        where m.storage_path = p_name and m.audience <> 'teacher' and m.bundle is null)
           else false
         end
$$;

-- 학생 코드 발급(manager): 코드는 DB 가 난수로 만든다(사용자 지정 금지 — 전역 PK 라 남의 조직 코드 존재가 드러남).
-- 충돌하면 다시 뽑고(최대 5회) 오류에 기존 코드를 싣지 않는다. 권한 없음·없는 과정은 같은 42501.
create function nomad_classroom.issue_student_codes(p_course uuid, p_labels text[], p_valid_until timestamptz default null)
returns table (code text, label text)
language plpgsql volatile security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32자(I·O·0·1 제외)
  v_org uuid; v_label text; v_code text; v_bytes bytea; v_try int; i int;
begin
  if not nomad_classroom.can_write(p_course) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_labels is null or cardinality(p_labels) not between 1 and 200 then
    raise exception 'labels must have 1..200 items' using errcode = '22023';
  end if;
  select c.organization_id into v_org from nomad_classroom.courses c where c.id = p_course;
  foreach v_label in array p_labels loop
    v_try := 0;
    loop
      v_bytes := extensions.gen_random_bytes(8);
      v_code := '';
      for i in 0..7 loop
        v_code := v_code || substr(v_alpha, 1 + get_byte(v_bytes, i) % 32, 1) || case when i = 3 then '-' else '' end;
      end loop;
      begin
        insert into nomad_classroom.student_codes (code, organization_id, course_id, label, valid_until)
        values (v_code, v_org, p_course, nullif(btrim(v_label), ''), p_valid_until);
        exit;
      exception when unique_violation then
        v_try := v_try + 1;
        if v_try >= 5 then
          raise exception 'could not issue a unique code, retry' using errcode = '55000';
        end if;
      end;
    end loop;
    code := v_code; label := nullif(btrim(v_label), '');
    return next;
  end loop;
end;
$$;

-- =====================================================================
-- 3. 트리거
-- =====================================================================
-- 과정 수정: 강사(instructor)는 평가 시작 시각만, null → 값으로만, 사전 평가 없이 사후 평가 불가(원본 0007).
-- 평가 시작 시각 변경은 누구든 기능 pre_post_assessment 필요(구독 끊김 = CL001). RLS USING 이 비멤버 행을 먼저 거른다.
create function nomad_classroom.guard_course_update() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_role text;
begin
  if (new.pre_eval_from is distinct from old.pre_eval_from or new.post_eval_from is distinct from old.post_eval_from)
     and not nomad_core.org_has_feature(old.organization_id, 'classroom', 'pre_post_assessment') then
    raise exception 'plan feature locked: pre_post_assessment' using errcode = 'CL001';
  end if;
  if nomad_core.is_service_caller() then
    return new;
  end if;
  v_role := nomad_classroom.course_role(old.id);
  if v_role is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_role = 'manager' then
    return new;
  end if;
  if (to_jsonb(new) - 'pre_eval_from' - 'post_eval_from') is distinct from (to_jsonb(old) - 'pre_eval_from' - 'post_eval_from') then
    raise exception 'instructors may only update pre_eval_from and post_eval_from' using errcode = '42501';
  end if;
  if (old.pre_eval_from is not null and new.pre_eval_from is distinct from old.pre_eval_from)
     or (old.post_eval_from is not null and new.post_eval_from is distinct from old.post_eval_from) then
    raise exception 'evaluation start times cannot be changed once set' using errcode = '42501';
  end if;
  if new.post_eval_from is not null and new.pre_eval_from is null then
    raise exception 'pre evaluation must start before post evaluation' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger courses_guard_update before update on nomad_classroom.courses
  for each row execute function nomad_classroom.guard_course_update();

-- 응시 기록: 기능 pre_post_assessment 가 없으면(구독 끊김) 서버도 기록하지 않는다.
create function nomad_classroom.guard_attempt() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.org_has_feature(new.organization_id, 'classroom', 'pre_post_assessment') then
    raise exception 'plan feature locked: pre_post_assessment' using errcode = 'CL001';
  end if;
  return new;
end;
$$;
create trigger quiz_attempts_guard before insert or update on nomad_classroom.quiz_attempts
  for each row execute function nomad_classroom.guard_attempt();

-- =====================================================================
-- 4. RLS 정책
-- =====================================================================
alter table nomad_classroom.courses enable row level security;
alter table nomad_classroom.course_instructors enable row level security;
alter table nomad_classroom.course_days enable row level security;
alter table nomad_classroom.quizzes enable row level security;
alter table nomad_classroom.materials enable row level security;
alter table nomad_classroom.student_codes enable row level security;
alter table nomad_classroom.quiz_questions enable row level security;
alter table nomad_classroom.quiz_attempts enable row level security;
alter table nomad_classroom.surveys enable row level security;
alter table nomad_classroom.survey_responses enable row level security;

-- courses: 역할이 있으면 읽기(조직 manager 판정을 함께 둔다 — insert … returning 시점에는 새 행이 course_role 조회에 안 보임), manager 만들기·수정, instructor 는 수정(트리거가 평가 시각만 허용). 삭제는 서버만(원본과 같음).
create policy courses_select on nomad_classroom.courses for select to authenticated
  using (nomad_classroom.is_org_manager(organization_id) or nomad_classroom.course_role(id) is not null);
create policy courses_insert on nomad_classroom.courses for insert to authenticated
  with check (nomad_classroom.is_org_manager(organization_id));
create policy courses_update on nomad_classroom.courses for update to authenticated
  using (nomad_classroom.can_read_private(id)) with check (nomad_classroom.can_read_private(id));

-- course_instructors: 본인 배정 또는 manager 읽기, manager 쓰기
create policy course_instructors_select on nomad_classroom.course_instructors for select to authenticated
  using ((user_id = (select auth.uid()) and nomad_classroom.course_role(course_id) is not null)
         or nomad_classroom.course_role(course_id) = 'manager');
create policy course_instructors_insert on nomad_classroom.course_instructors for insert to authenticated
  with check (nomad_classroom.can_write(course_id));
create policy course_instructors_delete on nomad_classroom.course_instructors for delete to authenticated
  using (nomad_classroom.can_write(course_id));

-- 과정 구조(일차·자료·설문): 역할이 있으면 읽기, manager 쓰기
create policy course_days_select on nomad_classroom.course_days for select to authenticated
  using (nomad_classroom.course_role(course_id) is not null);
create policy course_days_insert on nomad_classroom.course_days for insert to authenticated
  with check (nomad_classroom.can_write(course_id));
create policy course_days_update on nomad_classroom.course_days for update to authenticated
  using (nomad_classroom.can_write(course_id)) with check (nomad_classroom.can_write(course_id));
create policy course_days_delete on nomad_classroom.course_days for delete to authenticated
  using (nomad_classroom.can_write(course_id));

create policy materials_select on nomad_classroom.materials for select to authenticated
  using (nomad_classroom.can_read_material(course_id, audience, bundle));
create policy materials_insert on nomad_classroom.materials for insert to authenticated
  with check (nomad_classroom.can_write(course_id));
create policy materials_update on nomad_classroom.materials for update to authenticated
  using (nomad_classroom.can_write(course_id)) with check (nomad_classroom.can_write(course_id));
create policy materials_delete on nomad_classroom.materials for delete to authenticated
  using (nomad_classroom.can_write(course_id));

create policy surveys_select on nomad_classroom.surveys for select to authenticated
  using (nomad_classroom.course_role(course_id) is not null);
create policy surveys_insert on nomad_classroom.surveys for insert to authenticated
  with check (nomad_classroom.can_write(course_id));
create policy surveys_update on nomad_classroom.surveys for update to authenticated
  using (nomad_classroom.can_write(course_id)) with check (nomad_classroom.can_write(course_id));
create policy surveys_delete on nomad_classroom.surveys for delete to authenticated
  using (nomad_classroom.can_write(course_id));

-- 퀴즈: 역할이 있으면 읽기, manager + quiz_bank 쓰기
create policy quizzes_select on nomad_classroom.quizzes for select to authenticated
  using (nomad_classroom.course_role(course_id) is not null);
create policy quizzes_insert on nomad_classroom.quizzes for insert to authenticated
  with check (nomad_classroom.can_write(course_id, 'quiz_bank'));
create policy quizzes_update on nomad_classroom.quizzes for update to authenticated
  using (nomad_classroom.can_write(course_id, 'quiz_bank')) with check (nomad_classroom.can_write(course_id, 'quiz_bank'));
create policy quizzes_delete on nomad_classroom.quizzes for delete to authenticated
  using (nomad_classroom.can_write(course_id, 'quiz_bank'));

-- 정답 포함 문항: manager·instructor 읽기, manager + quiz_bank 쓰기
create policy quiz_questions_select on nomad_classroom.quiz_questions for select to authenticated
  using (nomad_classroom.can_read_private(course_id));
create policy quiz_questions_insert on nomad_classroom.quiz_questions for insert to authenticated
  with check (nomad_classroom.can_write(course_id, 'quiz_bank'));
create policy quiz_questions_update on nomad_classroom.quiz_questions for update to authenticated
  using (nomad_classroom.can_write(course_id, 'quiz_bank')) with check (nomad_classroom.can_write(course_id, 'quiz_bank'));
create policy quiz_questions_delete on nomad_classroom.quiz_questions for delete to authenticated
  using (nomad_classroom.can_write(course_id, 'quiz_bank'));

-- 학생 개인정보: manager·instructor 읽기. 발급은 issue_student_codes RPC 만(사용자 insert 권한·정책 없음), 수정(이름·유효기간·폐기)은 manager, 삭제 없음.
create policy student_codes_select on nomad_classroom.student_codes for select to authenticated
  using (nomad_classroom.can_read_private(course_id));
create policy student_codes_update on nomad_classroom.student_codes for update to authenticated
  using (nomad_classroom.can_write(course_id)) with check (nomad_classroom.can_write(course_id));

create policy quiz_attempts_select on nomad_classroom.quiz_attempts for select to authenticated
  using (nomad_classroom.can_read_private(course_id));

-- 설문 응답: 학생 응답·본인 응답은 manager·instructor, 다른 강사의 응답은 manager 만. 강사는 teacher 설문에 본인 이름으로만.
create policy survey_responses_select on nomad_classroom.survey_responses for select to authenticated
  using (nomad_classroom.course_role(course_id) = 'manager'
         or (nomad_classroom.can_read_private(course_id) and (code is not null or profile_id = (select auth.uid()))));
create policy survey_responses_insert_teacher on nomad_classroom.survey_responses for insert to authenticated
  with check (profile_id = (select auth.uid()) and code is null
              and nomad_classroom.can_read_private(course_id)
              and nomad_classroom.is_teacher_survey(survey_id, course_id));

-- =====================================================================
-- 5. 권한 (anon 없음. 사용자 insert 에 id 없음, 학생 코드는 RPC 발급만)
-- =====================================================================
revoke all on all tables in schema nomad_classroom from public, anon, authenticated;
grant all on all tables in schema nomad_classroom to service_role;

grant select on nomad_classroom.courses to authenticated;
grant insert (organization_id, subject, name, host, place, first_day, day_count, day_open_time, access_start, access_end,
              preview_until, programs, overview) on nomad_classroom.courses to authenticated;
grant update (subject, name, host, place, first_day, day_count, day_open_time, access_start, access_end,
              preview_until, programs, overview, pre_eval_from, post_eval_from) on nomad_classroom.courses to authenticated;

grant select, delete on nomad_classroom.course_instructors to authenticated;
grant insert (organization_id, course_id, user_id) on nomad_classroom.course_instructors to authenticated;

grant select, delete on nomad_classroom.course_days to authenticated;
grant insert (organization_id, course_id, no, title, summary, open_date, detail) on nomad_classroom.course_days to authenticated;
grant update (no, title, summary, open_date, detail) on nomad_classroom.course_days to authenticated;

grant select, delete on nomad_classroom.materials to authenticated;
grant insert (organization_id, course_id, day_id, audience, type, label, storage_path, url, sort, open_at, quiz_id, bundle)
  on nomad_classroom.materials to authenticated;
grant update (day_id, audience, type, label, storage_path, url, sort, open_at, quiz_id, bundle) on nomad_classroom.materials to authenticated;

grant select, delete on nomad_classroom.quizzes to authenticated;
grant insert (organization_id, course_id, title, kind, config) on nomad_classroom.quizzes to authenticated;
grant update (title, kind, config) on nomad_classroom.quizzes to authenticated;

grant select, delete on nomad_classroom.quiz_questions to authenticated;
grant insert (organization_id, course_id, quiz_id, prompt, options, answer, explanation, sort) on nomad_classroom.quiz_questions to authenticated;
grant update (prompt, options, answer, explanation, sort) on nomad_classroom.quiz_questions to authenticated;

grant select on nomad_classroom.student_codes to authenticated;
grant update (label, valid_until, revoked_at) on nomad_classroom.student_codes to authenticated;

grant select on nomad_classroom.quiz_attempts to authenticated;

grant select, delete on nomad_classroom.surveys to authenticated;
grant insert (organization_id, course_id, audience, open_at, questions) on nomad_classroom.surveys to authenticated;
grant update (audience, open_at, questions) on nomad_classroom.surveys to authenticated;

grant select on nomad_classroom.survey_responses to authenticated;
grant insert (organization_id, course_id, survey_id, profile_id, answers) on nomad_classroom.survey_responses to authenticated;

revoke execute on all functions in schema nomad_classroom from public, anon, authenticated;
grant execute on function nomad_classroom.course_role(uuid), nomad_classroom.can_read_private(uuid),
  nomad_classroom.can_write(uuid, text), nomad_classroom.is_org_manager(uuid),
  nomad_classroom.is_teacher_survey(uuid, uuid), nomad_classroom.storage_course_role(text),
  nomad_classroom.can_read_material(uuid, text, text), nomad_classroom.storage_can_read(text),
  nomad_classroom.issue_student_codes(uuid, text[], timestamptz) to authenticated, service_role;

-- =====================================================================
-- 6. Storage (원본 course-materials 대체). 비공개 50MB. 학생에게는 서버가 서명 URL·중계로만 내려준다.
--    읽기 = 그 과정 역할(manager·instructor, observer 는 교사용·풀이 자료 파일 제외), 올리기·지우기 = manager(course_core). 경로 <organization_id>/classroom/<course_id>/<uuid>.<확장자>
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('classroom-materials', 'classroom-materials', false, 52428800)
on conflict (id) do nothing;

create policy nomad_classroom_materials_select on storage.objects for select to authenticated
  using (bucket_id = 'classroom-materials' and nomad_classroom.storage_can_read(name));
create policy nomad_classroom_materials_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'classroom-materials'
              and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/classroom/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,10}$'
              and nomad_classroom.storage_course_role(name) = 'manager');
create policy nomad_classroom_materials_delete on storage.objects for delete to authenticated
  using (bucket_id = 'classroom-materials' and nomad_classroom.storage_course_role(name) = 'manager');

commit;
