-- school · 별도 Supabase 프로젝트 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 격리형(별도 Supabase 프로젝트)

-- 이 파일은 별도 Supabase 프로젝트(B)에 적용합니다. core 스키마가 없습니다.
create schema if not exists school;

create table school.teachers (
  user_id uuid primary key,
  subject text,
  role text  -- 담임·교과
);
alter table school.teachers enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table school.classes (
  id uuid primary key default gen_random_uuid(),
  name text,
  grade numeric,
  homeroom_id uuid references school.teachers(user_id) on delete cascade
);
alter table school.classes enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table school.students (
  id uuid primary key default gen_random_uuid(),
  class_id uuid references school.classes(id) on delete cascade,
  name_enc text,  -- 암호화
  birth_enc text  -- 암호화
);
alter table school.students enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table school.attendance (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references school.students(id) on delete cascade,
  date date,
  status text  -- 출석·결석·지각
);
alter table school.attendance enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table school.guardians (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references school.students(id) on delete cascade,
  user_id uuid references auth.users(id),
  phone_enc text  -- 암호화
);
alter table school.guardians enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table school.grades (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references school.students(id) on delete cascade,
  subject text,
  term text,
  score numeric
);
alter table school.grades enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

