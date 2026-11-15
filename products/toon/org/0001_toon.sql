-- toon-factory 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/2000_toon.sql 1~9·11장(작품·회차·컷·카탈로그·생성·내보내기·협찬)
-- core.organizations→nomad_core.organizations, org_members(member→editor)→nomad_core.memberships, has_entitlement·plan_features→nomad_core.has_feature,
-- core.jobs·credit_ledger→nomad_core.jobs·credit_ledger(uuid), core.write_audit→nomad_core.write_audit. 플랜 수치→plan_limits 키(시드 없음). 대응표: products/toon/existing.md
-- 플랜: 원본 free→C(무료 기능만), pro→A·B. 구독이 끊기면 C(무료 기능)만 남는다. AI 라우팅·AI 기능(원본 10장)은 org/0002_ai.sql.
-- 전제: nomad_core 코어 웨이브(touch_updated_at·jobs·credits·audit·plan_limits).
-- 되돌림: drop schema nomad_toon cascade; drop schema nomad_toon_private cascade;
--   delete from storage.buckets where id in ('toon-catalog', 'toon-previews', 'toon-user-assets'); (정책 toon_user_assets_select 함께 삭제)
begin;

create schema nomad_toon;
create schema nomad_toon_private;
revoke all on schema nomad_toon, nomad_toon_private from public, anon, authenticated;
grant usage on schema nomad_toon to authenticated, service_role;   -- anon 사용처 없음(공개 RPC 없음)
alter default privileges in schema nomad_toon revoke execute on functions from public;
alter default privileges in schema nomad_toon_private revoke execute on functions from public;

insert into nomad_core.products (code, name) values ('toon', 'Toon Factory') on conflict (code) do nothing;
-- 플랜 A/B/C 와 기능 잠금(수치 없음). 원본 free = C(구독 없는 조직 포함), pro = A·B.
-- studio = 작품·회차·컷 작성과 카탈로그 읽기(모든 플랜). 나머지는 pro 기능 = 구독이 끊기면 잠긴다.
insert into nomad_core.plans (product_code, code, name) values ('toon', 'A', 'A'), ('toon', 'B', 'B'), ('toon', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('toon', 'studio', '작품 제작(작품·회차·컷)'),
  ('toon', 'export_png', 'PNG 내보내기'),
  ('toon', 'export_zip', 'ZIP 내보내기'),
  ('toon', 'export_strip', '웹툰 세로 스트립 내보내기'),
  ('toon', 'export_mp4', 'MP4 내보내기'),
  ('toon', 'no_watermark', '워터마크 없음'),
  ('toon', 'premium_assets', '프리미엄 에셋'),
  ('toon', 'commercial_use', '상업적 이용'),
  ('toon', 'sponsorship', '브랜디드 툰(협찬)')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'toon', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['studio', 'export_png']) f
union all
select 'toon', p, f from unnest(array['A', 'B']) p,
  unnest(array['export_zip', 'export_strip', 'export_mp4', 'no_watermark', 'premium_assets', 'commercial_use', 'sponsorship']) f
on conflict do nothing;
-- plan_limits 키(시드 없음, 없으면 원본 free 값): max_series 1 · max_episodes_per_series 3 · max_cuts_per_episode 10
--   · exports_per_month 20 · mp4_max_seconds 0 · user_asset_storage_mb 100. 무제한 = 2147483647.

-- ---------- 정책 도우미 (authenticated 실행) ----------
-- 조직 작품 접근: 멤버 + studio 이용권(C 포함이므로 구독이 끊겨도 무료 기능은 남는다)
create function nomad_toon.has_access(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.has_feature(p_org, 'toon', 'studio'), false) $$;

-- 쓰기: owner/admin/editor(원본 member→editor) + 이용권
create function nomad_toon.can_edit(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(p_org) in ('owner', 'admin', 'editor'), false)
     and nomad_toon.has_access(p_org)
$$;

create function nomad_toon.is_manager(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(p_org) in ('owner', 'admin'), false) and nomad_toon.has_access(p_org)
$$;

-- 카탈로그 읽기: studio 이용권이 있는 조직의 멤버인가(원본 has_toon_access)
create function nomad_toon.has_toon_access() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from nomad_core.memberships m
    where m.user_id = (select auth.uid()) and nomad_core.has_feature(m.organization_id, 'toon', 'studio'))
$$;

-- ---------- 비노출 도우미 ----------
-- 플랜 한도(plan_limits). 키가 없으면 원본 free 값.
create function nomad_toon_private.limit_int(p_org uuid, p_key text, p_default integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_plan_limit(p_org, 'toon', p_key), p_default) $$;

-- 조직의 현재 플랜 코드(구독 없음·만료 = C)
create function nomad_toon_private.plan_code(p_org uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select s.plan_code from nomad_core.subscriptions s
    where s.organization_id = p_org and s.product_code = 'toon' and s.status = 'active'
      and s.starts_at <= now() and (s.ends_at is null or s.ends_at > now())
    limit 1), 'C')
$$;

-- features 의 정수 키(원본 그대로). 키가 없거나 숫자가 아니면 기본값.
create function nomad_toon.feature_int(p_features jsonb, p_key text, p_default integer) returns integer
language sql immutable set search_path = ''
as $$ select case when jsonb_typeof(p_features -> p_key) = 'number' then (p_features ->> p_key)::integer else p_default end $$;

-- 조직의 toon 기능 값(원본 plan_features 와 같은 모양). 멤버 또는 서버만.
create function nomad_toon.plan_features(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_exports jsonb; v_tiers jsonb;
begin
  if not nomad_core.is_service_caller() and nomad_core.organization_role(p_org) is null then
    raise exception 'plan_features: not a member' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(x.k), '[]'::jsonb) into v_exports
  from (values ('png', 'export_png'), ('zip', 'export_zip'), ('webtoon_strip', 'export_strip'), ('mp4', 'export_mp4')) as x(k, f)
  where nomad_core.org_has_feature(p_org, 'toon', x.f);
  v_tiers := case when nomad_core.org_has_feature(p_org, 'toon', 'premium_assets')
                  then '["free", "premium"]'::jsonb else '["free"]'::jsonb end;
  return jsonb_build_object(
    'plan_code', nomad_toon_private.plan_code(p_org),
    'studio', nomad_core.org_has_feature(p_org, 'toon', 'studio'),
    'watermark', not nomad_core.org_has_feature(p_org, 'toon', 'no_watermark'),
    'export', v_exports,
    'asset_tiers', v_tiers,
    'commercial_use', nomad_core.org_has_feature(p_org, 'toon', 'commercial_use'),
    'sponsorship', nomad_core.org_has_feature(p_org, 'toon', 'sponsorship'),
    'max_series', nomad_toon_private.limit_int(p_org, 'max_series', 1),
    'max_episodes_per_series', nomad_toon_private.limit_int(p_org, 'max_episodes_per_series', 3),
    'max_cuts_per_episode', nomad_toon_private.limit_int(p_org, 'max_cuts_per_episode', 10),
    'exports_per_month', nomad_toon_private.limit_int(p_org, 'exports_per_month', 20),
    'mp4_max_seconds', nomad_toon_private.limit_int(p_org, 'mp4_max_seconds', 0),
    'user_asset_storage_mb', nomad_toon_private.limit_int(p_org, 'user_asset_storage_mb', 100));
end;
$$;

-- ---------- 1. 카탈로그 (플랫폼 소유, 쓰기 service_role) ----------
create table nomad_toon.asset_packs (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique constraint asset_packs_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name                   text not null,
  description            text,
  style_preset           text not null default 'flat_line' constraint asset_packs_style_preset_check check (style_preset ~ '^[a-z][a-z0-9_]{1,40}$'),
  tier                   text not null default 'free' constraint asset_packs_tier_check check (tier in ('free', 'premium')),
  license_source         text not null constraint asset_packs_license_source_check check (license_source in ('in_house', 'commissioned', 'licensed_commercial')),
  license_ref            text not null constraint asset_packs_license_ref_check check (char_length(license_ref) between 3 and 200),
  commercial_use_allowed boolean not null default true,
  license_verified_at    timestamptz,
  license_verified_by    uuid,
  status                 text not null default 'draft' constraint asset_packs_status_check check (status in ('draft', 'published', 'retired')),
  sort_order             integer not null default 0,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint asset_packs_publish_license_check
    check (status <> 'published' or (license_verified_at is not null and license_verified_by is not null))
);
create index asset_packs_status_idx on nomad_toon.asset_packs (status, sort_order);
comment on table nomad_toon.asset_packs is '에셋 팩 카탈로그(플랫폼 소유). 쓰기는 service_role, 읽기는 studio 이용권 사용자(공개 행만). 라이선스 검증 없이 공개 불가.';

create table nomad_toon.characters (
  id          uuid primary key default gen_random_uuid(),
  pack_id     uuid not null references nomad_toon.asset_packs(id) on delete restrict,
  code        text not null constraint characters_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name        text not null,
  description text,
  status      text not null default 'draft' constraint characters_status_check check (status in ('draft', 'published', 'retired')),
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (pack_id, code)
);
comment on table nomad_toon.characters is '카탈로그 캐릭터(팩 소속). 쓰기는 service_role, 읽기는 studio 이용권 사용자(공개 행만).';

create table nomad_toon.assets (
  id           uuid primary key default gen_random_uuid(),
  pack_id      uuid not null references nomad_toon.asset_packs(id) on delete restrict,
  character_id uuid references nomad_toon.characters(id) on delete restrict,
  kind         text not null constraint assets_kind_check check (kind in ('pose', 'expression', 'background', 'prop', 'bubble', 'effect_text', 'bgm')),
  code         text not null constraint assets_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name         text not null,
  tier         text not null default 'free' constraint assets_tier_check check (tier in ('free', 'premium')),
  storage_path text not null,            -- 버킷 toon-catalog: 원본(렌더 워커만)
  editor_path  text,                     -- 버킷 toon-catalog: 편집용 1024px(서명 URL, 등급 검사 후)
  preview_path text not null,            -- 버킷 toon-previews: 256px 썸네일(공개)
  mime         text not null constraint assets_mime_check check (mime in ('image/png', 'image/webp', 'image/svg+xml', 'audio/mpeg')),
  width        integer constraint assets_width_check check (width is null or width between 1 and 8192),
  height       integer constraint assets_height_check check (height is null or height between 1 and 8192),
  duration_ms  integer constraint assets_duration_check check (duration_ms is null or duration_ms between 1 and 600000),
  anchors      jsonb not null default '{}'::jsonb,
  tags         text[] not null default '{}',
  status       text not null default 'draft' constraint assets_status_check check (status in ('draft', 'published', 'retired')),
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint assets_character_kind_check check ((kind in ('pose', 'expression')) = (character_id is not null)),
  constraint assets_bgm_mime_check check ((kind = 'bgm') = (mime = 'audio/mpeg')),
  constraint assets_identity_uniq unique nulls not distinct (pack_id, character_id, kind, code)
);
create index assets_pack_kind_idx on nomad_toon.assets (pack_id, kind, sort_order);
create index assets_character_kind_idx on nomad_toon.assets (character_id, kind) where character_id is not null;
comment on table nomad_toon.assets is '카탈로그 에셋. 원본·편집 경로 컬럼은 사용자에게 주지 않는다(컬럼 grant). 쓰기는 service_role.';

-- 사용자용 카탈로그 뷰: 원본/편집 경로 제외. security_invoker 라 assets RLS 를 그대로 통과한다.
create view nomad_toon.catalog_assets with (security_invoker = true) as
  select a.id, a.pack_id, a.character_id, a.kind, a.code, a.name, a.tier, a.preview_path, a.mime,
         a.width, a.height, a.duration_ms, a.anchors, a.tags, a.sort_order
  from nomad_toon.assets a
  where a.status = 'published';

-- ---------- 2. 작품 (조직 소유, 멤버 쓰기 + 플랜 한도 트리거) ----------
create table nomad_toon.series (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  title           text not null constraint series_title_check check (char_length(title) between 1 and 80),
  format          text not null constraint series_format_check check (format in ('instatoon', 'webtoon')),
  canvas_width    integer not null constraint series_canvas_width_check check (canvas_width between 320 and 2048),
  canvas_height   integer not null constraint series_canvas_height_check check (canvas_height between 320 and 4096),
  genre           text constraint series_genre_check check (genre is null or char_length(genre) <= 40),
  synopsis        text constraint series_synopsis_check check (synopsis is null or char_length(synopsis) <= 2000),
  style_pack_id   uuid references nomad_toon.asset_packs(id) on delete set null,
  status          text not null default 'active' constraint series_status_check check (status in ('active', 'archived')),
  metadata        jsonb not null default '{}'::jsonb,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint series_id_org_uniq unique (id, organization_id)
);
create index series_org_updated_idx on nomad_toon.series (organization_id, updated_at);
comment on table nomad_toon.series is '작품(조직 소유). 멤버 쓰기(editor 이상), 삭제 owner/admin. 작품 수는 plan_limits max_series.';

create table nomad_toon.series_characters (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  series_id       uuid not null,
  character_id    uuid not null references nomad_toon.characters(id) on delete restrict,
  display_name    text not null constraint series_characters_name_check check (char_length(display_name) between 1 and 40),
  role_note       text constraint series_characters_role_note_check check (role_note is null or char_length(role_note) <= 300),
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint series_characters_series_fk foreign key (series_id, organization_id) references nomad_toon.series (id, organization_id) on delete cascade,
  unique (series_id, character_id)
);
create index series_characters_org_updated_idx on nomad_toon.series_characters (organization_id, updated_at);
comment on table nomad_toon.series_characters is '작품 캐스트(카탈로그 캐릭터 + 작품 내 이름). 작품과 같은 조직만(복합 FK).';

create table nomad_toon.episodes (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  series_id       uuid not null,
  number          integer not null constraint episodes_number_check check (number between 1 and 9999),
  title           text not null default '' constraint episodes_title_check check (char_length(title) <= 80),
  logline         text constraint episodes_logline_check check (logline is null or char_length(logline) <= 500),
  script          jsonb not null default '{}'::jsonb,
  status          text not null default 'draft' constraint episodes_status_check check (status in ('draft', 'storyboarded', 'editing', 'done')),
  sponsorship_id  uuid,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint episodes_series_fk foreign key (series_id, organization_id) references nomad_toon.series (id, organization_id) on delete cascade,
  constraint episodes_id_org_uniq unique (id, organization_id),
  constraint episodes_series_number_uniq unique (series_id, number),
  constraint episodes_script_size_check check (pg_column_size(script) <= 131072)
);
create index episodes_org_updated_idx on nomad_toon.episodes (organization_id, updated_at);
create index episodes_sponsorship_idx on nomad_toon.episodes (sponsorship_id) where sponsorship_id is not null;
comment on table nomad_toon.episodes is '회차(작품 소속, 콘티 script). 회차 수는 plan_limits max_episodes_per_series.';

create table nomad_toon.cuts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  episode_id      uuid not null,
  position        integer not null constraint cuts_position_check check (position between 0 and 999),
  width           integer not null constraint cuts_width_check check (width between 320 and 2048),
  height          integer not null constraint cuts_height_check check (height between 320 and 4096),
  doc             jsonb not null default '{"v": 1, "layers": []}'::jsonb,
  duration_ms     integer not null default 2500 constraint cuts_duration_check check (duration_ms between 500 and 10000),
  revision        integer not null default 1,
  thumbnail_path  text,           -- 비공개 버킷 toon-user-assets <organization_id>/toon/thumbnails/… (공개 toon-previews 금지)
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint cuts_episode_fk foreign key (episode_id, organization_id) references nomad_toon.episodes (id, organization_id) on delete cascade,
  constraint cuts_episode_position_uniq unique (episode_id, position) deferrable initially deferred,
  constraint cuts_doc_shape_check check (
    jsonb_typeof(doc) = 'object'
    and coalesce(jsonb_typeof(doc -> 'v'), '') = 'number'
    and case when jsonb_typeof(doc -> 'layers') = 'array' then jsonb_array_length(doc -> 'layers') <= 60 else false end),
  constraint cuts_doc_size_check check (pg_column_size(doc) <= 262144)
);
create index cuts_org_updated_idx on nomad_toon.cuts (organization_id, updated_at);
comment on table nomad_toon.cuts is '컷(회차 소속, doc = 레이어 판별 유니온 문서). revision 은 트리거가 관리(낙관적 동시성 save_cut_doc).';

-- 협찬(브랜디드 툰, 원본 11-2). 승인·수정 요청은 decide_sponsorship(owner/admin)만.
create table nomad_toon.sponsorships (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  series_id         uuid not null,
  advertiser_name   text not null constraint sponsorships_advertiser_check check (char_length(advertiser_name) between 1 and 80),
  product_name      text constraint sponsorships_product_check check (product_name is null or char_length(product_name) <= 80),
  brief             text constraint sponsorships_brief_check check (brief is null or char_length(brief) <= 3000),
  key_messages      text[] not null default '{}' constraint sponsorships_key_messages_check check (cardinality(key_messages) <= 10),
  banned_terms      text[] not null default '{}' constraint sponsorships_banned_terms_check check (cardinality(banned_terms) <= 50),
  compensation_kind text not null constraint sponsorships_compensation_check check (compensation_kind in ('paid', 'free_product', 'commission', 'other')),
  disclosure_text   text not null default '광고' constraint sponsorships_disclosure_check check (char_length(btrim(disclosure_text)) between 2 and 60),
  virtual_character boolean not null default true,
  status            text not null default 'draft'
                    constraint sponsorships_status_check check (status in ('draft', 'in_review', 'changes_requested', 'approved', 'closed')),
  decided_at        timestamptz,
  decided_by        uuid,
  decision_note     text constraint sponsorships_decision_note_check check (decision_note is null or char_length(decision_note) <= 500),
  created_by        uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint sponsorships_series_fk foreign key (series_id, organization_id) references nomad_toon.series (id, organization_id) on delete cascade,
  constraint sponsorships_id_org_uniq unique (id, organization_id),
  constraint sponsorships_decided_check check (status not in ('approved', 'changes_requested') or (decided_at is not null and decided_by is not null))
);
create index sponsorships_org_updated_idx on nomad_toon.sponsorships (organization_id, updated_at);
comment on table nomad_toon.sponsorships is '브랜디드 툰 협찬(광고주 브리프·대가성 문구·승인). sponsorship 기능(A·B)만 생성, 결정은 decide_sponsorship.';

alter table nomad_toon.episodes add constraint episodes_sponsorship_fk
  foreign key (sponsorship_id, organization_id) references nomad_toon.sponsorships (id, organization_id) on delete restrict;

-- ---------- 3. 서버 기록 (쓰기 service_role 만) ----------
create table nomad_toon.generations (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  series_id        uuid references nomad_toon.series(id) on delete set null,
  kind             text not null constraint generations_kind_check check (kind in ('background', 'prop')),
  prompt           text not null constraint generations_prompt_check check (char_length(prompt) between 1 and 1000),
  prompt_en        text,
  negative_prompt  text,
  style_preset     text,
  model            text not null,
  seed             bigint,
  width            integer not null constraint generations_width_check check (width between 256 and 2048),
  height           integer not null constraint generations_height_check check (height between 256 and 2048),
  num_images       integer not null default 1 constraint generations_num_images_check check (num_images between 1 and 4),
  status           text not null default 'queued'
                   constraint generations_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  job_id           uuid references nomad_core.jobs(id) on delete set null,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  credits          integer not null default 0 constraint generations_credits_check check (credits >= 0),
  fal_request_id   text unique,
  request_id       uuid not null unique,
  error            text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  finished_at      timestamptz
);
create index generations_org_created_idx on nomad_toon.generations (organization_id, created_at desc);
create index generations_job_idx on nomad_toon.generations (job_id) where job_id is not null;
comment on table nomad_toon.generations is 'AI 이미지 생성 기록(크레딧·잡 연결, 멱등 request_id). 쓰기는 서버만, 멤버는 읽기.';

create table nomad_toon.user_assets (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  generation_id   uuid references nomad_toon.generations(id) on delete set null,
  kind            text not null constraint user_assets_kind_check check (kind in ('background', 'prop')),
  source          text not null constraint user_assets_source_check check (source in ('ai_generated', 'upload')),
  ai_generated    boolean not null,
  model           text,
  storage_path    text not null,   -- 버킷 toon-user-assets: <organization_id>/toon/user_assets/<uuid>.png (서버만 씀)
  preview_path    text not null,   -- 비공개 버킷 toon-user-assets <organization_id>/toon/user_assets/…_preview (공개 toon-previews 금지)
  width           integer not null,
  height          integer not null,
  bytes           bigint not null default 0,
  label           text constraint user_assets_label_check check (label is null or char_length(label) <= 80),
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  constraint user_assets_ai_source_check check ((source = 'ai_generated') = ai_generated),
  constraint user_assets_ai_model_check check (not ai_generated or model is not null)
);
create index user_assets_org_created_idx on nomad_toon.user_assets (organization_id, created_at desc) where deleted_at is null;
create index user_assets_org_updated_idx on nomad_toon.user_assets (organization_id, updated_at);
comment on table nomad_toon.user_assets is '채택한 생성물·업로드(AI 생성 표시 무결성). 쓰기는 서버, 보관은 archive_user_asset(소프트 삭제).';

create table nomad_toon.exports (
  id                      uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references nomad_core.organizations(id) on delete cascade,
  episode_id              uuid references nomad_toon.episodes(id) on delete set null,
  kind                    text not null constraint exports_kind_check check (kind in ('png', 'zip', 'webtoon_strip', 'mp4')),
  status                  text not null default 'queued'
                          constraint exports_status_check check (status in ('queued', 'running', 'succeeded', 'failed', 'canceled')),
  plan_code               text not null default 'C',      -- 요청 시점 플랜(트리거가 기록)
  watermark               boolean not null default true,  -- 트리거가 no_watermark 이용권으로 강제(요청 값은 켤 수만 있다)
  ai_label                boolean not null default false,
  ai_label_visible        boolean not null default true,
  options                 jsonb not null default '{}'::jsonb,
  preset                  text,
  job_id                  uuid references nomad_core.jobs(id) on delete set null,
  credit_ledger_id        uuid references nomad_core.credit_ledger(id),
  credits                 integer not null default 0 constraint exports_credits_check check (credits >= 0),
  request_id              uuid not null unique,
  output_paths            text[] not null default '{}',
  bytes                   bigint,
  duration_ms             integer,
  error                   text,
  sponsorship_id          uuid references nomad_toon.sponsorships(id) on delete set null,
  disclosure_text         text,
  virtual_character_label boolean not null default false,
  created_by              uuid,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  started_at              timestamptz,
  finished_at             timestamptz,
  expires_at              timestamptz,
  constraint exports_ai_label_visible_check check (ai_label_visible or ai_label),
  constraint exports_preset_check check (
    preset is null or preset in ('instagram_carousel', 'webtoon_canvas', 'naver_challenge', 'vertical_9x16')),
  constraint exports_preset_kind_check check (
    preset is null
    or (preset = 'instagram_carousel' and kind in ('png', 'zip'))
    or (preset in ('webtoon_canvas', 'naver_challenge') and kind = 'webtoon_strip')
    or (preset = 'vertical_9x16' and kind = 'mp4')),
  constraint exports_disclosure_check check (sponsorship_id is null or disclosure_text is not null)
);
create index exports_org_created_idx on nomad_toon.exports (organization_id, created_at desc);
create index exports_org_month_idx on nomad_toon.exports (organization_id, kind, created_at) where status in ('queued', 'running', 'succeeded');
create index exports_job_idx on nomad_toon.exports (job_id) where job_id is not null;
comment on table nomad_toon.exports is '내보내기 기록. 쓰기는 서버, 플랜·워터마크·종류 잠금·협찬 문구는 트리거가 정한다(요청 값 불신).';

-- ---------- 4. 트리거 ----------
do $$
declare t text;
begin
  foreach t in array array['asset_packs', 'characters', 'assets', 'series', 'series_characters', 'episodes', 'cuts',
                           'sponsorships', 'generations', 'user_assets', 'exports'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_toon.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
end $$;

-- 플랜 한도(작품 수·회차 수·컷 수). 사용자 insert 에만. 키가 없으면 원본 free 값.
create function nomad_toon_private.enforce_plan_limits() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_limit integer; v_count integer; v_format text;
begin
  if nomad_core.is_service_caller() then
    return new;
  end if;
  -- update 는 소유 키가 바뀔 때만(다른 작품·회차·조직으로 옮기기 = 그쪽 한도로 센다)
  if tg_op = 'UPDATE' then
    if to_jsonb(new) -> 'organization_id' = to_jsonb(old) -> 'organization_id'
       and to_jsonb(new) -> (case tg_table_name when 'episodes' then 'series_id' when 'cuts' then 'episode_id' else 'organization_id' end)
         = to_jsonb(old) -> (case tg_table_name when 'episodes' then 'series_id' when 'cuts' then 'episode_id' else 'organization_id' end) then
      return new;
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('toon:limits:' || new.organization_id::text, 0));
  if tg_table_name = 'series' then
    v_limit := nomad_toon_private.limit_int(new.organization_id, 'max_series', 1);
    select count(*) into v_count from nomad_toon.series s where s.organization_id = new.organization_id;
  elsif tg_table_name = 'episodes' then
    v_limit := nomad_toon_private.limit_int(new.organization_id, 'max_episodes_per_series', 3);
    select count(*) into v_count from nomad_toon.episodes e where e.series_id = new.series_id;
  else
    v_limit := nomad_toon_private.limit_int(new.organization_id, 'max_cuts_per_episode', 10);
    select s.format into v_format
    from nomad_toon.episodes e join nomad_toon.series s on s.id = e.series_id
    where e.id = new.episode_id;
    if v_format = 'instatoon' then
      v_limit := least(v_limit, 10);  -- 인스타 캐러셀 상한(원본 그대로)
    end if;
    select count(*) into v_count from nomad_toon.cuts c where c.episode_id = new.episode_id;
  end if;
  if v_count >= v_limit then
    raise exception 'toon: plan limit reached on % (limit %)', tg_table_name, v_limit using errcode = 'TN001';
  end if;
  return new;
end;
$$;
create trigger series_plan_limits before insert or update of organization_id on nomad_toon.series
  for each row execute function nomad_toon_private.enforce_plan_limits();
create trigger episodes_plan_limits before insert or update of organization_id, series_id on nomad_toon.episodes
  for each row execute function nomad_toon_private.enforce_plan_limits();
create trigger cuts_plan_limits before insert or update of organization_id, episode_id on nomad_toon.cuts
  for each row execute function nomad_toon_private.enforce_plan_limits();

-- 회차의 협찬 연결(sponsorship_id) 지정·변경은 owner/admin 만(대가성 문구·승인 게이트를 editor 가 우회하지 못하게)
create function nomad_toon_private.guard_episode_sponsorship() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if nomad_core.is_service_caller() then
    return new;
  end if;
  if (tg_op = 'INSERT' and new.sponsorship_id is not null)
     or (tg_op = 'UPDATE' and new.sponsorship_id is distinct from old.sponsorship_id) then
    if not nomad_toon.is_manager(new.organization_id) then
      raise exception 'toon: only owner/admin can link a sponsorship' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger episodes_guard_sponsorship before insert or update of sponsorship_id on nomad_toon.episodes
  for each row execute function nomad_toon_private.guard_episode_sponsorship();

-- 컷 revision: 문서/크기/시간이 바뀔 때만 +1. 사용자가 임의로 바꿀 수 없다.
create function nomad_toon_private.bump_cut_revision() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.revision := 1;
  elsif new.doc is distinct from old.doc or new.width is distinct from old.width
     or new.height is distinct from old.height or new.duration_ms is distinct from old.duration_ms then
    new.revision := old.revision + 1;
  else
    new.revision := old.revision;
  end if;
  return new;
end;
$$;
create trigger cuts_bump_revision before insert or update on nomad_toon.cuts for each row execute function nomad_toon_private.bump_cut_revision();

-- 실행 상태 전이(generations, exports). service_role 쓰기에도 적용.
create function nomad_toon_private.enforce_run_status_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'queued' then
      raise exception 'toon: % must start as queued', tg_table_name using errcode = '22023';
    end if;
    return new;
  end if;
  if new.status = old.status then
    return new;
  end if;
  if not ((old.status = 'queued' and new.status in ('running', 'canceled', 'failed'))
       or (old.status = 'running' and new.status in ('succeeded', 'failed', 'queued'))) then
    raise exception 'toon: invalid % status transition % -> %', tg_table_name, old.status, new.status using errcode = '22023';
  end if;
  if new.status in ('succeeded', 'failed', 'canceled') then
    new.finished_at := coalesce(new.finished_at, now());
  end if;
  return new;
end;
$$;
create trigger generations_status_transition before insert or update on nomad_toon.generations
  for each row execute function nomad_toon_private.enforce_run_status_transition();
create trigger exports_status_transition before insert or update on nomad_toon.exports
  for each row execute function nomad_toon_private.enforce_run_status_transition();

-- 협찬 상태 전이(원본 그대로). approved / changes_requested 는 decide_sponsorship 만.
create function nomad_toon_private.enforce_sponsorship_status() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_deciding boolean := coalesce(current_setting('nomad_toon.sponsorship_decision', true), '') = 'on';
  v_svc boolean := nomad_core.is_service_caller();
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' and not v_svc then
      raise exception 'sponsorship: must start as draft' using errcode = '22023';
    end if;
    if not v_svc then
      -- 플랜 게이트: sponsorship 기능(A·B). 구독이 끊기면(C) 새 협찬을 만들 수 없다.
      if not nomad_core.org_has_feature(new.organization_id, 'toon', 'sponsorship') then
        raise exception 'toon: sponsorship is not in this plan' using errcode = 'TN002';
      end if;
      new.decided_at := null; new.decided_by := null; new.decision_note := null;
    end if;
    return new;
  end if;
  if old.status = 'approved' and new.status = 'approved' and not v_deciding
     and (new.brief is distinct from old.brief or new.key_messages is distinct from old.key_messages
          or new.disclosure_text is distinct from old.disclosure_text or new.compensation_kind is distinct from old.compensation_kind
          or new.virtual_character is distinct from old.virtual_character or new.advertiser_name is distinct from old.advertiser_name
          or new.product_name is distinct from old.product_name) then
    new.status := 'in_review'; new.decided_at := null; new.decided_by := null;
    return new;
  end if;
  if new.status = old.status then
    if not v_deciding and not v_svc then
      new.decided_at := old.decided_at; new.decided_by := old.decided_by; new.decision_note := old.decision_note;
    end if;
    return new;
  end if;
  if v_deciding or v_svc then
    if not ((old.status = 'in_review' and new.status in ('approved', 'changes_requested'))
            or (old.status = 'approved' and new.status = 'closed')
            or (old.status in ('draft', 'changes_requested') and new.status = 'in_review')
            or (old.status = 'in_review' and new.status = 'draft')) then
      raise exception 'sponsorship: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    return new;
  end if;
  if not ((old.status = 'draft' and new.status = 'in_review')
          or (old.status = 'in_review' and new.status = 'draft')
          or (old.status = 'changes_requested' and new.status in ('draft', 'in_review'))
          or (old.status = 'approved' and new.status = 'closed')) then
    raise exception 'sponsorship: status % -> % needs decide_sponsorship', old.status, new.status using errcode = '42501';
  end if;
  new.decided_at := old.decided_at; new.decided_by := old.decided_by; new.decision_note := old.decision_note;
  return new;
end;
$$;
create trigger sponsorships_status before insert or update on nomad_toon.sponsorships
  for each row execute function nomad_toon_private.enforce_sponsorship_status();

-- 내보내기 행(서버 기록) 보정: 플랜 코드·워터마크·종류 잠금(신규, 원본은 서버 코드가 판정) + 협찬 정보(원본 apply_export_sponsorship).
--   협찬 회차는 승인 전 최종 내보내기 금지(TN008). options.purpose = 'review' 시안은 워터마크 강제.
create function nomad_toon_private.apply_export_sponsorship() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_sp nomad_toon.sponsorships; v_feature text;
begin
  v_feature := case new.kind when 'png' then 'export_png' when 'zip' then 'export_zip'
                             when 'webtoon_strip' then 'export_strip' else 'export_mp4' end;
  if not nomad_core.org_has_feature(new.organization_id, 'toon', v_feature) then
    raise exception 'toon: export % is not in this plan', new.kind using errcode = 'TN004';
  end if;
  new.plan_code := nomad_toon_private.plan_code(new.organization_id);
  new.watermark := coalesce(new.watermark, true) or not nomad_core.org_has_feature(new.organization_id, 'toon', 'no_watermark');
  new.sponsorship_id := null; new.disclosure_text := null; new.virtual_character_label := false;
  if new.episode_id is null then
    return new;
  end if;
  if not exists (select 1 from nomad_toon.episodes e where e.id = new.episode_id and e.organization_id = new.organization_id) then
    raise exception 'toon: episode is not in this organization' using errcode = '22023';
  end if;
  select s.* into v_sp
  from nomad_toon.episodes e join nomad_toon.sponsorships s on s.id = e.sponsorship_id and s.organization_id = e.organization_id
  where e.id = new.episode_id;
  if not found then
    return new;
  end if;
  if coalesce(new.options ->> 'purpose', '') = 'review' then
    new.watermark := true;
  elsif v_sp.status <> 'approved' then
    raise exception 'toon: sponsored episode needs an approved sponsorship before export' using errcode = 'TN008';
  end if;
  new.sponsorship_id := v_sp.id;
  new.disclosure_text := v_sp.disclosure_text;
  new.virtual_character_label := v_sp.virtual_character;
  return new;
end;
$$;
create trigger exports_apply_sponsorship before insert on nomad_toon.exports
  for each row execute function nomad_toon_private.apply_export_sponsorship();

-- 내보내기 행의 판정 값은 insert 때 트리거가 정한 뒤 바꿀 수 없다(service_role 포함). 진행 상태·결과 경로만 갱신.
create function nomad_toon_private.exports_immutable() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.episode_id is distinct from old.episode_id
     or new.kind is distinct from old.kind or new.preset is distinct from old.preset or new.plan_code is distinct from old.plan_code
     or new.watermark is distinct from old.watermark or new.request_id is distinct from old.request_id
     or new.sponsorship_id is distinct from old.sponsorship_id or new.disclosure_text is distinct from old.disclosure_text
     or new.virtual_character_label is distinct from old.virtual_character_label
     or new.credits is distinct from old.credits or new.credit_ledger_id is distinct from old.credit_ledger_id then
    raise exception 'toon: export decision columns are immutable' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger exports_immutable before update on nomad_toon.exports
  for each row execute function nomad_toon_private.exports_immutable();

-- ---------- 5. RPC ----------
-- 컷 문서 저장(낙관적 동시성). invoker: RLS 그대로.
create function nomad_toon.save_cut_doc(p_cut_id uuid, p_doc jsonb, p_expected_revision integer) returns integer
language plpgsql security invoker set search_path = ''
as $$
declare v_rev integer;
begin
  update nomad_toon.cuts set doc = p_doc
  where id = p_cut_id and revision = p_expected_revision
  returning revision into v_rev;
  if v_rev is null then
    if exists (select 1 from nomad_toon.cuts c where c.id = p_cut_id) then
      raise exception 'save_cut_doc: revision conflict' using errcode = 'TN409';
    end if;
    raise exception 'save_cut_doc: not found' using errcode = 'P0002';
  end if;
  return v_rev;
end;
$$;

-- 컷 순서 변경. 회차의 컷 id 전부를 새 순서로. invoker.
create function nomad_toon.reorder_cuts(p_episode_id uuid, p_cut_ids uuid[]) returns void
language plpgsql security invoker set search_path = ''
as $$
declare v_count integer;
begin
  select count(*) into v_count from nomad_toon.cuts c where c.episode_id = p_episode_id;
  if v_count = 0 then
    raise exception 'reorder_cuts: episode not found or empty' using errcode = 'P0002';
  end if;
  if coalesce(cardinality(p_cut_ids), 0) <> v_count
     or (select count(distinct x) from unnest(p_cut_ids) as u(x)) <> v_count
     or exists (select 1 from unnest(p_cut_ids) as u(x)
                where not exists (select 1 from nomad_toon.cuts c where c.id = u.x and c.episode_id = p_episode_id)) then
    raise exception 'reorder_cuts: id list does not match the episode cuts' using errcode = '22023';
  end if;
  update nomad_toon.cuts c
  set position = o.ord - 1
  from unnest(p_cut_ids) with ordinality as o(id, ord)
  where c.id = o.id and c.episode_id = p_episode_id;
end;
$$;

-- 에셋 사용 가능 여부(premium_assets 이용권 기준). 서명 URL 발급·렌더 워커가 같은 판정을 쓴다.
create function nomad_toon.org_asset_access(p_org_id uuid, p_asset_ids uuid[])
returns table (asset_id uuid, tier text, allowed boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare v_tiers text[];
begin
  if not nomad_core.is_service_caller() and not nomad_toon.has_access(p_org_id) then
    raise exception 'org_asset_access: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(p_org_id, 'toon', 'studio') then
    raise exception 'org_asset_access: no toon access' using errcode = '42501';
  end if;
  v_tiers := case when nomad_core.org_has_feature(p_org_id, 'toon', 'premium_assets')
                  then array['free', 'premium'] else array['free'] end;
  return query
    select a.id, a.tier, (a.status = 'published' and a.tier = any (v_tiers))
    from nomad_toon.assets a
    where a.id = any (p_asset_ids);
end;
$$;

-- 이번 달(KST) 이미지 내보내기 수(exports_per_month 판정용).
create function nomad_toon.monthly_export_count(p_org_id uuid) returns integer
language plpgsql stable security definer set search_path = ''
as $$
declare v_start timestamptz; v_count integer;
begin
  if not nomad_core.is_service_caller() and nomad_core.organization_role(p_org_id) is null then
    raise exception 'monthly_export_count: not a member' using errcode = '42501';
  end if;
  v_start := date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  select count(*) into v_count
  from nomad_toon.exports x
  where x.organization_id = p_org_id and x.kind in ('png', 'zip', 'webtoon_strip')
    and x.status in ('queued', 'running', 'succeeded') and x.created_at >= v_start;
  return v_count;
end;
$$;

-- 내 에셋 보관(소프트 삭제). editor 이상. 파일 삭제는 서버 정리 작업.
create function nomad_toon.archive_user_asset(p_user_asset_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_toon.user_assets;
begin
  select * into v_row from nomad_toon.user_assets where id = p_user_asset_id for update;
  if not found or v_row.deleted_at is not null
     or (not nomad_core.is_service_caller() and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'archive_user_asset: not found' using errcode = 'P0002';
  end if;
  if not nomad_core.is_service_caller() and not nomad_toon.can_edit(v_row.organization_id) then
    raise exception 'archive_user_asset: editor or above only' using errcode = '42501';
  end if;
  update nomad_toon.user_assets set deleted_at = now() where id = p_user_asset_id;
  perform nomad_core.write_audit(v_row.organization_id, 'toon.user_asset.archive', 'user_asset', p_user_asset_id::text);
end;
$$;

-- 협찬 승인·수정 요청 기록(owner/admin).
create function nomad_toon.decide_sponsorship(p_sponsorship_id uuid, p_decision text, p_note text default null) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_toon.sponsorships;
begin
  if p_decision is null or p_decision not in ('approved', 'changes_requested') then
    raise exception 'decide_sponsorship: decision must be approved or changes_requested' using errcode = '22023';
  end if;
  select * into v_row from nomad_toon.sponsorships where id = p_sponsorship_id for update;
  if not found or (not nomad_core.is_service_caller() and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'decide_sponsorship: not found' using errcode = 'P0002';
  end if;
  if not nomad_core.is_service_caller() and not nomad_toon.is_manager(v_row.organization_id) then
    raise exception 'decide_sponsorship: owner/admin only' using errcode = '42501';
  end if;
  if v_row.status <> 'in_review' then
    raise exception 'decide_sponsorship: sponsorship is not in review' using errcode = '22023';
  end if;
  perform set_config('nomad_toon.sponsorship_decision', 'on', true);
  update nomad_toon.sponsorships
     set status = p_decision, decided_at = now(), decided_by = auth.uid(), decision_note = left(p_note, 500)
   where id = p_sponsorship_id;
  perform set_config('nomad_toon.sponsorship_decision', 'off', true);
  perform nomad_core.write_audit(v_row.organization_id, 'toon.sponsorship.' || p_decision, 'sponsorship', p_sponsorship_id::text);
end;
$$;

-- ---------- 6. RLS 와 grant ----------
do $$
declare t text;
begin
  foreach t in array array['asset_packs', 'characters', 'assets', 'series', 'series_characters', 'episodes', 'cuts',
                           'sponsorships', 'generations', 'user_assets', 'exports'] loop
    execute format('alter table nomad_toon.%I enable row level security', t);
    execute format('revoke all on nomad_toon.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on nomad_toon.%I to service_role', t);
  end loop;
end $$;
revoke all on nomad_toon.catalog_assets from public, anon, authenticated;

-- 카탈로그: 공개 행만, studio 이용권 사용자만. 쓰기 정책 없음. assets 는 원본·편집 경로 컬럼 제외.
grant select on nomad_toon.asset_packs, nomad_toon.characters to authenticated;
grant select (id, pack_id, character_id, kind, code, name, tier, preview_path, mime, width, height, duration_ms,
              anchors, tags, status, sort_order, created_at, updated_at) on nomad_toon.assets to authenticated;
grant select on nomad_toon.catalog_assets to authenticated, service_role;
create policy asset_packs_select on nomad_toon.asset_packs for select to authenticated
  using (status = 'published' and nomad_toon.has_toon_access());
create policy characters_select on nomad_toon.characters for select to authenticated
  using (status = 'published' and nomad_toon.has_toon_access());
create policy assets_select on nomad_toon.assets for select to authenticated
  using (status = 'published' and nomad_toon.has_toon_access());

-- 콘텐츠: 읽기 멤버 + studio, 쓰기 editor 이상(with check), 삭제 owner/admin.
do $$
declare t text;
begin
  foreach t in array array['series', 'series_characters', 'episodes', 'cuts', 'sponsorships'] loop
    execute format('grant select, insert, update, delete on nomad_toon.%I to authenticated', t);
    execute format('create policy %1$s_select on nomad_toon.%1$I for select to authenticated using (nomad_toon.has_access(organization_id))', t);
    execute format('create policy %1$s_insert on nomad_toon.%1$I for insert to authenticated with check (nomad_toon.can_edit(organization_id))', t);
    execute format('create policy %1$s_update on nomad_toon.%1$I for update to authenticated using (nomad_toon.can_edit(organization_id)) with check (nomad_toon.can_edit(organization_id))', t);
    execute format('create policy %1$s_delete on nomad_toon.%1$I for delete to authenticated using (nomad_toon.is_manager(organization_id))', t);
  end loop;
end $$;

-- 서버 기록: 멤버 읽기만. 쓰기 grant 없음.
grant select on nomad_toon.generations, nomad_toon.user_assets, nomad_toon.exports to authenticated;
create policy generations_select on nomad_toon.generations for select to authenticated
  using (nomad_toon.has_access(organization_id));
create policy user_assets_select on nomad_toon.user_assets for select to authenticated
  using (deleted_at is null and nomad_toon.has_access(organization_id));
create policy exports_select on nomad_toon.exports for select to authenticated
  using (nomad_toon.has_access(organization_id));

-- ---------- 7. Storage ----------
--   toon-catalog     비공개. 정책 없음 → service_role 만(서명 URL 은 서버가 발급)
--   toon-previews    공개 버킷(public URL). 플랫폼 카탈로그 256px 썸네일(assets.preview_path)만 — 조직 창작물(user_assets.preview_path·
--                    cuts.thumbnail_path)은 넣지 않고 toon-user-assets 에 둔다. storage.objects 정책 없음(D8), 쓰기 service_role
--   toon-user-assets 비공개. 멤버는 자기 조직 폴더 읽기만, 쓰기는 서버만(AI 표시 무결성)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('toon-catalog',     'toon-catalog',     false, 20971520, array['image/png', 'image/webp', 'image/svg+xml', 'audio/mpeg']),
  ('toon-previews',    'toon-previews',    true,  1048576,  array['image/webp', 'image/png']),
  ('toon-user-assets', 'toon-user-assets', false, 20971520, array['image/png', 'image/webp'])
on conflict (id) do nothing;
create policy toon_user_assets_select on storage.objects for select to authenticated
  using (bucket_id = 'toon-user-assets' and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then nomad_toon.has_access(((storage.foldername(name))[1])::uuid) else false end);

-- ---------- 8. 함수 실행 권한 ----------
revoke execute on all functions in schema nomad_toon from public, anon;
revoke execute on all functions in schema nomad_toon_private from public, anon, authenticated;
grant execute on all functions in schema nomad_toon to service_role;
grant execute on function
  nomad_toon.has_access(uuid), nomad_toon.can_edit(uuid), nomad_toon.is_manager(uuid), nomad_toon.has_toon_access(),
  nomad_toon.feature_int(jsonb, text, integer), nomad_toon.plan_features(uuid),
  nomad_toon.save_cut_doc(uuid, jsonb, integer), nomad_toon.reorder_cuts(uuid, uuid[]),
  nomad_toon.org_asset_access(uuid, uuid[]), nomad_toon.monthly_export_count(uuid),
  nomad_toon.archive_user_asset(uuid), nomad_toon.decide_sponsorship(uuid, text, text)
to authenticated;

commit;
