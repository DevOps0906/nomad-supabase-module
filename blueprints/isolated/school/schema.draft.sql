-- school · 별도 Supabase 프로젝트 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 격리형(별도 Supabase 프로젝트)

-- 이 파일은 별도 Supabase 프로젝트(B)에 적용합니다. core 스키마가 없습니다.
create schema if not exists nomad_school;
revoke all on schema nomad_school from public, anon, authenticated;
grant usage on schema nomad_school to authenticated, service_role;

create table nomad_school.teachers (
  user_id uuid primary key,
  subject text,
  role text  -- 담임·교과
);
alter table nomad_school.teachers enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_school.classes (
  id uuid primary key default gen_random_uuid(),
  name text,
  grade numeric,
  homeroom_id uuid references nomad_school.teachers(user_id) on delete cascade
);
alter table nomad_school.classes enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_school.students (
  id uuid primary key default gen_random_uuid(),
  class_id uuid references nomad_school.classes(id) on delete cascade,
  name_enc text,  -- 암호화
  birth_enc text  -- 암호화
);
alter table nomad_school.students enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_school.attendance (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references nomad_school.students(id) on delete cascade,
  date date,
  status text  -- 출석·결석·지각
);
alter table nomad_school.attendance enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_school.guardians (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references nomad_school.students(id) on delete cascade,
  user_id uuid references auth.users(id),
  phone_enc text  -- 암호화
);
alter table nomad_school.guardians enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_school.grades (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references nomad_school.students(id) on delete cascade,
  subject text,
  term text,
  score numeric
);
alter table nomad_school.grades enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

