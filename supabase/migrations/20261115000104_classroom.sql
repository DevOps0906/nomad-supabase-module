-- Classroom · 조직형
-- 원본 청사진: blueprints/org/classroom/schema.draft.sql
-- 되돌림: drop schema nomad_classroom cascade; delete from nomad_core.products where code = 'classroom';
begin;

create schema nomad_classroom;
revoke all on schema nomad_classroom from public, anon, authenticated;
grant usage on schema nomad_classroom to authenticated, service_role;

insert into nomad_core.products (code, name) values ('classroom', 'Classroom');

create table nomad_classroom.courses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  title text not null,
  subject text not null default 'vibe_coding' check (subject in ('vibe_coding', 'cad')),
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_classroom.courses is '강좌';
comment on column nomad_classroom.courses.subject is '주제: vibe_coding 바이브코딩, cad';
create index idx_courses_org_created on nomad_classroom.courses(organization_id, created_at desc);
alter table nomad_classroom.courses enable row level security;
create policy courses_select on nomad_classroom.courses for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy courses_insert on nomad_classroom.courses for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy courses_update on nomad_classroom.courses for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy courses_delete on nomad_classroom.courses for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id uuid,
  starts_at timestamptz,
  open_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, course_id) references nomad_classroom.courses(organization_id, id) on delete cascade
);
comment on table nomad_classroom.sessions is '강좌의 회차';
comment on column nomad_classroom.sessions.open_at is '자료 공개 시각';
create index idx_sessions_org_created on nomad_classroom.sessions(organization_id, created_at desc);
create index idx_sessions_course_id on nomad_classroom.sessions(organization_id, course_id);
alter table nomad_classroom.sessions enable row level security;
create policy sessions_select on nomad_classroom.sessions for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy sessions_insert on nomad_classroom.sessions for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy sessions_update on nomad_classroom.sessions for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy sessions_delete on nomad_classroom.sessions for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  session_id uuid,
  kind text,
  file_path text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, session_id) references nomad_classroom.sessions(organization_id, id) on delete cascade
);
comment on table nomad_classroom.materials is '회차별 수업 자료';
create index idx_materials_org_created on nomad_classroom.materials(organization_id, created_at desc);
create index idx_materials_session_id on nomad_classroom.materials(organization_id, session_id);
alter table nomad_classroom.materials enable row level security;
create policy materials_select on nomad_classroom.materials for select to authenticated using (nomad_core.organization_role(organization_id) is not null and (exists (select 1 from nomad_classroom.sessions p where p.id = session_id and (p.open_at is null or p.open_at <= now())) or nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')));
create policy materials_insert on nomad_classroom.materials for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy materials_update on nomad_classroom.materials for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy materials_delete on nomad_classroom.materials for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.enrollments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id uuid,
  student_id uuid not null,
  role text not null default 'student' check (role in ('student', 'assistant')),
  created_at timestamptz not null default now(),
  foreign key (organization_id, course_id) references nomad_classroom.courses(organization_id, id) on delete cascade,
  foreign key (organization_id, student_id) references nomad_core.memberships(organization_id, user_id) on delete cascade
);
comment on table nomad_classroom.enrollments is '강좌 수강 등록과 역할';
comment on column nomad_classroom.enrollments.role is '역할: student 수강생, assistant 조교';
create index idx_enrollments_org_created on nomad_classroom.enrollments(organization_id, created_at desc);
create index idx_enrollments_student_id on nomad_classroom.enrollments(organization_id, student_id);
create index idx_enrollments_course_id on nomad_classroom.enrollments(organization_id, course_id);
alter table nomad_classroom.enrollments enable row level security;
create policy enrollments_select on nomad_classroom.enrollments for select to authenticated using (nomad_core.organization_role(organization_id) is not null and (student_id = (select auth.uid()) or nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')));
create policy enrollments_insert on nomad_classroom.enrollments for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy enrollments_update on nomad_classroom.enrollments for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy enrollments_delete on nomad_classroom.enrollments for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.assessments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  course_id uuid,
  phase text not null default 'pre' check (phase in ('pre', 'post')),
  created_at timestamptz not null default now(),
  foreign key (organization_id, course_id) references nomad_classroom.courses(organization_id, id) on delete cascade
);
comment on table nomad_classroom.assessments is '강좌 평가(사전·사후)';
comment on column nomad_classroom.assessments.phase is '평가 시점: pre 사전, post 사후';
create index idx_assessments_org_created on nomad_classroom.assessments(organization_id, created_at desc);
create index idx_assessments_course_id on nomad_classroom.assessments(organization_id, course_id);
alter table nomad_classroom.assessments enable row level security;
create policy assessments_select on nomad_classroom.assessments for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy assessments_insert on nomad_classroom.assessments for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy assessments_update on nomad_classroom.assessments for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy assessments_delete on nomad_classroom.assessments for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.quiz_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  level numeric,
  views numeric,
  is_hidden boolean,
  created_at timestamptz not null default now()
);
comment on table nomad_classroom.quiz_items is '퀴즈 문항';
comment on column nomad_classroom.quiz_items.level is '초급·중급·고급 수준';
comment on column nomad_classroom.quiz_items.views is '3면도·숨은선';
comment on column nomad_classroom.quiz_items.is_hidden is '히든 문제 여부';
create index idx_quiz_items_org_created on nomad_classroom.quiz_items(organization_id, created_at desc);
alter table nomad_classroom.quiz_items enable row level security;
create policy quiz_items_select on nomad_classroom.quiz_items for select to authenticated using (nomad_core.organization_role(organization_id) is not null and (not coalesce(is_hidden, false) or nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')));
create policy quiz_items_insert on nomad_classroom.quiz_items for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy quiz_items_update on nomad_classroom.quiz_items for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy quiz_items_delete on nomad_classroom.quiz_items for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_classroom.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  student_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  level numeric,
  score int check (score between 0 and 100),
  created_at timestamptz not null default now()
);
comment on table nomad_classroom.quiz_attempts is '수강생 퀴즈 응시 결과';
comment on column nomad_classroom.quiz_attempts.score is '점수(%), 70 이상 통과';
create index idx_quiz_attempts_org_created on nomad_classroom.quiz_attempts(organization_id, created_at desc);
create index idx_quiz_attempts_student_id on nomad_classroom.quiz_attempts(student_id);
alter table nomad_classroom.quiz_attempts enable row level security;
create policy quiz_attempts_select on nomad_classroom.quiz_attempts for select to authenticated using (nomad_core.organization_role(organization_id) is not null and (student_id = (select auth.uid()) or nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')));

revoke all on all tables in schema nomad_classroom from public, anon, authenticated;
grant all on all tables in schema nomad_classroom to service_role;
grant select, insert, delete on nomad_classroom.courses to authenticated;
grant update (title, subject) on nomad_classroom.courses to authenticated;
grant select, insert, delete on nomad_classroom.sessions to authenticated;
grant update (course_id, starts_at, open_at) on nomad_classroom.sessions to authenticated;
grant select, insert, delete on nomad_classroom.materials to authenticated;
grant update (session_id, kind, file_path) on nomad_classroom.materials to authenticated;
grant select, insert, delete on nomad_classroom.enrollments to authenticated;
grant update (course_id, role) on nomad_classroom.enrollments to authenticated;
grant select, insert, delete on nomad_classroom.assessments to authenticated;
grant update (course_id, phase) on nomad_classroom.assessments to authenticated;
grant select, insert, delete on nomad_classroom.quiz_items to authenticated;
grant update (level, views, is_hidden) on nomad_classroom.quiz_items to authenticated;
grant select on nomad_classroom.quiz_attempts to authenticated;

commit;
