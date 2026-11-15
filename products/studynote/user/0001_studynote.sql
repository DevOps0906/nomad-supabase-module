-- study-note 이식 · 개인형(user안, D5). 소유 user_id, RLS auth.uid() = user_id + nomad_core.user_has_feature. 원본: platform-docs/products/_supabase-modular/migrations/2100_notes.sql 1~13장(7표, 스키마 notes)
-- core.organizations→nomad_core.organizations, org_members→nomad_core.memberships(member→editor), has_entitlement→nomad_core.has_feature,
-- core.consume_credits·refund_credits·enqueue_job·cancel_job·write_audit → nomad_core 같은 이름(원장 id uuid),
-- 플랜 features jsonb → A/B/C 기능 + plan_limits 키(수치 시드 안 함, 없으면 원본 free 값). 대응표: products/studynote/existing.md
-- 과금·작업·플랜은 조직 단위(nomad_core)이므로 실행은 사용자가 owner인 과금 조직(1인 조직)을 organization_id로 함께 기록한다.
-- AI 라우팅·AI 기능(원본 14장)은 user/0002_ai.sql. 전제: core 20261119000100 · 20261120000100~0500(audit·credits·jobs·ai) · 20261120000800(mark_job_delivered).
-- 되돌림: drop schema nomad_studynote cascade; drop schema nomad_studynote_private cascade;
--   delete from nomad_core.plan_features where product_code = 'studynote'; delete from nomad_core.features where product_code = 'studynote';
-- SQLSTATE(원본 유지): NT001 상태 전이 · NT002 이미 실행 중 · NT003 종료된 실행 쓰기 · NT004 플랜 한도 · NT005 일일 예산 · NT006 동시 실행
begin;

create schema nomad_studynote;
create schema nomad_studynote_private;
revoke all on schema nomad_studynote, nomad_studynote_private from public, anon, authenticated;
grant usage on schema nomad_studynote to authenticated, service_role;  -- anon 0
grant usage on schema nomad_studynote_private to service_role;
alter default privileges in schema nomad_studynote revoke execute on functions from public;
alter default privileges in schema nomad_studynote_private revoke execute on functions from public;
comment on schema nomad_studynote is 'study-note: 원문 → 2모델 병렬 정리 + 통합 → 학습 일지(개인형)';

insert into nomad_core.products (code, name) values ('studynote', 'Study Note') on conflict (code) do nothing;
-- 플랜: 원본 pro→A·B, free→C. 구독이 끊기면(C) 원본 free 기능만: notes(정리) 유지, premium 등급 모델 잠김.
insert into nomad_core.plans (product_code, code, name) values ('studynote', 'A', 'A'), ('studynote', 'B', 'B'), ('studynote', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('studynote', 'notes', '학습 일지 정리'),
  ('studynote', 'premium_models', 'premium 등급 모델')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('studynote', 'A', 'notes'), ('studynote', 'B', 'notes'), ('studynote', 'C', 'notes'),
  ('studynote', 'A', 'premium_models'), ('studynote', 'B', 'premium_models')
on conflict do nothing;
-- plan_limits 키(수치 시드 안 함, 없으면 원본 free 값): max_input_chars(5000) · history_max_entries(50) · history_max_bytes(5000000)

-- =====================================================================
-- 0. 도우미
-- =====================================================================
-- 개인형 이용권: 호출자가 owner인 활성 조직 중 하나라도 notes 기능이 열려 있으면 true(nomad_core.user_has_feature)
create function nomad_studynote.has_access() returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.user_has_feature('studynote', 'notes'), false) $$;

create function nomad_studynote_private.org_limit(target_organization uuid, target_key text, fallback integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_plan_limit(target_organization, 'studynote', target_key), fallback) $$;

-- 서버 쓰기 판별: current_user가 authenticated·anon이 아니면 서버(service_role 직접 또는 소유자 DEFINER 함수 안)
create function nomad_studynote.guard_server_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'nomad_studynote.%: server-managed table', tg_table_name using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

-- =====================================================================
-- 1. model_catalog: 허용 LLM 목록(화이트리스트). 공통, 사용자는 읽기만.
-- =====================================================================
create table nomad_studynote.model_catalog (
  model_id         text primary key,
  display_name     text not null,
  provider         text not null,
  tier             text not null constraint model_catalog_tier_check check (tier in ('lite', 'standard', 'premium')),
  credits_per_call integer not null constraint model_catalog_credits_check check (credits_per_call between 1 and 20),
  is_free          boolean not null default false,
  is_active        boolean not null default true,
  sort_order       integer not null default 100,
  deprecated_at    timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table nomad_studynote.model_catalog is '허용 모델 목록(배포 없이 비활성화). premium 등급은 기능 premium_models(A·B) 필요.';

-- =====================================================================
-- 2. runtime_config, cost_guard: 운영 상한(사용자 접근 없음)
-- =====================================================================
create table nomad_studynote.runtime_config (
  key        text primary key,
  value_int  integer not null,
  note       text,
  updated_at timestamptz not null default now()
);
comment on table nomad_studynote.runtime_config is '운영 상수(서버 전용).';

create table nomad_studynote.cost_guard (
  day          date primary key,
  used_credits integer not null default 0 constraint cost_guard_used_check check (used_credits >= 0),
  updated_at   timestamptz not null default now()
);
comment on table nomad_studynote.cost_guard is '일일 전체 크레딧 소비(KST 날짜). 서버 전용.';

-- =====================================================================
-- 3. user_settings: 사용자별 모델 3종과 테마(API 키 컬럼 없음)
-- =====================================================================
create table nomad_studynote.user_settings (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  base_model_1    text references nomad_studynote.model_catalog(model_id) on update cascade on delete set null,
  base_model_2    text references nomad_studynote.model_catalog(model_id) on update cascade on delete set null,
  merge_model     text references nomad_studynote.model_catalog(model_id) on update cascade on delete set null,
  theme           text not null default 'system' constraint user_settings_theme_check check (theme in ('system', 'light', 'dark')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index user_settings_updated_idx on nomad_studynote.user_settings (user_id, updated_at);
comment on table nomad_studynote.user_settings is '사용자 모델 선택·테마. 본인 행만(+ 개인 이용권).';

-- =====================================================================
-- 4. entries: 하루치 일지(원문 + 최종본). 원문·날짜만 사용자가 쓴다.
-- =====================================================================
create table nomad_studynote.entries (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  entry_date      date not null,
  input_text      text not null constraint entries_input_len_check check (char_length(input_text) between 1 and 20000),
  status          text not null default 'draft' constraint entries_status_check check (status in ('draft', 'organizing', 'organized')),
  final_text      text,
  keywords        text[] constraint entries_keywords_check check (keywords is null or cardinality(keywords) = 2),
  last_run_id     uuid,
  organized_at    timestamptz,
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index entries_user_created_idx on nomad_studynote.entries (user_id, created_at desc) where deleted_at is null;
create index entries_user_date_idx on nomad_studynote.entries (user_id, entry_date desc) where deleted_at is null;
create index entries_user_updated_idx on nomad_studynote.entries (user_id, updated_at);
create index entries_deleted_idx on nomad_studynote.entries (deleted_at) where deleted_at is not null;
comment on table nomad_studynote.entries is '학습 일지. 상태·결과 컬럼은 서버만(컬럼 grant + 트리거). 소프트 삭제(휴지통 30일)·증분 동기화 대상.';

-- 2차 잠금: 사용자 세션은 상태·결과 컬럼을 바꾸지 못한다
create function nomad_studynote.guard_entry_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.final_text is not null or new.keywords is not null
       or new.last_run_id is not null or new.organized_at is not null or new.deleted_at is not null then
      raise exception 'entries: result columns are server-managed' using errcode = '42501';
    end if;
  elsif tg_op = 'UPDATE' then
    if new.user_id <> old.user_id
       or new.status is distinct from old.status or new.final_text is distinct from old.final_text
       or new.keywords is distinct from old.keywords or new.last_run_id is distinct from old.last_run_id
       or new.organized_at is distinct from old.organized_at then
      raise exception 'entries: result columns are server-managed' using errcode = '42501';
    end if;
    if old.status = 'organizing' and new.input_text is distinct from old.input_text then
      raise exception 'entries: input_text is locked while organizing' using errcode = 'NT001';
    end if;
    -- 소프트 삭제 시각은 클라이언트 값을 믿지 않는다: null(복원) 또는 now()
    if new.deleted_at is distinct from old.deleted_at and new.deleted_at is not null then
      new.deleted_at := now();
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger entries_guard_write before insert or update or delete on nomad_studynote.entries
  for each row execute function nomad_studynote.guard_entry_write();

-- 상태 전이: draft → organizing, organizing → organized | draft, organized → organizing (서버에도 적용)
create function nomad_studynote.check_entry_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if not ((old.status = 'draft' and new.status = 'organizing')
         or (old.status = 'organizing' and new.status in ('organized', 'draft'))
         or (old.status = 'organized' and new.status = 'organizing')) then
      raise exception 'entries: invalid transition % -> %', old.status, new.status using errcode = 'NT001';
    end if;
  end if;
  return new;
end;
$$;
create trigger entries_status_transition before update of status on nomad_studynote.entries
  for each row execute function nomad_studynote.check_entry_transition();

-- =====================================================================
-- 5. runs: 정리 실행 1회(2모델 병렬 + 통합). 일지당 활성 실행 1개(부분 유니크).
-- =====================================================================
create table nomad_studynote.runs (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,   -- 과금 조직(user가 owner)
  entry_id            uuid not null references nomad_studynote.entries(id) on delete cascade,
  request_id          uuid not null,
  idempotency_key     text not null unique,
  parent_run_id       uuid references nomad_studynote.runs(id) on delete set null,
  retry_roles         text[],
  base_model_1        text not null,
  base_model_2        text not null,
  merge_model         text not null,
  status              text not null default 'queued'
                      constraint runs_status_check check (status in ('queued', 'running', 'succeeded', 'partial', 'failed', 'canceled')),
  credits_charged     integer not null constraint runs_credits_charged_check check (credits_charged >= 0),
  credits_refunded    integer not null default 0 constraint runs_credits_refunded_check check (credits_refunded >= 0),
  credit_ledger_id    uuid references nomad_core.credit_ledger(id),
  job_id              uuid references nomad_core.jobs(id) on delete set null,
  cancel_requested_at timestamptz,
  error_code          text,
  error_message       text,
  queued_at           timestamptz not null default now(),
  started_at          timestamptz,
  finished_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint runs_refund_le_charge_check check (credits_refunded <= credits_charged)
);
create unique index runs_one_active_per_entry_uniq on nomad_studynote.runs (entry_id) where status in ('queued', 'running');
create index runs_org_queued_idx on nomad_studynote.runs (organization_id, queued_at);  -- 조직별 일일 예산 집계
create index runs_entry_created_idx on nomad_studynote.runs (entry_id, created_at desc);
create index runs_org_active_idx on nomad_studynote.runs (organization_id) where status in ('queued', 'running');
create index runs_user_created_idx on nomad_studynote.runs (user_id, created_at desc);
comment on table nomad_studynote.runs is '정리 실행. 과금 조직의 크레딧 선차감(consume_credits)·작업(enqueue_job)과 1:1. 서버 쓰기만, 본인 읽기.';

alter table nomad_studynote.entries add constraint entries_last_run_fk
  foreign key (last_run_id) references nomad_studynote.runs(id) on delete set null;

-- 상태 전이: queued → running|canceled|failed, running → succeeded|partial|failed|canceled. 종료 상태는 불변.
create function nomad_studynote.check_run_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if not ((old.status = 'queued' and new.status in ('running', 'canceled', 'failed'))
         or (old.status = 'running' and new.status in ('succeeded', 'partial', 'failed', 'canceled'))) then
      raise exception 'runs: invalid transition % -> %', old.status, new.status using errcode = 'NT001';
    end if;
  elsif old.status in ('succeeded', 'partial', 'failed', 'canceled') then
    if new.base_model_1 is distinct from old.base_model_1 or new.base_model_2 is distinct from old.base_model_2
       or new.merge_model is distinct from old.merge_model or new.credits_charged is distinct from old.credits_charged then
      raise exception 'runs: terminal run is immutable' using errcode = 'NT003';
    end if;
  end if;
  return new;
end;
$$;
create trigger runs_status_transition before update on nomad_studynote.runs
  for each row execute function nomad_studynote.check_run_transition();

-- =====================================================================
-- 6. run_steps: 카드 단위 결과(base1, base2, merge). 사용자는 읽기만.
-- =====================================================================
create table nomad_studynote.run_steps (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  run_id            uuid not null references nomad_studynote.runs(id) on delete cascade,
  role              text not null constraint run_steps_role_check check (role in ('base1', 'base2', 'merge')),
  model_id          text not null,
  status            text not null default 'pending'
                    constraint run_steps_status_check check (status in ('pending', 'running', 'succeeded', 'failed', 'skipped', 'reused', 'canceled')),
  credits           integer not null default 0 constraint run_steps_credits_check check (credits >= 0),
  content           text,
  latency_ms        integer,
  prompt_tokens     integer,
  completion_tokens integer,
  ai_usage_id       bigint references nomad_core.ai_usage(id) on delete set null,
  error_code        text,
  error_message     text,
  started_at        timestamptz,
  finished_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (run_id, role)
);
create index run_steps_user_idx on nomad_studynote.run_steps (user_id);
comment on table nomad_studynote.run_steps is '실행 단계별 결과 카드. 서버 쓰기만, 본인 읽기.';

do $$
declare t text;
begin
  foreach t in array array['model_catalog', 'runtime_config', 'cost_guard', 'user_settings', 'entries', 'runs', 'run_steps'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_studynote.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
  foreach t in array array['model_catalog', 'runtime_config', 'cost_guard', 'runs', 'run_steps'] loop
    execute format('create trigger %1$s_guard_write before insert or update or delete on nomad_studynote.%1$I for each row execute function nomad_studynote.guard_server_write()', t);
  end loop;
end $$;

-- 진행률 UI: runs·run_steps 변경을 RLS 하에서 구독(발행이 있을 때만)
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['runs', 'run_steps'] loop
      execute format('alter publication supabase_realtime add table nomad_studynote.%I', t);
    end loop;
  end if;
end $$;

-- 내부: 환불한 만큼 전체 일일 예산(cost_guard)을 되돌린다(실행이 접수된 KST 날짜 기준, 0 아래로 내려가지 않음).
create function nomad_studynote_private.release_budget(p_queued_at timestamptz, p_amount integer) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(p_amount, 0) > 0 then
    update nomad_studynote.cost_guard set used_credits = greatest(used_credits - p_amount, 0)
    where day = (p_queued_at at time zone 'Asia/Seoul')::date;
  end if;
end;
$$;

-- 내부: 결과 저장 전 작업 확인(읽기만). 작업이 이미 failed·canceled(환불 끝남)면 결과를 받지 않는다.
create function nomad_studynote_private.assert_job_open(p_job uuid, p_fn text) returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_job is not null and exists (select 1 from nomad_core.jobs j where j.id = p_job and j.status in ('failed', 'canceled')) then
    raise exception '%: job is already finished without result', p_fn using errcode = 'NT003';
  end if;
end;
$$;

-- =====================================================================
-- 7. start_run (서버 전용): 크레딧 선차감 + 실행/단계 생성 + 작업 등록을 한 트랜잭션으로.
--    p_retry_roles null = 전체 실행, {'base1'} 등 = 해당 카드만 다시 실행(나머지 base는 부모 결과 재사용 0크레딧) + merge 새로.
-- =====================================================================
create function nomad_studynote.start_run(
  p_organization_id uuid, p_user_id uuid, p_entry_id uuid, p_request_id uuid,
  p_base_model_1 text, p_base_model_2 text, p_merge_model text,
  p_parent_run_id uuid default null, p_retry_roles text[] default null
)
returns nomad_studynote.runs
language plpgsql security definer set search_path = ''
as $$
declare
  v_key       text := 'run:studynote:' || p_request_id::text;
  v_run       nomad_studynote.runs;
  v_entry     nomad_studynote.entries;
  v_parent    nomad_studynote.runs;
  v_premium   boolean;
  v_max_chars integer;
  v_cap       integer;
  v_active    integer;
  v_run_id    uuid := gen_random_uuid();
  v_roles     text[] := array['base1', 'base2', 'merge'];
  v_exec      text[];
  v_role      text;
  v_model     text;
  v_cat       nomad_studynote.model_catalog;
  v_pstep     nomad_studynote.run_steps;
  v_credits   integer := 0;
  v_cost      integer;
  v_ledger    uuid;
  v_job       nomad_core.jobs;
  v_day       date := (now() at time zone 'Asia/Seoul')::date;
  v_used      integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'start_run: service_role only' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'start_run: request_id required' using errcode = '22023';
  end if;
  if p_retry_roles is not null and (cardinality(p_retry_roles) = 0 or not (p_retry_roles <@ array['base1', 'base2'])) then
    raise exception 'start_run: retry_roles must be a non-empty subset of base1, base2' using errcode = '22023';
  end if;
  if (p_retry_roles is null) <> (p_parent_run_id is null) then
    raise exception 'start_run: retry_roles and parent_run_id must be given together' using errcode = '22023';
  end if;

  -- 멱등: 같은 request_id는 같은 실행(다른 조직이면 거부)
  perform pg_advisory_xact_lock(hashtextextended('studynote:run:' || v_key, 0));
  select * into v_run from nomad_studynote.runs r where r.idempotency_key = v_key;
  if v_run.id is not null then
    if v_run.user_id <> p_user_id then
      raise exception 'start_run: request belongs to another user' using errcode = '42501';
    end if;
    return v_run;
  end if;

  -- 과금 조직: 사용자가 owner인 조직만(개인형 이용권 규칙 user_has_feature와 같은 기준)
  if not exists (select 1 from nomad_core.memberships m
                 where m.organization_id = p_organization_id and m.user_id = p_user_id and m.role = 'owner') then
    raise exception 'start_run: not the owner of the billing organization' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(p_organization_id, 'studynote', 'notes') then
    raise exception 'start_run: no entitlement' using errcode = '42501';
  end if;

  select * into v_entry from nomad_studynote.entries e
  where e.id = p_entry_id and e.user_id = p_user_id and e.deleted_at is null for update;
  if v_entry.id is null then
    raise exception 'start_run: entry not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from nomad_studynote.runs r where r.entry_id = p_entry_id and r.status in ('queued', 'running')) then
    raise exception 'start_run: a run is already active for this entry' using errcode = 'NT002';
  end if;

  v_max_chars := nomad_studynote_private.org_limit(p_organization_id, 'max_input_chars', 5000);
  v_premium := nomad_core.org_has_feature(p_organization_id, 'studynote', 'premium_models');
  if char_length(v_entry.input_text) > v_max_chars then
    raise exception 'start_run: input exceeds plan limit (% > %)', char_length(v_entry.input_text), v_max_chars using errcode = 'NT004';
  end if;

  select count(*) into v_active from nomad_studynote.runs r where r.organization_id = p_organization_id and r.status in ('queued', 'running');
  if v_active >= coalesce((select c.value_int from nomad_studynote.runtime_config c where c.key = 'max_active_runs_per_org'), 2) then
    raise exception 'start_run: too many active runs for this organization' using errcode = 'NT006';
  end if;

  if p_parent_run_id is not null then
    select * into v_parent from nomad_studynote.runs r
    where r.id = p_parent_run_id and r.user_id = p_user_id and r.entry_id = p_entry_id
      and r.status in ('succeeded', 'partial', 'failed', 'canceled');
    if v_parent.id is null then
      raise exception 'start_run: parent run not found or not finished' using errcode = 'P0002';
    end if;
  end if;

  v_exec := case when p_retry_roles is null then v_roles else p_retry_roles || array['merge'] end;
  for v_role in select unnest(v_exec) loop
    v_model := case v_role when 'base1' then p_base_model_1 when 'base2' then p_base_model_2 else p_merge_model end;
    select * into v_cat from nomad_studynote.model_catalog c where c.model_id = v_model and c.is_active;
    if v_cat.model_id is null then
      raise exception 'start_run: model % is not available', v_model using errcode = '22023';
    end if;
    if v_cat.tier = 'premium' and not v_premium then
      raise exception 'start_run: model tier % is not allowed by the plan', v_cat.tier using errcode = 'NT004';
    end if;
    v_credits := v_credits + v_cat.credits_per_call;
  end loop;

  -- 조직(user안은 과금 조직)별 일일 상한: 오늘 접수분의 순사용(차감 − 환불). 한도 = plan_limits daily_credit_cap
  -- (없으면 runtime_config daily_credit_cap_per_org, 그것도 없으면 300). 한 조직이 전체 예산을 다 쓰지 못하게 한다.
  if (select coalesce(sum(r.credits_charged - r.credits_refunded), 0) from nomad_studynote.runs r
      where r.organization_id = p_organization_id and r.queued_at >= (v_day::timestamp at time zone 'Asia/Seoul')) + v_credits
     > nomad_studynote_private.org_limit(p_organization_id, 'daily_credit_cap',
         coalesce((select c.value_int from nomad_studynote.runtime_config c where c.key = 'daily_credit_cap_per_org'), 300)) then
    raise exception 'start_run: organization daily budget exhausted' using errcode = 'NT005';
  end if;

  -- 일일 전체 예산(공개 베타 비용 상한)
  select c.value_int into v_cap from nomad_studynote.runtime_config c where c.key = 'daily_credit_cap';
  insert into nomad_studynote.cost_guard (day, used_credits) values (v_day, v_credits)
  on conflict (day) do update set used_credits = nomad_studynote.cost_guard.used_credits + excluded.used_credits
  returning used_credits into v_used;
  if v_cap is not null and v_used > v_cap then
    raise exception 'start_run: daily budget exhausted' using errcode = 'NT005';
  end if;

  -- 선차감(원자, 멱등). 부족하면 전체 롤백
  select c.ledger_id into v_ledger
  from nomad_core.consume_credits(p_organization_id, v_credits, 'studynote.organize', 'consume:studynote:' || p_request_id::text,
                                  'studynote', 'studynote_run', v_run_id::text) c;

  insert into nomad_studynote.runs (id, organization_id, entry_id, user_id, request_id, idempotency_key, parent_run_id, retry_roles,
                                    base_model_1, base_model_2, merge_model, credits_charged, credit_ledger_id)
  values (v_run_id, p_organization_id, p_entry_id, p_user_id, p_request_id, v_key, p_parent_run_id, p_retry_roles,
          p_base_model_1, p_base_model_2, p_merge_model, v_credits, v_ledger)
  returning * into v_run;

  foreach v_role in array v_roles loop
    if v_role = any (v_exec) then
      v_model := case v_role when 'base1' then p_base_model_1 when 'base2' then p_base_model_2 else p_merge_model end;
      select c.credits_per_call into v_cost from nomad_studynote.model_catalog c where c.model_id = v_model;
      insert into nomad_studynote.run_steps (user_id, run_id, role, model_id, credits) values (p_user_id, v_run_id, v_role, v_model, v_cost);
    else
      select * into v_pstep from nomad_studynote.run_steps s
      where s.run_id = p_parent_run_id and s.role = v_role and s.status in ('succeeded', 'reused') and s.content is not null;
      if v_pstep.id is null then
        raise exception 'start_run: role % has no reusable result; include it in retry_roles', v_role using errcode = '22023';
      end if;
      insert into nomad_studynote.run_steps (user_id, run_id, role, model_id, status, credits, content, latency_ms, prompt_tokens, completion_tokens, finished_at)
      values (p_user_id, v_run_id, v_role, v_pstep.model_id, 'reused', 0, v_pstep.content, v_pstep.latency_ms,
              v_pstep.prompt_tokens, v_pstep.completion_tokens, now());
      if v_role = 'base1' then update nomad_studynote.runs set base_model_1 = v_pstep.model_id where id = v_run_id;
      else update nomad_studynote.runs set base_model_2 = v_pstep.model_id where id = v_run_id; end if;
    end if;
  end loop;

  select * into v_job from nomad_core.enqueue_job(
    p_organization_id, 'studynote', 'studynote.organize',
    jsonb_build_object('run_id', v_run_id, 'entry_id', p_entry_id, 'exec_roles', to_jsonb(v_exec)),
    'studynote.organize', 100, now(), 1, v_ledger, 'job:studynote:' || p_request_id::text, null, p_user_id, true);

  update nomad_studynote.runs set job_id = v_job.id where id = v_run_id returning * into v_run;
  update nomad_studynote.entries set status = 'organizing', last_run_id = v_run_id where id = p_entry_id;
  return v_run;
end;
$$;

-- =====================================================================
-- 8. record_step (서버 전용): 워커가 카드 진행/결과 기록. 종료된 실행에는 쓸 수 없다(NT003).
-- =====================================================================
create function nomad_studynote.record_step(
  p_run_id uuid, p_role text, p_status text, p_content text default null, p_latency_ms integer default null,
  p_prompt_tokens integer default null, p_completion_tokens integer default null, p_ai_usage_id bigint default null,
  p_error_code text default null, p_error_message text default null, p_model_id text default null
)
returns nomad_studynote.run_steps
language plpgsql security definer set search_path = ''
as $$
declare v_run nomad_studynote.runs; v_step nomad_studynote.run_steps;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_step: service_role only' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('running', 'succeeded', 'failed', 'skipped', 'canceled') then
    raise exception 'record_step: invalid status %', p_status using errcode = '22023';
  end if;
  if p_status = 'succeeded' and coalesce(p_content, '') = '' then
    raise exception 'record_step: succeeded step needs content' using errcode = '22023';
  end if;
  select * into v_run from nomad_studynote.runs r where r.id = p_run_id for update;
  if v_run.id is null then
    raise exception 'record_step: run not found' using errcode = 'P0002';
  end if;
  if v_run.status not in ('queued', 'running') then
    raise exception 'record_step: run % is already %', p_run_id, v_run.status using errcode = 'NT003';
  end if;
  select * into v_step from nomad_studynote.run_steps s where s.run_id = p_run_id and s.role = p_role for update;
  if v_step.id is null then
    raise exception 'record_step: step not found' using errcode = 'P0002';
  end if;
  if v_step.status = p_status then
    return v_step;
  end if;
  if not ((v_step.status = 'pending' and p_status in ('running', 'skipped', 'canceled', 'failed'))
       or (v_step.status = 'running' and p_status in ('succeeded', 'failed', 'canceled'))) then
    raise exception 'record_step: step % cannot go % -> %', p_role, v_step.status, p_status using errcode = 'NT003';
  end if;
  if v_run.status = 'queued' then
    update nomad_studynote.runs set status = 'running', started_at = now() where id = p_run_id;
  end if;
  update nomad_studynote.run_steps
  set status = p_status,
      model_id = coalesce(p_model_id, model_id),
      content = case when p_status = 'succeeded' then p_content else content end,
      latency_ms = coalesce(p_latency_ms, latency_ms),
      prompt_tokens = coalesce(p_prompt_tokens, prompt_tokens),
      completion_tokens = coalesce(p_completion_tokens, completion_tokens),
      ai_usage_id = coalesce(p_ai_usage_id, ai_usage_id),
      error_code = p_error_code,
      error_message = left(p_error_message, 500),
      started_at = case when p_status = 'running' then now() else started_at end,
      finished_at = case when p_status = 'running' then null else now() end
  where id = v_step.id
  returning * into v_step;
  return v_step;
end;
$$;

-- =====================================================================
-- 9. 보존·정리 (서버 전용)
--    enforce_retention: 한도(history_max_entries 50 · history_max_bytes 5,000,000, plan_limits) 초과 오래된 일지 soft delete.
--    purge_deleted: soft delete 후 유예(기본 30일) 지난 일지 영구 삭제 + 오래된 cost_guard 정리.
-- =====================================================================
-- 개인형: 소유자 일지에 과금 조직의 한도를 적용한다.
create function nomad_studynote.enforce_retention(p_user_id uuid, p_organization_id uuid) returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_max_n integer; v_max_b bigint; v_n integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'enforce_retention: service_role only' using errcode = '42501';
  end if;
  v_max_n := nomad_studynote_private.org_limit(p_organization_id, 'history_max_entries', 50);
  v_max_b := nomad_studynote_private.org_limit(p_organization_id, 'history_max_bytes', 5000000);
  with step_bytes as (
    select r.entry_id, coalesce(sum(octet_length(s.content)), 0) as b
    from nomad_studynote.runs r join nomad_studynote.run_steps s on s.run_id = r.id
    where r.user_id = p_user_id group by r.entry_id
  ), sized as (
    select e.id, e.status,
           row_number() over w as rn,
           sum(octet_length(e.input_text) + coalesce(octet_length(e.final_text), 0) + coalesce(sb.b, 0)) over (w rows between unbounded preceding and current row) as cum
    from nomad_studynote.entries e left join step_bytes sb on sb.entry_id = e.id
    where e.user_id = p_user_id and e.deleted_at is null
    window w as (order by e.created_at desc, e.id desc)
  )
  update nomad_studynote.entries t set deleted_at = now()
  from sized z
  where t.id = z.id and z.rn > 1 and z.status <> 'organizing' and (z.rn > v_max_n or z.cum > v_max_b);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create function nomad_studynote.purge_deleted(p_grace interval default interval '30 days') returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_deleted: service_role only' using errcode = '42501';
  end if;
  delete from nomad_studynote.entries e where e.deleted_at is not null and e.deleted_at < now() - p_grace;
  get diagnostics v_n = row_count;
  delete from nomad_studynote.cost_guard g where g.day < (now() at time zone 'Asia/Seoul')::date - 60;
  return v_n;
end;
$$;

-- =====================================================================
-- 10. finish_run (서버 전용): 종료 확정 + 미성공 단계 환불 + entries 갱신.
--     failed 환불은 nomad_core.fail_job과 같은 키('job:<작업 id>', 사유 job_failed, 전액)라 이중 환불이 없다.
--     그 밖의 종료는 'refund:run:<실행 id>' 키로 단계 금액만 환불하고 nomad_core.mark_job_delivered로 작업의 실패 환불을 끈다.
--     환불액만큼 전체 일일 예산(cost_guard)도 되돌린다. 작업이 이미 failed·canceled면 결과를 받지 않는다(NT003).
-- =====================================================================
create function nomad_studynote.finish_run(p_run_id uuid, p_final_text text default null, p_keywords text[] default null)
returns nomad_studynote.runs
language plpgsql security definer set search_path = ''
as $$
declare
  v_run     nomad_studynote.runs;
  v_status  text;
  v_exec_ok integer;
  v_merge   boolean;
  v_refund  integer;
  v_err     text;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'finish_run: service_role only' using errcode = '42501';
  end if;
  select * into v_run from nomad_studynote.runs r where r.id = p_run_id for update;
  if v_run.id is null then
    raise exception 'finish_run: run not found' using errcode = 'P0002';
  end if;
  if v_run.status not in ('queued', 'running') then
    raise exception 'finish_run: run % is already %', p_run_id, v_run.status using errcode = 'NT003';
  end if;
  perform nomad_studynote_private.assert_job_open(v_run.job_id, 'finish_run');

  select count(*) filter (where s.status = 'succeeded'),
         coalesce(bool_or(s.role = 'merge' and s.status = 'succeeded'), false)
  into v_exec_ok, v_merge
  from nomad_studynote.run_steps s where s.run_id = p_run_id;

  v_status := case
    when v_merge and coalesce(p_final_text, '') <> '' then 'succeeded'
    when v_run.cancel_requested_at is not null and v_exec_ok = 0 then 'canceled'
    when v_exec_ok > 0 then 'partial'
    else 'failed'
  end;
  if v_status = 'succeeded' and (p_keywords is null or cardinality(p_keywords) <> 2) then
    raise exception 'finish_run: succeeded run needs exactly 2 keywords' using errcode = '22023';
  end if;

  update nomad_studynote.run_steps
  set status = case when status = 'running' then 'failed' when v_status = 'canceled' then 'canceled' else 'skipped' end,
      error_code = case when status = 'running' then 'aborted' else error_code end,
      finished_at = now()
  where run_id = p_run_id and status in ('pending', 'running');

  select coalesce(sum(s.credits), 0) into v_refund
  from nomad_studynote.run_steps s where s.run_id = p_run_id and s.status in ('failed', 'skipped', 'canceled');

  if v_status = 'failed' then
    v_err := coalesce((select s.error_code from nomad_studynote.run_steps s where s.run_id = p_run_id and s.error_code is not null
                       order by s.finished_at desc nulls last limit 1), 'all_steps_failed');
  end if;
  if v_run.status = 'queued' then
    update nomad_studynote.runs set status = 'running', started_at = coalesce(started_at, now()) where id = p_run_id;
  end if;

  if v_refund > 0 and v_run.credit_ledger_id is not null then
    if v_status = 'failed' and v_run.job_id is not null then
      perform nomad_core.refund_credits(v_run.credit_ledger_id, 'job_failed', 'job:' || v_run.job_id::text, null);
    else
      perform nomad_core.refund_credits(v_run.credit_ledger_id, 'studynote_run_' || v_status, 'refund:run:' || p_run_id::text, v_refund);
    end if;
  end if;
  perform nomad_studynote_private.release_budget(v_run.queued_at, v_refund);
  if v_status <> 'failed' and v_run.job_id is not null then
    perform nomad_core.mark_job_delivered(v_run.job_id);
  end if;

  update nomad_studynote.runs
  set status = v_status, finished_at = now(), credits_refunded = v_refund,
      error_code = v_err, error_message = case when v_status = 'failed' then 'all executed steps failed' end
  where id = p_run_id
  returning * into v_run;

  if v_status = 'succeeded' then
    update nomad_studynote.entries
    set status = 'organized', final_text = p_final_text, keywords = p_keywords, organized_at = now(), last_run_id = p_run_id
    where id = v_run.entry_id;
  else
    update nomad_studynote.entries
    set status = case when final_text is not null then 'organized' else 'draft' end, last_run_id = p_run_id
    where id = v_run.entry_id and status = 'organizing';
  end if;

  perform nomad_studynote.enforce_retention(v_run.user_id, v_run.organization_id);
  return v_run;
end;
$$;

-- =====================================================================
-- 11. request_run_cancel (authenticated): 본인 실행만.
--     queued는 nomad_core.cancel_job으로 즉시 취소(전액 환불), running은 취소 요청만 남기고 워커가 단계 경계에서 멈춘다.
--     남의 실행은 존재도 알리지 않는다(P0002).
-- =====================================================================
create function nomad_studynote.request_run_cancel(p_run_id uuid) returns nomad_studynote.runs
language plpgsql security definer set search_path = ''
as $$
declare v_run nomad_studynote.runs;
begin
  select * into v_run from nomad_studynote.runs r where r.id = p_run_id;
  if v_run.id is null or not (nomad_core.is_service_caller()
                              or (v_run.user_id = (select auth.uid()) and nomad_studynote.has_access())) then
    raise exception 'request_run_cancel: run not found' using errcode = 'P0002';
  end if;
  select * into v_run from nomad_studynote.runs r where r.id = p_run_id for update;
  if v_run.status = 'queued' then
    if v_run.job_id is not null then
      perform nomad_core.cancel_job(v_run.job_id);
    end if;
    update nomad_studynote.run_steps set status = 'canceled', finished_at = now() where run_id = p_run_id and status = 'pending';
    update nomad_studynote.runs set status = 'canceled', finished_at = now(), cancel_requested_at = now(),
           credits_refunded = credits_charged
    where id = p_run_id returning * into v_run;
    perform nomad_studynote_private.release_budget(v_run.queued_at, v_run.credits_charged);
    update nomad_studynote.entries
    set status = case when final_text is not null then 'organized' else 'draft' end
    where id = v_run.entry_id and status = 'organizing';
  elsif v_run.status = 'running' then
    update nomad_studynote.runs set cancel_requested_at = coalesce(cancel_requested_at, now())
    where id = p_run_id returning * into v_run;
  else
    raise exception 'request_run_cancel: run is already %', v_run.status using errcode = 'NT003';
  end if;
  perform nomad_core.write_audit(v_run.organization_id, 'studynote.run.cancel', 'studynote_run', p_run_id::text);
  return v_run;
end;
$$;

-- =====================================================================
-- 11-1. reconcile_runs (서버 전용, 스케줄러가 nomad_core.reap_stale_jobs 뒤에 호출): 작업은 failed·canceled로 끝났는데
--       실행이 queued·running에 남은 경우(워커 사망) 정리 — 실행·단계 종료, 일지 상태 복귀, 예산 되돌리기.
--       크레딧은 core(fail_job·cancel_job)가 이미 환불했으므로(결과 미전달 = refund_on_failure 유지) 기록만 맞춘다.
--       p_organization_id null = 전체. 반환: 정리한 실행 수.
-- =====================================================================
create function nomad_studynote.reconcile_runs(p_organization_id uuid default null) returns integer
language plpgsql security definer set search_path = ''
as $$
declare r record; v_n integer := 0; v_status text;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'reconcile_runs: service_role only' using errcode = '42501';
  end if;
  for r in
    select x.id, x.status as run_status, x.entry_id, x.queued_at, x.credits_charged, j.status as job_status
    from nomad_studynote.runs x join nomad_core.jobs j on j.id = x.job_id
    where x.status in ('queued', 'running') and j.status in ('failed', 'canceled')
      and (p_organization_id is null or x.organization_id = p_organization_id)
    for update of x skip locked
  loop
    v_status := case when r.job_status = 'canceled' then 'canceled' else 'failed' end;
    update nomad_studynote.run_steps
    set status = case when v_status = 'canceled' then 'canceled' else 'failed' end,
        error_code = coalesce(error_code, 'job_' || r.job_status), finished_at = now()
    where run_id = r.id and status in ('pending', 'running');
    update nomad_studynote.runs
    set status = v_status, finished_at = now(), credits_refunded = credits_charged,
        error_code = 'job_' || r.job_status, error_message = 'job ended without result'
    where id = r.id;
    update nomad_studynote.entries
    set status = case when final_text is not null then 'organized' else 'draft' end
    where id = r.entry_id and status = 'organizing';
    perform nomad_studynote_private.release_budget(r.queued_at, r.credits_charged);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- =====================================================================
-- 12. RLS 정책과 GRANT (anon: 테이블 권한 0)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['model_catalog', 'runtime_config', 'cost_guard', 'user_settings', 'entries', 'runs', 'run_steps'] loop
    execute format('alter table nomad_studynote.%I enable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema nomad_studynote from public, anon, authenticated;
grant all on all tables in schema nomad_studynote to service_role;

grant select on nomad_studynote.model_catalog to authenticated;
create policy model_catalog_select on nomad_studynote.model_catalog for select to authenticated using (is_active);

grant select on nomad_studynote.user_settings to authenticated;
grant insert (user_id, base_model_1, base_model_2, merge_model, theme) on nomad_studynote.user_settings to authenticated;
grant update (base_model_1, base_model_2, merge_model, theme) on nomad_studynote.user_settings to authenticated;
create policy user_settings_select on nomad_studynote.user_settings for select to authenticated
  using (user_id = (select auth.uid()) and nomad_studynote.has_access());
create policy user_settings_insert on nomad_studynote.user_settings for insert to authenticated
  with check (user_id = (select auth.uid()) and nomad_studynote.has_access());
create policy user_settings_update on nomad_studynote.user_settings for update to authenticated
  using (user_id = (select auth.uid()) and nomad_studynote.has_access())
  with check (user_id = (select auth.uid()) and nomad_studynote.has_access());

grant select on nomad_studynote.entries to authenticated;
grant insert (id, entry_date, input_text) on nomad_studynote.entries to authenticated;  -- id: 오프라인 생성 멱등(원본에 없음)
grant update (entry_date, input_text, deleted_at) on nomad_studynote.entries to authenticated;
grant delete on nomad_studynote.entries to authenticated;
-- soft delete된 행도 읽힌다(휴지통 30일·복원). 목록 쿼리가 deleted_at is null로 거른다.
create policy entries_select on nomad_studynote.entries for select to authenticated
  using (user_id = (select auth.uid()) and nomad_studynote.has_access());
create policy entries_insert on nomad_studynote.entries for insert to authenticated
  with check (user_id = (select auth.uid()) and nomad_studynote.has_access());
create policy entries_update on nomad_studynote.entries for update to authenticated
  using (user_id = (select auth.uid()) and nomad_studynote.has_access())
  with check (user_id = (select auth.uid()) and nomad_studynote.has_access());
create policy entries_delete on nomad_studynote.entries for delete to authenticated
  using (user_id = (select auth.uid()));

grant select on nomad_studynote.runs, nomad_studynote.run_steps to authenticated;
create policy runs_select on nomad_studynote.runs for select to authenticated
  using (user_id = (select auth.uid()) and nomad_studynote.has_access());
create policy run_steps_select on nomad_studynote.run_steps for select to authenticated
  using (user_id = (select auth.uid()) and nomad_studynote.has_access());

revoke execute on all functions in schema nomad_studynote from public, anon, authenticated;
grant execute on all functions in schema nomad_studynote to service_role;
grant execute on function nomad_studynote.has_access(), nomad_studynote.request_run_cancel(uuid)
  to authenticated;
revoke execute on all functions in schema nomad_studynote_private from public, anon, authenticated;
grant execute on all functions in schema nomad_studynote_private to service_role;

-- =====================================================================
-- 13. 설정 시드(카탈로그 — 수치 한도 아님). 모델 ID·등급·크레딧은 원본 제안값.
-- =====================================================================
insert into nomad_studynote.model_catalog (model_id, display_name, provider, tier, credits_per_call, is_free, sort_order) values
  ('deepseek/deepseek-v4-flash',           'DeepSeek V4 Flash',    'DeepSeek',  'lite',     1, false, 10),
  ('qwen/qwen3.5-flash-02-23',             'Qwen 3.5 Flash',       'Qwen',      'lite',     1, false, 11),
  ('google/gemini-3-flash-preview',        'Gemini 3 Flash',       'Google',    'lite',     1, false, 12),
  ('openai/gpt-5-mini',                    'GPT-5 Mini',           'OpenAI',    'lite',     1, false, 13),
  ('tencent/hy3-preview',                  'Tencent Hy3',          'Tencent',   'lite',     1, false, 14),
  ('openai/gpt-oss-120b:free',             'GPT-OSS 120B (Free)',  'OpenAI',    'lite',     1, true,  20),
  ('z-ai/glm-4.5-air:free',                'GLM 4.5 Air (Free)',   'Z-AI',      'lite',     1, true,  21),
  ('arcee-ai/trinity-large-thinking:free', 'Trinity Large (Free)', 'Arcee',     'lite',     1, true,  22),
  ('anthropic/claude-sonnet-4.6',          'Claude Sonnet 4.6',    'Anthropic', 'standard', 2, false, 30),
  ('moonshotai/kimi-k2.6',                 'Kimi K2.6',            'Moonshot',  'standard', 2, false, 31),
  ('qwen/qwen3.6-plus',                    'Qwen 3.6 Plus',        'Qwen',      'standard', 2, false, 32),
  ('anthropic/claude-opus-4.7',            'Claude Opus 4.7',      'Anthropic', 'premium',  4, false, 40),
  ('openai/gpt-5.5',                       'GPT-5.5',              'OpenAI',    'premium',  4, false, 41)
on conflict (model_id) do nothing;

insert into nomad_studynote.runtime_config (key, value_int, note) values
  ('daily_credit_cap',        5000, '제안: 공개 베타 일일 전체 크레딧 소비 상한(환불분은 되돌림)'),
  ('daily_credit_cap_per_org', 300, '제안: 조직(과금 조직)별 일일 상한 기본값. plan_limits daily_credit_cap이 있으면 그 값'),
  ('max_active_runs_per_org', 2,    '제안: 과금 조직당 동시 활성 실행 수')
on conflict (key) do nothing;

commit;
