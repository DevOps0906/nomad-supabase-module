-- FLORA Publishing 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/1000_publishing.sql 0~14·16장(13표)
-- D9: platform-docs 기준으로 새로 작성(supabase/migrations/*_flora.sql 청사진은 참고만, 같은 스키마 이름이라 검사는 청사진을 drop 한 뒤 적용).
-- core.organizations→nomad_core.organizations, org_members(member)→nomad_core.memberships(editor), has_entitlement→nomad_core.has_feature,
-- core.jobs·credit_ledger·ai_runs·encrypted_credentials→nomad_core.jobs·credit_ledger(uuid)·ai_runs·provider_credentials, core.write_audit→nomad_core.write_audit,
-- 플랜 features jsonb → A/B/C 기능(features) + plan_limits 키(수치 시드 안 함, 없으면 원본 free 값). 대응표: products/flora/existing.md
-- AI 라우팅·AI 기능(원본 15장)은 org/0002_ai.sql. 전제: core 20261119000100(touch_updated_at) · 20261120000100~0600(audit·credits·jobs·ai·affiliate 복합 키) · 20261120000800(mark_job_delivered).
-- 되돌림: drop schema nomad_flora cascade; delete from storage.buckets where id in ('flora-files', 'flora-exports');
--   delete from nomad_core.plan_features where product_code = 'flora' and feature_code in (아래 11개); delete from nomad_core.features where …(같은 목록);
--   (api_providers 'outbound_webhook' 1행은 남겨도 무해)
-- SQLSTATE(원본 유지): PB001 책 한도 · PB002 챕터 한도 · PB003 소제목 한도 · PB004 단락 한도 · PB005 생성 중 편집 · PB006 표지 · PB007 실행 비활성
--   · PB008 테마 · PB009 공개 페이지 · PB010 복원 · PB011 페르소나 잠금 · PB012 검수 대기 아님 · PB013 재시도 불가 · 22023 상태 전이
--   · (이식 추가) PB014 플랜 기능 잠김 · PB015 작업이 이미 실패·취소(결과 저장 거부)
begin;

create schema nomad_flora;
revoke all on schema nomad_flora from public, anon, authenticated;
grant usage on schema nomad_flora to anon, authenticated, service_role;  -- anon: 공개 읽기 RPC get_public_book 하나만(D8), 표 권한 0
alter default privileges in schema nomad_flora revoke execute on functions from public;
comment on schema nomad_flora is 'FLORA Publishing: AI 책 쓰기(책·목차·원고·표지·내보내기·전체 생성·에이전트 작업)';

insert into nomad_core.products (code, name) values ('flora', 'FLORA Publishing') on conflict (code) do nothing;
-- 플랜: 원본은 free·basic 두 개. basic→A·B(같은 기능), free→C. 구독이 끊기면(구독 없음·inactive·만료 = C) 원본 free 기능만 남는다.
insert into nomad_core.plans (product_code, code, name) values ('flora', 'A', 'A'), ('flora', 'B', 'B'), ('flora', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('flora', 'flora', 'FLORA 작업 공간'),
  ('flora', 'no_watermark', '워터마크 없는 내보내기'),
  ('flora', 'themes_pro', '프로 화면 테마'),
  ('flora', 'write_all', '전체 순차 생성·전체 다듬기'),
  ('flora', 'upload', '원고 업로드'),
  ('flora', 'tone_slider', '어조 슬라이더'),
  ('flora', 'writing_assist', '보조 집필(이어쓰기·살붙이기·다듬기)'),
  ('flora', 'quality_mode', 'quality 모드'),
  ('flora', 'persona_blend', '나만의 페르소나 합성'),
  ('flora', 'webhooks', '발신 웹훅'),
  ('flora', 'public_page', '공개 책 페이지')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'flora', p, 'flora' from unnest(array['A', 'B', 'C']) p
union all
select 'flora', p, f from unnest(array['A', 'B']) p,
  unnest(array['no_watermark', 'themes_pro', 'write_all', 'upload', 'tone_slider', 'writing_assist', 'quality_mode',
               'persona_blend', 'webhooks', 'public_page']) f
on conflict do nothing;
-- plan_limits 키(수치 시드 안 함, 없으면 원본 free 값): max_books(3) · max_chapters(3) · max_sections(6) · max_paragraphs(3)
--   · exports_per_month(2, 서버) · personas(40, 서버) (existing.md 표)
-- 웹훅 서명 비밀은 nomad_core.provider_credentials(Vault)에만. 제공자 코드를 등록한다(표시 이름만).
insert into nomad_core.api_providers (code, name) values ('outbound_webhook', '발신 웹훅 서명 비밀') on conflict (code) do nothing;

-- =====================================================================
-- 1. 도우미
-- =====================================================================
-- 정책용(사용자 문맥): 기능 이용권 + 멤버십(has_feature가 둘 다 본다, 조직 비활성 = 거짓)
create function nomad_flora.has_access(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.has_feature(target_organization, 'flora', 'flora'), false) $$;

-- 쓰기: owner·admin·editor(원본 member) + 이용권
create function nomad_flora.can_edit(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin', 'editor'), false)
     and nomad_flora.has_access(target_organization)
$$;

-- 관리: owner·admin + 이용권(책·페르소나 삭제, 웹훅 보기)
create function nomad_flora.can_manage(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin'), false)
     and nomad_flora.has_access(target_organization)
$$;

-- 서버·트리거 전용(사용자 실행 권한 없음): 수량 한도(plan_limits, 없으면 원본 free 값) · 기능(조직 활성 포함, 멤버십 무관)
create function nomad_flora.limit_of(target_organization uuid, target_key text, fallback integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_plan_limit(target_organization, 'flora', target_key), fallback) $$;

create function nomad_flora.org_feature(target_organization uuid, target_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_has_feature(target_organization, 'flora', target_feature), false) $$;

-- 화면 테마: basic 3종은 모든 플랜, pro 4종은 기능 themes_pro
create function nomad_flora.theme_allowed(target_organization uuid, p_theme_key text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select case
    when p_theme_key in ('flora-dark', 'minimal-light', 'warm-serif') then true
    when p_theme_key in ('lunaris-dark', 'halo-dev', 'nitro-enterprise', 'hero-analytics') then nomad_flora.org_feature(target_organization, 'themes_pro')
    else false end
$$;

-- =====================================================================
-- 2. 표 (원본 1~10·16장, 13개)
-- =====================================================================
-- 2.1 custom_personas: 나만의 페르소나(합성 결과). 생성은 서버(LLM 합성), 사용자는 이름·보관만.
create table nomad_flora.custom_personas (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  name             text not null constraint custom_personas_name_check check (char_length(name) between 1 and 60),
  base_persona_ids text[] not null default '{}' constraint custom_personas_base_check check (cardinality(base_persona_ids) <= 3),
  taste_config     jsonb not null,
  status           text not null default 'active' constraint custom_personas_status_check check (status in ('active', 'archived')),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, organization_id)
);
create index custom_personas_org_updated_idx on nomad_flora.custom_personas (organization_id, updated_at);
comment on table nomad_flora.custom_personas is '나만의 페르소나(합성 결과). INSERT는 서버만(기능 persona_blend), 사용자는 이름·보관·삭제.';

-- 2.2 books: 책 1권 = 프로젝트 1개. 위저드 10단계 상태와 책 정보. 사용자 쓰기는 컬럼 GRANT(콘텐츠 컬럼).
create table nomad_flora.books (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  title              text not null default '제목 없음' constraint books_title_check check (char_length(title) between 1 and 200),
  subtitle           text constraint books_subtitle_check check (char_length(subtitle) <= 200),
  author_name        text constraint books_author_name_check check (char_length(author_name) <= 100),
  genre              text constraint books_genre_check check (genre in
                     ('novel', 'essay', 'poetry', 'self_help', 'nonfiction_business', 'it_tech', 'children', 'fantasy_genre')),
  format_key         text not null default 'A5'
                     constraint books_format_key_check check (format_key in ('A6', 'B6', 'A5', 'shinkuk', 'B5', 'A4_variant')),
  persona_id         text constraint books_persona_id_check check (char_length(persona_id) <= 64),
  custom_persona_id  uuid,
  taste_config       jsonb,
  tone               jsonb not null default '{}'::jsonb,
  layout_settings    jsonb not null default '{}'::jsonb,
  plan_brief         jsonb,
  book_info          jsonb not null default '{}'::jsonb,
  step_state         jsonb not null default '{}'::jsonb,
  current_step       smallint not null default 1 constraint books_current_step_check check (current_step between 1 and 10),
  source             text not null default 'wizard' constraint books_source_check check (source in ('wizard', 'upload', 'seed')),
  seed_key           text constraint books_seed_key_check check (seed_key in ('seed_01', 'seed_02', 'seed_03')),
  cover_image_id     uuid,
  status             text not null default 'draft'
                     constraint books_status_check check (status in ('draft', 'writing', 'ready', 'completed', 'archived')),
  writing_started_at timestamptz,
  completed_at       timestamptz,
  is_public          boolean not null default false,
  slug               text unique constraint books_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
  published_at       timestamptz,
  word_count         integer not null default 0 constraint books_word_count_check check (word_count >= 0),
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz,
  unique (id, organization_id),
  constraint books_custom_persona_fk foreign key (custom_persona_id, organization_id)
    references nomad_flora.custom_personas (id, organization_id),
  constraint books_public_check check (not is_public or slug is not null)
);
-- 증분 동기화(소프트 삭제 행 포함)
create index books_org_updated_idx on nomad_flora.books (organization_id, updated_at);
create index books_org_status_idx on nomad_flora.books (organization_id, status) where deleted_at is null;
create index books_deleted_idx on nomad_flora.books (deleted_at) where deleted_at is not null;
comment on table nomad_flora.books is '책 1권 = 프로젝트 1개(위저드 상태·책 정보). 소프트 삭제(deleted_at). 공개 페이지는 get_public_book RPC로만.';

-- 2.3 chapters / sections: 목차와 원고(소제목 단위). body_html은 서버 sanitize 후 저장, 렌더 시 재-sanitize.
create table nomad_flora.chapters (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id         uuid not null,
  position        smallint not null constraint chapters_position_check check (position between 1 and 20),
  title           text not null constraint chapters_title_check check (char_length(title) between 1 and 200),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  unique (id, book_id),
  constraint chapters_book_position_uniq unique (book_id, position) deferrable initially deferred,
  constraint chapters_book_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete cascade
);
create index chapters_org_updated_idx on nomad_flora.chapters (organization_id, updated_at);
comment on table nomad_flora.chapters is '책의 챕터(목차). 편집자 CRUD, 책당 개수는 plan_limits max_chapters.';

create table nomad_flora.sections (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id          uuid not null,
  chapter_id       uuid not null,
  position         smallint not null constraint sections_position_check check (position between 1 and 10),
  title            text not null constraint sections_title_check check (char_length(title) between 1 and 200),
  paragraph_target smallint not null default 2 constraint sections_paragraph_target_check check (paragraph_target between 1 and 5),
  body_html        text not null default '' constraint sections_body_size_check check (octet_length(body_html) <= 200000),
  char_count       integer not null default 0,
  gen_status       text not null default 'empty'
                   constraint sections_gen_status_check check (gen_status in ('empty', 'queued', 'generating', 'generated', 'edited', 'failed')),
  last_job_id      uuid,
  last_error       text,
  revision         integer not null default 0,
  updated_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, organization_id),
  constraint sections_chapter_position_uniq unique (chapter_id, position) deferrable initially deferred,
  constraint sections_chapter_fk foreign key (chapter_id, book_id) references nomad_flora.chapters (id, book_id) on delete cascade,
  constraint sections_org_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete cascade,
  constraint sections_job_fk foreign key (last_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (last_job_id)
);
create index sections_book_idx on nomad_flora.sections (book_id, chapter_id, position);
create index sections_org_updated_idx on nomad_flora.sections (organization_id, updated_at);
create index sections_job_idx on nomad_flora.sections (last_job_id) where last_job_id is not null;
comment on table nomad_flora.sections is '소제목 단위 원고. 사용자 편집 = edited, 서버 생성 결과 = generated(작업 실패·취소면 거부).';

-- 2.4 cover_images: AI 표지 후보. 서버만 쓴다. 파일은 버킷 flora-files(<org>/flora/covers/…).
create table nomad_flora.cover_images (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id         uuid not null,
  style           text not null constraint cover_images_style_check check (style in ('illustration', 'photo', 'minimal', 'typography', 'watercolor')),
  provider        text not null default 'fal',
  model           text,
  prompt          text constraint cover_images_prompt_check check (char_length(prompt) <= 4000),
  storage_path    text constraint cover_images_path_check check (storage_path is null or (split_part(storage_path, '/', 1) = organization_id::text
                                                                                       and split_part(storage_path, '/', 2) = 'flora')),
  width           integer,
  height          integer,
  status          text not null default 'queued' constraint cover_images_status_check check (status in ('queued', 'running', 'succeeded', 'failed')),
  job_id          uuid,
  error           text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint cover_images_book_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete cascade,
  constraint cover_images_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create index cover_images_book_idx on nomad_flora.cover_images (book_id, created_at desc);
create index cover_images_org_idx on nomad_flora.cover_images (organization_id, created_at desc);
comment on table nomad_flora.cover_images is 'AI 표지 후보. 서버 쓰기만, 이용권 멤버 읽기.';

alter table nomad_flora.books add constraint books_cover_image_fk
  foreign key (cover_image_id, organization_id) references nomad_flora.cover_images (id, organization_id) on delete set null (cover_image_id);

-- 2.5 manuscript_uploads: 원고 업로드. 원본 파일은 flora-files(<org>/flora/manuscripts/<uuid>.<ext>), 서버가 서명 업로드 URL 발급.
create table nomad_flora.manuscript_uploads (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id         uuid,
  storage_path    text not null unique
                  constraint manuscript_uploads_path_check check (split_part(storage_path, '/', 1) = organization_id::text
                                                                 and split_part(storage_path, '/', 2) = 'flora'),
  original_name   text constraint manuscript_uploads_name_check check (char_length(original_name) <= 255),
  ext             text not null constraint manuscript_uploads_ext_check check (ext in ('txt', 'md', 'docx', 'pdf')),
  mime            text,
  bytes           integer constraint manuscript_uploads_bytes_check check (bytes between 1 and 20971520),
  status          text not null default 'pending_upload'
                  constraint manuscript_uploads_status_check check (status in ('pending_upload', 'uploaded', 'parsing', 'parsed', 'failed', 'expired')),
  parsed_outline  jsonb,
  char_count      integer,
  error           text,
  job_id          uuid,
  raw_deleted_at  timestamptz,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint manuscript_uploads_book_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete set null (book_id),
  constraint manuscript_uploads_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create index manuscript_uploads_org_idx on nomad_flora.manuscript_uploads (organization_id, created_at desc);
comment on table nomad_flora.manuscript_uploads is '원고 업로드(기능 upload). 파싱은 워커(flora.parse_manuscript). 서버 쓰기만.';

-- 2.6 book_exports: PDF/ePub 내보내기. 파일은 flora-exports. 서버만 쓴다. 같은 content_hash·성공·만료 전이면 재과금 없이 재사용(서버).
create table nomad_flora.book_exports (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id          uuid not null,
  format           text not null constraint book_exports_format_check check (format in ('pdf', 'epub')),
  status           text not null default 'queued'
                   constraint book_exports_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled', 'expired')),
  job_id           uuid,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  content_hash     text not null,
  watermark        boolean not null,
  preset           jsonb not null,
  storage_path     text constraint book_exports_path_check check (storage_path is null or (split_part(storage_path, '/', 1) = organization_id::text
                                                                                        and split_part(storage_path, '/', 2) = 'flora')),
  bytes            bigint,
  pages            integer,
  error            text,
  requested_by     uuid,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  expires_at       timestamptz,
  updated_at       timestamptz not null default now(),
  constraint book_exports_book_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete cascade,
  constraint book_exports_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create index book_exports_book_idx on nomad_flora.book_exports (book_id, created_at desc);
create index book_exports_reuse_idx on nomad_flora.book_exports (book_id, format, content_hash) where status = 'succeeded';
create index book_exports_org_month_idx on nomad_flora.book_exports (organization_id, created_at) where status in ('queued', 'running', 'succeeded');
create index book_exports_expiry_idx on nomad_flora.book_exports (expires_at) where status = 'succeeded';
comment on table nomad_flora.book_exports is 'PDF/ePub 내보내기 기록(워터마크 없음 = 기능 no_watermark). 서버 쓰기만.';

-- 2.7 generation_runs: 전체 순차 생성(write_all)·전체 다듬기(refine_all). 부모 작업 1 + 섹션별 자식 작업. 책당 진행 중 1개.
create table nomad_flora.generation_runs (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id             uuid not null,
  kind                text not null constraint generation_runs_kind_check check (kind in ('write_all', 'refine_all')),
  mode                text not null default 'fast' constraint generation_runs_mode_check check (mode in ('fast', 'quality')),
  parent_job_id       uuid,
  status              text not null default 'queued'
                      constraint generation_runs_status_check check (status in ('queued', 'running', 'succeeded', 'partial', 'failed', 'canceled')),
  total_sections      integer not null default 0,
  done_sections       integer not null default 0,
  failed_sections     integer not null default 0,
  skipped_sections    integer not null default 0,
  credits_estimated   integer not null default 0,
  credits_used        integer not null default 0,
  cancel_requested_at timestamptz,
  cancel_requested_by uuid,
  error               text,
  requested_by        uuid,
  created_at          timestamptz not null default now(),
  started_at          timestamptz,
  finished_at         timestamptz,
  updated_at          timestamptz not null default now(),
  unique (id, organization_id),
  constraint generation_runs_book_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete cascade,
  constraint generation_runs_job_fk foreign key (parent_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (parent_job_id)
);
create unique index generation_runs_one_active_per_book_idx on nomad_flora.generation_runs (book_id) where status in ('queued', 'running');
create index generation_runs_org_idx on nomad_flora.generation_runs (organization_id, created_at desc);
comment on table nomad_flora.generation_runs is '전체 순차 생성·전체 다듬기 실행(기능 write_all, quality = quality_mode). 서버 쓰기, 취소 요청만 사용자 RPC.';

-- 2.8 member_settings: 사용자별 화면 설정(테마·페르소나 즐겨찾기·생성 모드). 본인 행만.
create table nomad_flora.member_settings (
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id              uuid not null,
  theme_key            text not null default 'flora-dark'
                       constraint member_settings_theme_check check (theme_key in
                       ('flora-dark', 'minimal-light', 'warm-serif', 'lunaris-dark', 'halo-dev', 'nitro-enterprise', 'hero-analytics')),
  favorite_persona_ids text[] not null default '{}' constraint member_settings_favorites_check check (cardinality(favorite_persona_ids) <= 60),
  llm_mode             text not null default 'fast' constraint member_settings_llm_mode_check check (llm_mode in ('fast', 'quality')),
  editor_prefs         jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  primary key (organization_id, user_id)
);
create index member_settings_user_idx on nomad_flora.member_settings (user_id, updated_at);
comment on table nomad_flora.member_settings is '사용자별 화면 설정(본인 행). 프로 테마·quality 모드는 기능 잠금(끊기면 기본값으로).';

-- 2.9 webhook_endpoints / webhook_deliveries: 발신 웹훅(Make·Zapier·n8n). 서명 비밀은 provider_credentials(같은 조직)에만. 서버만 쓴다.
create table nomad_flora.webhook_endpoints (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  url                  text not null constraint webhook_endpoints_url_check check (url ~ '^https://' and char_length(url) <= 2000),
  events               text[] not null constraint webhook_endpoints_events_check check (
                         cardinality(events) >= 1 and events <@ array['book.completed', 'export.succeeded', 'export.failed']::text[]),
  secret_credential_id uuid not null,
  status               text not null default 'active' constraint webhook_endpoints_status_check check (status in ('active', 'disabled', 'failing')),
  consecutive_failures integer not null default 0,
  last_delivery_at     timestamptz,
  last_http_status     integer,
  created_by           uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  disabled_at          timestamptz,
  unique (id, organization_id),
  constraint webhook_endpoints_credential_fk foreign key (secret_credential_id, organization_id)
    references nomad_core.provider_credentials (id, organization_id)
);
create index webhook_endpoints_org_idx on nomad_flora.webhook_endpoints (organization_id) where status <> 'disabled';
comment on table nomad_flora.webhook_endpoints is '발신 웹훅 엔드포인트(기능 webhooks). 서명 비밀은 같은 조직 provider_credentials. owner·admin 읽기, 서버 쓰기.';

create table nomad_flora.webhook_deliveries (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  endpoint_id     uuid not null,
  event_type      text not null,
  event_id        uuid not null,
  status          text not null default 'pending' constraint webhook_deliveries_status_check check (status in ('pending', 'succeeded', 'failed')),
  http_status     integer,
  attempts        integer not null default 0,
  next_attempt_at timestamptz,
  last_error      text,
  created_at      timestamptz not null default now(),
  delivered_at    timestamptz,
  unique (endpoint_id, event_id),
  constraint webhook_deliveries_endpoint_fk foreign key (endpoint_id, organization_id)
    references nomad_flora.webhook_endpoints (id, organization_id) on delete cascade
);
create index webhook_deliveries_org_idx on nomad_flora.webhook_deliveries (organization_id, created_at desc);
comment on table nomad_flora.webhook_deliveries is '웹훅 발송 기록(삽입 = 발송, 기능 webhooks). 서버 쓰기만.';

-- 2.10 waitlist: 출시 전 대기자 명단. 테넌트 데이터가 아니라 조직 없음. service_role 전용(정책 없음).
create table nomad_flora.waitlist (
  id                bigint generated always as identity primary key,
  email             text not null constraint waitlist_email_check check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and char_length(email) <= 254),
  source            text,
  consent_marketing boolean not null default false,
  ip_hash           text,
  created_at        timestamptz not null default now()
);
create unique index waitlist_email_uniq on nomad_flora.waitlist (lower(email));
comment on table nomad_flora.waitlist is '출시 전 대기자 명단(서버 전용, 사용자·anon 접근 0).';

-- 2.11 agent_tasks: AI 에이전트 작업 단위(원본 16장). 요청 1건 = 1행(멱등 organization_id + request_id). 실행은 jobs·generation_runs·ai_runs 를 잇기만.
create table nomad_flora.agent_tasks (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id             uuid,
  agent_key           text not null constraint agent_tasks_agent_key_check check (agent_key in ('planning', 'research', 'writing', 'editing', 'publishing', 'content')),
  action              text not null constraint agent_tasks_action_check check (action ~ '^[a-z][a-z0-9_]{1,40}$'),
  origin              text not null default 'workspace' constraint agent_tasks_origin_check check (origin in ('workspace', 'wizard', 'editor', 'admin_retry')),
  status              text not null default 'queued'
                      constraint agent_tasks_status_check check (status in ('queued', 'running', 'succeeded', 'partial', 'failed', 'canceled')),
  approval_status     text not null default 'not_required'
                      constraint agent_tasks_approval_status_check check (approval_status in ('not_required', 'pending', 'approved', 'partially_applied', 'rejected', 'expired')),
  approval_decided_by uuid,
  approval_decided_at timestamptz,
  approval_note       text constraint agent_tasks_approval_note_check check (approval_note is null or length(approval_note) <= 500),
  input_summary       jsonb not null default '{}'::jsonb,
  result_summary      jsonb not null default '{}'::jsonb,
  job_id              uuid,
  generation_run_id   uuid,
  ai_run_id           uuid,
  credit_ledger_id    uuid references nomad_core.credit_ledger(id),
  credits_estimated   integer not null default 0 constraint agent_tasks_credits_estimated_check check (credits_estimated >= 0),
  credits_used        integer not null default 0 constraint agent_tasks_credits_used_check check (credits_used >= 0),
  request_id          text not null constraint agent_tasks_request_id_check check (length(request_id) between 8 and 64),
  retry_of            uuid references nomad_flora.agent_tasks(id) on delete set null,
  attempt             smallint not null default 1 constraint agent_tasks_attempt_check check (attempt between 1 and 10),
  error_code          text constraint agent_tasks_error_code_check check (error_code is null or length(error_code) <= 64),
  error_message       text constraint agent_tasks_error_message_check check (error_message is null or length(error_message) <= 500),
  requested_by        uuid,
  created_at          timestamptz not null default now(),
  started_at          timestamptz,
  finished_at         timestamptz,
  updated_at          timestamptz not null default now(),
  constraint agent_tasks_book_fk foreign key (book_id, organization_id) references nomad_flora.books (id, organization_id) on delete cascade,
  constraint agent_tasks_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id),
  constraint agent_tasks_run_fk foreign key (generation_run_id, organization_id)
    references nomad_flora.generation_runs (id, organization_id) on delete set null (generation_run_id),
  constraint agent_tasks_ai_run_fk foreign key (ai_run_id, organization_id) references nomad_core.ai_runs (id, organization_id) on delete set null (ai_run_id),
  constraint agent_tasks_request_uniq unique (organization_id, request_id),
  constraint agent_tasks_decision_check check ((approval_status in ('approved', 'partially_applied', 'rejected')) = (approval_decided_at is not null))
);
create index agent_tasks_org_created_idx on nomad_flora.agent_tasks (organization_id, created_at desc);
create index agent_tasks_book_created_idx on nomad_flora.agent_tasks (book_id, created_at desc) where book_id is not null;
create index agent_tasks_review_idx on nomad_flora.agent_tasks (organization_id, created_at desc) where approval_status = 'pending';
create index agent_tasks_active_idx on nomad_flora.agent_tasks (status, created_at) where status in ('queued', 'running');
create index agent_tasks_job_idx on nomad_flora.agent_tasks (job_id) where job_id is not null;
create unique index agent_tasks_one_retry_idx on nomad_flora.agent_tasks (retry_of) where retry_of is not null;
comment on table nomad_flora.agent_tasks is 'AI 에이전트 작업 단위(멱등 organization_id+request_id). 서버 쓰기, 사용자 검수 결정은 decide_agent_task.';

-- =====================================================================
-- 3. 트리거
--   서버 판별(사용자 경로 강제값·서버 표 잠금): current_user가 authenticated·anon이 아니면 서버(service_role 직접 또는 소유자 DEFINER 함수 안).
--   한도·기능·결과 전달 트리거는 SECURITY DEFINER(서버·사용자 모두에 적용, core 한도·기능 함수는 사용자 실행 권한이 없다).
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['custom_personas', 'books', 'chapters', 'sections', 'cover_images', 'manuscript_uploads', 'book_exports',
                           'generation_runs', 'member_settings', 'webhook_endpoints', 'agent_tasks'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_flora.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
end $$;

-- 서버 기록 표: 사용자 세션 쓰기 42501(grant 없음과 이중 잠금). custom_personas는 INSERT만 서버.
create function nomad_flora.guard_server_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'nomad_flora.%: server-managed', tg_table_name using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['cover_images', 'manuscript_uploads', 'book_exports', 'generation_runs',
                           'webhook_endpoints', 'webhook_deliveries', 'waitlist', 'agent_tasks'] loop
    execute format('create trigger %1$s_guard_write before insert or update or delete on nomad_flora.%1$I for each row execute function nomad_flora.guard_server_write()', t);
  end loop;
end $$;
create trigger custom_personas_guard_insert before insert on nomad_flora.custom_personas
  for each row execute function nomad_flora.guard_server_write();

-- 수량 한도(원본 PB001~PB004). 서버 경로 포함. 한도 = plan_limits(없으면 원본 free 값).
create function nomad_flora.enforce_plan_limits() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_limit integer; v_count integer;
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 플랜·한도를 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'flora: not a member of this organization' using errcode = '42501';
  end if;
  -- 표마다 컬럼이 달라 sections 분기 안에서만 paragraph_target 을 읽는다(plpgsql 은 and 를 단락 평가하지 않는다)
  if tg_table_name = 'sections' then
    if tg_op = 'INSERT' or new.paragraph_target is distinct from old.paragraph_target then
      v_limit := nomad_flora.limit_of(new.organization_id, 'max_paragraphs', 3);
      if new.paragraph_target > v_limit then
        raise exception 'sections: paragraph_target % exceeds plan limit %', new.paragraph_target, v_limit using errcode = 'PB004';
      end if;
    end if;
  end if;
  if tg_op <> 'INSERT' then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('flora:limits:' || new.organization_id::text, 0));
  if tg_table_name = 'books' then
    v_limit := nomad_flora.limit_of(new.organization_id, 'max_books', 3);
    select count(*) into v_count from nomad_flora.books b where b.organization_id = new.organization_id and b.deleted_at is null;
    if v_count >= v_limit then
      raise exception 'books: plan limit reached (max_books=%)', v_limit using errcode = 'PB001';
    end if;
  elsif tg_table_name = 'chapters' then
    v_limit := nomad_flora.limit_of(new.organization_id, 'max_chapters', 3);
    select count(*) into v_count from nomad_flora.chapters c where c.book_id = new.book_id;
    if v_count >= v_limit then
      raise exception 'chapters: plan limit reached (max_chapters=%)', v_limit using errcode = 'PB002';
    end if;
  elsif tg_table_name = 'sections' then
    v_limit := nomad_flora.limit_of(new.organization_id, 'max_sections', 6);
    select count(*) into v_count from nomad_flora.sections s where s.book_id = new.book_id;
    if v_count >= v_limit then
      raise exception 'sections: plan limit reached (max_sections=%)', v_limit using errcode = 'PB003';
    end if;
  end if;
  return new;
end;
$$;
create trigger books_plan_limits before insert on nomad_flora.books for each row execute function nomad_flora.enforce_plan_limits();
create trigger chapters_plan_limits before insert on nomad_flora.chapters for each row execute function nomad_flora.enforce_plan_limits();
create trigger sections_plan_limits before insert or update of paragraph_target on nomad_flora.sections
  for each row execute function nomad_flora.enforce_plan_limits();

-- 플랜 기능 잠금(이식 추가 PB014). 원본은 Route Handler 몫이었으나 구독이 끊긴 뒤 기존 유료 행 경로까지 DB에서 막는다.
create function nomad_flora.enforce_plan_features() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_need text[] := '{}'; v_persona uuid; f text;
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 플랜·한도를 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'flora: not a member of this organization' using errcode = '42501';
  end if;
  if tg_table_name = 'custom_personas' then
    v_need := array['persona_blend'];
  elsif tg_table_name = 'books' then
    if new.custom_persona_id is not null and (tg_op = 'INSERT' or new.custom_persona_id is distinct from old.custom_persona_id) then
      v_need := array['persona_blend'];
    end if;
  elsif tg_table_name = 'generation_runs' then
    v_need := array['write_all'];
    if new.mode = 'quality' then v_need := v_need || 'quality_mode'::text; end if;
    -- 구독 중 고른 나만의 페르소나 책도 끊긴 뒤에는 새 실행 불가
    select b.custom_persona_id into v_persona from nomad_flora.books b where b.id = new.book_id;
    if v_persona is not null then v_need := v_need || 'persona_blend'::text; end if;
  elsif tg_table_name = 'manuscript_uploads' then
    -- 기존 업로드도 끊긴 뒤 파싱 시작 불가
    if tg_op = 'INSERT' or (new.status = 'parsing' and old.status is distinct from 'parsing') then
      v_need := array['upload'];
    end if;
  elsif tg_table_name = 'book_exports' then
    if not new.watermark then v_need := array['no_watermark']; end if;
  elsif tg_table_name = 'webhook_endpoints' then
    -- 끊긴 조직이 기존 엔드포인트를 되살리지 못한다
    if tg_op = 'INSERT' or (new.status = 'active' and old.status is distinct from 'active') then
      v_need := array['webhooks'];
    end if;
  elsif tg_table_name = 'webhook_deliveries' then
    v_need := array['webhooks'];   -- 발송 기록 = 발송. 기존 엔드포인트도 끊기면 발송 안 함
  end if;
  foreach f in array v_need loop
    if not nomad_flora.org_feature(new.organization_id, f) then
      raise exception 'flora: % needs a higher plan (%)', tg_table_name, f using errcode = 'PB014';
    end if;
  end loop;
  return new;
end;
$$;
create trigger custom_personas_plan_features before insert on nomad_flora.custom_personas
  for each row execute function nomad_flora.enforce_plan_features();
create trigger books_plan_features before insert or update of custom_persona_id on nomad_flora.books
  for each row execute function nomad_flora.enforce_plan_features();
create trigger generation_runs_plan_features before insert on nomad_flora.generation_runs
  for each row execute function nomad_flora.enforce_plan_features();
create trigger manuscript_uploads_plan_features before insert or update of status on nomad_flora.manuscript_uploads
  for each row execute function nomad_flora.enforce_plan_features();
create trigger book_exports_plan_features before insert on nomad_flora.book_exports
  for each row execute function nomad_flora.enforce_plan_features();
create trigger webhook_endpoints_plan_features before insert or update of status on nomad_flora.webhook_endpoints
  for each row execute function nomad_flora.enforce_plan_features();
create trigger webhook_deliveries_plan_features before insert on nomad_flora.webhook_deliveries
  for each row execute function nomad_flora.enforce_plan_features();

-- 결과 전달(이식 추가): 서버가 결과 상태로 바꿀 때 작업이 이미 failed·canceled(= 환불 끝)면 거부(PB015),
-- 아니면 nomad_core.mark_job_delivered(결과를 넘긴 뒤 작업이 실패해도 환불하지 않음). core 표 직접 쓰기 없음.
create function nomad_flora.deliver_job_result() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_job uuid; v_done boolean := false; v_status text;
begin
  -- INSERT 에는 old 가 없으므로 결과 상태로 바로 만드는 행도 결과 전달로 본다
  if tg_table_name = 'sections' then
    v_done := new.gen_status = 'generated' and (tg_op = 'INSERT' or old.gen_status is distinct from 'generated');
    v_job := new.last_job_id;
  elsif tg_table_name = 'generation_runs' then
    v_done := new.status in ('succeeded', 'partial') and (tg_op = 'INSERT' or old.status not in ('succeeded', 'partial'));
    v_job := new.parent_job_id;
  elsif tg_table_name = 'manuscript_uploads' then
    v_done := new.status = 'parsed' and (tg_op = 'INSERT' or old.status is distinct from 'parsed');
    v_job := new.job_id;
  elsif tg_table_name in ('cover_images', 'book_exports') then
    v_done := new.status = 'succeeded' and (tg_op = 'INSERT' or old.status is distinct from 'succeeded');
    v_job := new.job_id;
  elsif tg_table_name = 'agent_tasks' then
    v_done := new.status in ('succeeded', 'partial') and (tg_op = 'INSERT' or old.status not in ('succeeded', 'partial'));
    v_job := new.job_id;
  end if;
  if v_done and v_job is not null then
    -- 잡 행을 잠근 뒤 판정: 동시에 fail_job(환불)이 끝나는 경합에서 환불 + 결과 전달이 함께 일어나지 않게
    select j.status into v_status from nomad_core.jobs j where j.id = v_job for update;
    if v_status in ('failed', 'canceled') then
      raise exception '%: job is already finished without result', tg_table_name using errcode = 'PB015';
    end if;
    perform nomad_core.mark_job_delivered(v_job);
  end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['sections', 'generation_runs', 'manuscript_uploads', 'cover_images', 'book_exports', 'agent_tasks'] loop
    execute format('create trigger %1$s_deliver_result before insert or update on nomad_flora.%1$I for each row execute function nomad_flora.deliver_job_result()', t);
  end loop;
end $$;

-- 크레딧 원장 행은 같은 조직 것만(원장에는 (id, organization_id) 유니크가 없어 트리거로 본다)
create function nomad_flora.check_ledger_org() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.credit_ledger_id is not null
     and not exists (select 1 from nomad_core.credit_ledger l where l.id = new.credit_ledger_id and l.organization_id = new.organization_id) then
    raise exception '%: credit ledger belongs to another organization', tg_table_name using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger book_exports_ledger_org before insert or update of credit_ledger_id on nomad_flora.book_exports
  for each row execute function nomad_flora.check_ledger_org();
create trigger agent_tasks_ledger_org before insert or update of credit_ledger_id on nomad_flora.agent_tasks
  for each row execute function nomad_flora.check_ledger_org();

-- books INSERT: 사용자 경로 강제값(컬럼 GRANT와 이중)
create function nomad_flora.books_before_insert() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.created_by := auth.uid();
    new.status := 'draft';
    new.is_public := false;
    new.slug := null;
    new.published_at := null;
    new.taste_config := null;
    new.word_count := 0;
    new.deleted_at := null;
    new.cover_image_id := null;
  end if;
  return new;
end;
$$;
create trigger books_before_insert before insert on nomad_flora.books for each row execute function nomad_flora.books_before_insert();

-- books UPDATE: 상태 전이(서버 포함) + 사용자 경로 제한 + 소프트 삭제 시각 now() 강제
create function nomad_flora.books_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if not (
         (old.status = 'draft'     and new.status in ('writing', 'archived'))
      or (old.status = 'writing'   and new.status in ('draft', 'ready', 'archived'))
      or (old.status = 'ready'     and new.status in ('writing', 'completed', 'archived'))
      or (old.status = 'completed' and new.status in ('writing', 'archived'))
      or (old.status = 'archived'  and new.status in ('draft'))
    ) then
      raise exception 'books: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'writing' and old.writing_started_at is null then
      new.writing_started_at := now();
    end if;
    if new.status = 'completed' then
      new.completed_at := now();
    end if;
    if new.status <> 'completed' and new.is_public then
      new.is_public := false;   -- 완성 상태를 벗어나면 공개 페이지를 내린다
    end if;
  end if;

  if current_user in ('authenticated', 'anon') then
    if old.deleted_at is not null and new.deleted_at is null then
      raise exception 'books: restore is server-only' using errcode = 'PB010';
    end if;
    -- 소프트 삭제는 owner·admin 만(행 삭제 정책 can_manage 와 같다). editor 의 update 권한으로 우회하지 못한다
    if new.deleted_at is distinct from old.deleted_at and not nomad_flora.can_manage(new.organization_id) then
      raise exception 'books: only owner/admin may delete' using errcode = '42501';
    end if;
    -- 소프트 삭제 시각은 클라이언트 값 대신 서버 시각(이미 삭제된 행은 처음 시각 유지)
    if new.deleted_at is not null then
      new.deleted_at := coalesce(old.deleted_at, now());
    end if;
    if old.status <> 'draft'
       and (new.persona_id is distinct from old.persona_id or new.custom_persona_id is distinct from old.custom_persona_id) then
      raise exception 'books: persona is locked after writing starts' using errcode = 'PB011';
    end if;
    if new.cover_image_id is distinct from old.cover_image_id and new.cover_image_id is not null then
      if not exists (select 1 from nomad_flora.cover_images c
                     where c.id = new.cover_image_id and c.book_id = new.id and c.organization_id = new.organization_id and c.status = 'succeeded') then
        raise exception 'books: cover image does not belong to this book or is not ready' using errcode = 'PB006';
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger books_before_update before update on nomad_flora.books for each row execute function nomad_flora.books_before_update();

-- sections: 글자 수 계산 + 사용자 경로 강제값 + 생성 중 편집 금지
create function nomad_flora.sections_before_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.char_count := char_length(regexp_replace(new.body_html, '<[^>]*>', '', 'g'));
  if current_user in ('authenticated', 'anon') then
    new.updated_by := auth.uid();
    if tg_op = 'INSERT' then
      new.gen_status := case when new.body_html = '' then 'empty' else 'edited' end;
      new.last_job_id := null;
      new.last_error := null;
      new.revision := 0;
    else
      if old.gen_status in ('queued', 'generating') and new.body_html is distinct from old.body_html then
        raise exception 'sections: section is being generated' using errcode = 'PB005';
      end if;
      new.gen_status := case when new.body_html is distinct from old.body_html then 'edited' else old.gen_status end;
      new.last_job_id := old.last_job_id;
      new.last_error := old.last_error;
      new.revision := case when new.body_html is distinct from old.body_html then old.revision + 1 else old.revision end;
    end if;
  end if;
  return new;
end;
$$;
create trigger sections_before_write before insert or update on nomad_flora.sections for each row execute function nomad_flora.sections_before_write();

-- 상태 전이(서버 경로 포함): book_exports · generation_runs · manuscript_uploads
create function nomad_flora.book_exports_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and not (
       (old.status = 'queued'    and new.status in ('running', 'failed', 'canceled'))
    or (old.status = 'running'   and new.status in ('queued', 'succeeded', 'failed'))
    or (old.status = 'succeeded' and new.status in ('expired'))
  ) then
    raise exception 'book_exports: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  if new.status in ('succeeded', 'failed', 'canceled') and old.status <> new.status then
    new.finished_at := now();
  end if;
  if new.status = 'running' and old.status = 'queued' then
    new.started_at := coalesce(new.started_at, now());
  end if;
  return new;
end;
$$;
create trigger book_exports_transition before update on nomad_flora.book_exports for each row execute function nomad_flora.book_exports_transition();

create function nomad_flora.generation_runs_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and not (
       (old.status = 'queued'  and new.status in ('running', 'canceled', 'failed'))
    or (old.status = 'running' and new.status in ('succeeded', 'partial', 'failed', 'canceled'))
  ) then
    raise exception 'generation_runs: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  if new.status in ('succeeded', 'partial', 'failed', 'canceled') and old.status <> new.status then
    new.finished_at := now();
  end if;
  if new.status = 'running' and old.status = 'queued' then
    new.started_at := coalesce(new.started_at, now());
  end if;
  return new;
end;
$$;
create trigger generation_runs_transition before update on nomad_flora.generation_runs for each row execute function nomad_flora.generation_runs_transition();

create function nomad_flora.manuscript_uploads_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and not (
       (old.status = 'pending_upload' and new.status in ('uploaded', 'failed', 'expired'))
    or (old.status = 'uploaded'       and new.status in ('parsing', 'failed', 'expired'))
    or (old.status = 'parsing'        and new.status in ('parsed', 'failed', 'uploaded'))
    or (old.status = 'parsed'         and new.status in ('expired'))
    or (old.status = 'failed'         and new.status in ('expired'))
  ) then
    raise exception 'manuscript_uploads: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger manuscript_uploads_transition before update on nomad_flora.manuscript_uploads
  for each row execute function nomad_flora.manuscript_uploads_transition();

-- member_settings: 본인 행 + 플랜 잠금. 구독이 끊긴 뒤 기존 프로 테마·quality 행은 다음 사용자 저장 때 기본값으로 내린다(바꾸려는 값이면 거부).
create function nomad_flora.member_settings_before_write() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 플랜·한도를 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'flora: not a member of this organization' using errcode = '42501';
  end if;
  if not nomad_core.is_service_caller() then
    if new.user_id is distinct from auth.uid() then
      raise exception 'member_settings: own row only' using errcode = '42501';
    end if;
    if not nomad_flora.theme_allowed(new.organization_id, new.theme_key) then
      if tg_op = 'UPDATE' and new.theme_key = old.theme_key then
        new.theme_key := 'flora-dark';
      else
        raise exception 'member_settings: theme % is not in the current plan', new.theme_key using errcode = 'PB008';
      end if;
    end if;
    if new.llm_mode = 'quality' and not nomad_flora.org_feature(new.organization_id, 'quality_mode') then
      if tg_op = 'UPDATE' and old.llm_mode = 'quality' then
        new.llm_mode := 'fast';
      else
        raise exception 'member_settings: quality mode needs a higher plan' using errcode = 'PB014';
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger member_settings_before_write before insert or update on nomad_flora.member_settings
  for each row execute function nomad_flora.member_settings_before_write();

-- agent_tasks: 재시도 행 검사(원래 행이 끝난 실패·부분·취소, 같은 조직·책·에이전트·동작, attempt = 원래 + 1)
create function nomad_flora.agent_tasks_before_insert() returns trigger
language plpgsql set search_path = ''
as $$
declare v_orig nomad_flora.agent_tasks;
begin
  if new.retry_of is not null then
    select * into v_orig from nomad_flora.agent_tasks where id = new.retry_of;
    if not found then
      raise exception 'agent_tasks: retry source not found' using errcode = 'P0002';
    end if;
    if v_orig.status not in ('failed', 'partial', 'canceled') then
      raise exception 'agent_tasks: only failed/partial/canceled tasks can be retried (status=%)', v_orig.status using errcode = 'PB013';
    end if;
    if v_orig.organization_id <> new.organization_id or v_orig.book_id is distinct from new.book_id
       or v_orig.agent_key <> new.agent_key or v_orig.action <> new.action then
      raise exception 'agent_tasks: retry must keep organization, book, agent and action' using errcode = '22023';
    end if;
    if new.attempt <> v_orig.attempt + 1 then
      raise exception 'agent_tasks: retry attempt must be % (got %)', v_orig.attempt + 1, new.attempt using errcode = '22023';
    end if;
  end if;
  if new.retry_of is null and new.attempt <> 1 then
    raise exception 'agent_tasks: first attempt must be 1' using errcode = '22023';
  end if;
  if new.origin = 'admin_retry' and new.retry_of is null then
    raise exception 'agent_tasks: admin_retry requires retry_of' using errcode = '22023';
  end if;
  if new.status <> 'queued' or new.approval_status <> 'not_required' then
    raise exception 'agent_tasks: new task must start as queued/not_required' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger agent_tasks_before_insert before insert on nomad_flora.agent_tasks for each row execute function nomad_flora.agent_tasks_before_insert();

-- agent_tasks: 상태·승인 전이와 불변 컬럼(서버 경로 포함)
create function nomad_flora.agent_tasks_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.organization_id <> old.organization_id or new.book_id is distinct from old.book_id or new.agent_key <> old.agent_key
     or new.action <> old.action or new.request_id <> old.request_id
     or (new.retry_of is distinct from old.retry_of and new.retry_of is not null)  -- 원래 행 삭제 시 FK set null 만 허용
     or new.attempt <> old.attempt or new.origin <> old.origin then
    raise exception 'agent_tasks: identity columns are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'queued'  and new.status in ('running', 'canceled', 'failed'))
    or (old.status = 'running' and new.status in ('succeeded', 'partial', 'failed', 'canceled'))
  ) then
    raise exception 'agent_tasks: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  if new.approval_status is distinct from old.approval_status and not (
       (old.approval_status = 'not_required' and new.approval_status = 'pending' and new.status in ('succeeded', 'partial', 'canceled'))
    or (old.approval_status = 'pending' and new.approval_status in ('approved', 'partially_applied', 'rejected', 'expired'))
  ) then
    raise exception 'agent_tasks: invalid approval transition % -> %', old.approval_status, new.approval_status using errcode = '22023';
  end if;
  if new.status = 'running' and old.status = 'queued' then
    new.started_at := coalesce(new.started_at, now());
  end if;
  if new.status in ('succeeded', 'partial', 'failed', 'canceled') and old.status <> new.status then
    new.finished_at := now();
  end if;
  if old.approval_status = 'pending' and new.approval_status in ('approved', 'partially_applied', 'rejected') then
    new.approval_decided_at := coalesce(new.approval_decided_at, now());
  end if;
  return new;
end;
$$;
create trigger agent_tasks_transition before update on nomad_flora.agent_tasks for each row execute function nomad_flora.agent_tasks_transition();

-- =====================================================================
-- 4. 사용자 RPC (SECURITY DEFINER, authenticated). 남의 조직 행은 존재도 알리지 않는다(P0002).
--    반환 행은 호출자가 SELECT 권한을 가진 표(컬럼 전체 GRANT)만.
-- =====================================================================
-- 전체 생성 취소 요청. 워커가 cancel_requested_at 을 보고 남은 자식 작업을 cancel_job 한다(환불 포함).
create function nomad_flora.request_generation_cancel(p_run_id uuid) returns nomad_flora.generation_runs
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_flora.generation_runs; v_server boolean := nomad_core.is_service_caller();
begin
  select * into v_row from nomad_flora.generation_runs where id = p_run_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'request_generation_cancel: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_flora.can_edit(v_row.organization_id) then
    raise exception 'request_generation_cancel: editor role required' using errcode = '42501';
  end if;
  if v_row.status not in ('queued', 'running') then
    raise exception 'request_generation_cancel: run is not active (status=%)', v_row.status using errcode = 'PB007';
  end if;
  if v_row.cancel_requested_at is null then
    update nomad_flora.generation_runs set cancel_requested_at = now(), cancel_requested_by = auth.uid()
     where id = p_run_id returning * into v_row;
    perform nomad_core.write_audit(v_row.organization_id, 'flora.generation_run.cancel_request', 'generation_run', v_row.id::text);
  end if;
  return v_row;
end;
$$;

-- 공개 책 페이지 켜기/끄기. owner/admin, 완성 상태, 기능 public_page(끄기는 기능 없이도 가능).
create function nomad_flora.set_book_visibility(p_book_id uuid, p_is_public boolean, p_slug text default null) returns nomad_flora.books
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_flora.books; v_server boolean := nomad_core.is_service_caller();
begin
  if p_is_public is null then
    raise exception 'set_book_visibility: is_public required' using errcode = '22023';
  end if;
  select * into v_row from nomad_flora.books where id = p_book_id and deleted_at is null for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'set_book_visibility: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_flora.can_manage(v_row.organization_id) then
    raise exception 'set_book_visibility: owner/admin only' using errcode = '42501';
  end if;
  if not nomad_flora.org_feature(v_row.organization_id, 'flora') then
    raise exception 'set_book_visibility: no entitlement' using errcode = '42501';
  end if;
  if p_is_public then
    if v_row.status <> 'completed' then
      raise exception 'set_book_visibility: book must be completed' using errcode = 'PB009';
    end if;
    if not nomad_flora.org_feature(v_row.organization_id, 'public_page') then
      raise exception 'set_book_visibility: public_page needs a higher plan' using errcode = 'PB009';
    end if;
    if coalesce(p_slug, v_row.slug) is null or coalesce(p_slug, v_row.slug) !~ '^[a-z0-9][a-z0-9-]{2,62}$' then
      raise exception 'set_book_visibility: invalid slug' using errcode = '22023';
    end if;
  end if;
  update nomad_flora.books
     set is_public = p_is_public,
         slug = coalesce(p_slug, slug),
         published_at = case when p_is_public then coalesce(published_at, now()) else published_at end
   where id = p_book_id
  returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, case when p_is_public then 'flora.book.publish_page' else 'flora.book.unpublish_page' end,
                                 'book', v_row.id::text);
  return v_row;
end;
$$;

-- 검수 결정. 원고 반영(sections 수정, revision 확인)은 Route Handler 가 먼저 하고 이 RPC 로 결정을 기록한다.
create function nomad_flora.decide_agent_task(p_task_id uuid, p_decision text, p_note text default null) returns nomad_flora.agent_tasks
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_flora.agent_tasks; v_server boolean := nomad_core.is_service_caller();
begin
  if p_decision is null or p_decision not in ('approved', 'partially_applied', 'rejected') then
    raise exception 'decide_agent_task: invalid decision %', p_decision using errcode = '22023';
  end if;
  if p_note is not null and length(p_note) > 500 then
    raise exception 'decide_agent_task: note too long' using errcode = '22023';
  end if;
  select * into v_row from nomad_flora.agent_tasks where id = p_task_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'decide_agent_task: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_flora.can_edit(v_row.organization_id) then
    raise exception 'decide_agent_task: editor role required' using errcode = '42501';
  end if;
  if v_row.approval_status <> 'pending' then
    raise exception 'decide_agent_task: task is not awaiting review (approval_status=%)', v_row.approval_status using errcode = 'PB012';
  end if;
  update nomad_flora.agent_tasks
     set approval_status = p_decision, approval_decided_by = auth.uid(), approval_decided_at = now(), approval_note = p_note
   where id = p_task_id
  returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'flora.agent_task.decide', 'agent_task', v_row.id::text, null,
                                 jsonb_build_object('decision', p_decision, 'agent', v_row.agent_key, 'action', v_row.action));
  return v_row;
end;
$$;

-- =====================================================================
-- 5. 서버 RPC (service_role 전용)
-- =====================================================================
-- book-trailer 계약(trailer.import_flora_book 의 서버 의무 ①②③): 요청 사용자가 그 조직 멤버이고 조직에 flora 이용권이 있으며
-- 책이 그 조직 소유(삭제 안 됨)일 때만 책 정보(title·subtitle·author_name·genre)를 돌려준다. 다른 제품 스키마를 읽지 않는다.
create function nomad_flora.book_for_trailer(p_organization_id uuid, p_book_id uuid, p_actor uuid)
returns table (id uuid, organization_id uuid, title text, subtitle text, author_name text, genre text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'book_for_trailer: service_role only' using errcode = '42501';
  end if;
  if not exists (select 1 from nomad_core.memberships m where m.organization_id = p_organization_id and m.user_id = p_actor) then
    raise exception 'book_for_trailer: not a member' using errcode = '42501';
  end if;
  if not nomad_flora.org_feature(p_organization_id, 'flora') then
    raise exception 'book_for_trailer: no entitlement' using errcode = '42501';
  end if;
  return query
    select b.id, b.organization_id, b.title, b.subtitle, b.author_name, b.genre
    from nomad_flora.books b
    where b.id = p_book_id and b.organization_id = p_organization_id and b.deleted_at is null;
  if not found then
    raise exception 'book_for_trailer: not found' using errcode = 'P0002';
  end if;
end;
$$;

-- =====================================================================
-- 6. 공개 RPC (D8): anon 의 유일한 경로(원본 books_select_public 정책 대체). 읽기 전용, 입력 검증, 공개 컬럼만.
--    DB 요청 제한 없음(공개 읽기 — 과부하는 앞단 CDN 캐시·WAF 몫). 구독이 끊겨도 이미 공개된 책의 독자 열람은 유지(microweb 과 같은 원칙,
--    팀장 결정 2026-11-14). 새 공개는 set_book_visibility 가 public_page 로 막는다. 비공개·삭제·조직 비활성은 not_found.
-- =====================================================================
create function nomad_flora.get_public_book(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v nomad_flora.books;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{2,62}$' then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  select * into v from nomad_flora.books b
  where b.slug = p_slug and b.is_public and b.status = 'completed' and b.deleted_at is null;
  if v.id is null or not exists (select 1 from nomad_core.organizations o where o.id = v.organization_id and o.active) then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'book', jsonb_build_object(
    'id', v.id, 'slug', v.slug, 'title', v.title, 'subtitle', v.subtitle, 'author_name', v.author_name, 'genre', v.genre,
    'format_key', v.format_key, 'book_info', v.book_info, 'cover_image_id', v.cover_image_id, 'published_at', v.published_at));
end;
$$;

-- =====================================================================
-- 7. RLS 정책과 GRANT (anon: 테이블 권한 0)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['custom_personas', 'books', 'chapters', 'sections', 'cover_images', 'manuscript_uploads', 'book_exports',
                           'generation_runs', 'member_settings', 'webhook_endpoints', 'webhook_deliveries', 'waitlist', 'agent_tasks'] loop
    execute format('alter table nomad_flora.%I enable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema nomad_flora from public, anon, authenticated;
grant all on all tables in schema nomad_flora to service_role;
grant usage, select on all sequences in schema nomad_flora to service_role;

-- custom_personas: 이용권 멤버 읽기, 이름·보관 변경 편집자, 삭제 owner·admin, INSERT 없음(서버)
grant select, delete on nomad_flora.custom_personas to authenticated;
grant update (name, status) on nomad_flora.custom_personas to authenticated;
create policy custom_personas_select on nomad_flora.custom_personas for select to authenticated using (nomad_flora.has_access(organization_id));
create policy custom_personas_update on nomad_flora.custom_personas for update to authenticated
  using (nomad_flora.can_edit(organization_id)) with check (nomad_flora.can_edit(organization_id));
create policy custom_personas_delete on nomad_flora.custom_personas for delete to authenticated using (nomad_flora.can_manage(organization_id));

-- books: 컬럼 GRANT(is_public·slug·taste_config·word_count·created_by 등 서버 컬럼 제외), 삭제 owner·admin
grant select, delete on nomad_flora.books to authenticated;
grant insert (id, organization_id, title, subtitle, author_name, genre, format_key, persona_id, custom_persona_id,
              tone, layout_settings, plan_brief, book_info, step_state, current_step, source, seed_key)
  on nomad_flora.books to authenticated;
grant update (title, subtitle, author_name, genre, format_key, persona_id, custom_persona_id,
              tone, layout_settings, plan_brief, book_info, step_state, current_step, cover_image_id, status, deleted_at)
  on nomad_flora.books to authenticated;
create policy books_select on nomad_flora.books for select to authenticated using (nomad_flora.has_access(organization_id));
create policy books_insert on nomad_flora.books for insert to authenticated with check (nomad_flora.can_edit(organization_id));
create policy books_update on nomad_flora.books for update to authenticated
  using (nomad_flora.can_edit(organization_id)) with check (nomad_flora.can_edit(organization_id));
create policy books_delete on nomad_flora.books for delete to authenticated using (nomad_flora.can_manage(organization_id));

-- chapters / sections: 편집자 CRUD(생성 상태·작업·revision 컬럼은 grant 없음 + 트리거)
grant select, delete on nomad_flora.chapters to authenticated;
grant insert (id, organization_id, book_id, position, title) on nomad_flora.chapters to authenticated;
grant update (position, title) on nomad_flora.chapters to authenticated;
create policy chapters_select on nomad_flora.chapters for select to authenticated using (nomad_flora.has_access(organization_id));
create policy chapters_insert on nomad_flora.chapters for insert to authenticated with check (nomad_flora.can_edit(organization_id));
create policy chapters_update on nomad_flora.chapters for update to authenticated
  using (nomad_flora.can_edit(organization_id)) with check (nomad_flora.can_edit(organization_id));
create policy chapters_delete on nomad_flora.chapters for delete to authenticated using (nomad_flora.can_edit(organization_id));

grant select, delete on nomad_flora.sections to authenticated;
grant insert (id, organization_id, book_id, chapter_id, position, title, paragraph_target, body_html) on nomad_flora.sections to authenticated;
grant update (position, title, paragraph_target, body_html) on nomad_flora.sections to authenticated;
create policy sections_select on nomad_flora.sections for select to authenticated using (nomad_flora.has_access(organization_id));
create policy sections_insert on nomad_flora.sections for insert to authenticated with check (nomad_flora.can_edit(organization_id));
create policy sections_update on nomad_flora.sections for update to authenticated
  using (nomad_flora.can_edit(organization_id)) with check (nomad_flora.can_edit(organization_id));
create policy sections_delete on nomad_flora.sections for delete to authenticated using (nomad_flora.can_edit(organization_id));

-- 서버 기록 표: 이용권 멤버 SELECT 만
grant select on nomad_flora.cover_images, nomad_flora.manuscript_uploads, nomad_flora.book_exports,
                nomad_flora.generation_runs, nomad_flora.agent_tasks to authenticated;
create policy cover_images_select on nomad_flora.cover_images for select to authenticated using (nomad_flora.has_access(organization_id));
create policy manuscript_uploads_select on nomad_flora.manuscript_uploads for select to authenticated using (nomad_flora.has_access(organization_id));
create policy book_exports_select on nomad_flora.book_exports for select to authenticated using (nomad_flora.has_access(organization_id));
create policy generation_runs_select on nomad_flora.generation_runs for select to authenticated using (nomad_flora.has_access(organization_id));
create policy agent_tasks_select on nomad_flora.agent_tasks for select to authenticated using (nomad_flora.has_access(organization_id));

-- member_settings: 본인 행
grant select, insert, update on nomad_flora.member_settings to authenticated;
create policy member_settings_select on nomad_flora.member_settings for select to authenticated
  using (user_id = (select auth.uid()) and nomad_core.organization_role(organization_id) is not null);
create policy member_settings_insert on nomad_flora.member_settings for insert to authenticated
  with check (user_id = (select auth.uid()) and nomad_flora.has_access(organization_id));
create policy member_settings_update on nomad_flora.member_settings for update to authenticated
  using (user_id = (select auth.uid()) and nomad_flora.has_access(organization_id))
  with check (user_id = (select auth.uid()) and nomad_flora.has_access(organization_id));

-- 웹훅: owner·admin 만 읽기(URL 노출 최소화). 쓰기는 서버.
grant select on nomad_flora.webhook_endpoints, nomad_flora.webhook_deliveries to authenticated;
create policy webhook_endpoints_select on nomad_flora.webhook_endpoints for select to authenticated using (nomad_flora.can_manage(organization_id));
create policy webhook_deliveries_select on nomad_flora.webhook_deliveries for select to authenticated using (nomad_flora.can_manage(organization_id));

-- waitlist: 정책 없음(service_role 전용)

-- Realtime: 진행률은 core jobs(nomad_my_jobs)가 정본. 섹션 본문 갱신·실행 단위·에이전트 작업도 구독(RLS 적용).
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['sections', 'generation_runs', 'agent_tasks'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_flora' and tablename = t) then
        execute format('alter publication supabase_realtime add table nomad_flora.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- =====================================================================
-- 8. 함수 실행 권한: 기본 0, service_role 전부, authenticated 는 정책 도우미·사용자 RPC, anon 은 공개 RPC 하나.
-- =====================================================================
revoke execute on all functions in schema nomad_flora from public, anon, authenticated;
grant execute on all functions in schema nomad_flora to service_role;
grant execute on function
  nomad_flora.has_access(uuid), nomad_flora.can_edit(uuid), nomad_flora.can_manage(uuid),
  nomad_flora.request_generation_cancel(uuid), nomad_flora.set_book_visibility(uuid, boolean, text),
  nomad_flora.decide_agent_task(uuid, text, text)
to authenticated;
grant execute on function nomad_flora.get_public_book(text) to anon, authenticated;

-- =====================================================================
-- 9. Storage (제품 전용 버킷, 경로 <organization_id>/flora/...). 원본 core org-files·exports 대체.
--   flora-files   비공개. 원고(manuscripts/)·표지(covers/). 이용권 멤버 읽기. 쓰기는 서버(원고는 서버가 서명 업로드 URL 발급 — 기능 upload 확인 후).
--   flora-exports 비공개. PDF/ePub. 이용권 멤버 읽기, 쓰기는 서버.
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('flora-files',   'flora-files',   false, 20971520, array['text/plain', 'text/markdown', 'application/pdf',
     'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'image/png', 'image/jpeg', 'image/webp']),
  ('flora-exports', 'flora-exports', false, 104857600, array['application/pdf', 'application/epub+zip'])
on conflict (id) do nothing;

create policy nomad_flora_files_select on storage.objects for select to authenticated
  using (bucket_id in ('flora-files', 'flora-exports') and (storage.foldername(name))[2] = 'flora'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_flora.has_access(((storage.foldername(name))[1])::uuid) else false end);

commit;
