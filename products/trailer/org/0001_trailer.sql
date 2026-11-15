-- book-trailer 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/2600_trailer.sql 1~11장(17표)
-- core.organizations→nomad_core.organizations, org_members→nomad_core.memberships(member→editor), has_entitlement→nomad_core.has_feature,
-- core.consume_credits·enqueue_job→nomad_core.consume_credits·enqueue_job(크레딧 원장 id uuid), core.write_audit→nomad_core.write_audit,
-- 플랜 features jsonb → A/B/C 기능(features) + plan_limits 키(수치 시드 안 함, 없으면 원본 free 값). 대응표: products/trailer/existing.md
-- AI 라우팅·AI 기능(원본 13장)은 org/0002_ai.sql. 전제: core 20261119000100(touch_updated_at) · 20261120000100~0500(audit·credits·jobs·ai) · 20261120000800(mark_job_delivered).
-- 되돌림: drop schema nomad_trailer cascade; drop schema nomad_trailer_private cascade;
--   delete from storage.buckets where id in ('trailer-files', 'trailer-media', 'trailer-catalog', 'trailer-previews');
--   delete from nomad_core.plan_features where product_code = 'trailer'; delete from nomad_core.features where product_code = 'trailer';
-- SQLSTATE(원본 유지): TR001 상태 전이 · TR002 같은 대상 실행 중 · TR003 권리 확인 없음 · TR004 선행 단계 · TR005 플랜 한도
--   · TR006 인용 · TR007 엔드카드 · TR008 대가성 문구 · TR009 승인 링크 · TR010 FLORA · TR011 음악 권리 · TR409 동시 편집
begin;

create schema nomad_trailer;
create schema nomad_trailer_private;
revoke all on schema nomad_trailer, nomad_trailer_private from public, anon, authenticated;
grant usage on schema nomad_trailer to authenticated, service_role;  -- anon 0(D8: 공개 경로는 서버가 service_role로)
grant usage on schema nomad_trailer_private to service_role;
alter default privileges in schema nomad_trailer revoke execute on functions from public;
alter default privileges in schema nomad_trailer_private revoke execute on functions from public;
comment on schema nomad_trailer is 'book-trailer: 원고·책 → 북트레일러 영상 (책, 브리프, 스토리보드, 에셋, 렌더, 구매 링크)';

insert into nomad_core.products (code, name) values ('trailer', 'NOMAD Book Trailer') on conflict (code) do nothing;
-- 플랜: 원본 publisher→A, creator→B, free→C. 구독이 끊기면(구독 없음·inactive·만료 = C) 원본 무료 플랜 기능만 남는다.
-- trailer = 작업 공간(무료 포함 전 플랜) · 나머지는 유료 기능(원본 features 불리언·배열).
insert into nomad_core.plans (product_code, code, name) values ('trailer', 'A', 'A'), ('trailer', 'B', 'B'), ('trailer', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('trailer', 'trailer', '북트레일러 작업 공간'),
  ('trailer', 'formats_all', '전체 화면비(16:9·1:1·4:5·표지 루프)'),
  ('trailer', 'render_1080p', '1080p 렌더'),
  ('trailer', 'no_watermark', '워터마크 없는 렌더'),
  ('trailer', 'premium_templates', '프리미엄 템플릿'),
  ('trailer', 'music_upload', '음악 업로드'),
  ('trailer', 'sns_upload', 'SNS 업로드'),
  ('trailer', 'flora_import', 'FLORA 책 가져오기'),
  ('trailer', 'approval_links', '외부 승인 링크'),
  ('trailer', 'priority_render', '우선 렌더')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'trailer', p, 'trailer' from unnest(array['A', 'B', 'C']) p
union all
select 'trailer', p, f from unnest(array['A', 'B']) p,
  unnest(array['formats_all', 'render_1080p', 'no_watermark', 'premium_templates', 'music_upload', 'sns_upload', 'flora_import']) f
union all
select 'trailer', 'A', f from unnest(array['approval_links', 'priority_render']) f
on conflict do nothing;
-- plan_limits 키(수치 시드 안 함, 없으면 원본 free 값): max_books(1) · max_trailers_per_book(1) · brand_kits_max(1) · max_duration_s(30)
--   · members_max · storage_mb (existing.md 표)

-- =====================================================================
-- 1. 도우미
-- =====================================================================
-- 정책용(사용자 문맥, authenticated 실행): 기능 이용권 + 멤버십(has_feature가 둘 다 본다)
create function nomad_trailer.has_access(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.has_feature(target_organization, 'trailer', 'trailer'), false) $$;

-- 쓰기: owner·admin·editor(원본 member) + 이용권
create function nomad_trailer.can_edit(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin', 'editor'), false)
     and nomad_trailer.has_access(target_organization)
$$;

-- 카탈로그 읽기: trailer 이용권이 있는 조직의 멤버
create function nomad_trailer.has_catalog_access() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_core.memberships m
                 where m.user_id = (select auth.uid()) and nomad_core.has_feature(m.organization_id, 'trailer', 'trailer'))
$$;

-- 팔레트: 배열 3~6개, {"role", "hex": "#RRGGBB"}, 역할 중복 불가(CHECK에서 씀)
create function nomad_trailer.valid_palette(p jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) between 3 and 6
     and not exists (
       select 1 from jsonb_array_elements(p) as e(item)
       where jsonb_typeof(e.item) <> 'object'
          or coalesce(e.item ->> 'hex', '') !~ '^#[0-9A-Fa-f]{6}$'
          or coalesce(e.item ->> 'role', '') not in ('background', 'surface', 'text', 'accent', 'accent2', 'muted'))
     and (select count(distinct e.item ->> 'role') from jsonb_array_elements(p) as e(item)) = jsonb_array_length(p)
$$;

-- 해시태그: 30개 이하, 각 1~50자, 공백·# 중복 없음
create function nomad_trailer.valid_hashtags(p text[]) returns boolean
language sql immutable set search_path = ''
as $$
  select coalesce(cardinality(p), 0) <= 30
     and not exists (select 1 from unnest(p) as u(tag) where u.tag !~ '^#?[^[:space:]#]{1,50}$')
$$;

-- 서버 전용(비노출): 수량 한도(plan_limits, 없으면 원본 free 값) · 현재 플랜 코드(구독 없음 = C)
create function nomad_trailer_private.org_limit(target_organization uuid, target_key text, fallback integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_plan_limit(target_organization, 'trailer', target_key), fallback) $$;

create function nomad_trailer_private.plan_code(target_organization uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce((select s.plan_code from nomad_core.subscriptions s
                   where s.organization_id = target_organization and s.product_code = 'trailer' and s.status = 'active'
                     and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
                   order by s.starts_at desc limit 1), 'C')
$$;

-- =====================================================================
-- 2. 카탈로그 (플랫폼 소유. 쓰기는 service_role, 읽기는 trailer 사용자)
-- =====================================================================
create table nomad_trailer.runtime_config (
  key        text primary key constraint runtime_config_key_check check (key ~ '^[a-z][a-z0-9_]{2,60}$'),
  value_int  integer not null,
  note       text,
  updated_at timestamptz not null default now()
);
comment on table nomad_trailer.runtime_config is '운영 상수(서버 전용, 사용자 grant 없음).';

create function nomad_trailer_private.config_int(p_key text, p_default integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce((select c.value_int from nomad_trailer.runtime_config c where c.key = p_key), p_default) $$;

create table nomad_trailer.grammars (
  code             text primary key constraint grammars_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name             text not null constraint grammars_name_check check (char_length(name) between 1 and 60),
  description      text constraint grammars_description_check check (description is null or char_length(description) <= 500),
  book_genres      text[] not null default '{}',
  beats            jsonb not null,
  narration_style  text not null default 'voiceover'
                   constraint grammars_narration_style_check check (narration_style in ('voiceover', 'quote_reading', 'none')),
  music_mood       text constraint grammars_music_mood_check check (music_mood is null or music_mood ~ '^[a-z][a-z0-9_]{1,30}$'),
  status           text not null default 'draft' constraint grammars_status_check check (status in ('draft', 'published', 'retired')),
  version          integer not null default 1 constraint grammars_version_check check (version >= 1),
  sort_order       integer not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint grammars_beats_check check (jsonb_typeof(beats) = 'array' and jsonb_array_length(beats) between 3 and 10),
  constraint grammars_book_genres_check check (
    book_genres <@ array['novel', 'essay', 'poetry', 'self_help', 'nonfiction_business', 'it_tech', 'children', 'fantasy_genre', 'other']::text[])
);
comment on table nomad_trailer.grammars is '장르 트레일러 문법(이야기 비트). 플랫폼 카탈로그, 공개 행만 trailer 사용자 읽기.';

create table nomad_trailer.templates (
  code            text primary key constraint templates_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name            text not null constraint templates_name_check check (char_length(name) between 1 and 60),
  grammar_code    text not null references nomad_trailer.grammars(code) on delete restrict,
  composition_id  text not null constraint templates_composition_id_check check (composition_id ~ '^[A-Za-z][A-Za-z0-9-]{1,60}$'),
  formats         text[] not null,
  tier            text not null default 'free' constraint templates_tier_check check (tier in ('free', 'premium')),
  params_schema   jsonb not null default '{}'::jsonb,
  preview_path    text,
  status          text not null default 'draft' constraint templates_status_check check (status in ('draft', 'published', 'retired')),
  version         integer not null default 1 constraint templates_version_check check (version >= 1),
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint templates_formats_check check (
    cardinality(formats) >= 1
    and formats <@ array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5', 'cover_loop']::text[])
);
create index templates_grammar_idx on nomad_trailer.templates (grammar_code);
comment on table nomad_trailer.templates is 'Remotion 컴포지션 템플릿. premium은 기능 premium_templates(A·B) 필요.';

create table nomad_trailer.music_tracks (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique constraint music_tracks_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  title                  text not null constraint music_tracks_title_check check (char_length(title) between 1 and 80),
  mood                   text not null constraint music_tracks_mood_check check (mood ~ '^[a-z][a-z0-9_]{1,30}$'),
  bpm                    integer constraint music_tracks_bpm_check check (bpm is null or bpm between 40 and 220),
  duration_ms            integer not null constraint music_tracks_duration_check check (duration_ms between 5000 and 600000),
  tier                   text not null default 'free' constraint music_tracks_tier_check check (tier in ('free', 'premium')),
  license_source         text not null
                         constraint music_tracks_license_source_check check (license_source in ('in_house', 'commissioned', 'licensed_commercial')),
  license_ref            text not null constraint music_tracks_license_ref_check check (char_length(license_ref) between 3 and 200),
  commercial_use_allowed boolean not null default true,
  license_verified_at    timestamptz,
  license_verified_by    uuid,
  storage_path           text not null,      -- 버킷 trailer-catalog(비공개, 렌더러만)
  preview_path           text,               -- 버킷 trailer-previews(공개 30초 미리듣기)
  status                 text not null default 'draft' constraint music_tracks_status_check check (status in ('draft', 'published', 'retired')),
  sort_order             integer not null default 0,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint music_tracks_publish_license_check
    check (status <> 'published' or (license_verified_at is not null and license_verified_by is not null and commercial_use_allowed))
);
comment on table nomad_trailer.music_tracks is '라이선스 음악 카탈로그. 원본 경로(storage_path)는 사용자 컬럼 grant에서 뺀다.';

-- =====================================================================
-- 3. 콘텐츠 (조직 소유. 멤버 쓰기 + 수량 한도 트리거)
-- =====================================================================
create table nomad_trailer.books (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  title               text not null constraint books_title_check check (char_length(title) between 1 and 200),
  subtitle            text constraint books_subtitle_check check (subtitle is null or char_length(subtitle) <= 200),
  author_name         text constraint books_author_name_check check (author_name is null or char_length(author_name) <= 100),
  publisher_name      text constraint books_publisher_name_check check (publisher_name is null or char_length(publisher_name) <= 100),
  genre               text not null default 'other'
                      constraint books_genre_check check (genre in
                      ('novel', 'essay', 'poetry', 'self_help', 'nonfiction_business', 'it_tech', 'children', 'fantasy_genre', 'other')),
  language            text not null default 'ko' constraint books_language_check check (language in ('ko', 'en', 'ja')),
  isbn                text constraint books_isbn_check check (isbn is null or isbn ~ '^97[89][0-9]{10}$'),
  published_on        date,
  description         text constraint books_description_check check (description is null or char_length(description) <= 2000),
  audience            text constraint books_audience_check check (audience is null or char_length(audience) <= 300),
  source              text not null default 'upload' constraint books_source_check check (source in ('upload', 'paste', 'flora')),
  flora_book_id       uuid,                  -- FLORA 책 id(FK 없음: 제품 간 결합을 만들지 않는다)
  manuscript_path     text,                  -- 버킷 trailer-files <organization_id>/trailer/books/<book_id>/manuscript.<ext>
  manuscript_sha256   text constraint books_manuscript_sha_check check (manuscript_sha256 is null or manuscript_sha256 ~ '^[0-9a-f]{64}$'),
  manuscript_chars    integer not null default 0 constraint books_manuscript_chars_check check (manuscript_chars >= 0),
  cover_path          text,
  digest_status       text not null default 'none'
                      constraint books_digest_status_check check (digest_status in ('none', 'queued', 'ready', 'failed')),
  rights_ack_version  text constraint books_rights_ack_version_check check (rights_ack_version is null or rights_ack_version ~ '^rights-[0-9]{4}-[0-9]{2}-v[0-9]+$'),
  rights_ack_at       timestamptz,
  rights_ack_by       uuid,
  status              text not null default 'active' constraint books_status_check check (status in ('active', 'archived')),
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  constraint books_id_org_uniq unique (id, organization_id),
  constraint books_manuscript_path_check check (manuscript_path is null or (
    split_part(manuscript_path, '/', 1) = organization_id::text
    and manuscript_path ~ '^[0-9a-f-]{36}/trailer/books/[0-9a-f-]{36}/manuscript\.(pdf|epub|docx|md|txt)$')),
  constraint books_cover_path_check check (cover_path is null or (
    split_part(cover_path, '/', 1) = organization_id::text
    and cover_path ~ '^[0-9a-f-]{36}/trailer/books/[0-9a-f-]{36}/cover\.(png|jpg|jpeg|webp)$')),
  constraint books_rights_ack_check check ((rights_ack_version is null) = (rights_ack_at is null)),
  constraint books_flora_source_check check ((source = 'flora') = (flora_book_id is not null))
);
create index books_org_updated_idx on nomad_trailer.books (organization_id, updated_at);
create unique index books_org_flora_uniq on nomad_trailer.books (organization_id, flora_book_id)
  where flora_book_id is not null and deleted_at is null;  -- 같은 FLORA 책 중복 가져오기 금지
comment on table nomad_trailer.books is '책(원고 메타). 원문 텍스트는 DB에 두지 않는다. 소프트 삭제(deleted_at)·증분 동기화 대상.';

create table nomad_trailer.purchase_links (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id         uuid not null,
  store           text not null constraint purchase_links_store_check check (store in
                  ('kyobo', 'yes24', 'aladin', 'ridibooks', 'millie', 'kdp', 'smartstore', 'own_site', 'other')),
  label           text constraint purchase_links_label_check check (label is null or char_length(label) <= 40),
  url             text not null constraint purchase_links_url_check check (url ~* '^https://[^[:space:]]+$' and char_length(url) <= 2000),
  is_affiliate    boolean not null default false,
  short_code      text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)
                  constraint purchase_links_short_code_check check (short_code ~ '^[0-9a-z]{6,16}$'),
  click_count     bigint not null default 0,
  is_active       boolean not null default true,
  sort_order      integer not null default 0,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint purchase_links_book_fk foreign key (book_id, organization_id) references nomad_trailer.books (id, organization_id) on delete cascade,
  constraint purchase_links_id_org_uniq unique (id, organization_id)
);
create index purchase_links_book_idx on nomad_trailer.purchase_links (book_id, sort_order);
create index purchase_links_org_updated_idx on nomad_trailer.purchase_links (organization_id, updated_at);
comment on table nomad_trailer.purchase_links is '구매 링크(책당 최대 10). click_count는 서버만 갱신(컬럼 grant 제외).';

create table nomad_trailer.brand_kits (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id         uuid,                        -- null 이면 조직 기본 키트
  name            text not null constraint brand_kits_name_check check (char_length(name) between 1 and 60),
  palette         jsonb not null constraint brand_kits_palette_check check (nomad_trailer.valid_palette(palette)),
  font_display    text not null default 'pretendard'
                  constraint brand_kits_font_display_check check (font_display in
                  ('pretendard', 'noto_sans_kr', 'noto_serif_kr', 'gowun_batang', 'nanum_myeongjo', 'black_han_sans', 'do_hyeon', 'ibm_plex_sans_kr')),
  font_body       text not null default 'pretendard'
                  constraint brand_kits_font_body_check check (font_body in
                  ('pretendard', 'noto_sans_kr', 'noto_serif_kr', 'gowun_batang', 'nanum_myeongjo', 'ibm_plex_sans_kr')),
  logo_path       text,
  source          text not null default 'manual' constraint brand_kits_source_check check (source in ('cover_extract', 'manual')),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint brand_kits_book_fk foreign key (book_id, organization_id) references nomad_trailer.books (id, organization_id) on delete cascade,
  constraint brand_kits_id_org_uniq unique (id, organization_id),
  constraint brand_kits_logo_path_check check (logo_path is null or (
    split_part(logo_path, '/', 1) = organization_id::text
    and logo_path ~ '^[0-9a-f-]{36}/trailer/brand/[0-9a-f-]{36}\.(png|webp)$'))  -- svg 금지(스크립트 삽입)
);
create index brand_kits_org_updated_idx on nomad_trailer.brand_kits (organization_id, updated_at);
create index brand_kits_book_idx on nomad_trailer.brand_kits (book_id) where book_id is not null;
comment on table nomad_trailer.brand_kits is '브랜드 키트(팔레트·폰트·로고). 조직 기본(book_id null) 또는 책별.';

create table nomad_trailer.trailers (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id             uuid not null,
  title               text not null constraint trailers_title_check check (char_length(title) between 1 and 120),
  grammar_code        text not null references nomad_trailer.grammars(code) on delete restrict,
  template_code       text not null references nomad_trailer.templates(code) on delete restrict,
  brand_kit_id        uuid,
  formats             text[] not null default array['vertical_9_16']::text[],
  duration_s          integer not null default 30 constraint trailers_duration_check check (duration_s in (15, 30, 45, 60, 90)),
  language            text not null default 'ko' constraint trailers_language_check check (language in ('ko', 'en', 'ja')),
  spoiler_level       text not null default 'teaser' constraint trailers_spoiler_check check (spoiler_level in ('none', 'teaser', 'light')),
  narration_mode      text not null default 'voiceover' constraint trailers_narration_mode_check check (narration_mode in ('voiceover', 'none')),
  voice_pref          text not null default 'auto' constraint trailers_voice_pref_check check (voice_pref in ('auto', 'elevenlabs', 'oss-voice')),
  voice               jsonb not null default '{}'::jsonb,   -- 같은 목소리 규칙: 첫 내레이션 때 서버가 고정
  music_track_id      uuid references nomad_trailer.music_tracks(id) on delete set null,
  music_path          text,                  -- 버킷 trailer-files <organization_id>/trailer/music/<uuid>.(mp3|wav)
  music_rights_ack    boolean not null default false,
  music_rights_ack_at timestamptz,
  music_rights_ack_by uuid,
  current_brief_id    uuid,
  selected_hook       smallint constraint trailers_selected_hook_check check (selected_hook is null or selected_hook between 0 and 4),
  storyboard_version  integer not null default 0,
  status              text not null default 'active' constraint trailers_status_check check (status in ('active', 'approved', 'archived')),
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint trailers_book_fk foreign key (book_id, organization_id) references nomad_trailer.books (id, organization_id) on delete cascade,
  constraint trailers_brand_kit_fk foreign key (brand_kit_id, organization_id) references nomad_trailer.brand_kits (id, organization_id) on delete set null (brand_kit_id),
  constraint trailers_id_org_uniq unique (id, organization_id),
  constraint trailers_formats_check check (
    cardinality(formats) between 1 and 5
    and formats <@ array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5', 'cover_loop']::text[]),
  constraint trailers_music_choice_check check (music_track_id is null or music_path is null),
  constraint trailers_music_path_check check (music_path is null or (
    split_part(music_path, '/', 1) = organization_id::text
    and music_path ~ '^[0-9a-f-]{36}/trailer/music/[0-9a-f-]{36}\.(mp3|wav)$')),
  constraint trailers_voice_shape_check check (jsonb_typeof(voice) = 'object')
);
create index trailers_org_updated_idx on nomad_trailer.trailers (organization_id, updated_at);
create index trailers_book_idx on nomad_trailer.trailers (book_id);
comment on table nomad_trailer.trailers is '트레일러 1편. voice·storyboard_version·음악 권리 확인 기록은 서버·트리거만.';

create table nomad_trailer.briefs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  trailer_id      uuid not null,
  version         integer not null default 0,   -- 트리거가 트레일러별 max+1
  source          text not null constraint briefs_source_check check (source in ('ai', 'manual')),
  content         jsonb not null,
  ai_run_id       uuid,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  constraint briefs_trailer_fk foreign key (trailer_id, organization_id) references nomad_trailer.trailers (id, organization_id) on delete cascade,
  constraint briefs_id_org_uniq unique (id, organization_id),
  constraint briefs_trailer_version_uniq unique (trailer_id, version),
  constraint briefs_content_shape_check check (jsonb_typeof(content) = 'object' and pg_column_size(content) <= 65536),
  constraint briefs_ai_run_check check (source = 'ai' or ai_run_id is null)
);
create index briefs_org_created_idx on nomad_trailer.briefs (organization_id, created_at);
comment on table nomad_trailer.briefs is '브리프 불변 버전. AI 버전은 서버, 사용자 편집은 manual 새 행만(수정·삭제 없음).';

alter table nomad_trailer.trailers add constraint trailers_current_brief_fk
  foreign key (current_brief_id, organization_id) references nomad_trailer.briefs (id, organization_id) on delete set null (current_brief_id);

create table nomad_trailer.scenes (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  trailer_id      uuid not null,
  position        integer not null constraint scenes_position_check check (position between 0 and 39),
  kind            text not null constraint scenes_kind_check check (kind in
                  ('title_card', 'hook_text', 'quote_card', 'image_scene', 'character_scene', 'narration_card', 'cta_card', 'end_card')),
  duration_ms     integer not null default 3000 constraint scenes_duration_check check (duration_ms between 500 and 15000),
  text            text constraint scenes_text_check check (text is null or char_length(text) <= 160),
  narration       text constraint scenes_narration_check check (narration is null or char_length(narration) <= 400),
  quote_ref       jsonb,
  quote_verified  boolean not null default false,
  visual          jsonb not null default '{}'::jsonb,
  music_cue       text constraint scenes_music_cue_check check (music_cue is null or music_cue in ('intro', 'build', 'drop', 'calm', 'outro')),
  revision        integer not null default 1,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint scenes_trailer_fk foreign key (trailer_id, organization_id) references nomad_trailer.trailers (id, organization_id) on delete cascade,
  constraint scenes_id_org_uniq unique (id, organization_id),
  constraint scenes_trailer_position_uniq unique (trailer_id, position) deferrable initially deferred,
  constraint scenes_visual_shape_check check (jsonb_typeof(visual) = 'object' and pg_column_size(visual) <= 16384),
  constraint scenes_quote_ref_check check (quote_ref is null or jsonb_typeof(quote_ref) = 'object'),
  constraint scenes_quote_verified_check check (not quote_verified or (kind = 'quote_card' and quote_ref is not null))
);
create unique index scenes_one_end_card_idx on nomad_trailer.scenes (trailer_id) where kind = 'end_card';
create index scenes_org_updated_idx on nomad_trailer.scenes (organization_id, updated_at);
comment on table nomad_trailer.scenes is '스토리보드 장면. 엔드카드는 트리거가 만들고 사용자가 만들거나 지울 수 없다. revision = 낙관적 동시성.';

create table nomad_trailer.metadata_packs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  trailer_id      uuid not null,
  platform        text not null constraint metadata_packs_platform_check check (platform in
                  ('youtube_shorts', 'youtube', 'instagram', 'tiktok', 'naver_clip', 'bookstore', 'generic')),
  title           text not null constraint metadata_packs_title_check check (char_length(title) between 1 and 100),
  description     text not null default '' constraint metadata_packs_description_check check (char_length(description) <= 5000),
  hashtags        text[] not null default '{}' constraint metadata_packs_hashtags_check check (nomad_trailer.valid_hashtags(hashtags)),
  link_ids        uuid[] not null default '{}' constraint metadata_packs_link_ids_check check (cardinality(link_ids) <= 10),
  has_affiliate   boolean not null default false,
  disclosure      text,
  source          text not null default 'manual' constraint metadata_packs_source_check check (source in ('ai', 'manual')),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint metadata_packs_trailer_fk foreign key (trailer_id, organization_id) references nomad_trailer.trailers (id, organization_id) on delete cascade,
  constraint metadata_packs_trailer_platform_uniq unique (trailer_id, platform),
  constraint metadata_packs_disclosure_check check (
    not has_affiliate or (disclosure is not null and char_length(disclosure) >= 10 and left(description, char_length(disclosure)) = disclosure))
);
create index metadata_packs_org_updated_idx on nomad_trailer.metadata_packs (organization_id, updated_at);
comment on table nomad_trailer.metadata_packs is '플랫폼별 메타데이터. 제휴 링크가 있으면 대가성 문구가 설명 첫 줄(트리거+CHECK).';

-- =====================================================================
-- 4. 서버 기록 (쓰기는 service_role·소유자 함수만)
-- =====================================================================
create table nomad_trailer.book_digests (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  book_id           uuid not null,
  manuscript_sha256 text not null constraint book_digests_sha_check check (manuscript_sha256 ~ '^[0-9a-f]{64}$'),
  chapters          jsonb not null,
  characters        jsonb not null default '[]'::jsonb,
  themes            jsonb not null default '[]'::jsonb,
  settings          jsonb not null default '[]'::jsonb,
  ai_run_id         uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint book_digests_book_fk foreign key (book_id, organization_id) references nomad_trailer.books (id, organization_id) on delete cascade,
  constraint book_digests_book_uniq unique (book_id),
  constraint book_digests_chapters_check check (jsonb_typeof(chapters) = 'array' and jsonb_array_length(chapters) between 1 and 300),
  constraint book_digests_size_check check (pg_column_size(chapters) + pg_column_size(characters) + pg_column_size(themes) <= 524288)
);
create index book_digests_org_idx on nomad_trailer.book_digests (organization_id);
comment on table nomad_trailer.book_digests is '원고 분석 결과(책당 최신 1행). 서버 쓰기만.';

create table nomad_trailer.link_clicks (
  id              bigint generated always as identity primary key,
  link_id         uuid not null references nomad_trailer.purchase_links(id) on delete cascade,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  clicked_at      timestamptz not null default now(),
  referrer        text constraint link_clicks_referrer_check check (referrer is null or char_length(referrer) <= 500),
  ip_hash         text constraint link_clicks_ip_hash_check check (ip_hash is null or ip_hash ~ '^[0-9a-f]{64}$'),
  user_agent      text constraint link_clicks_ua_check check (user_agent is null or char_length(user_agent) <= 300),
  tag             text constraint link_clicks_tag_check check (tag is null or tag ~ '^[a-z0-9_:-]{1,80}$')
);
create index link_clicks_link_idx on nomad_trailer.link_clicks (link_id, clicked_at desc);
create index link_clicks_org_idx on nomad_trailer.link_clicks (organization_id, clicked_at desc);
comment on table nomad_trailer.link_clicks is '구매 링크 클릭(추가 전용). 공개 리다이렉트 서버가 record_link_click(service_role)으로만 기록.';

create table nomad_trailer.scene_assets (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  scene_id        uuid not null,
  kind            text not null constraint scene_assets_kind_check check (kind in ('image', 'user_image', 'narration')),
  slot            text generated always as (case when kind = 'narration' then 'audio' else 'visual' end) stored,
  status          text not null default 'ready' constraint scene_assets_status_check check (status in ('ready', 'superseded')),
  source          text not null constraint scene_assets_source_check check (source in ('ai_generated', 'upload')),
  ai_generated    boolean not null,
  provider        text,
  model           text,
  seed            bigint,
  voice_id        text,
  storage_path    text not null,             -- 버킷 trailer-media <organization_id>/trailer/assets/<scene_id>/<uuid>.<ext>
  width           integer,
  height          integer,
  duration_ms     integer constraint scene_assets_duration_check check (duration_ms is null or duration_ms between 100 and 60000),
  chars           integer constraint scene_assets_chars_check check (chars is null or chars >= 0),
  bytes           bigint not null default 0,
  rights_ack      boolean not null default false,
  run_id          uuid,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  constraint scene_assets_scene_fk foreign key (scene_id, organization_id) references nomad_trailer.scenes (id, organization_id) on delete cascade,
  constraint scene_assets_ai_source_check check ((source = 'ai_generated') = ai_generated),
  constraint scene_assets_ai_model_check check (not ai_generated or (provider is not null and model is not null)),
  constraint scene_assets_kind_source_check check ((kind = 'user_image') = (source = 'upload')),
  constraint scene_assets_upload_rights_check check (source <> 'upload' or rights_ack),
  constraint scene_assets_path_check check (
    split_part(storage_path, '/', 1) = organization_id::text
    and storage_path ~ '^[0-9a-f-]{36}/trailer/assets/[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|webp|jpg|mp3|wav)$')
);
create unique index scene_assets_one_ready_idx on nomad_trailer.scene_assets (scene_id, slot) where status = 'ready';
create index scene_assets_org_idx on nomad_trailer.scene_assets (organization_id, created_at desc);
comment on table nomad_trailer.scene_assets is '장면 에셋(AI 이미지·내레이션·사용자 이미지). 장면·슬롯마다 ready 1개. 서버 쓰기만.';

create table nomad_trailer.generation_runs (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  kind              text not null constraint generation_runs_kind_check check (kind in
                    ('digest', 'brief', 'storyboard', 'scene_image', 'narration', 'meta')),
  book_id           uuid not null references nomad_trailer.books(id) on delete cascade,
  trailer_id        uuid references nomad_trailer.trailers(id) on delete cascade,
  scene_id          uuid references nomad_trailer.scenes(id) on delete cascade,
  status            text not null default 'queued'
                    constraint generation_runs_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  credits_reserved  integer not null default 0 constraint generation_runs_credits_check check (credits_reserved >= 0),
  credit_ledger_id  uuid references nomad_core.credit_ledger(id),
  idempotency_key   text not null unique,
  job_id            uuid references nomad_core.jobs(id) on delete set null,
  ai_run_id         uuid,                    -- nomad_core.ai_runs.id(외래키 없음, core와 같은 방식)
  payload           jsonb not null default '{}'::jsonb,
  progress          jsonb not null default '{}'::jsonb,
  error             text,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  started_at        timestamptz,
  finished_at       timestamptz,
  constraint generation_runs_target_check check (
    (kind = 'digest' and trailer_id is null and scene_id is null)
    or (kind in ('brief', 'storyboard', 'meta') and trailer_id is not null and scene_id is null)
    or (kind in ('scene_image', 'narration') and trailer_id is not null and scene_id is not null))
);
create index generation_runs_org_created_idx on nomad_trailer.generation_runs (organization_id, created_at desc);
create index generation_runs_active_idx on nomad_trailer.generation_runs (organization_id, status) where status in ('queued', 'running');
create index generation_runs_job_idx on nomad_trailer.generation_runs (job_id) where job_id is not null;
comment on table nomad_trailer.generation_runs is 'AI 실행. 크레딧 선차감(nomad_core.consume_credits)·작업(nomad_core.enqueue_job)과 1:1. 서버 쓰기만.';

create table nomad_trailer.renders (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  trailer_id       uuid not null,
  format           text not null constraint renders_format_check check (format in
                   ('vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5', 'cover_loop')),
  resolution       text not null constraint renders_resolution_check check (resolution in ('480p', '720p', '1080p')),
  status           text not null default 'queued'
                   constraint renders_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  plan_code        text not null,            -- 렌더 시점 플랜(A·B·C, 구독 없음 = C)
  watermark        boolean not null,
  ai_label         boolean not null,
  snapshot         jsonb not null,
  credits          integer not null default 0 constraint renders_credits_check check (credits >= 0),
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  job_id           uuid references nomad_core.jobs(id) on delete set null,
  request_id       uuid not null unique,
  output_path      text,                     -- 버킷 trailer-media <organization_id>/trailer/renders/<render_id>/trailer.mp4
  poster_path      text,
  srt_path         text,
  bytes            bigint,
  duration_ms      integer,
  error            text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  expires_at       timestamptz,
  constraint renders_trailer_fk foreign key (trailer_id, organization_id) references nomad_trailer.trailers (id, organization_id) on delete cascade,
  constraint renders_ai_label_check check (ai_label or not coalesce((snapshot ->> 'has_ai_assets')::boolean, true)),
  constraint renders_preview_watermark_check check (resolution <> '480p' or watermark),
  constraint renders_output_check check (status <> 'succeeded' or output_path is not null)
);
create index renders_trailer_idx on nomad_trailer.renders (trailer_id, created_at desc);
create index renders_org_idx on nomad_trailer.renders (organization_id, created_at desc);
create index renders_active_idx on nomad_trailer.renders (organization_id, status) where status in ('queued', 'running');
create index renders_job_idx on nomad_trailer.renders (job_id) where job_id is not null;
create index renders_expiry_idx on nomad_trailer.renders (expires_at) where status = 'succeeded';
comment on table nomad_trailer.renders is '영상 렌더. 워터마크·AI 표시·플랜은 서버가 결정(사용자 입력 아님). 서버 쓰기만.';

create table nomad_trailer.reviews (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  trailer_id      uuid not null,
  render_ids      uuid[] not null constraint reviews_render_ids_check check (cardinality(render_ids) between 1 and 5),
  token_sha256    text not null unique constraint reviews_token_check check (token_sha256 ~ '^[0-9a-f]{64}$'),
  reviewer_label  text not null constraint reviews_label_check check (char_length(reviewer_label) between 1 and 60),
  status          text not null default 'pending'
                  constraint reviews_status_check check (status in ('pending', 'approved', 'changes_requested', 'expired', 'revoked')),
  expires_at      timestamptz not null,
  decided_at      timestamptz,
  comment         text constraint reviews_comment_check check (comment is null or char_length(comment) <= 1000),
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint reviews_trailer_fk foreign key (trailer_id, organization_id) references nomad_trailer.trailers (id, organization_id) on delete cascade
);
create index reviews_trailer_idx on nomad_trailer.reviews (trailer_id, created_at desc);
create index reviews_org_idx on nomad_trailer.reviews (organization_id);
comment on table nomad_trailer.reviews is '외부 승인 링크(기능 approval_links, A). 토큰 원문 저장 안 함(sha256, 사용자 컬럼 grant 제외).';

-- =====================================================================
-- 5. 트리거
--   서버 판별: current_user가 authenticated·anon이 아니면 서버(service_role 직접 또는 소유자 SECURITY DEFINER 함수 안).
--   원본 core.is_privileged_session(current_user 기준)과 같은 뜻 — nomad_core.is_privileged_session은 JWT 기준이라
--   사용자 RPC(acknowledge_rights) 안에서 거짓이 되므로 쓰지 않는다.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['runtime_config', 'grammars', 'templates', 'music_tracks', 'books', 'purchase_links', 'brand_kits',
                           'trailers', 'scenes', 'metadata_packs', 'book_digests', 'generation_runs', 'renders', 'reviews'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_trailer.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
end $$;

-- 서버 기록·카탈로그: 사용자 세션 쓰기 42501(grant 없음과 이중 잠금)
create function nomad_trailer.guard_server_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'nomad_trailer.%: server-managed table', tg_table_name using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['runtime_config', 'grammars', 'templates', 'music_tracks', 'book_digests', 'link_clicks',
                           'scene_assets', 'generation_runs', 'renders', 'reviews'] loop
    execute format('create trigger %1$s_guard_write before insert or update or delete on nomad_trailer.%1$I for each row execute function nomad_trailer.guard_server_write()', t);
  end loop;
end $$;

-- 수량 한도(책 수, 책당 트레일러, 브랜드 키트, 책당 구매 링크). 사용자 INSERT만. 한도 = plan_limits(없으면 원본 free 값).
create function nomad_trailer.enforce_plan_limits() returns trigger
language plpgsql set search_path = ''
as $$
declare v_limit integer; v_count integer;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('trailer:limits:' || new.organization_id::text, 0));
  if tg_table_name = 'books' then
    v_limit := coalesce(nomad_core.plan_limit(new.organization_id, 'trailer', 'max_books'), 1);
    select count(*) into v_count from nomad_trailer.books b where b.organization_id = new.organization_id and b.deleted_at is null;
  elsif tg_table_name = 'trailers' then
    v_limit := coalesce(nomad_core.plan_limit(new.organization_id, 'trailer', 'max_trailers_per_book'), 1);
    select count(*) into v_count from nomad_trailer.trailers t where t.book_id = new.book_id;
  elsif tg_table_name = 'brand_kits' then
    v_limit := coalesce(nomad_core.plan_limit(new.organization_id, 'trailer', 'brand_kits_max'), 1);
    select count(*) into v_count from nomad_trailer.brand_kits k where k.organization_id = new.organization_id;
  elsif tg_table_name = 'purchase_links' then
    v_limit := 10;   -- 플랜과 무관한 고정 상한
    select count(*) into v_count from nomad_trailer.purchase_links l where l.book_id = new.book_id;
  else
    return new;
  end if;
  if v_count >= v_limit then
    raise exception 'trailer: plan limit reached on % (limit %)', tg_table_name, v_limit using errcode = 'TR005';
  end if;
  return new;
end;
$$;
create trigger books_plan_limits before insert on nomad_trailer.books for each row execute function nomad_trailer.enforce_plan_limits();
create trigger trailers_plan_limits before insert on nomad_trailer.trailers for each row execute function nomad_trailer.enforce_plan_limits();
create trigger brand_kits_plan_limits before insert on nomad_trailer.brand_kits for each row execute function nomad_trailer.enforce_plan_limits();
create trigger purchase_links_plan_limits before insert on nomad_trailer.purchase_links for each row execute function nomad_trailer.enforce_plan_limits();

-- books: 서버 컬럼 보호(컬럼 grant와 이중), 원고 경로가 바뀌면 분석 상태 초기화
create function nomad_trailer.books_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.manuscript_sha256  := old.manuscript_sha256;
    new.manuscript_chars   := old.manuscript_chars;
    new.digest_status      := old.digest_status;
    new.rights_ack_version := old.rights_ack_version;
    new.rights_ack_at      := old.rights_ack_at;
    new.rights_ack_by      := old.rights_ack_by;
    new.source             := old.source;
    new.flora_book_id      := old.flora_book_id;
    new.organization_id    := old.organization_id;
    -- 소프트 삭제 시각은 클라이언트 값을 믿지 않는다: null(복원) 또는 now()
    if new.deleted_at is distinct from old.deleted_at and new.deleted_at is not null then
      new.deleted_at := now();
    end if;
    if new.manuscript_path is distinct from old.manuscript_path then
      new.manuscript_sha256 := null;
      new.manuscript_chars  := 0;
      new.digest_status     := 'none';
    end if;
  end if;
  return new;
end;
$$;
create trigger books_before_update before update on nomad_trailer.books for each row execute function nomad_trailer.books_before_update();

-- trailers: 승인은 성공 렌더(480p 제외) 필요, 음악 권리 확인 기록, 서버 컬럼 보호
create function nomad_trailer.trailers_before_write() returns trigger
language plpgsql set search_path = ''
as $$
declare v_client boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'INSERT' then
    if v_client then
      new.voice := '{}'::jsonb;
      new.storyboard_version := 0;
      new.current_brief_id := null;
      new.status := 'active';
    end if;
  else
    if v_client then
      new.voice := old.voice;
      new.storyboard_version := old.storyboard_version;
      new.organization_id := old.organization_id;
      new.book_id := old.book_id;
    end if;
    if new.status = 'approved' and old.status <> 'approved'
       and not exists (select 1 from nomad_trailer.renders r where r.trailer_id = new.id and r.status = 'succeeded' and r.resolution <> '480p') then
      raise exception 'trailer: approve requires a finished render' using errcode = 'TR004';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.music_path is distinct from old.music_path then
    new.music_rights_ack := false;
  end if;
  -- 음악 업로드는 기능 music_upload(A·B) 필요
  if v_client and new.music_path is not null
     and (tg_op = 'INSERT' or new.music_path is distinct from old.music_path)
     and not coalesce(nomad_core.has_feature(new.organization_id, 'trailer', 'music_upload'), false) then
    raise exception 'trailer: music upload needs a higher plan' using errcode = 'TR005';
  end if;
  if new.music_rights_ack and (tg_op = 'INSERT' or not old.music_rights_ack) then
    new.music_rights_ack_at := now();
    new.music_rights_ack_by := (select auth.uid());
  elsif not new.music_rights_ack then
    new.music_rights_ack_at := null;
    new.music_rights_ack_by := null;
  elsif tg_op = 'UPDATE' then
    new.music_rights_ack_at := old.music_rights_ack_at;
    new.music_rights_ack_by := old.music_rights_ack_by;
  end if;
  return new;
end;
$$;
create trigger trailers_before_write before insert or update on nomad_trailer.trailers for each row execute function nomad_trailer.trailers_before_write();

-- 트레일러를 만들면 엔드카드 1개(사용자 정책으로는 못 만들어 DEFINER)
create function nomad_trailer.create_end_card() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into nomad_trailer.scenes (organization_id, trailer_id, position, kind, duration_ms, text, created_by)
  values (new.organization_id, new.id, 0, 'end_card', 4000, null, new.created_by);
  return new;
end;
$$;
create trigger trailers_create_end_card after insert on nomad_trailer.trailers for each row execute function nomad_trailer.create_end_card();

-- scenes: revision 증가, 인용 검증 초기화, 엔드카드 보호
create function nomad_trailer.scenes_before_write() returns trigger
language plpgsql set search_path = ''
as $$
declare v_client boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'DELETE' then
    if old.kind = 'end_card' and exists (select 1 from nomad_trailer.trailers t where t.id = old.trailer_id) then
      raise exception 'trailer: end card cannot be deleted' using errcode = 'TR007';
    end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    if v_client then
      new.quote_verified := false;
      new.revision := 1;
    end if;
    return new;
  end if;
  if new.kind is distinct from old.kind and (old.kind = 'end_card' or new.kind = 'end_card') then
    raise exception 'trailer: end card kind is fixed' using errcode = 'TR007';
  end if;
  if v_client then
    new.organization_id := old.organization_id;
    new.trailer_id := old.trailer_id;
    new.quote_verified := old.quote_verified;
    new.quote_ref := old.quote_ref;
    if new.kind = 'quote_card' and new.text is distinct from old.text then
      new.quote_verified := false;
    end if;
  end if;
  if (new.text, new.narration, new.duration_ms, new.visual, new.position, new.kind, new.music_cue)
     is distinct from (old.text, old.narration, old.duration_ms, old.visual, old.position, old.kind, old.music_cue) then
    new.revision := old.revision + 1;
  else
    new.revision := old.revision;
  end if;
  return new;
end;
$$;
create trigger scenes_before_write before insert or update or delete on nomad_trailer.scenes for each row execute function nomad_trailer.scenes_before_write();

-- briefs: 버전 번호(트레일러별 max+1), 사용자 행은 manual만
create function nomad_trailer.briefs_before_insert() returns trigger
language plpgsql set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('trailer:brief:' || new.trailer_id::text, 0));
  select coalesce(max(b.version), 0) + 1 into new.version from nomad_trailer.briefs b where b.trailer_id = new.trailer_id;
  if current_user in ('authenticated', 'anon') then
    new.source := 'manual';
    new.ai_run_id := null;
  end if;
  return new;
end;
$$;
create trigger briefs_before_insert before insert on nomad_trailer.briefs for each row execute function nomad_trailer.briefs_before_insert();

-- metadata_packs: 링크는 같은 조직·같은 책만, 제휴 링크면 대가성 문구를 설명 첫 줄에
create function nomad_trailer.metadata_packs_before_write() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_book    uuid;
  v_bad     integer;
  v_default constant text := '이 설명에는 제휴 링크가 포함되어 있으며, 링크를 통한 구매 시 일정액의 수수료를 받을 수 있습니다.';
begin
  if tg_op = 'UPDATE' and current_user in ('authenticated', 'anon') then
    new.organization_id := old.organization_id;
    new.trailer_id := old.trailer_id;
    new.source := old.source;
  end if;
  select t.book_id into v_book from nomad_trailer.trailers t where t.id = new.trailer_id and t.organization_id = new.organization_id;
  select count(*) into v_bad
  from unnest(new.link_ids) as u(link_id)
  where not exists (select 1 from nomad_trailer.purchase_links l
                    where l.id = u.link_id and l.organization_id = new.organization_id and l.book_id = v_book);
  if v_bad > 0 then
    raise exception 'metadata_packs: link does not belong to this book' using errcode = '23503';
  end if;
  new.has_affiliate := exists (select 1 from nomad_trailer.purchase_links l where l.id = any (new.link_ids) and l.is_affiliate);
  if new.has_affiliate then
    new.disclosure := coalesce(nullif(btrim(new.disclosure), ''), v_default);
    if left(new.description, char_length(new.disclosure)) <> new.disclosure then
      new.description := new.disclosure || E'\n' || new.description;
    end if;
    if char_length(new.description) > 5000 then
      raise exception 'metadata_packs: description too long after disclosure' using errcode = 'TR008';
    end if;
  else
    new.disclosure := null;
  end if;
  return new;
end;
$$;
create trigger metadata_packs_before_write before insert or update on nomad_trailer.metadata_packs
  for each row execute function nomad_trailer.metadata_packs_before_write();

-- 실행 상태 전이(generation_runs, renders): queued → running|canceled|failed, running → succeeded|failed|queued(재시도)
create function nomad_trailer.enforce_run_status_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'queued' then
      raise exception 'trailer: % must start as queued', tg_table_name using errcode = 'TR001';
    end if;
    return new;
  end if;
  if new.status = old.status then
    return new;
  end if;
  if not ((old.status = 'queued'  and new.status in ('running', 'canceled', 'failed'))
       or (old.status = 'running' and new.status in ('succeeded', 'failed', 'queued'))) then
    raise exception 'trailer: invalid % status transition % -> %', tg_table_name, old.status, new.status using errcode = 'TR001';
  end if;
  if new.status = 'running' then
    new.started_at := coalesce(new.started_at, now());
  end if;
  if new.status in ('succeeded', 'failed', 'canceled') then
    new.finished_at := coalesce(new.finished_at, now());
  end if;
  return new;
end;
$$;
create trigger generation_runs_status_transition before insert or update on nomad_trailer.generation_runs
  for each row execute function nomad_trailer.enforce_run_status_transition();
create trigger renders_status_transition before insert or update on nomad_trailer.renders
  for each row execute function nomad_trailer.enforce_run_status_transition();

-- reviews: pending → approved | changes_requested | expired | revoked
create function nomad_trailer.enforce_review_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'reviews: must start as pending' using errcode = 'TR001';
    end if;
    return new;
  end if;
  if new.status <> old.status then
    if old.status <> 'pending' then
      raise exception 'reviews: invalid transition % -> %', old.status, new.status using errcode = 'TR001';
    end if;
    if new.status in ('approved', 'changes_requested') then
      new.decided_at := now();
    end if;
  end if;
  return new;
end;
$$;
create trigger reviews_status_transition before insert or update on nomad_trailer.reviews
  for each row execute function nomad_trailer.enforce_review_transition();

-- =====================================================================
-- 6. 사용자 RPC (authenticated)
-- =====================================================================
-- 권리 확인(생성·렌더의 전제 TR003). 남의 조직 책은 존재도 알리지 않는다(P0002).
create function nomad_trailer.acknowledge_rights(p_book_id uuid, p_version text) returns nomad_trailer.books
language plpgsql security definer set search_path = ''
as $$
declare v_book nomad_trailer.books;
begin
  select * into v_book from nomad_trailer.books b where b.id = p_book_id and b.deleted_at is null;
  if v_book.id is null or not (nomad_core.is_service_caller() or nomad_trailer.has_access(v_book.organization_id)) then
    raise exception 'acknowledge_rights: not found' using errcode = 'P0002';
  end if;
  if not nomad_core.is_service_caller() and not nomad_trailer.can_edit(v_book.organization_id) then
    raise exception 'acknowledge_rights: not an editor' using errcode = '42501';
  end if;
  if p_version is null or p_version !~ '^rights-[0-9]{4}-[0-9]{2}-v[0-9]+$' then
    raise exception 'acknowledge_rights: invalid notice version' using errcode = '22023';
  end if;
  update nomad_trailer.books
     set rights_ack_version = p_version, rights_ack_at = now(), rights_ack_by = (select auth.uid())
   where id = p_book_id
  returning * into v_book;
  perform nomad_core.write_audit(v_book.organization_id, 'trailer.book.rights_ack', 'book', p_book_id::text, null,
                                 jsonb_build_object('version', p_version));
  return v_book;
end;
$$;

-- 장면 저장(낙관적 동시성). INVOKER: RLS·컬럼 grant 그대로. p_patch 키: text, narration, duration_ms, visual, music_cue
create function nomad_trailer.save_scene(p_scene_id uuid, p_patch jsonb, p_expected_revision integer) returns integer
language plpgsql security invoker set search_path = ''
as $$
declare v_rev integer;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'save_scene: patch must be an object' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_patch) as k(key)
             where k.key not in ('text', 'narration', 'duration_ms', 'visual', 'music_cue')) then
    raise exception 'save_scene: unknown key in patch' using errcode = '22023';
  end if;
  update nomad_trailer.scenes s
     set text        = case when p_patch ? 'text' then p_patch ->> 'text' else s.text end,
         narration   = case when p_patch ? 'narration' then p_patch ->> 'narration' else s.narration end,
         duration_ms = case when p_patch ? 'duration_ms' then (p_patch ->> 'duration_ms')::integer else s.duration_ms end,
         visual      = case when p_patch ? 'visual' then p_patch -> 'visual' else s.visual end,
         music_cue   = case when p_patch ? 'music_cue' then p_patch ->> 'music_cue' else s.music_cue end
   where s.id = p_scene_id and s.revision = p_expected_revision
  returning s.revision into v_rev;
  if v_rev is null then
    if exists (select 1 from nomad_trailer.scenes s where s.id = p_scene_id) then
      raise exception 'save_scene: revision conflict' using errcode = 'TR409';
    end if;
    raise exception 'save_scene: not found' using errcode = 'P0002';
  end if;
  return v_rev;
end;
$$;

-- 장면 순서 변경(전체 id를 새 순서로, 엔드카드는 마지막). INVOKER.
create function nomad_trailer.reorder_scenes(p_trailer_id uuid, p_scene_ids uuid[]) returns void
language plpgsql security invoker set search_path = ''
as $$
declare v_count integer; v_end uuid;
begin
  select count(*) into v_count from nomad_trailer.scenes s where s.trailer_id = p_trailer_id;
  if v_count = 0 then
    raise exception 'reorder_scenes: trailer not found or empty' using errcode = 'P0002';
  end if;
  if coalesce(cardinality(p_scene_ids), 0) <> v_count
     or (select count(distinct x) from unnest(p_scene_ids) as u(x)) <> v_count
     or exists (select 1 from unnest(p_scene_ids) as u(x)
                where not exists (select 1 from nomad_trailer.scenes s where s.id = u.x and s.trailer_id = p_trailer_id)) then
    raise exception 'reorder_scenes: id list does not match the trailer scenes' using errcode = '22023';
  end if;
  select s.id into v_end from nomad_trailer.scenes s where s.trailer_id = p_trailer_id and s.kind = 'end_card';
  if v_end is not null and p_scene_ids[v_count] <> v_end then
    raise exception 'reorder_scenes: end card must be last' using errcode = 'TR007';
  end if;
  update nomad_trailer.scenes s
     set position = o.ord - 1
    from unnest(p_scene_ids) with ordinality as o(id, ord)
   where s.id = o.id and s.trailer_id = p_trailer_id;
end;
$$;

-- =====================================================================
-- 7. 서버 RPC (service_role 전용)
-- =====================================================================
-- 서버 호출자 + 조직 쓰기 역할(owner·admin·editor) + trailer 이용권(조직 활성 포함)
create function nomad_trailer_private.assert_actor(p_organization_id uuid, p_actor uuid, p_fn text) returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception '%: service_role only', p_fn using errcode = '42501';
  end if;
  if not exists (select 1 from nomad_core.memberships m
                 where m.organization_id = p_organization_id and m.user_id = p_actor and m.role in ('owner', 'admin', 'editor')) then
    raise exception '%: not an editor', p_fn using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(p_organization_id, 'trailer', 'trailer') then
    raise exception '%: no entitlement', p_fn using errcode = '42501';
  end if;
end;
$$;

-- 결과 저장 전 작업 확인: 작업이 이미 failed·canceled(환불 끝남)면 결과를 받지 않는다. 읽기만(쓰기는 mark_job_delivered).
create function nomad_trailer_private.assert_job_open(p_job uuid, p_fn text) returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_job is not null and exists (select 1 from nomad_core.jobs j where j.id = p_job and j.status in ('failed', 'canceled')) then
    raise exception '%: job is already finished without result', p_fn using errcode = 'TR001';
  end if;
end;
$$;

-- 작업만 끝난 실행 정리(cancel_job·reap_stale_jobs·fail_job 뒤). 영구 TR002 방지.
create function nomad_trailer.reconcile_runs(p_organization_id uuid) returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'reconcile_runs: service_role only' using errcode = '42501';
  end if;
  with dead as (
    update nomad_trailer.generation_runs r
       set status = case when j.status = 'canceled' and r.status = 'queued' then 'canceled' else 'failed' end,
           error = coalesce(r.error, 'job ' || j.status)
      from nomad_core.jobs j
     where r.organization_id = p_organization_id and r.job_id = j.id and r.status in ('queued', 'running')
       and j.status in ('failed', 'canceled')
    returning r.id
  )
  select count(*) into v_n from dead;
  update nomad_trailer.books b set digest_status = 'failed'
   where b.organization_id = p_organization_id and b.digest_status = 'queued'
     and not exists (select 1 from nomad_trailer.generation_runs r
                     where r.book_id = b.id and r.kind = 'digest' and r.status in ('queued', 'running'));
  update nomad_trailer.renders x
     set status = case when j.status = 'canceled' and x.status = 'queued' then 'canceled' else 'failed' end,
         error = coalesce(x.error, 'job ' || j.status)
    from nomad_core.jobs j
   where x.organization_id = p_organization_id and x.job_id = j.id and x.status in ('queued', 'running')
     and j.status in ('failed', 'canceled');
  return v_n;
end;
$$;

-- AI 실행 시작: 검사 → 크레딧 선차감(consume_credits) → 실행 행 → 작업 등록(enqueue_job) 한 트랜잭션.
-- 단가는 서버 상수(p_credits). 멱등 키 'run:trailer:<request_id>'.
create function nomad_trailer.start_run(
  p_organization_id uuid, p_kind text, p_book_id uuid, p_trailer_id uuid, p_scene_id uuid,
  p_credits integer, p_idempotency_key text, p_actor uuid, p_payload jsonb default '{}'::jsonb
)
returns nomad_trailer.generation_runs
language plpgsql security definer set search_path = ''
as $$
declare
  v_run     nomad_trailer.generation_runs;
  v_book    nomad_trailer.books;
  v_trailer nomad_trailer.trailers;
  v_scene   nomad_trailer.scenes;
  v_rid     text;
  v_active  integer;
  v_ledger  uuid;
  v_job     nomad_core.jobs;
  v_run_id  uuid := gen_random_uuid();
begin
  if not nomad_core.is_service_caller() then
    raise exception 'start_run: service_role only' using errcode = '42501';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^run:trailer:[A-Za-z0-9][A-Za-z0-9_:-]{7,119}$' then
    raise exception 'start_run: idempotency key must be run:trailer:<request_id>' using errcode = '22023';
  end if;
  if p_kind is null or p_kind not in ('digest', 'brief', 'storyboard', 'scene_image', 'narration', 'meta') then
    raise exception 'start_run: invalid kind %', p_kind using errcode = '22023';
  end if;
  if p_credits is null or p_credits < 0 then
    raise exception 'start_run: credits must be >= 0' using errcode = '22023';
  end if;
  v_rid := substring(p_idempotency_key from 13);

  perform pg_advisory_xact_lock(hashtextextended('trailer:run:' || p_idempotency_key, 0));
  select * into v_run from nomad_trailer.generation_runs r where r.idempotency_key = p_idempotency_key;
  if v_run.id is not null then
    if v_run.organization_id <> p_organization_id then
      raise exception 'start_run: idempotency key belongs to another organization' using errcode = '42501';
    end if;
    return v_run;
  end if;
  perform nomad_trailer_private.assert_actor(p_organization_id, p_actor, 'start_run');

  if p_kind in ('brief', 'storyboard', 'meta', 'scene_image', 'narration') then
    select * into v_trailer from nomad_trailer.trailers t where t.id = p_trailer_id and t.organization_id = p_organization_id for update;
    if v_trailer.id is null then
      raise exception 'start_run: trailer not found' using errcode = 'P0002';
    end if;
    if v_trailer.status = 'archived' then
      raise exception 'start_run: trailer is archived' using errcode = 'TR001';
    end if;
    if p_book_id is not null and p_book_id <> v_trailer.book_id then
      raise exception 'start_run: book mismatch' using errcode = '22023';
    end if;
    p_book_id := v_trailer.book_id;
  elsif p_trailer_id is not null or p_scene_id is not null then
    raise exception 'start_run: digest takes a book only' using errcode = '22023';
  end if;
  select * into v_book from nomad_trailer.books b
  where b.id = p_book_id and b.organization_id = p_organization_id and b.deleted_at is null for update;
  if v_book.id is null then
    raise exception 'start_run: book not found' using errcode = 'P0002';
  end if;
  if v_book.rights_ack_at is null then
    raise exception 'start_run: rights not acknowledged' using errcode = 'TR003';
  end if;
  if p_kind in ('scene_image', 'narration') then
    select * into v_scene from nomad_trailer.scenes s where s.id = p_scene_id and s.trailer_id = v_trailer.id and s.organization_id = p_organization_id;
    if v_scene.id is null then
      raise exception 'start_run: scene not found' using errcode = 'P0002';
    end if;
    if p_kind = 'scene_image' and v_scene.kind not in ('image_scene', 'character_scene', 'title_card', 'quote_card', 'hook_text') then
      raise exception 'start_run: scene kind % has no generated image', v_scene.kind using errcode = '22023';
    end if;
    if p_kind = 'narration' and coalesce(btrim(v_scene.narration), '') = '' then
      raise exception 'start_run: scene has no narration text' using errcode = 'TR004';
    end if;
    if p_kind = 'narration' and v_trailer.narration_mode = 'none' then
      raise exception 'start_run: narration is off for this trailer' using errcode = '22023';
    end if;
  elsif p_scene_id is not null then
    raise exception 'start_run: scene is only for scene_image or narration' using errcode = '22023';
  end if;

  if p_kind = 'digest' then
    if v_book.manuscript_path is null or v_book.manuscript_sha256 is null then
      raise exception 'start_run: manuscript is not parsed yet' using errcode = 'TR004';
    end if;
    if v_book.digest_status = 'ready' and exists (select 1 from nomad_trailer.book_digests d
        where d.book_id = v_book.id and d.manuscript_sha256 = v_book.manuscript_sha256) then
      raise exception 'start_run: digest is up to date' using errcode = '22023';
    end if;
  elsif p_kind = 'brief' then
    if v_book.digest_status <> 'ready' then
      raise exception 'start_run: digest is not ready' using errcode = 'TR004';
    end if;
  elsif p_kind = 'storyboard' then
    if v_trailer.current_brief_id is null then
      raise exception 'start_run: choose a brief first' using errcode = 'TR004';
    end if;
  elsif p_kind = 'meta' then
    if not exists (select 1 from nomad_trailer.scenes s where s.trailer_id = v_trailer.id and s.kind <> 'end_card') then
      raise exception 'start_run: storyboard is empty' using errcode = 'TR004';
    end if;
  end if;

  perform nomad_trailer.reconcile_runs(p_organization_id);
  if exists (select 1 from nomad_trailer.generation_runs r
             where r.organization_id = p_organization_id and r.kind = p_kind and r.status in ('queued', 'running')
               and r.book_id = v_book.id and r.trailer_id is not distinct from v_trailer.id
               and r.scene_id is not distinct from v_scene.id) then
    raise exception 'start_run: % already running for this target', p_kind using errcode = 'TR002';
  end if;
  select count(*) into v_active from nomad_trailer.generation_runs r
  where r.organization_id = p_organization_id and r.status in ('queued', 'running');
  if v_active >= nomad_trailer_private.config_int('max_active_runs_per_org', 4) then
    raise exception 'start_run: too many active runs for this organization' using errcode = 'TR005';
  end if;

  if p_credits > 0 then
    select c.ledger_id into v_ledger
    from nomad_core.consume_credits(p_organization_id, p_credits, 'trailer.' || p_kind, 'consume:trailer:run:' || v_rid,
                                    'trailer', 'trailer_generation_run', v_run_id::text) c;
  end if;

  insert into nomad_trailer.generation_runs (id, organization_id, kind, book_id, trailer_id, scene_id, credits_reserved,
                                             credit_ledger_id, idempotency_key, payload, created_by)
  values (v_run_id, p_organization_id, p_kind, v_book.id, v_trailer.id, v_scene.id, p_credits, v_ledger,
          p_idempotency_key, coalesce(p_payload, '{}'::jsonb), p_actor)
  returning * into v_run;

  select * into v_job from nomad_core.enqueue_job(
    p_organization_id, 'trailer', 'trailer.' || p_kind,
    jsonb_build_object('run_id', v_run_id, 'kind', p_kind, 'book_id', v_book.id, 'trailer_id', v_trailer.id, 'scene_id', v_scene.id),
    'trailer.ai', 100, now(), 2, v_ledger, 'job:trailer:run:' || v_rid, null, p_actor, true);

  update nomad_trailer.generation_runs set job_id = v_job.id where id = v_run_id returning * into v_run;
  if p_kind = 'digest' then
    update nomad_trailer.books set digest_status = 'queued' where id = v_book.id;
  end if;
  return v_run;
end;
$$;

-- AI 실행 종료: 결과 저장 + succeeded + 작업 환불 표시 해제(결과를 넘긴 실행은 작업이 나중에 실패해도 환불하지 않는다).
create function nomad_trailer.finish_run(p_run_id uuid, p_result jsonb, p_ai_run_id uuid default null)
returns nomad_trailer.generation_runs
language plpgsql security definer set search_path = ''
as $$
declare
  v_run     nomad_trailer.generation_runs;
  v_book    nomad_trailer.books;
  v_trailer nomad_trailer.trailers;
  v_brief   nomad_trailer.briefs;
  v_scene   jsonb;
  v_pos     integer := 0;
  v_pack    jsonb;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'finish_run: service_role only' using errcode = '42501';
  end if;
  if p_result is null or jsonb_typeof(p_result) <> 'object' then
    raise exception 'finish_run: result must be an object' using errcode = '22023';
  end if;
  select * into v_run from nomad_trailer.generation_runs r where r.id = p_run_id for update;
  if v_run.id is null then
    raise exception 'finish_run: run not found' using errcode = 'P0002';
  end if;
  if v_run.status not in ('queued', 'running') then
    raise exception 'finish_run: run is already %', v_run.status using errcode = 'TR001';
  end if;
  perform nomad_trailer_private.assert_job_open(v_run.job_id, 'finish_run');
  if v_run.status = 'queued' then
    update nomad_trailer.generation_runs set status = 'running' where id = p_run_id;
  end if;
  if v_run.job_id is not null then
    perform nomad_core.mark_job_delivered(v_run.job_id);
  end if;
  select * into v_book from nomad_trailer.books b where b.id = v_run.book_id for update;
  if v_run.trailer_id is not null then
    select * into v_trailer from nomad_trailer.trailers t where t.id = v_run.trailer_id for update;
  end if;

  if v_run.kind = 'digest' then
    if coalesce(jsonb_typeof(p_result -> 'chapters'), '') <> 'array' then
      raise exception 'finish_run: digest needs chapters' using errcode = '22023';
    end if;
    insert into nomad_trailer.book_digests (organization_id, book_id, manuscript_sha256, chapters, characters, themes, settings, ai_run_id)
    values (v_run.organization_id, v_run.book_id, coalesce(p_result ->> 'manuscript_sha256', v_book.manuscript_sha256),
            p_result -> 'chapters', coalesce(p_result -> 'characters', '[]'::jsonb), coalesce(p_result -> 'themes', '[]'::jsonb),
            coalesce(p_result -> 'settings', '[]'::jsonb), p_ai_run_id)
    on conflict (book_id) do update
      set manuscript_sha256 = excluded.manuscript_sha256, chapters = excluded.chapters, characters = excluded.characters,
          themes = excluded.themes, settings = excluded.settings, ai_run_id = excluded.ai_run_id;
    update nomad_trailer.books set digest_status = 'ready' where id = v_run.book_id;

  elsif v_run.kind = 'brief' then
    if coalesce(jsonb_typeof(p_result -> 'briefs'), '') <> 'array' or coalesce(jsonb_array_length(p_result -> 'briefs'), 0) not between 1 and 3 then
      raise exception 'finish_run: brief needs 1~3 briefs' using errcode = '22023';
    end if;
    for v_pack in select value from jsonb_array_elements(p_result -> 'briefs') loop
      insert into nomad_trailer.briefs (organization_id, trailer_id, source, content, ai_run_id)
      values (v_run.organization_id, v_run.trailer_id, 'ai', v_pack, p_ai_run_id)
      returning * into v_brief;
      if v_trailer.current_brief_id is null then
        update nomad_trailer.trailers set current_brief_id = v_brief.id where id = v_run.trailer_id returning * into v_trailer;
      end if;
    end loop;

  elsif v_run.kind = 'storyboard' then
    if coalesce(jsonb_typeof(p_result -> 'scenes'), '') <> 'array' or jsonb_array_length(p_result -> 'scenes') not between 1 and 39 then
      raise exception 'finish_run: storyboard needs 1~39 scenes' using errcode = '22023';
    end if;
    delete from nomad_trailer.scenes s where s.trailer_id = v_run.trailer_id and s.kind <> 'end_card';
    for v_scene in select value from jsonb_array_elements(p_result -> 'scenes') loop
      if coalesce(v_scene ->> 'kind', '') = 'end_card' then
        raise exception 'finish_run: storyboard must not include the end card' using errcode = 'TR007';
      end if;
      insert into nomad_trailer.scenes (organization_id, trailer_id, position, kind, duration_ms, text, narration, quote_ref, quote_verified,
                                        visual, music_cue, created_by)
      values (v_run.organization_id, v_run.trailer_id, v_pos, v_scene ->> 'kind', coalesce((v_scene ->> 'duration_ms')::integer, 3000),
              v_scene ->> 'text', v_scene ->> 'narration', v_scene -> 'quote_ref',
              coalesce((v_scene ->> 'quote_verified')::boolean, false) and (v_scene ->> 'kind') = 'quote_card',
              coalesce(v_scene -> 'visual', '{}'::jsonb), v_scene ->> 'music_cue', v_run.created_by);
      v_pos := v_pos + 1;
    end loop;
    update nomad_trailer.scenes set position = v_pos where trailer_id = v_run.trailer_id and kind = 'end_card';
    update nomad_trailer.trailers set storyboard_version = storyboard_version + 1 where id = v_run.trailer_id;

  elsif v_run.kind in ('scene_image', 'narration') then
    if coalesce(p_result ->> 'storage_path', '') = '' then
      raise exception 'finish_run: asset needs storage_path' using errcode = '22023';
    end if;
    if v_run.kind = 'narration' then
      if v_trailer.voice ? 'provider'
         and ((v_trailer.voice ->> 'provider') is distinct from (p_result ->> 'provider')
              or (v_trailer.voice ->> 'voice_id') is distinct from (p_result ->> 'voice_id')) then
        raise exception 'finish_run: narration voice differs from the fixed voice' using errcode = '22023';
      end if;
      if not (v_trailer.voice ? 'provider') then
        update nomad_trailer.trailers
           set voice = jsonb_build_object('provider', p_result ->> 'provider', 'voice_id', p_result ->> 'voice_id', 'fixed_at', now())
         where id = v_run.trailer_id;
      end if;
    end if;
    update nomad_trailer.scene_assets set status = 'superseded'
     where scene_id = v_run.scene_id and status = 'ready'
       and slot = case when v_run.kind = 'narration' then 'audio' else 'visual' end;
    insert into nomad_trailer.scene_assets (organization_id, scene_id, kind, source, ai_generated, provider, model, seed, voice_id, storage_path,
                                            width, height, duration_ms, chars, bytes, run_id, created_by)
    values (v_run.organization_id, v_run.scene_id, case when v_run.kind = 'narration' then 'narration' else 'image' end,
            'ai_generated', true, p_result ->> 'provider', coalesce(p_result ->> 'model', p_result ->> 'provider'),
            (p_result ->> 'seed')::bigint, p_result ->> 'voice_id', p_result ->> 'storage_path',
            (p_result ->> 'width')::integer, (p_result ->> 'height')::integer, (p_result ->> 'duration_ms')::integer,
            (p_result ->> 'chars')::integer, coalesce((p_result ->> 'bytes')::bigint, 0), v_run.id, v_run.created_by);

  elsif v_run.kind = 'meta' then
    if coalesce(jsonb_typeof(p_result -> 'packs'), '') <> 'array' then
      raise exception 'finish_run: meta needs packs' using errcode = '22023';
    end if;
    for v_pack in select value from jsonb_array_elements(p_result -> 'packs') loop
      insert into nomad_trailer.metadata_packs (organization_id, trailer_id, platform, title, description, hashtags, link_ids, source, created_by)
      values (v_run.organization_id, v_run.trailer_id, v_pack ->> 'platform', v_pack ->> 'title', coalesce(v_pack ->> 'description', ''),
              coalesce(array(select jsonb_array_elements_text(v_pack -> 'hashtags')), '{}'),
              coalesce(array(select (jsonb_array_elements_text(v_pack -> 'link_ids'))::uuid), '{}'),
              'ai', v_run.created_by)
      on conflict (trailer_id, platform) do update
        set title = excluded.title, description = excluded.description, hashtags = excluded.hashtags,
            link_ids = excluded.link_ids, source = 'ai';
    end loop;
  end if;

  update nomad_trailer.generation_runs
     set status = 'succeeded', ai_run_id = coalesce(p_ai_run_id, ai_run_id),
         progress = jsonb_build_object('stage', 'done', 'at', now())
   where id = p_run_id
  returning * into v_run;
  return v_run;
end;
$$;

-- AI 실행 실패 기록(환불은 nomad_core.fail_job이 한다. 오케스트레이터는 fail_job 다음에 이것을 부른다).
create function nomad_trailer.fail_run(p_run_id uuid, p_error text) returns nomad_trailer.generation_runs
language plpgsql security definer set search_path = ''
as $$
declare v_run nomad_trailer.generation_runs;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'fail_run: service_role only' using errcode = '42501';
  end if;
  update nomad_trailer.generation_runs
     set status = 'failed', error = left(coalesce(p_error, 'failed'), 1000)
   where id = p_run_id and status in ('queued', 'running')
  returning * into v_run;
  if v_run.id is null then
    raise exception 'fail_run: run not active' using errcode = 'TR001';
  end if;
  if v_run.kind = 'digest' then
    update nomad_trailer.books set digest_status = 'failed' where id = v_run.book_id and digest_status = 'queued';
  end if;
  return v_run;
end;
$$;

-- 렌더 시작: 플랜 기능(서버 판정)·권리·엔드카드·인용·에셋·음악 검사 → 스냅샷 → 선차감 → 작업 등록.
create function nomad_trailer.start_render(
  p_organization_id uuid, p_trailer_id uuid, p_format text, p_resolution text, p_credits integer,
  p_request_id uuid, p_actor uuid, p_allow_unverified_quotes boolean default false
)
returns nomad_trailer.renders
language plpgsql security definer set search_path = ''
as $$
declare
  v_render    nomad_trailer.renders;
  v_trailer   nomad_trailer.trailers;
  v_book      nomad_trailer.books;
  v_tpl       nomad_trailer.templates;
  v_kit       nomad_trailer.brand_kits;
  v_total     integer;
  v_last      nomad_trailer.scenes;
  v_missing   integer;
  v_qsum      integer;
  v_qmax      integer;
  v_has_ai    boolean;
  v_snapshot  jsonb;
  v_ledger    uuid;
  v_job       nomad_core.jobs;
  v_active    integer;
  v_render_id uuid := gen_random_uuid();
begin
  if not nomad_core.is_service_caller() then
    raise exception 'start_render: service_role only' using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'start_render: request_id required' using errcode = '22023';
  end if;
  if p_credits is null or p_credits < 0 then
    raise exception 'start_render: credits must be >= 0' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('trailer:render:' || p_request_id::text, 0));
  select * into v_render from nomad_trailer.renders r where r.request_id = p_request_id;
  if v_render.id is not null then
    if v_render.organization_id <> p_organization_id then
      raise exception 'start_render: request belongs to another organization' using errcode = '42501';
    end if;
    return v_render;
  end if;
  perform nomad_trailer_private.assert_actor(p_organization_id, p_actor, 'start_render');

  select * into v_trailer from nomad_trailer.trailers t where t.id = p_trailer_id and t.organization_id = p_organization_id for update;
  if v_trailer.id is null then
    raise exception 'start_render: trailer not found' using errcode = 'P0002';
  end if;
  if v_trailer.status = 'archived' then
    raise exception 'start_render: trailer is archived' using errcode = 'TR001';
  end if;
  select * into v_book from nomad_trailer.books b where b.id = v_trailer.book_id;
  if v_book.deleted_at is not null then
    raise exception 'start_render: book is deleted' using errcode = 'P0002';
  end if;
  if v_book.rights_ack_at is null then
    raise exception 'start_render: rights not acknowledged' using errcode = 'TR003';
  end if;

  -- 플랜 판정(서버가 결정): 구독이 끊기면 C = 원본 free(세로 9:16, 720p, 30초, 워터마크, 무료 템플릿)
  if p_format is null or not (p_format = any (v_trailer.formats)) then
    raise exception 'start_render: format % is not selected for this trailer', p_format using errcode = '22023';
  end if;
  if p_format <> 'vertical_9_16' and not nomad_core.org_has_feature(p_organization_id, 'trailer', 'formats_all') then
    raise exception 'start_render: format % needs a higher plan', p_format using errcode = 'TR005';
  end if;
  if p_resolution is null or p_resolution not in ('480p', '720p', '1080p') then
    raise exception 'start_render: invalid resolution' using errcode = '22023';
  end if;
  if p_resolution = '1080p' and not nomad_core.org_has_feature(p_organization_id, 'trailer', 'render_1080p') then
    raise exception 'start_render: 1080p needs a higher plan' using errcode = 'TR005';
  end if;

  select * into v_last from nomad_trailer.scenes s where s.trailer_id = p_trailer_id order by s.position desc limit 1;
  if v_last.kind is distinct from 'end_card' then
    raise exception 'start_render: end card must be the last scene' using errcode = 'TR007';
  end if;
  if (select count(*) from nomad_trailer.scenes s where s.trailer_id = p_trailer_id) < 2 then
    raise exception 'start_render: storyboard is empty' using errcode = 'TR004';
  end if;
  select sum(s.duration_ms) into v_total from nomad_trailer.scenes s where s.trailer_id = p_trailer_id;
  if p_format <> 'cover_loop'
     and v_total > least(v_trailer.duration_s, nomad_trailer_private.org_limit(p_organization_id, 'max_duration_s', 30)) * 1100 then
    raise exception 'start_render: total duration % ms exceeds the limit', v_total using errcode = 'TR005';
  end if;

  if not coalesce(p_allow_unverified_quotes, false) and exists (select 1 from nomad_trailer.scenes s
      where s.trailer_id = p_trailer_id and s.kind = 'quote_card' and not s.quote_verified) then
    raise exception 'start_render: unverified quote' using errcode = 'TR006';
  end if;
  v_qmax := nomad_trailer_private.config_int('max_quote_chars_each', 80);
  if exists (select 1 from nomad_trailer.scenes s where s.trailer_id = p_trailer_id and s.kind = 'quote_card'
             and char_length(coalesce(s.text, '')) > v_qmax) then
    raise exception 'start_render: a quote exceeds % chars', v_qmax using errcode = 'TR006';
  end if;
  select coalesce(sum(char_length(coalesce(s.text, ''))), 0) into v_qsum
  from nomad_trailer.scenes s where s.trailer_id = p_trailer_id and s.kind = 'quote_card';
  if v_qsum > nomad_trailer_private.config_int('max_quote_chars_per_trailer', 300) then
    raise exception 'start_render: quotes exceed the total limit' using errcode = 'TR006';
  end if;

  select count(*) into v_missing
  from nomad_trailer.scenes s
  where s.trailer_id = p_trailer_id
    and ((s.kind in ('image_scene', 'character_scene')
          and not exists (select 1 from nomad_trailer.scene_assets a where a.scene_id = s.id and a.slot = 'visual' and a.status = 'ready'))
      or (v_trailer.narration_mode = 'voiceover' and coalesce(btrim(s.narration), '') <> ''
          and not exists (select 1 from nomad_trailer.scene_assets a where a.scene_id = s.id and a.slot = 'audio' and a.status = 'ready')));
  if v_missing > 0 then
    raise exception 'start_render: % scenes are missing assets', v_missing using errcode = 'TR004';
  end if;

  if v_trailer.music_path is not null and not nomad_core.org_has_feature(p_organization_id, 'trailer', 'music_upload') then
    raise exception 'start_render: uploaded music needs a higher plan' using errcode = 'TR005';
  end if;
  if v_trailer.music_path is not null and not v_trailer.music_rights_ack then
    raise exception 'start_render: music rights not acknowledged' using errcode = 'TR011';
  end if;
  if v_trailer.music_track_id is not null and not exists (
      select 1 from nomad_trailer.music_tracks m where m.id = v_trailer.music_track_id and m.status = 'published') then
    raise exception 'start_render: music track is not available' using errcode = 'TR011';
  end if;

  select * into v_tpl from nomad_trailer.templates x where x.code = v_trailer.template_code;
  if v_tpl.status <> 'published' or not (p_format = any (v_tpl.formats)) then
    raise exception 'start_render: template does not support %', p_format using errcode = '22023';
  end if;
  if v_tpl.tier = 'premium' and not nomad_core.org_has_feature(p_organization_id, 'trailer', 'premium_templates') then
    raise exception 'start_render: premium template needs a higher plan' using errcode = 'TR005';
  end if;
  if v_trailer.brand_kit_id is not null then
    select * into v_kit from nomad_trailer.brand_kits k where k.id = v_trailer.brand_kit_id;
  end if;

  perform nomad_trailer.reconcile_runs(p_organization_id);
  select count(*) into v_active from nomad_trailer.renders r where r.organization_id = p_organization_id and r.status in ('queued', 'running');
  if v_active >= nomad_trailer_private.config_int('max_active_renders_per_org', 2) then
    raise exception 'start_render: too many active renders' using errcode = 'TR005';
  end if;

  select exists (select 1 from nomad_trailer.scene_assets a join nomad_trailer.scenes s on s.id = a.scene_id
                 where s.trailer_id = p_trailer_id and a.status = 'ready' and a.ai_generated) into v_has_ai;

  v_snapshot := jsonb_build_object(
    'trailer', jsonb_build_object('id', v_trailer.id, 'title', v_trailer.title, 'duration_s', v_trailer.duration_s,
                                  'language', v_trailer.language, 'voice', v_trailer.voice, 'storyboard_version', v_trailer.storyboard_version),
    'book', jsonb_build_object('title', v_book.title, 'subtitle', v_book.subtitle, 'author_name', v_book.author_name,
                               'publisher_name', v_book.publisher_name, 'cover_path', v_book.cover_path, 'genre', v_book.genre),
    'template', jsonb_build_object('code', v_tpl.code, 'composition_id', v_tpl.composition_id, 'version', v_tpl.version),
    'brand_kit', case when v_kit.id is null then null else
                   jsonb_build_object('palette', v_kit.palette, 'font_display', v_kit.font_display, 'font_body', v_kit.font_body,
                                      'logo_path', v_kit.logo_path) end,
    'music', jsonb_build_object('track_id', v_trailer.music_track_id, 'path', v_trailer.music_path),  -- 카탈로그 원본 경로는 넣지 않는다
    'cta', (select jsonb_build_object('short_code', l.short_code, 'store', l.store, 'label', l.label)
              from nomad_trailer.purchase_links l where l.book_id = v_book.id and l.is_active order by l.sort_order, l.created_at limit 1),
    'scenes', (select jsonb_agg(jsonb_build_object(
                 'id', s.id, 'position', s.position, 'kind', s.kind, 'duration_ms', s.duration_ms, 'text', s.text,
                 'narration', s.narration, 'visual', s.visual, 'music_cue', s.music_cue, 'revision', s.revision,
                 'image', (select jsonb_build_object('path', a.storage_path, 'ai', a.ai_generated)
                             from nomad_trailer.scene_assets a where a.scene_id = s.id and a.slot = 'visual' and a.status = 'ready'),
                 'audio', (select jsonb_build_object('path', a.storage_path, 'duration_ms', a.duration_ms, 'ai', a.ai_generated)
                             from nomad_trailer.scene_assets a where a.scene_id = s.id and a.slot = 'audio' and a.status = 'ready'))
                 order by s.position)
               from nomad_trailer.scenes s where s.trailer_id = p_trailer_id),
    'total_ms', v_total,
    'has_ai_assets', v_has_ai);

  if p_credits > 0 then
    select c.ledger_id into v_ledger
    from nomad_core.consume_credits(p_organization_id, p_credits, 'trailer.render', 'consume:trailer:render:' || p_request_id::text,
                                    'trailer', 'trailer_render', v_render_id::text) c;
  end if;

  insert into nomad_trailer.renders (id, organization_id, trailer_id, format, resolution, plan_code, watermark, ai_label, snapshot,
                                     credits, credit_ledger_id, request_id, created_by)
  values (v_render_id, p_organization_id, p_trailer_id, p_format, p_resolution, nomad_trailer_private.plan_code(p_organization_id),
          p_resolution = '480p' or not nomad_core.org_has_feature(p_organization_id, 'trailer', 'no_watermark'),
          v_has_ai, v_snapshot, p_credits, v_ledger, p_request_id, p_actor)
  returning * into v_render;

  select * into v_job from nomad_core.enqueue_job(
    p_organization_id, 'trailer', 'render.trailer', jsonb_build_object('render_id', v_render_id), 'trailer.render',
    case when nomad_core.org_has_feature(p_organization_id, 'trailer', 'priority_render') then 1 else 100 end,
    now(), 2, v_ledger, 'job:trailer:render:' || p_request_id::text, null, p_actor, true);

  update nomad_trailer.renders set job_id = v_job.id where id = v_render_id returning * into v_render;
  return v_render;
end;
$$;

-- 렌더 종료(성공). 경로는 그 렌더 폴더만. 보존: C(무료) 14일, 유료 90일(runtime_config).
create function nomad_trailer.finish_render(
  p_render_id uuid, p_output_path text, p_poster_path text, p_srt_path text, p_bytes bigint, p_duration_ms integer
)
returns nomad_trailer.renders
language plpgsql security definer set search_path = ''
as $$
declare v_render nomad_trailer.renders; v_prefix text; v_days integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'finish_render: service_role only' using errcode = '42501';
  end if;
  select * into v_render from nomad_trailer.renders r where r.id = p_render_id for update;
  if v_render.id is null then
    raise exception 'finish_render: not found' using errcode = 'P0002';
  end if;
  if v_render.status not in ('queued', 'running') then
    raise exception 'finish_render: render is already %', v_render.status using errcode = 'TR001';
  end if;
  v_prefix := v_render.organization_id::text || '/trailer/renders/' || p_render_id::text || '/';
  if p_output_path is null or left(p_output_path, char_length(v_prefix)) <> v_prefix
     or (p_poster_path is not null and left(p_poster_path, char_length(v_prefix)) <> v_prefix)
     or (p_srt_path is not null and left(p_srt_path, char_length(v_prefix)) <> v_prefix) then
    raise exception 'finish_render: output path must be under %', v_prefix using errcode = '22023';
  end if;
  perform nomad_trailer_private.assert_job_open(v_render.job_id, 'finish_render');
  if v_render.status = 'queued' then
    update nomad_trailer.renders set status = 'running' where id = p_render_id;
  end if;
  if v_render.job_id is not null then
    perform nomad_core.mark_job_delivered(v_render.job_id);
  end if;
  v_days := case when v_render.plan_code = 'C'
                 then nomad_trailer_private.config_int('render_retention_days_free', 14)
                 else nomad_trailer_private.config_int('render_retention_days_paid', 90) end;
  update nomad_trailer.renders
     set status = 'succeeded', output_path = p_output_path, poster_path = p_poster_path, srt_path = p_srt_path,
         bytes = p_bytes, duration_ms = p_duration_ms, expires_at = now() + make_interval(days => v_days)
   where id = p_render_id
  returning * into v_render;
  return v_render;
end;
$$;

create function nomad_trailer.fail_render(p_render_id uuid, p_error text) returns nomad_trailer.renders
language plpgsql security definer set search_path = ''
as $$
declare v_render nomad_trailer.renders;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'fail_render: service_role only' using errcode = '42501';
  end if;
  update nomad_trailer.renders set status = 'failed', error = left(coalesce(p_error, 'failed'), 1000)
   where id = p_render_id and status in ('queued', 'running')
  returning * into v_render;
  if v_render.id is null then
    raise exception 'fail_render: render not active' using errcode = 'TR001';
  end if;
  return v_render;
end;
$$;

-- 구매 링크 클릭: 공개 리다이렉트(/b/[code]) 서버가 service_role로 호출(anon 직접 실행 없음, D8).
-- 속도 제한: 서버가 호출 전에 nomad_core.rate_limit_hit('trailer:click:<ip_hash>', …)로 거른다(existing.md).
create function nomad_trailer.record_link_click(
  p_code text, p_referrer text default null, p_ip_hash text default null, p_user_agent text default null, p_tag text default null
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_link nomad_trailer.purchase_links;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_link_click: service_role only' using errcode = '42501';
  end if;
  select l.* into v_link
  from nomad_trailer.purchase_links l
  join nomad_trailer.books b on b.id = l.book_id
  where l.short_code = p_code and l.is_active and b.deleted_at is null;
  if v_link.id is null then
    return null;
  end if;
  insert into nomad_trailer.link_clicks (link_id, organization_id, referrer, ip_hash, user_agent, tag)
  values (v_link.id, v_link.organization_id, left(p_referrer, 500),
          case when p_ip_hash ~ '^[0-9a-f]{64}$' then p_ip_hash end, left(p_user_agent, 300),
          case when p_tag ~ '^[a-z0-9_:-]{1,80}$' then p_tag end);
  update nomad_trailer.purchase_links set click_count = click_count + 1 where id = v_link.id;
  return v_link.url;
end;
$$;

-- 외부 승인 링크 열기(기능 approval_links). 토큰 원문은 서버가 만들고 sha256만 넘긴다.
create function nomad_trailer.open_review(
  p_organization_id uuid, p_trailer_id uuid, p_render_ids uuid[], p_token_sha256 text, p_label text, p_actor uuid
)
returns nomad_trailer.reviews
language plpgsql security definer set search_path = ''
as $$
declare v_review nomad_trailer.reviews;
begin
  perform nomad_trailer_private.assert_actor(p_organization_id, p_actor, 'open_review');
  if not nomad_core.org_has_feature(p_organization_id, 'trailer', 'approval_links') then
    raise exception 'open_review: approval links need a higher plan' using errcode = 'TR005';
  end if;
  if not exists (select 1 from nomad_trailer.trailers t where t.id = p_trailer_id and t.organization_id = p_organization_id) then
    raise exception 'open_review: trailer not found' using errcode = 'P0002';
  end if;
  if coalesce(cardinality(p_render_ids), 0) = 0 or exists (
       select 1 from unnest(p_render_ids) as u(rid)
       where not exists (select 1 from nomad_trailer.renders r
                         where r.id = u.rid and r.trailer_id = p_trailer_id and r.organization_id = p_organization_id and r.status = 'succeeded')) then
    raise exception 'open_review: renders must be finished renders of this trailer' using errcode = '22023';
  end if;
  insert into nomad_trailer.reviews (organization_id, trailer_id, render_ids, token_sha256, reviewer_label, expires_at, created_by)
  values (p_organization_id, p_trailer_id, p_render_ids, p_token_sha256, p_label,
          now() + make_interval(days => nomad_trailer_private.config_int('review_link_days', 7)), p_actor)
  returning * into v_review;
  perform nomad_core.write_audit(p_organization_id, 'trailer.review.open', 'review', v_review.id::text);
  return v_review;
end;
$$;

-- 외부 승인 결정: 공개 /review/[token] 서버가 토큰을 sha256 해서 service_role로 호출(anon 직접 실행 없음).
create function nomad_trailer.decide_review(p_token_sha256 text, p_decision text, p_comment text default null)
returns nomad_trailer.reviews
language plpgsql security definer set search_path = ''
as $$
declare v_review nomad_trailer.reviews;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'decide_review: service_role only' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('approved', 'changes_requested') then
    raise exception 'decide_review: invalid decision' using errcode = '22023';
  end if;
  select * into v_review from nomad_trailer.reviews r where r.token_sha256 = p_token_sha256 for update;
  if v_review.id is null or v_review.status <> 'pending' then
    raise exception 'decide_review: link is not valid' using errcode = 'TR009';
  end if;
  if v_review.expires_at <= now() then
    -- 만료 표시는 남기고 결과로 알린다(raise하면 표시가 롤백된다)
    update nomad_trailer.reviews set status = 'expired' where id = v_review.id returning * into v_review;
    return v_review;
  end if;
  update nomad_trailer.reviews set status = p_decision, comment = left(p_comment, 1000) where id = v_review.id
  returning * into v_review;
  if p_decision = 'approved' then
    update nomad_trailer.trailers set status = 'approved' where id = v_review.trailer_id and status = 'active';
  end if;
  perform nomad_core.write_audit(v_review.organization_id, 'trailer.review.' || p_decision, 'review', v_review.id::text);
  return v_review;
end;
$$;

-- FLORA 책 가져오기(기능 flora_import). 다른 제품 스키마를 읽지 않는다: 서버가 FLORA 책 정보를 읽어 인자로 넘긴다.
create function nomad_trailer.import_flora_book(
  p_organization_id uuid, p_flora_book_id uuid, p_actor uuid,
  p_title text, p_subtitle text default null, p_author_name text default null, p_genre text default null
)
returns nomad_trailer.books
language plpgsql security definer set search_path = ''
as $$
declare v_book nomad_trailer.books;
begin
  perform nomad_trailer_private.assert_actor(p_organization_id, p_actor, 'import_flora_book');
  if p_flora_book_id is null then
    raise exception 'import_flora_book: flora book id required' using errcode = '22023';
  end if;
  if not nomad_core.org_has_feature(p_organization_id, 'trailer', 'flora_import') then
    raise exception 'import_flora_book: needs a higher plan' using errcode = 'TR005';
  end if;
  -- 책 수 한도(사용자 INSERT 트리거는 서버 경로를 건너뛰므로 여기서 본다)
  perform pg_advisory_xact_lock(hashtextextended('trailer:limits:' || p_organization_id::text, 0));
  if (select count(*) from nomad_trailer.books b where b.organization_id = p_organization_id and b.deleted_at is null)
     >= nomad_trailer_private.org_limit(p_organization_id, 'max_books', 1) then
    raise exception 'import_flora_book: plan limit reached on books' using errcode = 'TR005';
  end if;
  if exists (select 1 from nomad_trailer.books b where b.organization_id = p_organization_id
             and b.flora_book_id = p_flora_book_id and b.deleted_at is null) then
    raise exception 'import_flora_book: already imported' using errcode = '23505';
  end if;
  insert into nomad_trailer.books (organization_id, title, subtitle, author_name, genre, source, flora_book_id, created_by)
  values (p_organization_id, coalesce(nullif(btrim(p_title), ''), '제목 없음'), p_subtitle, p_author_name,
          case when p_genre in ('novel', 'essay', 'poetry', 'self_help', 'nonfiction_business', 'it_tech', 'children', 'fantasy_genre')
               then p_genre else 'other' end,
          'flora', p_flora_book_id, p_actor)
  returning * into v_book;
  perform nomad_core.write_audit(p_organization_id, 'trailer.book.import_flora', 'book', v_book.id::text, null,
                                 jsonb_build_object('flora_book_id', p_flora_book_id));
  return v_book;
end;
$$;

-- =====================================================================
-- 8. RLS 정책과 GRANT (anon: 테이블 권한 0)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['runtime_config', 'grammars', 'templates', 'music_tracks', 'books', 'purchase_links', 'brand_kits',
                           'trailers', 'briefs', 'scenes', 'metadata_packs', 'book_digests', 'link_clicks', 'scene_assets',
                           'generation_runs', 'renders', 'reviews'] loop
    execute format('alter table nomad_trailer.%I enable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema nomad_trailer from public, anon, authenticated;
grant all on all tables in schema nomad_trailer to service_role;
grant usage, select on all sequences in schema nomad_trailer to service_role;

-- 카탈로그: 공개 행만, trailer 이용권 사용자만. runtime_config는 grant 없음. 음악 원본 경로는 컬럼 grant에서 뺀다.
grant select on nomad_trailer.grammars, nomad_trailer.templates to authenticated;
grant select (id, code, title, mood, bpm, duration_ms, tier, preview_path, status, sort_order, created_at, updated_at)
  on nomad_trailer.music_tracks to authenticated;
create policy grammars_select on nomad_trailer.grammars for select to authenticated
  using (status = 'published' and nomad_trailer.has_catalog_access());
create policy templates_select on nomad_trailer.templates for select to authenticated
  using (status = 'published' and nomad_trailer.has_catalog_access());
create policy music_tracks_select on nomad_trailer.music_tracks for select to authenticated
  using (status = 'published' and nomad_trailer.has_catalog_access());

-- books: 이용권 멤버 읽기, editor 이상 쓰기(서버 컬럼 제외), 삭제는 owner·admin. 사용자는 flora 출처를 만들 수 없다.
grant select on nomad_trailer.books to authenticated;
grant insert (id, organization_id, title, subtitle, author_name, publisher_name, genre, language, isbn, published_on, description, audience,
              source, manuscript_path, cover_path) on nomad_trailer.books to authenticated;
grant update (title, subtitle, author_name, publisher_name, genre, language, isbn, published_on, description, audience,
              manuscript_path, cover_path, status, deleted_at) on nomad_trailer.books to authenticated;
grant delete on nomad_trailer.books to authenticated;
create policy books_select on nomad_trailer.books for select to authenticated
  using (nomad_trailer.has_access(organization_id));
create policy books_insert on nomad_trailer.books for insert to authenticated
  with check (nomad_trailer.can_edit(organization_id) and source in ('upload', 'paste'));
create policy books_update on nomad_trailer.books for update to authenticated
  using (nomad_trailer.can_edit(organization_id)) with check (nomad_trailer.can_edit(organization_id));
create policy books_delete on nomad_trailer.books for delete to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

grant select on nomad_trailer.purchase_links to authenticated;
grant insert (id, organization_id, book_id, store, label, url, is_affiliate, sort_order, is_active) on nomad_trailer.purchase_links to authenticated;
grant update (store, label, url, is_affiliate, sort_order, is_active) on nomad_trailer.purchase_links to authenticated;
grant delete on nomad_trailer.purchase_links to authenticated;

grant select on nomad_trailer.brand_kits to authenticated;
grant insert (id, organization_id, book_id, name, palette, font_display, font_body, logo_path, source) on nomad_trailer.brand_kits to authenticated;
grant update (name, palette, font_display, font_body, logo_path) on nomad_trailer.brand_kits to authenticated;
grant delete on nomad_trailer.brand_kits to authenticated;

grant select on nomad_trailer.metadata_packs to authenticated;
grant insert (id, organization_id, trailer_id, platform, title, description, hashtags, link_ids) on nomad_trailer.metadata_packs to authenticated;
grant update (title, description, hashtags, link_ids) on nomad_trailer.metadata_packs to authenticated;
grant delete on nomad_trailer.metadata_packs to authenticated;

do $$
declare t text;
begin
  foreach t in array array['purchase_links', 'brand_kits', 'metadata_packs'] loop
    execute format('create policy %1$s_select on nomad_trailer.%1$I for select to authenticated using (nomad_trailer.has_access(organization_id))', t);
    execute format('create policy %1$s_insert on nomad_trailer.%1$I for insert to authenticated with check (nomad_trailer.can_edit(organization_id))', t);
    execute format('create policy %1$s_update on nomad_trailer.%1$I for update to authenticated using (nomad_trailer.can_edit(organization_id)) with check (nomad_trailer.can_edit(organization_id))', t);
    execute format('create policy %1$s_delete on nomad_trailer.%1$I for delete to authenticated using (nomad_trailer.can_edit(organization_id))', t);
  end loop;
end $$;

-- trailers: 서버 컬럼(voice, storyboard_version, music_rights_ack_at/by)은 grant 없음
grant select on nomad_trailer.trailers to authenticated;
grant insert (id, organization_id, book_id, title, grammar_code, template_code, brand_kit_id, formats, duration_s, language, spoiler_level,
              narration_mode, voice_pref, music_track_id, music_path, music_rights_ack) on nomad_trailer.trailers to authenticated;
grant update (title, grammar_code, template_code, brand_kit_id, formats, duration_s, language, spoiler_level, narration_mode,
              voice_pref, music_track_id, music_path, music_rights_ack, current_brief_id, selected_hook, status) on nomad_trailer.trailers to authenticated;
grant delete on nomad_trailer.trailers to authenticated;
create policy trailers_select on nomad_trailer.trailers for select to authenticated
  using (nomad_trailer.has_access(organization_id));
create policy trailers_insert on nomad_trailer.trailers for insert to authenticated
  with check (nomad_trailer.can_edit(organization_id));
create policy trailers_update on nomad_trailer.trailers for update to authenticated
  using (nomad_trailer.can_edit(organization_id)) with check (nomad_trailer.can_edit(organization_id));
create policy trailers_delete on nomad_trailer.trailers for delete to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

-- briefs: 사용자 쓰기는 manual 새 버전 INSERT만(불변)
grant select on nomad_trailer.briefs to authenticated;
grant insert (id, organization_id, trailer_id, source, content) on nomad_trailer.briefs to authenticated;
create policy briefs_select on nomad_trailer.briefs for select to authenticated
  using (nomad_trailer.has_access(organization_id));
create policy briefs_insert on nomad_trailer.briefs for insert to authenticated
  with check (source = 'manual' and nomad_trailer.can_edit(organization_id));

-- scenes: 엔드카드 생성·삭제 불가, 인용 검증·revision은 grant 없음(트리거)
grant select on nomad_trailer.scenes to authenticated;
grant insert (id, organization_id, trailer_id, position, kind, duration_ms, text, narration, visual, music_cue) on nomad_trailer.scenes to authenticated;
grant update (position, duration_ms, text, narration, visual, music_cue) on nomad_trailer.scenes to authenticated;
grant delete on nomad_trailer.scenes to authenticated;
create policy scenes_select on nomad_trailer.scenes for select to authenticated
  using (nomad_trailer.has_access(organization_id));
create policy scenes_insert on nomad_trailer.scenes for insert to authenticated
  with check (kind <> 'end_card' and nomad_trailer.can_edit(organization_id));
create policy scenes_update on nomad_trailer.scenes for update to authenticated
  using (nomad_trailer.can_edit(organization_id)) with check (nomad_trailer.can_edit(organization_id));
create policy scenes_delete on nomad_trailer.scenes for delete to authenticated
  using (kind <> 'end_card' and nomad_trailer.can_edit(organization_id));

-- 서버 기록: 이용권 멤버 SELECT만. 승인 토큰 해시는 사용자에게 주지 않는다.
grant select on nomad_trailer.book_digests, nomad_trailer.link_clicks, nomad_trailer.scene_assets,
  nomad_trailer.generation_runs, nomad_trailer.renders to authenticated;
grant select (id, organization_id, trailer_id, render_ids, reviewer_label, status, expires_at, decided_at, comment, created_by, created_at, updated_at)
  on nomad_trailer.reviews to authenticated;
do $$
declare t text;
begin
  foreach t in array array['book_digests', 'link_clicks', 'scene_assets', 'generation_runs', 'renders', 'reviews'] loop
    execute format('create policy %1$s_select on nomad_trailer.%1$I for select to authenticated using (nomad_trailer.has_access(organization_id))', t);
  end loop;
end $$;

-- =====================================================================
-- 9. 함수 실행 권한: 기본 0, service_role 전부, authenticated는 정책 도우미·사용자 RPC만. anon 0.
-- =====================================================================
revoke execute on all functions in schema nomad_trailer from public, anon, authenticated;
grant execute on all functions in schema nomad_trailer to service_role;
grant execute on function
  nomad_trailer.has_access(uuid), nomad_trailer.can_edit(uuid), nomad_trailer.has_catalog_access(),
  nomad_trailer.valid_palette(jsonb), nomad_trailer.valid_hashtags(text[]),
  nomad_trailer.acknowledge_rights(uuid, text), nomad_trailer.save_scene(uuid, jsonb, integer), nomad_trailer.reorder_scenes(uuid, uuid[])
to authenticated;
revoke execute on all functions in schema nomad_trailer_private from public, anon, authenticated;
grant execute on all functions in schema nomad_trailer_private to service_role;

-- =====================================================================
-- 10. Storage (제품 전용 버킷, 경로 <organization_id>/trailer/...)
--   trailer-files    비공개. 사용자 업로드(원고·표지·음악·로고). 이용권 멤버 읽기, editor 이상 쓰기.
--   trailer-media    비공개. 서버 생성(장면 에셋·렌더 결과). 이용권 멤버 읽기만, 쓰기는 서버.
--   trailer-catalog  비공개. 카탈로그 음악 원본·템플릿 자산. 정책 없음 → service_role만(렌더러).
--   trailer-previews 공개 버킷(공개 URL). 템플릿 미리보기·음악 30초 미리듣기만. storage.objects 정책 없음(목록·쓰기 불가).
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('trailer-files',    'trailer-files',    false, 104857600, array['application/pdf', 'application/epub+zip',
     'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'text/markdown', 'text/plain',
     'image/png', 'image/jpeg', 'image/webp', 'audio/mpeg', 'audio/wav']),
  ('trailer-media',    'trailer-media',    false, 524288000, array['image/png', 'image/webp', 'image/jpeg', 'audio/mpeg', 'audio/wav',
     'video/mp4', 'application/x-subrip', 'text/plain']),
  ('trailer-catalog',  'trailer-catalog',  false, 52428800, array['audio/mpeg', 'audio/wav', 'image/png', 'image/webp', 'font/woff2']),
  ('trailer-previews', 'trailer-previews', true,  5242880,  array['image/webp', 'image/png', 'video/mp4', 'audio/mpeg'])
on conflict (id) do nothing;

create policy nomad_trailer_files_select on storage.objects for select to authenticated
  using (bucket_id = 'trailer-files' and (storage.foldername(name))[2] = 'trailer'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_trailer.has_access(((storage.foldername(name))[1])::uuid) else false end);
create policy nomad_trailer_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'trailer-files' and (storage.foldername(name))[2] = 'trailer'
              and (storage.foldername(name))[3] in ('books', 'music', 'brand')
              and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                       then nomad_trailer.can_edit(((storage.foldername(name))[1])::uuid)
                            and ((storage.foldername(name))[3] <> 'music'
                                 or coalesce(nomad_core.has_feature(((storage.foldername(name))[1])::uuid, 'trailer', 'music_upload'), false))
                       else false end);
create policy nomad_trailer_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'trailer-files' and (storage.foldername(name))[2] = 'trailer'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_trailer.can_edit(((storage.foldername(name))[1])::uuid) else false end);
create policy nomad_trailer_media_select on storage.objects for select to authenticated
  using (bucket_id = 'trailer-media' and (storage.foldername(name))[2] = 'trailer'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_trailer.has_access(((storage.foldername(name))[1])::uuid) else false end);

-- =====================================================================
-- 11. 카탈로그 시드(설정 데이터 — 수치 한도 아님). 장르 문법 6종, 템플릿 6종(무료 3, 프리미엄 3), 운영 상수(원본 제안값).
-- =====================================================================
insert into nomad_trailer.runtime_config (key, value_int, note) values
  ('max_active_runs_per_org',       4,      '제안: 조직당 동시 AI 실행'),
  ('max_active_renders_per_org',    2,      '제안: 조직당 동시 렌더'),
  ('max_quote_chars_each',          80,     '제안: 인용 장면 1개 글자 상한'),
  ('max_quote_chars_per_trailer',   300,    '제안: 트레일러 1편 인용 합계 상한'),
  ('max_manuscript_chars',          600000, '제안: 원고 글자 상한'),
  ('review_link_days',              7,      '제안: 외부 승인 링크 유효 기간(일)'),
  ('render_retention_days_free',    14,     '제안: C(무료) 렌더 보존(일)'),
  ('render_retention_days_paid',    90,     '제안: A·B 렌더 보존(일)')
on conflict (key) do nothing;

insert into nomad_trailer.grammars (code, name, description, book_genres, beats, narration_style, music_mood, status, sort_order) values
  ('novel_cinematic', '소설 시네마틱', '분위기와 인물의 갈등을 보여 주고 결말은 숨긴다',
   array['novel', 'fantasy_genre'],
   '[{"key":"atmosphere","label":"세계와 분위기","share_pct":20,"scene_kinds":["image_scene"]},
     {"key":"character","label":"인물과 욕망","share_pct":20,"scene_kinds":["character_scene","narration_card"]},
     {"key":"conflict","label":"갈등의 시작","share_pct":25,"scene_kinds":["image_scene","quote_card"]},
     {"key":"question","label":"질문 던지기","share_pct":15,"scene_kinds":["hook_text"]},
     {"key":"title","label":"제목 공개","share_pct":20,"scene_kinds":["title_card"]}]',
   'voiceover', 'cinematic_tension', 'published', 1),
  ('practical_problem', '실용서 문제 해결', '독자의 문제 → 이 책의 해법 → 얻는 결과 순서',
   array['self_help', 'nonfiction_business', 'it_tech'],
   '[{"key":"pain","label":"독자의 문제","share_pct":25,"scene_kinds":["hook_text","image_scene"]},
     {"key":"promise","label":"이 책의 약속","share_pct":20,"scene_kinds":["narration_card"]},
     {"key":"inside","label":"목차 하이라이트","share_pct":30,"scene_kinds":["narration_card","quote_card"]},
     {"key":"proof","label":"저자와 근거","share_pct":10,"scene_kinds":["title_card"]},
     {"key":"cta","label":"행동 유도","share_pct":15,"scene_kinds":["cta_card"]}]',
   'voiceover', 'upbeat_focus', 'published', 2),
  ('essay_quote', '에세이 문장', '한 문장의 여운을 길게 보여 준다',
   array['essay'],
   '[{"key":"mood","label":"정서 장면","share_pct":25,"scene_kinds":["image_scene"]},
     {"key":"line1","label":"문장 하나","share_pct":30,"scene_kinds":["quote_card"]},
     {"key":"line2","label":"문장 둘","share_pct":25,"scene_kinds":["quote_card"]},
     {"key":"title","label":"제목","share_pct":20,"scene_kinds":["title_card"]}]',
   'quote_reading', 'calm_piano', 'published', 3),
  ('poetry_typo', '시집 타이포그래피', '시 구절을 글자 움직임으로 낭독한다',
   array['poetry'],
   '[{"key":"silence","label":"여백","share_pct":15,"scene_kinds":["image_scene"]},
     {"key":"verse","label":"구절","share_pct":55,"scene_kinds":["quote_card"]},
     {"key":"title","label":"시집 제목","share_pct":30,"scene_kinds":["title_card"]}]',
   'quote_reading', 'ambient_soft', 'published', 4),
  ('children_storybook', '그림책 동화', '그림책 장면을 넘기듯 보여 준다(실존 아동 이미지 금지)',
   array['children'],
   '[{"key":"meet","label":"주인공 소개","share_pct":25,"scene_kinds":["character_scene"]},
     {"key":"adventure","label":"모험","share_pct":35,"scene_kinds":["image_scene","narration_card"]},
     {"key":"wonder","label":"궁금증","share_pct":20,"scene_kinds":["hook_text"]},
     {"key":"title","label":"제목","share_pct":20,"scene_kinds":["title_card"]}]',
   'voiceover', 'playful_light', 'published', 5),
  ('insight_hook', '인사이트 훅(숏폼)', '첫 2초 반전 질문으로 붙잡고 핵심 한 줄로 끝낸다',
   array['self_help', 'nonfiction_business', 'it_tech', 'essay', 'other'],
   '[{"key":"hook","label":"반전 질문","share_pct":20,"scene_kinds":["hook_text"]},
     {"key":"insight","label":"핵심 통찰","share_pct":45,"scene_kinds":["narration_card","quote_card"]},
     {"key":"turn","label":"그래서 이 책","share_pct":15,"scene_kinds":["title_card"]},
     {"key":"cta","label":"행동 유도","share_pct":20,"scene_kinds":["cta_card"]}]',
   'voiceover', 'upbeat_focus', 'published', 6)
on conflict (code) do nothing;

insert into nomad_trailer.templates (code, name, grammar_code, composition_id, formats, tier, status, sort_order) values
  ('cinematic_basic', '시네마틱 기본',   'novel_cinematic',    'CinematicBasic', array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5', 'cover_loop'], 'free',    'published', 1),
  ('practical_clean', '실용서 클린',     'practical_problem',  'PracticalClean', array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5', 'cover_loop'], 'free',    'published', 2),
  ('essay_paper',     '에세이 종이',     'essay_quote',        'EssayPaper',     array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5', 'cover_loop'], 'free',    'published', 3),
  ('poetry_ink',      '시집 잉크',       'poetry_typo',        'PoetryInk',      array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5'],               'premium', 'published', 4),
  ('storybook_page',  '그림책 페이지',   'children_storybook', 'StorybookPage',  array['vertical_9_16', 'landscape_16_9', 'square_1_1', 'portrait_4_5'],               'premium', 'published', 5),
  ('insight_kinetic', '인사이트 키네틱', 'insight_hook',       'InsightKinetic', array['vertical_9_16', 'square_1_1', 'portrait_4_5'],                                  'premium', 'published', 6)
on conflict (code) do nothing;

commit;
