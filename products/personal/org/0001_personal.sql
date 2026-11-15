-- personal(꿈해몽·사주·여행) 이식 · 조직형(org안). 원본(기존): supabase/migrations/20261115000111_personal.sql + 20261116000111_personal.sql(기능 잠금)
-- user_id → organization_id + created_by(작성자). 기능 판정 nomad_core.has_feature(조직, 'personal', 기능) — 멤버·활성 조직·구독(없으면 C) 포함.
-- 민감(풀이·리포트·생년월일): 읽기·쓰기·삭제는 작성자 본인만(멤버이고 이용권이 있을 때). owner/admin은 열람 없이 erase_personal_data로 탈퇴자 것만 삭제.
-- 여행(trips·trip_days): 조직 공유 — 멤버 읽기, owner/admin/editor 쓰기. 잠김(구독 끊김·조직 비활성)이면 모두 잠그고 erase_personal_data(개인정보 삭제)만 연다.
-- 사주 영역이 nomad_astro와 겹치지만 별도 제품(D4). 대응표: products/personal/existing.md
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

-- ---------- 1. readings: 꿈·사주·타로 풀이 (작성자만) ----------
create table nomad_personal.readings (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  created_by      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind            text not null default 'dream' constraint readings_kind_check check (kind in ('dream', 'saju', 'tarot')),
  input_json      jsonb,
  result_md       text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint readings_org_author_id_uniq unique (organization_id, created_by, id)
);
comment on table nomad_personal.readings is '꿈·사주·타로 풀이 기록. input_json(꿈 내용 등)은 민감정보 — 작성자만 열람.';
comment on column nomad_personal.readings.kind is 'dream=꿈, saju=사주, tarot=타로';
create index readings_org_author_created_idx on nomad_personal.readings (organization_id, created_by, created_at desc);
create index readings_org_updated_idx on nomad_personal.readings (organization_id, updated_at);
create index readings_author_idx on nomad_personal.readings (created_by);

-- ---------- 2. saved_reports: 리포트(PDF). 같은 조직·같은 작성자의 풀이만 참조(복합 FK) ----------
create table nomad_personal.saved_reports (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  created_by      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reading_id      uuid,
  pdf_path        text constraint saved_reports_pdf_path_check check (pdf_path is null or pdf_path like (organization_id::text || '/personal/' || created_by::text || '/%')),
  created_at      timestamptz not null default now(),
  constraint saved_reports_reading_fk foreign key (organization_id, created_by, reading_id)
    references nomad_personal.readings (organization_id, created_by, id) on delete cascade
);
comment on table nomad_personal.saved_reports is '저장한 풀이 리포트(PDF). 경로 <organization_id>/personal/<created_by>/…(서버만 기록), 작성자만 열람.';
create index saved_reports_org_author_created_idx on nomad_personal.saved_reports (organization_id, created_by, created_at desc);
create index saved_reports_reading_idx on nomad_personal.saved_reports (organization_id, created_by, reading_id);
create index saved_reports_author_idx on nomad_personal.saved_reports (created_by);

-- ---------- 3. birth_profiles: 조직 안 사용자별 생년월일(본인만) ----------
create table nomad_personal.birth_profiles (
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  birth_date      date,
  birth_time      text,
  gender          text,
  updated_at      timestamptz not null default now(),
  primary key (organization_id, user_id)
);
comment on table nomad_personal.birth_profiles is '조직 안 사용자별 생년월일·성별. 본인만 읽고 쓴다(owner/admin은 삭제만).';
comment on column nomad_personal.birth_profiles.birth_date is '평문 저장. 암호화는 앱·서버 책임(이 마이그레이션은 암호화하지 않음)';
comment on column nomad_personal.birth_profiles.birth_time is '평문 저장. 암호화는 앱·서버 책임(이 마이그레이션은 암호화하지 않음)';
create index birth_profiles_user_idx on nomad_personal.birth_profiles (user_id);

-- ---------- 4. trips · trip_days: 여행 계획(조직 공유) ----------
create table nomad_personal.trips (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  created_by      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title           text not null,
  start_date      date,
  end_date        date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint trips_dates_check check (start_date is null or end_date is null or end_date >= start_date),
  constraint trips_org_id_uniq unique (organization_id, id)
);
comment on table nomad_personal.trips is '여행 계획(조직 공유)';
create index trips_org_created_idx on nomad_personal.trips (organization_id, created_at desc);
create index trips_org_updated_idx on nomad_personal.trips (organization_id, updated_at);
create index trips_author_idx on nomad_personal.trips (created_by);

create table nomad_personal.trip_days (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  trip_id         uuid not null,
  day             text,
  plan_json       jsonb,
  tools           jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint trip_days_trip_fk foreign key (organization_id, trip_id) references nomad_personal.trips (organization_id, id) on delete cascade
);
comment on table nomad_personal.trip_days is '여행 일자별 계획. tools = 날씨·환율';
create index trip_days_trip_idx on nomad_personal.trip_days (organization_id, trip_id);
create index trip_days_org_updated_idx on nomad_personal.trip_days (organization_id, updated_at);

-- ---------- 5. 트리거(updated_at) ----------
do $$
declare t text;
begin
  foreach t in array array['readings', 'birth_profiles', 'trips', 'trip_days']
  loop
    execute format('create trigger %I_touch before update on nomad_personal.%I for each row execute function nomad_core.touch_updated_at()', t, t);
  end loop;
end $$;

-- ---------- 6. RLS·권한 ----------
do $$
declare t text;
begin
  foreach t in array array['readings', 'saved_reports', 'birth_profiles', 'trips', 'trip_days']
  loop
    execute format('alter table nomad_personal.%I enable row level security', t);
    execute format('revoke all on table nomad_personal.%I from public, anon, authenticated', t);
    execute format('grant all on table nomad_personal.%I to service_role', t);
    execute format('grant select, delete on table nomad_personal.%I to authenticated', t);
  end loop;
end $$;

-- 6.1 민감 표(작성자 본인만): 읽기·추가·수정·삭제 = 본인 + 이용권. 잠긴 뒤·남의 데이터 삭제는 erase_personal_data
do $$
declare r record;
begin
  for r in select * from (values ('readings', 'created_by', 'divination'), ('saved_reports', 'created_by', 'report_save'),
                                 ('birth_profiles', 'user_id', 'divination')) v(t, c, f)
  loop
    execute format('create policy %I on nomad_personal.%I for select to authenticated using (%I = (select auth.uid()) and nomad_core.has_feature(organization_id, ''personal'', %L))',
                   r.t || '_select', r.t, r.c, r.f);
    execute format('create policy %I on nomad_personal.%I for insert to authenticated with check (%I = (select auth.uid()) and nomad_core.has_feature(organization_id, ''personal'', %L))',
                   r.t || '_insert', r.t, r.c, r.f);
    execute format('create policy %I on nomad_personal.%I for update to authenticated using (%I = (select auth.uid()) and nomad_core.has_feature(organization_id, ''personal'', %L)) with check (%I = (select auth.uid()) and nomad_core.has_feature(organization_id, ''personal'', %L))',
                   r.t || '_update', r.t, r.c, r.f, r.c, r.f);
    execute format('create policy %I on nomad_personal.%I for delete to authenticated using (%I = (select auth.uid()) and nomad_core.has_feature(organization_id, ''personal'', %L))',
                   r.t || '_delete', r.t, r.c, r.f);
  end loop;
end $$;

-- 6.2 여행(조직 공유): 읽기 = 멤버 + 이용권, 쓰기·삭제 = owner/admin/editor + 이용권
do $$
declare t text;
begin
  foreach t in array array['trips', 'trip_days']
  loop
    execute format('create policy %I on nomad_personal.%I for select to authenticated using (nomad_core.has_feature(organization_id, ''personal'', ''trip_planner''))', t || '_select', t);
    execute format('create policy %I on nomad_personal.%I for insert to authenticated with check (nomad_core.has_feature(organization_id, ''personal'', ''trip_planner'') and nomad_core.organization_role(organization_id) in (''owner'', ''admin'', ''editor''))', t || '_insert', t);
    execute format('create policy %I on nomad_personal.%I for update to authenticated using (nomad_core.has_feature(organization_id, ''personal'', ''trip_planner'') and nomad_core.organization_role(organization_id) in (''owner'', ''admin'', ''editor'')) with check (nomad_core.has_feature(organization_id, ''personal'', ''trip_planner'') and nomad_core.organization_role(organization_id) in (''owner'', ''admin'', ''editor''))', t || '_update', t);
    execute format('create policy %I on nomad_personal.%I for delete to authenticated using (nomad_core.has_feature(organization_id, ''personal'', ''trip_planner'') and nomad_core.organization_role(organization_id) in (''owner'', ''admin'', ''editor''))', t || '_delete', t);
  end loop;
end $$;
-- trips 작성자는 실제 호출자만(위조 금지)
alter policy trips_insert on nomad_personal.trips
  with check (created_by = (select auth.uid()) and nomad_core.has_feature(organization_id, 'personal', 'trip_planner')
              and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));

-- 사용자 컬럼 권한: id·작성자(기본값 auth.uid())·시각 컬럼 제외, 조직·부모 참조는 추가 때만
grant insert (organization_id, kind, input_json, result_md), update (kind, input_json, result_md) on nomad_personal.readings to authenticated;
-- saved_reports.pdf_path는 서버(PDF 생성)만 기록한다(사용자 권한 없음 — 같은 조직 다른 작성자 경로 지정 차단)
grant insert (organization_id, reading_id) on nomad_personal.saved_reports to authenticated;
grant insert (organization_id, birth_date, birth_time, gender), update (birth_date, birth_time, gender) on nomad_personal.birth_profiles to authenticated;
grant insert (organization_id, title, start_date, end_date), update (title, start_date, end_date) on nomad_personal.trips to authenticated;
grant insert (organization_id, trip_id, day, plan_json, tools), update (day, plan_json, tools) on nomad_personal.trip_days to authenticated;

-- ---------- 7. 개인정보 삭제(잠김과 무관) ----------
-- 잠기면 select 정책이 행을 숨겨 직접 delete가 0행이 되므로 이 RPC로 연다(기능 잠금을 일부러 보지 않는다).
-- 대상 = 조직 안 한 사람의 민감 표(풀이·리포트·생년월일). 본인 것은 멤버가 아니어도(탈퇴 후) 지울 수 있고,
-- 남의 것은 활성 조직의 owner/admin이 탈퇴자(비멤버)만(현직 멤버면 42501, 열람 없이 삭제, 감사 기록). 서버(service_role)는 대상 제한 없음.
-- 여행은 조직 공유 자료라 대상이 아니다. 반환: 지운 리포트의 pdf_path 목록 → 서버가 스토리지 파일을 정리한다.
create function nomad_personal.erase_personal_data(p_organization uuid, p_user uuid default null) returns setof text
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid()); v_target uuid := coalesce(p_user, (select auth.uid())); v_paths text[];
begin
  if p_organization is null or v_target is null then
    raise exception 'erase_personal_data: organization and user required' using errcode = '22023';
  end if;
  if not nomad_core.is_service_caller() then
    if v_uid is null then raise exception 'erase_personal_data: login required' using errcode = '42501'; end if;
    if v_target <> v_uid then
      if coalesce(nomad_core.organization_role(p_organization) in ('owner', 'admin'), false) is false then
        raise exception 'erase_personal_data: owner or admin only' using errcode = '42501';
      end if;
      if exists (select 1 from nomad_core.memberships m where m.organization_id = p_organization and m.user_id = v_target) then
        raise exception 'erase_personal_data: target is a current member' using errcode = '42501';
      end if;
    end if;
  end if;
  with d as (delete from nomad_personal.saved_reports where organization_id = p_organization and created_by = v_target returning pdf_path)
  select coalesce(array_agg(d.pdf_path) filter (where d.pdf_path is not null), '{}') into v_paths from d;
  delete from nomad_personal.readings where organization_id = p_organization and created_by = v_target;
  delete from nomad_personal.birth_profiles where organization_id = p_organization and user_id = v_target;
  if v_target is distinct from v_uid then
    perform nomad_core.write_audit(p_organization, 'personal.erase', 'user', v_target::text, null, null, jsonb_build_object('result', 'erased'));
  end if;
  return query select unnest(v_paths);
end;
$$;

revoke all on all functions in schema nomad_personal from public, anon, authenticated;
grant execute on all functions in schema nomad_personal to service_role;
grant execute on function nomad_personal.erase_personal_data(uuid, uuid) to authenticated;

commit;
