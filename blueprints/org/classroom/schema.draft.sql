-- classroom · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create schema if not exists nomad_classroom;
revoke all on schema nomad_classroom from public, anon, authenticated;
grant usage on schema nomad_classroom to authenticated, service_role;

create table nomad_classroom.courses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  title text,
  subject text,  -- 바이브코딩·CAD
  created_at timestamptz not null default now()
);
create index idx_courses_org_id on nomad_classroom.courses(organization_id);
alter table nomad_classroom.courses enable row level security;
create policy courses_select_member on nomad_classroom.courses for select using (nomad_core.organization_role(organization_id) is not null);
create policy courses_insert_member on nomad_classroom.courses for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy courses_update_member on nomad_classroom.courses for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy courses_delete_admin on nomad_classroom.courses for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id uuid references nomad_classroom.courses(id) on delete cascade,
  starts_at timestamptz,
  open_at timestamptz,  -- 자료 공개 시각
  created_at timestamptz not null default now()
);
create index idx_sessions_org_id on nomad_classroom.sessions(organization_id);
alter table nomad_classroom.sessions enable row level security;
create policy sessions_select_member on nomad_classroom.sessions for select using (nomad_core.organization_role(organization_id) is not null);
create policy sessions_insert_member on nomad_classroom.sessions for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy sessions_update_member on nomad_classroom.sessions for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy sessions_delete_admin on nomad_classroom.sessions for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  session_id uuid references nomad_classroom.sessions(id) on delete cascade,
  kind text,
  file_path text,
  created_at timestamptz not null default now()
);
create index idx_materials_org_id on nomad_classroom.materials(organization_id);
alter table nomad_classroom.materials enable row level security;
create policy materials_select_member on nomad_classroom.materials for select using (nomad_core.organization_role(organization_id) is not null);
create policy materials_insert_member on nomad_classroom.materials for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy materials_update_member on nomad_classroom.materials for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy materials_delete_admin on nomad_classroom.materials for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.enrollments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id uuid references nomad_classroom.courses(id) on delete cascade,
  student_id uuid references nomad_core.profiles(user_id),
  role text,  -- 수강생·조교
  created_at timestamptz not null default now()
);
create index idx_enrollments_org_id on nomad_classroom.enrollments(organization_id);
alter table nomad_classroom.enrollments enable row level security;
create policy enrollments_select_member on nomad_classroom.enrollments for select using (nomad_core.organization_role(organization_id) is not null);
create policy enrollments_insert_member on nomad_classroom.enrollments for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy enrollments_update_member on nomad_classroom.enrollments for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy enrollments_delete_admin on nomad_classroom.enrollments for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.assessments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id uuid references nomad_classroom.courses(id) on delete cascade,
  phase text,  -- 사전·사후
  created_at timestamptz not null default now()
);
create index idx_assessments_org_id on nomad_classroom.assessments(organization_id);
alter table nomad_classroom.assessments enable row level security;
create policy assessments_select_member on nomad_classroom.assessments for select using (nomad_core.organization_role(organization_id) is not null);
create policy assessments_insert_member on nomad_classroom.assessments for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy assessments_update_member on nomad_classroom.assessments for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy assessments_delete_admin on nomad_classroom.assessments for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.quiz_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  level numeric,  -- 초급·중급·고급
  views numeric,  -- 3면도·숨은선
  is_hidden boolean,  -- 히든 문제
  created_at timestamptz not null default now()
);
create index idx_quiz_items_org_id on nomad_classroom.quiz_items(organization_id);
alter table nomad_classroom.quiz_items enable row level security;
create policy quiz_items_select_member on nomad_classroom.quiz_items for select using (nomad_core.organization_role(organization_id) is not null);
create policy quiz_items_insert_member on nomad_classroom.quiz_items for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy quiz_items_update_member on nomad_classroom.quiz_items for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy quiz_items_delete_admin on nomad_classroom.quiz_items for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  student_id uuid references nomad_core.profiles(user_id),
  level numeric,
  score numeric,  -- 70% 이상 통과
  created_at timestamptz not null default now()
);
create index idx_quiz_attempts_org_id on nomad_classroom.quiz_attempts(organization_id);
alter table nomad_classroom.quiz_attempts enable row level security;
create policy quiz_attempts_select_member on nomad_classroom.quiz_attempts for select using (nomad_core.organization_role(organization_id) is not null);
create policy quiz_attempts_insert_member on nomad_classroom.quiz_attempts for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy quiz_attempts_update_member on nomad_classroom.quiz_attempts for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy quiz_attempts_delete_admin on nomad_classroom.quiz_attempts for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

