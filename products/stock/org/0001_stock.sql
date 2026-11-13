-- stock-dashboard 이식 · 조직형(org안). 원본: platform-docs _supabase-modular/migrations/1900_stock.sql 1~11절(14절 AI는 0002_ai.sql)
-- core.organizations→nomad_core.organizations(org_id→organization_id), org_members→nomad_core.memberships(member→editor),
-- has_entitlement→nomad_core.has_feature(기능 stock/dashboard), encrypted_credentials→nomad_core.provider_credentials,
-- core.write_audit→nomad_core.write_audit, guard_privileged_write→권한(GRANT) 미부여로 대체. 대응표: products/stock/existing.md
-- 금액(*_krw)은 정수(bigint, 원). 시세·단가(price)는 시장 데이터라 numeric 유지.
-- 전제: nomad_core.touch_updated_at() (core 20261119000100). 되돌림: drop schema nomad_stock cascade; (api_providers kis·kiwoom·hana 행은 남겨도 무해)
begin;

create schema nomad_stock;
revoke all on schema nomad_stock from public, anon, authenticated;
grant usage on schema nomad_stock to authenticated, service_role;  -- anon 사용 없음(공개 RPC 없음)

insert into nomad_core.products (code, name) values ('stock', 'Stock Dashboard') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('stock', 'A', 'A'), ('stock', 'B', 'B'), ('stock', 'C', 'C') on conflict do nothing;
-- 원본 플랜 대응: pro→A, beta→B, default(기능 없음)→C. 구독이 끊기면(C 취급) 대시보드 전체가 잠긴다.
insert into nomad_core.features (product_code, code, name) values
  ('stock', 'dashboard', '포트폴리오 대시보드·동기화·AI 진단'),
  ('stock', 'ai_compare', 'AI 모델 비교 진단'),
  ('stock', 'ideas', 'AI 아이디어'),
  ('stock', 'leaderboard', '아이디어 성과 리더보드'),
  ('stock', 'paper_orders', '모의투자 주문')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('stock', 'A', 'dashboard'), ('stock', 'B', 'dashboard'),
  ('stock', 'A', 'ai_compare'), ('stock', 'A', 'ideas'), ('stock', 'A', 'leaderboard'), ('stock', 'A', 'paper_orders')
on conflict do nothing;
-- plan_limits 키(수치 시드 안 함): ai_diagnosis_per_day · broker_connections_max · history_days · monthly_credits(원본 beta 300 / pro 400)

-- 증권사 자격 증명은 nomad_core.provider_credentials(Vault)에만. 제공자 코드를 등록한다.
insert into nomad_core.api_providers (code, name) values
  ('kis', '한국투자증권 Open API'), ('kiwoom', '키움증권 REST API'), ('hana', '하나증권 Open API')
on conflict (code) do nothing;

-- ---------- 1. 공용 트리거 함수 ----------
-- 상태 전이 강제. 인자 'a>b' = a→b 허용, '>a' = INSERT 초기 상태 a.
create function nomad_stock.enforce_status_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if not (('>' || new.status) = any (tg_argv)) then
      raise exception '%.%: invalid initial status %', tg_table_schema, tg_table_name, new.status using errcode = '22023';
    end if;
  elsif new.status is distinct from old.status then
    if not ((old.status || '>' || new.status) = any (tg_argv)) then
      raise exception '%.%: invalid transition % -> %', tg_table_schema, tg_table_name, old.status, new.status using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

-- append-only 로그. 직접 UPDATE·DELETE 금지. 조직 삭제 cascade(트리거 깊이 > 1)만 통과.
create function nomad_stock.reject_log_mutation() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception '%.% is append-only (%)', tg_table_schema, tg_table_name, tg_op using errcode = 'ST000';
end;
$$;

-- ---------- 2. 베타 초대와 접근 게이트 ----------
create table nomad_stock.beta_invites (
  id                       uuid primary key default gen_random_uuid(),
  email_normalized         text not null
                           constraint beta_invites_email_check check (email_normalized = lower(btrim(email_normalized)) and position('@' in email_normalized) > 1),
  token_hash               text not null unique
                           constraint beta_invites_token_hash_check check (token_hash ~ '^[0-9a-f]{64}$'),
  status                   text not null default 'issued'
                           constraint beta_invites_status_check check (status in ('issued', 'accepted', 'revoked', 'expired')),
  expires_at               timestamptz not null default (now() + interval '14 days'),
  invited_by               uuid,
  accepted_user_id         uuid,
  accepted_organization_id uuid references nomad_core.organizations(id) on delete set null,
  accepted_at              timestamptz,
  revoked_at               timestamptz,
  note                     text constraint beta_invites_note_check check (note is null or char_length(note) <= 200),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
comment on table nomad_stock.beta_invites is '베타 초대(토큰은 sha256만). service_role 전용.';
create unique index beta_invites_open_email_uniq on nomad_stock.beta_invites (email_normalized) where status = 'issued';
create index beta_invites_expiry_idx on nomad_stock.beta_invites (expires_at) where status = 'issued';

create table nomad_stock.beta_access (
  organization_id uuid primary key references nomad_core.organizations(id) on delete cascade,
  invite_id       uuid references nomad_stock.beta_invites(id) on delete set null,
  status          text not null default 'active' constraint beta_access_status_check check (status in ('active', 'revoked')),
  granted_at      timestamptz not null default now(),
  granted_by      uuid,
  revoked_at      timestamptz,
  revoke_reason   text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table nomad_stock.beta_access is '조직별 베타 접근(초대 수락). 회수하면 모든 도메인 정책이 0행.';

-- 도메인 RLS 단일 판정: 멤버 + 기능 이용권(stock/dashboard) + 베타 접근.
create function nomad_stock.has_stock_access(p_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_organization is not null
     and nomad_core.has_feature(p_organization, 'stock', 'dashboard')
     and exists (select 1 from nomad_stock.beta_access b where b.organization_id = p_organization and b.status = 'active')
$$;

-- 호출자가 이용 가능한 조직이 하나라도 있는지(전역 시장 데이터·전역 킬 스위치 읽기 정책).
create function nomad_stock.has_any_stock_access() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_core.memberships m
                  where m.user_id = (select auth.uid()) and nomad_stock.has_stock_access(m.organization_id))
$$;

-- ---------- 3. 참조 데이터(전역): 종목·재무·일봉(내부)·장 캘린더 ----------
create table nomad_stock.instruments (
  symbol      text primary key constraint instruments_symbol_check check (symbol ~ '^[0-9A-Z]{6}$'),
  name        text not null,
  market      text not null constraint instruments_market_check check (market in ('KOSPI', 'KOSDAQ', 'KONEX', 'ETF', 'ETN', 'INDEX')),
  sector      text,
  is_active   boolean not null default true,
  listed_on   date,
  delisted_on date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table nomad_stock.instruments is '종목 마스터(전역). 로그인 사용자 읽기, 쓰기 service_role.';

create table nomad_stock.fundamentals (
  id                 bigint generated always as identity primary key,
  symbol             text not null references nomad_stock.instruments(symbol) on delete cascade,
  fiscal_period      text not null constraint fundamentals_period_check check (fiscal_period ~ '^[0-9]{4}(Q[1-4]|FY)$'),
  per                numeric(10,2),
  pbr                numeric(10,2),
  roe_pct            numeric(8,2),
  eps_krw            bigint,
  dividend_yield_pct numeric(6,2),
  source             text not null constraint fundamentals_source_check check (source in ('dart', 'broker', 'manual')),
  source_ref         text,
  as_of              date not null,
  computed_at        timestamptz not null default now(),
  unique (symbol, fiscal_period, source)
);
comment on table nomad_stock.fundamentals is '재무지표(출처·기준일). 로그인 사용자 읽기.';
create index fundamentals_symbol_idx on nomad_stock.fundamentals (symbol, as_of desc);

create table nomad_stock.daily_prices (
  symbol     text not null references nomad_stock.instruments(symbol) on delete cascade,
  trade_date date not null,
  open       numeric(18,2),
  high       numeric(18,2),
  low        numeric(18,2),
  close      numeric(18,2) not null constraint daily_prices_close_check check (close > 0),
  volume     bigint,
  source     text not null constraint daily_prices_source_check check (source in ('broker', 'krx', 'mock')),
  created_at timestamptz not null default now(),
  primary key (symbol, trade_date)
);
comment on table nomad_stock.daily_prices is '일봉(성과 계산 전용). 시세 재배포 제한 — 사용자 권한 없음, service_role만.';
create index daily_prices_date_idx on nomad_stock.daily_prices (trade_date);

create table nomad_stock.market_calendar (
  trade_date date primary key,
  is_open    boolean not null,
  open_at    timestamptz,
  close_at   timestamptz,
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint market_calendar_hours_check check (not is_open or (open_at is not null and close_at is not null and open_at < close_at))
);
comment on table nomad_stock.market_calendar is '장 운영 캘린더(전역). 로그인 사용자 읽기.';

-- ---------- 4. 증권사 연결과 동기화 결과 (쓰기 service_role) ----------
create table nomad_stock.broker_connections (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  broker             text not null constraint broker_connections_broker_check check (broker in ('mock', 'kis', 'kiwoom', 'hana')),
  env                text not null default 'paper' constraint broker_connections_env_check check (env in ('paper', 'live')),
  label              text constraint broker_connections_label_check check (label is null or char_length(label) <= 40),
  account_masked     text not null
                     constraint broker_connections_account_masked_check check (account_masked ~ '^[0-9*-]{4,24}$' and account_masked ~ '[*]' and account_masked !~ '[0-9]{5,}'),
  account_ref_hash   text not null constraint broker_connections_account_ref_check check (account_ref_hash ~ '^[0-9a-f]{64}$'),
  credential_id      uuid references nomad_core.provider_credentials(id) on delete set null,
  status             text not null default 'pending'
                     constraint broker_connections_status_check check (status in ('pending', 'active', 'error', 'revoked')),
  orders_enabled     boolean not null default false,
  last_synced_at     timestamptz,
  last_error_code    text,
  consecutive_errors integer not null default 0 constraint broker_connections_errors_check check (consecutive_errors >= 0),
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (id, organization_id),
  unique (organization_id, broker, env, account_ref_hash),
  constraint broker_connections_orders_paper_check check (not orders_enabled or env = 'paper'),
  constraint broker_connections_mock_paper_check check (broker <> 'mock' or env = 'paper'),
  constraint broker_connections_credential_check check (broker = 'mock' or status in ('pending', 'revoked') or credential_id is not null)
);
comment on table nomad_stock.broker_connections is '증권사 연결(계좌는 마스킹+HMAC만, 키는 provider_credentials). 쓰기 service_role.';
create index broker_connections_org_idx on nomad_stock.broker_connections (organization_id, updated_at) where status <> 'revoked';
create index broker_connections_credential_idx on nomad_stock.broker_connections (credential_id) where credential_id is not null;

-- 연결의 키는 같은 조직·같은 증권사(provider_code = broker)·폐기되지 않은 것만.
create function nomad_stock.broker_connections_check_credential() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.credential_id is not null and not exists (
       select 1 from nomad_core.provider_credentials c
        where c.id = new.credential_id and c.organization_id = new.organization_id
          and c.provider_code = new.broker and c.revoked_at is null) then
    raise exception 'broker_connections: credential must be an active % key of the same organization', new.broker using errcode = 'ST050';
  end if;
  return new;
end;
$$;
create trigger broker_connections_check_credential before insert or update of credential_id, broker, organization_id
  on nomad_stock.broker_connections for each row execute function nomad_stock.broker_connections_check_credential();


create table nomad_stock.balance_snapshots (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  connection_id   uuid not null,
  captured_at     timestamptz not null default now(),
  cash_krw        bigint not null default 0,
  purchase_krw    bigint not null default 0 constraint balance_snapshots_purchase_check check (purchase_krw >= 0),
  eval_krw        bigint not null default 0 constraint balance_snapshots_eval_check check (eval_krw >= 0),
  pnl_krw         bigint generated always as (eval_krw - purchase_krw) stored,
  is_sample       boolean not null default false,
  source          text not null default 'sync' constraint balance_snapshots_source_check check (source in ('sync', 'mock')),
  foreign key (connection_id, organization_id) references nomad_stock.broker_connections(id, organization_id) on delete cascade
);
comment on table nomad_stock.balance_snapshots is '잔고 스냅샷(원 단위 정수). 쓰기 service_role.';
create index balance_snapshots_conn_captured_idx on nomad_stock.balance_snapshots (connection_id, captured_at desc);
create index balance_snapshots_org_captured_idx on nomad_stock.balance_snapshots (organization_id, captured_at desc);

create table nomad_stock.holdings (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  connection_id   uuid not null,
  symbol          text not null constraint holdings_symbol_check check (symbol ~ '^[0-9A-Z]{6}$'),
  name            text not null,
  quantity        numeric(18,4) not null constraint holdings_quantity_check check (quantity >= 0),
  avg_price       numeric(18,2) not null constraint holdings_avg_price_check check (avg_price >= 0),
  purchase_krw    bigint not null constraint holdings_purchase_check check (purchase_krw >= 0),
  is_sample       boolean not null default false,
  synced_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (connection_id, symbol),
  foreign key (connection_id, organization_id) references nomad_stock.broker_connections(id, organization_id) on delete cascade
);
comment on table nomad_stock.holdings is '보유 종목(동기화 결과). 쓰기 service_role.';
create index holdings_org_updated_idx on nomad_stock.holdings (organization_id, updated_at);

create table nomad_stock.trades (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  connection_id   uuid not null,
  broker_exec_id  text not null,
  symbol          text not null constraint trades_symbol_check check (symbol ~ '^[0-9A-Z]{6}$'),
  name            text not null,
  side            text not null constraint trades_side_check check (side in ('buy', 'sell')),
  quantity        numeric(18,4) not null constraint trades_quantity_check check (quantity > 0),
  price           numeric(18,2) not null constraint trades_price_check check (price >= 0),
  amount_krw      bigint not null,
  fee_krw         bigint not null default 0,
  tax_krw         bigint not null default 0,
  executed_at     timestamptz not null,
  is_sample       boolean not null default false,
  synced_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  unique (connection_id, broker_exec_id),
  foreign key (connection_id, organization_id) references nomad_stock.broker_connections(id, organization_id) on delete cascade
);
comment on table nomad_stock.trades is '체결 내역(broker_exec_id로 멱등). 쓰기 service_role.';
create index trades_org_executed_idx on nomad_stock.trades (organization_id, executed_at desc);
create index trades_org_symbol_idx on nomad_stock.trades (organization_id, symbol, executed_at desc);
create index trades_org_updated_idx on nomad_stock.trades (organization_id, updated_at);

-- 사용자가 직접 쓰는 유일한 도메인 표(순수 메모). 동기화 대상: updated_at + deleted_at(소프트 삭제).
create table nomad_stock.trade_notes (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  trade_id        uuid not null,
  body            text not null constraint trade_notes_body_check check (char_length(body) between 1 and 2000),
  tags            text[] not null default '{}' constraint trade_notes_tags_check check (cardinality(tags) <= 10),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  foreign key (trade_id, organization_id) references nomad_stock.trades(id, organization_id) on delete cascade
);
comment on table nomad_stock.trade_notes is '체결 메모(작성자 본인 쓰기). 소프트 삭제 deleted_at.';
create index trade_notes_trade_idx on nomad_stock.trade_notes (trade_id);
create index trade_notes_org_updated_idx on nomad_stock.trade_notes (organization_id, updated_at);

-- ---------- 5. AI 진단 리포트와 성과 평가 (쓰기 service_role) ----------
create table nomad_stock.ai_reports (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  kind                text not null default 'diagnosis' constraint ai_reports_kind_check check (kind in ('diagnosis', 'idea', 'research', 'briefing')),
  scope_connection_id uuid,
  status              text not null default 'queued'
                      constraint ai_reports_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  mode                text not null default 'quality' constraint ai_reports_mode_check check (mode in ('fast', 'quality')),
  provider            text,
  model               text,
  prompt_version      text not null,
  input_hash          text not null constraint ai_reports_input_hash_check check (input_hash ~ '^[0-9a-f]{64}$'),
  input_summary       jsonb not null default '{}'::jsonb,
  output              jsonb,
  disclaimer_version  text not null,
  credits_charged     integer not null default 0 constraint ai_reports_credits_check check (credits_charged >= 0),
  credit_ledger_id    uuid references nomad_core.credit_ledger(id),
  request_id          uuid not null unique,
  error_code          text,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  started_at          timestamptz,
  finished_at         timestamptz,
  updated_at          timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (scope_connection_id, organization_id) references nomad_stock.broker_connections(id, organization_id) on delete set null (scope_connection_id),
  -- 진단은 매수가·목표가·손절가를 저장할 수 없다(키 이름 수준 마지막 방어선)
  constraint ai_reports_no_price_targets_check check (
    output is null or output::text !~* '"(buy_price|entry_price|target_price|stop_price|stop_loss)"[[:space:]]*:'
  ),
  constraint ai_reports_output_status_check check (status <> 'succeeded' or output is not null),
  -- 성공 결과는 투자 권유 검사 기록(output.advice_check.passed = true)이 있어야 한다
  constraint ai_reports_advice_check_passed_check check (status <> 'succeeded' or coalesce(output #>> '{advice_check,passed}', 'false') = 'true')
);
comment on table nomad_stock.ai_reports is 'AI 진단·아이디어·리서치·브리핑 리포트. request_id 멱등, 크레딧은 nomad_core.consume_credits.';
create index ai_reports_org_created_idx on nomad_stock.ai_reports (organization_id, created_at desc);
create index ai_reports_org_day_idx on nomad_stock.ai_reports (organization_id, kind, created_at) where status in ('queued', 'running', 'succeeded');

-- 크레딧 원장은 같은 조직의 차감(consume) 행만 연결한다.
create function nomad_stock.ai_reports_check_ledger() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.credit_ledger_id is not null and not exists (
       select 1 from nomad_core.credit_ledger l
        where l.id = new.credit_ledger_id and l.organization_id = new.organization_id and l.delta < 0) then
    raise exception 'ai_reports: credit entry must be a consume of the same organization' using errcode = 'ST051';
  end if;
  return new;
end;
$$;
create trigger ai_reports_check_ledger before insert or update of credit_ledger_id, organization_id
  on nomad_stock.ai_reports for each row execute function nomad_stock.ai_reports_check_ledger();

create table nomad_stock.ai_report_items (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  report_id       uuid not null,
  symbol          text not null constraint ai_report_items_symbol_check check (symbol ~ '^[0-9A-Z]{6}$'),
  risk_level      text not null constraint ai_report_items_risk_check check (risk_level in ('low', 'medium', 'high')),
  weight_pct      numeric(6,2) constraint ai_report_items_weight_check check (weight_pct is null or weight_pct between 0 and 100),
  factors         jsonb not null default '[]'::jsonb constraint ai_report_items_factors_check check (jsonb_typeof(factors) = 'array'),
  rationale       text constraint ai_report_items_rationale_check check (rationale is null or char_length(rationale) <= 1000),
  reference_price numeric(18,2) constraint ai_report_items_ref_price_check check (reference_price is null or reference_price > 0),
  reference_at    timestamptz,
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  unique (report_id, symbol),
  foreign key (report_id, organization_id) references nomad_stock.ai_reports(id, organization_id) on delete cascade
);
comment on table nomad_stock.ai_report_items is '리포트 종목별 항목. 쓰기 service_role.';
create index ai_report_items_org_idx on nomad_stock.ai_report_items (organization_id);

create table nomad_stock.idea_evaluations (
  id                   bigint generated always as identity primary key,
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  item_id              uuid not null,
  horizon_days         smallint not null constraint idea_evaluations_horizon_check check (horizon_days in (5, 20, 60)),
  entry_date           date not null,
  entry_price          numeric(18,2) not null constraint idea_evaluations_entry_check check (entry_price > 0),
  eval_date            date not null,
  eval_price           numeric(18,2) not null constraint idea_evaluations_eval_check check (eval_price > 0),
  return_pct           numeric(9,4) not null,
  benchmark_return_pct numeric(9,4) not null,
  excess_pct           numeric(9,4) generated always as (return_pct - benchmark_return_pct) stored,
  rule_version         text not null,
  computed_at          timestamptz not null default now(),
  unique (item_id, horizon_days),
  constraint idea_evaluations_dates_check check (eval_date > entry_date),
  foreign key (item_id, organization_id) references nomad_stock.ai_report_items(id, organization_id) on delete cascade
);
comment on table nomad_stock.idea_evaluations is '아이디어 성과(리더보드, Phase 2). 읽기는 leaderboard 기능이 열린 조직만.';
create index idea_evaluations_org_idx on nomad_stock.idea_evaluations (organization_id, horizon_days);

-- ---------- 6. 동의 기록 (append-only, record_consent로만) ----------
create table nomad_stock.consents (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id         uuid not null,
  kind            text not null constraint consents_kind_check check (kind in ('investment_disclaimer', 'ai_overseas_transfer', 'paper_order_risk', 'voice_processing')),
  version         text not null constraint consents_version_check check (version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$'),
  accepted_at     timestamptz not null default now(),
  unique (organization_id, user_id, kind, version)
);
comment on table nomad_stock.consents is '투자 고지·국외 이전·모의주문 위험·음성 처리 동의 증빙(append-only).';
create index consents_user_kind_idx on nomad_stock.consents (user_id, kind, accepted_at desc);

-- ---------- 7. 모의투자 주문 안전장치 (env = paper만, 실전 주문 행 불가) ----------
create table nomad_stock.order_limits (
  organization_id         uuid primary key references nomad_core.organizations(id) on delete cascade,
  max_order_krw           bigint not null default 1000000
                          constraint order_limits_max_order_check check (max_order_krw between 10000 and 10000000),
  max_daily_krw           bigint not null default 5000000
                          constraint order_limits_max_daily_check check (max_daily_krw between 10000 and 50000000),
  max_orders_per_day      integer not null default 20
                          constraint order_limits_max_orders_check check (max_orders_per_day between 1 and 100),
  max_position_weight_pct numeric(5,2) not null default 30
                          constraint order_limits_weight_check check (max_position_weight_pct between 1 and 100),
  max_price_deviation_pct numeric(5,2) not null default 5
                          constraint order_limits_deviation_check check (max_price_deviation_pct between 0.5 and 10),
  max_quote_age_seconds   integer not null default 10
                          constraint order_limits_quote_age_check check (max_quote_age_seconds between 1 and 60),
  updated_by              uuid,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint order_limits_daily_ge_order_check check (max_daily_krw >= max_order_krw)
);
comment on table nomad_stock.order_limits is '조직별 모의주문 한도(플랫폼 상한은 CHECK). 변경은 set_order_limits.';

create table nomad_stock.kill_switches (
  id              uuid primary key default gen_random_uuid(),
  scope           text not null constraint kill_switches_scope_check check (scope in ('global', 'org', 'connection')),
  organization_id uuid references nomad_core.organizations(id) on delete cascade,
  connection_id   uuid references nomad_stock.broker_connections(id) on delete cascade,
  is_active       boolean not null default true,
  trigger_source  text not null default 'manual'
                  constraint kill_switches_source_check check (trigger_source in ('manual', 'ops', 'auto_quote_stale', 'auto_broker_errors', 'auto_balance_mismatch')),
  reason          text not null constraint kill_switches_reason_check check (char_length(reason) between 1 and 200),
  engaged_by      uuid,
  engaged_at      timestamptz not null default now(),
  released_by     uuid,
  released_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint kill_switches_target_check check (
       (scope = 'global' and organization_id is null and connection_id is null)
    or (scope = 'org' and organization_id is not null and connection_id is null)
    or (scope = 'connection' and organization_id is not null and connection_id is not null)),
  constraint kill_switches_release_check check (is_active or released_at is not null)
);
comment on table nomad_stock.kill_switches is '킬 스위치(전역 > 조직 > 연결). 켜기는 멤버 누구나, 해제는 owner/admin(수동만).';
create unique index kill_switches_one_active_idx on nomad_stock.kill_switches
  (scope, coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(connection_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where is_active;
create index kill_switches_org_idx on nomad_stock.kill_switches (organization_id) where is_active;

create table nomad_stock.order_requests (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  connection_id      uuid not null,
  client_order_id    uuid not null unique,
  env                text not null default 'paper' constraint order_requests_env_check check (env = 'paper'),
  symbol             text not null constraint order_requests_symbol_check check (symbol ~ '^[0-9A-Z]{6}$'),
  side               text not null constraint order_requests_side_check check (side in ('buy', 'sell')),
  order_type         text not null default 'limit' constraint order_requests_type_check check (order_type = 'limit'),
  quantity           integer not null constraint order_requests_quantity_check check (quantity > 0),
  limit_price        numeric(18,2) not null constraint order_requests_limit_price_check check (limit_price > 0),
  est_amount_krw     bigint generated always as (round(quantity * limit_price)::bigint) stored,
  ref_price          numeric(18,2) not null constraint order_requests_ref_price_check check (ref_price > 0),
  ref_price_at       timestamptz not null,
  status             text not null default 'pending_confirm'
                     constraint order_requests_status_check check (status in ('pending_confirm', 'confirmed', 'submitted', 'accepted',
                       'partially_filled', 'filled', 'rejected', 'canceled', 'expired', 'blocked', 'failed')),
  limit_check        jsonb not null default '{}'::jsonb,
  block_reason       text,
  confirm_expires_at timestamptz not null,
  confirmed_at       timestamptz,
  confirmed_by       uuid,
  submitted_at       timestamptz,
  broker_order_id    text,
  filled_quantity    integer not null default 0 constraint order_requests_filled_check check (filled_quantity >= 0 and filled_quantity <= quantity),
  avg_fill_price     numeric(18,2),
  prefill_report_id  uuid,
  created_by         uuid not null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (id, organization_id),
  unique (connection_id, broker_order_id),
  foreign key (connection_id, organization_id) references nomad_stock.broker_connections(id, organization_id) on delete cascade,
  constraint order_requests_confirm_check check (status not in ('confirmed', 'submitted', 'accepted', 'partially_filled', 'filled')
                                                 or (confirmed_at is not null and confirmed_by is not null)),
  constraint order_requests_block_check check (status <> 'blocked' or block_reason is not null)
);
comment on table nomad_stock.order_requests is '모의주문(client_order_id 멱등, 생성자 본인 60초 확인). 생성 service_role.';
create index order_requests_org_created_idx on nomad_stock.order_requests (organization_id, created_at desc);
create index order_requests_pending_idx on nomad_stock.order_requests (confirm_expires_at) where status = 'pending_confirm';
create index order_requests_open_idx on nomad_stock.order_requests (connection_id) where status in ('confirmed', 'submitted', 'accepted', 'partially_filled');

create table nomad_stock.order_events (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  order_id        uuid not null,
  event           text not null constraint order_events_event_check check (event in ('created', 'blocked', 'confirmed', 'expired', 'canceled',
                    'submitted', 'broker_response', 'accepted', 'partially_filled', 'filled', 'rejected', 'failed')),
  from_status     text,
  to_status       text,
  detail          jsonb not null default '{}'::jsonb,
  actor_id        uuid,
  actor_role      text not null constraint order_events_actor_check check (actor_role in ('user', 'service', 'system')),
  created_at      timestamptz not null default now(),
  foreign key (order_id, organization_id) references nomad_stock.order_requests(id, organization_id) on delete cascade
);
comment on table nomad_stock.order_events is '주문 이벤트 로그(append-only).';
create index order_events_order_idx on nomad_stock.order_events (order_id, id);
create index order_events_org_idx on nomad_stock.order_events (organization_id);

-- ---------- 8. 트리거 ----------
do $$
declare t text;
begin
  foreach t in array array['beta_invites', 'beta_access', 'instruments', 'market_calendar', 'broker_connections',
                           'holdings', 'trades', 'trade_notes', 'ai_reports', 'order_limits', 'kill_switches', 'order_requests']
  loop
    execute format('create trigger %I_touch before update on nomad_stock.%I for each row execute function nomad_core.touch_updated_at()', t, t);
  end loop;
end $$;

create trigger beta_invites_status_transition before insert or update of status on nomad_stock.beta_invites
  for each row execute function nomad_stock.enforce_status_transition('>issued', 'issued>accepted', 'issued>revoked', 'issued>expired');
create trigger beta_access_status_transition before insert or update of status on nomad_stock.beta_access
  for each row execute function nomad_stock.enforce_status_transition('>active', 'active>revoked', 'revoked>active');
create trigger broker_connections_status_transition before insert or update of status on nomad_stock.broker_connections
  for each row execute function nomad_stock.enforce_status_transition(
    '>pending', '>active', 'pending>active', 'pending>error', 'pending>revoked',
    'active>error', 'active>revoked', 'error>active', 'error>revoked');
create trigger ai_reports_status_transition before insert or update of status on nomad_stock.ai_reports
  for each row execute function nomad_stock.enforce_status_transition(
    '>queued', 'queued>running', 'queued>canceled', 'queued>failed', 'running>succeeded', 'running>failed');
create trigger order_requests_status_transition before insert or update of status on nomad_stock.order_requests
  for each row execute function nomad_stock.enforce_status_transition(
    '>pending_confirm', '>blocked',
    'pending_confirm>confirmed', 'pending_confirm>expired', 'pending_confirm>canceled', 'pending_confirm>blocked',
    'confirmed>submitted', 'confirmed>blocked', 'confirmed>failed',
    'submitted>accepted', 'submitted>rejected', 'submitted>failed',
    'accepted>partially_filled', 'accepted>filled', 'accepted>canceled', 'accepted>rejected',
    'partially_filled>partially_filled', 'partially_filled>filled', 'partially_filled>canceled');
create trigger consents_immutable before update or delete on nomad_stock.consents
  for each row execute function nomad_stock.reject_log_mutation();
create trigger order_events_immutable before update or delete on nomad_stock.order_events
  for each row execute function nomad_stock.reject_log_mutation();

-- ---------- 9. RLS ----------
do $$
declare t text;
begin
  foreach t in array array['beta_invites', 'beta_access', 'instruments', 'fundamentals', 'daily_prices', 'market_calendar',
                           'broker_connections', 'balance_snapshots', 'holdings', 'trades', 'trade_notes', 'ai_reports',
                           'ai_report_items', 'idea_evaluations', 'consents', 'order_limits', 'kill_switches', 'order_requests', 'order_events']
  loop
    execute format('alter table nomad_stock.%I enable row level security', t);
    execute format('revoke all on table nomad_stock.%I from public, anon, authenticated', t);
    execute format('grant all on table nomad_stock.%I to service_role', t);
  end loop;
  -- 읽기 권한(정책이 범위를 정한다). beta_invites·daily_prices는 사용자 권한 없음.
  foreach t in array array['beta_access', 'instruments', 'fundamentals', 'market_calendar',
                           'balance_snapshots', 'holdings', 'trades', 'trade_notes', 'ai_reports',
                           'ai_report_items', 'idea_evaluations', 'consents', 'order_limits', 'kill_switches', 'order_requests', 'order_events']
  loop
    execute format('grant select on table nomad_stock.%I to authenticated', t);
  end loop;
  foreach t in array array['broker_connections', 'balance_snapshots', 'holdings', 'trades', 'ai_reports', 'ai_report_items',
                           'order_limits', 'order_requests', 'order_events']
  loop
    execute format('create policy %I_select on nomad_stock.%I for select to authenticated using (nomad_stock.has_stock_access(organization_id))', t, t);
  end loop;
end $$;

-- broker_connections: 계좌 해시·키 id는 사용자 권한 없음(Realtime 발행도 같은 컬럼만)
grant select (id, organization_id, broker, env, label, account_masked, status, orders_enabled, last_synced_at,
              last_error_code, consecutive_errors, created_by, created_at, updated_at)
  on nomad_stock.broker_connections to authenticated;

create policy beta_access_select on nomad_stock.beta_access for select to authenticated
  using (nomad_core.organization_role(organization_id) is not null);
-- 시장 데이터: 이용 가능한 조직(구독+베타)이 있는 사용자만
create policy instruments_select on nomad_stock.instruments for select to authenticated using (nomad_stock.has_any_stock_access());
create policy fundamentals_select on nomad_stock.fundamentals for select to authenticated using (nomad_stock.has_any_stock_access());
create policy market_calendar_select on nomad_stock.market_calendar for select to authenticated using (nomad_stock.has_any_stock_access());
create policy idea_evaluations_select on nomad_stock.idea_evaluations for select to authenticated
  using (nomad_stock.has_stock_access(organization_id) and nomad_core.has_feature(organization_id, 'stock', 'leaderboard'));
create policy kill_switches_select on nomad_stock.kill_switches for select to authenticated
  using ((scope = 'global' and nomad_stock.has_any_stock_access()) or nomad_stock.has_stock_access(organization_id));
create policy consents_select on nomad_stock.consents for select to authenticated
  using (user_id = (select auth.uid()) and nomad_core.organization_role(organization_id) is not null);

-- trade_notes: 작성자 본인 쓰기, 삭제는 본인 또는 owner/admin
grant insert (organization_id, trade_id, body, tags) on nomad_stock.trade_notes to authenticated;
grant update (body, tags, deleted_at) on nomad_stock.trade_notes to authenticated;
grant delete on nomad_stock.trade_notes to authenticated;
create policy trade_notes_select on nomad_stock.trade_notes for select to authenticated
  using (nomad_stock.has_stock_access(organization_id));
create policy trade_notes_insert on nomad_stock.trade_notes for insert to authenticated
  with check (nomad_stock.has_stock_access(organization_id) and created_by = (select auth.uid())
              and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy trade_notes_update on nomad_stock.trade_notes for update to authenticated
  using (nomad_stock.has_stock_access(organization_id) and created_by = (select auth.uid()))
  with check (nomad_stock.has_stock_access(organization_id) and created_by = (select auth.uid()));
create policy trade_notes_delete on nomad_stock.trade_notes for delete to authenticated
  using (nomad_stock.has_stock_access(organization_id)
         and (created_by = (select auth.uid()) or nomad_core.organization_role(organization_id) in ('owner', 'admin')));

-- ---------- 10. RPC: 베타 초대 ----------
-- 초대 수락(service_role): 서버가 토큰 원문을 sha256으로 바꿔 넘긴다. 만료면 expired로 남기고 null(롤백 방지).
-- 플랜 전환(B 구독)과 첫 달 크레딧은 서버가 코어 경로로 처리한다.
create function nomad_stock.redeem_beta_invite(p_token_hash text, p_user_id uuid)
returns nomad_stock.beta_access language plpgsql security definer set search_path = ''
as $$
declare v_inv nomad_stock.beta_invites; v_email text; v_confirmed boolean; v_org uuid; v_row nomad_stock.beta_access;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'redeem_beta_invite: service_role only' using errcode = '42501';
  end if;
  select * into v_inv from nomad_stock.beta_invites where token_hash = p_token_hash for update;
  if not found then raise exception 'redeem_beta_invite: invite not found' using errcode = 'ST030'; end if;
  if v_inv.status = 'issued' and v_inv.expires_at <= now() then
    update nomad_stock.beta_invites set status = 'expired' where id = v_inv.id;
    return null;
  end if;
  if v_inv.status <> 'issued' then
    raise exception 'redeem_beta_invite: invite is %', v_inv.status using errcode = 'ST030';
  end if;
  select lower(u.email), u.email_confirmed_at is not null into v_email, v_confirmed from auth.users u where u.id = p_user_id;
  if v_email is null or v_email <> v_inv.email_normalized then
    raise exception 'redeem_beta_invite: email mismatch' using errcode = 'ST031';
  end if;
  if not v_confirmed then
    raise exception 'redeem_beta_invite: email not confirmed' using errcode = 'ST032';
  end if;
  select o.id into v_org from nomad_core.organizations o
    join nomad_core.memberships m on m.organization_id = o.id and m.user_id = p_user_id and m.role = 'owner'
   where o.kind = 'personal' and o.active
   order by o.created_at limit 1;
  if v_org is null then raise exception 'redeem_beta_invite: no personal organization' using errcode = 'P0002'; end if;

  update nomad_stock.beta_invites
     set status = 'accepted', accepted_user_id = p_user_id, accepted_organization_id = v_org, accepted_at = now()
   where id = v_inv.id;
  insert into nomad_stock.beta_access (organization_id, invite_id, status, granted_at, granted_by)
  values (v_org, v_inv.id, 'active', now(), v_inv.invited_by)
  on conflict (organization_id) do update
    set status = 'active', invite_id = excluded.invite_id, granted_at = now(), revoked_at = null, revoke_reason = null
  returning * into v_row;
  perform nomad_core.write_audit(v_org, 'stock.beta.accept', 'beta_invite', v_inv.id::text, null,
                                 jsonb_build_object('organization_id', v_org), jsonb_build_object('user_id', p_user_id));
  return v_row;
end;
$$;

-- 베타 회수(service_role): 회수하면 모든 도메인 정책이 즉시 0행.
create function nomad_stock.revoke_beta_access(p_organization_id uuid, p_reason text)
returns nomad_stock.beta_access language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_stock.beta_access;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'revoke_beta_access: service_role only' using errcode = '42501';
  end if;
  update nomad_stock.beta_access
     set status = 'revoked', revoked_at = now(), revoke_reason = left(coalesce(p_reason, ''), 200)
   where organization_id = p_organization_id and status = 'active'
  returning * into v_row;
  if found then
    perform nomad_core.write_audit(p_organization_id, 'stock.beta.revoke', 'organization', p_organization_id::text, null, null,
                                   jsonb_build_object('reason', left(coalesce(p_reason, ''), 200)));
  end if;
  return v_row;
end;
$$;

-- 본인 동의만 기록. 베타 접근이 있는 조직에서만. 같은 버전 재동의는 기존 행 반환.
create function nomad_stock.record_consent(p_organization_id uuid, p_kind text, p_version text)
returns nomad_stock.consents language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_stock.consents;
begin
  if (select auth.uid()) is null then
    raise exception 'record_consent: user session required' using errcode = '42501';
  end if;
  if not nomad_core.is_service_caller() and not nomad_stock.has_stock_access(p_organization_id) then
    raise exception 'record_consent: no stock access' using errcode = '42501';
  end if;
  insert into nomad_stock.consents (organization_id, user_id, kind, version)
  values (p_organization_id, (select auth.uid()), p_kind, p_version)
  on conflict (organization_id, user_id, kind, version) do nothing
  returning * into v_row;
  if v_row.id is null then
    select * into v_row from nomad_stock.consents
     where organization_id = p_organization_id and user_id = (select auth.uid()) and kind = p_kind and version = p_version;
  end if;
  return v_row;
end;
$$;

-- ---------- 11. RPC: 모의주문 ----------
create function nomad_stock.is_trading_blocked(p_organization_id uuid, p_connection_id uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from nomad_stock.kill_switches k
    where k.is_active
      and (k.scope = 'global'
           or (k.scope = 'org' and k.organization_id = p_organization_id)
           or (k.scope = 'connection' and k.connection_id = p_connection_id))
  )
$$;

-- 주문 적격(내부, 실행 권한 없음): 연결 active·paper·orders_enabled + 기능 paper_orders + 베타 접근.
-- 연결 사용 시점 검사(내부, 실행 권한 없음): 키가 코어에서 폐기됐으면 연결을 revoked·주문 불가로 표시하고 true.
-- 코어 표에 트리거를 걸지 않는다(제품 표만 갱신). 주문 생성·확인·제출이 부른다.
create function nomad_stock.revoke_if_credential_revoked(p_connection_id uuid) returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  update nomad_stock.broker_connections c set status = 'revoked', orders_enabled = false
   where c.id = p_connection_id and c.status <> 'revoked' and c.credential_id is not null
     and exists (select 1 from nomad_core.provider_credentials pc where pc.id = c.credential_id and pc.revoked_at is not null);
  return found;
end;
$$;

create function nomad_stock.order_eligible(p_organization_id uuid, p_connection_id uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_stock.broker_connections c
                  where c.id = p_connection_id and c.organization_id = p_organization_id
                    and c.status = 'active' and c.env = 'paper' and c.orders_enabled
                    and (c.credential_id is null
                         or exists (select 1 from nomad_core.provider_credentials pc where pc.id = c.credential_id and pc.revoked_at is null)))
     and nomad_core.org_has_feature(p_organization_id, 'stock', 'paper_orders')
     and exists (select 1 from nomad_stock.beta_access b where b.organization_id = p_organization_id and b.status = 'active')
$$;

create function nomad_stock.set_order_limits(
  p_organization_id uuid, p_max_order_krw bigint, p_max_daily_krw bigint, p_max_orders_per_day integer,
  p_max_position_weight_pct numeric, p_max_price_deviation_pct numeric
)
returns nomad_stock.order_limits language plpgsql security definer set search_path = ''
as $$
declare v_before nomad_stock.order_limits; v_row nomad_stock.order_limits;
begin
  if not nomad_core.is_service_caller() then
    if not nomad_stock.has_stock_access(p_organization_id)
       or coalesce(nomad_core.organization_role(p_organization_id), '') not in ('owner', 'admin') then
      raise exception 'set_order_limits: owner/admin with stock access only' using errcode = '42501';
    end if;
  end if;
  select * into v_before from nomad_stock.order_limits where organization_id = p_organization_id for update;
  insert into nomad_stock.order_limits (organization_id, max_order_krw, max_daily_krw, max_orders_per_day,
                                        max_position_weight_pct, max_price_deviation_pct, updated_by)
  values (p_organization_id, p_max_order_krw, p_max_daily_krw, p_max_orders_per_day,
          p_max_position_weight_pct, p_max_price_deviation_pct, (select auth.uid()))
  on conflict (organization_id) do update
    set max_order_krw = excluded.max_order_krw, max_daily_krw = excluded.max_daily_krw,
        max_orders_per_day = excluded.max_orders_per_day, max_position_weight_pct = excluded.max_position_weight_pct,
        max_price_deviation_pct = excluded.max_price_deviation_pct, updated_by = excluded.updated_by
  returning * into v_row;
  perform nomad_core.write_audit(p_organization_id, 'stock.order_limits.update', 'organization', p_organization_id::text,
                                 to_jsonb(v_before), to_jsonb(v_row));
  return v_row;
end;
$$;

-- 킬 스위치 작동: 조직 멤버 누구나, 구독·베타 상태와 무관하게(멈추는 쪽은 항상 허용). 대기·확인 주문을 즉시 blocked로.
create function nomad_stock.engage_kill_switch(p_organization_id uuid, p_connection_id uuid default null, p_reason text default 'manual stop')
returns nomad_stock.kill_switches language plpgsql security definer set search_path = ''
as $$
declare
  v_row   nomad_stock.kill_switches;
  v_scope text := case when p_connection_id is null then 'org' else 'connection' end;
  v_actor text := case when nomad_core.is_service_caller() then 'service' else 'user' end;
  r       record;
begin
  if p_organization_id is null then raise exception 'engage_kill_switch: organization required' using errcode = '22023'; end if;
  if not nomad_core.is_service_caller() and nomad_core.organization_role(p_organization_id) is null then
    raise exception 'engage_kill_switch: not a member' using errcode = '42501';
  end if;
  if p_connection_id is not null
     and not exists (select 1 from nomad_stock.broker_connections c where c.id = p_connection_id and c.organization_id = p_organization_id) then
    raise exception 'engage_kill_switch: connection not in organization' using errcode = '42501';
  end if;
  select * into v_row from nomad_stock.kill_switches k
   where k.is_active and k.scope = v_scope and k.organization_id = p_organization_id
     and k.connection_id is not distinct from p_connection_id;
  if not found then
    insert into nomad_stock.kill_switches (scope, organization_id, connection_id, is_active, trigger_source, reason, engaged_by)
    values (v_scope, p_organization_id, p_connection_id, true, 'manual',
            left(coalesce(nullif(btrim(p_reason), ''), 'manual stop'), 200), (select auth.uid()))
    returning * into v_row;
  end if;
  for r in
    select o.id, o.status from nomad_stock.order_requests o
     where o.organization_id = p_organization_id and o.status in ('pending_confirm', 'confirmed')
       and (p_connection_id is null or o.connection_id = p_connection_id)
     for update
  loop
    update nomad_stock.order_requests set status = 'blocked', block_reason = 'kill_switch' where id = r.id;
    insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, detail, actor_id, actor_role)
    values (p_organization_id, r.id, 'blocked', r.status, 'blocked', jsonb_build_object('kill_switch_id', v_row.id), (select auth.uid()), v_actor);
  end loop;
  perform nomad_core.write_audit(p_organization_id, 'stock.kill_switch.engage', 'kill_switch', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end;
$$;

-- 킬 스위치 해제: 수동(manual) 조직·연결 스위치만 owner/admin. 자동·운영·전역은 service_role만.
create function nomad_stock.release_kill_switch(p_switch_id uuid)
returns nomad_stock.kill_switches language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_stock.kill_switches;
begin
  select * into v_row from nomad_stock.kill_switches where id = p_switch_id for update;
  if not found then raise exception 'release_kill_switch: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller() then
    if v_row.scope = 'global' or v_row.trigger_source <> 'manual' then
      raise exception 'release_kill_switch: service only for % / %', v_row.scope, v_row.trigger_source using errcode = '42501';
    end if;
    if not nomad_stock.has_stock_access(v_row.organization_id)
       or coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin') then
      raise exception 'release_kill_switch: owner/admin only' using errcode = '42501';
    end if;
  end if;
  if not v_row.is_active then return v_row; end if;
  update nomad_stock.kill_switches set is_active = false, released_by = (select auth.uid()), released_at = now()
   where id = p_switch_id returning * into v_row;
  if v_row.organization_id is not null then
    perform nomad_core.write_audit(v_row.organization_id, 'stock.kill_switch.release', 'kill_switch', v_row.id::text);
  end if;
  return v_row;
end;
$$;

-- 주문 생성(service_role): 기능 paper_orders 필요. 한도 위반·킬 스위치·시세 지연은 예외 대신 blocked 행. client_order_id 멱등.
create function nomad_stock.create_paper_order(
  p_organization_id uuid, p_connection_id uuid, p_client_order_id uuid, p_symbol text, p_side text,
  p_quantity integer, p_limit_price numeric, p_ref_price numeric, p_ref_price_at timestamptz,
  p_actor_id uuid, p_prefill_report_id uuid default null
)
returns nomad_stock.order_requests language plpgsql security definer set search_path = ''
as $$
declare
  v_conn nomad_stock.broker_connections; v_lim nomad_stock.order_limits; v_row nomad_stock.order_requests;
  v_amount bigint; v_dev numeric; v_day_from timestamptz; v_day_sum bigint; v_day_cnt integer; v_reason text;
  v_total bigint; v_pos numeric; v_weight numeric; v_cred_revoked boolean;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'create_paper_order: service_role only' using errcode = '42501';
  end if;
  if p_actor_id is null then raise exception 'create_paper_order: human actor required' using errcode = '22023'; end if;

  perform pg_advisory_xact_lock(hashtextextended('stock:order:' || p_client_order_id::text, 0));
  select * into v_row from nomad_stock.order_requests where client_order_id = p_client_order_id;
  if found then
    if v_row.organization_id <> p_organization_id then
      raise exception 'create_paper_order: client_order_id belongs to another organization' using errcode = '22023';
    end if;
    return v_row;
  end if;
  if not nomad_core.org_has_feature(p_organization_id, 'stock', 'paper_orders') then
    raise exception 'create_paper_order: plan does not include paper_orders' using errcode = 'ST040';
  end if;
  -- 행위자는 이 조직의 쓰기 역할 멤버(활성 조직)이고, 조직은 베타 접근이 있어야 한다.
  if not exists (select 1 from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
                  where m.organization_id = p_organization_id and m.user_id = p_actor_id
                    and m.role in ('owner', 'admin', 'editor') and o.active)
     or not exists (select 1 from nomad_stock.beta_access b where b.organization_id = p_organization_id and b.status = 'active') then
    raise exception 'create_paper_order: actor is not an active member with stock beta access' using errcode = '42501';
  end if;
  select * into v_conn from nomad_stock.broker_connections where id = p_connection_id and organization_id = p_organization_id;
  if not found or v_conn.env <> 'paper' or not v_conn.orders_enabled or v_conn.status <> 'active' then
    raise exception 'create_paper_order: connection not eligible for paper orders' using errcode = 'ST010';
  end if;
  v_cred_revoked := nomad_stock.revoke_if_credential_revoked(p_connection_id);

  insert into nomad_stock.order_limits (organization_id) values (p_organization_id) on conflict (organization_id) do nothing;
  select * into v_lim from nomad_stock.order_limits where organization_id = p_organization_id for update;

  v_amount   := round(p_quantity * p_limit_price)::bigint;
  v_dev      := abs(p_limit_price - p_ref_price) / nullif(p_ref_price, 0) * 100;
  v_day_from := date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  select coalesce(sum(o.est_amount_krw), 0)::bigint, count(*) into v_day_sum, v_day_cnt
    from nomad_stock.order_requests o
   where o.organization_id = p_organization_id and o.created_at >= v_day_from
     and o.status not in ('blocked', 'canceled', 'expired', 'rejected', 'failed');
  -- 종목 비중: (보유 수량 × 지정가 + 주문 금액) / 최근 스냅샷(현금+평가). 매수만, 스냅샷이 없으면 판정 불가 = 차단.
  if p_side = 'buy' then
    select s.cash_krw + s.eval_krw into v_total from nomad_stock.balance_snapshots s
     where s.connection_id = p_connection_id order by s.captured_at desc, s.id desc limit 1;
    select coalesce(sum(h.quantity), 0) * p_limit_price into v_pos from nomad_stock.holdings h
     where h.connection_id = p_connection_id and h.symbol = p_symbol;
    v_weight := case when coalesce(v_total, 0) > 0 then (v_pos + v_amount) / v_total * 100 end;
  end if;

  v_reason := case
    when v_cred_revoked                                                                     then 'not_eligible'
    when nomad_stock.is_trading_blocked(p_organization_id, p_connection_id)                then 'kill_switch'
    when p_ref_price_at < now() - make_interval(secs => v_lim.max_quote_age_seconds)       then 'quote_stale'
    when v_dev is null or v_dev > v_lim.max_price_deviation_pct                             then 'price_deviation'
    when v_amount > v_lim.max_order_krw                                                     then 'max_order_krw'
    when v_day_sum + v_amount > v_lim.max_daily_krw                                         then 'max_daily_krw'
    when v_day_cnt >= v_lim.max_orders_per_day                                              then 'max_orders_per_day'
    when p_side = 'buy' and (v_weight is null or v_weight > v_lim.max_position_weight_pct)  then 'max_position_weight'
    else null end;

  insert into nomad_stock.order_requests (organization_id, connection_id, client_order_id, env, symbol, side, order_type, quantity,
                                          limit_price, ref_price, ref_price_at, status, limit_check, block_reason,
                                          confirm_expires_at, prefill_report_id, created_by)
  values (p_organization_id, p_connection_id, p_client_order_id, 'paper', p_symbol, p_side, 'limit', p_quantity,
          p_limit_price, p_ref_price, p_ref_price_at,
          case when v_reason is null then 'pending_confirm' else 'blocked' end,
          jsonb_build_object('amount_krw', v_amount, 'deviation_pct', round(coalesce(v_dev, -1), 4),
                             'day_sum_krw', v_day_sum, 'day_count', v_day_cnt, 'weight_pct', round(v_weight, 4), 'limits', to_jsonb(v_lim)),
          v_reason, now() + interval '60 seconds', p_prefill_report_id, p_actor_id)
  returning * into v_row;
  insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, detail, actor_id, actor_role)
  values (p_organization_id, v_row.id, case when v_reason is null then 'created' else 'blocked' end, null, v_row.status,
          v_row.limit_check || jsonb_build_object('block_reason', v_reason), p_actor_id, 'service');
  return v_row;
end;
$$;

-- 사람의 최종 확인: 주문을 만든 사용자 본인 세션만(서버 대리 확인 없음), 60초 안에.
-- 만료·킬 스위치·적격 상실(연결·orders_enabled·paper_orders·베타)은 상태로 남기고 행을 반환한다.
create function nomad_stock.confirm_paper_order(p_order_id uuid)
returns nomad_stock.order_requests language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_stock.order_requests; v_from text; v_uid uuid := (select auth.uid()); v_block text;
begin
  if v_uid is null or nomad_core.jwt_role() <> 'authenticated' then
    raise exception 'confirm_paper_order: user session required' using errcode = '42501';
  end if;
  select * into v_row from nomad_stock.order_requests where id = p_order_id for update;
  if not found or nomad_core.organization_role(v_row.organization_id) is null then
    raise exception 'confirm_paper_order: not found' using errcode = 'P0002';
  end if;
  if v_row.created_by is distinct from v_uid or not nomad_stock.has_stock_access(v_row.organization_id) then
    raise exception 'confirm_paper_order: only the requester can confirm' using errcode = '42501';
  end if;
  if v_row.status <> 'pending_confirm' then
    raise exception 'confirm_paper_order: invalid state %', v_row.status using errcode = 'ST020';
  end if;
  v_from := v_row.status;
  if v_row.confirm_expires_at <= now() then
    update nomad_stock.order_requests set status = 'expired' where id = p_order_id returning * into v_row;
    insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, actor_id, actor_role)
    values (v_row.organization_id, v_row.id, 'expired', v_from, 'expired', v_uid, 'user');
    return v_row;
  end if;
  perform nomad_stock.revoke_if_credential_revoked(v_row.connection_id);
  v_block := case when nomad_stock.is_trading_blocked(v_row.organization_id, v_row.connection_id) then 'kill_switch'
                  when not nomad_stock.order_eligible(v_row.organization_id, v_row.connection_id) then 'not_eligible' end;
  if v_block is not null then
    update nomad_stock.order_requests set status = 'blocked', block_reason = v_block where id = p_order_id returning * into v_row;
    insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, detail, actor_id, actor_role)
    values (v_row.organization_id, v_row.id, 'blocked', v_from, 'blocked', jsonb_build_object('block_reason', v_block), v_uid, 'user');
    return v_row;
  end if;
  update nomad_stock.order_requests set status = 'confirmed', confirmed_at = now(), confirmed_by = v_uid
   where id = p_order_id returning * into v_row;
  insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, actor_id, actor_role)
  values (v_row.organization_id, v_row.id, 'confirmed', v_from, 'confirmed', v_uid, 'user');
  perform nomad_core.write_audit(v_row.organization_id, 'stock.order.confirm', 'order_request', v_row.id::text);
  return v_row;
end;
$$;

-- 워커가 증권사 응답을 반영(service_role). 전이는 트리거가 검사한다. submitted 직전 킬 스위치 재확인.
create function nomad_stock.apply_order_update(
  p_order_id uuid, p_to text, p_broker_order_id text default null, p_filled_quantity integer default null,
  p_avg_fill_price numeric default null, p_detail jsonb default '{}'::jsonb
)
returns nomad_stock.order_requests language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_stock.order_requests; v_from text; v_block text;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'apply_order_update: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_stock.order_requests where id = p_order_id for update;
  if not found then raise exception 'apply_order_update: not found' using errcode = 'P0002'; end if;
  v_from := v_row.status;
  if p_to = 'submitted' then
    perform nomad_stock.revoke_if_credential_revoked(v_row.connection_id);
    v_block := case when nomad_stock.is_trading_blocked(v_row.organization_id, v_row.connection_id) then 'kill_switch'
                    when not nomad_stock.order_eligible(v_row.organization_id, v_row.connection_id) then 'not_eligible' end;
    if v_block is not null then p_to := 'blocked'; end if;
  end if;
  update nomad_stock.order_requests
     set status          = p_to,
         block_reason    = case when p_to = 'blocked' then coalesce(v_block, block_reason, 'kill_switch') else block_reason end,
         broker_order_id = coalesce(p_broker_order_id, broker_order_id),
         filled_quantity = coalesce(p_filled_quantity, filled_quantity),
         avg_fill_price  = coalesce(p_avg_fill_price, avg_fill_price),
         submitted_at    = case when p_to = 'submitted' then now() else submitted_at end
   where id = p_order_id
  returning * into v_row;
  insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, detail, actor_role)
  values (v_row.organization_id, v_row.id,
          case when p_to in ('submitted', 'accepted', 'partially_filled', 'filled', 'rejected', 'failed', 'canceled', 'blocked') then p_to
               else 'broker_response' end,
          v_from, p_to, coalesce(p_detail, '{}'::jsonb), 'service');
  return v_row;
end;
$$;

-- 확인 대기 만료(스케줄 매 1분, service_role).
create function nomad_stock.expire_pending_orders() returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_count integer := 0; r record;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'expire_pending_orders: service_role only' using errcode = '42501';
  end if;
  for r in select id, organization_id from nomad_stock.order_requests
            where status = 'pending_confirm' and confirm_expires_at <= now() for update skip locked
  loop
    update nomad_stock.order_requests set status = 'expired' where id = r.id;
    insert into nomad_stock.order_events (organization_id, order_id, event, from_status, to_status, actor_role)
    values (r.organization_id, r.id, 'expired', 'pending_confirm', 'expired', 'system');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ---------- 12. Realtime (postgres_changes, RLS 적용) ----------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['holdings', 'balance_snapshots', 'ai_reports', 'order_requests']
    loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_stock' and tablename = t) then
        execute format('alter publication supabase_realtime add table nomad_stock.%I', t);
      end if;
    end loop;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_stock' and tablename = 'broker_connections') then
      alter publication supabase_realtime add table nomad_stock.broker_connections
        (id, organization_id, broker, env, label, account_masked, status, orders_enabled, last_synced_at,
         last_error_code, consecutive_errors, created_by, created_at, updated_at);
    end if;
  end if;
end $$;

-- ---------- 13. 함수 권한 (PUBLIC 회수 후 허용 목록만) ----------
revoke all on all functions in schema nomad_stock from public, anon, authenticated;
grant execute on all functions in schema nomad_stock to service_role;
-- 사람 확인은 사용자 세션 전용, 내부 도우미는 정의자 함수 안에서만
revoke all on function nomad_stock.confirm_paper_order(uuid), nomad_stock.order_eligible(uuid, uuid),
  nomad_stock.revoke_if_credential_revoked(uuid) from service_role;
grant execute on function
  nomad_stock.has_stock_access(uuid),
  nomad_stock.has_any_stock_access(),
  nomad_stock.record_consent(uuid, text, text),
  nomad_stock.set_order_limits(uuid, bigint, bigint, integer, numeric, numeric),
  nomad_stock.engage_kill_switch(uuid, uuid, text),
  nomad_stock.release_kill_switch(uuid),
  nomad_stock.confirm_paper_order(uuid)
to authenticated;

commit;
