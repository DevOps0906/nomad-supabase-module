-- =====================================================================
-- hospital 격리형 0001_hospital.sql (task-008, 2026-11-15 결정 반영)
-- 병원 CRM(예약·연락·상담 메모). EMR 아님: 검사·수납·처방 표는 두지 않는다.
-- 별도 Supabase 프로젝트 전용. 공용 프로젝트 스키마·플랜·기능 잠금과 연결하지 않는다(auth·vault·extensions 만 참조).
--
-- 접근 경로: 서버 전용. 브라우저 직접 접근 없음.
--   - anon·authenticated: 스키마·표·함수 권한 0.
--   - service_role(앱 서버): 표 직접 권한 0, API 함수 EXECUTE 만.
--   - API 함수는 security definer + search_path ''. 첫 인자 p_actor(앱 서버가 보증한 직원 user_id)를
--     함수마다 다시 확인한다(활성 직원 + 역할). 열람 함수는 같은 트랜잭션에서 audit_logs 에 행을 남긴다(VOLATILE).
-- 담당 판정: care_assignments(관리자만 배정) — 예약 기반 판정이 아니므로 자가 배정 불가, 간호사도 배정으로 포함.
-- 삭제: 모든 FK on delete restrict. 퇴사는 deactivate_staff(비활성). 감사 로그 행위자는 스냅샷(이름·역할, FK 없음).
-- 암호화: 이름·전화·생년월일·메모 본문은 앱이 암호화한 암호문(text)만 저장. 주민등록번호 컬럼 없음.
--   정확 일치 검색용 HMAC 은 DB 함수가 Vault 비밀(nomad_hospital_hmac_v<N>, 가장 큰 N)로 계산. 키 없으면 오류(fail-closed).
-- 보존: retention_policies(법무 확인 전 초안, legal_review_pending=true 면 파기 거부). 기간 전 파기 거부, 기간 후 list_purge_candidates + purge_record(관리자, 감사).
-- SQLSTATE: HP001 행위자 없음·비활성 · HP002 HMAC 키 없음 · HP003 보존 기간 전 파기 · HP004 bootstrap 완료됨 · HP005 보존 기간 법무 확인 전 · 42501 권한·담당·append-only · 22023 입력
-- =====================================================================
begin;

create schema nomad_hospital;
revoke all on schema nomad_hospital from public, anon, authenticated;
grant usage on schema nomad_hospital to service_role;

-- ---------------------------------------------------------------------
-- 1. 표 (전부 RLS 활성 + 정책 없음 = 함수 경로 외 전면 거부)
-- ---------------------------------------------------------------------
create table nomad_hospital.staff (
  user_id        uuid primary key references auth.users (id) on delete restrict,
  display_name   text not null check (char_length(btrim(display_name)) between 1 and 100),
  role           text not null check (role in ('doctor', 'nurse', 'reception', 'admin')),
  dept           text check (dept is null or char_length(dept) <= 100),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  deactivated_at timestamptz
);
comment on table nomad_hospital.staff is '직원(역할). 퇴사는 active=false, 삭제하지 않는다.';
alter table nomad_hospital.staff enable row level security;

create table nomad_hospital.bootstrap_state (
  singleton    boolean primary key default true check (singleton),
  admin_id     uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  completed_at timestamptz not null default now()
);
comment on table nomad_hospital.bootstrap_state is '첫 관리자 bootstrap 완료 표시(단일 행).';
alter table nomad_hospital.bootstrap_state enable row level security;

create table nomad_hospital.patients (
  id               uuid primary key default gen_random_uuid(),
  name_enc         text not null,
  phone_enc        text,
  birth_enc        text,
  name_hash        text not null,
  phone_hash       text,
  hash_key_version integer not null check (hash_key_version > 0),
  consent_at       timestamptz,
  created_by       uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  created_at       timestamptz not null default now()
);
comment on table nomad_hospital.patients is '환자 기본 정보. 본문은 앱 암호문, 검색은 HMAC 정확 일치만.';
alter table nomad_hospital.patients enable row level security;
create index patients_name_hash_idx on nomad_hospital.patients (name_hash);
create index patients_phone_hash_idx on nomad_hospital.patients (phone_hash);
create index patients_created_by_idx on nomad_hospital.patients (created_by);

create table nomad_hospital.care_assignments (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references nomad_hospital.patients (id) on delete restrict,
  staff_id    uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  assigned_by uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  assigned_at timestamptz not null default now(),
  ended_at    timestamptz
);
comment on table nomad_hospital.care_assignments is '담당 관계(의사·간호사). 관리자만 배정·종료.';
alter table nomad_hospital.care_assignments enable row level security;
create unique index care_assignments_active_uq on nomad_hospital.care_assignments (patient_id, staff_id) where ended_at is null;
create index care_assignments_staff_idx on nomad_hospital.care_assignments (staff_id, patient_id) where ended_at is null;
create index care_assignments_assigned_by_idx on nomad_hospital.care_assignments (assigned_by);

create table nomad_hospital.appointments (
  id           uuid primary key default gen_random_uuid(),
  patient_id   uuid not null references nomad_hospital.patients (id) on delete restrict,
  staff_id     uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  scheduled_at timestamptz not null,
  status       text not null default 'booked' check (status in ('booked', 'checked_in', 'done', 'canceled', 'no_show')),
  created_by   uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table nomad_hospital.appointments is '예약. 접수·관리자가 관리.';
alter table nomad_hospital.appointments enable row level security;
create index appointments_patient_idx on nomad_hospital.appointments (patient_id);
create index appointments_staff_idx on nomad_hospital.appointments (staff_id);
create index appointments_scheduled_idx on nomad_hospital.appointments (scheduled_at);
create index appointments_created_by_idx on nomad_hospital.appointments (created_by);

create table nomad_hospital.contact_logs (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references nomad_hospital.patients (id) on delete restrict,
  channel     text not null check (channel in ('phone', 'sms', 'email', 'visit')),
  summary_enc text not null,
  created_by  uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  created_at  timestamptz not null default now()
);
comment on table nomad_hospital.contact_logs is '연락 기록(append-only). 요약은 앱 암호문.';
alter table nomad_hospital.contact_logs enable row level security;
create index contact_logs_patient_idx on nomad_hospital.contact_logs (patient_id);
create index contact_logs_created_by_idx on nomad_hospital.contact_logs (created_by);

create table nomad_hospital.consult_notes (
  id         uuid primary key default gen_random_uuid(),
  patient_id uuid not null references nomad_hospital.patients (id) on delete restrict,
  author_id  uuid not null references nomad_hospital.staff (user_id) on delete restrict,
  note_enc   text not null,
  amends_id  uuid references nomad_hospital.consult_notes (id) on delete restrict,
  created_at timestamptz not null default now()
);
comment on table nomad_hospital.consult_notes is '상담(진료) 메모. append-only, 정정은 amends_id 로 새 행. 본문은 앱 암호문.';
alter table nomad_hospital.consult_notes enable row level security;
create index consult_notes_patient_idx on nomad_hospital.consult_notes (patient_id);
create index consult_notes_author_idx on nomad_hospital.consult_notes (author_id);
create index consult_notes_amends_idx on nomad_hospital.consult_notes (amends_id);

create table nomad_hospital.audit_logs (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor_id     uuid,
  actor_name   text,
  actor_role   text,
  action       text not null,
  target_table text,
  target_id    text,
  patient_id   uuid,
  purpose      text,
  row_count    integer,
  detail       jsonb not null default '{}'::jsonb
);
comment on table nomad_hospital.audit_logs is '감사 로그(append-only, TRUNCATE 차단). 행위자는 스냅샷이라 FK 없음.';
alter table nomad_hospital.audit_logs enable row level security;
create index audit_logs_at_idx on nomad_hospital.audit_logs (at);
create index audit_logs_actor_idx on nomad_hospital.audit_logs (actor_id);
create index audit_logs_patient_idx on nomad_hospital.audit_logs (patient_id);

create table nomad_hospital.retention_policies (
  record_kind          text primary key check (record_kind in ('consult_note', 'contact_log', 'appointment')),
  retain_years         integer not null check (retain_years > 0),
  legal_basis          text not null,
  legal_review_pending boolean not null default true
);
comment on table nomad_hospital.retention_policies is '기록 종류별 보존 기간(초안, 법무 확인 필요). 변경은 새 마이그레이션으로.';
alter table nomad_hospital.retention_policies enable row level security;
insert into nomad_hospital.retention_policies (record_kind, retain_years, legal_basis) values
  ('consult_note', 10, '의료법 시행규칙 제15조 진료기록부 10년 준용(초안, 법무 확인 필요)'),
  ('appointment', 5, '의료법 시행규칙 제15조 환자 명부 5년 준용(초안, 법무 확인 필요)'),
  ('contact_log', 3, '개인정보 보호법 제21조 목적 달성 후 파기, 내부 기준 3년(초안, 법무 확인 필요)');

-- ---------------------------------------------------------------------
-- 2. 보호 트리거 (append-only · TRUNCATE 차단)
-- ---------------------------------------------------------------------
create function nomad_hospital.tg_append_only()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and tg_table_name <> 'audit_logs'
     and current_setting('nomad_hospital.allow_purge', true) = 'on' then
    return old;
  end if;
  raise exception '%.% is append-only (%)', tg_table_schema, tg_table_name, tg_op using errcode = '42501';
end $$;

create function nomad_hospital.tg_block_truncate()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception '%.% truncate is not allowed', tg_table_schema, tg_table_name using errcode = '42501';
end $$;

create trigger consult_notes_append_only before update or delete on nomad_hospital.consult_notes
  for each row execute function nomad_hospital.tg_append_only();
create trigger contact_logs_append_only before update or delete on nomad_hospital.contact_logs
  for each row execute function nomad_hospital.tg_append_only();
create trigger audit_logs_append_only before update or delete on nomad_hospital.audit_logs
  for each row execute function nomad_hospital.tg_append_only();
create trigger audit_logs_no_truncate before truncate on nomad_hospital.audit_logs
  for each statement execute function nomad_hospital.tg_block_truncate();
create trigger consult_notes_no_truncate before truncate on nomad_hospital.consult_notes
  for each statement execute function nomad_hospital.tg_block_truncate();
create trigger contact_logs_no_truncate before truncate on nomad_hospital.contact_logs
  for each statement execute function nomad_hospital.tg_block_truncate();

-- ---------------------------------------------------------------------
-- 3. 내부 도우미 (EXECUTE 권한 없음, definer 함수 안에서만)
-- ---------------------------------------------------------------------
-- 행위자 확인: 활성 직원 + 허용 역할
create function nomad_hospital._actor(p_actor uuid, p_roles text[])
returns nomad_hospital.staff
language plpgsql stable security definer set search_path = '' as $$
declare s nomad_hospital.staff;
begin
  select * into s from nomad_hospital.staff where user_id = p_actor;
  if p_actor is null or s.user_id is null or not s.active then
    raise exception 'actor is not an active staff member' using errcode = 'HP001';
  end if;
  if not (s.role = any (p_roles)) then
    raise exception 'role % not allowed', s.role using errcode = '42501';
  end if;
  return s;
end $$;

create function nomad_hospital._is_assigned(p_staff uuid, p_patient uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from nomad_hospital.care_assignments a
                 where a.staff_id = p_staff and a.patient_id = p_patient and a.ended_at is null);
$$;

-- 환자 범위: 접수·관리자 = 전체, 의사·간호 = 담당만
create function nomad_hospital._require_patient(p_actor nomad_hospital.staff, p_patient uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from nomad_hospital.patients where id = p_patient) then
    raise exception 'patient not found' using errcode = '22023';
  end if;
  if p_actor.role in ('doctor', 'nurse') and not nomad_hospital._is_assigned(p_actor.user_id, p_patient) then
    raise exception 'patient is not assigned to actor' using errcode = '42501';
  end if;
end $$;

create function nomad_hospital._check_purpose(p_purpose text)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if coalesce(p_purpose, '') not in ('treatment', 'reception', 'admin_review', 'patient_request') then
    raise exception 'purpose must be one of treatment/reception/admin_review/patient_request' using errcode = '22023';
  end if;
end $$;

create function nomad_hospital._audit(
  p_actor nomad_hospital.staff, p_action text, p_table text, p_target text,
  p_patient uuid, p_purpose text, p_rows integer, p_detail jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into nomad_hospital.audit_logs (actor_id, actor_name, actor_role, action, target_table, target_id, patient_id, purpose, row_count, detail)
  values (p_actor.user_id, p_actor.display_name, p_actor.role, p_action, p_table, p_target, p_patient, p_purpose, p_rows, coalesce(p_detail, '{}'::jsonb));
end $$;

-- 정규화: 전화 = 숫자만, 국가번호(+82·82·(+82)·0082) → 0, 앞자리 0 반복은 0 하나(+82 010 → 010)
--         이름 = NFKC + 소문자 + 공백·폭 없는 문자(U+200B~200D·2060·FEFF) 제거
create function nomad_hospital._normalize(p_kind text, p_value text)
returns text language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  if p_kind = 'phone' then
    v := regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');
    v := regexp_replace(v, '^(00)?82', '0');
    v := regexp_replace(v, '^0+', '0');
  elsif p_kind = 'name' then
    v := regexp_replace(lower(normalize(coalesce(p_value, ''), NFKC)), '[[:space:]​‌‍⁠﻿]', '', 'g');
  else
    raise exception 'unknown kind %', p_kind using errcode = '22023';
  end if;
  if v = '' or v = '0' then
    raise exception 'empty % after normalization', p_kind using errcode = '22023';
  end if;
  return v;
end $$;

-- 현재 HMAC 키(가장 큰 버전). 없으면 오류.
create function nomad_hospital._hmac_key(out key_version integer, out key text)
language plpgsql stable security definer set search_path = '' as $$
begin
  select substring(s.name from '^nomad_hospital_hmac_v([0-9]+)$')::integer, s.decrypted_secret
    into key_version, key
    from vault.decrypted_secrets s
   where s.name ~ '^nomad_hospital_hmac_v[0-9]+$'
   order by substring(s.name from '^nomad_hospital_hmac_v([0-9]+)$')::integer desc
   limit 1;
  if key is null or key = '' then
    raise exception 'HMAC key is not configured in vault' using errcode = 'HP002';
  end if;
end $$;

create function nomad_hospital._hmac(p_kind text, p_value text, p_key text)
returns text language sql immutable set search_path = '' as $$
  select encode(extensions.hmac(p_kind || ':' || nomad_hospital._normalize(p_kind, p_value), p_key, 'sha256'), 'hex');
$$;

-- ---------------------------------------------------------------------
-- 4. API 함수 (service_role EXECUTE)
-- ---------------------------------------------------------------------
-- 4.1 첫 관리자: 설치 스크립트가 1회 호출. 이미 있으면 HP004.
create function nomad_hospital.bootstrap_admin(p_user_id uuid, p_display_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare s nomad_hospital.staff;
begin
  perform pg_advisory_xact_lock(hashtext('nomad_hospital.bootstrap_admin'));
  if exists (select 1 from nomad_hospital.bootstrap_state) or exists (select 1 from nomad_hospital.staff) then
    raise exception 'bootstrap already completed' using errcode = 'HP004';
  end if;
  insert into nomad_hospital.staff (user_id, display_name, role) values (p_user_id, p_display_name, 'admin')
  returning * into s;
  insert into nomad_hospital.bootstrap_state (admin_id) values (p_user_id);
  perform nomad_hospital._audit(s, 'staff.bootstrap', 'staff', p_user_id::text, null, null, 1);
end $$;

-- 4.2 직원 (관리자)
create function nomad_hospital.add_staff(p_actor uuid, p_user_id uuid, p_display_name text, p_role text, p_dept text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
begin
  insert into nomad_hospital.staff (user_id, display_name, role, dept) values (p_user_id, p_display_name, p_role, p_dept);
  perform nomad_hospital._audit(a, 'staff.add', 'staff', p_user_id::text, null, null, 1, jsonb_build_object('role', p_role));
end $$;

create function nomad_hospital.deactivate_staff(p_actor uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
begin
  if p_user_id = p_actor then
    raise exception 'cannot deactivate self' using errcode = '22023';
  end if;
  update nomad_hospital.staff set active = false, deactivated_at = now() where user_id = p_user_id and active;
  if not found then raise exception 'active staff not found' using errcode = '22023'; end if;
  update nomad_hospital.care_assignments set ended_at = now() where staff_id = p_user_id and ended_at is null;
  perform nomad_hospital._audit(a, 'staff.deactivate', 'staff', p_user_id::text, null, null, 1);
end $$;

create function nomad_hospital.list_staff(p_actor uuid)
returns table (user_id uuid, display_name text, role text, dept text, active boolean)
language plpgsql security definer set search_path = '' as $$
declare a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
begin
  return query select s.user_id, s.display_name, s.role, s.dept, s.active from nomad_hospital.staff s order by s.display_name;
end $$;

-- 4.3 담당 배정 (관리자만 → 자가 배정 불가)
create function nomad_hospital.assign_care(p_actor uuid, p_patient_id uuid, p_staff_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
begin
  if not exists (select 1 from nomad_hospital.staff where user_id = p_staff_id and active and role in ('doctor', 'nurse')) then
    raise exception 'assignee must be an active doctor or nurse' using errcode = '22023';
  end if;
  insert into nomad_hospital.care_assignments (patient_id, staff_id, assigned_by) values (p_patient_id, p_staff_id, p_actor);
  perform nomad_hospital._audit(a, 'care.assign', 'care_assignments', p_staff_id::text, p_patient_id, null, 1);
end $$;

create function nomad_hospital.end_care(p_actor uuid, p_patient_id uuid, p_staff_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
begin
  update nomad_hospital.care_assignments set ended_at = now()
   where patient_id = p_patient_id and staff_id = p_staff_id and ended_at is null;
  if not found then raise exception 'active assignment not found' using errcode = '22023'; end if;
  perform nomad_hospital._audit(a, 'care.end', 'care_assignments', p_staff_id::text, p_patient_id, null, 1);
end $$;

-- 4.4 환자 (등록 = 접수·관리자, 검색·열람 = 역할 범위 + 감사)
create function nomad_hospital.register_patient(
  p_actor uuid, p_name text, p_phone text, p_name_enc text, p_phone_enc text, p_birth_enc text, p_consent_at timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['reception', 'admin']);
  k record := nomad_hospital._hmac_key();
  v_id uuid;
begin
  insert into nomad_hospital.patients (name_enc, phone_enc, birth_enc, name_hash, phone_hash, hash_key_version, consent_at, created_by)
  values (p_name_enc, p_phone_enc, p_birth_enc,
          nomad_hospital._hmac('name', p_name, k.key),
          case when p_phone is null then null else nomad_hospital._hmac('phone', p_phone, k.key) end,
          k.key_version, p_consent_at, p_actor)
  returning id into v_id;
  perform nomad_hospital._audit(a, 'patient.register', 'patients', v_id::text, v_id, null, 1);
  return v_id;
end $$;

-- 검색은 식별 최소(id·등록일)만 반환. 이름·전화·생년월일 암호문은 get_patient 로만(열람 감사).
create function nomad_hospital.search_patients(p_actor uuid, p_name text, p_phone text, p_purpose text)
returns table (id uuid, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse', 'reception', 'admin']);
  k record;
  v_name text;
  v_phone text;
  v_ids uuid[];
begin
  perform nomad_hospital._check_purpose(p_purpose);
  if p_name is null and p_phone is null then
    raise exception 'name or phone required' using errcode = '22023';
  end if;
  k := nomad_hospital._hmac_key();
  v_name := case when p_name is null then null else nomad_hospital._hmac('name', p_name, k.key) end;
  v_phone := case when p_phone is null then null else nomad_hospital._hmac('phone', p_phone, k.key) end;
  select coalesce(array_agg(p.id order by p.created_at), '{}') into v_ids
    from nomad_hospital.patients p
   where p.hash_key_version = k.key_version
     and (v_name is null or p.name_hash = v_name)
     and (v_phone is null or p.phone_hash = v_phone)
     and (a.role in ('reception', 'admin') or nomad_hospital._is_assigned(a.user_id, p.id));
  perform nomad_hospital._audit(a, 'patient.search', 'patients', null, null, p_purpose, cardinality(v_ids),
                                jsonb_build_object('patient_ids', to_jsonb(v_ids)));
  return query select p.id, p.created_at from nomad_hospital.patients p
                where p.id = any (v_ids) order by p.created_at;
end $$;

create function nomad_hospital.get_patient(p_actor uuid, p_patient_id uuid, p_purpose text)
returns table (id uuid, name_enc text, phone_enc text, birth_enc text, consent_at timestamptz, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse', 'reception', 'admin']);
begin
  perform nomad_hospital._check_purpose(p_purpose);
  perform nomad_hospital._require_patient(a, p_patient_id);
  perform nomad_hospital._audit(a, 'patient.view', 'patients', p_patient_id::text, p_patient_id, p_purpose, 1);
  return query select p.id, p.name_enc, p.phone_enc, p.birth_enc, p.consent_at, p.created_at
                 from nomad_hospital.patients p where p.id = p_patient_id;
end $$;

-- 4.5 예약 (쓰기 = 접수·관리자, 읽기 = 역할 범위)
create function nomad_hospital.create_appointment(p_actor uuid, p_patient_id uuid, p_staff_id uuid, p_scheduled_at timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['reception', 'admin']);
  v_id uuid;
begin
  if not exists (select 1 from nomad_hospital.staff where user_id = p_staff_id and active and role in ('doctor', 'nurse')) then
    raise exception 'appointment staff must be an active doctor or nurse' using errcode = '22023';
  end if;
  insert into nomad_hospital.appointments (patient_id, staff_id, scheduled_at, created_by)
  values (p_patient_id, p_staff_id, p_scheduled_at, p_actor) returning id into v_id;
  perform nomad_hospital._audit(a, 'appointment.create', 'appointments', v_id::text, p_patient_id, null, 1);
  return v_id;
end $$;

create function nomad_hospital.set_appointment_status(p_actor uuid, p_appointment_id uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['reception', 'admin']);
  v_patient uuid;
begin
  update nomad_hospital.appointments set status = p_status, updated_at = now()
   where id = p_appointment_id returning patient_id into v_patient;
  if v_patient is null then raise exception 'appointment not found' using errcode = '22023'; end if;
  perform nomad_hospital._audit(a, 'appointment.status', 'appointments', p_appointment_id::text, v_patient, null, 1,
                                jsonb_build_object('status', p_status));
end $$;

create function nomad_hospital.list_appointments(p_actor uuid, p_from timestamptz, p_to timestamptz, p_purpose text)
returns table (id uuid, patient_id uuid, staff_id uuid, scheduled_at timestamptz, status text)
language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse', 'reception', 'admin']);
  n integer;
begin
  perform nomad_hospital._check_purpose(p_purpose);
  return query
    select ap.id, ap.patient_id, ap.staff_id, ap.scheduled_at, ap.status
      from nomad_hospital.appointments ap
     where ap.scheduled_at >= p_from and ap.scheduled_at < p_to
       and (a.role in ('reception', 'admin') or nomad_hospital._is_assigned(a.user_id, ap.patient_id))
     order by ap.scheduled_at;
  get diagnostics n = row_count;
  perform nomad_hospital._audit(a, 'appointment.list', 'appointments', null, null, p_purpose, n);
end $$;

-- 4.6 연락 기록 (쓰기 = 접수·관리자·담당 의료진, 읽기 = 역할 범위)
create function nomad_hospital.add_contact_log(p_actor uuid, p_patient_id uuid, p_channel text, p_summary_enc text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse', 'reception', 'admin']);
  v_id uuid;
begin
  perform nomad_hospital._require_patient(a, p_patient_id);
  insert into nomad_hospital.contact_logs (patient_id, channel, summary_enc, created_by)
  values (p_patient_id, p_channel, p_summary_enc, p_actor) returning id into v_id;
  perform nomad_hospital._audit(a, 'contact.add', 'contact_logs', v_id::text, p_patient_id, null, 1);
  return v_id;
end $$;

create function nomad_hospital.list_contact_logs(p_actor uuid, p_patient_id uuid, p_purpose text)
returns table (id uuid, channel text, summary_enc text, created_by uuid, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse', 'reception', 'admin']);
  n integer;
begin
  perform nomad_hospital._check_purpose(p_purpose);
  perform nomad_hospital._require_patient(a, p_patient_id);
  return query select c.id, c.channel, c.summary_enc, c.created_by, c.created_at
                 from nomad_hospital.contact_logs c where c.patient_id = p_patient_id order by c.created_at;
  get diagnostics n = row_count;
  perform nomad_hospital._audit(a, 'contact.list', 'contact_logs', null, p_patient_id, p_purpose, n);
end $$;

-- 4.7 상담(진료) 메모 (담당 의사·간호사만. 접수·관리자 본문 접근 없음)
create function nomad_hospital.add_consult_note(p_actor uuid, p_patient_id uuid, p_note_enc text, p_amends_id uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse']);
  v_id uuid;
begin
  perform nomad_hospital._require_patient(a, p_patient_id);
  if p_amends_id is not null and not exists (
       select 1 from nomad_hospital.consult_notes where id = p_amends_id and patient_id = p_patient_id) then
    raise exception 'amended note must belong to the same patient' using errcode = '22023';
  end if;
  insert into nomad_hospital.consult_notes (patient_id, author_id, note_enc, amends_id)
  values (p_patient_id, p_actor, p_note_enc, p_amends_id) returning id into v_id;
  perform nomad_hospital._audit(a, 'note.add', 'consult_notes', v_id::text, p_patient_id, null, 1);
  return v_id;
end $$;

create function nomad_hospital.list_consult_notes(p_actor uuid, p_patient_id uuid, p_purpose text)
returns table (id uuid, author_id uuid, note_enc text, amends_id uuid, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['doctor', 'nurse']);
  n integer;
begin
  perform nomad_hospital._check_purpose(p_purpose);
  perform nomad_hospital._require_patient(a, p_patient_id);
  return query select c.id, c.author_id, c.note_enc, c.amends_id, c.created_at
                 from nomad_hospital.consult_notes c where c.patient_id = p_patient_id order by c.created_at;
  get diagnostics n = row_count;
  perform nomad_hospital._audit(a, 'note.list', 'consult_notes', null, p_patient_id, p_purpose, n);
end $$;

-- 4.8 보존·파기 (관리자. 자동 삭제 없음)
create function nomad_hospital.list_purge_candidates(p_actor uuid)
returns table (record_kind text, record_id uuid, patient_id uuid, created_at timestamptz, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
  n integer;
begin
  return query
    with r as (select rp.record_kind, make_interval(years => rp.retain_years) as keep from nomad_hospital.retention_policies rp),
    rows_all as (
      select 'consult_note'::text as kind, c.id, c.patient_id, c.created_at from nomad_hospital.consult_notes c
      union all select 'contact_log', l.id, l.patient_id, l.created_at from nomad_hospital.contact_logs l
      union all select 'appointment', ap.id, ap.patient_id, ap.created_at from nomad_hospital.appointments ap)
    select x.kind, x.id, x.patient_id, x.created_at, x.created_at + r.keep
      from rows_all x join r on r.record_kind = x.kind
     where x.created_at + r.keep <= now()
     order by x.created_at;
  get diagnostics n = row_count;
  perform nomad_hospital._audit(a, 'purge.candidates', null, null, null, null, n);
end $$;

create function nomad_hospital.purge_record(p_actor uuid, p_record_kind text, p_record_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
  v_keep interval;
  v_pending boolean;
  v_created timestamptz;
  v_patient uuid;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 2 then
    raise exception 'reason required' using errcode = '22023';
  end if;
  select make_interval(years => retain_years), legal_review_pending into v_keep, v_pending
    from nomad_hospital.retention_policies where record_kind = p_record_kind;
  if v_keep is null then raise exception 'unknown record kind %', p_record_kind using errcode = '22023'; end if;
  -- 법무 확인 전 보존 기간으로는 파기하지 않는다(fail-closed)
  if v_pending is distinct from false then
    raise exception 'retention policy for % is pending legal review', p_record_kind using errcode = 'HP005';
  end if;

  if p_record_kind = 'consult_note' then
    select created_at, patient_id into v_created, v_patient from nomad_hospital.consult_notes where id = p_record_id for update;
  elsif p_record_kind = 'contact_log' then
    select created_at, patient_id into v_created, v_patient from nomad_hospital.contact_logs where id = p_record_id for update;
  else
    select created_at, patient_id into v_created, v_patient from nomad_hospital.appointments where id = p_record_id for update;
  end if;
  if v_created is null then raise exception 'record not found' using errcode = '22023'; end if;
  if v_created + v_keep > now() then
    raise exception 'retention period not elapsed (until %)', v_created + v_keep using errcode = 'HP003';
  end if;

  perform set_config('nomad_hospital.allow_purge', 'on', true);
  if p_record_kind = 'consult_note' then
    delete from nomad_hospital.consult_notes where id = p_record_id;
  elsif p_record_kind = 'contact_log' then
    delete from nomad_hospital.contact_logs where id = p_record_id;
  else
    delete from nomad_hospital.appointments where id = p_record_id;
  end if;
  perform set_config('nomad_hospital.allow_purge', 'off', true);

  perform nomad_hospital._audit(a, 'purge.record', p_record_kind, p_record_id::text, v_patient, null, 1,
                                jsonb_build_object('reason', p_reason, 'created_at', v_created));
end $$;

-- 4.9 감사 로그 열람 (관리자, 열람도 감사)
create function nomad_hospital.list_audit_logs(p_actor uuid, p_from timestamptz, p_to timestamptz)
returns table (id bigint, at timestamptz, actor_id uuid, actor_name text, actor_role text, action text,
               target_table text, target_id text, patient_id uuid, purpose text, row_count integer, detail jsonb)
language plpgsql security definer set search_path = '' as $$
declare
  a nomad_hospital.staff := nomad_hospital._actor(p_actor, array['admin']);
  n integer;
begin
  return query select l.id, l.at, l.actor_id, l.actor_name, l.actor_role, l.action, l.target_table, l.target_id,
                      l.patient_id, l.purpose, l.row_count, l.detail
                 from nomad_hospital.audit_logs l where l.at >= p_from and l.at < p_to order by l.id;
  get diagnostics n = row_count;
  perform nomad_hospital._audit(a, 'audit.list', 'audit_logs', null, null, 'admin_review', n);
end $$;

-- ---------------------------------------------------------------------
-- 5. 권한: 표·시퀀스 직접 권한 0, 함수는 API 만 service_role EXECUTE
-- ---------------------------------------------------------------------
revoke all on all tables in schema nomad_hospital from public, anon, authenticated, service_role;
revoke all on all sequences in schema nomad_hospital from public, anon, authenticated, service_role;
revoke all on all functions in schema nomad_hospital from public, anon, authenticated, service_role;

grant execute on function
  nomad_hospital.bootstrap_admin(uuid, text),
  nomad_hospital.add_staff(uuid, uuid, text, text, text),
  nomad_hospital.deactivate_staff(uuid, uuid),
  nomad_hospital.list_staff(uuid),
  nomad_hospital.assign_care(uuid, uuid, uuid),
  nomad_hospital.end_care(uuid, uuid, uuid),
  nomad_hospital.register_patient(uuid, text, text, text, text, text, timestamptz),
  nomad_hospital.search_patients(uuid, text, text, text),
  nomad_hospital.get_patient(uuid, uuid, text),
  nomad_hospital.create_appointment(uuid, uuid, uuid, timestamptz),
  nomad_hospital.set_appointment_status(uuid, uuid, text),
  nomad_hospital.list_appointments(uuid, timestamptz, timestamptz, text),
  nomad_hospital.add_contact_log(uuid, uuid, text, text),
  nomad_hospital.list_contact_logs(uuid, uuid, text),
  nomad_hospital.add_consult_note(uuid, uuid, text, uuid),
  nomad_hospital.list_consult_notes(uuid, uuid, text),
  nomad_hospital.list_purge_candidates(uuid),
  nomad_hospital.purge_record(uuid, text, uuid, text),
  nomad_hospital.list_audit_logs(uuid, timestamptz, timestamptz)
to service_role;

-- 기본 권한(함수 EXECUTE to PUBLIC 등)은 스키마 단위로 막을 수 없다. 이후 마이그레이션은 새 표·함수마다
-- 명시적으로 revoke all ... from public, anon, authenticated, service_role 한 뒤 필요한 grant 만 준다
-- (check_isolated.sql 이 service_role 실행 가능 함수 = API 목록과 정확히 일치하는지 검사).

commit;
