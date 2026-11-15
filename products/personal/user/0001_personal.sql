-- personal(꿈해몽·사주·여행) 이식 · 개인형(user안). 원본(기존): supabase/migrations/20261115000111_personal.sql + 20261116000111_personal.sql(기능 잠금)
-- 소유 = auth.users(user_id), 본인 행만. 기능 판정은 사용자의 개인 조직(owner, kind personal)의 nomad_core.org_has_feature(과금 조직과 같은 조직, astro와 같은 방식).
-- 잠김(구독 끊김·개인 조직 비활성): 읽기·쓰기 모두 잠그고 본인 전체 삭제 RPC erase_my_data만 연다(개인정보 삭제 예외). 생년월일·꿈 내용은 본인만.
-- 생년월일·풀이 입력은 앱 서버가 AES-256-GCM으로 암호화한 암호문만 저장(astro 방식, task-018). 암호문 컬럼은 authenticated 권한 없음 = 쓰기·복호화는 서버만. 풀이 결과(result_md)는 평문.
-- 사주 영역이 nomad_astro와 겹치지만 별도 제품(D4) — 서로 참조하지 않는다. 대응표: products/personal/existing.md
-- 전제: nomad_core.touch_updated_at() (core 20261119000100). 되돌림: drop schema nomad_personal cascade;
begin;

create schema nomad_personal;
revoke all on schema nomad_personal from public, anon, authenticated;
grant usage on schema nomad_personal to authenticated, service_role;

insert into nomad_core.products (code, name) values ('personal', '꿈해몽·사주·여행') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('personal', 'C', '무료'), ('personal', 'B', '프로'), ('personal', 'A', '비즈니스') on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('personal', 'divination', '꿈·사주·타로 풀이'),
  ('personal', 'report_save', '풀이 리포트 저장'),
  ('personal', 'trip_planner', '여행 계획')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('personal', 'C', 'divination'), ('personal', 'B', 'divination'), ('personal', 'A', 'divination'),
  ('personal', 'B', 'report_save'), ('personal', 'A', 'report_save'),
  ('personal', 'B', 'trip_planner'), ('personal', 'A', 'trip_planner')
on conflict do nothing;

-- 개인 조직(내부, API 역할 실행 권한 없음)
create function nomad_personal.personal_organization(p_user uuid) returns uuid
language sql stable security definer set search_path = ''
as $$
  select o.id from nomad_core.organizations o
    join nomad_core.memberships m on m.organization_id = o.id and m.user_id = p_user and m.role = 'owner'
   where o.kind = 'personal' and o.active
   order by o.created_at limit 1
$$;

-- 정책 도우미: 본인 행 + 개인 조직 이용권
create function nomad_personal.has_access(p_user uuid, p_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_user is not null and p_user = (select auth.uid())
     and coalesce(nomad_core.org_has_feature(nomad_personal.personal_organization(p_user), 'personal', p_feature), false)
$$;

-- ---------- 1. readings: 꿈·사주·타로 풀이 (입력에 꿈 내용·생년월일이 들어간다 = 민감 → 암호문) ----------
-- 암호문 형식: base64(iv 12바이트 + 암호문 + 태그 16바이트) → 최소 40자, 4의 배수. 이 CHECK는 날짜·JSON 원형만 거부한다(실제 암호화 여부는 못 본다 — 방어선은 서버 암·복호화 왕복 테스트).
create table nomad_personal.readings (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind             text not null default 'dream' constraint readings_kind_check check (kind in ('dream', 'saju', 'tarot')),
  input_ciphertext text constraint readings_input_ciphertext_check check (input_ciphertext ~ '^[A-Za-z0-9+/]{38,}={0,2}$' and char_length(input_ciphertext) % 4 = 0),
  key_version      smallint constraint readings_key_version_check check (key_version > 0),
  result_md        text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint readings_user_id_uniq unique (user_id, id),
  constraint readings_input_key_check check ((input_ciphertext is null) = (key_version is null))
);
comment on table nomad_personal.readings is '꿈·사주·타로 풀이 기록. 입력(꿈 내용·생년월일)은 서버 암호문만 — 본인만. 풀이 결과는 평문.';
comment on column nomad_personal.readings.input_ciphertext is '풀이 입력 JSON의 AES-256-GCM 암호문(앱 서버가 암·복호화, 키는 서버 비밀 저장소). 사용자 권한 없음';
comment on column nomad_personal.readings.kind is 'dream=꿈, saju=사주, tarot=타로';
create index readings_user_created_idx on nomad_personal.readings (user_id, created_at desc);
create index readings_user_updated_idx on nomad_personal.readings (user_id, updated_at);

-- ---------- 2. saved_reports: 저장한 풀이 리포트(PDF) ----------
create table nomad_personal.saved_reports (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reading_id uuid,
  pdf_path   text constraint saved_reports_pdf_path_check check (pdf_path is null or pdf_path like (user_id::text || '/personal/%')),
  created_at timestamptz not null default now(),
  constraint saved_reports_reading_fk foreign key (user_id, reading_id) references nomad_personal.readings (user_id, id) on delete cascade
);
comment on table nomad_personal.saved_reports is '저장한 풀이 리포트(PDF). 경로 <user_id>/personal/…';
create index saved_reports_user_created_idx on nomad_personal.saved_reports (user_id, created_at desc);
create index saved_reports_reading_idx on nomad_personal.saved_reports (user_id, reading_id);

-- ---------- 3. birth_profiles: 생년월일·출생시각(민감, 본인만) ----------
create table nomad_personal.birth_profiles (
  user_id          uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  birth_ciphertext text not null constraint birth_profiles_birth_ciphertext_check check (birth_ciphertext ~ '^[A-Za-z0-9+/]{38,}={0,2}$' and char_length(birth_ciphertext) % 4 = 0),
  key_version      smallint not null constraint birth_profiles_key_version_check check (key_version > 0),
  gender           text,
  updated_at       timestamptz not null default now()
);
comment on table nomad_personal.birth_profiles is '사용자별 생년월일·성별. 본인만 읽고 삭제한다. 쓰기는 서버만(암호화가 서버에서만 가능).';
comment on column nomad_personal.birth_profiles.birth_ciphertext is '생년월일·출생시각 AES-256-GCM 암호문(앱 서버가 암·복호화, 키는 서버 비밀 저장소). 사용자 권한 없음';

-- ---------- 4. trips · trip_days: 여행 계획 ----------
create table nomad_personal.trips (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title      text not null,
  start_date date,
  end_date   date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trips_dates_check check (start_date is null or end_date is null or end_date >= start_date),
  constraint trips_user_id_uniq unique (user_id, id)
);
comment on table nomad_personal.trips is '여행 계획';
create index trips_user_created_idx on nomad_personal.trips (user_id, created_at desc);
create index trips_user_updated_idx on nomad_personal.trips (user_id, updated_at);

-- 기존에는 소유 컬럼이 없었다 → user_id + 복합 FK(남의 여행에 일자를 붙일 수 없다)
create table nomad_personal.trip_days (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  trip_id    uuid not null,
  day        text,
  plan_json  jsonb,
  tools      jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trip_days_trip_fk foreign key (user_id, trip_id) references nomad_personal.trips (user_id, id) on delete cascade
);
comment on table nomad_personal.trip_days is '여행 일자별 계획. tools = 날씨·환율';
create index trip_days_trip_idx on nomad_personal.trip_days (user_id, trip_id);
create index trip_days_user_updated_idx on nomad_personal.trip_days (user_id, updated_at);

-- ---------- 5. 트리거(updated_at) ----------
do $$
declare t text;
begin
  foreach t in array array['readings', 'birth_profiles', 'trips', 'trip_days']
  loop
    execute format('create trigger %I_touch before update on nomad_personal.%I for each row execute function nomad_core.touch_updated_at()', t, t);
  end loop;
end $$;

-- ---------- 6. RLS·권한 (표 → 기능) ----------
-- 읽기·추가·수정·삭제 = has_access(user_id, 기능)로 보이는 본인 행. 잠긴 뒤 삭제는 erase_my_data
do $$
declare r record;
begin
  for r in select * from (values ('readings', 'divination'), ('saved_reports', 'report_save'), ('birth_profiles', 'divination'),
                                 ('trips', 'trip_planner'), ('trip_days', 'trip_planner')) v(t, f)
  loop
    execute format('alter table nomad_personal.%I enable row level security', r.t);
    execute format('revoke all on table nomad_personal.%I from public, anon, authenticated', r.t);
    execute format('grant all on table nomad_personal.%I to service_role', r.t);
    execute format('grant delete on table nomad_personal.%I to authenticated', r.t);
    execute format('create policy %I on nomad_personal.%I for select to authenticated using (nomad_personal.has_access(user_id, %L))', r.t || '_select', r.t, r.f);
    execute format('create policy %I on nomad_personal.%I for insert to authenticated with check (nomad_personal.has_access(user_id, %L))', r.t || '_insert', r.t, r.f);
    execute format('create policy %I on nomad_personal.%I for update to authenticated using (nomad_personal.has_access(user_id, %L)) with check (nomad_personal.has_access(user_id, %L))', r.t || '_update', r.t, r.f, r.f);
    execute format('create policy %I on nomad_personal.%I for delete to authenticated using (nomad_personal.has_access(user_id, %L))', r.t || '_delete', r.t, r.f);
  end loop;
end $$;

-- 사용자 컬럼 권한: id·user_id(기본값 auth.uid())·시각 컬럼 제외. 암호문 컬럼은 읽기·쓰기 모두 없음(서버만)
grant select (id, user_id, kind, key_version, result_md, created_at, updated_at) on nomad_personal.readings to authenticated;
grant select on nomad_personal.saved_reports, nomad_personal.trips, nomad_personal.trip_days to authenticated;
grant select (user_id, key_version, gender, updated_at) on nomad_personal.birth_profiles to authenticated;
grant insert (kind, result_md), update (kind, result_md) on nomad_personal.readings to authenticated;
grant insert (reading_id, pdf_path), update (pdf_path) on nomad_personal.saved_reports to authenticated;
grant insert (title, start_date, end_date), update (title, start_date, end_date) on nomad_personal.trips to authenticated;
grant insert (trip_id, day, plan_json, tools), update (day, plan_json, tools) on nomad_personal.trip_days to authenticated;

-- ---------- 7. 개인정보 삭제(잠김과 무관) ----------
-- 잠기면 select 정책이 행을 숨겨 직접 delete가 0행이 되므로, 본인 데이터 전체 삭제는 이 RPC로 연다(기능 잠금을 일부러 보지 않는다).
-- 반환: 지운 리포트의 pdf_path 목록 → 서버가 스토리지 파일을 정리한다.
create function nomad_personal.erase_my_data() returns setof text
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid()); v_paths text[];
begin
  if v_uid is null then raise exception 'erase_my_data: login required' using errcode = '42501'; end if;
  with d as (delete from nomad_personal.saved_reports where user_id = v_uid returning pdf_path)
  select coalesce(array_agg(d.pdf_path) filter (where d.pdf_path is not null), '{}') into v_paths from d;
  delete from nomad_personal.trip_days where user_id = v_uid;
  delete from nomad_personal.trips where user_id = v_uid;
  delete from nomad_personal.readings where user_id = v_uid;
  delete from nomad_personal.birth_profiles where user_id = v_uid;
  return query select unnest(v_paths);
end;
$$;

-- ---------- 8. 함수 권한 ----------
revoke all on all functions in schema nomad_personal from public, anon, authenticated;
grant execute on all functions in schema nomad_personal to service_role;
revoke all on function nomad_personal.personal_organization(uuid) from service_role;
grant execute on function nomad_personal.has_access(uuid, text), nomad_personal.erase_my_data() to authenticated;

commit;
