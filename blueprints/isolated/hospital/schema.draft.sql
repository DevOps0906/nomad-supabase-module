-- hospital · 별도 Supabase 프로젝트 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 격리형(별도 Supabase 프로젝트)

-- 이 파일은 별도 Supabase 프로젝트(B)에 적용합니다. core 스키마가 없습니다.
create schema if not exists nomad_hospital;
revoke all on schema nomad_hospital from public, anon, authenticated;
grant usage on schema nomad_hospital to authenticated, service_role;

create table nomad_hospital.patients (
  id uuid primary key default gen_random_uuid(),
  name_enc text,  -- 암호화
  birth_enc text,  -- 암호화
  phone_enc text,  -- 암호화
  consent_at timestamptz  -- 동의 일시
);
alter table nomad_hospital.patients enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_hospital.staff (
  user_id uuid primary key,
  role text,  -- 의사·간호·접수
  dept text
);
alter table nomad_hospital.staff enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_hospital.appointments (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid references nomad_hospital.patients(id) on delete cascade,
  staff_id uuid references nomad_hospital.staff(user_id) on delete cascade,
  "at" timestamptz,
  status text
);
alter table nomad_hospital.appointments enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_hospital.records (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid references nomad_hospital.patients(id) on delete cascade,
  staff_id uuid references nomad_hospital.staff(user_id) on delete cascade,
  note_enc text,  -- 암호화
  created_at timestamptz
);
alter table nomad_hospital.records enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)

create table nomad_hospital.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  action text,  -- 열람·수정
  target text,
  "at" timestamptz
);
alter table nomad_hospital.audit_logs enable row level security;
-- TODO: 역할별 정책 작성 (현재 기본 거부)


grant select, insert, update, delete on all tables in schema nomad_hospital to authenticated;
