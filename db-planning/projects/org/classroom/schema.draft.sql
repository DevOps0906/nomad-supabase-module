-- classroom · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists classroom;

create table classroom.courses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  title text,
  subject text,  -- 바이브코딩·CAD
  created_at timestamptz not null default now()
);
create index idx_courses_org_id on classroom.courses(org_id);
alter table classroom.courses enable row level security;
create policy courses_select_member on classroom.courses for select using (core.is_member(org_id));
create policy courses_insert_member on classroom.courses for insert with check (core.is_member(org_id));
create policy courses_update_member on classroom.courses for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy courses_delete_admin on classroom.courses for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table classroom.sessions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  course_id uuid references classroom.courses(id) on delete cascade,
  starts_at timestamptz,
  open_at timestamptz,  -- 자료 공개 시각
  created_at timestamptz not null default now()
);
create index idx_sessions_org_id on classroom.sessions(org_id);
alter table classroom.sessions enable row level security;
create policy sessions_select_member on classroom.sessions for select using (core.is_member(org_id));
create policy sessions_insert_member on classroom.sessions for insert with check (core.is_member(org_id));
create policy sessions_update_member on classroom.sessions for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy sessions_delete_admin on classroom.sessions for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table classroom.materials (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  session_id uuid references classroom.sessions(id) on delete cascade,
  kind text,
  file_path text,
  created_at timestamptz not null default now()
);
create index idx_materials_org_id on classroom.materials(org_id);
alter table classroom.materials enable row level security;
create policy materials_select_member on classroom.materials for select using (core.is_member(org_id));
create policy materials_insert_member on classroom.materials for insert with check (core.is_member(org_id));
create policy materials_update_member on classroom.materials for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy materials_delete_admin on classroom.materials for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table classroom.enrollments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  course_id uuid references classroom.courses(id) on delete cascade,
  student_id uuid references core.profiles(user_id),
  role text,  -- 수강생·조교
  created_at timestamptz not null default now()
);
create index idx_enrollments_org_id on classroom.enrollments(org_id);
alter table classroom.enrollments enable row level security;
create policy enrollments_select_member on classroom.enrollments for select using (core.is_member(org_id));
create policy enrollments_insert_member on classroom.enrollments for insert with check (core.is_member(org_id));
create policy enrollments_update_member on classroom.enrollments for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy enrollments_delete_admin on classroom.enrollments for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table classroom.assessments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  course_id uuid references classroom.courses(id) on delete cascade,
  phase text,  -- 사전·사후
  created_at timestamptz not null default now()
);
create index idx_assessments_org_id on classroom.assessments(org_id);
alter table classroom.assessments enable row level security;
create policy assessments_select_member on classroom.assessments for select using (core.is_member(org_id));
create policy assessments_insert_member on classroom.assessments for insert with check (core.is_member(org_id));
create policy assessments_update_member on classroom.assessments for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy assessments_delete_admin on classroom.assessments for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table classroom.quiz_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  level numeric,  -- 초급·중급·고급
  views numeric,  -- 3면도·숨은선
  is_hidden boolean,  -- 히든 문제
  created_at timestamptz not null default now()
);
create index idx_quiz_items_org_id on classroom.quiz_items(org_id);
alter table classroom.quiz_items enable row level security;
create policy quiz_items_select_member on classroom.quiz_items for select using (core.is_member(org_id));
create policy quiz_items_insert_member on classroom.quiz_items for insert with check (core.is_member(org_id));
create policy quiz_items_update_member on classroom.quiz_items for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy quiz_items_delete_admin on classroom.quiz_items for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table classroom.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  student_id uuid references core.profiles(user_id),
  level numeric,
  score numeric,  -- 70% 이상 통과
  created_at timestamptz not null default now()
);
create index idx_quiz_attempts_org_id on classroom.quiz_attempts(org_id);
alter table classroom.quiz_attempts enable row level security;
create policy quiz_attempts_select_member on classroom.quiz_attempts for select using (core.is_member(org_id));
create policy quiz_attempts_insert_member on classroom.quiz_attempts for insert with check (core.is_member(org_id));
create policy quiz_attempts_update_member on classroom.quiz_attempts for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy quiz_attempts_delete_admin on classroom.quiz_attempts for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

