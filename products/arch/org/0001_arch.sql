-- arch-studio 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/2400_arch.sql 1~12장(라이선스·기기·빌드·규칙 팩·표제란·클라우드 사본·AI 실행)
-- core.organizations→nomad_core.organizations, org_members(member→editor)→nomad_core.memberships, has_entitlement·plans.features→nomad_core.has_feature·plan_limits,
-- core.jobs·credit_ledger(bigint)→nomad_core.jobs·credit_ledger(uuid), consume/refund/enqueue→nomad_core 서버 함수, core.write_audit→nomad_core.write_audit.
-- 결정 D1: 결제 테이블(payment_orders·payments·webhook)은 이식하지 않는다. 일회성 주문은 제품 표 license_orders(상태·금액 정수 원·멱등 키)만 두고,
--   결제 확정은 외부 결제 서버가 mark_license_order(service_role)로 알린다(계약: products/arch/existing.md "결제 연동 계약").
-- 플랜: A = 월 구독(원본 sub_monthly), B = 체험(원본 trial, 서버가 ends_at 을 정해 구독을 만든다), C = 기능 없음 → 구독이 끊기면 잠긴다.
--   영구 라이선스 보유 조직은 플랜과 무관하게 접근(라이선스 상태 + 플랜을 org_features 가 합친다, 원본 그대로).
-- 수치(단가·운영 상수·라이선스 상품·플랜 한도)는 시드하지 않는다: runtime_config·license_skus 는 운영자가, 한도는 plan_limits 키. AI 라우팅은 org/0002_ai.sql.
-- 되돌림: drop schema nomad_arch cascade; drop schema nomad_arch_private cascade; delete from storage.buckets where id in ('arch-releases', 'arch-user');
begin;

create schema nomad_arch;
create schema nomad_arch_private;
revoke all on schema nomad_arch, nomad_arch_private from public, anon, authenticated;
grant usage on schema nomad_arch to anon, authenticated, service_role;
alter default privileges in schema nomad_arch revoke execute on functions from public;
alter default privileges in schema nomad_arch_private revoke execute on functions from public;

insert into nomad_core.products (code, name) values ('arch', 'Arch Studio') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values ('arch', 'A', 'A'), ('arch', 'B', 'B'), ('arch', 'C', 'C')
  on conflict do nothing;
-- 원본 features 불리언 키 → 기능 이용권. drafting_watermark(true=워터마크)는 반대 의미 drafting_no_watermark 로 바꿨다.
insert into nomad_core.features (product_code, code, name) values
  ('arch', 'workspace', 'Arch 클라우드 작업 공간(표제란·클라우드 사본·실행 기록)'),
  ('arch', 'cloud_review', '클라우드 법규 검토'),
  ('arch', 'rule_pack_updates', '규칙 팩·공사비 단가표 업데이트'),
  ('arch', 'ai_render', 'AI 렌더·제안서'),
  ('arch', 'ai_intake', '대화형 설계 입력·상담 녹음 후보'),
  ('arch', 'local_gpu_render', '로컬 GPU 렌더'),
  ('arch', 'ai_layout', 'AI 실 배치 초안'),
  ('arch', 'drafting_no_watermark', '도면 워터마크 없음')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'arch', p, f from unnest(array['A', 'B']) p, unnest(array['workspace', 'cloud_review', 'rule_pack_updates', 'ai_render', 'ai_intake']) f
union all
select 'arch', 'A', f from unnest(array['local_gpu_render', 'ai_layout', 'drafting_no_watermark']) f
on conflict do nothing;
-- plan_limits 키(시드 없음, 없으면 원본 "키가 없을 때" 값): render_max_px 1024 · site_lookups_per_day 10 · ai_chat_turns_per_day 20
--   · cloud_projects_max 3 · max_activations 1. 무제한 = 2147483647.

-- ---------- 1. 카탈로그 (플랫폼 소유, 쓰기 service_role) ----------
create table nomad_arch.runtime_config (
  key        text primary key constraint runtime_config_key_check check (key ~ '^[a-z][a-z0-9_.]{1,63}$'),
  value_int  integer not null,
  note       text,
  updated_at timestamptz not null default now()
);
comment on table nomad_arch.runtime_config is '운영 상수·크레딧 단가(price.<variant>)·원화 가격(price_krw.*). 서버 전용, 시드 없음(운영자가 넣는다).';

create table nomad_arch.license_skus (
  code                    text primary key constraint license_skus_code_check check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name                    text not null constraint license_skus_name_check check (char_length(name) between 1 and 80),
  price_krw               integer not null constraint license_skus_price_check check (price_krw > 0),
  includes_updates_months integer not null default 12 constraint license_skus_updates_check check (includes_updates_months between 0 and 60),
  bonus_credits           integer not null default 0 constraint license_skus_bonus_check check (bonus_credits >= 0),
  max_activations         integer not null default 2 constraint license_skus_max_act_check check (max_activations between 1 and 10),
  max_quantity            integer constraint license_skus_qty_check check (max_quantity is null or max_quantity > 0),
  fallback_features       jsonb not null default '{}'::jsonb constraint license_skus_fallback_check check (jsonb_typeof(fallback_features) = 'object'),
  is_active               boolean not null default true,
  sort_order              integer not null default 0,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
comment on table nomad_arch.license_skus is '영구 라이선스 상품(금액 정수 원). 쓰기 service_role, 공개 목록은 public_license_skus RPC 만(D8).';

create table nomad_arch.builds (
  id           uuid primary key default gen_random_uuid(),
  version      text not null constraint builds_version_check check (version ~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}$'),
  platform     text not null constraint builds_platform_check check (platform ~ '^(windows|darwin)-(x86_64|aarch64)$'),
  channel      text not null default 'stable' constraint builds_channel_check check (channel in ('stable', 'beta')),
  status       text not null default 'draft' constraint builds_status_check check (status in ('draft', 'published', 'withdrawn')),
  build_date   date not null,
  storage_path text not null constraint builds_path_check check (storage_path ~ '^builds/(stable|beta)/[0-9.]+/[A-Za-z0-9._-]{1,120}$'),
  signature    text not null constraint builds_signature_check check (char_length(signature) between 16 and 2000),
  sha256       text not null constraint builds_sha_check check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes        bigint not null constraint builds_bytes_check check (bytes > 0),
  notes        text constraint builds_notes_check check (notes is null or char_length(notes) <= 4000),
  published_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (platform, channel, version),
  constraint builds_published_check check (status = 'draft' or published_at is not null)
);
comment on table nomad_arch.builds is '데스크톱 빌드(Tauri 업데이터). 서버 전용, 자격은 eligible_build.';

create table nomad_arch.rule_packs (
  id           uuid primary key default gen_random_uuid(),
  version      text not null unique constraint rule_packs_version_check check (version ~ '^[0-9]{4}\.[0-9]{2}\.[0-9]{1,3}$'),
  status       text not null default 'draft' constraint rule_packs_status_check check (status in ('draft', 'published', 'withdrawn')),
  basis_date   date not null,
  summary      text constraint rule_packs_summary_check check (summary is null or char_length(summary) <= 2000),
  storage_path text not null constraint rule_packs_path_check check (storage_path ~ '^rule-packs/[0-9.]+/pack\.json$'),
  sha256       text not null constraint rule_packs_sha_check check (sha256 ~ '^[0-9a-f]{64}$'),
  signature    text not null constraint rule_packs_signature_check check (char_length(signature) between 16 and 512),
  kid          text not null constraint rule_packs_kid_check check (kid ~ '^[A-Za-z0-9_-]{1,40}$'),
  bytes        bigint not null constraint rule_packs_bytes_check check (bytes > 0),
  published_at timestamptz,
  withdrawn_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint rule_packs_published_check check (status = 'draft' or published_at is not null)
);
comment on table nomad_arch.rule_packs is '법규 규칙 팩 메타데이터(서명 매니페스트). 읽기는 Arch 접근 사용자(storage_path 제외), 자격 목록은 eligible_rule_packs.';

create table nomad_arch.rule_pack_changes (
  id             uuid primary key default gen_random_uuid(),
  rule_pack_id   uuid not null references nomad_arch.rule_packs(id) on delete cascade,
  title          text not null constraint rule_pack_changes_title_check check (char_length(title) between 1 and 200),
  kind           text not null constraint rule_pack_changes_kind_check check (kind in ('law', 'decree', 'rule', 'ordinance', 'interpretation')),
  effective_from date not null,
  law_ref        text constraint rule_pack_changes_ref_check check (law_ref is null or char_length(law_ref) <= 200),
  created_at     timestamptz not null default now()
);
create index rule_pack_changes_pack_idx on nomad_arch.rule_pack_changes (rule_pack_id);
comment on table nomad_arch.rule_pack_changes is '규칙 팩 사이 개정 목록(제목·시행일). 공개된 팩의 행만 Arch 접근 사용자가 읽는다.';

create table nomad_arch.cost_catalogs (
  id           uuid primary key default gen_random_uuid(),
  version      text not null unique constraint cost_catalogs_version_check check (version ~ '^[0-9]{4}\.[0-9]{2}\.[0-9]{1,3}$'),
  status       text not null default 'draft' constraint cost_catalogs_status_check check (status in ('draft', 'published', 'withdrawn')),
  basis_date   date not null,
  items        jsonb not null constraint cost_catalogs_items_check check (jsonb_typeof(items) = 'array' and pg_column_size(items) <= 1048576),
  source_note  text not null constraint cost_catalogs_source_check check (char_length(source_note) between 1 and 1000),
  sha256       text not null constraint cost_catalogs_sha_check check (sha256 ~ '^[0-9a-f]{64}$'),
  published_at timestamptz,
  withdrawn_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint cost_catalogs_published_check check (status = 'draft' or published_at is not null)
);
comment on table nomad_arch.cost_catalogs is '개략 공사비 단가표. 서버 전용, 내용은 latest_cost_catalog RPC 로만.';

-- ---------- 2. 주문(D1: 결제 테이블 대신) · 라이선스 · 기기 ----------
create table nomad_arch.license_orders (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references nomad_core.organizations(id) on delete cascade,
  kind                  text not null constraint license_orders_kind_check check (kind in ('license', 'updates_extension')),
  sku_code              text references nomad_arch.license_skus(code),
  amount_krw            integer not null constraint license_orders_amount_check check (amount_krw > 0),
  status                text not null default 'pending'
                        constraint license_orders_status_check check (status in ('pending', 'paid', 'canceled', 'refunded')),
  idempotency_key       text not null constraint license_orders_key_check check (char_length(idempotency_key) between 8 and 200),
  external_payment_ref  text unique constraint license_orders_ref_check check (external_payment_ref is null or char_length(external_payment_ref) between 1 and 200),
  paid_at               timestamptz,
  status_changed_at     timestamptz,
  created_by            uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (organization_id, idempotency_key),
  constraint license_orders_sku_check check ((kind = 'license') = (sku_code is not null)),
  constraint license_orders_paid_check check (status not in ('paid', 'refunded') or (paid_at is not null and external_payment_ref is not null))
);
create index license_orders_org_idx on nomad_arch.license_orders (organization_id, created_at desc);
comment on table nomad_arch.license_orders is '영구 라이선스·업데이트 연장 일회성 주문(상태·금액 정수 원·멱등 키). 결제 수단·키는 외부 결제 서버, 쓰기는 서버 RPC 만.';

create table nomad_arch.licenses (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  sku_code            text not null references nomad_arch.license_skus(code),
  order_id            uuid unique references nomad_arch.license_orders(id) on delete restrict,   -- null = 운영 수동 발급(감사 필수)
  serial_hash         text not null unique constraint licenses_serial_hash_check check (serial_hash ~ '^[0-9a-f]{64}$'),
  serial_last5        text not null constraint licenses_serial_last5_check check (serial_last5 ~ '^[0-9A-HJKMNP-TV-Z]{5}$'),
  status              text not null default 'active'
                      constraint licenses_status_check check (status in ('active', 'suspended', 'refunded', 'revoked')),
  purchased_at        timestamptz not null default now(),
  updates_until       date not null,
  max_activations     integer not null default 2 constraint licenses_max_act_check check (max_activations between 1 and 10),
  extension_order_ids uuid[] not null default '{}',
  status_changed_at   timestamptz,
  status_reason       text constraint licenses_reason_check check (status_reason is null or char_length(status_reason) <= 300),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, organization_id)
);
create index licenses_org_idx on nomad_arch.licenses (organization_id, status);
comment on table nomad_arch.licenses is '영구 라이선스(시리얼은 SHA-256 해시와 끝 5자만). 멤버 읽기(해시 제외), 쓰기는 서버 RPC.';

create table nomad_arch.license_activations (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  license_id        uuid,
  source            text not null constraint license_activations_source_check check (source in ('license', 'plan')),
  device_hash       text not null constraint license_activations_device_check check (device_hash ~ '^[0-9a-f]{64}$'),
  device_label      text constraint license_activations_label_check check (device_label is null or char_length(device_label) <= 60),
  activated_by      uuid,
  activated_at      timestamptz not null default now(),
  last_seen_at      timestamptz not null default now(),
  deactivated_at    timestamptz,
  deactivated_by    uuid,
  deactivation_kind text constraint license_activations_kind_check check (deactivation_kind is null or deactivation_kind in ('self', 'support', 'refund', 'revoke')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint license_activations_source_ref_check check ((source = 'license') = (license_id is not null)),
  constraint license_activations_deactivated_check check ((deactivated_at is null) = (deactivation_kind is null)),
  foreign key (license_id, organization_id) references nomad_arch.licenses (id, organization_id) on delete cascade
);
create unique index license_activations_license_device_uniq
  on nomad_arch.license_activations (license_id, device_hash) where deactivated_at is null and license_id is not null;
create unique index license_activations_plan_device_uniq
  on nomad_arch.license_activations (organization_id, device_hash) where deactivated_at is null and source = 'plan';
create index license_activations_active_idx on nomad_arch.license_activations (license_id) where deactivated_at is null;
create index license_activations_org_idx on nomad_arch.license_activations (organization_id, deactivated_at);
comment on table nomad_arch.license_activations is '기기 활성화(영구 라이선스 license, 체험·구독 plan). 멤버 읽기(device_hash 제외), 해제는 deactivate_activation.';

-- ---------- 3. 조직 설정과 클라우드 사본 ----------
create table nomad_arch.drafting_profiles (
  organization_id        uuid primary key references nomad_core.organizations(id) on delete cascade,
  office_name            text not null constraint drafting_profiles_office_check check (char_length(btrim(office_name)) between 1 and 100),
  architect_name         text constraint drafting_profiles_architect_check check (architect_name is null or char_length(architect_name) <= 50),
  contact                text constraint drafting_profiles_contact_check check (contact is null or char_length(contact) <= 100),
  logo_storage_path      text,
  layer_map              jsonb not null default '{}'::jsonb constraint drafting_profiles_layer_map_check check (jsonb_typeof(layer_map) = 'object'),
  default_paper          text not null default 'A3' constraint drafting_profiles_paper_check check (default_paper in ('A3', 'A2', 'A1')),
  default_text_height_mm numeric(3, 1) not null default 2.5 constraint drafting_profiles_text_check check (default_text_height_mm between 2.0 and 5.0),
  font_family            text not null default 'Noto Sans KR' constraint drafting_profiles_font_check check (font_family ~ '^[A-Za-z0-9 가-힣_-]{1,64}$'),
  updated_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint drafting_profiles_logo_check check (
    logo_storage_path is null
    or logo_storage_path ~ ('^' || organization_id::text || '/arch/drafting-logo/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$'))
);
create index drafting_profiles_org_updated_idx on nomad_arch.drafting_profiles (organization_id, updated_at);
comment on table nomad_arch.drafting_profiles is '표제란·레이어 매핑(조직당 1행, 건축주 정보 없음). 읽기 접근 멤버, 쓰기 upsert_drafting_profile(owner/admin).';

create table nomad_arch.cloud_projects (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  local_id        uuid not null,
  name            text not null constraint cloud_projects_name_check check (char_length(btrim(name)) between 1 and 120),
  storage_path    text not null,
  version         integer not null default 1 constraint cloud_projects_version_check check (version >= 1),
  created_by      uuid,
  updated_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organization_id, local_id),
  constraint cloud_projects_path_check check (
    storage_path ~ ('^' || organization_id::text || '/arch/project_snapshot/' || local_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,8}$'))
);
create index cloud_projects_org_updated_idx on nomad_arch.cloud_projects (organization_id, updated_at);
comment on table nomad_arch.cloud_projects is '클라우드 사본(프로젝트 스냅샷, version 낙관적 동시성). 쓰기는 save_cloud_project(editor 이상).';

-- ---------- 4. AI 실행 기록 (쓰기 서버 RPC). 실행 1건 = 제품 행 1 + nomad_core.jobs 1 ----------
create table nomad_arch.renders (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  project_ref       uuid not null,
  request_id        uuid not null unique,
  variant           text not null constraint renders_variant_check check (variant in ('render_std', 'render_hq', 'upscale')),
  status            text not null default 'queued' constraint renders_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'refunded')),
  credits           integer not null constraint renders_credits_check check (credits >= 0),
  credit_ledger_id  uuid references nomad_core.credit_ledger(id),
  job_id            uuid references nomad_core.jobs(id) on delete set null,
  options           jsonb not null default '{}'::jsonb constraint renders_options_check check (jsonb_typeof(options) = 'object' and pg_column_size(options) <= 16384),
  source_render_id  uuid,
  output_path       text,
  width             integer constraint renders_width_check check (width is null or width between 64 and 8192),
  height            integer constraint renders_height_check check (height is null or height between 64 and 8192),
  bytes             bigint,
  provider          text,
  model             text,
  seed              bigint,
  ai_label          boolean not null default true,
  expires_at        timestamptz,
  purged_at         timestamptz,
  error             text constraint renders_error_check check (error is null or char_length(error) <= 1000),
  created_by        uuid,
  created_at        timestamptz not null default now(),
  started_at        timestamptz,
  finished_at       timestamptz,
  updated_at        timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (source_render_id, organization_id) references nomad_arch.renders (id, organization_id),
  constraint renders_output_check check (status <> 'succeeded' or (output_path is not null and expires_at is not null and ai_label)),
  constraint renders_upscale_check check ((variant = 'upscale') = (source_render_id is not null))
);
create index renders_active_idx on nomad_arch.renders (organization_id, status) where status in ('queued', 'running');
create index renders_org_created_idx on nomad_arch.renders (organization_id, created_at desc);
create index renders_expiry_idx on nomad_arch.renders (expires_at) where status = 'succeeded' and purged_at is null;
comment on table nomad_arch.renders is 'AI 렌더 실행(선차감 크레딧·잡 연결, 멱등 request_id). 쓰기는 start/finish/fail_ai_run, 멤버 읽기.';

create table nomad_arch.reviews (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  project_ref        uuid not null,
  request_id         uuid not null unique,
  variant            text not null default 'review' constraint reviews_variant_check check (variant = 'review'),
  status             text not null default 'queued' constraint reviews_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'refunded')),
  credits            integer not null constraint reviews_credits_check check (credits >= 0),
  credit_ledger_id   uuid references nomad_core.credit_ledger(id),
  job_id             uuid references nomad_core.jobs(id) on delete set null,
  rule_pack_version  text not null constraint reviews_pack_check check (rule_pack_version ~ '^[0-9]{4}\.[0-9]{2}\.[0-9]{1,3}$'),
  application_date   date not null,
  municipality_code  text not null constraint reviews_muni_check check (municipality_code ~ '^[0-9]{5,10}$'),
  judgment           jsonb not null constraint reviews_judgment_check check (jsonb_typeof(judgment) = 'object' and pg_column_size(judgment) <= 262144),
  model_summary      jsonb not null default '{}'::jsonb constraint reviews_summary_check check (jsonb_typeof(model_summary) = 'object' and pg_column_size(model_summary) <= 16384),
  result             jsonb constraint reviews_result_check check (result is null or pg_column_size(result) <= 524288),
  disclaimer_version text,
  error              text constraint reviews_error_check check (error is null or char_length(error) <= 1000),
  created_by         uuid,
  created_at         timestamptz not null default now(),
  started_at         timestamptz,
  finished_at        timestamptz,
  updated_at         timestamptz not null default now(),
  constraint reviews_output_check check (status <> 'succeeded' or result is not null)
);
create index reviews_org_created_idx on nomad_arch.reviews (organization_id, created_at desc);
create index reviews_active_idx on nomad_arch.reviews (organization_id, status) where status in ('queued', 'running');
comment on table nomad_arch.reviews is '클라우드 법규 검토 실행(출처 없는 결과 저장 금지 AR033). 쓰기는 서버 RPC, 멤버 읽기.';

create table nomad_arch.intake_runs (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  project_ref      uuid not null,
  request_id       uuid not null unique,
  variant          text not null constraint intake_runs_variant_check check (variant in ('intake_text', 'intake_consult')),
  source           text not null constraint intake_runs_source_check check (source in ('chat', 'consult')),
  input_kind       text not null default 'text' constraint intake_runs_input_kind_check check (input_kind in ('text', 'voice')),
  status           text not null default 'queued' constraint intake_runs_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'refunded')),
  credits          integer not null constraint intake_runs_credits_check check (credits >= 0),
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  job_id           uuid references nomad_core.jobs(id) on delete set null,
  input_text       text constraint intake_runs_text_check check (input_text is null or char_length(input_text) between 1 and 4000),
  stt_job_id       uuid references nomad_core.jobs(id) on delete set null,
  notice_version   text constraint intake_runs_notice_check check (notice_version is null or notice_version ~ '^[a-z0-9._-]{1,40}$'),
  result           jsonb constraint intake_runs_result_check check (result is null or pg_column_size(result) <= 131072),
  expires_at       timestamptz not null default (now() + interval '90 days'),
  error            text constraint intake_runs_error_check check (error is null or char_length(error) <= 1000),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  updated_at       timestamptz not null default now(),
  constraint intake_runs_variant_source_check check ((variant = 'intake_consult') = (source = 'consult')),
  constraint intake_runs_input_check check (
    (source = 'chat' and input_kind = 'text' and input_text is not null)
    or (source = 'chat' and input_kind = 'voice' and stt_job_id is not null)
    or (source = 'consult' and input_kind = 'voice' and stt_job_id is not null and input_text is null and notice_version is not null)),
  constraint intake_runs_output_check check (status <> 'succeeded' or result is not null)
);
create index intake_runs_org_created_idx on nomad_arch.intake_runs (organization_id, created_at desc);
create index intake_runs_expiry_idx on nomad_arch.intake_runs (expires_at);
comment on table nomad_arch.intake_runs is '대화형 설계 입력·상담 녹음 후보 실행(90일 뒤 삭제). 쓰기는 서버 RPC, 멤버 읽기.';

create table nomad_arch.proposals (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  project_ref      uuid not null,
  request_id       uuid not null unique,
  variant          text not null constraint proposals_variant_check check (variant in ('proposal', 'doc_template')),
  doc_kind         text not null constraint proposals_doc_kind_check check (doc_kind in ('proposal', 'overview', 'area_table', 'cost')),
  status           text not null default 'queued' constraint proposals_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'refunded')),
  credits          integer not null constraint proposals_credits_check check (credits >= 0),
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  job_id           uuid references nomad_core.jobs(id) on delete set null,
  template_version text not null constraint proposals_template_check check (template_version ~ '^[a-z0-9._-]{1,40}$'),
  content_path     text not null,
  content_sha256   text not null constraint proposals_content_sha_check check (content_sha256 ~ '^[0-9a-f]{64}$'),
  render_ids       uuid[] not null default '{}' constraint proposals_render_ids_check check (cardinality(render_ids) <= 12),
  sheet_paths      text[] not null default '{}' constraint proposals_sheet_paths_check check (cardinality(sheet_paths) <= 20),
  pdf_path         text,
  pages            integer constraint proposals_pages_check check (pages is null or pages between 1 and 200),
  bytes            bigint,
  narrative        jsonb,
  error            text constraint proposals_error_check check (error is null or char_length(error) <= 1000),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  updated_at       timestamptz not null default now(),
  constraint proposals_variant_kind_check check ((variant = 'proposal') = (doc_kind = 'proposal')),
  constraint proposals_output_check check (status <> 'succeeded' or pdf_path is not null)
);
create index proposals_org_created_idx on nomad_arch.proposals (organization_id, created_at desc);
create index proposals_template_reuse_idx on nomad_arch.proposals (organization_id, content_sha256, template_version) where status = 'succeeded';
comment on table nomad_arch.proposals is '제안서·템플릿 문서 PDF 실행(같은 내용·버전 재요청 0크레딧). 쓰기는 서버 RPC, 멤버 읽기.';

create table nomad_arch.site_lookups (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  lookup_date     date not null,
  pnu_hash        text not null constraint site_lookups_hash_check check (pnu_hash ~ '^[0-9a-f]{64}$'),
  created_at      timestamptz not null default now(),
  unique (organization_id, lookup_date, pnu_hash)
);
create index site_lookups_created_idx on nomad_arch.site_lookups (created_at);
comment on table nomad_arch.site_lookups is '대지 조회 일일 상한 집계(지번 HMAC 해시와 날짜만, 주소 원문 없음). 사용자 접근 없음.';

-- ---------- 5. 도우미 ----------
-- 정책용(authenticated 실행)
create function nomad_arch.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select nomad_core.organization_role(p_org) is not null $$;

-- Arch 작업 공간 접근: 멤버 + (workspace 이용권(A·B) 또는 활성 영구 라이선스). 구독도 라이선스도 없으면 잠긴다.
create function nomad_arch.has_access(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_core.organization_role(p_org) is not null
     and (nomad_core.org_has_feature(p_org, 'arch', 'workspace')
          or exists (select 1 from nomad_arch.licenses l where l.organization_id = p_org and l.status = 'active'))
$$;

-- 카탈로그(규칙 팩) 읽기: 접근 가능한 조직이 하나라도 있는가(원본 has_arch_access)
create function nomad_arch.has_arch_access() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_core.memberships m
                 where m.user_id = (select auth.uid()) and nomad_arch.has_access(m.organization_id))
$$;

create function nomad_arch.feature_int(p_features jsonb, p_key text, p_default integer) returns integer
language sql immutable set search_path = ''
as $$ select case when jsonb_typeof(p_features -> p_key) = 'number' then (p_features ->> p_key)::integer else p_default end $$;

create function nomad_arch.feature_bool(p_features jsonb, p_key text, p_default boolean) returns boolean
language sql immutable set search_path = ''
as $$ select case when jsonb_typeof(p_features -> p_key) = 'boolean' then (p_features ->> p_key)::boolean else p_default end $$;

create function nomad_arch.kst_today() returns date
language sql stable set search_path = ''
as $$ select (now() at time zone 'Asia/Seoul')::date $$;

-- 서버가 만든 사용자 업로드 경로인가: <organization_id>/arch/<purpose>/[<project_ref>/]<uuid>.<ext>
create function nomad_arch.valid_user_path(p_org uuid, p_purpose text, p_path text) returns boolean
language sql immutable set search_path = ''
as $$
  select p_org is not null and p_purpose ~ '^[a-z][a-z_-]{2,31}$' and p_path is not null and char_length(p_path) <= 300
     and p_path ~ ('^' || p_org::text || '/arch/' || p_purpose
                   || '/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?'
                   || '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,8}$')
$$;

-- 비노출
create function nomad_arch_private.config_int(p_key text, p_default integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce((select c.value_int from nomad_arch.runtime_config c where c.key = p_key), p_default) $$;

-- 경로 첫 폴더의 조직 id(원본 core.storage_org_id)
create function nomad_arch_private.storage_org_id(p_path text) returns uuid
language sql immutable set search_path = ''
as $$
  select case when split_part(p_path, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_path, '/', 1)::uuid end
$$;

-- 호출자가 고를 조직: p_org 가 null 이면 개인 조직. 멤버가 아니면 42501.
create function nomad_arch_private.caller_org(p_org uuid) returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare v_org uuid := p_org;
begin
  if v_org is null then
    select o.id into v_org
    from nomad_core.organizations o join nomad_core.memberships m on m.organization_id = o.id
    where o.kind = 'personal' and m.user_id = auth.uid() and m.role = 'owner' and o.active
    order by o.created_at limit 1;
  end if;
  if v_org is null or nomad_core.organization_role(v_org) is null then
    raise exception 'caller_org: not a member' using errcode = '42501';
  end if;
  return v_org;
end;
$$;

-- 서버 RPC 의 행위자(p_actor)가 조직의 쓰기 역할(owner/admin/editor)인가. 원본 member → editor.
create function nomad_arch_private.actor_can_write(p_org uuid, p_actor uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
                 where m.organization_id = p_org and m.user_id = p_actor and o.active and m.role in ('owner', 'admin', 'editor'))
$$;

-- 무작위 시리얼 본문: Crockford Base32 20자(100비트).
create function nomad_arch_private.new_serial_body() returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alpha constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_bytes bytea := extensions.gen_random_bytes(20);
  v_out text := '';
  i integer;
begin
  for i in 0..19 loop
    v_out := v_out || substr(v_alpha, (get_byte(v_bytes, i) & 31) + 1, 1);
  end loop;
  return v_out;
end;
$$;

-- 조직의 최종 기능 값(원본 org_features 와 같은 모양). 영구 라이선스 상태 + 플랜 이용권·한도를 서버가 합친다.
--   licensed(라이선스 업데이트 유효) = 플랜 A 의 이용권·한도 · subscribed(A) / trial(B) = 조직 이용권·한도 · licensed_fallback = 상품 fallback_features
--   · 그 밖 = 만료 값(열람·내보내기만).
create function nomad_arch.org_features(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_missing constant jsonb := '{"cloud_review": false, "rule_pack_updates": false, "ai_render": false, "local_gpu_render": false,
    "render_max_px": 1024, "site_lookups_per_day": 10, "ai_chat_turns_per_day": 20, "cloud_projects_max": 3, "max_activations": 1,
    "drafting_watermark": true, "ai_intake": false, "ai_layout": false}';
  v_expired constant jsonb := '{"cloud_review": false, "rule_pack_updates": false, "ai_render": false, "local_gpu_render": false,
    "render_max_px": 1024, "site_lookups_per_day": 0, "ai_chat_turns_per_day": 0, "cloud_projects_max": 3, "max_activations": 0,
    "drafting_watermark": true, "ai_intake": false, "ai_layout": false}';
  v_bools constant text[] := array['cloud_review', 'rule_pack_updates', 'ai_render', 'local_gpu_render', 'ai_intake', 'ai_layout'];
  v_ints  constant text[] := array['render_max_px', 'site_lookups_per_day', 'ai_chat_turns_per_day', 'cloud_projects_max', 'max_activations'];
  v_sub_plan text; v_sub_active boolean := false; v_sub_ends timestamptz;
  v_lic_until date; v_lic_ids jsonb; v_state text; v_feat jsonb; v_trial_end timestamptz; v_out jsonb;
begin
  if p_org is null then
    raise exception 'org_features: org required' using errcode = '22023';
  end if;
  if not nomad_core.is_service_caller() and nomad_core.organization_role(p_org) is null then
    raise exception 'org_features: not a member' using errcode = '42501';
  end if;

  select s.plan_code, (s.status = 'active' and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())), s.ends_at
    into v_sub_plan, v_sub_active, v_sub_ends
  from nomad_core.subscriptions s where s.organization_id = p_org and s.product_code = 'arch';
  v_sub_active := coalesce(v_sub_active, false);

  select max(l.updates_until), coalesce(jsonb_agg(l.id order by l.purchased_at), '[]'::jsonb)
    into v_lic_until, v_lic_ids
  from nomad_arch.licenses l where l.organization_id = p_org and l.status = 'active';

  if v_lic_until is not null and v_lic_until >= nomad_arch.kst_today() then
    v_state := 'licensed';
    select jsonb_object_agg(k, exists (select 1 from nomad_core.plan_features pf
                                       where pf.product_code = 'arch' and pf.plan_code = 'A' and pf.feature_code = k))
      into v_feat from unnest(v_bools) k;
    v_feat := v_feat || jsonb_build_object('drafting_watermark', not exists (
      select 1 from nomad_core.plan_features pf where pf.product_code = 'arch' and pf.plan_code = 'A' and pf.feature_code = 'drafting_no_watermark'));
    v_feat := v_feat || (select jsonb_object_agg(k, coalesce(
      (select pl.limit_value from nomad_core.plan_limits pl where pl.product_code = 'arch' and pl.plan_code = 'A' and pl.limit_key = k),
      (v_missing ->> k)::integer)) from unnest(v_ints) k);
  elsif v_sub_active and v_sub_plan in ('A', 'B') then
    v_state := case v_sub_plan when 'A' then 'subscribed' else 'trial' end;
    if v_sub_plan = 'B' then v_trial_end := v_sub_ends; end if;
    select jsonb_object_agg(k, nomad_core.org_has_feature(p_org, 'arch', k)) into v_feat from unnest(v_bools) k;
    v_feat := v_feat || jsonb_build_object('drafting_watermark', not nomad_core.org_has_feature(p_org, 'arch', 'drafting_no_watermark'));
    v_feat := v_feat || (select jsonb_object_agg(k, coalesce(nomad_core.org_plan_limit(p_org, 'arch', k), (v_missing ->> k)::integer))
                         from unnest(v_ints) k);
  elsif v_lic_until is not null then
    v_state := 'licensed_fallback';
    select s.fallback_features into v_feat
    from nomad_arch.licenses l join nomad_arch.license_skus s on s.code = l.sku_code
    where l.organization_id = p_org and l.status = 'active'
    order by l.updates_until desc, l.purchased_at limit 1;
  elsif v_sub_plan = 'A' then
    v_state := 'subscription_expired';
  else
    v_state := 'trial_expired';
  end if;

  if v_state in ('trial_expired', 'subscription_expired') then
    v_out := v_expired;
  else
    v_out := v_missing || coalesce((
      select jsonb_object_agg(f.key, f.value)
      from jsonb_each(coalesce(v_feat, '{}'::jsonb)) as f(key, value)
      where v_missing ? f.key and jsonb_typeof(f.value) = jsonb_typeof(v_missing -> f.key)), '{}'::jsonb);
  end if;

  return v_out || jsonb_build_object(
    'state', v_state, 'updates_until', v_lic_until, 'license_ids', v_lic_ids,
    'trial_ends_at', v_trial_end, 'plan_code', coalesce(case when v_sub_active then v_sub_plan end, 'C'));
end;
$$;

-- 실행 행이 잡만 끝난 상태로 남지 않게 정리(reap_stale_jobs·cancel_job 뒤). 서버 전용.
create function nomad_arch.reconcile_runs(p_org uuid) returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer := 0; v_c integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'reconcile_runs: server only' using errcode = '42501';
  end if;
  update nomad_arch.renders r set status = 'failed', error = coalesce(r.error, 'job ' || j.status), finished_at = now()
    from nomad_core.jobs j where r.organization_id = p_org and r.job_id = j.id and r.status in ('queued', 'running') and j.status in ('failed', 'canceled');
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update nomad_arch.reviews r set status = 'failed', error = coalesce(r.error, 'job ' || j.status), finished_at = now()
    from nomad_core.jobs j where r.organization_id = p_org and r.job_id = j.id and r.status in ('queued', 'running') and j.status in ('failed', 'canceled');
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update nomad_arch.intake_runs r set status = 'failed', error = coalesce(r.error, 'job ' || j.status), finished_at = now()
    from nomad_core.jobs j where r.organization_id = p_org and r.job_id = j.id and r.status in ('queued', 'running') and j.status in ('failed', 'canceled');
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  update nomad_arch.proposals r set status = 'failed', error = coalesce(r.error, 'job ' || j.status), finished_at = now()
    from nomad_core.jobs j where r.organization_id = p_org and r.job_id = j.id and r.status in ('queued', 'running') and j.status in ('failed', 'canceled');
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  return v_n;
end;
$$;

-- ---------- 6. 트리거 ----------
create function nomad_arch_private.enforce_run_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'queued' then
      raise exception '%: new run must be queued', tg_table_name using errcode = '22023';
    end if;
    return new;
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'queued' and new.status in ('running', 'failed'))
         or (old.status = 'running' and new.status in ('succeeded', 'failed'))
         or (old.status = 'failed' and new.status = 'refunded')) then
      raise exception '%: invalid transition % -> %', tg_table_name, old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'running' then new.started_at := coalesce(new.started_at, now()); end if;
    if new.status in ('succeeded', 'failed') then new.finished_at := coalesce(new.finished_at, now()); end if;
  end if;
  if new.request_id is distinct from old.request_id or new.organization_id is distinct from old.organization_id
     or new.credits is distinct from old.credits or new.credit_ledger_id is distinct from old.credit_ledger_id then
    raise exception '%: request_id, organization_id, credits and ledger are immutable', tg_table_name using errcode = '22023';
  end if;
  return new;
end;
$$;

create function nomad_arch_private.enforce_order_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.kind is distinct from old.kind
     or new.sku_code is distinct from old.sku_code or new.amount_krw is distinct from old.amount_krw
     or new.idempotency_key is distinct from old.idempotency_key then
    raise exception 'license_orders: organization, kind, sku, amount and key are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'pending' and new.status in ('paid', 'canceled'))
         or (old.status = 'paid' and new.status = 'refunded')) then
      raise exception 'license_orders: invalid transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    new.status_changed_at := now();
  end if;
  return new;
end;
$$;

create function nomad_arch_private.enforce_license_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.serial_hash is distinct from old.serial_hash or new.organization_id is distinct from old.organization_id
     or new.sku_code is distinct from old.sku_code or new.order_id is distinct from old.order_id then
    raise exception 'licenses: serial, organization, sku and order are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'active' and new.status in ('suspended', 'refunded', 'revoked'))
         or (old.status = 'suspended' and new.status in ('active', 'refunded', 'revoked'))) then
      raise exception 'licenses: invalid transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    new.status_changed_at := now();
  end if;
  return new;
end;
$$;

-- 환불·회수된 라이선스의 활성 기기를 모두 해제한다.
create function nomad_arch_private.after_license_status() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status in ('refunded', 'revoked') and old.status is distinct from new.status then
    update nomad_arch.license_activations a
       set deactivated_at = now(), deactivation_kind = case when new.status = 'refunded' then 'refund' else 'revoke' end
     where a.license_id = new.id and a.deactivated_at is null;
  end if;
  return null;
end;
$$;

create function nomad_arch_private.enforce_activation_rules() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.device_hash is distinct from old.device_hash or new.license_id is distinct from old.license_id
     or new.organization_id is distinct from old.organization_id or new.source is distinct from old.source then
    raise exception 'license_activations: device, license, organization and source are immutable' using errcode = '22023';
  end if;
  if old.deactivated_at is not null and (new.deactivated_at is distinct from old.deactivated_at
                                         or new.deactivation_kind is distinct from old.deactivation_kind) then
    raise exception 'license_activations: already deactivated' using errcode = '22023';
  end if;
  return new;
end;
$$;

create function nomad_arch_private.enforce_release_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if not ((old.status = 'draft' and new.status in ('published', 'withdrawn'))
         or (old.status = 'published' and new.status = 'withdrawn')) then
      raise exception '%: invalid transition % -> %', tg_table_name, old.status, new.status using errcode = '22023';
    end if;
  end if;
  if old.status <> 'draft' and (new.version is distinct from old.version or new.sha256 is distinct from old.sha256) then
    raise exception '%: published content is immutable', tg_table_name using errcode = '22023';
  end if;
  return new;
end;
$$;

create function nomad_arch_private.enforce_cloud_project_version() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.version < old.version or new.local_id is distinct from old.local_id or new.organization_id is distinct from old.organization_id then
    raise exception 'cloud_projects: version must not decrease, local_id/organization immutable' using errcode = '22023';
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['runtime_config', 'license_skus', 'builds', 'rule_packs', 'cost_catalogs', 'license_orders', 'licenses',
                           'license_activations', 'drafting_profiles', 'cloud_projects', 'renders', 'reviews', 'intake_runs', 'proposals'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_arch.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
  foreach t in array array['renders', 'reviews', 'intake_runs', 'proposals'] loop
    execute format('create trigger %1$s_status_transition before insert or update on nomad_arch.%1$I for each row execute function nomad_arch_private.enforce_run_transition()', t);
  end loop;
  foreach t in array array['builds', 'rule_packs', 'cost_catalogs'] loop
    execute format('create trigger %1$s_release_transition before update on nomad_arch.%1$I for each row execute function nomad_arch_private.enforce_release_transition()', t);
  end loop;
end $$;
create trigger license_orders_status_transition before update on nomad_arch.license_orders
  for each row execute function nomad_arch_private.enforce_order_transition();
create trigger licenses_status_transition before update on nomad_arch.licenses
  for each row execute function nomad_arch_private.enforce_license_transition();
create trigger licenses_after_status after update of status on nomad_arch.licenses
  for each row execute function nomad_arch_private.after_license_status();
create trigger license_activations_rules before update on nomad_arch.license_activations
  for each row execute function nomad_arch_private.enforce_activation_rules();
create trigger cloud_projects_version before update on nomad_arch.cloud_projects
  for each row execute function nomad_arch_private.enforce_cloud_project_version();

-- ---------- 7. 서버 RPC (service_role 전용) ----------
-- 7-0. 일회성 주문 만들기(D1). 금액은 서버가 정한다(license = 상품 가격, updates_extension = runtime_config price_krw.updates_yearly).
--      멱등 = (조직, idempotency_key): 같은 요청이면 기존 주문, 다르면 거부.
create function nomad_arch.create_license_order(p_org uuid, p_actor uuid, p_kind text, p_sku text, p_idempotency_key text)
returns nomad_arch.license_orders
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_arch.license_orders; v_amount integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'create_license_order: server only' using errcode = '42501';
  end if;
  if p_org is null or p_actor is null or p_kind is null or p_kind not in ('license', 'updates_extension')
     or p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 200
     or ((p_kind = 'license') <> (p_sku is not null)) then
    raise exception 'create_license_order: invalid input' using errcode = '22023';
  end if;
  if not exists (select 1 from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
                 where m.organization_id = p_org and m.user_id = p_actor and o.active and m.role in ('owner', 'admin')) then
    raise exception 'create_license_order: owner or admin only' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('arch:order:' || p_org::text || ':' || p_idempotency_key, 0));
  select * into v_row from nomad_arch.license_orders o where o.organization_id = p_org and o.idempotency_key = p_idempotency_key;
  if found then
    if v_row.kind <> p_kind or v_row.sku_code is distinct from p_sku then
      raise exception 'create_license_order: idempotency key reused with different request' using errcode = '22023';
    end if;
    return v_row;
  end if;
  if p_kind = 'license' then
    select s.price_krw into v_amount from nomad_arch.license_skus s where s.code = p_sku and s.is_active;
    if v_amount is null then
      raise exception 'create_license_order: unknown license sku' using errcode = '22023';
    end if;
  else
    if not exists (select 1 from nomad_arch.licenses l where l.organization_id = p_org and l.status = 'active') then
      raise exception 'create_license_order: no active license in organization' using errcode = 'AR003';
    end if;
    v_amount := nomad_arch_private.config_int('price_krw.updates_yearly', null);
    if v_amount is null or v_amount <= 0 then
      raise exception 'create_license_order: no price for updates_yearly' using errcode = '22023';
    end if;
  end if;
  insert into nomad_arch.license_orders (organization_id, kind, sku_code, amount_krw, idempotency_key, created_by)
  values (p_org, p_kind, p_sku, v_amount, p_idempotency_key, p_actor)
  returning * into v_row;
  perform nomad_core.write_audit(p_org, 'arch.order.create', 'license_order', v_row.id::text, null,
                                 jsonb_build_object('kind', p_kind, 'sku', p_sku, 'amount_krw', v_amount));
  return v_row;
end;
$$;

-- 7-0b. 외부 결제 서버의 결과 반영: paid(결제 확정 금액이 주문 금액과 같아야 함) · canceled
--       · refunded(라이선스 환불 → 기기 해제 + 보너스 크레딧 잔액 한도 회수 / 연장 환불 → 연장 되돌림).
--       같은 상태 재호출은 그대로 돌려준다(웹훅 재전송 멱등).
create function nomad_arch.mark_license_order(p_order_id uuid, p_status text, p_external_payment_ref text default null, p_amount_krw integer default null)
returns nomad_arch.license_orders
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_arch.license_orders; v_bonus integer; v_balance integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'mark_license_order: server only' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('paid', 'canceled', 'refunded') then
    raise exception 'mark_license_order: status must be paid, canceled or refunded' using errcode = '22023';
  end if;
  select * into v_row from nomad_arch.license_orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'mark_license_order: order not found' using errcode = 'P0002';
  end if;
  if v_row.status = p_status then
    if p_status = 'paid' and v_row.external_payment_ref is distinct from p_external_payment_ref then
      raise exception 'mark_license_order: already paid with another payment' using errcode = '22023';
    end if;
    return v_row;
  end if;
  if p_status = 'paid' then
    if p_external_payment_ref is null or p_amount_krw is distinct from v_row.amount_krw then
      raise exception 'mark_license_order: payment ref and matching amount required' using errcode = '22023';
    end if;
    update nomad_arch.license_orders o set status = 'paid', paid_at = now(), external_payment_ref = p_external_payment_ref
     where o.id = p_order_id returning * into v_row;
  else
    update nomad_arch.license_orders o set status = p_status where o.id = p_order_id returning * into v_row;
    if p_status = 'refunded' and v_row.kind = 'license' then
      select s.bonus_credits into v_bonus
      from nomad_arch.licenses l join nomad_arch.license_skus s on s.code = l.sku_code where l.order_id = p_order_id;
      update nomad_arch.licenses l set status = 'refunded', status_reason = 'order refunded'
       where l.order_id = p_order_id and l.status in ('active', 'suspended');
      -- 보너스 크레딧 회수(팀장 결정): 남은 잔액 한도 안에서만, 멱등 키 arch:bonus_clawback:<order>
      select coalesce(b.plan_balance, 0) + coalesce(b.pack_balance, 0) into v_balance
      from nomad_core.credit_bucket_balances(v_row.organization_id) b;
      v_bonus := least(coalesce(v_bonus, 0), greatest(coalesce(v_balance, 0), 0));
      if v_bonus > 0 then
        perform nomad_core.consume_credits(v_row.organization_id, v_bonus, 'arch.license_bonus_clawback',
                                           'arch:bonus_clawback:' || p_order_id::text, 'arch', 'license_order', p_order_id::text);
      end if;
    elsif p_status = 'refunded' and v_row.kind = 'updates_extension' then
      -- 연장 환불: extend_updates 효과를 되돌린다(+1년 취소, 주문 id 제거)
      update nomad_arch.licenses l
         set updates_until = (l.updates_until - interval '1 year')::date,
             extension_order_ids = array_remove(l.extension_order_ids, p_order_id)
       where l.organization_id = v_row.organization_id and p_order_id = any (l.extension_order_ids);
    end if;
  end if;
  perform nomad_core.write_audit(v_row.organization_id, 'arch.order.' || p_status, 'license_order', p_order_id::text);
  return v_row;
end;
$$;

-- 7-1. 라이선스 발급(주문 paid 후). 주문 id 멱등. 시리얼 원문은 첫 호출 반환값에서만(재호출은 null).
create function nomad_arch.issue_license(p_order_id uuid)
returns table (license_id uuid, serial text)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare v_order nomad_arch.license_orders; v_sku nomad_arch.license_skus; v_lic nomad_arch.licenses; v_body text; v_sold integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'issue_license: server only' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('arch:issue_license:' || coalesce(p_order_id::text, ''), 0));
  select * into v_lic from nomad_arch.licenses l where l.order_id = p_order_id;
  if found then
    return query select v_lic.id, null::text;
    return;
  end if;
  select * into v_order from nomad_arch.license_orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'issue_license: order not found' using errcode = 'P0002';
  end if;
  if v_order.kind <> 'license' or v_order.status <> 'paid' then
    raise exception 'issue_license: paid license order required' using errcode = '22023';
  end if;
  select * into v_sku from nomad_arch.license_skus s where s.code = v_order.sku_code;
  if v_order.amount_krw <> v_sku.price_krw then
    raise exception 'issue_license: amount mismatch' using errcode = '22023';
  end if;
  if v_sku.max_quantity is not null then
    perform pg_advisory_xact_lock(hashtextextended('arch:sku:' || v_sku.code, 0));
    select count(*) into v_sold from nomad_arch.licenses l where l.sku_code = v_sku.code and l.status <> 'refunded';
    if v_sold >= v_sku.max_quantity then
      raise exception 'issue_license: sku sold out' using errcode = '22023';
    end if;
  end if;

  v_body := nomad_arch_private.new_serial_body();
  insert into nomad_arch.licenses (organization_id, sku_code, order_id, serial_hash, serial_last5, status, purchased_at, updates_until, max_activations)
  values (v_order.organization_id, v_sku.code, v_order.id, encode(extensions.digest(v_body, 'sha256'), 'hex'), right(v_body, 5), 'active', now(),
          (nomad_arch.kst_today() + make_interval(months => v_sku.includes_updates_months))::date, v_sku.max_activations)
  returning * into v_lic;

  if v_sku.bonus_credits > 0 then
    perform nomad_core.grant_credits(v_lic.organization_id, v_sku.bonus_credits, 'arch.license_bonus', 'arch:license:' || v_lic.id::text, 'arch');
  end if;
  perform nomad_core.write_audit(v_lic.organization_id, 'arch.license.issue', 'license', v_lic.id::text, null,
                                 jsonb_build_object('sku', v_sku.code, 'serial_last5', v_lic.serial_last5, 'order_id', v_order.id));
  return query select v_lic.id,
    'ARCH-' || substr(v_body, 1, 5) || '-' || substr(v_body, 6, 5) || '-' || substr(v_body, 11, 5) || '-' || substr(v_body, 16, 5);
end;
$$;

-- 7-2. 영구 라이선스 기기 활성화. Route Handler 가 세션 user 를 p_user, 정규화 시리얼 본문의 SHA-256 을 넘긴다.
create function nomad_arch.activate_license(p_serial_hash text, p_device_hash text, p_user uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_lic nomad_arch.licenses; v_act nomad_arch.license_activations; v_active integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'activate_license: server only' using errcode = '42501';
  end if;
  if p_serial_hash is null or p_serial_hash !~ '^[0-9a-f]{64}$' or p_device_hash is null or p_device_hash !~ '^[0-9a-f]{64}$' or p_user is null then
    raise exception 'activate_license: invalid input' using errcode = '22023';
  end if;
  select * into v_lic from nomad_arch.licenses l where l.serial_hash = p_serial_hash for update;
  if not found then
    raise exception 'activate_license: serial not found' using errcode = 'AR002';
  end if;
  if not nomad_arch_private.actor_can_write(v_lic.organization_id, p_user) then
    raise exception 'activate_license: serial belongs to another organization' using errcode = 'AR006';
  end if;
  if v_lic.status <> 'active' then
    raise exception 'activate_license: license is %', v_lic.status using errcode = 'AR003';
  end if;
  select * into v_act from nomad_arch.license_activations a
  where a.license_id = v_lic.id and a.device_hash = p_device_hash and a.deactivated_at is null;
  if found then
    update nomad_arch.license_activations set last_seen_at = now() where id = v_act.id returning * into v_act;
  else
    select count(*) into v_active from nomad_arch.license_activations a where a.license_id = v_lic.id and a.deactivated_at is null;
    if v_active >= v_lic.max_activations then
      raise exception 'activate_license: activation limit % reached', v_lic.max_activations using errcode = 'AR001';
    end if;
    insert into nomad_arch.license_activations (organization_id, license_id, source, device_hash, activated_by)
    values (v_lic.organization_id, v_lic.id, 'license', p_device_hash, p_user)
    returning * into v_act;
    perform nomad_core.write_audit(v_lic.organization_id, 'arch.license.activate', 'license_activation', v_act.id::text, null,
                                   jsonb_build_object('license_id', v_lic.id, 'user_id', p_user));
  end if;
  return jsonb_build_object(
    'activation', jsonb_build_object('id', v_act.id, 'activated_at', v_act.activated_at, 'last_seen_at', v_act.last_seen_at),
    'license', jsonb_build_object('id', v_lic.id, 'organization_id', v_lic.organization_id, 'sku', v_lic.sku_code,
                                  'serial_last5', v_lic.serial_last5, 'updates_until', v_lic.updates_until, 'status', v_lic.status));
end;
$$;

-- 7-3. 체험·월 구독 기기 활성화(source 'plan'). 한도는 org_features.max_activations.
create function nomad_arch.activate_plan_device(p_org uuid, p_user uuid, p_device_hash text) returns nomad_arch.license_activations
language plpgsql security definer set search_path = ''
as $$
declare v_feat jsonb; v_act nomad_arch.license_activations; v_active integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'activate_plan_device: server only' using errcode = '42501';
  end if;
  if p_org is null or p_user is null or p_device_hash is null or p_device_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'activate_plan_device: invalid input' using errcode = '22023';
  end if;
  if not nomad_arch_private.actor_can_write(p_org, p_user) then
    raise exception 'activate_plan_device: not a member' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('arch:plan_device:' || p_org::text, 0));
  v_feat := nomad_arch.org_features(p_org);
  if v_feat ->> 'state' not in ('trial', 'subscribed') then
    raise exception 'activate_plan_device: no active trial or subscription (state %)', v_feat ->> 'state' using errcode = 'AR003';
  end if;
  select * into v_act from nomad_arch.license_activations a
  where a.organization_id = p_org and a.source = 'plan' and a.device_hash = p_device_hash and a.deactivated_at is null;
  if found then
    update nomad_arch.license_activations set last_seen_at = now() where id = v_act.id returning * into v_act;
    return v_act;
  end if;
  select count(*) into v_active from nomad_arch.license_activations a
  where a.organization_id = p_org and a.source = 'plan' and a.deactivated_at is null;
  if v_active >= nomad_arch.feature_int(v_feat, 'max_activations', 1) then
    raise exception 'activate_plan_device: activation limit reached' using errcode = 'AR001';
  end if;
  insert into nomad_arch.license_activations (organization_id, license_id, source, device_hash, activated_by)
  values (p_org, null, 'plan', p_device_hash, p_user)
  returning * into v_act;
  perform nomad_core.write_audit(p_org, 'arch.license.activate_plan_device', 'license_activation', v_act.id::text, null,
                                 jsonb_build_object('user_id', p_user, 'state', v_feat ->> 'state'));
  return v_act;
end;
$$;

-- 7-4. 업데이트 연장(updates_extension 주문 paid 후). 주문 id 멱등(extension_order_ids). 유효 중이면 +1년, 만료 후면 오늘 +1년.
create function nomad_arch.extend_updates(p_order_id uuid) returns setof nomad_arch.licenses
language plpgsql security definer set search_path = ''
as $$
declare v_order nomad_arch.license_orders;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'extend_updates: server only' using errcode = '42501';
  end if;
  select * into v_order from nomad_arch.license_orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'extend_updates: order not found' using errcode = 'P0002';
  end if;
  if v_order.kind <> 'updates_extension' or v_order.status <> 'paid' then
    raise exception 'extend_updates: paid updates_extension order required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('arch:extend:' || v_order.organization_id::text, 0));
  if exists (select 1 from nomad_arch.licenses l where l.organization_id = v_order.organization_id and p_order_id = any (l.extension_order_ids)) then
    return query select * from nomad_arch.licenses l where l.organization_id = v_order.organization_id and p_order_id = any (l.extension_order_ids);
    return;
  end if;
  if not exists (select 1 from nomad_arch.licenses l where l.organization_id = v_order.organization_id and l.status = 'active') then
    raise exception 'extend_updates: no active license in organization' using errcode = 'AR003';
  end if;
  return query
  update nomad_arch.licenses l
     set updates_until = case when l.updates_until >= nomad_arch.kst_today()
                              then (l.updates_until + interval '1 year')::date
                              else (nomad_arch.kst_today() + interval '1 year')::date end,
         extension_order_ids = l.extension_order_ids || p_order_id
   where l.organization_id = v_order.organization_id and l.status = 'active'
  returning l.*;
  perform nomad_core.write_audit(v_order.organization_id, 'arch.license.extend_updates', 'license_order', p_order_id::text);
end;
$$;

-- 7-5. 업데이트 매니페스트용 빌드 자격.
create function nomad_arch.eligible_build(p_org uuid, p_platform text, p_current text) returns nomad_arch.builds
language plpgsql stable security definer set search_path = ''
as $$
declare v_feat jsonb; v_limit date; v_row nomad_arch.builds;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'eligible_build: server only' using errcode = '42501';
  end if;
  if p_platform is null or p_platform !~ '^(windows|darwin)-(x86_64|aarch64)$'
     or p_current is null or p_current !~ '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}$' then
    raise exception 'eligible_build: invalid platform or version' using errcode = '22023';
  end if;
  v_feat := nomad_arch.org_features(p_org);
  if v_feat ->> 'state' in ('licensed', 'licensed_fallback') then
    v_limit := (v_feat ->> 'updates_until')::date;
  elsif v_feat ->> 'state' in ('trial', 'subscribed') then
    v_limit := 'infinity'::date;
  else
    return null;
  end if;
  select * into v_row from nomad_arch.builds b
  where b.platform = p_platform and b.channel = 'stable' and b.status = 'published' and b.build_date <= v_limit
    and string_to_array(b.version, '.')::integer[] > string_to_array(p_current, '.')::integer[]
  order by string_to_array(b.version, '.')::integer[] desc
  limit 1;
  if not found then
    return null;
  end if;
  return v_row;
end;
$$;

-- 7-6. 대지 조회 일일 상한(조직, KST). 같은 날 같은 지번 재조회는 세지 않는다. 반환: 남은 횟수.
create function nomad_arch.record_site_lookup(p_org uuid, p_pnu_hash text) returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_limit integer; v_used integer; v_today date := nomad_arch.kst_today();
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_site_lookup: server only' using errcode = '42501';
  end if;
  if p_org is null or p_pnu_hash is null or p_pnu_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'record_site_lookup: invalid input' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('arch:site:' || p_org::text, 0));
  v_limit := nomad_arch.feature_int(nomad_arch.org_features(p_org), 'site_lookups_per_day', 0);
  select count(*) into v_used from nomad_arch.site_lookups s where s.organization_id = p_org and s.lookup_date = v_today;
  if exists (select 1 from nomad_arch.site_lookups s where s.organization_id = p_org and s.lookup_date = v_today and s.pnu_hash = p_pnu_hash) then
    return greatest(v_limit - v_used, 0);
  end if;
  if v_used >= v_limit then
    raise exception 'record_site_lookup: daily limit % reached', v_limit using errcode = 'AR020';
  end if;
  insert into nomad_arch.site_lookups (organization_id, lookup_date, pnu_hash) values (p_org, v_today, p_pnu_hash);
  return v_limit - v_used - 1;
end;
$$;

-- 7-7. AI 실행 시작: 검사 → 크레딧 선차감(nomad_core.consume_credits) → 실행 행 → 잡 enqueue(nomad_core.enqueue_job) 한 트랜잭션.
--      차감액은 runtime_config price.<variant>(클라이언트 금액 없음). 같은 request_id 는 기존 실행을 돌려준다.
create function nomad_arch.start_ai_run(
  p_org uuid, p_actor uuid, p_kind text, p_variant text, p_request_id uuid, p_project_ref uuid, p_options jsonb default '{}'::jsonb
)
returns table (run_id uuid, job_id uuid, credits integer)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_opt jsonb := coalesce(p_options, '{}'::jsonb);
  v_feat jsonb; v_credits integer; v_run_id uuid := gen_random_uuid(); v_job_type text; v_ledger uuid;
  v_job nomad_core.jobs; v_existing record; v_used integer; v_cap integer; v_max_px integer; v_payload jsonb;
  v_src uuid; v_path text; v_rid uuid; v_stt uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'start_ai_run: server only' using errcode = '42501';
  end if;
  if p_org is null or p_actor is null or p_request_id is null or p_project_ref is null or jsonb_typeof(v_opt) <> 'object' then
    raise exception 'start_ai_run: org, actor, request_id, project_ref required' using errcode = '22023';
  end if;
  if pg_column_size(v_opt) > 262144 then
    raise exception 'start_ai_run: options too large' using errcode = 'AR031';
  end if;
  if not ((p_kind = 'render' and p_variant in ('render_std', 'render_hq', 'upscale'))
       or (p_kind = 'review' and p_variant = 'review')
       or (p_kind = 'intake' and p_variant in ('intake_text', 'intake_consult'))
       or (p_kind = 'proposal' and p_variant in ('proposal', 'doc_template'))
       or (p_kind = 'layout' and p_variant = 'layout')
       or (p_kind = 'walkthrough' and p_variant = 'walkthrough')) then
    raise exception 'start_ai_run: invalid kind/variant %/%', p_kind, p_variant using errcode = '22023';
  end if;
  if p_kind in ('layout', 'walkthrough') then
    raise exception 'start_ai_run: % is Phase 2 (no run table yet)', p_kind using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('arch:run:' || p_request_id::text, 0));
  select x.id, x.job_id, x.credits, x.organization_id into v_existing from (
    select r.id, r.job_id, r.credits, r.organization_id from nomad_arch.renders r where r.request_id = p_request_id
    union all select r.id, r.job_id, r.credits, r.organization_id from nomad_arch.reviews r where r.request_id = p_request_id
    union all select r.id, r.job_id, r.credits, r.organization_id from nomad_arch.intake_runs r where r.request_id = p_request_id
    union all select r.id, r.job_id, r.credits, r.organization_id from nomad_arch.proposals r where r.request_id = p_request_id) x
  limit 1;
  if found then
    if v_existing.organization_id <> p_org then
      raise exception 'start_ai_run: request_id belongs to another organization' using errcode = '42501';
    end if;
    return query select v_existing.id, v_existing.job_id, v_existing.credits;
    return;
  end if;

  if not nomad_arch_private.actor_can_write(p_org, p_actor) then
    raise exception 'start_ai_run: not a member' using errcode = '42501';
  end if;
  v_feat := nomad_arch.org_features(p_org);
  if v_feat ->> 'state' in ('trial_expired', 'subscription_expired') then
    raise exception 'start_ai_run: no active plan or license (state %)', v_feat ->> 'state' using errcode = '42501';
  end if;
  if p_kind = 'review' and not nomad_arch.feature_bool(v_feat, 'cloud_review', false) then
    raise exception 'start_ai_run: cloud review is not available in state %', v_feat ->> 'state' using errcode = 'AR012';
  end if;
  if (p_kind in ('render', 'proposal') and not nomad_arch.feature_bool(v_feat, 'ai_render', false))
     or (p_kind = 'intake' and not nomad_arch.feature_bool(v_feat, 'ai_intake', false)) then
    raise exception 'start_ai_run: feature not available in state %', v_feat ->> 'state' using errcode = '42501';
  end if;

  v_credits := nomad_arch_private.config_int('price.' || p_variant, null);
  if v_credits is null then
    raise exception 'start_ai_run: no price for %', p_variant using errcode = '22023';
  end if;

  perform nomad_arch.reconcile_runs(p_org);

  if p_kind = 'render' then
    v_max_px := nomad_arch.feature_int(v_feat, 'render_max_px', 1024);
    if (p_variant = 'render_hq' and v_max_px < 2048) or (p_variant = 'upscale' and v_max_px < 4096) then
      raise exception 'start_ai_run: % exceeds render_max_px %', p_variant, v_max_px using errcode = '22023';
    end if;
    if (select count(*) from nomad_arch.renders r where r.organization_id = p_org and r.status in ('queued', 'running'))
       >= nomad_arch_private.config_int('render_max_active_per_org', 3) then
      raise exception 'start_ai_run: too many active renders' using errcode = 'AR030';
    end if;
    if p_variant = 'upscale' then
      v_src := nullif(v_opt #>> '{inputs,source_render_id}', '')::uuid;
      if v_src is null or not exists (select 1 from nomad_arch.renders r where r.id = v_src and r.organization_id = p_org
                                       and r.status = 'succeeded' and r.purged_at is null and r.expires_at > now()) then
        raise exception 'start_ai_run: source render not found' using errcode = 'P0002';
      end if;
    elsif not nomad_arch.valid_user_path(p_org, 'render_input', v_opt #>> '{inputs,depth_path}')
       or not nomad_arch.valid_user_path(p_org, 'render_input', v_opt #>> '{inputs,edge_path}') then
      raise exception 'start_ai_run: render input path must be own render_input upload' using errcode = '23514';
    end if;
    v_payload := jsonb_build_object('quality', case p_variant when 'render_std' then 'standard' when 'render_hq' then 'high' else 'upscale' end,
                                    'preset', coalesce(v_opt -> 'preset', '{}'::jsonb), 'inputs', coalesce(v_opt -> 'inputs', '{}'::jsonb),
                                    'max_px', v_max_px);
  elsif p_kind = 'review' then
    if jsonb_typeof(v_opt -> 'judgment') is distinct from 'object' or coalesce(v_opt ->> 'rule_pack_version', '') = ''
       or coalesce(v_opt ->> 'application_date', '') = '' or coalesce(v_opt ->> 'municipality_code', '') = '' then
      raise exception 'start_ai_run: review needs judgment, rule_pack_version, application_date, municipality_code' using errcode = '22023';
    end if;
    if pg_column_size(v_opt -> 'judgment') > 262144 then
      raise exception 'start_ai_run: judgment too large' using errcode = 'AR031';
    end if;
    v_payload := jsonb_build_object('rule_pack_version', v_opt ->> 'rule_pack_version', 'application_date', v_opt ->> 'application_date',
                                    'municipality_code', v_opt ->> 'municipality_code');
  elsif p_kind = 'intake' then
    v_stt := nullif(v_opt ->> 'stt_job_id', '')::uuid;
    if v_stt is not null and not exists (select 1 from nomad_core.jobs j where j.id = v_stt and j.organization_id = p_org) then
      raise exception 'start_ai_run: stt job not found' using errcode = 'P0002';
    end if;
    v_payload := jsonb_build_object('source', case p_variant when 'intake_consult' then 'consult' else 'chat' end, 'stt_job_id', v_stt);
  else
    if not nomad_arch.valid_user_path(p_org, 'proposal_content', v_opt ->> 'content_path')
       or coalesce(v_opt ->> 'content_sha256', '') !~ '^[0-9a-f]{64}$' then
      raise exception 'start_ai_run: proposal content path/sha256 invalid' using errcode = '23514';
    end if;
    if jsonb_typeof(coalesce(v_opt -> 'drawing_sheets', '[]'::jsonb)) <> 'array'
       or jsonb_typeof(coalesce(v_opt -> 'render_ids', '[]'::jsonb)) <> 'array' then
      raise exception 'start_ai_run: drawing_sheets and render_ids must be arrays' using errcode = '22023';
    end if;
    for v_path in select jsonb_array_elements_text(coalesce(v_opt -> 'drawing_sheets', '[]'::jsonb)) loop
      if not nomad_arch.valid_user_path(p_org, 'proposal_sheet', v_path) then
        raise exception 'start_ai_run: drawing sheet path must be own proposal_sheet upload' using errcode = '23514';
      end if;
    end loop;
    for v_rid in select (jsonb_array_elements_text(coalesce(v_opt -> 'render_ids', '[]'::jsonb)))::uuid loop
      if not exists (select 1 from nomad_arch.renders r where r.id = v_rid and r.organization_id = p_org and r.status = 'succeeded'
                     and r.purged_at is null and r.expires_at > now()) then
        raise exception 'start_ai_run: render % not found', v_rid using errcode = 'P0002';
      end if;
    end loop;
    if p_variant = 'doc_template' and exists (
         select 1 from nomad_arch.proposals x where x.organization_id = p_org and x.variant = 'doc_template' and x.status = 'succeeded'
           and x.content_sha256 = v_opt ->> 'content_sha256' and x.template_version = v_opt ->> 'template_version') then
      v_credits := 0;   -- 같은 버전 재요청 0크레딧
    end if;
    v_payload := jsonb_build_object('kind', coalesce(v_opt ->> 'doc_kind', 'proposal'), 'content_path', v_opt ->> 'content_path',
                                    'content_sha256', v_opt ->> 'content_sha256', 'render_ids', coalesce(v_opt -> 'render_ids', '[]'::jsonb),
                                    'drawing_sheets', coalesce(v_opt -> 'drawing_sheets', '[]'::jsonb),
                                    'template_version', v_opt ->> 'template_version', 'narrative', p_variant = 'proposal');
  end if;

  -- 일일 플랫폼 상한(서킷 브레이커). 0·미설정이면 끔.
  v_cap := nomad_arch_private.config_int('daily_credit_cap', 0);
  if v_cap > 0 and v_credits > 0 then
    perform pg_advisory_xact_lock(hashtextextended('arch:daily_cap', 0));
    select coalesce(sum(x.c), 0) into v_used from (
      select r.credits as c from nomad_arch.renders r where r.created_at >= (nomad_arch.kst_today()::timestamp at time zone 'Asia/Seoul')
      union all select r.credits from nomad_arch.reviews r where r.created_at >= (nomad_arch.kst_today()::timestamp at time zone 'Asia/Seoul')
      union all select r.credits from nomad_arch.intake_runs r where r.created_at >= (nomad_arch.kst_today()::timestamp at time zone 'Asia/Seoul')
      union all select r.credits from nomad_arch.proposals r where r.created_at >= (nomad_arch.kst_today()::timestamp at time zone 'Asia/Seoul')) x;
    if v_used + v_credits > v_cap then
      raise exception 'start_ai_run: daily platform credit cap reached' using errcode = 'AR034';
    end if;
  end if;

  -- 선차감(원자, 멱등 키 arch:consume:<request_id>). 부족하면 예외로 전체 롤백.
  if v_credits > 0 then
    select c.ledger_id into v_ledger
    from nomad_core.consume_credits(p_org, v_credits, 'arch.' || p_variant, 'arch:consume:' || p_request_id::text,
                                    'arch', 'arch_' || p_kind, v_run_id::text) c;
  end if;

  if p_kind = 'render' then
    insert into nomad_arch.renders (id, organization_id, project_ref, request_id, variant, credits, credit_ledger_id, options, source_render_id, created_by)
    values (v_run_id, p_org, p_project_ref, p_request_id, p_variant, v_credits, v_ledger,
            jsonb_build_object('preset', coalesce(v_opt -> 'preset', '{}'::jsonb), 'inputs', coalesce(v_opt -> 'inputs', '{}'::jsonb)),
            v_src, p_actor);
  elsif p_kind = 'review' then
    insert into nomad_arch.reviews (id, organization_id, project_ref, request_id, credits, credit_ledger_id, rule_pack_version, application_date,
                                    municipality_code, judgment, model_summary, created_by)
    values (v_run_id, p_org, p_project_ref, p_request_id, v_credits, v_ledger, v_opt ->> 'rule_pack_version', (v_opt ->> 'application_date')::date,
            v_opt ->> 'municipality_code', v_opt -> 'judgment', coalesce(v_opt -> 'model_summary', '{}'::jsonb), p_actor);
  elsif p_kind = 'intake' then
    insert into nomad_arch.intake_runs (id, organization_id, project_ref, request_id, variant, source, input_kind, credits, credit_ledger_id,
                                        input_text, stt_job_id, notice_version, created_by)
    values (v_run_id, p_org, p_project_ref, p_request_id, p_variant, case p_variant when 'intake_consult' then 'consult' else 'chat' end,
            case when v_stt is null then 'text' else 'voice' end, v_credits, v_ledger,
            case when v_stt is null then v_opt ->> 'text' else null end, v_stt, v_opt ->> 'notice_version', p_actor);
  else
    insert into nomad_arch.proposals (id, organization_id, project_ref, request_id, variant, doc_kind, credits, credit_ledger_id, template_version,
                                      content_path, content_sha256, render_ids, sheet_paths, created_by)
    values (v_run_id, p_org, p_project_ref, p_request_id, p_variant, coalesce(v_opt ->> 'doc_kind', 'proposal'), v_credits, v_ledger,
            v_opt ->> 'template_version', v_opt ->> 'content_path', v_opt ->> 'content_sha256',
            coalesce((select array_agg(e::uuid) from jsonb_array_elements_text(coalesce(v_opt -> 'render_ids', '[]'::jsonb)) as e), '{}'),
            coalesce((select array_agg(e) from jsonb_array_elements_text(coalesce(v_opt -> 'drawing_sheets', '[]'::jsonb)) as e), '{}'),
            p_actor);
  end if;

  v_job_type := case p_kind when 'proposal' then 'arch.proposal_pdf' else 'arch.' || p_kind end;
  select * into v_job from nomad_core.enqueue_job(
    p_org, 'arch', v_job_type,
    jsonb_build_object('run_id', v_run_id, 'variant', p_variant) || coalesce(v_payload, '{}'::jsonb),
    v_job_type, 100, now(), 2, v_ledger, 'arch:job:' || p_request_id::text, null, p_actor, true);

  if p_kind = 'render' then update nomad_arch.renders r set job_id = v_job.id where r.id = v_run_id;
  elsif p_kind = 'review' then update nomad_arch.reviews r set job_id = v_job.id where r.id = v_run_id;
  elsif p_kind = 'intake' then update nomad_arch.intake_runs r set job_id = v_job.id where r.id = v_run_id;
  else update nomad_arch.proposals r set job_id = v_job.id where r.id = v_run_id;
  end if;

  return query select v_run_id, v_job.id, v_credits;
end;
$$;

-- 7-8. AI 실행 종료: 잡 행을 잠그고(실패·취소된 잡이면 거부 — 이미 환불된 실행에 결과를 저장하지 않는다) 결과 검증·저장 + succeeded,
--      nomad_core.mark_job_delivered 로 이후 잡 실패 환불을 막는다. 워커는 이어서 nomad_core.complete_job 을 부른다.
create function nomad_arch.finish_ai_run(p_run_id uuid, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_org uuid; v_status text; v_kind text; v_job uuid; v_job_status text; v_bad integer; v_days integer := nomad_arch_private.config_int('render_retention_days', 90);
begin
  if not nomad_core.is_service_caller() then
    raise exception 'finish_ai_run: server only' using errcode = '42501';
  end if;
  if p_result is null or jsonb_typeof(p_result) <> 'object' then
    raise exception 'finish_ai_run: result object required' using errcode = '22023';
  end if;
  select r.organization_id, r.status, r.job_id, 'render' into v_org, v_status, v_job, v_kind from nomad_arch.renders r where r.id = p_run_id for update;
  if not found then
    select r.organization_id, r.status, r.job_id, 'review' into v_org, v_status, v_job, v_kind from nomad_arch.reviews r where r.id = p_run_id for update;
  end if;
  if not found then
    select r.organization_id, r.status, r.job_id, 'intake' into v_org, v_status, v_job, v_kind from nomad_arch.intake_runs r where r.id = p_run_id for update;
  end if;
  if not found then
    select r.organization_id, r.status, r.job_id, 'proposal' into v_org, v_status, v_job, v_kind from nomad_arch.proposals r where r.id = p_run_id for update;
  end if;
  if v_kind is null then
    raise exception 'finish_ai_run: run not found' using errcode = 'P0002';
  end if;
  if v_status not in ('queued', 'running') then
    raise exception 'finish_ai_run: run is %', v_status using errcode = '22023';
  end if;
  if v_job is not null then
    select j.status into v_job_status from nomad_core.jobs j where j.id = v_job for update;
    if v_job_status in ('failed', 'canceled') then
      raise exception 'finish_ai_run: job is % (credits already refunded)', v_job_status using errcode = '55000';
    end if;
  end if;

  if v_kind = 'render' then
    if not nomad_arch.valid_user_path(v_org, 'render', p_result ->> 'output_path')
       or coalesce(p_result ->> 'output_path', '') !~ '\.(png|jpg|webp)$' then
      raise exception 'finish_ai_run: render output must be under own org render folder' using errcode = '23514';
    end if;
    if coalesce((p_result ->> 'ai_label')::boolean, false) is not true then
      raise exception 'finish_ai_run: ai_label must be true' using errcode = '22023';
    end if;
    update nomad_arch.renders r set status = 'running' where r.id = p_run_id and r.status = 'queued';
    update nomad_arch.renders r
       set status = 'succeeded', output_path = p_result ->> 'output_path',
           width = (p_result ->> 'width')::integer, height = (p_result ->> 'height')::integer, bytes = (p_result ->> 'bytes')::bigint,
           provider = left(p_result ->> 'provider', 40), model = left(p_result ->> 'model', 120), seed = (p_result ->> 'seed')::bigint,
           ai_label = true, expires_at = now() + make_interval(days => v_days)
     where r.id = p_run_id;
  elsif v_kind = 'review' then
    if p_result ->> 'schema_version' is distinct from 'review.v1' or jsonb_typeof(p_result -> 'items') is distinct from 'array' then
      raise exception 'finish_ai_run: review.v1 result required' using errcode = 'AR033';
    end if;
    select count(*) into v_bad
    from (select s.value as sentence
          from jsonb_array_elements(p_result -> 'items') as i(item)
          cross join lateral jsonb_array_elements(coalesce(i.item -> 'sentences', '[]'::jsonb)) as s(value)
          union all
          select n.value from jsonb_array_elements(coalesce(p_result -> 'needs_check', '[]'::jsonb)) as n(value)) z
    where jsonb_typeof(z.sentence -> 'source_ids') is distinct from 'array' or jsonb_array_length(z.sentence -> 'source_ids') = 0;
    if v_bad > 0 then
      raise exception 'finish_ai_run: % sentences without sources', v_bad using errcode = 'AR033';
    end if;
    update nomad_arch.reviews r set status = 'running' where r.id = p_run_id and r.status = 'queued';
    update nomad_arch.reviews r set status = 'succeeded', result = p_result, disclaimer_version = left(p_result ->> 'disclaimer_version', 40)
     where r.id = p_run_id;
  elsif v_kind = 'intake' then
    if p_result ->> 'schema_version' is distinct from 'intake.v1'
       or exists (select 1 from jsonb_object_keys(p_result) k where k not in ('schema_version', 'checklist_answers', 'rooms', 'memo'))
       or jsonb_typeof(p_result -> 'checklist_answers') is distinct from 'array'
       or jsonb_typeof(p_result -> 'rooms') is distinct from 'array'
       or jsonb_typeof(p_result -> 'memo') is distinct from 'array'
       or exists (select 1 from jsonb_array_elements(p_result -> 'rooms') r(room)
                  where jsonb_typeof(r.room) <> 'object'
                     or exists (select 1 from jsonb_object_keys(r.room) k where k not in ('name', 'use', 'count', 'target_area_m2', 'area_evidence'))
                     or (jsonb_typeof(r.room -> 'target_area_m2') = 'number' and jsonb_typeof(r.room -> 'area_evidence') is distinct from 'string'))
       or exists (select 1 from jsonb_array_elements(p_result -> 'checklist_answers') c(item)
                  where jsonb_typeof(c.item) <> 'object'
                     or exists (select 1 from jsonb_object_keys(c.item) k where k not in ('question_id', 'answer', 'confidence', 'evidence'))) then
      raise exception 'finish_ai_run: intake.v1 schema violation' using errcode = 'AR032';
    end if;
    update nomad_arch.intake_runs r set status = 'running' where r.id = p_run_id and r.status = 'queued';
    update nomad_arch.intake_runs r set status = 'succeeded', result = p_result where r.id = p_run_id;
  else
    if coalesce(p_result ->> 'pdf_path', '') !~ ('^' || v_org::text || '/arch/pdf/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$') then
      raise exception 'finish_ai_run: pdf must be under own org exports folder' using errcode = '23514';
    end if;
    update nomad_arch.proposals r set status = 'running' where r.id = p_run_id and r.status = 'queued';
    update nomad_arch.proposals r
       set status = 'succeeded', pdf_path = p_result ->> 'pdf_path', pages = (p_result ->> 'pages')::integer,
           bytes = (p_result ->> 'bytes')::bigint, narrative = p_result -> 'narrative'
     where r.id = p_run_id;
  end if;
  if v_job is not null then
    perform nomad_core.mark_job_delivered(v_job);   -- 결과를 넘긴 실행은 이후 잡 실패로 환불하지 않는다
  end if;
  return jsonb_build_object('run_id', p_run_id, 'kind', v_kind, 'status', 'succeeded');
end;
$$;

-- 7-9. AI 실행 실패: failed → 남은 크레딧 환불(nomad_core.refund_credits, 키 arch:refund:<run_id>; 잡 실패로 이미 환불됐으면 0) → refunded.
--      워커 계약: 최종 실패에서만 부른다(fail_job 이 재시도로 잡을 queued 로 돌린 경우 호출 금지). 잡이 아직 queued·running 이면 55000 으로 거부.
create function nomad_arch.fail_ai_run(p_run_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_status text; v_ledger uuid; v_job uuid; v_job_status text; v_kind text; v_final text := 'failed'; v_reason text := left(coalesce(p_reason, 'failed'), 1000);
begin
  if not nomad_core.is_service_caller() then
    raise exception 'fail_ai_run: server only' using errcode = '42501';
  end if;
  select r.status, r.credit_ledger_id, r.job_id, 'render' into v_status, v_ledger, v_job, v_kind from nomad_arch.renders r where r.id = p_run_id for update;
  if not found then
    select r.status, r.credit_ledger_id, r.job_id, 'review' into v_status, v_ledger, v_job, v_kind from nomad_arch.reviews r where r.id = p_run_id for update;
  end if;
  if not found then
    select r.status, r.credit_ledger_id, r.job_id, 'intake' into v_status, v_ledger, v_job, v_kind from nomad_arch.intake_runs r where r.id = p_run_id for update;
  end if;
  if not found then
    select r.status, r.credit_ledger_id, r.job_id, 'proposal' into v_status, v_ledger, v_job, v_kind from nomad_arch.proposals r where r.id = p_run_id for update;
  end if;
  if v_kind is null then
    raise exception 'fail_ai_run: run not found' using errcode = 'P0002';
  end if;
  if v_status not in ('queued', 'running', 'failed') then
    raise exception 'fail_ai_run: run is %', v_status using errcode = '22023';
  end if;
  if v_job is not null then
    select j.status into v_job_status from nomad_core.jobs j where j.id = v_job for update;
    if v_job_status in ('queued', 'running') then
      raise exception 'fail_ai_run: job is still % (call only after final failure)', v_job_status using errcode = '55000';
    end if;
  end if;
  if v_status in ('queued', 'running') then
    if v_kind = 'render' then update nomad_arch.renders r set status = 'failed', error = v_reason where r.id = p_run_id;
    elsif v_kind = 'review' then update nomad_arch.reviews r set status = 'failed', error = v_reason where r.id = p_run_id;
    elsif v_kind = 'intake' then update nomad_arch.intake_runs r set status = 'failed', error = v_reason where r.id = p_run_id;
    else update nomad_arch.proposals r set status = 'failed', error = v_reason where r.id = p_run_id;
    end if;
  end if;
  if v_ledger is not null then
    perform nomad_core.refund_credits(v_ledger, 'arch.run_failed', 'arch:refund:' || p_run_id::text, null);
    v_final := 'refunded';
    if v_kind = 'render' then update nomad_arch.renders r set status = 'refunded' where r.id = p_run_id;
    elsif v_kind = 'review' then update nomad_arch.reviews r set status = 'refunded' where r.id = p_run_id;
    elsif v_kind = 'intake' then update nomad_arch.intake_runs r set status = 'refunded' where r.id = p_run_id;
    else update nomad_arch.proposals r set status = 'refunded' where r.id = p_run_id;
    end if;
  end if;
  return jsonb_build_object('run_id', p_run_id, 'kind', v_kind, 'status', v_final);
end;
$$;

-- 7-10. 보존 기간 정리(워커 크론 매일). 만료 렌더는 purged_at 표시 후 삭제할 Storage 경로를 돌려준다.
create function nomad_arch.purge_expired() returns table (bucket text, path text)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_expired: server only' using errcode = '42501';
  end if;
  delete from nomad_arch.site_lookups s where s.created_at < now() - make_interval(days => nomad_arch_private.config_int('site_lookup_retention_days', 90));
  delete from nomad_arch.intake_runs r where r.expires_at < now() and r.status in ('succeeded', 'failed', 'refunded');
  return query
  update nomad_arch.renders r set purged_at = now()
   where r.status = 'succeeded' and r.purged_at is null and r.expires_at < now()
  returning 'org-files'::text, r.output_path;
end;
$$;

-- ---------- 8. 사용자 RPC (authenticated) ----------
-- 8-0. 공개 상품 목록(가격 화면, D8: anon 은 이 RPC 만). 입력 없음. 요청 제한은 앞단(CDN·Route Handler) 캐시로 — existing.md.
create function nomad_arch.public_license_skus()
returns table (code text, name text, price_krw integer, includes_updates_months integer, bonus_credits integer,
               max_activations integer, max_quantity integer, sort_order integer)
language sql stable security definer set search_path = ''
as $$
  select s.code, s.name, s.price_krw, s.includes_updates_months, s.bonus_credits, s.max_activations, s.max_quantity, s.sort_order
  from nomad_arch.license_skus s where s.is_active order by s.sort_order, s.code
$$;

-- 8-1. 기기 해제(owner/admin). 사용자 셀프 해제는 조직당 30일 self_deactivations_per_30d(기본 3)회(AR004). 서버(고객지원) 해제는 세지 않는다.
create function nomad_arch.deactivate_activation(p_activation_id uuid) returns nomad_arch.license_activations
language plpgsql security definer set search_path = ''
as $$
declare v_act nomad_arch.license_activations; v_used integer; v_svc boolean := nomad_core.is_service_caller();
begin
  select * into v_act from nomad_arch.license_activations a where a.id = p_activation_id for update;
  if not found or (not v_svc and nomad_core.organization_role(v_act.organization_id) is null) then
    raise exception 'deactivate_activation: not found' using errcode = 'P0002';
  end if;
  if not v_svc and coalesce(nomad_core.organization_role(v_act.organization_id) not in ('owner', 'admin'), true) then
    raise exception 'deactivate_activation: owner or admin only' using errcode = '42501';
  end if;
  if v_act.deactivated_at is not null then
    return v_act;
  end if;
  if not v_svc then
    perform pg_advisory_xact_lock(hashtextextended('arch:deactivate:' || v_act.organization_id::text, 0));
    select count(*) into v_used from nomad_arch.license_activations a
    where a.organization_id = v_act.organization_id and a.deactivation_kind = 'self' and a.deactivated_at > now() - interval '30 days';
    if v_used >= nomad_arch_private.config_int('self_deactivations_per_30d', 3) then
      raise exception 'deactivate_activation: self deactivation limit reached' using errcode = 'AR004';
    end if;
  end if;
  update nomad_arch.license_activations a
     set deactivated_at = now(), deactivated_by = auth.uid(), deactivation_kind = case when v_svc then 'support' else 'self' end
   where a.id = p_activation_id
  returning * into v_act;
  perform nomad_core.write_audit(v_act.organization_id, 'arch.license.deactivate', 'license_activation', v_act.id::text, null,
                                 jsonb_build_object('kind', v_act.deactivation_kind));
  return v_act;
end;
$$;

-- 8-2. 받을 수 있는 규칙 팩 목록. 업데이트 유효면 게시된 전부, 폴백이면 published_at <= updates_until.
create function nomad_arch.eligible_rule_packs(p_org uuid default null)
returns table (version text, published_at timestamptz, basis_date date, sha256 text, signature text, kid text, bytes bigint, status text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare v_org uuid; v_feat jsonb; v_limit timestamptz;
begin
  v_org := case when nomad_core.is_service_caller() then p_org else nomad_arch_private.caller_org(p_org) end;
  if v_org is null then
    raise exception 'eligible_rule_packs: org required' using errcode = '22023';
  end if;
  v_feat := nomad_arch.org_features(v_org);
  if nomad_arch.feature_bool(v_feat, 'rule_pack_updates', false) then
    v_limit := 'infinity'::timestamptz;
  elsif v_feat ->> 'state' = 'licensed_fallback' then
    v_limit := (((v_feat ->> 'updates_until')::date + 1)::timestamp at time zone 'Asia/Seoul');
  else
    return;
  end if;
  return query
  select p.version, p.published_at, p.basis_date, p.sha256, p.signature, p.kid, p.bytes, p.status
  from nomad_arch.rule_packs p
  where p.status = 'published' and p.published_at < v_limit
  order by p.published_at desc;
end;
$$;

-- 8-3. 받을 수 있는 최신 공사비 단가표(규칙 팩과 같은 자격).
create function nomad_arch.latest_cost_catalog(p_org uuid default null)
returns table (version text, basis_date date, published_at timestamptz, items jsonb, source_note text, sha256 text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare v_org uuid; v_feat jsonb; v_limit timestamptz;
begin
  v_org := case when nomad_core.is_service_caller() then p_org else nomad_arch_private.caller_org(p_org) end;
  if v_org is null then
    raise exception 'latest_cost_catalog: org required' using errcode = '22023';
  end if;
  v_feat := nomad_arch.org_features(v_org);
  if nomad_arch.feature_bool(v_feat, 'rule_pack_updates', false) then
    v_limit := 'infinity'::timestamptz;
  elsif v_feat ->> 'state' = 'licensed_fallback' then
    v_limit := (((v_feat ->> 'updates_until')::date + 1)::timestamp at time zone 'Asia/Seoul');
  else
    return;
  end if;
  return query
  select c.version, c.basis_date, c.published_at, c.items, c.source_note, c.sha256
  from nomad_arch.cost_catalogs c
  where c.status = 'published' and c.published_at < v_limit
  order by c.published_at desc
  limit 1;
end;
$$;

-- 8-4. 표제란·레이어 매핑 저장(owner/admin, AR042). 허용 키 밖(건축주 이름 등)은 22023. 감사에는 바뀐 키 이름만.
create function nomad_arch.upsert_drafting_profile(p jsonb, p_org uuid default null) returns nomad_arch.drafting_profiles
language plpgsql security definer set search_path = ''
as $$
declare
  v_org uuid; v_row nomad_arch.drafting_profiles;
  v_std constant text[] := array['A-SITE-BNDY', 'A-SITE-ROAD', 'A-SITE-SETB', 'A-ENVL', 'A-MASS', 'A-WALL', 'A-DOOR', 'A-GLAZ',
                                 'A-AREA', 'A-AREA-IDEN', 'A-PARK', 'A-ANNO-DIMS', 'A-ANNO-TEXT', 'A-ANNO-NRTH', 'A-TTLB', 'A-REFR'];
  v_keys constant text[] := array['office_name', 'architect_name', 'contact', 'logo_storage_path', 'layer_map',
                                  'default_paper', 'default_text_height_mm', 'font_family'];
begin
  v_org := nomad_arch_private.caller_org(p_org);
  if coalesce(nomad_core.organization_role(v_org) not in ('owner', 'admin'), true) then
    raise exception 'upsert_drafting_profile: owner or admin only' using errcode = 'AR042';
  end if;
  if not nomad_arch.has_access(v_org) then
    raise exception 'upsert_drafting_profile: no arch access' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' or pg_column_size(p) > 16384
     or exists (select 1 from jsonb_object_keys(p) k where k <> all (v_keys)) then
    raise exception 'upsert_drafting_profile: unknown keys (allowed: %)', array_to_string(v_keys, ', ') using errcode = '22023';
  end if;
  if p ? 'layer_map' and (jsonb_typeof(p -> 'layer_map') <> 'object'
       or exists (select 1 from jsonb_each(p -> 'layer_map') e
                  where e.key <> all (v_std) or jsonb_typeof(e.value) <> 'string' or (e.value #>> '{}') !~ '^[A-Za-z0-9_$-]{1,64}$')) then
    raise exception 'upsert_drafting_profile: layer_map keys must be standard layers, values ^[A-Za-z0-9_$-]{1,64}$' using errcode = '22023';
  end if;
  if nullif(p ->> 'logo_storage_path', '') is not null and not nomad_arch.valid_user_path(v_org, 'drafting-logo', p ->> 'logo_storage_path') then
    raise exception 'upsert_drafting_profile: logo must be own drafting-logo upload' using errcode = '23514';
  end if;
  select * into v_row from nomad_arch.drafting_profiles d where d.organization_id = v_org for update;
  if not found then
    insert into nomad_arch.drafting_profiles (organization_id, office_name, architect_name, contact, logo_storage_path, layer_map,
                                              default_paper, default_text_height_mm, font_family, updated_by)
    values (v_org, coalesce(p ->> 'office_name', ''), nullif(p ->> 'architect_name', ''), nullif(p ->> 'contact', ''),
            nullif(p ->> 'logo_storage_path', ''), coalesce(p -> 'layer_map', '{}'::jsonb), coalesce(p ->> 'default_paper', 'A3'),
            coalesce((p ->> 'default_text_height_mm')::numeric, 2.5), coalesce(p ->> 'font_family', 'Noto Sans KR'), auth.uid())
    returning * into v_row;
  else
    update nomad_arch.drafting_profiles d set
      office_name            = case when p ? 'office_name' then coalesce(p ->> 'office_name', '') else d.office_name end,
      architect_name         = case when p ? 'architect_name' then nullif(p ->> 'architect_name', '') else d.architect_name end,
      contact                = case when p ? 'contact' then nullif(p ->> 'contact', '') else d.contact end,
      logo_storage_path      = case when p ? 'logo_storage_path' then nullif(p ->> 'logo_storage_path', '') else d.logo_storage_path end,
      layer_map              = case when p ? 'layer_map' then p -> 'layer_map' else d.layer_map end,
      default_paper          = case when p ? 'default_paper' then p ->> 'default_paper' else d.default_paper end,
      default_text_height_mm = case when p ? 'default_text_height_mm' then (p ->> 'default_text_height_mm')::numeric else d.default_text_height_mm end,
      font_family            = case when p ? 'font_family' then p ->> 'font_family' else d.font_family end,
      updated_by             = auth.uid()
    where d.organization_id = v_org
    returning * into v_row;
  end if;
  perform nomad_core.write_audit(v_org, 'arch.drafting_profile.update', 'drafting_profile', v_org::text, null,
                                 jsonb_build_object('keys', (select jsonb_agg(k) from jsonb_object_keys(p) k)));
  return v_row;
end;
$$;

-- 8-5. 클라우드 사본 저장(editor 이상). 조직은 경로 첫 폴더. 새 사본은 cloud_projects_max(AR040), 기존은 version 낙관적 동시성(AR041).
create function nomad_arch.save_cloud_project(p_local_id uuid, p_name text, p_storage_path text, p_expected_version integer)
returns table (id uuid, version integer)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare v_org uuid := nomad_arch_private.storage_org_id(coalesce(p_storage_path, '')); v_row nomad_arch.cloud_projects; v_count integer; v_max integer;
begin
  if v_org is null or p_local_id is null then
    raise exception 'save_cloud_project: storage path must start with organization id' using errcode = '23514';
  end if;
  if not nomad_core.is_service_caller() and coalesce(nomad_core.organization_role(v_org) not in ('owner', 'admin', 'editor'), true) then
    raise exception 'save_cloud_project: not a member' using errcode = '42501';
  end if;
  if not nomad_core.is_service_caller() and not nomad_arch.has_access(v_org) then
    raise exception 'save_cloud_project: no arch access' using errcode = '42501';
  end if;
  if p_storage_path !~ ('^' || v_org::text || '/arch/project_snapshot/' || p_local_id::text
                        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,8}$') then
    raise exception 'save_cloud_project: path must be <organization>/arch/project_snapshot/<local_id>/<uuid>.<ext>' using errcode = '23514';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 120 or p_expected_version is null or p_expected_version < 0 then
    raise exception 'save_cloud_project: invalid name or expected_version' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('arch:cloud:' || v_org::text, 0));
  select * into v_row from nomad_arch.cloud_projects c where c.organization_id = v_org and c.local_id = p_local_id for update;
  if not found then
    if p_expected_version <> 0 then
      raise exception 'save_cloud_project: version conflict (current 0)' using errcode = 'AR041';
    end if;
    v_max := nomad_arch.feature_int(nomad_arch.org_features(v_org), 'cloud_projects_max', 3);
    select count(*) into v_count from nomad_arch.cloud_projects c where c.organization_id = v_org;
    if v_count >= v_max then
      raise exception 'save_cloud_project: cloud copy limit % reached', v_max using errcode = 'AR040';
    end if;
    insert into nomad_arch.cloud_projects (organization_id, local_id, name, storage_path, version, created_by, updated_by)
    values (v_org, p_local_id, btrim(p_name), p_storage_path, 1, auth.uid(), auth.uid())
    returning * into v_row;
  else
    if v_row.version <> p_expected_version then
      raise exception 'save_cloud_project: version conflict (current %)', v_row.version using errcode = 'AR041';
    end if;
    update nomad_arch.cloud_projects c
       set name = btrim(p_name), storage_path = p_storage_path, version = c.version + 1, updated_by = auth.uid()
     where c.id = v_row.id
    returning * into v_row;
  end if;
  perform nomad_core.write_audit(v_org, 'arch.cloud_project.save', 'cloud_project', v_row.id::text, null, jsonb_build_object('version', v_row.version));
  return query select v_row.id, v_row.version;
end;
$$;

-- ---------- 9. RLS 와 grant. 사용자에게는 select 만(컬럼 단위), 쓰기 정책·쓰기 grant 없음. anon 표 grant 없음. ----------
do $$
declare t text;
begin
  foreach t in array array['runtime_config', 'license_skus', 'builds', 'rule_packs', 'rule_pack_changes', 'cost_catalogs', 'license_orders',
                           'licenses', 'license_activations', 'drafting_profiles', 'cloud_projects', 'renders', 'reviews', 'intake_runs',
                           'proposals', 'site_lookups'] loop
    execute format('alter table nomad_arch.%I enable row level security', t);
    execute format('revoke all on nomad_arch.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on nomad_arch.%I to service_role', t);
  end loop;
end $$;
grant usage, select on sequence nomad_arch.site_lookups_id_seq to service_role;

-- 주문·라이선스·기기: 같은 조직 멤버(플랜과 무관 — 구매 기록은 잠기지 않는다). 해시 컬럼은 주지 않는다.
grant select (id, organization_id, kind, sku_code, amount_krw, status, paid_at, status_changed_at, created_at, updated_at)
  on nomad_arch.license_orders to authenticated;
create policy license_orders_select on nomad_arch.license_orders for select to authenticated
  using (nomad_arch.is_member(organization_id));
grant select (id, organization_id, sku_code, serial_last5, status, purchased_at, updates_until, max_activations, status_changed_at, created_at, updated_at)
  on nomad_arch.licenses to authenticated;
create policy licenses_select on nomad_arch.licenses for select to authenticated
  using (nomad_arch.is_member(organization_id));
grant select (id, organization_id, license_id, source, device_label, activated_at, last_seen_at, deactivated_at, deactivation_kind, updated_at)
  on nomad_arch.license_activations to authenticated;
create policy license_activations_select on nomad_arch.license_activations for select to authenticated
  using (nomad_arch.is_member(organization_id));

-- 규칙 팩 메타데이터·개정 제목: Arch 접근 사용자. storage_path 제외(다운로드는 서명 URL).
grant select (id, version, status, basis_date, summary, sha256, signature, kid, bytes, published_at, withdrawn_at)
  on nomad_arch.rule_packs to authenticated;
create policy rule_packs_select on nomad_arch.rule_packs for select to authenticated
  using (status in ('published', 'withdrawn') and nomad_arch.has_arch_access());
grant select on nomad_arch.rule_pack_changes to authenticated;
create policy rule_pack_changes_select on nomad_arch.rule_pack_changes for select to authenticated
  using (nomad_arch.has_arch_access()
         and exists (select 1 from nomad_arch.rule_packs p where p.id = rule_pack_id and p.status = 'published'));

-- 표제란·클라우드 사본·AI 실행: 접근 가능한 조직 멤버(구독 또는 라이선스)
grant select on nomad_arch.drafting_profiles, nomad_arch.cloud_projects, nomad_arch.renders, nomad_arch.reviews,
  nomad_arch.intake_runs, nomad_arch.proposals to authenticated;
do $$
declare t text;
begin
  foreach t in array array['drafting_profiles', 'cloud_projects', 'renders', 'reviews', 'intake_runs', 'proposals'] loop
    execute format('create policy %1$s_select on nomad_arch.%1$I for select to authenticated using (nomad_arch.has_access(organization_id))', t);
  end loop;
end $$;
-- runtime_config, license_skus, builds, cost_catalogs, site_lookups: 사용자 grant·정책 없음(service_role 과 RPC 만)

-- ---------- 10. 함수 실행 권한 ----------
revoke execute on all functions in schema nomad_arch from public, anon, authenticated;
revoke execute on all functions in schema nomad_arch_private from public, anon, authenticated;
grant execute on all functions in schema nomad_arch to service_role;
grant execute on function nomad_arch.public_license_skus() to anon, authenticated;
grant execute on function
  nomad_arch.is_member(uuid), nomad_arch.has_access(uuid), nomad_arch.has_arch_access(),
  nomad_arch.feature_int(jsonb, text, integer), nomad_arch.feature_bool(jsonb, text, boolean), nomad_arch.kst_today(),
  nomad_arch.valid_user_path(uuid, text, text), nomad_arch.org_features(uuid),
  nomad_arch.deactivate_activation(uuid), nomad_arch.eligible_rule_packs(uuid), nomad_arch.latest_cost_catalog(uuid),
  nomad_arch.upsert_drafting_profile(jsonb, uuid), nomad_arch.save_cloud_project(uuid, text, text, integer)
to authenticated;

-- ---------- 11. Storage (제품 전용 비공개 버킷). 정책 없음 = 사용자 직접 접근 없음, 서버 서명 URL 만. ----------
--     렌더 결과·제안서 PDF·상담 녹음은 코어 공용 버킷 계약(org-files·exports·voice-audio) — 이 저장소에 아직 없음(existing.md).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('arch-releases', 'arch-releases', false, 524288000, null),
  ('arch-user',     'arch-user',     false, 104857600, null)
on conflict (id) do nothing;

commit;
