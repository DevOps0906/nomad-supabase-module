-- 꿈해몽·사주·여행(personal) · 개인형 · 원본: blueprints/user/personal/schema.draft.sql
-- 되돌림: drop schema nomad_personal cascade; delete from nomad_core.products where code = 'personal';
begin;

create schema nomad_personal;
revoke all on schema nomad_personal from public, anon, authenticated;
grant usage on schema nomad_personal to authenticated, service_role;

insert into nomad_core.products (code, name) values ('personal', '꿈해몽·사주·여행');

create table nomad_personal.readings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null default 'dream' check (kind in ('dream','saju','tarot')),
  input_json jsonb,
  result_md text,
  created_at timestamptz not null default now(),
  unique (user_id, id)
);

create table nomad_personal.saved_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reading_id uuid,
  pdf_path text,
  created_at timestamptz not null default now(),
  foreign key (user_id, reading_id) references nomad_personal.readings(user_id, id) on delete cascade
);

create table nomad_personal.birth_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  birth_date date,  -- 암호화
  birth_time text,  -- 암호화
  gender text
);

create table nomad_personal.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  start_date date,
  end_date date,
  created_at timestamptz not null default now(),
  unique (user_id, id)
);

create table nomad_personal.trip_days (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid references nomad_personal.trips(id) on delete cascade,
  day text,
  plan_json jsonb,
  tools jsonb,  -- 날씨·환율
  created_at timestamptz not null default now()
);

comment on table nomad_personal.readings is '꿈·사주·타로 풀이 기록';
comment on table nomad_personal.saved_reports is '저장한 풀이 리포트(PDF)';
comment on table nomad_personal.birth_profiles is '사용자별 생년월일·성별(암호화 대상)';
comment on table nomad_personal.trips is '여행 계획';
comment on table nomad_personal.trip_days is '여행 일자별 계획';
comment on column nomad_personal.birth_profiles.birth_date is '평문 저장. 암호화는 앱·서버 책임(이 마이그레이션은 암호화하지 않음)';
comment on column nomad_personal.birth_profiles.birth_time is '평문 저장. 암호화는 앱·서버 책임(이 마이그레이션은 암호화하지 않음)';
comment on column nomad_personal.readings.kind is 'dream=꿈, saju=사주, tarot=타로';

create index readings_user_created_idx on nomad_personal.readings (user_id, created_at desc);
create index saved_reports_user_created_idx on nomad_personal.saved_reports (user_id, created_at desc);
create index saved_reports_reading_idx on nomad_personal.saved_reports (user_id, reading_id);
create index trips_user_created_idx on nomad_personal.trips (user_id, created_at desc);
create index trip_days_trip_idx on nomad_personal.trip_days (trip_id);

alter table nomad_personal.readings enable row level security;
alter table nomad_personal.saved_reports enable row level security;
alter table nomad_personal.birth_profiles enable row level security;
alter table nomad_personal.trips enable row level security;
alter table nomad_personal.trip_days enable row level security;

create policy readings_select on nomad_personal.readings for select to authenticated using ((select auth.uid()) = user_id);
create policy readings_insert on nomad_personal.readings for insert to authenticated with check ((select auth.uid()) = user_id);
create policy readings_update on nomad_personal.readings for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy readings_delete on nomad_personal.readings for delete to authenticated using ((select auth.uid()) = user_id);

create policy saved_reports_select on nomad_personal.saved_reports for select to authenticated using ((select auth.uid()) = user_id);
create policy saved_reports_insert on nomad_personal.saved_reports for insert to authenticated with check ((select auth.uid()) = user_id);
create policy saved_reports_update on nomad_personal.saved_reports for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy saved_reports_delete on nomad_personal.saved_reports for delete to authenticated using ((select auth.uid()) = user_id);

create policy birth_profiles_select on nomad_personal.birth_profiles for select to authenticated using ((select auth.uid()) = user_id);
create policy birth_profiles_insert on nomad_personal.birth_profiles for insert to authenticated with check ((select auth.uid()) = user_id);
create policy birth_profiles_update on nomad_personal.birth_profiles for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy birth_profiles_delete on nomad_personal.birth_profiles for delete to authenticated using ((select auth.uid()) = user_id);

create policy trips_select on nomad_personal.trips for select to authenticated using ((select auth.uid()) = user_id);
create policy trips_insert on nomad_personal.trips for insert to authenticated with check ((select auth.uid()) = user_id);
create policy trips_update on nomad_personal.trips for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy trips_delete on nomad_personal.trips for delete to authenticated using ((select auth.uid()) = user_id);

create policy trip_days_select on nomad_personal.trip_days for select to authenticated
  using (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())));
create policy trip_days_insert on nomad_personal.trip_days for insert to authenticated
  with check (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())));
create policy trip_days_update on nomad_personal.trip_days for update to authenticated
  using (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())))
  with check (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())));
create policy trip_days_delete on nomad_personal.trip_days for delete to authenticated
  using (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())));

revoke all on all tables in schema nomad_personal from public, anon, authenticated;
grant all on all tables in schema nomad_personal to service_role;
grant select, insert, delete on all tables in schema nomad_personal to authenticated;
grant update (kind, input_json, result_md) on nomad_personal.readings to authenticated;
grant update (pdf_path) on nomad_personal.saved_reports to authenticated;
grant update (birth_date, birth_time, gender) on nomad_personal.birth_profiles to authenticated;
grant update (title, start_date, end_date) on nomad_personal.trips to authenticated;
grant update (day, plan_json, tools) on nomad_personal.trip_days to authenticated;

commit;
