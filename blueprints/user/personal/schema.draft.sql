-- personal · 개인형 (개인 AI 서비스 묶음) · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 개인형(user_id 기준)

create schema if not exists nomad_personal;
revoke all on schema nomad_personal from public, anon, authenticated;
grant usage on schema nomad_personal to authenticated, service_role;

create table nomad_personal.readings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references nomad_core.profiles(user_id),
  kind text,  -- 꿈·사주·타로
  input_json jsonb,
  result_md text,
  created_at timestamptz not null default now()
);
alter table nomad_personal.readings enable row level security;
create policy readings_own on nomad_personal.readings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_personal.saved_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references nomad_core.profiles(user_id),
  reading_id uuid references nomad_personal.readings(id) on delete cascade,
  pdf_path text,
  created_at timestamptz not null default now()
);
alter table nomad_personal.saved_reports enable row level security;
create policy saved_reports_own on nomad_personal.saved_reports for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_personal.birth_profiles (
  user_id uuid primary key,
  birth_date date,  -- 암호화
  birth_time text,  -- 암호화
  gender text
);
alter table nomad_personal.birth_profiles enable row level security;
create policy birth_profiles_own on nomad_personal.birth_profiles for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_personal.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references nomad_core.profiles(user_id),
  title text,
  start_date date,
  end_date date,
  created_at timestamptz not null default now()
);
alter table nomad_personal.trips enable row level security;
create policy trips_own on nomad_personal.trips for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_personal.trip_days (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references nomad_personal.trips(id) on delete cascade,
  day text,
  plan_json jsonb,
  tools jsonb,  -- 날씨·환율
  created_at timestamptz not null default now()
);
alter table nomad_personal.trip_days enable row level security;
create policy trip_days_own_via_trips on nomad_personal.trip_days for all using (exists (select 1 from nomad_personal.trips p where p.id = trip_id and (p.user_id = auth.uid())));


grant select, insert, update, delete on all tables in schema nomad_personal to authenticated;
