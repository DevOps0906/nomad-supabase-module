-- nomad-commerce 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/1400_commerce.sql 1~19장(소싱·상품DB·AI 상세페이지·마켓 업로드·내보내기·금지어)
-- 결정 D9: platform-docs 기준으로 새로 작성(청사진 20261115000107·20261116000107·20261117000107_commerce.sql 은 참고만, 같은 스키마 이름이라 둘 중 하나만 적용).
-- core.organizations→nomad_core.organizations, org_members(member→editor)→nomad_core.organization_role, has_entitlement·plans.features→nomad_core.has_feature·org_has_feature·org_plan_limit,
-- core.jobs·credit_ledger(bigint)→nomad_core.jobs·credit_ledger(uuid), core.encrypted_credentials→nomad_core.provider_credentials, core.write_audit→nomad_core.write_audit.
-- 결정 D1: 결제 테이블 없음. commerce 결제는 구독(A/B/C)·크레딧팩(addon)뿐이라 제품 주문 표도 두지 않는다(계약: products/commerce/existing.md "결제 연동 계약").
-- 플랜: A = 원본 pro(enterprise 는 미판매, 한도만 다름), B = starter, C = free(구독이 끊기면 C = free 기능만 남는다).
-- 수치(가격·크레딧 단가·플랜 한도)는 시드하지 않는다: 한도는 plan_limits 키(existing.md), 단가는 서버 상수. 금지어 사전(문자열)은 원본 19장 그대로 시드. AI 라우팅은 org/0002_ai.sql.
-- SQLSTATE: CM001 상태 전이 · CM002 상품 수 · CM003 마켓 계정 슬롯 · CM004 compliance FAIL · CM005 WARN 미확인 · CM006 마켓 계정·자격 무효
--           CM007 플랜 미허용 · CM008 상세페이지 미완료 · CM009 확인할 WARN 없음 · CM010 코어 참조(잡·원장·상품) 조직 불일치 · CM011 업로드 대상 변경 · 55000 잡 실패·취소(환불됨) 뒤 결과 저장
-- 되돌림: drop schema nomad_commerce cascade; drop schema nomad_commerce_private cascade;
--   delete from nomad_core.plan_features/features where product_code = 'commerce' and feature_code/code in (아래 12개); (api_providers 마켓 8행은 남겨도 무해)
begin;

create schema nomad_commerce;
create schema nomad_commerce_private;
revoke all on schema nomad_commerce, nomad_commerce_private from public, anon, authenticated;
-- 공개(anon) RPC 가 없으므로 anon 에는 스키마 usage 도 주지 않는다(D8).
grant usage on schema nomad_commerce to authenticated, service_role;
alter default privileges in schema nomad_commerce revoke execute on functions from public;
alter default privileges in schema nomad_commerce_private revoke execute on functions from public;
comment on schema nomad_commerce is 'NOMAD Commerce: 소싱, 상품DB, AI 상세페이지, 마켓 업로드';

insert into nomad_core.products (code, name) values ('commerce', 'NOMAD Commerce') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values ('commerce', 'A', 'A'), ('commerce', 'B', 'B'), ('commerce', 'C', 'C')
  on conflict do nothing;
-- 원본 plans.features 불리언·배열 키 → 기능 이용권. market_api(text[])는 마켓별 기능 market_api_<market>, detail_types·slot_sets 는 확장분만 기능으로.
insert into nomad_core.features (product_code, code, name) values
  ('commerce', 'commerce', '커머스 작업 공간(상품DB·상세페이지·마켓 등록)'),
  ('commerce', 'zip_export', 'ZIP 이미지 내보내기'),
  ('commerce', 'ai_chat', '셀러 어시스턴트 채팅'),
  ('commerce', 'market_api_coupang', '쿠팡 API 업로드'),
  ('commerce', 'market_api_smartstore', '스마트스토어 API 업로드'),
  ('commerce', 'excel_export', '엑셀(플레이오토 호환) 내보내기'),
  ('commerce', 'extra_detail_types', '상세페이지 유형 확장(정보형·감성형)'),
  ('commerce', 'slot_set_15', '15슬롯 상세페이지'),
  ('commerce', 'url_benchmark', 'URL 벤치마킹'),
  ('commerce', 'voice_input', '상품 설명 음성 입력'),
  ('commerce', 'voice_chat', '음성 대화'),
  ('commerce', 'shorts_narration', '쇼츠 내레이션 음성')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'commerce', p, f from unnest(array['A', 'B', 'C']) p,
  unnest(array['commerce', 'zip_export', 'ai_chat', 'market_api_coupang', 'market_api_smartstore']) f
union all
select 'commerce', p, f from unnest(array['A', 'B']) p,
  unnest(array['excel_export', 'extra_detail_types', 'slot_set_15', 'url_benchmark', 'voice_input', 'voice_chat', 'shorts_narration']) f
on conflict do nothing;
-- plan_limits 키(시드 없음, 괄호 = 키가 없을 때 원본 코드 기본값): products(30 = 원본 free, 팀장 결정) · market_slots(1) · concurrency(1) · ai_chat_turns_per_day(20) · image_quality_level(0=draft)

-- 마켓 API 자격(provider_credentials.provider_code). 표시 이름만, 비밀은 vault(core set 함수).
insert into nomad_core.api_providers (code, name) values
  ('coupang', '쿠팡 Wing Open API'), ('smartstore', '네이버 커머스 API'), ('gmarket', 'G마켓 ESM'), ('auction', '옥션 ESM'),
  ('street11', '11번가 Open API'), ('lotteon', '롯데온 API'), ('cafe24', '카페24 API'), ('imweb', '아임웹 API')
on conflict do nothing;

-- ---------- 1. 표 ----------
create table nomad_commerce.import_batches (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  source_type     text not null check (source_type in ('excel', 'amazon')),
  supplier        text not null check (supplier in ('amazon', 'ownerclan', 'domeggook', 'onchannel', 'amazon_csv', 'custom')),
  file_path       text,
  column_mapping  jsonb not null default '{}'::jsonb,
  status          text not null default 'uploaded' check (status in ('uploaded', 'parsing', 'completed', 'failed')),
  total_rows      integer not null default 0 check (total_rows >= 0),
  imported_rows   integer not null default 0 check (imported_rows >= 0),
  skipped_rows    integer not null default 0 check (skipped_rows >= 0),
  failed_rows     integer not null default 0 check (failed_rows >= 0),
  errors          jsonb not null default '[]'::jsonb,
  job_id          uuid references nomad_core.jobs(id) on delete set null,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  finished_at     timestamptz,
  unique (organization_id, id)
);
create index import_batches_org_created_idx on nomad_commerce.import_batches (organization_id, created_at desc);
comment on table nomad_commerce.import_batches is '엑셀·아마존 가져오기 실행 단위(서버 전용 쓰기).';

create table nomad_commerce.products (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  source_type        text not null default 'manual' check (source_type in ('manual', 'excel', 'amazon', 'url_benchmark')),
  source_supplier    text check (source_supplier is null or source_supplier in ('amazon', 'ownerclan', 'domeggook', 'onchannel', 'amazon_csv', 'custom')),
  source_ref         text,
  source_url         text,
  import_batch_id    uuid,
  title              text not null check (char_length(title) between 1 and 300),
  title_original     text,
  title_optimized    text check (title_optimized is null or char_length(title_optimized) <= 100),
  brand              text,
  manufacturer       text,
  origin_country     text,
  model_code         text,
  category_path      text,
  is_health_food     boolean not null default false,
  health_food_status text not null default 'not_applicable' check (health_food_status in ('not_applicable', 'certified_hff', 'general_food', 'unknown')),
  is_overseas        boolean not null default false,
  -- 외화 원가(USD 등 소수 단위)라 원본 numeric 유지. 원화 금액은 아래 *_krw 정수.
  source_price       numeric(12, 2) check (source_price is null or source_price >= 0),
  source_currency    text check (source_currency is null or source_currency in ('KRW', 'USD', 'CAD', 'EUR', 'JPY', 'CNY')),
  sell_price_krw     integer check (sell_price_krw is null or (sell_price_krw >= 0 and sell_price_krw % 10 = 0)),
  list_price_krw     integer check (list_price_krw is null or list_price_krw >= 0),
  stock              integer not null default 999 check (stock >= 0),
  images             jsonb not null default '[]'::jsonb check (jsonb_typeof(images) = 'array'),
  attributes         jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes) = 'object'),
  tags               text[] not null default '{}',
  banned_words_found text[] not null default '{}',
  status             text not null default 'active' check (status in ('active', 'archived')),
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  unique (organization_id, id),
  constraint products_import_batch_fk foreign key (organization_id, import_batch_id)
    references nomad_commerce.import_batches (organization_id, id) on delete set null (import_batch_id)
);
create index products_org_created_idx on nomad_commerce.products (organization_id, created_at desc) where deleted_at is null;
create index products_org_updated_idx on nomad_commerce.products (organization_id, updated_at);
create unique index products_source_uniq on nomad_commerce.products (organization_id, source_supplier, source_ref)
  where source_ref is not null and deleted_at is null;
comment on table nomad_commerce.products is '상품DB(사용자 콘텐츠, 상품 수 한도 트리거, 소프트 삭제).';

create table nomad_commerce.detail_pages (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  product_id           uuid not null,
  version              integer not null default 1 check (version >= 1),
  page_type            text not null check (page_type in ('persuasive', 'informative', 'emotional', 'social_proof', 'story', 'comparison', 'promotion', 'bundle')),
  slot_set             smallint not null default 10 check (slot_set in (10, 15)),
  slots                text[] not null check (
                         slots <@ array['T-1','T-2','T-3','T-4','T-5','D-1','D-2','D-3','D-4','D-5','D-6','D-7','D-8','D-9','D-10','L-1','L-2','L-3']
                         and slots @> array['T-1','L-3'] and cardinality(slots) between 3 and 18),
  -- 10슬롯 세트에 슬롯을 더 넣어 15슬롯 잠금을 우회하지 못하게(보안 리뷰 반영)
  constraint detail_pages_slots_within_set check (cardinality(slots) <= slot_set),
  template             text not null default 'simple' check (template in ('simple', 'health', 'overseas')),
  target_markets       text[] not null default array['coupang', 'smartstore']
                       check (target_markets <@ array['coupang', 'smartstore', 'wadiz', 'street11', 'gmarket', 'auction', 'lotteon', 'cafe24', 'imweb']),
  options              jsonb not null default '{}'::jsonb,
  status               text not null default 'waiting' check (status in ('waiting', 'queued', 'generating', 'ready', 'failed', 'canceled', 'archived')),
  progress             integer not null default 0 check (progress between 0 and 100),
  current_phase        text check (current_phase is null or current_phase in ('prepare', 'storyline', 'copy', 'images', 'compose', 'verify', 'convert', 'assemble')),
  credits_charged      integer not null default 0 check (credits_charged >= 0),
  credit_ledger_id     uuid references nomad_core.credit_ledger(id),
  job_id               uuid references nomad_core.jobs(id) on delete set null,
  request_id           uuid,
  copy                 jsonb not null default '{}'::jsonb,
  html_content         text,
  geo_jsonld           jsonb,
  compliance_verdict   text check (compliance_verdict is null or compliance_verdict in ('pass', 'warn', 'fail')),
  compliance_issues    jsonb not null default '[]'::jsonb,
  warn_acknowledged_at timestamptz,
  warn_acknowledged_by uuid,
  cancel_requested_at  timestamptz,
  error_code           text,
  error_message        text,
  created_by           uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  started_at           timestamptz,
  finished_at          timestamptz,
  unique (organization_id, id),
  constraint detail_pages_product_fk foreign key (organization_id, product_id)
    references nomad_commerce.products (organization_id, id) on delete cascade
);
create index detail_pages_org_created_idx on nomad_commerce.detail_pages (organization_id, created_at desc);
create index detail_pages_product_idx on nomad_commerce.detail_pages (product_id, version desc);
create index detail_pages_waiting_idx on nomad_commerce.detail_pages (organization_id, created_at) where status = 'waiting';
-- 멱등 키는 조직 범위(다른 조직의 키로 존재 여부를 떠보거나 막지 못하게)
create unique index detail_pages_request_uniq on nomad_commerce.detail_pages (organization_id, request_id) where request_id is not null;
comment on table nomad_commerce.detail_pages is 'AI 상세페이지(서버 전용 쓰기, 사용자는 WARN 확인 RPC 만).';

create table nomad_commerce.detail_page_slots (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  detail_page_id      uuid not null,
  slot_code           text not null check (slot_code in ('T-1','T-2','T-3','T-4','T-5','D-1','D-2','D-3','D-4','D-5','D-6','D-7','D-8','D-9','D-10','L-1','L-2','L-3')),
  position            smallint not null check (position between 1 and 18),
  render_method       text not null check (render_method in ('cutout', 'ai_scene', 'infographic', 'legal')),
  status              text not null default 'pending' check (status in ('pending', 'generating', 'completed', 'failed', 'skipped')),
  copy_ko             text,
  image_prompt_en     text,
  template_data       jsonb not null default '{}'::jsonb,
  master_path         text,
  provider_request_id text unique,
  model               text,
  attempts            integer not null default 0 check (attempts >= 0),
  error_message       text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  completed_at        timestamptz,
  unique (detail_page_id, slot_code),
  constraint detail_page_slots_page_fk foreign key (organization_id, detail_page_id)
    references nomad_commerce.detail_pages (organization_id, id) on delete cascade
);
create index detail_page_slots_page_idx on nomad_commerce.detail_page_slots (detail_page_id, position);
create index detail_page_slots_org_idx on nomad_commerce.detail_page_slots (organization_id);
comment on table nomad_commerce.detail_page_slots is '상세페이지 슬롯별 생성 상태(서버 전용 쓰기, Realtime).';

create table nomad_commerce.market_images (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  detail_page_id  uuid not null,
  slot_code       text not null,
  market          text not null check (market in ('coupang', 'smartstore', 'wadiz', 'street11', 'gmarket', 'auction', 'lotteon', 'cafe24', 'imweb')),
  kind            text not null check (kind in ('thumbnail', 'detail')),
  part_no         smallint not null default 1 check (part_no >= 1),
  storage_path    text not null,
  width           integer check (width is null or width > 0),
  height          integer check (height is null or height > 0),
  bytes           integer check (bytes is null or bytes > 0),
  format          text check (format is null or format in ('jpeg', 'png', 'gif', 'webp')),
  validation      jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  unique (detail_page_id, market, slot_code, kind, part_no),
  constraint market_images_page_fk foreign key (organization_id, detail_page_id)
    references nomad_commerce.detail_pages (organization_id, id) on delete cascade
);
create index market_images_org_idx on nomad_commerce.market_images (organization_id);
comment on table nomad_commerce.market_images is '마켓별 변환 이미지(서버 전용 쓰기).';

create table nomad_commerce.market_accounts (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  market           text not null check (market in ('coupang', 'smartstore', 'gmarket', 'auction', 'street11', 'lotteon', 'cafe24', 'imweb')),
  slot_no          smallint not null check (slot_no >= 1),
  label            text not null check (char_length(label) between 1 and 40),
  credential_id    uuid references nomad_core.provider_credentials(id) on delete set null,
  vendor_id        text,
  status           text not null default 'active' check (status in ('active', 'disabled', 'error')),
  last_verified_at timestamptz,
  last_error       text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, market, slot_no)
);
comment on table nomad_commerce.market_accounts is '마켓 다계정 슬롯(서버 전용 쓰기). 키는 nomad_core.provider_credentials(vault)에만.';

create table nomad_commerce.shipping_templates (
  id                       uuid primary key default gen_random_uuid(),
  organization_id          uuid not null references nomad_core.organizations(id) on delete cascade,
  name                     text not null check (char_length(name) between 1 and 60),
  template_type            text not null default 'custom' check (template_type in ('overseas_purchase', 'domestic_dropship', 'custom')),
  shipping                 jsonb not null default '{}'::jsonb check (jsonb_typeof(shipping) = 'object'),
  dispatch_days            smallint not null default 3 check (dispatch_days between 1 and 30),
  return_window_days       smallint not null default 7 check (return_window_days between 7 and 90),
  exchange_allowed         boolean not null default true,
  return_fee_krw           integer check (return_fee_krw is null or return_fee_krw >= 0),
  initial_shipping_fee_krw integer check (initial_shipping_fee_krw is null or initial_shipping_fee_krw >= 0),
  restriction_codes        text[] not null default '{}' check (restriction_codes <@ array['buyer_damage', 'used_or_consumed', 'time_lapse_resale', 'copyable_opened']),
  return_address           jsonb not null default '{}'::jsonb,
  contact_phone            text,
  is_default               boolean not null default false,
  created_by               uuid,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (organization_id, id)
);
create unique index shipping_templates_one_default_idx on nomad_commerce.shipping_templates (organization_id) where is_default;
create index shipping_templates_org_updated_idx on nomad_commerce.shipping_templates (organization_id, updated_at);
comment on table nomad_commerce.shipping_templates is '배송·반품 템플릿(사용자 콘텐츠). 청약철회 7일 미만·자유 제한 사유는 CHECK 로 거부.';

create table nomad_commerce.listing_drafts (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  product_id           uuid not null,
  detail_page_id       uuid,
  market               text not null check (market in ('coupang', 'smartstore', 'gmarket', 'auction', 'street11', 'lotteon', 'cafe24', 'imweb')),
  market_account_id    uuid,
  shipping_template_id uuid,
  category_code        text,
  category_path        text,
  display_name         text check (display_name is null or char_length(display_name) <= 100),
  form_data            jsonb not null default '{}'::jsonb check (jsonb_typeof(form_data) = 'object'),
  notice_info          jsonb not null default '{}'::jsonb check (jsonb_typeof(notice_info) = 'object'),
  completeness_pct     smallint not null default 0 check (completeness_pct between 0 and 100),
  missing_fields       text[] not null default '{}',
  status               text not null default 'draft' check (status in ('draft', 'ready', 'archived')),
  created_by           uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, id),
  constraint listing_drafts_product_fk foreign key (organization_id, product_id)
    references nomad_commerce.products (organization_id, id) on delete cascade,
  constraint listing_drafts_detail_page_fk foreign key (organization_id, detail_page_id)
    references nomad_commerce.detail_pages (organization_id, id) on delete set null (detail_page_id),
  constraint listing_drafts_account_fk foreign key (organization_id, market_account_id)
    references nomad_commerce.market_accounts (organization_id, id) on delete set null (market_account_id),
  constraint listing_drafts_template_fk foreign key (organization_id, shipping_template_id)
    references nomad_commerce.shipping_templates (organization_id, id) on delete set null (shipping_template_id)
);
create index listing_drafts_org_updated_idx on nomad_commerce.listing_drafts (organization_id, updated_at desc);
create unique index listing_drafts_product_account_uniq on nomad_commerce.listing_drafts (product_id, market_account_id)
  where market_account_id is not null and status <> 'archived';
comment on table nomad_commerce.listing_drafts is '마켓 등록 폼(사용자는 콘텐츠 컬럼만, status·completeness 는 서버).';

create table nomad_commerce.market_uploads (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  listing_draft_id  uuid,
  product_id        uuid,
  detail_page_id    uuid,
  market            text not null check (market in ('coupang', 'smartstore', 'gmarket', 'auction', 'street11', 'lotteon', 'cafe24', 'imweb')),
  market_account_id uuid,
  job_id            uuid references nomad_core.jobs(id) on delete set null,
  status            text not null default 'queued' check (status in ('queued', 'validating', 'uploading', 'submitted', 'approved', 'rejected', 'failed', 'canceled')),
  market_product_id text,
  market_url        text,
  request_snapshot  jsonb not null default '{}'::jsonb,
  response_summary  jsonb not null default '{}'::jsonb,
  error_code        text,
  error_message     text,
  attempts          integer not null default 0 check (attempts >= 0),
  idempotency_key   text,
  submitted_at      timestamptz,
  decided_at        timestamptz,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint market_uploads_draft_fk foreign key (organization_id, listing_draft_id)
    references nomad_commerce.listing_drafts (organization_id, id) on delete set null (listing_draft_id),
  constraint market_uploads_product_fk foreign key (organization_id, product_id)
    references nomad_commerce.products (organization_id, id) on delete set null (product_id),
  constraint market_uploads_detail_page_fk foreign key (organization_id, detail_page_id)
    references nomad_commerce.detail_pages (organization_id, id) on delete set null (detail_page_id),
  constraint market_uploads_account_fk foreign key (organization_id, market_account_id)
    references nomad_commerce.market_accounts (organization_id, id) on delete set null (market_account_id)
);
create index market_uploads_org_created_idx on nomad_commerce.market_uploads (organization_id, created_at desc);
create unique index market_uploads_idempotency_uniq on nomad_commerce.market_uploads (organization_id, idempotency_key) where idempotency_key is not null;
create index market_uploads_submitted_idx on nomad_commerce.market_uploads (updated_at) where status = 'submitted';
create unique index market_uploads_external_uniq on nomad_commerce.market_uploads (market_account_id, market_product_id)
  where market_product_id is not null;
comment on table nomad_commerce.market_uploads is '마켓 API 업로드 이력(서버 전용 쓰기, 상태 전이 + 게이트 트리거, 멱등 키).';

create table nomad_commerce.export_files (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  kind            text not null check (kind in ('excel_playauto', 'zip_images')),
  market          text not null default 'all' check (market in ('coupang', 'smartstore', 'wadiz', 'street11', 'all')),
  product_ids     uuid[] not null default '{}',
  detail_page_ids uuid[] not null default '{}',
  status          text not null default 'queued' check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled', 'expired')),
  storage_path    text,
  file_bytes      bigint check (file_bytes is null or file_bytes >= 0),
  row_count       integer,
  expires_at      timestamptz,
  job_id          uuid references nomad_core.jobs(id) on delete set null,
  error_message   text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint export_files_size_check check (cardinality(product_ids) <= 500 and cardinality(detail_page_ids) <= 500)
);
create index export_files_org_created_idx on nomad_commerce.export_files (organization_id, created_at desc);
create index export_files_expiry_idx on nomad_commerce.export_files (expires_at) where status = 'succeeded';
comment on table nomad_commerce.export_files is '엑셀(플레이오토 호환)·ZIP 내보내기(서버 전용 쓰기).';

create table nomad_commerce.banned_words (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references nomad_core.organizations(id) on delete cascade,
  word            text not null check (char_length(btrim(word)) between 1 and 50),
  category        text not null default 'general' check (category in ('health_food', 'cosmetics', 'medical', 'general')),
  match_mode      text not null default 'substring' check (match_mode in ('substring', 'token')),
  severity        text not null default 'fail' check (severity in ('fail', 'warn')),
  replacement     text,
  note            text,
  is_active       boolean not null default true,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index banned_words_global_uniq on nomad_commerce.banned_words (category, word) where organization_id is null;
create unique index banned_words_org_uniq on nomad_commerce.banned_words (organization_id, category, word) where organization_id is not null;
comment on table nomad_commerce.banned_words is '금지어 사전. organization_id null = 제품 기본(읽기 전용), 조직 행 = owner/admin 편집.';

create table nomad_commerce.exchange_rates (
  id         bigint generated always as identity primary key,
  currency   text not null check (currency in ('USD', 'CAD', 'EUR', 'JPY', 'CNY')),
  unit       integer not null default 1 check (unit in (1, 100)),
  rate_krw   numeric(14, 4) not null check (rate_krw > 0),
  source     text not null default 'koreaexim',
  rate_date  date not null,
  fetched_at timestamptz not null default now(),
  unique (currency, rate_date)
);
comment on table nomad_commerce.exchange_rates is '환율 캐시(한국수출입은행, 서버 쓰기·로그인 사용자 읽기). 환율은 금액이 아니라 비율이라 numeric.';

create table nomad_commerce.market_categories (
  market        text not null check (market in ('coupang', 'smartstore', 'gmarket', 'auction', 'street11', 'lotteon', 'cafe24', 'imweb')),
  category_code text not null,
  parent_code   text,
  name          text not null,
  path          text not null,
  depth         smallint not null default 1,
  is_leaf       boolean not null default false,
  notice_type   text,
  synced_at     timestamptz not null default now(),
  primary key (market, category_code)
);
comment on table nomad_commerce.market_categories is '마켓 카테고리 트리 캐시(서버 쓰기, 로그인 사용자 읽기).';

-- ---------- 2. 내부 함수(트리거) ----------
-- 상태 전이 표. 초기 상태는 from = ''. 원본 05_DATA_MODEL.md 3장과 같다.
create function nomad_commerce_private.transition_allowed(p_table text, p_from text, p_to text)
returns boolean language sql immutable set search_path = ''
as $$
  select (coalesce(p_from, '') || '>' || coalesce(p_to, '')) = any (
    case p_table
      when 'import_batches' then array['>uploaded', 'uploaded>parsing', 'uploaded>failed', 'parsing>completed', 'parsing>failed']
      when 'detail_pages' then array[
        '>waiting', 'waiting>queued', 'waiting>canceled', 'queued>generating', 'queued>canceled', 'queued>failed',
        'generating>ready', 'generating>failed', 'generating>canceled', 'ready>archived', 'archived>ready', 'failed>waiting']
      when 'detail_page_slots' then array[
        '>pending', 'pending>generating', 'pending>skipped', 'pending>failed',
        'generating>completed', 'generating>failed', 'failed>generating', 'completed>generating']
      when 'listing_drafts' then array['>draft', 'draft>ready', 'ready>draft', 'draft>archived', 'ready>archived', 'archived>draft']
      when 'market_uploads' then array[
        '>queued', 'queued>validating', 'queued>canceled', 'queued>failed', 'validating>uploading', 'validating>failed',
        'uploading>submitted', 'uploading>failed', 'submitted>approved', 'submitted>rejected', 'submitted>failed',
        'failed>queued', 'rejected>queued']
      when 'export_files' then array[
        '>queued', 'queued>running', 'queued>canceled', 'queued>failed', 'running>succeeded', 'running>failed', 'succeeded>expired']
      else array[]::text[]
    end);
$$;

create function nomad_commerce_private.status_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if not nomad_commerce_private.transition_allowed(tg_table_name, '', new.status) then
      raise exception '%: invalid initial status %', tg_table_name, new.status using errcode = 'CM001';
    end if;
  elsif new.status is distinct from old.status
        and not nomad_commerce_private.transition_allowed(tg_table_name, old.status, new.status) then
    raise exception '%: invalid transition % -> %', tg_table_name, old.status, new.status using errcode = 'CM001';
  end if;
  return new;
end;
$$;

-- 사용자 세션이 만든 행의 created_by 를 auth.uid() 로 고정.
create function nomad_commerce_private.stamp_creator() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    new.created_by := auth.uid();
  end if;
  return new;
end;
$$;

-- 소프트 삭제 시각은 DB 가 정한다(과거·미래 시각 금지). 이미 삭제된 행의 삭제 시각은 바꾸지 않는다. 복원(null)은 허용.
create function nomad_commerce_private.force_deleted_at() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.deleted_at is not null then
    if tg_op = 'UPDATE' and old.deleted_at is not null then
      new.deleted_at := old.deleted_at;
    else
      new.deleted_at := now();
    end if;
  end if;
  return new;
end;
$$;

-- 코어 참조(잡·크레딧 원장)는 같은 조직·commerce 제품이어야 한다.
create function nomad_commerce_private.check_core_refs() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v jsonb := to_jsonb(new);
begin
  if v ->> 'job_id' is not null and not exists (
       select 1 from nomad_core.jobs j
       where j.id = (v ->> 'job_id')::uuid and j.organization_id = new.organization_id and j.product_code = 'commerce') then
    raise exception '%: job belongs to another organization or product', tg_table_name using errcode = 'CM010';
  end if;
  if v ->> 'credit_ledger_id' is not null and not exists (
       select 1 from nomad_core.credit_ledger l
       where l.id = (v ->> 'credit_ledger_id')::uuid and l.organization_id = new.organization_id
         and coalesce(l.product_code, 'commerce') = 'commerce') then
    raise exception '%: credit entry belongs to another organization or product', tg_table_name using errcode = 'CM010';
  end if;
  return new;
end;
$$;

-- 결과 전달(상세페이지 ready · 가져오기 completed): 연결된 잡이 환불됨(failed·canceled 이면서 refund_on_failure)이면 거부,
-- 아니면 core mark_job_delivered(이후 잡이 실패해도 환불하지 않음). 이미 전달된 잡(refund_on_failure false)은 archived → ready 복원 허용.
-- core 표는 직접 쓰지 않는다. 인자 = 결과 상태.
create function nomad_commerce_private.guard_job_delivery() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_job uuid := (to_jsonb(new) ->> 'job_id')::uuid; v_status text; v_refund boolean;
begin
  if new.status is distinct from tg_argv[0] or (tg_op = 'UPDATE' and old.status is not distinct from new.status) or v_job is null then
    return new;
  end if;
  select j.status, j.refund_on_failure into v_status, v_refund from nomad_core.jobs j where j.id = v_job for update;
  if v_status in ('failed', 'canceled') and v_refund then
    raise exception '%: job is % (credits already refunded)', tg_table_name, v_status using errcode = '55000';
  end if;
  perform nomad_core.mark_job_delivered(v_job);
  return new;
end;
$$;

-- 상품 수 한도(plan_limits products, 키 없으면 원본 free 값 30 — 팀장 결정 2026-11-14, docs 방식). 조직 단위 advisory lock 으로 직렬화.
create function nomad_commerce_private.products_enforce_quota() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_limit integer; v_count integer;
begin
  if tg_op = 'UPDATE' and not (old.deleted_at is not null and new.deleted_at is null) then
    return new;
  end if;
  if new.deleted_at is not null then
    return new;
  end if;
  if not nomad_core.org_has_feature(new.organization_id, 'commerce', 'commerce') then
    raise exception 'products: organization has no commerce access' using errcode = '42501';
  end if;
  v_limit := coalesce(nomad_core.org_plan_limit(new.organization_id, 'commerce', 'products'), 30);
  perform pg_advisory_xact_lock(hashtext('commerce:products:' || new.organization_id::text));
  select count(*) into v_count from nomad_commerce.products p
  where p.organization_id = new.organization_id and p.deleted_at is null and p.id <> new.id;
  if v_count >= v_limit then
    raise exception 'products quota exceeded (%/%)', v_count, v_limit using errcode = 'CM002';
  end if;
  return new;
end;
$$;

-- 마켓 계정: 자격은 같은 조직·같은 마켓 제공자·미폐기 + 활성 슬롯 한도(plan_limits market_slots, 기본 1).
create function nomad_commerce_private.market_accounts_enforce() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_limit integer; v_count integer; v_cred nomad_core.provider_credentials;
begin
  if new.credential_id is not null
     and (tg_op = 'INSERT' or new.credential_id is distinct from old.credential_id or (new.status = 'active' and old.status <> 'active')) then
    select * into v_cred from nomad_core.provider_credentials c where c.id = new.credential_id;
    if v_cred.id is null or v_cred.organization_id <> new.organization_id or v_cred.provider_code <> new.market
       or v_cred.revoked_at is not null then
      raise exception 'market_accounts: credential is not a live % key of this organization', new.market using errcode = 'CM006';
    end if;
  end if;
  if new.status <> 'active' or (tg_op = 'UPDATE' and old.status = 'active') then
    return new;
  end if;
  v_limit := coalesce(nomad_core.org_plan_limit(new.organization_id, 'commerce', 'market_slots'), 1);
  perform pg_advisory_xact_lock(hashtext('commerce:market_slots:' || new.organization_id::text));
  select count(*) into v_count from nomad_commerce.market_accounts a
  where a.organization_id = new.organization_id and a.status = 'active' and a.id <> new.id;
  if v_count >= v_limit then
    raise exception 'market slot quota exceeded (%/%)', v_count, v_limit using errcode = 'CM003';
  end if;
  return new;
end;
$$;

-- 상세페이지 플랜 게이트(원본은 Route Handler 403 — 구독이 끊긴 뒤 기존 실패 행 재시도까지 막으려고 DB 에 추가).
-- 생성(insert)·재시도(failed → waiting)·세트·유형·슬롯 변경(상태 무관) 때: 15슬롯 = slot_set_15, 설득형 외 유형 = extra_detail_types.
create function nomad_commerce_private.detail_pages_gate() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and not (old.status = 'failed' and new.status = 'waiting')
     and new.slot_set is not distinct from old.slot_set and new.page_type is not distinct from old.page_type
     and new.slots is not distinct from old.slots then
    return new;
  end if;
  if not nomad_core.org_has_feature(new.organization_id, 'commerce', 'commerce') then
    raise exception 'detail_pages: organization has no commerce access' using errcode = '42501';
  end if;
  if new.slot_set = 15 and not nomad_core.org_has_feature(new.organization_id, 'commerce', 'slot_set_15') then
    raise exception 'detail_pages: plan does not allow 15 slots' using errcode = 'CM007';
  end if;
  if new.page_type <> 'persuasive' and not nomad_core.org_has_feature(new.organization_id, 'commerce', 'extra_detail_types') then
    raise exception 'detail_pages: plan does not allow page type %', new.page_type using errcode = 'CM007';
  end if;
  return new;
end;
$$;

-- 업로드 게이트: 등록(insert)과 재시도(failed·rejected → queued) 때마다 계정·자격(사용 시점 재확인)·플랜·상세페이지 검사.
create function nomad_commerce_private.market_uploads_gate() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_acc nomad_commerce.market_accounts; v_page nomad_commerce.detail_pages;
begin
  if tg_op = 'UPDATE' and not (new.status = 'queued' and old.status <> 'queued') then
    return new;
  end if;
  select * into v_acc from nomad_commerce.market_accounts a where a.id = new.market_account_id;
  if v_acc.id is null or v_acc.organization_id <> new.organization_id or v_acc.market <> new.market
     or v_acc.status <> 'active' or v_acc.credential_id is null
     or not exists (select 1 from nomad_core.provider_credentials c
                    where c.id = v_acc.credential_id and c.organization_id = new.organization_id
                      and c.provider_code = new.market and c.revoked_at is null) then
    raise exception 'market_uploads: market account is not usable' using errcode = 'CM006';
  end if;
  if not nomad_core.org_has_feature(new.organization_id, 'commerce', 'market_api_' || new.market) then
    raise exception 'market_uploads: plan does not allow % api upload', new.market using errcode = 'CM007';
  end if;
  -- 상세페이지 없는 업로드는 compliance 판정을 건너뛰므로 거부(팀장 결정)
  if new.detail_page_id is null then
    raise exception 'market_uploads: detail page required' using errcode = 'CM008';
  else
    select * into v_page from nomad_commerce.detail_pages d where d.id = new.detail_page_id;
    if v_page.id is null or v_page.status <> 'ready' then
      raise exception 'market_uploads: detail page is not ready' using errcode = 'CM008';
    end if;
    if coalesce(v_page.compliance_verdict, 'fail') = 'fail' then
      raise exception 'market_uploads: compliance verdict fail or missing' using errcode = 'CM004';
    end if;
    if v_page.compliance_verdict = 'warn' and v_page.warn_acknowledged_at is null then
      raise exception 'market_uploads: compliance warning not acknowledged' using errcode = 'CM005';
    end if;
  end if;
  return new;
end;
$$;

-- 업로드 대상(마켓·계정·상세페이지)은 등록 뒤 바꿀 수 없다(게이트 우회 방지). FK on delete set null(→ null)만 허용 — null 이면 재시도 게이트가 거부.
create function nomad_commerce_private.market_uploads_target_immutable() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.market is distinct from old.market
     or (new.market_account_id is distinct from old.market_account_id and new.market_account_id is not null)
     or (new.detail_page_id is distinct from old.detail_page_id and new.detail_page_id is not null) then
    raise exception 'market_uploads: upload target cannot change' using errcode = 'CM011';
  end if;
  return new;
end;
$$;

-- compliance 판정·이슈가 바뀌면 WARN 확인을 초기화(새 판정은 다시 확인해야 업로드 가능).
create function nomad_commerce_private.reset_warn_ack() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.compliance_verdict is distinct from old.compliance_verdict or new.compliance_issues is distinct from old.compliance_issues then
    new.warn_acknowledged_at := null;
    new.warn_acknowledged_by := null;
  end if;
  return new;
end;
$$;

-- 조직 금지어 행은 제품 기본 사전의 활성 FAIL 단어를 낮출 수 없다(같은 단어면 severity fail·is_active true 강제).
create function nomad_commerce_private.banned_words_floor() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.organization_id is not null and exists (
       select 1 from nomad_commerce.banned_words g
       where g.organization_id is null and g.word = btrim(new.word) and g.severity = 'fail' and g.is_active) then
    new.severity := 'fail';
    new.is_active := true;
  end if;
  return new;
end;
$$;

-- 내보내기 게이트: 플랜(excel_export·zip_export) + 대상 상품·상세페이지가 같은 조직(배열이라 FK 없음).
create function nomad_commerce_private.export_files_gate() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.kind = 'excel_playauto' and not nomad_core.org_has_feature(new.organization_id, 'commerce', 'excel_export') then
    raise exception 'export_files: plan does not allow excel export' using errcode = 'CM007';
  end if;
  if new.kind = 'zip_images' and not nomad_core.org_has_feature(new.organization_id, 'commerce', 'zip_export') then
    raise exception 'export_files: plan does not allow zip export' using errcode = 'CM007';
  end if;
  if exists (select 1 from unnest(new.product_ids) x(id)
             where not exists (select 1 from nomad_commerce.products p where p.id = x.id and p.organization_id = new.organization_id))
     or exists (select 1 from unnest(new.detail_page_ids) x(id)
                where not exists (select 1 from nomad_commerce.detail_pages d where d.id = x.id and d.organization_id = new.organization_id)) then
    raise exception 'export_files: target belongs to another organization' using errcode = 'CM010';
  end if;
  return new;
end;
$$;

-- ---------- 3. 트리거 ----------
do $$
declare t text;
begin
  foreach t in array array['import_batches', 'products', 'detail_pages', 'detail_page_slots', 'market_accounts', 'shipping_templates',
                           'listing_drafts', 'market_uploads', 'export_files', 'banned_words'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_commerce.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
  foreach t in array array['import_batches', 'detail_pages', 'detail_page_slots', 'listing_drafts', 'market_uploads', 'export_files'] loop
    execute format('create trigger %1$s_status_guard before insert or update of status on nomad_commerce.%1$I for each row execute function nomad_commerce_private.status_guard()', t);
  end loop;
  foreach t in array array['products', 'shipping_templates', 'listing_drafts', 'banned_words'] loop
    execute format('create trigger %1$s_stamp_creator before insert on nomad_commerce.%1$I for each row execute function nomad_commerce_private.stamp_creator()', t);
  end loop;
end $$;
create trigger import_batches_core_refs before insert or update of job_id on nomad_commerce.import_batches
  for each row execute function nomad_commerce_private.check_core_refs();
create trigger detail_pages_core_refs before insert or update of job_id, credit_ledger_id on nomad_commerce.detail_pages
  for each row execute function nomad_commerce_private.check_core_refs();
create trigger market_uploads_core_refs before insert or update of job_id on nomad_commerce.market_uploads
  for each row execute function nomad_commerce_private.check_core_refs();
create trigger export_files_core_refs before insert or update of job_id on nomad_commerce.export_files
  for each row execute function nomad_commerce_private.check_core_refs();
create trigger detail_pages_job_delivery before update of status on nomad_commerce.detail_pages
  for each row execute function nomad_commerce_private.guard_job_delivery('ready');
create trigger import_batches_job_delivery before update of status on nomad_commerce.import_batches
  for each row execute function nomad_commerce_private.guard_job_delivery('completed');
create trigger products_force_deleted_at before insert or update of deleted_at on nomad_commerce.products
  for each row execute function nomad_commerce_private.force_deleted_at();
create trigger products_enforce_quota before insert or update of deleted_at on nomad_commerce.products
  for each row execute function nomad_commerce_private.products_enforce_quota();
create trigger market_accounts_enforce before insert or update of status, credential_id on nomad_commerce.market_accounts
  for each row execute function nomad_commerce_private.market_accounts_enforce();
create trigger detail_pages_gate before insert or update of status, slot_set, page_type, slots on nomad_commerce.detail_pages
  for each row execute function nomad_commerce_private.detail_pages_gate();
create trigger detail_pages_reset_warn_ack before update of compliance_verdict, compliance_issues on nomad_commerce.detail_pages
  for each row execute function nomad_commerce_private.reset_warn_ack();
create trigger market_uploads_target_immutable before update of market, market_account_id, detail_page_id on nomad_commerce.market_uploads
  for each row execute function nomad_commerce_private.market_uploads_target_immutable();
create trigger banned_words_floor before insert or update on nomad_commerce.banned_words
  for each row execute function nomad_commerce_private.banned_words_floor();
create trigger market_uploads_gate before insert or update of status on nomad_commerce.market_uploads
  for each row execute function nomad_commerce_private.market_uploads_gate();
create trigger export_files_gate before insert on nomad_commerce.export_files
  for each row execute function nomad_commerce_private.export_files_gate();

-- ---------- 4. 사용자 RPC: compliance WARN 확인(FAIL 은 확인으로 넘길 수 없다) ----------
-- 반환 = detail_pages 행(authenticated 가 모든 컬럼을 읽을 수 있는 표라 노출 범위가 같다).
create function nomad_commerce.acknowledge_compliance_warning(p_detail_page_id uuid, p_note text default null)
returns nomad_commerce.detail_pages
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_commerce.detail_pages;
begin
  select * into v_row from nomad_commerce.detail_pages d where d.id = p_detail_page_id for update;
  if not found then
    raise exception 'acknowledge_compliance_warning: not found' using errcode = 'P0002';
  end if;
  if not nomad_core.is_service_caller()
     and coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin', 'editor') then
    raise exception 'acknowledge_compliance_warning: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_row.organization_id, 'commerce', 'commerce') then
    raise exception 'acknowledge_compliance_warning: no access' using errcode = '42501';
  end if;
  if v_row.status <> 'ready' then
    raise exception 'acknowledge_compliance_warning: detail page is %', v_row.status using errcode = 'CM008';
  end if;
  if coalesce(v_row.compliance_verdict, '') <> 'warn' then
    raise exception 'acknowledge_compliance_warning: verdict is not warn' using errcode = 'CM009';
  end if;
  update nomad_commerce.detail_pages set warn_acknowledged_at = now(), warn_acknowledged_by = auth.uid()
   where id = p_detail_page_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'commerce.detail_page.compliance_warn_ack', 'detail_page', p_detail_page_id::text,
                                 null, null, jsonb_build_object('note', left(coalesce(p_note, ''), 500), 'issues', v_row.compliance_issues));
  return v_row;
end;
$$;

-- ---------- 5. RLS · GRANT ----------
do $$
declare t text;
begin
  foreach t in array array['import_batches', 'products', 'detail_pages', 'detail_page_slots', 'market_images', 'market_accounts',
                           'shipping_templates', 'listing_drafts', 'market_uploads', 'export_files', 'banned_words', 'exchange_rates', 'market_categories'] loop
    execute format('alter table nomad_commerce.%I enable row level security', t);
    execute format('revoke all on nomad_commerce.%I from public, anon, authenticated', t);
    execute format('grant all on nomad_commerce.%I to service_role', t);
  end loop;
  -- 서버가 쓰는 테넌트 표: 같은 조직 멤버 + commerce 접근이면 읽기
  foreach t in array array['import_batches', 'detail_pages', 'detail_page_slots', 'market_images', 'market_accounts', 'market_uploads', 'export_files'] loop
    execute format('grant select on nomad_commerce.%I to authenticated', t);
    execute format('create policy %1$s_select on nomad_commerce.%1$I for select to authenticated using (nomad_core.has_feature(organization_id, ''commerce'', ''commerce''))', t);
  end loop;
  -- 사용자 콘텐츠 표: 읽기(멤버) · 쓰기(owner/admin/editor) · 삭제(owner/admin)
  foreach t in array array['products', 'shipping_templates', 'listing_drafts'] loop
    execute format('grant select, delete on nomad_commerce.%I to authenticated', t);
    execute format('create policy %1$s_select on nomad_commerce.%1$I for select to authenticated using (nomad_core.has_feature(organization_id, ''commerce'', ''commerce''))', t);
    execute format('create policy %1$s_insert on nomad_commerce.%1$I for insert to authenticated with check (coalesce(nomad_core.organization_role(organization_id), '''') in (''owner'', ''admin'', ''editor'') and nomad_core.has_feature(organization_id, ''commerce'', ''commerce''))', t);
    execute format('create policy %1$s_update on nomad_commerce.%1$I for update to authenticated using (coalesce(nomad_core.organization_role(organization_id), '''') in (''owner'', ''admin'', ''editor'') and nomad_core.has_feature(organization_id, ''commerce'', ''commerce'')) with check (coalesce(nomad_core.organization_role(organization_id), '''') in (''owner'', ''admin'', ''editor'') and nomad_core.has_feature(organization_id, ''commerce'', ''commerce''))', t);
    execute format('create policy %1$s_delete on nomad_commerce.%1$I for delete to authenticated using (coalesce(nomad_core.organization_role(organization_id), '''') in (''owner'', ''admin''))', t);
  end loop;
end $$;

-- products: 콘텐츠 컬럼만. banned_words_found·source_*·import_batch_id 는 서버 전용. organization_id 는 update 불가(조직 이동 금지).
grant insert (organization_id, title, title_original, title_optimized, brand, manufacturer, origin_country, model_code, category_path,
              is_health_food, health_food_status, is_overseas, source_price, source_currency, sell_price_krw, list_price_krw,
              stock, images, attributes, tags)
  on nomad_commerce.products to authenticated;
grant update (title, title_optimized, brand, manufacturer, origin_country, model_code, category_path,
              is_health_food, health_food_status, is_overseas, source_price, source_currency, sell_price_krw, list_price_krw,
              stock, images, attributes, tags, status, deleted_at)
  on nomad_commerce.products to authenticated;
grant insert (organization_id, name, template_type, shipping, dispatch_days, return_window_days, exchange_allowed, return_fee_krw,
              initial_shipping_fee_krw, restriction_codes, return_address, contact_phone, is_default)
  on nomad_commerce.shipping_templates to authenticated;
grant update (name, template_type, shipping, dispatch_days, return_window_days, exchange_allowed, return_fee_krw,
              initial_shipping_fee_krw, restriction_codes, return_address, contact_phone, is_default)
  on nomad_commerce.shipping_templates to authenticated;
-- listing_drafts: status·completeness_pct·missing_fields 는 서버 전용.
grant insert (organization_id, product_id, detail_page_id, market, market_account_id, shipping_template_id, category_code, category_path,
              display_name, form_data, notice_info)
  on nomad_commerce.listing_drafts to authenticated;
grant update (detail_page_id, market_account_id, shipping_template_id, category_code, category_path, display_name, form_data, notice_info)
  on nomad_commerce.listing_drafts to authenticated;

-- banned_words: 기본 사전(organization_id null)은 읽기 전용, 조직 추가분은 owner/admin 편집
grant select, delete on nomad_commerce.banned_words to authenticated;
grant insert (organization_id, word, category, match_mode, severity, replacement, note, is_active) on nomad_commerce.banned_words to authenticated;
grant update (word, category, match_mode, severity, replacement, note, is_active) on nomad_commerce.banned_words to authenticated;
create index banned_words_org_idx on nomad_commerce.banned_words (organization_id) where organization_id is not null;
create policy banned_words_select on nomad_commerce.banned_words for select to authenticated
  using (organization_id is null or nomad_core.has_feature(organization_id, 'commerce', 'commerce'));
create policy banned_words_insert on nomad_commerce.banned_words for insert to authenticated
  with check (organization_id is not null and coalesce(nomad_core.organization_role(organization_id), '') in ('owner', 'admin')
              and nomad_core.has_feature(organization_id, 'commerce', 'commerce'));
create policy banned_words_update on nomad_commerce.banned_words for update to authenticated
  using (organization_id is not null and coalesce(nomad_core.organization_role(organization_id), '') in ('owner', 'admin'))
  with check (organization_id is not null and coalesce(nomad_core.organization_role(organization_id), '') in ('owner', 'admin')
              and nomad_core.has_feature(organization_id, 'commerce', 'commerce'));
create policy banned_words_delete on nomad_commerce.banned_words for delete to authenticated
  using (organization_id is not null and coalesce(nomad_core.organization_role(organization_id), '') in ('owner', 'admin'));

-- 전역 캐시: 로그인 사용자 읽기(비밀·개인정보 없음)
grant select on nomad_commerce.exchange_rates, nomad_commerce.market_categories to authenticated;
create policy exchange_rates_select on nomad_commerce.exchange_rates for select to authenticated using (true);
create policy market_categories_select on nomad_commerce.market_categories for select to authenticated using (true);
grant usage, select on sequence nomad_commerce.exchange_rates_id_seq to service_role;

-- ---------- 6. 함수 실행 권한 ----------
revoke execute on all functions in schema nomad_commerce from public, anon, authenticated;
revoke execute on all functions in schema nomad_commerce_private from public, anon, authenticated;
grant execute on function nomad_commerce.acknowledge_compliance_warning(uuid, text) to authenticated, service_role;

-- ---------- 7. Realtime: 슬롯 카드·업로드·내보내기·가져오기 상태(RLS 적용) ----------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['detail_pages', 'detail_page_slots', 'market_uploads', 'export_files', 'import_batches'] loop
      execute format('alter publication supabase_realtime add table nomad_commerce.%I', t);
    end loop;
  end if;
end $$;

-- ---------- 8. 제품 기본 금지어 사전(문자열, 원본 19장 그대로 — 목록 확정은 법률 검토 뒤) ----------
insert into nomad_commerce.banned_words (organization_id, word, category, match_mode, severity, replacement) values
  (null, '치료',          'health_food', 'substring', 'fail', '관리에 도움을 줄 수 있는'),
  (null, '치유',          'health_food', 'substring', 'fail', null),
  (null, '치료제',        'health_food', 'substring', 'fail', null),
  (null, '효능',          'health_food', 'substring', 'fail', '기능성'),
  (null, '효과가 있는',   'health_food', 'substring', 'fail', null),
  (null, '의약품',        'health_food', 'substring', 'fail', null),
  (null, '약품',          'health_food', 'substring', 'warn', null),
  (null, '항암',          'health_food', 'substring', 'fail', null),
  (null, '항균',          'health_food', 'substring', 'fail', '청결 유지'),
  (null, '살균',          'health_food', 'substring', 'fail', '위생 관리'),
  (null, '멸균',          'health_food', 'substring', 'fail', null),
  (null, '탈모치료',      'health_food', 'substring', 'fail', null),
  (null, '발모',          'health_food', 'substring', 'fail', null),
  (null, '혈압강하',      'health_food', 'substring', 'fail', null),
  (null, '당뇨치료',      'health_food', 'substring', 'fail', null),
  (null, '관절치료',      'health_food', 'substring', 'fail', null),
  (null, '면역치료',      'health_food', 'substring', 'fail', null),
  (null, '암예방',        'health_food', 'substring', 'fail', null),
  (null, '암치료',        'health_food', 'substring', 'fail', null),
  (null, '콜레스테롤 낮추는', 'health_food', 'substring', 'fail', null),
  (null, '혈당 낮추는',   'health_food', 'substring', 'fail', null)
on conflict (category, word) where organization_id is null do nothing;

commit;
