-- microweb-studio 이식 · 조직형(org안). 원본: platform-docs _supabase-modular/migrations/1500_microweb.sql 1~19절 + 20.4·20.5(음성 연결)
-- core.organizations→nomad_core.organizations(org_id→organization_id), org_members→nomad_core.memberships(member→editor),
-- has_entitlement→nomad_core.has_feature / org_has_feature(기능 코드 microweb/studio), core.credit_ledger·jobs·voice_jobs→nomad_core 대응.
-- AI 라우팅 기본값(원본 20.1~20.3)은 0002_ai.sql. 대응표: products/microweb/existing.md
-- 전제: nomad_core 코어 웨이브(touch_updated_at · audit · credits · rate_limit_take · jobs · voice). 되돌림: drop schema nomad_microweb cascade;
begin;

create schema nomad_microweb;
revoke all on schema nomad_microweb from public, anon, authenticated;
grant usage on schema nomad_microweb to anon, authenticated, service_role;

insert into nomad_core.products (code, name) values ('microweb', 'Microweb Studio') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('microweb', 'A', 'A'), ('microweb', 'B', 'B'), ('microweb', 'C', 'C') on conflict do nothing;
-- studio = 원본 has_entitlement(org, 'microweb'). 나머지는 원본 free 플랜 features 불리언 키(01_PRD 4장).
insert into nomad_core.features (product_code, code, name) values
  ('microweb', 'studio',          '마이크로웹 스튜디오(사이트·게시·하객·견적·주문)'),
  ('microweb', 'guestbook',       '방명록 블록'),
  ('microweb', 'rsvp',            'RSVP 블록'),
  ('microweb', 'ai_greeting',     '하객 AI 축하말'),
  ('microweb', 'bgm_upload',      'BGM mp3 업로드'),
  ('microweb', 'custom_slug',     'slug 직접 지정'),
  ('microweb', 'ai_copy',         'AI 문구·구성 제안'),
  ('microweb', 'ai_chat',         '제작 상담 채팅'),
  ('microweb', 'voice_chat',      '음성 대화'),
  ('microweb', 'voice_greeting',  '인사말 음성'),
  ('microweb', 'guestbook_voice', '하객 음성 방명록')
on conflict do nothing;
-- 구독이 끊기면 잠긴다: 구독 없음·만료·inactive는 C 취급(core 규칙)이고 C에는 studio가 없다.
-- 원본 free 플랜의 세부 기능만 C에도 둔다(세부 기능은 항상 studio와 함께 검사하므로 C 단독으로는 열리지 않는다).
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'microweb', p.code, f.code
from (values ('A'), ('B'), ('C')) p(code)
cross join (values ('studio'), ('guestbook'), ('rsvp'), ('ai_greeting'), ('bgm_upload'), ('custom_slug'),
                   ('ai_copy'), ('ai_chat'), ('voice_chat'), ('voice_greeting'), ('guestbook_voice')) f(code)
where not (p.code = 'C' and f.code = 'studio')
on conflict do nothing;

-- ---------- 공통 도우미: nomad_core 사용(제품 사본 없음) ----------
-- 서버 판정 nomad_core.is_service_caller() · 요청 제한 nomad_core.rate_limit_take(키 접두사 'microweb:')
-- · 감사 nomad_core.write_audit · 크레딧 nomad_core.credit_ledger(consume_credits) · 작업 nomad_core.jobs · 음성 nomad_core.voice_jobs.

-- ---------- 1. templates: 템플릿 카탈로그(전역, 조직 없음). 쓰기는 service_role 만 ----------
create table nomad_microweb.templates (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique
                        constraint templates_code_check check (code ~ '^[a-z][a-z0-9_]{2,40}$'),
  kind                  text not null
                        constraint templates_kind_check check (kind in (
                          'wedding', 'dol', 'obituary', 'business_card', 'mini_home', 'event',
                          'real_estate', 'portfolio', 'rolling_paper', 'qr_menu', 'pet_profile', 'gallery')),
  name                  text not null constraint templates_name_check check (char_length(name) between 1 and 60),
  summary               text,
  status                text not null default 'planned'
                        constraint templates_status_check check (status in ('planned', 'beta', 'released', 'retired')),
  release_phase         text not null default 'backlog'
                        constraint templates_release_phase_check check (release_phase in ('mvp', 'phase2', 'phase3', 'backlog')),
  agency_price_min_krw  integer constraint templates_price_min_check check (agency_price_min_krw is null or agency_price_min_krw >= 0),
  agency_price_max_krw  integer,
  price_note            text,
  self_publish_credits  integer constraint templates_self_credits_check check (self_publish_credits is null or self_publish_credits > 0),
  allowed_blocks        text[] not null default '{}',
  required_blocks       text[] not null default '{}',
  default_content       jsonb not null default '{}'::jsonb,
  preview_mockup        jsonb not null default '{}'::jsonb,
  sort_order            integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint templates_price_range_check check (
    agency_price_max_krw is null or agency_price_min_krw is null or agency_price_max_krw >= agency_price_min_krw),
  constraint templates_required_blocks_check check (required_blocks <@ allowed_blocks)
);
comment on table nomad_microweb.templates is '템플릿 카탈로그(전역). 쓰기는 service_role, 방문자는 list_public_templates RPC로만 읽는다.';
create index templates_status_sort_idx on nomad_microweb.templates (status, sort_order);

-- ---------- 2. portfolio_items: 쇼룸 포트폴리오(전역). 고객 게시 동의가 없으면 published 불가 ----------
create table nomad_microweb.portfolio_items (
  id                    uuid primary key default gen_random_uuid(),
  slug                  text not null unique constraint portfolio_items_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{2,58}[a-z0-9]$'),
  title                 text not null constraint portfolio_items_title_check check (char_length(title) between 1 and 80),
  category              text not null constraint portfolio_items_category_check check (category in ('microweb', 'website', 'detail_page')),
  tier                  text constraint portfolio_items_tier_check check (tier is null or tier in ('basic', 'pro', 'premium', 'custom')),
  industry              text constraint portfolio_items_industry_check check (industry is null or char_length(industry) <= 40),
  summary               text constraint portfolio_items_summary_check check (summary is null or char_length(summary) <= 300),
  external_url          text constraint portfolio_items_url_check check (external_url is null or external_url ~ '^https://'),
  image_path            text,
  client_permission_at  timestamptz,
  status                text not null default 'draft'
                        constraint portfolio_items_status_check check (status in ('draft', 'published', 'hidden')),
  sort_order            integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint portfolio_items_publish_check check (status <> 'published' or (client_permission_at is not null and image_path is not null))
);
comment on table nomad_microweb.portfolio_items is '쇼룸 포트폴리오(전역). 쓰기는 service_role, 방문자는 list_public_portfolio RPC로만 읽는다.';
create index portfolio_items_status_sort_idx on nomad_microweb.portfolio_items (status, category, sort_order);

-- ---------- 3. studio_access: 초대제 베타 허용 목록(쓰기는 service_role). 활성 사이트 상한은 운영자가 조직별로 준다 ----------
create table nomad_microweb.studio_access (
  organization_id   uuid primary key references nomad_core.organizations(id) on delete cascade,
  mode              text not null default 'agency'
                    constraint studio_access_mode_check check (mode in ('agency', 'self_service')),
  max_active_sites  integer not null default 3
                    constraint studio_access_max_sites_check check (max_active_sites between 0 and 1000),
  granted_by        uuid,
  granted_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table nomad_microweb.studio_access is '초대제 베타 허용 목록(조직당 1행). 기능 잠금(studio)과 함께 이 행이 있어야 스튜디오가 열린다.';

-- ---------- 4. sites: 청첩장/마이크로웹 편집본. 공개 페이지는 site_publications 스냅샷을 읽는다 ----------
create table nomad_microweb.sites (
  id                        uuid primary key default gen_random_uuid(),
  organization_id           uuid not null references nomad_core.organizations(id) on delete cascade,
  template_id               uuid not null references nomad_microweb.templates(id),
  kind                      text not null
                            constraint sites_kind_check check (kind in (
                              'wedding', 'dol', 'obituary', 'business_card', 'mini_home', 'event',
                              'real_estate', 'portfolio', 'rolling_paper', 'qr_menu', 'pet_profile', 'gallery')),
  slug                      text not null unique
                            constraint sites_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{2,38}[a-z0-9]$' and slug !~ '--'),
  title                     text not null constraint sites_title_check check (char_length(title) between 1 and 80),
  status                    text not null default 'draft'
                            constraint sites_status_check check (status in (
                              'draft', 'review', 'publishing', 'published', 'unpublished', 'expired', 'archived')),
  content                   jsonb not null default '{}'::jsonb
                            constraint sites_content_check check (jsonb_typeof(content) = 'object' and pg_column_size(content) <= 262144),
  event_at                  timestamptz,
  expires_at                timestamptz,
  guestbook_enabled         boolean not null default true,
  rsvp_enabled              boolean not null default false,
  ai_greeting_enabled       boolean not null default false,
  noindex                   boolean not null default true,
  disclosure_consent_at     timestamptz,
  disclosure_consent_by     uuid,
  disclosure_consent_basis  text constraint sites_consent_basis_check check (
                              disclosure_consent_basis is null or disclosure_consent_basis in ('self', 'written', 'recorded_call')),
  preview_token_hash        text unique,
  preview_token_expires_at  timestamptz,
  customer_approved_at      timestamptz,
  customer_approved_name    text constraint sites_approved_name_check check (customer_approved_name is null or char_length(customer_approved_name) <= 40),
  publish_ledger_id         uuid references nomad_core.credit_ledger(id) on delete set null,
  publish_charged_at        timestamptz,
  publish_job_id            uuid references nomad_core.jobs(id) on delete set null,
  publish_requested_at      timestamptz,
  first_published_at        timestamptz,
  published_at              timestamptz,
  unpublished_at            timestamptz,
  expired_at                timestamptz,
  archived_at               timestamptz,
  created_by                uuid,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint sites_expires_check check (expires_at is null or event_at is null or expires_at <= event_at + interval '365 days'),
  constraint sites_slug_reserved_check check (slug not in (
    'admin', 'api', 'studio', 'login', 'logout', 'signup', 'www', 'preview', 'static', 'assets',
    'help', 'pricing', 'portfolio', 'templates', 'simulator', 'contact'))
);
comment on table nomad_microweb.sites is '마이크로웹 편집본(조직 소유). 사용자는 콘텐츠 컬럼만 직접 수정, 상태·게시·동의·과금은 RPC 전용.';
create index sites_org_status_idx on nomad_microweb.sites (organization_id, status, updated_at desc);
create index sites_org_updated_idx on nomad_microweb.sites (organization_id, updated_at);
create index sites_expiry_idx on nomad_microweb.sites (expires_at) where status in ('published', 'unpublished');
create index sites_publishing_idx on nomad_microweb.sites (publish_requested_at) where status = 'publishing';
create unique index sites_publish_ledger_idx on nomad_microweb.sites (publish_ledger_id) where publish_ledger_id is not null;

-- ---------- 5. site_publications: 공개 스냅샷(사이트당 1행). 방문자는 get_public_site RPC로만 읽는다 ----------
create table nomad_microweb.site_publications (
  site_id          uuid primary key references nomad_microweb.sites(id) on delete cascade,
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  slug             text not null unique,
  version          integer not null default 1 constraint site_publications_version_check check (version >= 1),
  content          jsonb not null
                   constraint site_publications_content_check check (jsonb_typeof(content) = 'object' and pg_column_size(content) <= 262144),
  og_title         text constraint site_publications_og_title_check check (og_title is null or char_length(og_title) <= 80),
  og_description   text constraint site_publications_og_desc_check check (og_description is null or char_length(og_description) <= 160),
  og_image_url     text constraint site_publications_og_image_check check (og_image_url is null or og_image_url ~ '^https://'),
  is_live          boolean not null default false,
  published_at     timestamptz not null default now(),
  expires_at       timestamptz not null,
  unpublished_at   timestamptz,
  job_id           uuid references nomad_core.jobs(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table nomad_microweb.site_publications is '공개 스냅샷. 쓰기는 finalize_publish·transition_site·expire_sites(DEFINER)와 service_role 만.';
create index site_publications_live_idx on nomad_microweb.site_publications (slug) where is_live;
create index site_publications_org_updated_idx on nomad_microweb.site_publications (organization_id, updated_at);

-- ---------- 6. site_assets: 업로드 사진·음원 메타(원본 비공개, 공개 파생본은 게시 때만). voice = 인사말 음성 mp3(원본 20.5) ----------
create table nomad_microweb.site_assets (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  site_id          uuid not null references nomad_microweb.sites(id) on delete cascade,
  kind             text not null constraint site_assets_kind_check check (kind in ('hero', 'gallery', 'og', 'bgm', 'voice', 'other')),
  storage_path     text not null unique,
  mime             text not null constraint site_assets_mime_check check (mime in ('image/jpeg', 'image/png', 'image/webp', 'audio/mpeg')),
  bytes            integer not null constraint site_assets_bytes_check check (bytes between 1 and 15728640),
  width            integer,
  height           integer,
  status           text not null default 'uploaded'
                   constraint site_assets_status_check check (status in ('uploaded', 'processing', 'ready', 'failed')),
  exif_stripped    boolean not null default false,
  variants         jsonb not null default '{}'::jsonb,
  public_paths     jsonb not null default '{}'::jsonb,
  caption          text constraint site_assets_caption_check check (caption is null or char_length(caption) <= 100),
  sort_order       integer not null default 0,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint site_assets_path_check check (split_part(storage_path, '/', 1) = organization_id::text and split_part(storage_path, '/', 2) = 'microweb'),
  constraint site_assets_kind_mime_check check ((kind in ('bgm', 'voice')) = (mime = 'audio/mpeg')),
  constraint site_assets_ready_check check (status <> 'ready' or exif_stripped or kind in ('bgm', 'voice'))
);
comment on table nomad_microweb.site_assets is '사이트 자산 메타. INSERT·DELETE 는 서버(Storage 와 함께), 사용자는 캡션·순서만 수정.';
create index site_assets_site_idx on nomad_microweb.site_assets (site_id, kind, sort_order);
create index site_assets_org_updated_idx on nomad_microweb.site_assets (organization_id, updated_at);

-- ---------- 7. guestbook_entries: 하객 방명록. INSERT 는 submit_guestbook_entry(service_role)만. ip_hash·voice_job_id 는 사용자에게 안 보인다 ----------
create table nomad_microweb.guestbook_entries (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  site_id          uuid not null references nomad_microweb.sites(id) on delete cascade,
  author_name      text not null constraint guestbook_entries_name_check check (char_length(btrim(author_name)) between 1 and 20),
  body             text not null constraint guestbook_entries_body_check check (char_length(btrim(body)) between 1 and 500),
  relation         text constraint guestbook_entries_relation_check check (
                     relation is null or relation in ('friend', 'colleague', 'family', 'acquaintance', 'other')),
  ai_assisted      boolean not null default false,
  status           text not null default 'visible'
                   constraint guestbook_entries_status_check check (status in ('visible', 'hidden', 'spam')),
  ip_hash          text not null constraint guestbook_entries_ip_hash_check check (char_length(ip_hash) between 16 and 128),
  voice_job_id     uuid references nomad_core.voice_jobs(id) on delete set null,
  has_voice        boolean generated always as (voice_job_id is not null) stored,
  moderated_by     uuid,
  moderated_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table nomad_microweb.guestbook_entries is '하객 방명록. 쓰기는 service_role RPC, 멤버는 ip_hash·voice_job_id 제외 컬럼만 읽는다.';
comment on column nomad_microweb.guestbook_entries.voice_job_id is '하객 음성(nomad_core.voice_jobs, STT·보관·하객 고지). attach_guestbook_voice 로만 붙인다';
create index guestbook_entries_site_idx on nomad_microweb.guestbook_entries (site_id, created_at desc) where status = 'visible';
create index guestbook_entries_dedupe_idx on nomad_microweb.guestbook_entries (site_id, ip_hash, created_at desc);
create index guestbook_entries_org_updated_idx on nomad_microweb.guestbook_entries (organization_id, updated_at);
create unique index guestbook_entries_voice_job_idx on nomad_microweb.guestbook_entries (voice_job_id) where voice_job_id is not null;

-- ---------- 8. rsvp_responses: 참석 여부(추가 전용, 개인정보). INSERT 는 submit_rsvp(service_role)만 ----------
create table nomad_microweb.rsvp_responses (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  site_id          uuid not null references nomad_microweb.sites(id) on delete cascade,
  guest_name       text not null constraint rsvp_responses_name_check check (char_length(btrim(guest_name)) between 1 and 20),
  side             text not null default 'none' constraint rsvp_responses_side_check check (side in ('side_a', 'side_b', 'none')),
  attending        text not null constraint rsvp_responses_attending_check check (attending in ('yes', 'no', 'undecided')),
  party_size       smallint not null default 1 constraint rsvp_responses_party_check check (party_size between 1 and 10),
  meal             text constraint rsvp_responses_meal_check check (meal is null or meal in ('yes', 'no', 'undecided')),
  message          text constraint rsvp_responses_message_check check (message is null or char_length(message) <= 200),
  ip_hash          text not null constraint rsvp_responses_ip_hash_check check (char_length(ip_hash) between 16 and 128),
  created_at       timestamptz not null default now()
);
comment on table nomad_microweb.rsvp_responses is '하객 참석 응답(개인정보, 추가 전용). 읽기는 owner/admin/editor(ip_hash 제외).';
create index rsvp_responses_site_idx on nomad_microweb.rsvp_responses (site_id, created_at desc);
create index rsvp_responses_org_created_idx on nomad_microweb.rsvp_responses (organization_id, created_at desc);

-- ---------- 9. leads: 견적 문의(대행 영업, 개인정보). organization_id = 스튜디오(대행사) 조직. INSERT 는 create_lead(service_role)만 ----------
create table nomad_microweb.leads (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  source              text not null constraint leads_source_check check (source in ('contact_form', 'simulator', 'template_gallery', 'pricing', 'manual')),
  name                text not null constraint leads_name_check check (char_length(btrim(name)) between 1 and 40),
  phone               text constraint leads_phone_check check (phone is null or phone ~ '^0[0-9]{1,2}-?[0-9]{3,4}-?[0-9]{4}$'),
  email               text constraint leads_email_check check (email is null or (char_length(email) <= 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  kind                text constraint leads_kind_check check (kind is null or kind in (
                        'wedding', 'dol', 'obituary', 'business_card', 'mini_home', 'event',
                        'real_estate', 'portfolio', 'rolling_paper', 'qr_menu', 'pet_profile', 'gallery', 'website', 'detail_page')),
  template_code       text constraint leads_template_code_check check (template_code is null or template_code ~ '^[a-z][a-z0-9_]{2,40}$'),
  tier                text constraint leads_tier_check check (tier is null or tier in ('basic', 'pro', 'premium', 'custom')),
  industry            text constraint leads_industry_check check (industry is null or char_length(industry) <= 40),
  event_on            date,
  simulator           jsonb not null default '{}'::jsonb
                      constraint leads_simulator_check check (jsonb_typeof(simulator) = 'object' and pg_column_size(simulator) <= 8192),
  message             text constraint leads_message_check check (message is null or char_length(message) <= 2000),
  privacy_consent_at  timestamptz not null,
  status              text not null default 'new'
                      constraint leads_status_check check (status in ('new', 'contacted', 'quoted', 'won', 'lost', 'spam')),
  status_note         text constraint leads_status_note_check check (status_note is null or char_length(status_note) <= 500),
  ip_hash             text,
  contacted_at        timestamptz,
  closed_at           timestamptz,
  purge_after         timestamptz not null default (now() + interval '1 year'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint leads_contact_check check (phone is not null or email is not null)
);
comment on table nomad_microweb.leads is '견적 문의(개인정보). 쓰기는 create_lead·set_lead_status·delete_lead RPC, 읽기는 owner/admin/editor(ip_hash 제외).';
create index leads_org_status_idx on nomad_microweb.leads (organization_id, status, created_at desc);
create index leads_org_updated_idx on nomad_microweb.leads (organization_id, updated_at);
create index leads_purge_idx on nomad_microweb.leads (purge_after);

-- ---------- 10. production_orders: 대행 제작 주문(대행사 자체 장부, 플랫폼 과금과 별개). 금액 정수(원), 생성 멱등 키 ----------
create table nomad_microweb.production_orders (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  lead_id            uuid references nomad_microweb.leads(id) on delete set null,
  site_id            uuid references nomad_microweb.sites(id) on delete set null,
  customer_name      text not null constraint production_orders_customer_check check (char_length(btrim(customer_name)) between 1 and 40),
  template_code      text,
  tier               text constraint production_orders_tier_check check (tier is null or tier in ('basic', 'pro', 'premium', 'custom')),
  amount_krw         integer not null constraint production_orders_amount_check check (amount_krw between 0 and 100000000),
  idempotency_key    text not null constraint production_orders_idem_check check (char_length(idempotency_key) between 1 and 200),
  status             text not null default 'quoted'
                     constraint production_orders_status_check check (status in (
                       'quoted', 'paid', 'in_production', 'delivered', 'closed', 'canceled', 'refunded')),
  payment_method     text constraint production_orders_method_check check (
                       payment_method is null or payment_method in ('bank_transfer', 'toss_link', 'card_onsite', 'other')),
  payment_reference  text constraint production_orders_reference_check check (
                       payment_reference is null or (char_length(payment_reference) <= 100 and payment_reference !~ '[0-9]{12,}')),
  note               text constraint production_orders_note_check check (note is null or char_length(note) <= 1000),
  paid_at            timestamptz,
  in_production_at   timestamptz,
  delivered_at       timestamptz,
  closed_at          timestamptz,
  canceled_at        timestamptz,
  refunded_at        timestamptz,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint production_orders_paid_check check (status in ('quoted', 'canceled') or (paid_at is not null and payment_method is not null)),
  constraint production_orders_idem_uniq unique (organization_id, idempotency_key)
);
comment on table nomad_microweb.production_orders is '대행 제작 주문(대행사 장부). 쓰기는 create_order·transition_order·attach_order_site RPC, 결제 민감정보 저장 금지.';
create index production_orders_org_status_idx on nomad_microweb.production_orders (organization_id, status, created_at desc);
create index production_orders_org_updated_idx on nomad_microweb.production_orders (organization_id, updated_at);
create index production_orders_site_idx on nomad_microweb.production_orders (site_id) where site_id is not null;

-- ---------- 11. updated_at 트리거(nomad_core.touch_updated_at) ----------
create trigger templates_touch before update on nomad_microweb.templates for each row execute function nomad_core.touch_updated_at();
create trigger portfolio_items_touch before update on nomad_microweb.portfolio_items for each row execute function nomad_core.touch_updated_at();
create trigger studio_access_touch before update on nomad_microweb.studio_access for each row execute function nomad_core.touch_updated_at();
create trigger sites_touch before update on nomad_microweb.sites for each row execute function nomad_core.touch_updated_at();
create trigger site_publications_touch before update on nomad_microweb.site_publications for each row execute function nomad_core.touch_updated_at();
create trigger site_assets_touch before update on nomad_microweb.site_assets for each row execute function nomad_core.touch_updated_at();
create trigger guestbook_entries_touch before update on nomad_microweb.guestbook_entries for each row execute function nomad_core.touch_updated_at();
create trigger leads_touch before update on nomad_microweb.leads for each row execute function nomad_core.touch_updated_at();
create trigger production_orders_touch before update on nomad_microweb.production_orders for each row execute function nomad_core.touch_updated_at();

-- ---------- 12. 상태 전이 트리거(service_role 쓰기에도 적용, 위반은 MW001) ----------
create function nomad_microweb.sites_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'sites: new site must start as draft' using errcode = 'MW001';
    end if;
    return new;
  end if;
  if new.status is not distinct from old.status then
    return new;
  end if;
  if not (
       (old.status = 'draft'       and new.status in ('review', 'publishing', 'archived'))
    or (old.status = 'review'      and new.status in ('draft', 'publishing', 'archived'))
    or (old.status = 'publishing'  and new.status in ('published', 'draft', 'unpublished', 'expired'))
    or (old.status = 'published'   and new.status in ('publishing', 'unpublished', 'expired'))
    or (old.status = 'unpublished' and new.status in ('publishing', 'expired', 'archived'))
    or (old.status = 'expired'     and new.status in ('publishing', 'archived'))
  ) then
    raise exception 'sites: transition % -> % not allowed', old.status, new.status using errcode = 'MW001';
  end if;
  return new;
end;
$$;
create trigger sites_status_transition before insert or update on nomad_microweb.sites
  for each row execute function nomad_microweb.sites_status_transition();

-- 편집 잠금: 사용자 세션은 publishing/archived 상태를 편집할 수 없고, 만료일은 미래여야 한다. 슬러그는 첫 게시 뒤 누구도 못 바꾼다.
create function nomad_microweb.sites_guard_edit()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.slug is distinct from old.slug and old.first_published_at is not null then
    raise exception 'sites: slug is locked after first publish' using errcode = 'MW002';
  end if;
  if not nomad_core.is_service_caller() then
    if old.status in ('publishing', 'archived') then
      raise exception 'sites: site is locked in status %', old.status using errcode = 'MW003';
    end if;
    if new.expires_at is distinct from old.expires_at then
      if new.expires_at is null and old.first_published_at is not null then
        raise exception 'sites: published site needs expires_at' using errcode = '22023';
      end if;
      if new.expires_at is not null and new.expires_at <= now() then
        raise exception 'sites: expires_at must be in the future' using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger sites_guard_edit before update on nomad_microweb.sites
  for each row execute function nomad_microweb.sites_guard_edit();

-- 만료일 변경을 공개 스냅샷에 반영한다(DEFINER: 사용자는 스냅샷 쓰기 권한이 없으므로).
create function nomad_microweb.sites_sync_publication()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.expires_at is distinct from old.expires_at and new.expires_at is not null then
    update nomad_microweb.site_publications set expires_at = new.expires_at where site_id = new.id;
  end if;
  return null;
end;
$$;
create trigger sites_sync_publication after update of expires_at on nomad_microweb.sites
  for each row execute function nomad_microweb.sites_sync_publication();

create function nomad_microweb.leads_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;
  if not (
       (old.status = 'new'       and new.status in ('contacted', 'quoted', 'lost', 'spam'))
    or (old.status = 'contacted' and new.status in ('quoted', 'won', 'lost', 'spam'))
    or (old.status = 'quoted'    and new.status in ('won', 'lost', 'spam'))
    or (old.status = 'lost'      and new.status in ('contacted'))
  ) then
    raise exception 'leads: transition % -> % not allowed', old.status, new.status using errcode = 'MW001';
  end if;
  return new;
end;
$$;
create trigger leads_status_transition before update on nomad_microweb.leads
  for each row execute function nomad_microweb.leads_status_transition();

create function nomad_microweb.production_orders_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'quoted' then
      raise exception 'production_orders: new order must start as quoted' using errcode = 'MW001';
    end if;
    return new;
  end if;
  if new.status is not distinct from old.status then
    return new;
  end if;
  if not (
       (old.status = 'quoted'        and new.status in ('paid', 'canceled'))
    or (old.status = 'paid'          and new.status in ('in_production', 'refunded'))
    or (old.status = 'in_production' and new.status in ('delivered', 'refunded'))
    or (old.status = 'delivered'     and new.status in ('closed', 'refunded'))
  ) then
    raise exception 'production_orders: transition % -> % not allowed', old.status, new.status using errcode = 'MW001';
  end if;
  return new;
end;
$$;
create trigger production_orders_status_transition before insert or update on nomad_microweb.production_orders
  for each row execute function nomad_microweb.production_orders_status_transition();

-- ---------- 13. RLS 헬퍼(DEFINER, 읽기 전용) ----------
-- 스튜디오 접근 = 조직 멤버 + 기능 studio(A·B, 구독 끊기면 false) + 허용 목록(회수 안 됨)
create function nomad_microweb.has_studio_access(p_organization_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select nomad_core.organization_role(p_organization_id) is not null
     and nomad_core.has_feature(p_organization_id, 'microweb', 'studio')
     and exists (select 1 from nomad_microweb.studio_access a where a.organization_id = p_organization_id and a.revoked_at is null);
$$;

-- 조직 단위(멤버십 무관) 판정: 서버·공개 RPC 내부용
create function nomad_microweb.org_studio_open(p_organization_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select nomad_core.org_has_feature(p_organization_id, 'microweb', 'studio')
     and exists (select 1 from nomad_microweb.studio_access a where a.organization_id = p_organization_id and a.revoked_at is null);
$$;

-- 게시 중 열람 판정(사용자 결정 2026-11-14): 구독 잠김·허용 목록 회수와 무관하게 게시 중이면 true, 조직 비활성이면 false.
-- 쓰기 경로(방명록·RSVP·음성 연결·게시)는 org_studio_open 을 따로 검사한다.
create function nomad_microweb.is_site_live(p_site_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from nomad_microweb.site_publications p
    where p.site_id = p_site_id and p.is_live and p.expires_at > now()
      and exists (select 1 from nomad_core.organizations o where o.id = p.organization_id and o.active)
  );
$$;

create function nomad_microweb.is_guestbook_public(p_site_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select nomad_microweb.is_site_live(p_site_id)
     and exists (select 1 from nomad_microweb.sites s where s.id = p_site_id and s.guestbook_enabled
                   and nomad_core.org_has_feature(s.organization_id, 'microweb', 'guestbook'));
$$;

-- 내부용: DEFINER 함수 안에서 호출자 역할과 스튜디오 접근을 확인한다(원본 member → editor)
create function nomad_microweb.require_org_role(p_organization_id uuid, p_roles text[], p_ctx text)
returns void language plpgsql stable set search_path = ''
as $$
begin
  if nomad_core.is_service_caller() then
    return;
  end if;
  if p_organization_id is null or coalesce(nomad_core.organization_role(p_organization_id), '') <> all (p_roles) then
    raise exception '%: role % required', p_ctx, p_roles using errcode = '42501';
  end if;
  if not nomad_microweb.has_studio_access(p_organization_id) then
    raise exception '%: no studio access', p_ctx using errcode = '42501';
  end if;
end;
$$;

-- ---------- 14. RLS: 모든 표 ON. 정책은 authenticated 만(anon 테이블 권한 0) ----------
alter table nomad_microweb.templates         enable row level security;
alter table nomad_microweb.portfolio_items   enable row level security;
alter table nomad_microweb.studio_access     enable row level security;
alter table nomad_microweb.sites             enable row level security;
alter table nomad_microweb.site_publications enable row level security;
alter table nomad_microweb.site_assets       enable row level security;
alter table nomad_microweb.guestbook_entries enable row level security;
alter table nomad_microweb.rsvp_responses    enable row level security;
alter table nomad_microweb.leads             enable row level security;
alter table nomad_microweb.production_orders enable row level security;

create policy templates_select on nomad_microweb.templates for select to authenticated using (status <> 'retired');
create policy portfolio_items_select on nomad_microweb.portfolio_items for select to authenticated using (status = 'published');
-- 허용 목록은 잠긴 조직도 자기 행을 볼 수 있다(왜 잠겼는지 안내용)
create policy studio_access_select on nomad_microweb.studio_access for select to authenticated
  using (nomad_core.organization_role(organization_id) is not null);
create policy sites_select on nomad_microweb.sites for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id));
create policy sites_update on nomad_microweb.sites for update to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'))
  with check (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy site_publications_select on nomad_microweb.site_publications for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id));
create policy site_assets_select on nomad_microweb.site_assets for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id));
create policy site_assets_update on nomad_microweb.site_assets for update to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'))
  with check (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy guestbook_entries_select on nomad_microweb.guestbook_entries for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id));
create policy guestbook_entries_delete on nomad_microweb.guestbook_entries for delete to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin'));
-- 개인정보(참석·견적·주문 고객명)는 viewer 제외
create policy rsvp_responses_select on nomad_microweb.rsvp_responses for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy rsvp_responses_delete on nomad_microweb.rsvp_responses for delete to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy leads_select on nomad_microweb.leads for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy production_orders_select on nomad_microweb.production_orders for select to authenticated
  using (nomad_microweb.has_studio_access(organization_id) and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));

revoke all on all tables in schema nomad_microweb from public, anon, authenticated;
grant select, insert, update, delete on all tables in schema nomad_microweb to service_role;
grant select on nomad_microweb.templates, nomad_microweb.portfolio_items,
  nomad_microweb.sites, nomad_microweb.site_publications, nomad_microweb.site_assets, nomad_microweb.production_orders to authenticated;
grant update (title, content, event_at, expires_at, slug, guestbook_enabled, rsvp_enabled, ai_greeting_enabled)
  on nomad_microweb.sites to authenticated;
grant update (caption, sort_order) on nomad_microweb.site_assets to authenticated;
-- 허용 목록: note·granted_by(운영 메모·부여자)는 멤버 컬럼 GRANT 에서 뺀다 → owner/admin 은 studio_access_detail RPC
grant select (organization_id, mode, max_active_sites, granted_at, revoked_at, created_at, updated_at)
  on nomad_microweb.studio_access to authenticated;
grant select (id, organization_id, site_id, author_name, body, relation, ai_assisted, status, has_voice, moderated_at, created_at, updated_at)
  on nomad_microweb.guestbook_entries to authenticated;
grant delete on nomad_microweb.guestbook_entries, nomad_microweb.rsvp_responses to authenticated;
grant select (id, organization_id, site_id, guest_name, side, attending, party_size, meal, message, created_at)
  on nomad_microweb.rsvp_responses to authenticated;
grant select (id, organization_id, source, name, phone, email, kind, template_code, tier, industry, event_on, simulator, message,
              privacy_consent_at, status, status_note, contacted_at, closed_at, purge_after, created_at, updated_at)
  on nomad_microweb.leads to authenticated;

-- ---------- 15. 사용자 RPC (authenticated + service_role). 호출자 판정은 is_service_caller ----------
-- 사이트 생성: 템플릿(beta/released)만, 활성 사이트 상한(studio_access.max_active_sites), 기본 만료 = 예식 + 90일
create function nomad_microweb.create_site(
  p_organization_id uuid, p_template_code text, p_title text, p_slug text, p_event_at timestamptz default null
)
returns nomad_microweb.sites language plpgsql security definer set search_path = ''
as $$
declare v_tpl nomad_microweb.templates; v_access nomad_microweb.studio_access; v_active integer; v_row nomad_microweb.sites;
begin
  perform nomad_microweb.require_org_role(p_organization_id, array['owner', 'admin', 'editor'], 'create_site');
  select * into v_access from nomad_microweb.studio_access where organization_id = p_organization_id and revoked_at is null;
  if not found or not nomad_core.org_has_feature(p_organization_id, 'microweb', 'studio') then
    raise exception 'create_site: no studio access' using errcode = '42501';
  end if;
  select * into v_tpl from nomad_microweb.templates where code = p_template_code and status in ('beta', 'released');
  if not found then
    raise exception 'create_site: template % not available', p_template_code using errcode = 'MW004';
  end if;
  perform pg_advisory_xact_lock(hashtext('microweb:create_site:' || p_organization_id::text));
  select count(*) into v_active from nomad_microweb.sites
   where organization_id = p_organization_id and status not in ('expired', 'archived');
  if v_active >= v_access.max_active_sites then
    raise exception 'create_site: active site limit % reached', v_access.max_active_sites using errcode = 'MW005';
  end if;
  insert into nomad_microweb.sites (organization_id, template_id, kind, slug, title, content, event_at, expires_at, created_by)
  values (p_organization_id, v_tpl.id, v_tpl.kind, lower(btrim(p_slug)), btrim(p_title), v_tpl.default_content, p_event_at,
          case when p_event_at is not null then p_event_at + interval '90 days' end, auth.uid())
  returning * into v_row;
  perform nomad_core.write_audit(p_organization_id, 'site.create', 'site', v_row.id::text, null,
                                 jsonb_build_object('slug', v_row.slug, 'template', p_template_code));
  return v_row;
end;
$$;

-- 사용자 상태 전이: draft <-> review (owner/admin/editor), unpublished / archived (owner/admin). 게시·만료는 이 함수로 못 바꾼다
create function nomad_microweb.transition_site(p_site_id uuid, p_to text, p_reason text default null)
returns nomad_microweb.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites; v_from text;
begin
  select * into v_row from nomad_microweb.sites where id = p_site_id for update;
  if not found then raise exception 'transition_site: not found' using errcode = 'P0002'; end if;
  if p_to in ('unpublished', 'archived') then
    perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin'], 'transition_site');
  elsif p_to in ('draft', 'review') then
    perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin', 'editor'], 'transition_site');
  else
    raise exception 'transition_site: % is not a user transition', p_to using errcode = 'MW001';
  end if;
  v_from := v_row.status;
  update nomad_microweb.sites
     set status = p_to,
         unpublished_at = case when p_to = 'unpublished' then now() else unpublished_at end,
         archived_at = case when p_to = 'archived' then now() else archived_at end,
         preview_token_hash = case when p_to = 'archived' then null else preview_token_hash end,
         preview_token_expires_at = case when p_to = 'archived' then null else preview_token_expires_at end
   where id = p_site_id
  returning * into v_row;
  if p_to = 'unpublished' then
    update nomad_microweb.site_publications set is_live = false, unpublished_at = now() where site_id = p_site_id;
  end if;
  perform nomad_core.write_audit(v_row.organization_id, 'site.' || p_to, 'site', p_site_id::text,
                                 jsonb_build_object('status', v_from), jsonb_build_object('status', p_to, 'reason', left(p_reason, 200)));
  return v_row;
end;
$$;

-- 고객 시안 확인 링크 토큰. 원문은 한 번만 반환, DB 에는 sha256 해시만. TTL 1~336시간
create function nomad_microweb.issue_preview_token(p_site_id uuid, p_ttl_hours integer default 168)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites; v_token text;
begin
  select * into v_row from nomad_microweb.sites where id = p_site_id for update;
  if not found then raise exception 'issue_preview_token: not found' using errcode = 'P0002'; end if;
  perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin', 'editor'], 'issue_preview_token');
  if v_row.status in ('publishing', 'archived') then
    raise exception 'issue_preview_token: site is %', v_row.status using errcode = 'MW003';
  end if;
  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  update nomad_microweb.sites
     set preview_token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'),
         preview_token_expires_at = now() + make_interval(hours => least(greatest(coalesce(p_ttl_hours, 168), 1), 336))
   where id = p_site_id;
  perform nomad_core.write_audit(v_row.organization_id, 'site.preview_token', 'site', p_site_id::text, null,
                                 jsonb_build_object('ttl_hours', p_ttl_hours));
  return v_token;
end;
$$;

-- 계좌번호·연락처 공개 동의 기록. 게시 전 필수(request_publish 가 검사)
create function nomad_microweb.confirm_disclosure_consent(p_site_id uuid, p_basis text)
returns nomad_microweb.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites;
begin
  select * into v_row from nomad_microweb.sites where id = p_site_id for update;
  if not found then raise exception 'confirm_disclosure_consent: not found' using errcode = 'P0002'; end if;
  perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin', 'editor'], 'confirm_disclosure_consent');
  if coalesce(p_basis, '') not in ('self', 'written', 'recorded_call') then
    raise exception 'confirm_disclosure_consent: invalid basis' using errcode = '22023';
  end if;
  update nomad_microweb.sites
     set disclosure_consent_at = now(), disclosure_consent_by = auth.uid(), disclosure_consent_basis = p_basis
   where id = p_site_id
  returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'site.disclosure_consent', 'site', p_site_id::text, null,
                                 jsonb_build_object('basis', p_basis));
  return v_row;
end;
$$;

-- 반환은 authenticated 컬럼 GRANT 와 같은 공개 컬럼만(jsonb). 행 전체를 돌려주면 ip_hash·voice_job_id·moderated_by 가 새어 나간다(보안 리뷰).
create function nomad_microweb.moderate_guestbook_entry(p_entry_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.guestbook_entries; v_from text;
begin
  select * into v_row from nomad_microweb.guestbook_entries where id = p_entry_id for update;
  if not found then raise exception 'moderate_guestbook_entry: not found' using errcode = 'P0002'; end if;
  perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin', 'editor'], 'moderate_guestbook_entry');
  if coalesce(p_status, '') not in ('visible', 'hidden', 'spam') then
    raise exception 'moderate_guestbook_entry: invalid status' using errcode = '22023';
  end if;
  v_from := v_row.status;
  update nomad_microweb.guestbook_entries set status = p_status, moderated_by = auth.uid(), moderated_at = now()
   where id = p_entry_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'guestbook.' || p_status, 'guestbook_entry', p_entry_id::text,
                                 jsonb_build_object('status', v_from), jsonb_build_object('status', p_status));
  return jsonb_build_object('id', v_row.id, 'organization_id', v_row.organization_id, 'site_id', v_row.site_id,
    'author_name', v_row.author_name, 'body', v_row.body, 'relation', v_row.relation, 'ai_assisted', v_row.ai_assisted,
    'status', v_row.status, 'has_voice', v_row.has_voice, 'moderated_at', v_row.moderated_at,
    'created_at', v_row.created_at, 'updated_at', v_row.updated_at);
end;
$$;

-- 반환은 authenticated 컬럼 GRANT 와 같은 공개 컬럼만(jsonb). 행 전체를 돌려주면 ip_hash 가 새어 나간다(보안 리뷰).
create function nomad_microweb.set_lead_status(p_lead_id uuid, p_to text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.leads; v_from text;
begin
  select * into v_row from nomad_microweb.leads where id = p_lead_id for update;
  if not found then raise exception 'set_lead_status: not found' using errcode = 'P0002'; end if;
  perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin', 'editor'], 'set_lead_status');
  v_from := v_row.status;
  update nomad_microweb.leads
     set status = p_to,
         status_note = coalesce(p_note, status_note),
         contacted_at = case when p_to = 'contacted' and contacted_at is null then now() else contacted_at end,
         closed_at = case when p_to in ('won', 'lost', 'spam') then now() else closed_at end
   where id = p_lead_id
  returning * into v_row;
  -- 감사에는 개인정보(이름·연락처·메시지)를 남기지 않는다
  perform nomad_core.write_audit(v_row.organization_id, 'lead.' || p_to, 'lead', p_lead_id::text,
                                 jsonb_build_object('status', v_from), jsonb_build_object('status', p_to));
  return jsonb_build_object('id', v_row.id, 'organization_id', v_row.organization_id, 'source', v_row.source,
    'name', v_row.name, 'phone', v_row.phone, 'email', v_row.email, 'kind', v_row.kind, 'template_code', v_row.template_code,
    'tier', v_row.tier, 'industry', v_row.industry, 'event_on', v_row.event_on, 'simulator', v_row.simulator,
    'message', v_row.message, 'privacy_consent_at', v_row.privacy_consent_at, 'status', v_row.status,
    'status_note', v_row.status_note, 'contacted_at', v_row.contacted_at, 'closed_at', v_row.closed_at,
    'purge_after', v_row.purge_after, 'created_at', v_row.created_at, 'updated_at', v_row.updated_at);
end;
$$;

-- 허용 목록 상세(note·granted_by 포함). owner/admin 만, 잠긴 조직도 볼 수 있다(studio_access_select 정책과 같은 기준)
create function nomad_microweb.studio_access_detail(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_row nomad_microweb.studio_access;
begin
  if not nomad_core.is_service_caller()
     and coalesce(nomad_core.organization_role(p_organization_id), '') not in ('owner', 'admin') then
    raise exception 'studio_access_detail: owner/admin only' using errcode = '42501';
  end if;
  select * into v_row from nomad_microweb.studio_access where organization_id = p_organization_id;
  if not found then
    return null;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- 개인정보 삭제 요청(owner/admin). 기능 잠금·허용 목록을 일부러 보지 않는다: 구독이 끊긴 조직도 삭제 요청은 처리할 수 있어야 한다.
create function nomad_microweb.delete_lead(p_lead_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.leads;
begin
  select * into v_row from nomad_microweb.leads where id = p_lead_id for update;
  if not found then raise exception 'delete_lead: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller()
     and coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin') then
    raise exception 'delete_lead: owner/admin only' using errcode = '42501';
  end if;
  delete from nomad_microweb.leads where id = p_lead_id;
  perform nomad_core.write_audit(v_row.organization_id, 'lead.delete', 'lead', p_lead_id::text,
                                 jsonb_build_object('status', v_row.status, 'created_at', v_row.created_at), null);
end;
$$;

-- 제작 주문 생성(금액 정수, 멱등 키 필수). 같은 키 재호출은 같은 요청이면 기존 행, 다르면 22023
create function nomad_microweb.create_order(
  p_organization_id uuid, p_customer_name text, p_amount_krw integer, p_idempotency_key text,
  p_template_code text default null, p_tier text default null, p_lead_id uuid default null,
  p_site_id uuid default null, p_note text default null
)
returns nomad_microweb.production_orders language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.production_orders;
begin
  perform nomad_microweb.require_org_role(p_organization_id, array['owner', 'admin'], 'create_order');
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 1 and 200 then
    raise exception 'create_order: idempotency key required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('microweb:create_order:' || p_organization_id::text || ':' || p_idempotency_key));
  select * into v_row from nomad_microweb.production_orders
   where organization_id = p_organization_id and idempotency_key = p_idempotency_key;
  if found then
    if v_row.customer_name = btrim(p_customer_name) and v_row.amount_krw = p_amount_krw
       and v_row.lead_id is not distinct from p_lead_id and v_row.site_id is not distinct from p_site_id
       and v_row.template_code is not distinct from p_template_code and v_row.tier is not distinct from p_tier then
      return v_row;
    end if;
    raise exception 'create_order: idempotency key reused with different request' using errcode = '22023';
  end if;
  if p_lead_id is not null and not exists (select 1 from nomad_microweb.leads l where l.id = p_lead_id and l.organization_id = p_organization_id) then
    raise exception 'create_order: lead not in organization' using errcode = '42501';
  end if;
  if p_site_id is not null and not exists (select 1 from nomad_microweb.sites s where s.id = p_site_id and s.organization_id = p_organization_id) then
    raise exception 'create_order: site not in organization' using errcode = '42501';
  end if;
  insert into nomad_microweb.production_orders (organization_id, lead_id, site_id, customer_name, template_code, tier, amount_krw,
                                                idempotency_key, note, created_by)
  values (p_organization_id, p_lead_id, p_site_id, btrim(p_customer_name), p_template_code, p_tier, p_amount_krw,
          p_idempotency_key, p_note, auth.uid())
  returning * into v_row;
  perform nomad_core.write_audit(p_organization_id, 'order.create', 'production_order', v_row.id::text, null,
                                 jsonb_build_object('amount_krw', p_amount_krw, 'tier', p_tier, 'template', p_template_code));
  return v_row;
end;
$$;

-- 주문 상태 전이. 이미 목표 상태면 그대로 돌려준다(재시도 멱등: 결제 시각을 다시 찍지 않는다)
create function nomad_microweb.transition_order(
  p_order_id uuid, p_to text, p_payment_method text default null, p_payment_reference text default null, p_note text default null
)
returns nomad_microweb.production_orders language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.production_orders; v_from text;
begin
  select * into v_row from nomad_microweb.production_orders where id = p_order_id for update;
  if not found then raise exception 'transition_order: not found' using errcode = 'P0002'; end if;
  perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin'], 'transition_order');
  if v_row.status = p_to then
    return v_row;
  end if;
  if p_to = 'paid' and coalesce(p_payment_method, '') = '' then
    raise exception 'transition_order: payment_method required' using errcode = '22023';
  end if;
  v_from := v_row.status;
  update nomad_microweb.production_orders
     set status = p_to,
         payment_method = case when p_to = 'paid' then p_payment_method else payment_method end,
         payment_reference = case when p_to = 'paid' then p_payment_reference else payment_reference end,
         paid_at = case when p_to = 'paid' then now() else paid_at end,
         in_production_at = case when p_to = 'in_production' then now() else in_production_at end,
         delivered_at = case when p_to = 'delivered' then now() else delivered_at end,
         closed_at = case when p_to = 'closed' then now() else closed_at end,
         canceled_at = case when p_to = 'canceled' then now() else canceled_at end,
         refunded_at = case when p_to = 'refunded' then now() else refunded_at end,
         note = coalesce(p_note, note)
   where id = p_order_id
  returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'order.' || p_to, 'production_order', p_order_id::text,
                                 jsonb_build_object('status', v_from),
                                 jsonb_build_object('status', p_to, 'amount_krw', v_row.amount_krw, 'payment_method', v_row.payment_method));
  return v_row;
end;
$$;

create function nomad_microweb.attach_order_site(p_order_id uuid, p_site_id uuid)
returns nomad_microweb.production_orders language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.production_orders;
begin
  select * into v_row from nomad_microweb.production_orders where id = p_order_id for update;
  if not found then raise exception 'attach_order_site: not found' using errcode = 'P0002'; end if;
  perform nomad_microweb.require_org_role(v_row.organization_id, array['owner', 'admin'], 'attach_order_site');
  -- 주문 1건당 사이트 1개: 같은 사이트 재호출은 그대로, 다른 사이트로 바꾸기는 거부
  if v_row.site_id = p_site_id then
    return v_row;
  end if;
  if v_row.site_id is not null then
    raise exception 'attach_order_site: order already has a site' using errcode = '22023';
  end if;
  if not exists (select 1 from nomad_microweb.sites s where s.id = p_site_id and s.organization_id = v_row.organization_id) then
    raise exception 'attach_order_site: site not in organization' using errcode = '42501';
  end if;
  update nomad_microweb.production_orders set site_id = p_site_id where id = p_order_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'order.attach_site', 'production_order', p_order_id::text, null,
                                 jsonb_build_object('site_id', p_site_id));
  return v_row;
end;
$$;

-- ---------- 16. service_role 전용 함수(Route Handler · 워커 · pg_cron). EXECUTE 1차 + is_service_caller 2차 잠금 ----------
-- 게시 요청. 호출자(p_actor_id)가 owner/admin 인지 다시 확인한다.
-- 대행 모드: 첫 게시는 결제된 제작 주문 + 고객 확인. 셀프 모드: 첫 게시는 이 사이트용 microweb consume 원장(미환불·미사용, 차감액 >= 템플릿 self_publish_credits).
--   원장 조건: consume_credits(p_product 'microweb', p_ref_type 'microweb_publish', p_ref_id = 사이트 id)가 돌려준 대표 행.
create function nomad_microweb.request_publish(p_site_id uuid, p_actor_id uuid, p_ledger_id uuid default null)
returns nomad_microweb.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites; v_access nomad_microweb.studio_access; v_price integer; v_paid integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'request_publish: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_microweb.sites where id = p_site_id for update;
  if not found then raise exception 'request_publish: not found' using errcode = 'P0002'; end if;
  if p_actor_id is null or not exists (
       select 1 from nomad_core.memberships m
       where m.organization_id = v_row.organization_id and m.user_id = p_actor_id and m.role in ('owner', 'admin')) then
    raise exception 'request_publish: owner/admin only' using errcode = '42501';
  end if;
  select * into v_access from nomad_microweb.studio_access where organization_id = v_row.organization_id and revoked_at is null;
  if not found or not nomad_core.org_has_feature(v_row.organization_id, 'microweb', 'studio') then
    raise exception 'request_publish: no studio access' using errcode = '42501';
  end if;
  if v_row.status not in ('draft', 'review', 'published', 'unpublished', 'expired') then
    raise exception 'request_publish: cannot publish from %', v_row.status using errcode = 'MW001';
  end if;
  if v_row.disclosure_consent_at is null then
    raise exception 'request_publish: disclosure consent required' using errcode = 'MW006';
  end if;
  if v_row.expires_at is null or v_row.expires_at <= now() then
    raise exception 'request_publish: expires_at must be in the future' using errcode = 'MW007';
  end if;
  if v_access.mode = 'agency' then
    if v_row.first_published_at is null then
      if not exists (select 1 from nomad_microweb.production_orders o
                     where o.site_id = v_row.id and o.status in ('paid', 'in_production', 'delivered', 'closed')) then
        raise exception 'request_publish: paid production order required' using errcode = 'MW008';
      end if;
      if v_row.customer_approved_at is null then
        raise exception 'request_publish: customer approval required' using errcode = 'MW009';
      end if;
    end if;
  else
    if v_row.publish_charged_at is null then
      if p_ledger_id is null or not exists (
           select 1 from nomad_core.credit_ledger l
           where l.id = p_ledger_id and l.organization_id = v_row.organization_id and l.product_code = 'microweb'
             and l.delta < 0 and l.refund_of is null
             and l.ref_type = 'microweb_publish' and l.ref_id = v_row.id::text) then
        raise exception 'request_publish: credit charge required' using errcode = 'MW008';
      end if;
      if exists (select 1 from nomad_core.credit_ledger r where r.refund_of = p_ledger_id)
         or exists (select 1 from nomad_microweb.sites s where s.publish_ledger_id = p_ledger_id and s.id <> v_row.id) then
        raise exception 'request_publish: ledger already refunded or used' using errcode = 'MW008';
      end if;
      -- 차감액(같은 멱등 키 묶음, plan·pack 두 행 합) >= 템플릿 셀프 발행 크레딧. 단가가 없는(null) 템플릿은 셀프 게시 불가
      select t.self_publish_credits into v_price from nomad_microweb.templates t where t.id = v_row.template_id;
      select coalesce(-sum(g.delta), 0)::integer into v_paid
        from nomad_core.credit_ledger l
        join nomad_core.credit_ledger g
          on g.organization_id = l.organization_id and g.idempotency_key = l.idempotency_key and g.delta < 0 and g.refund_of is null
       where l.id = p_ledger_id;
      if v_price is null or v_paid < v_price then
        raise exception 'request_publish: credit charge % below template price %', v_paid, v_price using errcode = 'MW008';
      end if;
    end if;
  end if;
  update nomad_microweb.sites
     set status = 'publishing',
         publish_requested_at = now(),
         publish_ledger_id = case when v_row.publish_charged_at is null and p_ledger_id is not null then p_ledger_id else publish_ledger_id end
   where id = p_site_id
  returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'site.publish_request', 'site', p_site_id::text, null,
                                 jsonb_build_object('actor', p_actor_id, 'mode', v_access.mode, 'ledger_id', p_ledger_id));
  return v_row;
end;
$$;

-- 워커가 공개 파생본 복사를 마친 뒤 호출. 스냅샷을 만들고 published 로 바꾼다
create function nomad_microweb.finalize_publish(
  p_site_id uuid, p_job_id uuid, p_content jsonb,
  p_og_title text default null, p_og_description text default null, p_og_image_url text default null
)
returns nomad_microweb.site_publications language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites; v_pub nomad_microweb.site_publications;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'finalize_publish: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_microweb.sites where id = p_site_id for update;
  if not found then raise exception 'finalize_publish: not found' using errcode = 'P0002'; end if;
  if v_row.status <> 'publishing' then
    raise exception 'finalize_publish: site is %', v_row.status using errcode = 'MW001';
  end if;
  insert into nomad_microweb.site_publications as p
    (site_id, organization_id, slug, version, content, og_title, og_description, og_image_url, is_live, published_at, expires_at, job_id)
  values
    (v_row.id, v_row.organization_id, v_row.slug, 1, p_content, p_og_title, p_og_description, p_og_image_url, true, now(), v_row.expires_at, p_job_id)
  on conflict (site_id) do update
    set version = p.version + 1, slug = excluded.slug, content = excluded.content,
        og_title = excluded.og_title, og_description = excluded.og_description, og_image_url = excluded.og_image_url,
        is_live = true, published_at = now(), expires_at = excluded.expires_at, unpublished_at = null, job_id = excluded.job_id
  returning * into v_pub;
  update nomad_microweb.sites
     set status = 'published',
         published_at = now(),
         first_published_at = coalesce(first_published_at, now()),
         publish_charged_at = case when publish_ledger_id is not null then coalesce(publish_charged_at, now()) else publish_charged_at end,
         publish_job_id = p_job_id,
         unpublished_at = null,
         expired_at = null
   where id = p_site_id;
  perform nomad_core.write_audit(v_row.organization_id, 'site.publish', 'site', p_site_id::text, null,
                                 jsonb_build_object('version', v_pub.version, 'job_id', p_job_id));
  return v_pub;
end;
$$;

-- 게시 잡 실패. 크레딧 환불은 nomad_core.fail_job 이 jobs.credit_ledger_id 로 처리한다. 여기서는 상태만 되돌린다
create function nomad_microweb.fail_publish(p_site_id uuid, p_error text default null)
returns nomad_microweb.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites; v_to text;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'fail_publish: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_microweb.sites where id = p_site_id for update;
  if not found then raise exception 'fail_publish: not found' using errcode = 'P0002'; end if;
  if v_row.status <> 'publishing' then
    return v_row;
  end if;
  v_to := case
    when exists (select 1 from nomad_microweb.site_publications p where p.site_id = p_site_id and p.is_live and p.expires_at > now()) then 'published'
    when v_row.expired_at is not null then 'expired'
    when v_row.first_published_at is not null then 'unpublished'
    else 'draft' end;
  update nomad_microweb.sites
     set status = v_to,
         publish_ledger_id = case when publish_charged_at is null then null else publish_ledger_id end
   where id = p_site_id
  returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'site.publish_failed', 'site', p_site_id::text, null,
                                 jsonb_build_object('status', v_to, 'error', left(coalesce(p_error, ''), 300)));
  return v_row;
end;
$$;

-- 고객 시안 확인(공개 /p/[token] 라우트가 토큰 해시로 호출)
create function nomad_microweb.record_customer_approval(p_token_hash text, p_name text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_microweb.sites;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_customer_approval: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_microweb.sites
   where preview_token_hash = p_token_hash and preview_token_expires_at > now() and status in ('draft', 'review')
   for update;
  if not found then
    raise exception 'record_customer_approval: invalid or expired token' using errcode = 'MW013';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 40 then
    raise exception 'record_customer_approval: name required' using errcode = '22023';
  end if;
  update nomad_microweb.sites set customer_approved_at = now(), customer_approved_name = btrim(p_name) where id = v_row.id;
  perform nomad_core.write_audit(v_row.organization_id, 'site.customer_approve', 'site', v_row.id::text);
  return v_row.id;
end;
$$;

-- 하객 방명록 등록(Route Handler 가 IP 해시를 계산해 호출). 예외 대신 결과 코드를 돌려줘 요청 제한 카운트가 롤백되지 않게 한다.
-- result: ok | closed | invalid | spam | rate_limited. 잠긴 조직(구독 끊김)·방명록 기능 없음은 closed
create function nomad_microweb.submit_guestbook_entry(
  p_slug text, p_author_name text, p_body text, p_relation text, p_ai_assisted boolean, p_ip_hash text
)
returns table (entry_id uuid, result text) language plpgsql security definer set search_path = ''
as $$
declare
  v_site nomad_microweb.sites; v_name text := btrim(coalesce(p_author_name, '')); v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'submit_guestbook_entry: service_role only' using errcode = '42501';
  end if;
  if p_ip_hash is null or char_length(p_ip_hash) not between 16 and 128 then
    return query select null::uuid, 'invalid'::text; return;
  end if;
  select s.* into v_site
    from nomad_microweb.site_publications p join nomad_microweb.sites s on s.id = p.site_id
   where p.slug = lower(btrim(coalesce(p_slug, ''))) and p.is_live and p.expires_at > now();
  if not found or not v_site.guestbook_enabled or not nomad_microweb.org_studio_open(v_site.organization_id)
     or not nomad_core.org_has_feature(v_site.organization_id, 'microweb', 'guestbook') then
    return query select null::uuid, 'closed'::text; return;
  end if;
  if not (select allowed from nomad_core.rate_limit_take('microweb:gb:ip:' || p_ip_hash || ':' || v_site.id::text, 3, 600))
     or not (select allowed from nomad_core.rate_limit_take('microweb:gb:site:' || v_site.id::text, 500, 86400)) then
    return query select null::uuid, 'rate_limited'::text; return;
  end if;
  if char_length(v_name) not between 1 and 20 or char_length(v_body) not between 1 and 500
     or (p_relation is not null and p_relation not in ('friend', 'colleague', 'family', 'acquaintance', 'other')) then
    return query select null::uuid, 'invalid'::text; return;
  end if;
  if v_body ~* '(https?://|www\.)' or v_name ~* '(https?://|www\.)'
     or exists (select 1 from nomad_microweb.guestbook_entries g
                 where g.site_id = v_site.id and g.ip_hash = p_ip_hash and g.body = v_body
                   and g.created_at > now() - interval '1 hour') then
    return query select null::uuid, 'spam'::text; return;
  end if;
  insert into nomad_microweb.guestbook_entries (organization_id, site_id, author_name, body, relation, ai_assisted, ip_hash)
  values (v_site.organization_id, v_site.id, v_name, v_body, p_relation, coalesce(p_ai_assisted, false), p_ip_hash)
  returning id into v_id;
  return query select v_id, 'ok'::text;
end;
$$;

-- 참석 여부 등록. result: ok | closed | invalid | rate_limited
create function nomad_microweb.submit_rsvp(
  p_slug text, p_guest_name text, p_side text, p_attending text, p_party_size integer,
  p_meal text, p_message text, p_ip_hash text
)
returns table (rsvp_id uuid, result text) language plpgsql security definer set search_path = ''
as $$
declare v_site nomad_microweb.sites; v_name text := btrim(coalesce(p_guest_name, '')); v_id uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'submit_rsvp: service_role only' using errcode = '42501';
  end if;
  if p_ip_hash is null or char_length(p_ip_hash) not between 16 and 128 then
    return query select null::uuid, 'invalid'::text; return;
  end if;
  select s.* into v_site
    from nomad_microweb.site_publications p join nomad_microweb.sites s on s.id = p.site_id
   where p.slug = lower(btrim(coalesce(p_slug, ''))) and p.is_live and p.expires_at > now();
  if not found or not v_site.rsvp_enabled or (v_site.event_at is not null and v_site.event_at <= now())
     or not nomad_microweb.org_studio_open(v_site.organization_id)
     or not nomad_core.org_has_feature(v_site.organization_id, 'microweb', 'rsvp') then
    return query select null::uuid, 'closed'::text; return;
  end if;
  if not (select allowed from nomad_core.rate_limit_take('microweb:rsvp:ip:' || p_ip_hash || ':' || v_site.id::text, 5, 3600))
     or not (select allowed from nomad_core.rate_limit_take('microweb:rsvp:site:' || v_site.id::text, 2000, 86400)) then
    return query select null::uuid, 'rate_limited'::text; return;
  end if;
  if char_length(v_name) not between 1 and 20
     or coalesce(p_side, 'none') not in ('side_a', 'side_b', 'none')
     or coalesce(p_attending, '') not in ('yes', 'no', 'undecided')
     or coalesce(p_party_size, 1) not between 1 and 10
     or (p_meal is not null and p_meal not in ('yes', 'no', 'undecided'))
     or (p_message is not null and char_length(p_message) > 200) then
    return query select null::uuid, 'invalid'::text; return;
  end if;
  insert into nomad_microweb.rsvp_responses (organization_id, site_id, guest_name, side, attending, party_size, meal, message, ip_hash)
  values (v_site.organization_id, v_site.id, v_name, coalesce(p_side, 'none'), p_attending, coalesce(p_party_size, 1), p_meal,
          nullif(btrim(coalesce(p_message, '')), ''), p_ip_hash)
  returning id into v_id;
  return query select v_id, 'ok'::text;
end;
$$;

-- 견적 문의 접수(공개 /contact). 개인정보 수집 동의 필수. result: ok | closed | invalid | spam | rate_limited
create function nomad_microweb.create_lead(
  p_organization_id uuid, p_source text, p_name text, p_phone text, p_email text, p_kind text,
  p_template_code text, p_tier text, p_industry text, p_event_on date, p_simulator jsonb,
  p_message text, p_privacy_consent boolean, p_ip_hash text
)
returns table (lead_id uuid, result text) language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'create_lead: service_role only' using errcode = '42501';
  end if;
  if not exists (select 1 from nomad_microweb.studio_access a
                  where a.organization_id = p_organization_id and a.revoked_at is null and a.mode = 'agency')
     or not nomad_core.org_has_feature(p_organization_id, 'microweb', 'studio') then
    return query select null::uuid, 'closed'::text; return;
  end if;
  if p_ip_hash is null or char_length(p_ip_hash) not between 16 and 128 or coalesce(p_privacy_consent, false) is false then
    return query select null::uuid, 'invalid'::text; return;
  end if;
  if not (select allowed from nomad_core.rate_limit_take('microweb:lead:ip:' || p_ip_hash, 3, 600))
     or not (select allowed from nomad_core.rate_limit_take('microweb:lead:org:' || p_organization_id::text, 300, 86400)) then
    return query select null::uuid, 'rate_limited'::text; return;
  end if;
  if coalesce(p_message, '') ~* '(https?://|www\.).*(https?://|www\.).*(https?://|www\.)' then
    return query select null::uuid, 'spam'::text; return;
  end if;
  begin
    insert into nomad_microweb.leads (organization_id, source, name, phone, email, kind, template_code, tier, industry, event_on,
                                      simulator, message, privacy_consent_at, ip_hash)
    values (p_organization_id, coalesce(p_source, 'contact_form'), btrim(coalesce(p_name, '')), nullif(btrim(coalesce(p_phone, '')), ''),
            nullif(lower(btrim(coalesce(p_email, ''))), ''), p_kind, p_template_code, p_tier, p_industry, p_event_on,
            coalesce(p_simulator, '{}'::jsonb), nullif(btrim(coalesce(p_message, '')), ''), now(), p_ip_hash)
    returning id into v_id;
  exception when check_violation or not_null_violation then
    return query select null::uuid, 'invalid'::text; return;
  end;
  return query select v_id, 'ok'::text;
end;
$$;

-- 하객 음성 연결(원본 20.4). 같은 조직·제품 microweb·기능 microweb_guestbook_voice·STT·성공·보관·하객 고지(third_party_notice) 작업만.
-- result: ok | not_found | invalid | already | closed(잠긴 조직·guestbook_voice 없음)
create function nomad_microweb.attach_guestbook_voice(p_entry_id uuid, p_voice_job_id uuid)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_entry nomad_microweb.guestbook_entries; v_job nomad_core.voice_jobs;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'attach_guestbook_voice: service_role only' using errcode = '42501';
  end if;
  select * into v_entry from nomad_microweb.guestbook_entries where id = p_entry_id for update;
  if not found then return 'not_found'; end if;
  if not nomad_microweb.org_studio_open(v_entry.organization_id)
     or not nomad_core.org_has_feature(v_entry.organization_id, 'microweb', 'guestbook_voice') then
    return 'closed';
  end if;
  select * into v_job from nomad_core.voice_jobs where id = p_voice_job_id;
  if not found then return 'not_found'; end if;
  if v_job.organization_id <> v_entry.organization_id or v_job.product_code <> 'microweb' or v_job.feature <> 'microweb_guestbook_voice'
     or v_job.kind <> 'stt' or not v_job.store_audio or v_job.consent_kind is distinct from 'third_party_notice'
     or v_job.status <> 'succeeded' then
    return 'invalid';
  end if;
  if v_entry.voice_job_id is not null
     or exists (select 1 from nomad_microweb.guestbook_entries g where g.voice_job_id = p_voice_job_id) then
    return 'already';
  end if;
  update nomad_microweb.guestbook_entries set voice_job_id = p_voice_job_id where id = p_entry_id;
  perform nomad_core.write_audit(v_entry.organization_id, 'guestbook.voice_attach', 'guestbook_entry', p_entry_id::text,
                                 null, jsonb_build_object('voice_job_id', p_voice_job_id));
  return 'ok';
end;
$$;

-- 만료 처리(pg_cron 또는 워커, 매 10분). 만료된 사이트 id 를 돌려주면 워커가 공개 파생본 삭제 잡을 넣는다.
-- 30분 넘게 publishing 에 머문 사이트는 fail_publish 로 되돌린다. 플랜과 무관하게 돈다
create function nomad_microweb.expire_sites()
returns setof uuid language plpgsql security definer set search_path = ''
as $$
declare v_site record;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'expire_sites: service_role only' using errcode = '42501';
  end if;
  for v_site in
    select id, organization_id from nomad_microweb.sites
     where status in ('published', 'unpublished') and expires_at <= now()
     for update skip locked
  loop
    update nomad_microweb.sites set status = 'expired', expired_at = now() where id = v_site.id;
    update nomad_microweb.site_publications set is_live = false, unpublished_at = coalesce(unpublished_at, now()) where site_id = v_site.id;
    perform nomad_core.write_audit(v_site.organization_id, 'site.expired', 'site', v_site.id::text);
    return next v_site.id;
  end loop;
  for v_site in
    select id from nomad_microweb.sites
     where status = 'publishing' and publish_requested_at < now() - interval '30 minutes'
     for update skip locked
  loop
    perform nomad_microweb.fail_publish(v_site.id, 'stale publishing (30 min)');
  end loop;
  return;
end;
$$;

-- 보존 기간 경과 데이터 삭제(매일). 견적 문의 purge_after, 만료 180일·보관 30일 지난 사이트의 하객 데이터. 플랜과 무관
create function nomad_microweb.purge_expired_data()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_leads integer; v_guestbook integer; v_rsvp integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_expired_data: service_role only' using errcode = '42501';
  end if;
  delete from nomad_microweb.leads where purge_after < now();
  get diagnostics v_leads = row_count;
  delete from nomad_microweb.guestbook_entries g using nomad_microweb.sites s
   where g.site_id = s.id
     and ((s.status = 'expired' and s.expired_at < now() - interval '180 days')
       or (s.status = 'archived' and s.archived_at < now() - interval '30 days'));
  get diagnostics v_guestbook = row_count;
  delete from nomad_microweb.rsvp_responses r using nomad_microweb.sites s
   where r.site_id = s.id
     and ((s.status = 'expired' and s.expired_at < now() - interval '180 days')
       or (s.status = 'archived' and s.archived_at < now() - interval '30 days'));
  get diagnostics v_rsvp = row_count;
  if v_leads + v_guestbook + v_rsvp > 0 then
    perform nomad_core.write_audit(null, 'microweb.purge', 'microweb', null, null,
                                   jsonb_build_object('leads', v_leads, 'guestbook', v_guestbook, 'rsvp', v_rsvp));
  end if;
  return jsonb_build_object('leads', v_leads, 'guestbook', v_guestbook, 'rsvp', v_rsvp);
end;
$$;

-- ---------- 17. 공개 RPC (D8): 방문자(anon)의 유일한 경로. 읽기 전용, 입력 검증. DB 요청 제한 없음(보안 리뷰: 사이트·slug 키는 anon 한 명이 남의 청첩장을 닫을 수 있다) —
-- 과부하는 앞단 CDN 캐시·WAF 몫. 게시 중 열람은 구독 잠김과 무관(사용자 결정) ----------
-- 원본 anon 직접 SELECT(templates·portfolio_items·site_publications·guestbook_entries 공개 컬럼)를 대체한다. 하객 쓰기는 위 service_role 함수(IP 해시는 서버가 계산).

-- 템플릿 카탈로그(retired 제외)
create function nomad_microweb.list_public_templates()
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  return jsonb_build_object('ok', true, 'templates', coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', t.code, 'kind', t.kind, 'name', t.name, 'summary', t.summary, 'status', t.status,
             'release_phase', t.release_phase, 'agency_price_min_krw', t.agency_price_min_krw,
             'agency_price_max_krw', t.agency_price_max_krw, 'price_note', t.price_note,
             'self_publish_credits', t.self_publish_credits, 'allowed_blocks', t.allowed_blocks,
             'required_blocks', t.required_blocks, 'preview_mockup', t.preview_mockup, 'sort_order', t.sort_order)
           order by t.sort_order, t.code)
    from nomad_microweb.templates t where t.status <> 'retired'), '[]'::jsonb));
end;
$$;

-- 쇼룸 포트폴리오(published). p_category: null | microweb | website | detail_page
create function nomad_microweb.list_public_portfolio(p_category text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if p_category is not null and p_category not in ('microweb', 'website', 'detail_page') then
    return jsonb_build_object('ok', false, 'code', 'invalid');
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'slug', i.slug, 'title', i.title, 'category', i.category, 'tier', i.tier, 'industry', i.industry,
             'summary', i.summary, 'external_url', i.external_url, 'image_path', i.image_path, 'sort_order', i.sort_order)
           order by i.sort_order, i.slug)
    from nomad_microweb.portfolio_items i
    where i.status = 'published' and (p_category is null or i.category = p_category)), '[]'::jsonb));
end;
$$;

-- 게시 중 스냅샷 1건(/i/[slug]). 없음·만료·게시 중지·조직 비활성은 모두 not_found(존재 여부를 구분하지 않는다).
-- 구독이 끊긴(잠긴) 조직도 이미 게시된 사이트는 열람 유지(사용자 결정 2026-11-14). 단 guestbook_open·rsvp_open 은 false.
create function nomad_microweb.get_public_site(p_slug text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_slug text := lower(btrim(coalesce(p_slug, ''))); v_pub nomad_microweb.site_publications; v_site nomad_microweb.sites;
begin
  if v_slug !~ '^[a-z0-9][a-z0-9-]{2,38}[a-z0-9]$' then
    return jsonb_build_object('ok', false, 'code', 'invalid');
  end if;
  select * into v_pub from nomad_microweb.site_publications p where p.slug = v_slug and p.is_live and p.expires_at > now();
  if found then
    select * into v_site from nomad_microweb.sites s where s.id = v_pub.site_id;
  end if;
  if v_pub.site_id is null or not nomad_microweb.is_site_live(v_pub.site_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'site', jsonb_build_object(
    'site_id', v_pub.site_id, 'slug', v_pub.slug, 'version', v_pub.version, 'content', v_pub.content,
    'og_title', v_pub.og_title, 'og_description', v_pub.og_description, 'og_image_url', v_pub.og_image_url,
    'published_at', v_pub.published_at, 'expires_at', v_pub.expires_at, 'noindex', v_site.noindex,
    -- 쓰기 가능 여부(잠긴 조직이면 false — 열람만 유지)
    'guestbook_open', v_site.guestbook_enabled and nomad_microweb.org_studio_open(v_pub.organization_id)
                      and nomad_core.org_has_feature(v_pub.organization_id, 'microweb', 'guestbook'),
    'rsvp_open', v_site.rsvp_enabled and (v_site.event_at is null or v_site.event_at > now())
                 and nomad_microweb.org_studio_open(v_pub.organization_id)
                 and nomad_core.org_has_feature(v_pub.organization_id, 'microweb', 'rsvp')));
end;
$$;

-- 공개 방명록(visible 만, ip_hash·작성자 식별 정보 없음). 커서 p_before(created_at), 1~50건
create function nomad_microweb.list_public_guestbook(p_slug text, p_before timestamptz default null, p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_slug text := lower(btrim(coalesce(p_slug, ''))); v_site_id uuid;
begin
  if v_slug !~ '^[a-z0-9][a-z0-9-]{2,38}[a-z0-9]$' then
    return jsonb_build_object('ok', false, 'code', 'invalid');
  end if;
  select p.site_id into v_site_id from nomad_microweb.site_publications p where p.slug = v_slug;
  if v_site_id is null or not nomad_microweb.is_guestbook_public(v_site_id) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'author_name', e.author_name, 'body', e.body, 'relation', e.relation,
                                        'ai_assisted', e.ai_assisted, 'has_voice', e.has_voice, 'created_at', e.created_at)
                     order by e.created_at desc)
    from (select g.* from nomad_microweb.guestbook_entries g
           where g.site_id = v_site_id and g.status = 'visible' and (p_before is null or g.created_at < p_before)
           order by g.created_at desc
           limit least(greatest(coalesce(p_limit, 20), 1), 50)) e), '[]'::jsonb));
end;
$$;

-- ---------- 18. EXECUTE 정리: 전부 회수 후 허용 목록만 ----------
revoke all on all functions in schema nomad_microweb from public, anon, authenticated;
-- 공개(anon·authenticated·service_role): 읽기 RPC 4개
grant execute on function
  nomad_microweb.list_public_templates(), nomad_microweb.list_public_portfolio(text),
  nomad_microweb.get_public_site(text), nomad_microweb.list_public_guestbook(text, timestamptz, integer)
  to anon, authenticated, service_role;
-- 정책 헬퍼(authenticated 정책에서 호출)
grant execute on function nomad_microweb.has_studio_access(uuid) to authenticated, service_role;
-- 사용자 RPC
grant execute on function
  nomad_microweb.create_site(uuid, text, text, text, timestamptz), nomad_microweb.transition_site(uuid, text, text),
  nomad_microweb.issue_preview_token(uuid, integer), nomad_microweb.confirm_disclosure_consent(uuid, text),
  nomad_microweb.moderate_guestbook_entry(uuid, text), nomad_microweb.set_lead_status(uuid, text, text),
  nomad_microweb.delete_lead(uuid), nomad_microweb.studio_access_detail(uuid),
  nomad_microweb.create_order(uuid, text, integer, text, text, text, uuid, uuid, text),
  nomad_microweb.transition_order(uuid, text, text, text, text), nomad_microweb.attach_order_site(uuid, uuid)
  to authenticated, service_role;
-- service_role 전용
grant execute on function
  nomad_microweb.is_site_live(uuid), nomad_microweb.is_guestbook_public(uuid), nomad_microweb.org_studio_open(uuid),
  nomad_microweb.request_publish(uuid, uuid, uuid),
  nomad_microweb.finalize_publish(uuid, uuid, jsonb, text, text, text), nomad_microweb.fail_publish(uuid, text),
  nomad_microweb.record_customer_approval(text, text),
  nomad_microweb.submit_guestbook_entry(text, text, text, text, boolean, text),
  nomad_microweb.submit_rsvp(text, text, text, text, integer, text, text, text),
  nomad_microweb.create_lead(uuid, text, text, text, text, text, text, text, text, date, jsonb, text, boolean, text),
  nomad_microweb.attach_guestbook_voice(uuid, uuid),
  nomad_microweb.expire_sites(), nomad_microweb.purge_expired_data()
  to service_role;

-- ---------- 19. 템플릿 카탈로그 기준 데이터(원본 nexus 12개 모델). 가격·셀프 발행 크레딧 수치는 넣지 않는다(열린 결정, existing.md) ----------
insert into nomad_microweb.templates (code, kind, name, summary, status, release_phase, allowed_blocks, required_blocks, sort_order)
values
  ('wedding_classic', 'wedding', '모바일 청첩장', '사진, 인사말, 달력, 오시는 길, 연락처와 계좌, 방명록을 담는 예식 안내 페이지', 'beta', 'mvp',
   array['hero', 'greeting', 'hosts', 'calendar', 'gallery', 'location', 'transport', 'contacts', 'accounts', 'wreath', 'guestbook', 'rsvp', 'bgm', 'notice', 'share'],
   array['hero', 'greeting', 'calendar', 'location', 'share'], 0),
  ('dol_basic', 'dol', '모바일 돌잔치 초대장', '아이 사진, 성장 타임라인, 일시와 장소 안내', 'planned', 'phase2',
   array['hero', 'greeting', 'timeline', 'calendar', 'gallery', 'location', 'transport', 'contacts', 'accounts', 'guestbook', 'rsvp', 'bgm', 'notice', 'share'],
   array['hero', 'greeting', 'calendar', 'location', 'share'], 1),
  ('obituary_basic', 'obituary', '모바일 부고장', '고인 안내, 빈소와 발인 정보, 조의금 계좌', 'planned', 'phase2',
   array['memorial', 'funeral_info', 'location', 'transport', 'contacts', 'accounts', 'guestbook', 'notice', 'share'],
   array['memorial', 'funeral_info', 'location', 'share'], 2),
  ('mini_home', 'mini_home', '소상공인 미니 홈피', '영업 정보, 메뉴/서비스, 예약과 문의 버튼', 'planned', 'phase3', '{}', '{}', 3),
  ('event_notice', 'event', '행사/세미나 안내장', '행사 일정, 장소, 사전 등록 안내', 'planned', 'phase3', '{}', '{}', 4),
  ('business_card', 'business_card', '디지털 명함', '연락처와 링크를 모은 개인 페이지', 'planned', 'backlog', '{}', '{}', 5),
  ('real_estate', 'real_estate', '부동산 모바일 전단', '매물 소개와 문의', 'planned', 'backlog', '{}', '{}', 6),
  ('freelancer_portfolio', 'portfolio', '프리랜서 포트폴리오', '작업 사례와 연락처', 'planned', 'backlog', '{}', '{}', 7),
  ('rolling_paper', 'rolling_paper', '온라인 롤링페이퍼', '여러 사람이 남기는 축하 메시지 모음', 'planned', 'backlog', '{}', '{}', 8),
  ('qr_menu', 'qr_menu', '모바일 메뉴판(QR)', '매장 메뉴와 가격', 'planned', 'backlog', '{}', '{}', 9),
  ('pet_profile', 'pet_profile', '반려동물 QR 프로필', '보호자 연락처와 건강 정보', 'planned', 'backlog', '{}', '{}', 10),
  ('online_gallery', 'gallery', '온라인 전시/갤러리', '작품 소개와 도슨트', 'planned', 'backlog', '{}', '{}', 11)
on conflict (code) do nothing;

commit;
