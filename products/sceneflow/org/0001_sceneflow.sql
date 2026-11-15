-- sceneflow 이식 · 조직형(org안). 원본: platform-docs _supabase-modular/migrations/1200_video.sql 1~13절(스키마 video, 표 36개)
-- D9: platform-docs 기준으로 새로 작성(청사진 supabase/migrations/*_sceneflow.sql 은 참고만, 같은 스키마 이름이라 함께 설치하지 않는다).
-- 원본 12·13절의 ALTER·create or replace 는 최종 모양으로 합쳤다(표 정의에 바로 반영, 같은 함수는 마지막 정의만).
-- 변환: core.organizations·org_id → nomad_core.organizations·organization_id, has_org_role(member) → organization_role(editor),
--   has_entitlement(video)/plan_features jsonb → nomad_core.org_has_feature('sceneflow', 기능) + plan_limits 키(수치 시드 없음),
--   core.jobs·credit_ledger(bigint)·ai_runs·affiliate_links·brandconnect_applications·encrypted_credentials
--   → nomad_core.jobs·credit_ledger(uuid)·ai_runs·affiliate_links·brandconnect_applications·provider_credentials.
--   조직 일치는 복합 FK(id, organization_id), 복합 키가 없는 core 표(credit_ledger·brandconnect_applications)는 제품 표 트리거로 확인.
--   core.guard_privileged_write 는 없앴다(사용자 쓰기 grant 가 없는 표는 RPC·service_role 만 쓴다). core 표에는 트리거·직접 쓰기 없음.
-- 플랜: A = 원본 advanced, B = 원본 pro(basic 기능 포함), C = 원본 starter(무료). 구독이 끊기면 C(무료 기능만) — 유료 기능의
--   신규 생성뿐 아니라 기존 행의 수정·게시·업로드·렌더 경로도 잠근다(공개 랜딩은 not_found). 대응표: products/sceneflow/existing.md
-- 렌더 1건 = 컷 스냅샷 + 크레딧 선차감 + nomad_core.jobs (start_cut_render · finish_cut_render · fail_cut_render, 이식에서 추가).
-- 되돌림: drop schema nomad_sceneflow cascade; drop schema nomad_sceneflow_private cascade;
--   drop policy sceneflow_media_select on storage.objects; delete from storage.buckets where id = 'sceneflow-media';
begin;

create schema nomad_sceneflow;
create schema nomad_sceneflow_private;
revoke all on schema nomad_sceneflow, nomad_sceneflow_private from public, anon, authenticated;
-- anon usage: 공개 읽기 RPC(get_public_landing·get_public_linkinbio)가 있어서만 준다. 표 grant 는 없다.
grant usage on schema nomad_sceneflow to anon, authenticated, service_role;
alter default privileges in schema nomad_sceneflow revoke execute on functions from public;
alter default privileges in schema nomad_sceneflow_private revoke execute on functions from public;

insert into nomad_core.products (code, name) values ('sceneflow', 'SceneFlow') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values ('sceneflow', 'A', 'A'), ('sceneflow', 'B', 'B'), ('sceneflow', 'C', 'C')
  on conflict do nothing;
-- 원본 plans.features 불리언·배열 키 → 기능 이용권. watermark(true=워터마크)는 반대 의미 no_watermark.
insert into nomad_core.features (product_code, code, name) values
  ('sceneflow', 'studio',          'SceneFlow 작업 공간(원본 has_entitlement video)'),
  ('sceneflow', 'track_a',         'Track A 쇼츠'),
  ('sceneflow', 'track_b',         'Track B 커머스 쇼츠'),
  ('sceneflow', 'track_c',         'Track C(신규 생성 중단, 기존 행 호환)'),
  ('sceneflow', 'track_d',         'Track D 롱폼(Track S 로 대체)'),
  ('sceneflow', 'track_e',         'Track E 단일 곡'),
  ('sceneflow', 'track_f',         'Track F 플레이리스트'),
  ('sceneflow', 'lang_multi',      '일본어·영어 언어판'),
  ('sceneflow', 'no_watermark',    '워터마크 없음'),
  ('sceneflow', 'multi_platform',  'YouTube 외 플랫폼(Instagram·TikTok·Threads·네이버 클립)'),
  ('sceneflow', 'brandconnect',    '브랜드커넥트 클립 캠페인(core 지원서 잠금 키)'),
  ('sceneflow', 'radar',           '트렌드 레이더(플레이보드·채널파인더·블링)'),
  ('sceneflow', 'compliance',      '업로드 전 컴플라이언스 검사'),
  ('sceneflow', 'silence_cut',     '무음 컷'),
  ('sceneflow', 'layer_composite', '레이어 합성'),
  ('sceneflow', 'coupang_landing', '공개 랜딩 페이지'),
  ('sceneflow', 'suno',            'Suno 음원 생성'),
  ('sceneflow', 'osmu',            'OSMU 하이라이트'),
  ('sceneflow', 'priority_render', '우선 렌더'),
  ('sceneflow', 'react_flow_full', '워크플로 캔버스 전체'),
  ('sceneflow', 'api_access',      'API 접근'),
  ('sceneflow', 'agency',          '대행 운영(고객·승인·리포트)'),
  ('sceneflow', 'ai_chat',         'AI 채팅'),
  ('sceneflow', 'voice_chat',      '음성 대화'),
  ('sceneflow', 'ai_script',       'AI 대본'),
  ('sceneflow', 'storyboard',      'Track S 스토리보드'),
  ('sceneflow', 'ai_edit',         'AI 자동편집'),
  ('sceneflow', 'nle_export',      'NLE 내보내기'),
  ('sceneflow', 'render_4k60',     '4K 60fps 렌더')
on conflict do nothing;
-- C = 원본 starter(무료) 기능만 → 구독이 끊기면 이 기능만 남는다.
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'sceneflow', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['studio', 'track_a', 'ai_chat', 'voice_chat']) f
union all
select 'sceneflow', p, f from unnest(array['A', 'B']) p,
  unnest(array['track_b', 'track_c', 'track_d', 'track_e', 'track_f', 'lang_multi', 'no_watermark', 'multi_platform', 'brandconnect',
               'radar', 'compliance', 'silence_cut', 'layer_composite', 'coupang_landing', 'suno', 'osmu', 'priority_render',
               'ai_script', 'storyboard', 'ai_edit', 'nle_export']) f
union all
select 'sceneflow', 'A', f from unnest(array['react_flow_full', 'api_access', 'agency', 'render_4k60']) f
on conflict do nothing;
-- plan_limits 키(시드 없음, 괄호 = 키가 없을 때 원본 코드 기본값): max_channels(0) · storyboard_max_minutes(0) · shorts_extract_max(0)
--   · render_max_resolution(1080, 짧은 변 px) · render_max_fps(30) · aspect_variants_max(0) · edit_presets_max(0)
--   · 앱 몫: bling_monthly_limit · team_members · ai_chat_turns_per_day · credit_discount_pct. 무제한 = 2147483647.

-- ---------- 1. 도우미 ----------
-- 정책·RPC 판정(authenticated 실행, 불리언만)
create function nomad_sceneflow.has_access(p_org uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select nomad_core.organization_role(p_org) is not null and nomad_core.org_has_feature(p_org, 'sceneflow', 'studio') $$;

-- 쓰기 판정: 역할(기본 owner/admin/editor, p_admin = owner/admin) + studio + (기능). 원본 member → editor.
create function nomad_sceneflow.can_write(p_org uuid, p_admin boolean default false, p_feature text default null) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(p_org), '')
           = any (case when p_admin then array['owner', 'admin'] else array['owner', 'admin', 'editor'] end)
     and nomad_core.org_has_feature(p_org, 'sceneflow', 'studio')
     and (p_feature is null or nomad_core.org_has_feature(p_org, 'sceneflow', p_feature))
$$;

-- 기능 판정(멤버 또는 서버만, 남의 조직 플랜은 false)
create function nomad_sceneflow.has_feature(p_org uuid, p_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select (nomad_core.is_service_caller() or nomad_core.organization_role(p_org) is not null)
     and nomad_core.org_has_feature(p_org, 'sceneflow', 'studio')
     and nomad_core.org_has_feature(p_org, 'sceneflow', p_feature)
$$;

-- 공용 카탈로그(trend_videos·storyboard_templates) 읽기: 그 기능이 있는 조직의 멤버
create function nomad_sceneflow.caller_has_feature(p_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_core.memberships m
                 where m.user_id = (select auth.uid()) and nomad_sceneflow.has_feature(m.organization_id, p_feature))
$$;

-- 경로 첫 폴더의 조직 id(Storage 정책용)
create function nomad_sceneflow.storage_org_id(p_path text) returns uuid
language sql immutable set search_path = ''
as $$
  select case when split_part(p_path, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(p_path, '/', 1)::uuid end
$$;

-- CHECK 헬퍼(사용자가 직접 쓰는 표의 CHECK 가 부르므로 authenticated 실행)
create function nomad_sceneflow.storyboard_aspect_allowed(p_format text, p_aspect text) returns boolean
language sql immutable set search_path = ''
as $$
  select case p_format when 'shorts' then p_aspect in ('9:16', '1:1', '4:5')
                       when 'longform' then p_aspect in ('16:9', '9:16', '1:1') else false end
$$;

create function nomad_sceneflow.valid_preset_settings(p jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select p is not null and jsonb_typeof(p) = 'object' and pg_column_size(p) <= 4096
     and not exists (select 1 from jsonb_object_keys(p) as k(key)
                     where k.key not in ('pacing', 'caption_style', 'caption_hanja', 'transition', 'transition_ms', 'auto_motion',
                                         'bgm_level_db', 'loudnorm', 'extra_fillers', 'filler_strength', 'min_silence_ms',
                                         'pad_ms', 'aspect', 'resolution', 'fps'))
$$;

-- 비노출: 서버·트리거 판정(멤버십 무관)
create function nomad_sceneflow_private.feat(p_org uuid, p_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_core.org_has_feature(p_org, 'sceneflow', 'studio') and nomad_core.org_has_feature(p_org, 'sceneflow', p_feature)
$$;

create function nomad_sceneflow_private.limit_int(p_org uuid, p_key text, p_default integer) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_plan_limit(p_org, 'sceneflow', p_key), p_default) $$;

-- DEFINER RPC 안에서 호출자 역할 확인. 서버는 통과, 사용자는 역할 + studio(+기능).
create function nomad_sceneflow_private.require_role(p_org uuid, p_admin boolean, p_ctx text, p_feature text default null) returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_core.is_service_caller() then
    if p_feature is not null and not nomad_sceneflow_private.feat(p_org, p_feature) then
      raise exception '%: plan does not include %', p_ctx, p_feature using errcode = 'VD009';
    end if;
    return;
  end if;
  if not nomad_sceneflow.can_write(p_org, p_admin) then
    raise exception '%: % only', p_ctx, case when p_admin then 'owner/admin' else 'owner/admin/editor' end using errcode = '42501';
  end if;
  if p_feature is not null and not nomad_sceneflow_private.feat(p_org, p_feature) then
    raise exception '%: plan does not include %', p_ctx, p_feature using errcode = 'VD009';
  end if;
end;
$$;

create function nomad_sceneflow_private.scene_count_limits(p_format text, p_target_seconds integer, out min_scenes integer, out max_scenes integer)
language sql immutable set search_path = ''
as $$
  select case when p_format = 'shorts' then 3 else ceil(p_target_seconds / 60.0 * 3)::integer end,
         case when p_format = 'shorts' then 12 else least(240, floor(p_target_seconds / 60.0 * 8)::integer) end
$$;

create function nomad_sceneflow_private.valid_scene_sources(p jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select case when p is null or jsonb_typeof(p) <> 'array' then false
              when jsonb_array_length(p) > 5 then false
              else not exists (
                select 1 from jsonb_array_elements(p) as e(item)
                where case when jsonb_typeof(e.item) <> 'object' then true
                           else jsonb_typeof(e.item -> 'title') is distinct from 'string'
                             or char_length(btrim(e.item ->> 'title')) not between 1 and 200
                             or (coalesce(jsonb_typeof(e.item -> 'url'), 'null') <> 'null'
                                 and (jsonb_typeof(e.item -> 'url') <> 'string' or (e.item ->> 'url') !~* '^https?://'
                                      or char_length(e.item ->> 'url') > 2000))
                             or (coalesce(jsonb_typeof(e.item -> 'note'), 'null') <> 'null'
                                 and (jsonb_typeof(e.item -> 'note') <> 'string' or char_length(e.item ->> 'note') > 300))
                             or exists (select 1 from jsonb_object_keys(e.item) as k(key) where k.key not in ('title', 'url', 'note'))
                      end)
         end
$$;

create function nomad_sceneflow_private.render_dimensions(p_aspect text, p_resolution text, out width integer, out height integer)
language sql immutable set search_path = ''
as $$
  with r as (select case p_resolution when '720p' then 720 when '1080p' then 1080 when '1440p' then 1440 when '2160p' then 2160 end as s)
  select case p_aspect when '16:9' then s * 16 / 9 else s end,
         case p_aspect when '9:16' then s * 16 / 9 when '4:5' then s * 5 / 4 else s end
  from r
$$;

create function nomad_sceneflow_private.valid_edit_commands(p jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select case when p is null or jsonb_typeof(p) <> 'array' then false
              when jsonb_array_length(p) > 100 then false
              else not exists (
                select 1 from jsonb_array_elements(p) as e(c)
                where jsonb_typeof(e.c) <> 'object'
                   or jsonb_typeof(e.c -> 'id') <> 'number'
                   or coalesce(e.c ->> 'op', '') not in ('set_duration', 'move_scene', 'delete_scene', 'add_scene', 'set_text',
                        'set_motion', 'set_transition', 'set_focus', 'set_music_cue', 'set_caption_emphasis', 'set_clip_trim',
                        'remove_ranges', 'set_shorts_candidate', 'propose_short', 'set_render', 'set_style', 'regenerate')
                   or coalesce(jsonb_typeof(e.c -> 'args'), 'object') <> 'object'
                   or (e.c ->> 'op' not in ('add_scene', 'propose_short', 'set_render', 'set_style')
                       and coalesce(e.c ->> 'scene_id', '') !~ '^[0-9a-f-]{36}$')
                   or exists (select 1 from jsonb_object_keys(e.c) as k(key) where k.key not in ('id', 'op', 'scene_id', 'args')))
              and (select count(distinct e.c ->> 'id') = count(*) from jsonb_array_elements(p) as e(c))
         end
$$;

create function nomad_sceneflow_private.valid_cut_ranges(p jsonb) returns boolean
language sql immutable set search_path = ''
as $$
  select case when p is null or jsonb_typeof(p) <> 'array' then false
              when jsonb_array_length(p) > 500 then false
              when exists (select 1 from jsonb_array_elements(p) as e(r)
                           where jsonb_typeof(e.r) <> 'object'
                              or jsonb_typeof(e.r -> 'start_ms') <> 'number' or jsonb_typeof(e.r -> 'end_ms') <> 'number'
                              or (e.r ->> 'start_ms')::numeric < 0
                              or (e.r ->> 'end_ms')::numeric <= (e.r ->> 'start_ms')::numeric
                              or coalesce(e.r ->> 'reason', '') not in ('silence', 'filler', 'retake', 'user')) then false
              else not exists (
                select 1 from (
                  select (r ->> 'start_ms')::numeric s, lag((r ->> 'end_ms')::numeric) over (order by (r ->> 'start_ms')::numeric) prev_end
                  from jsonb_array_elements(p) as e(r)) x
                where x.prev_end is not null and x.s < x.prev_end)
         end
$$;

create function nomad_sceneflow_private.valid_caption_emphasis(p_kind text, p_narration text, p_words text[]) returns boolean
language sql immutable set search_path = ''
as $$
  select coalesce(cardinality(p_words), 0) <= 10
     and not exists (select 1 from unnest(coalesce(p_words, '{}'::text[])) as w(x)
                     where char_length(btrim(w.x)) not between 1 and 30
                        or (p_kind <> 'clip' and position(w.x in coalesce(p_narration, '')) = 0))
$$;

-- 네이버 클립 자동 업로드 위험 고지문 현재 버전(바꾸면 기존 동의 무효)
create function nomad_sceneflow_private.clip_notice_version() returns text
language sql immutable set search_path = ''
as $$ select 'clip-2026-10-v1'::text $$;

-- ---------- 2. 표 (원본 3절 + 12·13절 변경 반영) ----------
-- 2.1 channels: 연결된 플랫폼 채널. 토큰은 nomad_core.provider_credentials(vault)에만(credential_id).
create table nomad_sceneflow.channels (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  platform            text not null constraint channels_platform_check check (platform in ('youtube', 'instagram', 'tiktok', 'threads', 'naver_clip')),
  credential_id       uuid,
  external_channel_id text not null,
  name                text,
  handle              text,
  role                text not null default 'main'
                      constraint channels_role_check check (role in ('main', 'commerce', 'trend', 'longform', 'lofi', 'playlist', 'insurance')),
  target_language     text not null default 'KO' constraint channels_target_language_check check (target_language in ('KO', 'JA', 'EN')),
  target_country      text not null default 'KR' constraint channels_target_country_check check (target_country in ('KR', 'JP', 'US')),
  daily_quota_units   integer not null default 10000 constraint channels_daily_quota_check check (daily_quota_units >= 0),
  quota_used_today    integer not null default 0 constraint channels_quota_used_check check (quota_used_today >= 0),
  quota_reset_at      timestamptz,
  status              text not null default 'active' constraint channels_status_check check (status in ('active', 'paused', 'error', 'revoked')),
  last_error          text,
  automation_consent_version text,
  automation_consented_at    timestamptz,
  automation_consented_by    uuid,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, platform, external_channel_id),
  unique (id, organization_id),
  constraint channels_automation_consent_check check ((automation_consent_version is null) = (automation_consented_at is null)),
  constraint channels_credential_fk foreign key (credential_id, organization_id)
    references nomad_core.provider_credentials (id, organization_id) on delete set null (credential_id)
);
create index channels_pick_idx on nomad_sceneflow.channels (organization_id, platform, target_language, role) where status = 'active';
comment on table nomad_sceneflow.channels is '플랫폼 채널. 쓰기 서버(연결)·RPC(설정·해제·위험 동의). 키는 provider_credentials 에만.';

-- 2.2 trend_videos: 수집 트렌드(플랫폼 공용, 조직 없음). growth_rate null = 미산출(난수 지표 금지).
create table nomad_sceneflow.trend_videos (
  id                  bigint generated always as identity primary key,
  source              text not null constraint trend_videos_source_check check (source in ('playboard', 'serpapi', 'tiktok', 'google_trends', 'youtube_api')),
  country             text not null constraint trend_videos_country_check check (country in ('KR', 'US', 'JP')),
  category            text,
  period              text not null constraint trend_videos_period_check check (period in ('realtime', 'daily', 'weekly')),
  rank                integer,
  external_video_id   text not null,
  title               text,
  channel_external_id text,
  views               bigint,
  views_24h           bigint,
  growth_rate         numeric,
  weighted_score      numeric,
  is_estimated        boolean not null default false,
  collected_at        timestamptz not null default now(),
  unique (source, country, period, external_video_id, collected_at)
);
create index trend_videos_lookup_idx on nomad_sceneflow.trend_videos (country, period, collected_at desc, weighted_score desc);
comment on table nomad_sceneflow.trend_videos is '트렌드 수집(공용). 쓰기 서버, 읽기는 radar 기능이 있는 조직 멤버.';

-- 2.3 radar_reports: 채널파인더·블링·주제 점수(블링은 근거 출처 1개 이상)
create table nomad_sceneflow.radar_reports (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  kind             text not null constraint radar_reports_kind_check check (kind in ('channel_finder', 'bling', 'topic_score')),
  params           jsonb not null default '{}'::jsonb,
  result           jsonb not null default '{}'::jsonb,
  citations        jsonb not null default '[]'::jsonb,
  trend_score      integer constraint radar_reports_score_check check (trend_score between 0 and 100),
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  constraint radar_reports_citations_check check (jsonb_typeof(citations) = 'array' and (kind <> 'bling' or jsonb_array_length(citations) >= 1))
);
create index radar_reports_org_idx on nomad_sceneflow.radar_reports (organization_id, kind, created_at desc);
comment on table nomad_sceneflow.radar_reports is '레이더 결과(조직별). 쓰기 서버.';

-- 2.4 sources: 소싱 원본. 원본 파일은 ready 후 purge_after 에 지운다.
create table nomad_sceneflow.sources (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  track             text not null constraint sources_track_check check (track in ('A', 'B', 'C')),
  platform          text not null constraint sources_platform_check check (platform in ('douyin', 'xiaohongshu', 'youtube', 'tiktok')),
  source_url        text not null constraint sources_url_check check (source_url ~* '^https://'),
  external_video_id text,
  title_original    text,
  thumbnail_url     text,
  likes_count       integer,
  duration_sec      numeric,
  rights_basis      text not null constraint sources_rights_check check (rights_basis in ('public_free', 'creative_commons', 'licensed', 'own')),
  rights_note       text,
  phash             text,
  storage_path      text,
  status            text not null default 'requested' constraint sources_status_check check (status in ('requested', 'downloading', 'ready', 'failed', 'purged')),
  trend_video_id    bigint references nomad_sceneflow.trend_videos(id) on delete set null,
  job_id            uuid,
  downloaded_at     timestamptz,
  purge_after       timestamptz,
  purged_at         timestamptz,
  last_error        text,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, organization_id),
  constraint sources_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
comment on constraint sources_track_check on nomad_sceneflow.sources is 'C 는 신규 생성 금지(기존 행 호환, 원본 SF-1 제안)';
create unique index sources_dedup_uniq on nomad_sceneflow.sources (organization_id, platform, external_video_id) where external_video_id is not null;
create index sources_phash_idx on nomad_sceneflow.sources (organization_id, phash) where phash is not null;
create index sources_purge_idx on nomad_sceneflow.sources (purge_after) where status = 'ready';
comment on table nomad_sceneflow.sources is '소싱 원본. 쓰기 서버.';

-- 2.5 clients: 대행 고객사(agency 기능). productions·storyboards 가 참조하므로 먼저 만든다.
create table nomad_sceneflow.clients (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  name             text not null constraint clients_name_check check (length(btrim(name)) between 1 and 120),
  brand_name       text,
  business_no      text,
  contact_name     text,
  contact_email    text,
  contact_phone    text,
  brand_guide_path text,
  brand_wiki_ref   text,
  package_code     text constraint clients_package_check check (package_code in ('produce', 'produce_upload', 'full_ops')),
  contract_start   date,
  contract_end     date,
  monthly_quota    integer constraint clients_quota_check check (monthly_quota is null or monthly_quota >= 0),
  review_required  boolean not null default true,
  report_day       integer not null default 5 constraint clients_report_day_check check (report_day between 1 and 28),
  status           text not null default 'active' constraint clients_status_check check (status in ('active', 'paused', 'ended')),
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  unique (organization_id, name),
  unique (id, organization_id),
  constraint clients_contract_check check (contract_end is null or contract_start is null or contract_end >= contract_start),
  constraint clients_brand_guide_path_check check (brand_guide_path is null or (
    split_part(brand_guide_path, '/', 1) = organization_id::text
    and brand_guide_path ~ '^[0-9a-f-]{36}/sceneflow/clients/[0-9a-f-]{36}\.[a-z0-9]{1,8}$'))
);
create index clients_org_idx on nomad_sceneflow.clients (organization_id, status);
create index clients_sync_idx on nomad_sceneflow.clients (organization_id, updated_at);
comment on table nomad_sceneflow.clients is '대행 고객(agency). 쓰기 owner/admin(컬럼 grant), 상태는 set_client_status. 소프트 삭제 deleted_at.';

-- 2.6 productions: 숏폼 생산 요청 1건(Track A/B/C). request_id 멱등.
create table nomad_sceneflow.productions (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  track            text not null constraint productions_track_check check (track in ('A', 'B', 'C')),
  mode             text constraint productions_mode_check check (mode in ('ai_generate', 're_edit')),
  source_id        uuid,
  client_id        uuid,
  topic            text,
  topic_score      integer constraint productions_topic_score_check check (topic_score between 0 and 100),
  languages        text[] not null default array['KO']::text[],
  options          jsonb not null default '{}'::jsonb,
  watermark        boolean not null default false,
  status           text not null default 'queued' constraint productions_status_check check (status in ('queued', 'processing', 'partial', 'ready', 'failed', 'canceled')),
  root_job_id      uuid,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  credits_charged  integer not null default 0 constraint productions_credits_check check (credits_charged >= 0),
  credits_refunded integer not null default 0 constraint productions_refund_check check (credits_refunded >= 0 and credits_refunded <= credits_charged),
  request_id       uuid not null unique,
  last_error       text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  unique (id, organization_id),
  constraint productions_mode_track_check check ((track = 'C') = (mode is not null)),
  constraint productions_languages_check check (cardinality(languages) between 1 and 3 and languages <@ array['KO', 'JA', 'EN']::text[]),
  constraint productions_source_fk foreign key (source_id, organization_id) references nomad_sceneflow.sources (id, organization_id) on delete set null (source_id),
  constraint productions_client_fk foreign key (client_id, organization_id) references nomad_sceneflow.clients (id, organization_id) on delete set null (client_id),
  constraint productions_job_fk foreign key (root_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (root_job_id)
);
comment on constraint productions_track_check on nomad_sceneflow.productions is 'C 는 신규 생성 금지(기존 행 호환, 원본 SF-1 제안). Track S 는 storyboards';
create index productions_org_idx on nomad_sceneflow.productions (organization_id, created_at desc);
create index productions_status_idx on nomad_sceneflow.productions (organization_id, status);
create index productions_client_idx on nomad_sceneflow.productions (client_id) where client_id is not null;
comment on table nomad_sceneflow.productions is '숏폼 생산 요청. 쓰기 서버(크레딧은 서버가 nomad_core 로 차감).';

-- 2.7 longform_projects / sections / highlights: Track D(Track S 로 대체, 신규 생성 안 함, 원본 D-34 삭제 예정)
create table nomad_sceneflow.longform_projects (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  title            text not null constraint longform_title_check check (length(btrim(title)) between 1 and 200),
  category         text not null default 'knowledge' constraint longform_category_check check (category in ('knowledge', 'radio', 'viral_remake')),
  topic            text,
  topic_score      integer constraint longform_topic_score_check check (topic_score between 0 and 100),
  languages        text[] not null default array['KO']::text[],
  storyline        text,
  target_minutes   integer not null default 10 constraint longform_minutes_check check (target_minutes between 3 and 60),
  status           text not null default 'draft'
                   constraint longform_status_check check (status in ('draft', 'storyboard', 'generating', 'review', 'encoding', 'ready', 'failed', 'canceled')),
  root_job_id      uuid,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  last_error       text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, organization_id),
  constraint longform_languages_check check (cardinality(languages) between 1 and 3 and languages <@ array['KO', 'JA', 'EN']::text[]),
  constraint longform_job_fk foreign key (root_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (root_job_id)
);
create index longform_projects_org_idx on nomad_sceneflow.longform_projects (organization_id, created_at desc);
comment on table nomad_sceneflow.longform_projects is 'Track D 롱폼(Track S 로 대체). 콘텐츠 컬럼만 사용자 편집(track_d 필요).';

create table nomad_sceneflow.longform_sections (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  longform_id      uuid not null,
  position         integer not null constraint longform_sections_position_check check (position between 1 and 10),
  heading          text,
  script           jsonb not null default '{}'::jsonb,
  image_prompt     text,
  image_path       text,
  clip_path        text,
  narration_paths  jsonb not null default '{}'::jsonb,
  duration_sec     numeric,
  status           text not null default 'draft' constraint longform_sections_status_check check (status in ('draft', 'image_pending', 'image_ready', 'failed')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (longform_id, position),
  foreign key (longform_id, organization_id) references nomad_sceneflow.longform_projects (id, organization_id) on delete cascade
);
comment on table nomad_sceneflow.longform_sections is 'Track D 섹션(Track S scenes 로 대체).';

create table nomad_sceneflow.longform_highlights (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  longform_id     uuid not null,
  rank            integer not null constraint longform_highlights_rank_check check (rank between 1 and 3),
  start_sec       numeric not null constraint longform_highlights_start_check check (start_sec >= 0),
  end_sec         numeric not null,
  reason          text,
  status          text not null default 'proposed' constraint longform_highlights_status_check check (status in ('proposed', 'rendering', 'ready', 'failed')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (longform_id, rank),
  unique (id, organization_id),
  constraint longform_highlights_range_check check (end_sec > start_sec and end_sec - start_sec <= 60),
  foreign key (longform_id, organization_id) references nomad_sceneflow.longform_projects (id, organization_id) on delete cascade
);
comment on table nomad_sceneflow.longform_highlights is 'Track D OSMU(Track S 쇼츠 컷으로 대체). 쓰기 서버.';

-- 2.8 music_tracks (Track E) / music_library · playlists · playlist_items (Track F)
create table nomad_sceneflow.music_tracks (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  title               text not null constraint music_tracks_title_check check (length(btrim(title)) between 1 and 200),
  genre               text not null constraint music_tracks_genre_check check (genre in ('lofi', 'chill', 'ambient', 'white_noise')),
  prompt              text,
  mood                text,
  bpm                 integer constraint music_tracks_bpm_check check (bpm between 40 and 200),
  rights_basis        text not null default 'suno_generated' constraint music_tracks_rights_check check (rights_basis in ('suno_generated')),
  provider_task_id    text,
  audio_path          text,
  cover_path          text,
  duration_sec        numeric,
  status              text not null default 'requested' constraint music_tracks_status_check check (status in ('requested', 'generating', 'ready', 'failed', 'archived')),
  distribution_status text not null default 'none'
                      constraint music_tracks_distribution_check check (distribution_status in ('none', 'packaged', 'submitted', 'live', 'rejected', 'takedown')),
  distribution_note   text,
  isrc                text constraint music_tracks_isrc_check check (isrc is null or isrc ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'),
  package_path        text,
  distributed_at      timestamptz,
  job_id              uuid,
  credit_ledger_id    uuid references nomad_core.credit_ledger(id),
  request_id          uuid unique,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, organization_id),
  constraint music_tracks_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create index music_tracks_org_idx on nomad_sceneflow.music_tracks (organization_id, created_at desc);
comment on table nomad_sceneflow.music_tracks is 'Track E 단일 곡(Suno). 쓰기 서버, 제목만 사용자(track_e), 유통 상태는 RPC.';

create table nomad_sceneflow.music_library (
  id                           uuid primary key default gen_random_uuid(),
  organization_id              uuid not null references nomad_core.organizations(id) on delete cascade,
  title                        text not null,
  artist                       text,
  license_type                 text not null constraint music_library_license_check check (license_type in ('purchased', 'royalty_free', 'commissioned', 'cc_by')),
  license_source               text,
  license_proof_path           text not null,
  license_expires_at           timestamptz,
  youtube_monetization_allowed boolean not null,
  attribution_text             text,
  audio_path                   text not null,
  duration_sec                 numeric constraint music_library_duration_check check (duration_sec > 0),
  status                       text not null default 'active' constraint music_library_status_check check (status in ('active', 'expired', 'revoked')),
  created_by                   uuid default auth.uid(),
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now(),
  deleted_at                   timestamptz,
  unique (id, organization_id),
  constraint music_library_attribution_check check (license_type <> 'cc_by' or attribution_text is not null),
  -- 사용자가 쓰는 경로도 scene_assets 처럼 첫 폴더 = 자기 조직(남의 조직 파일을 가리키지 못하게)
  constraint music_library_license_proof_path_check check (
    split_part(license_proof_path, '/', 1) = organization_id::text
    and license_proof_path ~ '^[0-9a-f-]{36}/sceneflow/music_library/[0-9a-f-]{36}\.[a-z0-9]{1,8}$'),
  constraint music_library_audio_path_check check (
    split_part(audio_path, '/', 1) = organization_id::text
    and audio_path ~ '^[0-9a-f-]{36}/sceneflow/music_library/[0-9a-f-]{36}\.[a-z0-9]{1,8}$')
);
create index music_library_org_idx on nomad_sceneflow.music_library (organization_id, status);
create index music_library_sync_idx on nomad_sceneflow.music_library (organization_id, updated_at);
comment on table nomad_sceneflow.music_library is 'Track F 라이선스 곡(증빙 필수). 사용자 쓰기(track_f). 소프트 삭제 deleted_at.';

create table nomad_sceneflow.playlists (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  title                text not null constraint playlists_title_check check (length(btrim(title)) between 1 and 200),
  mood                 text not null constraint playlists_mood_check check (mood in ('cafe', 'drive', 'study', 'sleep', 'work', 'rain', 'healing', 'workout', 'other')),
  target_duration_min  integer not null constraint playlists_duration_check check (target_duration_min in (30, 60, 180)),
  language             text not null default 'KO' constraint playlists_language_check check (language in ('KO', 'JA', 'EN')),
  visual_style         text,
  cover_prompt         text,
  description_body     text,
  pinned_comment_body  text,
  tracklist            jsonb not null default '[]'::jsonb,
  thumbnail_path       text,
  status               text not null default 'draft' constraint playlists_status_check check (status in ('draft', 'rendering', 'ready', 'failed', 'canceled')),
  root_job_id          uuid,
  credit_ledger_id     uuid references nomad_core.credit_ledger(id),
  last_error           text,
  created_by           uuid default auth.uid(),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  unique (id, organization_id),
  constraint playlists_job_fk foreign key (root_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (root_job_id)
);
create index playlists_org_idx on nomad_sceneflow.playlists (organization_id, created_at desc);
create index playlists_sync_idx on nomad_sceneflow.playlists (organization_id, updated_at);
comment on table nomad_sceneflow.playlists is 'Track F 플레이리스트. 사용자 쓰기(track_f, draft 만 편집). 소프트 삭제 deleted_at.';

create table nomad_sceneflow.playlist_items (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  playlist_id      uuid not null,
  position         integer not null constraint playlist_items_position_check check (position >= 1),
  music_track_id   uuid,
  library_track_id uuid,
  start_sec        numeric,
  duration_sec     numeric,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint playlist_items_position_uniq unique (playlist_id, position) deferrable initially deferred,
  constraint playlist_items_source_check check (num_nonnulls(music_track_id, library_track_id) = 1),
  foreign key (playlist_id, organization_id) references nomad_sceneflow.playlists (id, organization_id) on delete cascade,
  foreign key (music_track_id, organization_id) references nomad_sceneflow.music_tracks (id, organization_id),
  foreign key (library_track_id, organization_id) references nomad_sceneflow.music_library (id, organization_id)
);
create index playlist_items_sync_idx on nomad_sceneflow.playlist_items (organization_id, updated_at);
comment on table nomad_sceneflow.playlist_items is '플레이리스트 곡(Suno 곡 또는 라이선스 곡 하나). 사용자 쓰기(track_f).';

-- 2.9 landing_pages · linkinbio (공개는 RPC 만, D8)
create table nomad_sceneflow.landing_pages (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  production_id    uuid,
  slug             text not null unique constraint landing_pages_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{2,63}$'),
  product_name     text not null,
  headline         text,
  features         jsonb not null default '[]'::jsonb,
  youtube_video_id text,
  primary_link_id  uuid,
  related_link_ids uuid[] not null default '{}'::uuid[],
  status           text not null default 'draft' constraint landing_pages_status_check check (status in ('draft', 'published', 'unpublished')),
  view_count       bigint not null default 0,
  published_at     timestamptz,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, organization_id),
  constraint landing_pages_features_check check (jsonb_typeof(features) = 'array' and jsonb_array_length(features) <= 3),
  constraint landing_pages_related_check check (cardinality(related_link_ids) <= 3),
  constraint landing_pages_production_fk foreign key (production_id, organization_id)
    references nomad_sceneflow.productions (id, organization_id) on delete set null (production_id),
  constraint landing_pages_link_fk foreign key (primary_link_id, organization_id)
    references nomad_core.affiliate_links (id, organization_id) on delete set null (primary_link_id)
);
create index landing_pages_org_idx on nomad_sceneflow.landing_pages (organization_id, created_at desc);
create index landing_pages_sync_idx on nomad_sceneflow.landing_pages (organization_id, updated_at);
comment on table nomad_sceneflow.landing_pages is '공개 랜딩(coupang_landing). 생성 서버, 문구만 사용자, 공개는 set_landing_status, 방문자는 get_public_landing.';

create table nomad_sceneflow.linkinbio_profiles (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references nomad_core.organizations(id) on delete cascade,
  handle          text not null unique
                  constraint linkinbio_handle_check check (handle ~ '^[a-z0-9_]{3,30}$'
                    and handle not in ('admin', 'api', 'app', 'dashboard', 'login', 'signup', 'landing', 'lb', 'r', 'pricing', 'legal', 'support')),
  display_name    text,
  bio             text constraint linkinbio_bio_check check (bio is null or length(bio) <= 300),
  avatar_path     text,
  is_published    boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint linkinbio_avatar_path_check check (avatar_path is null or (
    split_part(avatar_path, '/', 1) = organization_id::text
    and avatar_path ~ '^[0-9a-f-]{36}/sceneflow/linkinbio/[0-9a-f-]{36}\.[a-z0-9]{1,8}$'))
);
create index linkinbio_profiles_sync_idx on nomad_sceneflow.linkinbio_profiles (organization_id, updated_at);
comment on table nomad_sceneflow.linkinbio_profiles is '링크인바이오 프로필(조직당 1). 쓰기 owner/admin, 방문자는 get_public_linkinbio.';

create table nomad_sceneflow.linkinbio_items (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  profile_id        uuid not null,
  kind              text not null constraint linkinbio_items_kind_check check (kind in ('link', 'landing', 'affiliate', 'video')),
  title             text not null constraint linkinbio_items_title_check check (length(btrim(title)) between 1 and 120),
  url               text constraint linkinbio_items_url_check check (url is null or url ~* '^https://'),
  landing_page_id   uuid,
  affiliate_link_id uuid,
  position          integer not null default 0,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint linkinbio_items_target_check check (
       (kind in ('link', 'video') and url is not null and landing_page_id is null and affiliate_link_id is null)
    or (kind = 'landing'   and landing_page_id   is not null and affiliate_link_id is null)
    or (kind = 'affiliate' and affiliate_link_id is not null and landing_page_id is null)),
  foreign key (profile_id, organization_id) references nomad_sceneflow.linkinbio_profiles (id, organization_id) on delete cascade,
  foreign key (landing_page_id, organization_id) references nomad_sceneflow.landing_pages (id, organization_id) on delete cascade,
  foreign key (affiliate_link_id, organization_id) references nomad_core.affiliate_links (id, organization_id) on delete cascade
);
create index linkinbio_items_profile_idx on nomad_sceneflow.linkinbio_items (profile_id, position);
create index linkinbio_items_sync_idx on nomad_sceneflow.linkinbio_items (organization_id, updated_at);
comment on table nomad_sceneflow.linkinbio_items is '링크인바이오 항목. 사용자 쓰기(editor 이상).';

-- 2.10 Track S: storyboard_templates · edit_presets · storyboards · scenes · scene_assets · storyboard_cuts · storyboard_snapshots
create table nomad_sceneflow.storyboard_templates (
  code                  text primary key constraint storyboard_templates_code_check check (code ~ '^[a-z][a-z0-9_]{2,39}$'),
  label                 text not null constraint storyboard_templates_label_check check (length(btrim(label)) between 1 and 60),
  beats                 jsonb not null default '[]'::jsonb,
  default_scene_seconds integer not null default 6 constraint storyboard_templates_seconds_check check (default_scene_seconds between 2 and 30),
  status                text not null default 'active' constraint storyboard_templates_status_check check (status in ('active', 'retired')),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint storyboard_templates_beats_check check (jsonb_typeof(beats) = 'array' and jsonb_array_length(beats) between 1 and 20)
);
comment on table nomad_sceneflow.storyboard_templates is '스토리보드 템플릿(공용 카탈로그, 문구 데이터). 쓰기 service_role, 읽기 storyboard 기능 조직 멤버.';

create table nomad_sceneflow.edit_presets (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  client_id       uuid,
  name            text not null constraint edit_presets_name_check check (length(btrim(name)) between 1 and 60),
  settings        jsonb not null default '{}'::jsonb constraint edit_presets_settings_check check (nomad_sceneflow.valid_preset_settings(settings)),
  is_default      boolean not null default false,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (client_id, organization_id) references nomad_sceneflow.clients (id, organization_id) on delete cascade
);
create unique index edit_presets_default_uniq on nomad_sceneflow.edit_presets (organization_id, (coalesce(client_id::text, ''))) where is_default;
create index edit_presets_org_idx on nomad_sceneflow.edit_presets (organization_id, created_at desc);
create index edit_presets_sync_idx on nomad_sceneflow.edit_presets (organization_id, updated_at);
comment on table nomad_sceneflow.edit_presets is '조직·고객별 편집 프리셋(한도 edit_presets_max). 사용자 쓰기.';

create table nomad_sceneflow.storyboards (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  client_id        uuid,
  title            text not null constraint storyboards_title_check check (length(btrim(title)) between 1 and 200),
  format           text not null constraint storyboards_format_check check (format in ('shorts', 'longform')),
  aspect           text not null constraint storyboards_aspect_check check (aspect in ('16:9', '9:16', '1:1', '4:5')),
  target_seconds   integer not null,
  template_code    text not null references nomad_sceneflow.storyboard_templates(code),
  topic            text constraint storyboards_topic_check check (topic is null or length(topic) <= 300),
  script_ai_run_id uuid,
  languages        text[] not null default array['KO']::text[],
  voice_provider   text constraint storyboards_voice_provider_check check (voice_provider in ('elevenlabs', 'oss')),
  voice_id         text constraint storyboards_voice_id_check check (voice_id is null or length(btrim(voice_id)) between 1 and 120),
  resolution       text not null default '1080p' constraint storyboards_resolution_check check (resolution in ('720p', '1080p', '1440p', '2160p')),
  fps              smallint not null default 30 constraint storyboards_fps_check check (fps in (24, 30, 60)),
  shorts_aspect    text not null default '9:16' constraint storyboards_shorts_aspect_check check (shorts_aspect in ('9:16', '1:1', '4:5')),
  caption_style    text not null default 'clean' constraint storyboards_caption_style_check check (caption_style in ('clean', 'bold_box', 'word_pop')),
  caption_hanja    boolean not null default false,
  bgm_level_db     smallint not null default -18 constraint storyboards_bgm_level_check check (bgm_level_db between -40 and 0),
  loudnorm         boolean not null default true,
  edit_preset_id   uuid,
  status           text not null default 'draft' constraint storyboards_status_check check (status in ('draft', 'ready', 'rendering', 'rendered', 'archived')),
  version          integer not null default 0 constraint storyboards_version_check check (version >= 0),
  revision         integer not null default 1 constraint storyboards_revision_check check (revision >= 1),
  root_job_id      uuid,
  last_error       text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  unique (id, organization_id),
  constraint storyboards_preset_check check (
    nomad_sceneflow.storyboard_aspect_allowed(format, aspect)
    and ((format = 'shorts' and target_seconds in (15, 30, 45, 60, 90))
         or (format = 'longform' and target_seconds in (180, 300, 600, 1200, 1800, 3600)))),
  constraint storyboards_languages_check check (cardinality(languages) between 1 and 3 and languages <@ array['KO', 'JA', 'EN']::text[]),
  constraint storyboards_voice_pair_check check ((voice_provider is null) = (voice_id is null)),
  constraint storyboards_client_fk foreign key (client_id, organization_id) references nomad_sceneflow.clients (id, organization_id) on delete set null (client_id),
  constraint storyboards_ai_run_fk foreign key (script_ai_run_id, organization_id) references nomad_core.ai_runs (id, organization_id) on delete set null (script_ai_run_id),
  constraint storyboards_job_fk foreign key (root_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (root_job_id),
  constraint storyboards_preset_fk foreign key (edit_preset_id, organization_id) references nomad_sceneflow.edit_presets (id, organization_id) on delete set null (edit_preset_id)
);
create index storyboards_org_idx on nomad_sceneflow.storyboards (organization_id, created_at desc);
create index storyboards_status_idx on nomad_sceneflow.storyboards (organization_id, status);
create index storyboards_client_idx on nomad_sceneflow.storyboards (client_id) where client_id is not null;
create index storyboards_sync_idx on nomad_sceneflow.storyboards (organization_id, updated_at);
comment on table nomad_sceneflow.storyboards is 'Track S 스토리보드(storyboard 기능). 콘텐츠·렌더 설정만 사용자, 상태·버전·revision 은 서버·RPC. 소프트 삭제 deleted_at.';

create table nomad_sceneflow.scenes (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  storyboard_id    uuid not null,
  ord              integer not null constraint scenes_ord_check check (ord between 1 and 240),
  chapter          text constraint scenes_chapter_check check (chapter is null or length(btrim(chapter)) between 1 and 80),
  kind             text not null default 'image' constraint scenes_kind_check check (kind in ('image', 'clip', 'text_card', 'title')),
  duration_ms      integer not null default 6000 constraint scenes_duration_check check (duration_ms between 1000 and 60000),
  narration        text constraint scenes_narration_check check (narration is null or char_length(narration) <= 600),
  on_screen_text   text constraint scenes_on_screen_text_check check (on_screen_text is null or char_length(on_screen_text) <= 160),
  visual_prompt    text constraint scenes_visual_prompt_check check (visual_prompt is null or char_length(visual_prompt) <= 600),
  motion_preset    text not null default 'static' constraint scenes_motion_check check (motion_preset in ('zoom_in', 'zoom_out', 'pan_left', 'pan_right', 'static')),
  music_cue        text constraint scenes_music_cue_check check (music_cue is null or music_cue in ('intro', 'build', 'drop', 'calm', 'outro')),
  shorts_candidate boolean not null default false,
  sources          jsonb not null default '[]'::jsonb constraint scenes_sources_check check (nomad_sceneflow_private.valid_scene_sources(sources)),
  source_required  boolean not null default false,
  focus_x          numeric(4, 3) not null default 0.5,
  focus_y          numeric(4, 3) not null default 0.5,
  transition       text not null default 'cut',
  transition_ms    integer not null default 0,
  clip_in_ms       integer,
  clip_out_ms      integer,
  cut_ranges       jsonb not null default '[]'::jsonb,
  caption_emphasis text[] not null default '{}'::text[],
  revision         integer not null default 1 constraint scenes_revision_check check (revision >= 1),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, organization_id),
  constraint scenes_ord_uniq unique (storyboard_id, ord) deferrable initially deferred,
  constraint scenes_focus_check check (focus_x between 0 and 1 and focus_y between 0 and 1),
  constraint scenes_transition_check check (
    transition in ('cut', 'fade', 'dissolve', 'fadeblack', 'slideleft', 'slideup', 'zoomin', 'wipeleft')
    and ((transition = 'cut' and transition_ms = 0) or (transition <> 'cut' and transition_ms between 200 and 1500))),
  constraint scenes_clip_trim_check check ((clip_in_ms is null and clip_out_ms is null) or (kind = 'clip' and clip_in_ms >= 0 and clip_out_ms > clip_in_ms)),
  constraint scenes_cut_ranges_check check (nomad_sceneflow_private.valid_cut_ranges(cut_ranges) and (kind = 'clip' or cut_ranges = '[]'::jsonb)),
  constraint scenes_caption_emphasis_check check (nomad_sceneflow_private.valid_caption_emphasis(kind, narration, caption_emphasis)),
  foreign key (storyboard_id, organization_id) references nomad_sceneflow.storyboards (id, organization_id) on delete cascade
);
create index scenes_shorts_idx on nomad_sceneflow.scenes (storyboard_id, ord) where shorts_candidate;
create index scenes_source_warn_idx on nomad_sceneflow.scenes (storyboard_id) where source_required and sources = '[]'::jsonb;
create index scenes_sync_idx on nomad_sceneflow.scenes (organization_id, updated_at);
comment on table nomad_sceneflow.scenes is '장면. 쓰기는 사용자 RPC(save_scene 등, revision 낙관적 동시성)와 서버만.';

create table nomad_sceneflow.scene_assets (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  scene_id             uuid not null,
  kind                 text not null constraint scene_assets_kind_check check (kind in ('image', 'narration', 'clip')),
  lang                 text constraint scene_assets_lang_check check (lang in ('KO', 'JA', 'EN')),
  aspect               text constraint scene_assets_aspect_check check (aspect in ('16:9', '9:16', '1:1', '4:5')),
  status               text not null default 'ready' constraint scene_assets_status_check check (status in ('ready', 'superseded')),
  storage_path         text not null,
  rights_basis         text constraint scene_assets_rights_check check (rights_basis in ('public_free', 'creative_commons', 'licensed', 'own')),
  rights_note          text constraint scene_assets_rights_note_check check (rights_note is null or char_length(rights_note) <= 500),
  ai_generated         boolean not null default true,
  reused_from_asset_id uuid,
  meta                 jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (id, organization_id),
  constraint scene_assets_lang_kind_check check ((kind = 'narration') = (lang is not null)),
  constraint scene_assets_aspect_kind_check check ((kind = 'image' and aspect is not null) or kind = 'clip' or (kind = 'narration' and aspect is null)),
  constraint scene_assets_clip_rights_check check (
    kind <> 'clip' or (rights_basis is not null and rights_note is not null and length(btrim(rights_note)) >= 2 and not ai_generated)),
  constraint scene_assets_path_check check (
    split_part(storage_path, '/', 1) = organization_id::text
    and storage_path ~ '^[0-9a-f-]{36}/sceneflow/scenes/[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|jpeg|webp|mp3|wav|m4a|mp4|webm|mov)$'),
  constraint scene_assets_meta_check check (jsonb_typeof(meta) = 'object' and pg_column_size(meta) <= 4096),
  foreign key (scene_id, organization_id) references nomad_sceneflow.scenes (id, organization_id) on delete cascade,
  foreign key (reused_from_asset_id, organization_id) references nomad_sceneflow.scene_assets (id, organization_id) on delete set null (reused_from_asset_id)
);
create unique index scene_assets_one_ready_uniq on nomad_sceneflow.scene_assets (scene_id, kind, (coalesce(lang, '')), (coalesce(aspect, ''))) where status = 'ready';
create index scene_assets_scene_idx on nomad_sceneflow.scene_assets (scene_id, created_at desc);
create index scene_assets_reuse_idx on nomad_sceneflow.scene_assets (organization_id, created_at desc) where status = 'ready' and kind = 'image';
comment on table nomad_sceneflow.scene_assets is '장면 소재(이전 소재는 superseded). 쓰기 서버(finish_scene_asset).';

create table nomad_sceneflow.storyboard_cuts (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  storyboard_id    uuid not null,
  kind             text not null constraint storyboard_cuts_kind_check check (kind in ('master', 'short', 'variant')),
  aspect           text not null constraint storyboard_cuts_aspect_check check (aspect in ('16:9', '9:16', '1:1', '4:5')),
  scene_ids        uuid[] not null constraint storyboard_cuts_scene_ids_check check (cardinality(scene_ids) between 1 and 240),
  hook_text        text constraint storyboard_cuts_hook_check check (hook_text is null or char_length(hook_text) <= 100),
  status           text not null default 'proposed' constraint storyboard_cuts_status_check check (status in ('proposed', 'rendering', 'ready', 'failed')),
  ord              integer not null default 0 constraint storyboard_cuts_ord_check check (ord between 0 and 10),
  job_id           uuid,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),   -- 이식 추가: 렌더 선차감 묶음(start_cut_render)
  credits_charged  integer not null default 0 constraint storyboard_cuts_credits_check check (credits_charged >= 0),  -- 이식 추가
  request_id       uuid unique,                                     -- 이식 추가: 마지막 렌더 요청 멱등 키
  last_error       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, organization_id),
  unique (id, storyboard_id),
  constraint storyboard_cuts_kind_shape_check check (
       (kind = 'master'  and ord = 0 and hook_text is null)
    or (kind = 'short'   and aspect in ('9:16', '1:1', '4:5') and ord between 1 and 10 and cardinality(scene_ids) <= 12)
    or (kind = 'variant' and ord between 1 and 3 and hook_text is null)),
  constraint storyboard_cuts_ord_uniq unique (storyboard_id, kind, ord),
  foreign key (storyboard_id, organization_id) references nomad_sceneflow.storyboards (id, organization_id) on delete cascade,
  constraint storyboard_cuts_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create unique index storyboard_cuts_one_master on nomad_sceneflow.storyboard_cuts (storyboard_id) where kind = 'master';
create unique index storyboard_cuts_variant_aspect_uniq on nomad_sceneflow.storyboard_cuts (storyboard_id, aspect) where kind = 'variant';
comment on table nomad_sceneflow.storyboard_cuts is '렌더 단위(master·short·variant). 쓰기 서버·RPC.';

create table nomad_sceneflow.storyboard_snapshots (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  storyboard_id   uuid not null,
  cut_id          uuid not null,
  version         integer not null constraint storyboard_snapshots_version_check check (version >= 1),
  snapshot        jsonb not null,
  created_at      timestamptz not null default now(),
  constraint storyboard_snapshots_version_uniq unique (storyboard_id, version),
  constraint storyboard_snapshots_shape_check check (jsonb_typeof(snapshot) = 'object' and pg_column_size(snapshot) <= 2097152),
  foreign key (storyboard_id, organization_id) references nomad_sceneflow.storyboards (id, organization_id) on delete cascade,
  foreign key (cut_id, storyboard_id) references nomad_sceneflow.storyboard_cuts (id, storyboard_id) on delete cascade
);
create index storyboard_snapshots_cut_idx on nomad_sceneflow.storyboard_snapshots (cut_id, version desc);
comment on table nomad_sceneflow.storyboard_snapshots is '렌더 스냅샷(읽기 전용, service 도 수정 거부).';

-- 2.11 outputs: 렌더 결과물. 소유 엔티티 정확히 1개(storyboard_cut 포함).
create table nomad_sceneflow.outputs (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references nomad_core.organizations(id) on delete cascade,
  kind              text not null constraint outputs_kind_check check (kind in ('short', 'longform', 'highlight', 'music_loop', 'playlist')),
  production_id     uuid,
  longform_id       uuid,
  highlight_id      uuid,
  music_track_id    uuid,
  playlist_id       uuid,
  storyboard_cut_id uuid,
  language          text constraint outputs_language_check check (language in ('KO', 'JA', 'EN')),
  aspect            text not null default '9:16' constraint outputs_aspect_check check (aspect in ('9:16', '16:9', '1:1', '4:5')),
  video_path        text,
  thumbnail_path    text,
  duration_sec      numeric,
  width             integer,
  height            integer,
  fps               smallint,
  title             text,
  description_body  text,
  tags              text[] not null default '{}'::text[],
  watermark         boolean not null default false,
  status            text not null default 'pending' constraint outputs_status_check check (status in ('pending', 'ready', 'failed', 'purged')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, organization_id),
  constraint outputs_owner_check check (num_nonnulls(production_id, longform_id, highlight_id, music_track_id, playlist_id, storyboard_cut_id) = 1),
  constraint outputs_kind_owner_check check (
       (kind = 'short'      and production_id  is not null)
    or (kind = 'longform'   and longform_id    is not null)
    or (kind = 'highlight'  and highlight_id   is not null)
    or (kind = 'music_loop' and music_track_id is not null)
    or (kind = 'playlist'   and playlist_id    is not null)
    or (kind in ('short', 'longform') and storyboard_cut_id is not null)),
  constraint outputs_dimensions_check check (
    ((width is null) = (height is null)) and (width is null or (width between 240 and 4096 and height between 240 and 4096))
    and (fps is null or fps in (24, 25, 30, 60))),
  foreign key (production_id, organization_id) references nomad_sceneflow.productions (id, organization_id) on delete cascade,
  foreign key (longform_id, organization_id) references nomad_sceneflow.longform_projects (id, organization_id) on delete cascade,
  foreign key (highlight_id, organization_id) references nomad_sceneflow.longform_highlights (id, organization_id) on delete cascade,
  foreign key (music_track_id, organization_id) references nomad_sceneflow.music_tracks (id, organization_id) on delete cascade,
  foreign key (playlist_id, organization_id) references nomad_sceneflow.playlists (id, organization_id) on delete cascade,
  foreign key (storyboard_cut_id, organization_id) references nomad_sceneflow.storyboard_cuts (id, organization_id) on delete cascade
);
create unique index outputs_short_lang_uniq on nomad_sceneflow.outputs (production_id, language) where production_id is not null;
create unique index outputs_storyboard_cut_lang_uniq on nomad_sceneflow.outputs (storyboard_cut_id, language) where storyboard_cut_id is not null;
create index outputs_org_idx on nomad_sceneflow.outputs (organization_id, created_at desc);
comment on table nomad_sceneflow.outputs is '렌더 결과물. 쓰기 서버(ready 는 소유 잡이 failed·canceled 면 거부 + mark_job_delivered).';

-- 2.12 uploads · upload_links · compliance_checks · analytics_snapshots
create table nomad_sceneflow.uploads (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references nomad_core.organizations(id) on delete cascade,
  output_id              uuid not null,
  channel_id             uuid not null,
  platform               text not null constraint uploads_platform_check check (platform in ('youtube', 'instagram', 'tiktok', 'threads', 'naver_clip')),
  language               text constraint uploads_language_check check (language in ('KO', 'JA', 'EN')),
  title                  text not null constraint uploads_title_check check (length(btrim(title)) between 1 and 100),
  description            text not null default '',
  pinned_comment         text,
  tags                   text[] not null default '{}'::text[],
  visibility             text not null default 'public' constraint uploads_visibility_check check (visibility in ('public', 'unlisted', 'private')),
  scheduled_at           timestamptz,
  paid_promotion         boolean not null default false,
  has_affiliate          boolean not null default false,
  disclosure_description text,
  disclosure_pinned      text,
  disclosure_title       text,
  disclosure_hashtag     text,
  brandconnect_application_id uuid,
  status                 text not null default 'draft'
                         constraint uploads_status_check check (status in ('draft', 'checking', 'blocked', 'awaiting_confirm', 'approved', 'client_review', 'scheduled', 'uploading', 'published', 'failed', 'canceled')),
  compliance_check_id    uuid,
  compliance_ack_by      uuid,
  compliance_ack_at      timestamptz,
  job_id                 uuid,
  credit_ledger_id       uuid references nomad_core.credit_ledger(id),
  platform_post_id       text,
  post_url               text,
  published_at           timestamptz,
  attempts               integer not null default 0,
  last_error             text,
  request_id             uuid unique,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (channel_id, platform_post_id),
  unique (id, organization_id),
  constraint uploads_disclosure_check check (
    not (has_affiliate or brandconnect_application_id is not null) or (
      case when platform = 'naver_clip' then
            disclosure_title is not null and length(btrim(disclosure_title)) >= 2 and starts_with(title, disclosure_title)
        and disclosure_hashtag is not null and length(btrim(disclosure_hashtag)) >= 2
        and cardinality(tags) >= 1 and tags[1] = disclosure_hashtag
        and disclosure_description is not null and length(btrim(disclosure_description)) >= 10
        and starts_with(description, disclosure_description)
      else
            disclosure_description is not null and length(btrim(disclosure_description)) >= 10
        and starts_with(description, disclosure_description)
        and disclosure_pinned is not null and length(btrim(disclosure_pinned)) >= 10
        and pinned_comment is not null and starts_with(pinned_comment, disclosure_pinned)
      end)),
  foreign key (output_id, organization_id) references nomad_sceneflow.outputs (id, organization_id),
  foreign key (channel_id, organization_id) references nomad_sceneflow.channels (id, organization_id),
  constraint uploads_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create index uploads_org_idx on nomad_sceneflow.uploads (organization_id, created_at desc);
create index uploads_due_idx on nomad_sceneflow.uploads (scheduled_at) where status = 'scheduled';
create index uploads_output_idx on nomad_sceneflow.uploads (output_id);
create index uploads_channel_idx on nomad_sceneflow.uploads (channel_id);
comment on table nomad_sceneflow.uploads is '플랫폼 게시 1건(대가성 문구 CHECK, 컴플라이언스·고객 승인 게이트). 쓰기 서버·RPC.';

create table nomad_sceneflow.upload_links (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  upload_id       uuid not null,
  link_id         uuid not null,
  placement       text not null constraint upload_links_placement_check check (placement in ('video_description', 'video_pinned_comment')),
  position        integer not null default 1,
  created_at      timestamptz not null default now(),
  unique (upload_id, link_id, placement),
  foreign key (upload_id, organization_id) references nomad_sceneflow.uploads (id, organization_id) on delete cascade,
  foreign key (link_id, organization_id) references nomad_core.affiliate_links (id, organization_id)
);
create index upload_links_link_idx on nomad_sceneflow.upload_links (link_id);
comment on table nomad_sceneflow.upload_links is '업로드에 넣은 제휴 링크(nomad_core.affiliate_links). 쓰기 서버.';

create table nomad_sceneflow.compliance_checks (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  upload_id        uuid not null,
  verdict          text not null constraint compliance_checks_verdict_check check (verdict in ('pass', 'warn', 'fail')),
  stages           text[] not null default array['rules']::text[],
  issues           jsonb not null default '[]'::jsonb,
  suggestions      jsonb not null default '[]'::jsonb,
  llm_failed       boolean not null default false,
  usage_id         bigint,
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  created_at       timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (upload_id, organization_id) references nomad_sceneflow.uploads (id, organization_id) on delete cascade
);
create index compliance_checks_upload_idx on nomad_sceneflow.compliance_checks (upload_id, created_at desc);
alter table nomad_sceneflow.uploads add constraint uploads_compliance_fk foreign key (compliance_check_id, organization_id)
  references nomad_sceneflow.compliance_checks (id, organization_id) on delete set null (compliance_check_id);
comment on table nomad_sceneflow.compliance_checks is '업로드 전 검사 결과(append-only). 쓰기 서버.';

create table nomad_sceneflow.analytics_snapshots (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  upload_id       uuid not null,
  captured_at     timestamptz not null default now(),
  views           bigint,
  likes           bigint,
  comments        bigint,
  watch_time_sec  bigint,
  unique (upload_id, captured_at),
  foreign key (upload_id, organization_id) references nomad_sceneflow.uploads (id, organization_id) on delete cascade
);
create index analytics_snapshots_org_idx on nomad_sceneflow.analytics_snapshots (organization_id, captured_at desc);
comment on table nomad_sceneflow.analytics_snapshots is '게시물 성과 수집. 쓰기 서버.';

-- 2.13 workflows · banned_words
create table nomad_sceneflow.workflows (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name            text not null constraint workflows_name_check check (length(btrim(name)) between 1 and 120),
  graph           jsonb not null default '{"nodes": [], "edges": []}'::jsonb,
  is_active       boolean not null default false,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  constraint workflows_graph_check check (jsonb_typeof(graph -> 'nodes') = 'array' and jsonb_typeof(graph -> 'edges') = 'array')
);
create index workflows_sync_idx on nomad_sceneflow.workflows (organization_id, updated_at);
comment on table nomad_sceneflow.workflows is '자동화 캔버스 저장(Phase 2). 사용자 쓰기. 소프트 삭제 deleted_at.';

create table nomad_sceneflow.banned_words (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  word            text not null constraint banned_words_word_check check (length(btrim(word)) between 1 and 60),
  severity        text not null default 'warn' constraint banned_words_severity_check check (severity in ('warn', 'fail')),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (organization_id, word)
);
comment on table nomad_sceneflow.banned_words is '컴플라이언스 금칙어 조직 추가분. 사용자 쓰기.';

-- 2.14 대행: client_channels · client_reviews · client_reports
create table nomad_sceneflow.client_channels (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  client_id       uuid not null,
  channel_id      uuid not null,
  ownership       text not null default 'client' constraint client_channels_ownership_check check (ownership in ('client', 'agency')),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (channel_id),
  foreign key (client_id, organization_id) references nomad_sceneflow.clients (id, organization_id) on delete cascade,
  foreign key (channel_id, organization_id) references nomad_sceneflow.channels (id, organization_id) on delete cascade
);
create index client_channels_client_idx on nomad_sceneflow.client_channels (client_id);
comment on table nomad_sceneflow.client_channels is '고객 ↔ 운영 채널(한 채널은 한 고객). 쓰기 owner/admin(agency).';

create table nomad_sceneflow.client_reviews (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  client_id       uuid not null,
  upload_id       uuid not null,
  token_hash      text not null unique constraint client_reviews_token_check check (token_hash ~ '^[0-9a-f]{64}$'),
  expires_at      timestamptz not null,
  decision        text not null default 'pending'
                  constraint client_reviews_decision_check check (decision in ('pending', 'approved', 'changes_requested', 'expired', 'canceled')),
  reviewer_name   text,
  comment         text constraint client_reviews_comment_check check (comment is null or length(comment) <= 2000),
  decided_at      timestamptz,
  requested_by    uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  foreign key (client_id, organization_id) references nomad_sceneflow.clients (id, organization_id) on delete cascade,
  foreign key (upload_id, organization_id) references nomad_sceneflow.uploads (id, organization_id) on delete cascade
);
create index client_reviews_upload_idx on nomad_sceneflow.client_reviews (upload_id, created_at desc);
create unique index client_reviews_one_pending on nomad_sceneflow.client_reviews (upload_id) where decision = 'pending';
comment on table nomad_sceneflow.client_reviews is '고객 승인 요청(토큰 해시만, 사용자에게 token_hash 컬럼 미노출). 쓰기 서버.';

create table nomad_sceneflow.client_reports (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  client_id       uuid not null,
  period_month    date not null constraint client_reports_period_check check (period_month = date_trunc('month', period_month)::date),
  kpis            jsonb not null default '{}'::jsonb,
  summary         text,
  pdf_path        text,
  status          text not null default 'generating' constraint client_reports_status_check check (status in ('generating', 'ready', 'failed', 'sent')),
  job_id          uuid,
  sent_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (client_id, period_month),
  foreign key (client_id, organization_id) references nomad_sceneflow.clients (id, organization_id) on delete cascade,
  constraint client_reports_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
comment on table nomad_sceneflow.client_reports is '고객 월간 리포트. 쓰기 서버.';

-- 2.15 편집: pronunciation_lexicon · clip_transcripts · edit_plans
create table nomad_sceneflow.pronunciation_lexicon (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  lang            text not null default 'KO' constraint pronunciation_lexicon_lang_check check (lang in ('KO', 'JA', 'EN')),
  term            text not null constraint pronunciation_lexicon_term_check check (char_length(btrim(term)) between 1 and 50),
  reading         text not null constraint pronunciation_lexicon_reading_check check (char_length(btrim(reading)) between 1 and 100),
  note            text constraint pronunciation_lexicon_note_check check (note is null or char_length(note) <= 200),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint pronunciation_lexicon_term_uniq unique (organization_id, lang, term)
);
create index pronunciation_lexicon_sync_idx on nomad_sceneflow.pronunciation_lexicon (organization_id, updated_at);
comment on table nomad_sceneflow.pronunciation_lexicon is '조직 발음 사전(조직당 2,000개). 사용자 쓰기.';

create table nomad_sceneflow.clip_transcripts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  scene_asset_id  uuid not null,
  language        text not null constraint clip_transcripts_language_check check (language in ('KO', 'JA', 'EN')),
  provider        text not null default 'oss-voice' constraint clip_transcripts_provider_check check (provider = 'oss-voice'),
  duration_ms     integer not null constraint clip_transcripts_duration_check check (duration_ms > 0),
  words           jsonb not null constraint clip_transcripts_words_check check (jsonb_typeof(words) = 'array' and pg_column_size(words) <= 2097152),
  created_at      timestamptz not null default now(),
  constraint clip_transcripts_asset_uniq unique (scene_asset_id),
  foreign key (scene_asset_id, organization_id) references nomad_sceneflow.scene_assets (id, organization_id) on delete cascade
);
comment on table nomad_sceneflow.clip_transcripts is '업로드 클립 단어 전사(오픈소스 STT). 쓰기 서버.';

create table nomad_sceneflow.edit_plans (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  storyboard_id       uuid not null,
  source              text not null constraint edit_plans_source_check check (source in ('command', 'voice', 'auto_polish', 'silence_cut', 'retake', 'broll')),
  instruction         text constraint edit_plans_instruction_check check (instruction is null or char_length(instruction) <= 1000),
  commands            jsonb not null constraint edit_plans_commands_check check (nomad_sceneflow_private.valid_edit_commands(commands)),
  summary             text constraint edit_plans_summary_check check (summary is null or char_length(summary) <= 2000),
  estimate_credits    integer not null default 0 constraint edit_plans_estimate_check check (estimate_credits >= 0),
  base_fingerprint    text not null,
  after_fingerprint   text,
  applied_command_ids integer[],
  undo_state          jsonb,
  status              text not null default 'proposed' constraint edit_plans_status_check check (status in ('proposed', 'applied', 'rejected', 'expired', 'undone', 'failed')),
  ai_run_id           uuid,
  last_error          text,
  created_by          uuid,
  applied_by          uuid,
  applied_at          timestamptz,
  undone_at           timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint edit_plans_applied_check check (status not in ('applied', 'undone') or (applied_at is not null and after_fingerprint is not null)),
  foreign key (storyboard_id, organization_id) references nomad_sceneflow.storyboards (id, organization_id) on delete cascade,
  constraint edit_plans_ai_run_fk foreign key (ai_run_id, organization_id) references nomad_core.ai_runs (id, organization_id) on delete set null (ai_run_id)
);
create index edit_plans_storyboard_idx on nomad_sceneflow.edit_plans (storyboard_id, created_at desc);
create index edit_plans_applied_idx on nomad_sceneflow.edit_plans (storyboard_id, applied_at desc) where status = 'applied';
comment on table nomad_sceneflow.edit_plans is 'AI 편집안. 쓰기 서버, 사용자는 apply·undo·reject RPC(ai_edit).';

-- ---------- 3. 트리거 함수 (비노출 스키마, service_role 쓰기에도 적용) ----------
-- 상태 전이(원본 enforce_status_transition + enforce_storyboard_transition 합침). 인자 0 = 컬럼(기본 status).
create function nomad_sceneflow_private.enforce_status_transition() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_col text := coalesce(tg_argv[0], 'status');
  v_old text := to_jsonb(old) ->> v_col;
  v_new text := to_jsonb(new) ->> v_col;
  v_map constant jsonb := '{
    "channels.status":            {"active":["paused","error","revoked"], "paused":["active","error","revoked"], "error":["active","revoked"]},
    "sources.status":             {"requested":["downloading","failed"], "downloading":["ready","failed"], "failed":["requested"], "ready":["purged"]},
    "productions.status":         {"queued":["processing","failed","canceled"], "processing":["ready","partial","failed","canceled"]},
    "outputs.status":             {"pending":["ready","failed"], "failed":["pending"], "ready":["purged"]},
    "longform_projects.status":   {"draft":["storyboard","canceled"], "storyboard":["draft","generating","canceled"], "generating":["review","failed","canceled"], "review":["storyboard","encoding"], "encoding":["ready","failed"], "failed":["storyboard"]},
    "longform_sections.status":   {"draft":["image_pending"], "image_pending":["image_ready","failed"], "image_ready":["image_pending"], "failed":["image_pending"]},
    "longform_highlights.status": {"proposed":["rendering"], "rendering":["ready","failed"], "failed":["rendering"]},
    "music_tracks.status":        {"requested":["generating","failed"], "generating":["ready","failed"], "failed":["requested"], "ready":["archived"]},
    "music_tracks.distribution_status": {"none":["packaged"], "packaged":["submitted","none"], "submitted":["live","rejected"], "rejected":["packaged"], "live":["takedown"]},
    "music_library.status":       {"active":["expired","revoked"], "expired":["active","revoked"]},
    "playlists.status":           {"draft":["rendering","canceled"], "rendering":["ready","failed","draft"], "failed":["draft"], "ready":["draft"]},
    "landing_pages.status":       {"draft":["published"], "published":["unpublished"], "unpublished":["published","draft"]},
    "uploads.status":             {"draft":["checking","canceled"], "checking":["blocked","awaiting_confirm","approved","draft"], "blocked":["draft","canceled"], "awaiting_confirm":["approved","draft","canceled"], "approved":["client_review","scheduled","canceled"], "client_review":["scheduled","draft","canceled"], "scheduled":["uploading","canceled"], "uploading":["published","failed","scheduled"], "failed":["scheduled","canceled"]},
    "clients.status":             {"active":["paused","ended"], "paused":["active","ended"]},
    "client_reviews.decision":    {"pending":["approved","changes_requested","expired","canceled"]},
    "client_reports.status":      {"generating":["ready","failed"], "failed":["generating"], "ready":["sent","generating"]},
    "storyboard_templates.status": {"active":["retired"], "retired":["active"]},
    "storyboards.status":         {"draft":["ready","archived"], "ready":["draft","rendering","archived"], "rendering":["rendered","ready"], "rendered":["ready","rendering","archived"]},
    "scene_assets.status":        {"ready":["superseded"], "superseded":["ready"]},
    "storyboard_cuts.status":     {"proposed":["rendering"], "rendering":["ready","failed"], "failed":["rendering"], "ready":["rendering"]},
    "edit_plans.status":          {"proposed":["applied","rejected","expired","failed"], "applied":["undone"]}
  }'::jsonb;
begin
  if v_old is distinct from v_new
     and not coalesce((v_map -> (tg_table_name || '.' || v_col) -> v_old) ? v_new, false) then
    raise exception 'sceneflow: invalid %.% transition % -> %', tg_table_name, v_col, v_old, v_new using errcode = '22023';
  end if;
  return new;
end;
$$;

-- 사용자 세션의 Track D·F 콘텐츠 편집을 부모·자기 상태로 잠근다(VD005). 서버는 통과.
create function nomad_sceneflow_private.guard_user_edit() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_status text; v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  if nomad_core.is_service_caller() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 부모 상태(VD005)을 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role((v_row ->> 'organization_id')::uuid) is null then
    raise exception 'sceneflow: not a member of this organization' using errcode = '42501';
  end if;
  if tg_table_name = 'longform_projects' then
    if tg_op = 'UPDATE' and old.status not in ('draft', 'storyboard', 'review') then
      raise exception 'sceneflow: longform project is locked in status %', old.status using errcode = 'VD005';
    end if;
  elsif tg_table_name = 'longform_sections' then
    select p.status into v_status from nomad_sceneflow.longform_projects p where p.id = (v_row ->> 'longform_id')::uuid;
    if coalesce(v_status, '') not in ('draft', 'storyboard', 'review') then
      raise exception 'sceneflow: longform sections are locked (project status %)', v_status using errcode = 'VD005';
    end if;
  elsif tg_table_name = 'playlists' then
    if tg_op = 'UPDATE' and old.status <> 'draft' then
      raise exception 'sceneflow: playlist is locked in status %', old.status using errcode = 'VD005';
    end if;
  elsif tg_table_name = 'playlist_items' then
    select p.status into v_status from nomad_sceneflow.playlists p where p.id = (v_row ->> 'playlist_id')::uuid;
    if coalesce(v_status, '') <> 'draft' then
      raise exception 'sceneflow: playlist items are locked (playlist status %)', v_status using errcode = 'VD005';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- 소프트 삭제: 시각은 클라이언트 값을 믿지 않는다(null = 복구, 그 밖 = now()). 삭제·복구는 owner/admin(원본 삭제 정책과 같음).
create function nomad_sceneflow_private.soft_delete_guard() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.deleted_at is distinct from old.deleted_at then
    if not nomad_core.is_service_caller() and not nomad_sceneflow.can_write(new.organization_id, true) then
      raise exception 'sceneflow: only owner/admin may delete or restore' using errcode = '42501';
    end if;
    if new.deleted_at is not null then
      new.deleted_at := now();
    end if;
  end if;
  return new;
end;
$$;

-- 크레딧 원장 조직 일치(credit_ledger 는 복합 키가 없어 트리거로 확인, VD002)
create function nomad_sceneflow_private.check_ledger_org() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.credit_ledger_id is not null and (tg_op = 'INSERT' or new.credit_ledger_id is distinct from old.credit_ledger_id)
     and not exists (select 1 from nomad_core.credit_ledger l where l.id = new.credit_ledger_id and l.organization_id = new.organization_id) then
    raise exception 'sceneflow: credit ledger org mismatch' using errcode = 'VD002';
  end if;
  return new;
end;
$$;

-- 결과 전달 가드: status 가 ready 가 되는 순간 소유 잡이 failed·canceled(이미 환불)면 거부(55000),
--   아니면 nomad_core.mark_job_delivered 로 이후 잡 실패 환불을 끈다. 인자 0 = 잡 컬럼(outputs 는 소유 행의 잡).
create function nomad_sceneflow_private.guard_job_delivery() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_job uuid; v_status text;
begin
  if new.status <> 'ready' or (tg_op = 'UPDATE' and old.status = 'ready') then
    return new;
  end if;
  if tg_table_name = 'outputs' then
    select coalesce(
      (select p.root_job_id from nomad_sceneflow.productions p where p.id = new.production_id),
      (select l.root_job_id from nomad_sceneflow.longform_projects l where l.id = new.longform_id),
      (select l.root_job_id from nomad_sceneflow.longform_highlights h join nomad_sceneflow.longform_projects l on l.id = h.longform_id where h.id = new.highlight_id),
      (select m.job_id from nomad_sceneflow.music_tracks m where m.id = new.music_track_id),
      (select p.root_job_id from nomad_sceneflow.playlists p where p.id = new.playlist_id),
      (select c.job_id from nomad_sceneflow.storyboard_cuts c where c.id = new.storyboard_cut_id)) into v_job;
  else
    v_job := (to_jsonb(new) ->> tg_argv[0])::uuid;
  end if;
  if v_job is null then
    return new;
  end if;
  select j.status into v_status from nomad_core.jobs j where j.id = v_job for update;
  if v_status in ('failed', 'canceled') then
    raise exception 'sceneflow: % job is % (credits already refunded)', tg_table_name, v_status using errcode = '55000';
  end if;
  perform nomad_core.mark_job_delivered(v_job);
  return new;
end;
$$;

-- 업로드·플리 곡·제휴 링크·랜딩 게이트(원본 check_refs 중 복합 FK 로 대체되지 않은 부분)
create function nomad_sceneflow_private.check_refs() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_status text; v_cnt integer; v_lib record; v_ch record; v_verdict text; v_bc uuid;
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 곡·라이선스·채널 상태을 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'sceneflow: not a member of this organization' using errcode = '42501';
  end if;
  if tg_table_name = 'playlist_items' then
    if new.music_track_id is not null then
      select status into v_status from nomad_sceneflow.music_tracks where id = new.music_track_id;
      if v_status <> 'ready' then raise exception 'sceneflow: music track is not ready (%)', v_status using errcode = 'VD006'; end if;
    end if;
    if new.library_track_id is not null then
      select status, license_expires_at, youtube_monetization_allowed into v_lib from nomad_sceneflow.music_library where id = new.library_track_id;
      if v_lib.status <> 'active' or (v_lib.license_expires_at is not null and v_lib.license_expires_at <= now())
         or not v_lib.youtube_monetization_allowed then
        raise exception 'sceneflow: library track license is not usable' using errcode = 'VD006';
      end if;
    end if;

  elsif tg_table_name = 'landing_pages' then
    if cardinality(new.related_link_ids) > 0 then
      select count(*) into v_cnt from nomad_core.affiliate_links a where a.id = any (new.related_link_ids) and a.organization_id = new.organization_id;
      if v_cnt <> cardinality(new.related_link_ids) then raise exception 'sceneflow: related link org mismatch' using errcode = 'VD002'; end if;
    end if;

  elsif tg_table_name = 'upload_links' then
    if not exists (select 1 from nomad_sceneflow.uploads u where u.id = new.upload_id and u.has_affiliate) then
      raise exception 'sceneflow: upload must carry affiliate disclosure before links are attached' using errcode = 'VD007';
    end if;

  elsif tg_table_name = 'uploads' then
    if tg_op = 'INSERT' then
      select status into v_status from nomad_sceneflow.outputs where id = new.output_id;
      if v_status <> 'ready' then raise exception 'sceneflow: output is not ready (%)', v_status using errcode = 'VD008'; end if;
      select platform, status, automation_consent_version into v_ch from nomad_sceneflow.channels where id = new.channel_id;
      if v_ch.platform <> new.platform or v_ch.status <> 'active' then
        raise exception 'sceneflow: channel is not an active % channel', new.platform using errcode = 'VD008';
      end if;
      if new.platform = 'naver_clip' and v_ch.automation_consent_version is distinct from nomad_sceneflow_private.clip_notice_version() then
        raise exception 'sceneflow: naver clip automation risk consent required (%)', nomad_sceneflow_private.clip_notice_version() using errcode = 'VD015';
      end if;
    end if;
    -- 플랜 잠금: 새 업로드와, 기존 업로드가 예약·게시로 넘어갈 때 모두 본다(구독이 끊긴 조직의 유료 플랫폼·브랜드커넥트 업로드 차단)
    if tg_op = 'INSERT' or (new.status in ('scheduled', 'uploading') and new.status is distinct from old.status) then
      if new.platform <> 'youtube' and not nomad_sceneflow_private.feat(new.organization_id, 'multi_platform') then
        raise exception 'sceneflow: platform % is not in the plan', new.platform using errcode = 'VD004';
      end if;
      if new.brandconnect_application_id is not null and not nomad_sceneflow_private.feat(new.organization_id, 'brandconnect') then
        raise exception 'sceneflow: brandconnect is not in the plan' using errcode = 'VD009';
      end if;
      if not nomad_sceneflow_private.feat(new.organization_id, 'studio') then
        raise exception 'sceneflow: organization has no sceneflow access' using errcode = 'VD003';
      end if;
    end if;
    if new.brandconnect_application_id is not null
       and (tg_op = 'INSERT' or new.brandconnect_application_id is distinct from old.brandconnect_application_id) then
      select b.organization_id into v_bc from nomad_core.brandconnect_applications b where b.id = new.brandconnect_application_id;
      if v_bc is distinct from new.organization_id then raise exception 'sceneflow: brandconnect application org mismatch' using errcode = 'VD002'; end if;
    end if;
    if tg_op = 'UPDATE' then
      if old.has_affiliate and not new.has_affiliate and exists (select 1 from nomad_sceneflow.upload_links l where l.upload_id = new.id) then
        raise exception 'sceneflow: affiliate links exist; disclosure cannot be removed' using errcode = 'VD007';
      end if;
      if new.status = 'approved' and old.status is distinct from 'approved' then
        if new.compliance_check_id is null then
          raise exception 'sceneflow: compliance check required' using errcode = 'VD011';
        end if;
        select verdict into v_verdict from nomad_sceneflow.compliance_checks where id = new.compliance_check_id and upload_id = new.id;
        if v_verdict is null or v_verdict = 'fail' or (v_verdict = 'warn' and new.compliance_ack_at is null) then
          raise exception 'sceneflow: compliance gate not satisfied (%)', coalesce(v_verdict, 'none') using errcode = 'VD011';
        end if;
      end if;
      if new.status = 'scheduled' and old.status = 'approved'
         and exists (select 1 from nomad_sceneflow.client_channels cc join nomad_sceneflow.clients c on c.id = cc.client_id
                     where cc.channel_id = new.channel_id and c.review_required) then
        raise exception 'sceneflow: client review required before scheduling' using errcode = 'VD016';
      end if;
      if new.status = 'scheduled' and old.status = 'client_review'
         and not exists (select 1 from nomad_sceneflow.client_reviews r where r.upload_id = new.id and r.decision = 'approved') then
        raise exception 'sceneflow: client has not approved this upload' using errcode = 'VD016';
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- 채널 한도: studio 필수(VD003), YouTube 외 플랫폼은 multi_platform(VD004), YouTube 활성 수 <= max_channels(키 없으면 0, VD003)
create function nomad_sceneflow_private.enforce_channel_limit() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_max integer; v_cnt integer;
begin
  if new.status <> 'active' or (tg_op = 'UPDATE' and old.status = 'active') then
    return new;
  end if;
  if not nomad_sceneflow_private.feat(new.organization_id, 'studio') then
    raise exception 'sceneflow: organization has no sceneflow access' using errcode = 'VD003';
  end if;
  if new.platform <> 'youtube' and not nomad_sceneflow_private.feat(new.organization_id, 'multi_platform') then
    raise exception 'sceneflow: platform % is not in the plan', new.platform using errcode = 'VD004';
  end if;
  if new.platform = 'youtube' then
    v_max := nomad_sceneflow_private.limit_int(new.organization_id, 'max_channels', 0);
    select count(*) into v_cnt from nomad_sceneflow.channels c
    where c.organization_id = new.organization_id and c.platform = 'youtube' and c.status = 'active' and c.id <> new.id;
    if v_cnt >= v_max then
      raise exception 'sceneflow: youtube channel limit % reached', v_max using errcode = 'VD003';
    end if;
  end if;
  return new;
end;
$$;

-- 스토리보드 사용자 편집 잠금: rendering 중 수정·삭제 VD020, archived 수정 VD005. 서버는 통과.
create function nomad_sceneflow_private.guard_storyboard_edit() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if nomad_core.is_service_caller() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if old.status = 'rendering' then
    raise exception 'sceneflow: storyboard is rendering' using errcode = 'VD020';
  end if;
  if tg_op = 'UPDATE' and old.status = 'archived' then
    raise exception 'sceneflow: storyboard is archived' using errcode = 'VD005';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- 스토리보드 플랜 한도(VD009): storyboard 기능, 롱폼 길이 <= storyboard_max_minutes, 해상도 <= render_max_resolution(짧은 변 px),
--   fps <= render_max_fps, 4K60 은 render_4k60. 키가 없으면 원본 코드 기본값(0분 · 1080 · 30).
create function nomad_sceneflow_private.enforce_storyboard_limits() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_res integer := case new.resolution when '720p' then 720 when '1080p' then 1080 when '1440p' then 1440 when '2160p' then 2160 end;
        v_max integer;
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 플랜·한도(VD009)를 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'sceneflow: not a member of this organization' using errcode = '42501';
  end if;
  if not nomad_sceneflow_private.feat(new.organization_id, 'storyboard') then
    raise exception 'sceneflow: plan does not include storyboards' using errcode = 'VD009';
  end if;
  v_max := nomad_sceneflow_private.limit_int(new.organization_id, 'storyboard_max_minutes', 0);
  if new.format = 'longform' and new.target_seconds > v_max * 60 then
    raise exception 'sceneflow: longform storyboard over plan limit (% min)', v_max using errcode = 'VD009';
  end if;
  v_max := nomad_sceneflow_private.limit_int(new.organization_id, 'render_max_resolution', 1080);
  if v_res > v_max then
    raise exception 'sceneflow: resolution % over plan limit %p', new.resolution, v_max using errcode = 'VD009';
  end if;
  if new.fps > nomad_sceneflow_private.limit_int(new.organization_id, 'render_max_fps', 30) then
    raise exception 'sceneflow: fps % over plan limit', new.fps using errcode = 'VD009';
  end if;
  if new.resolution = '2160p' and new.fps = 60 and not nomad_sceneflow_private.feat(new.organization_id, 'render_4k60') then
    raise exception 'sceneflow: 4K 60fps is not in the plan' using errcode = 'VD009';
  end if;
  return new;
end;
$$;

-- 렌더 설정이 바뀌면 rendered → ready(다시 렌더 필요)
create function nomad_sceneflow_private.storyboard_render_settings_changed() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if (new.aspect, new.resolution, new.fps, new.shorts_aspect) is distinct from (old.aspect, old.resolution, old.fps, old.shorts_aspect)
     and old.status = 'rendered' then
    new.status := 'ready';
  end if;
  return new;
end;
$$;

-- 컷 장면 목록: 모두 그 스토리보드 장면, 중복 없음, short 는 ord 연속
create function nomad_sceneflow_private.cut_scenes_valid(p_storyboard_id uuid, p_kind text, p_scene_ids uuid[]) returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v_cnt integer; v_ords integer[];
begin
  if coalesce(cardinality(p_scene_ids), 0) = 0
     or (select count(distinct x) from unnest(p_scene_ids) as u(x)) <> cardinality(p_scene_ids) then
    return false;
  end if;
  select count(*), array_agg(s.ord order by u.n) into v_cnt, v_ords
  from unnest(p_scene_ids) with ordinality as u(id, n)
  join nomad_sceneflow.scenes s on s.id = u.id and s.storyboard_id = p_storyboard_id;
  if v_cnt <> cardinality(p_scene_ids) then
    return false;
  end if;
  if p_kind = 'short' then
    for i in 2 .. v_cnt loop
      if v_ords[i] <> v_ords[1] + i - 1 then
        return false;
      end if;
    end loop;
  end if;
  return true;
end;
$$;

-- 컷 검사: 장면 목록(22023), 쇼츠 컷 한도 shorts_extract_max(키 없으면 0, VD021), 변형본 화면비·한도 aspect_variants_max(키 없으면 0, VD022).
--   소재 재사용은 이미지끼리만.
create function nomad_sceneflow_private.check_storyboard_refs() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_kind text; v_cnt integer; v_max integer; v_sb nomad_sceneflow.storyboards;
begin
  if tg_table_name = 'scene_assets' then
    if new.reused_from_asset_id is not null then
      select kind into v_kind from nomad_sceneflow.scene_assets where id = new.reused_from_asset_id;
      if v_kind <> 'image' or new.kind <> 'image' then
        raise exception 'sceneflow: only images can be reused' using errcode = '22023';
      end if;
    end if;
  elsif tg_table_name = 'storyboard_cuts' then
    if tg_op = 'INSERT' or new.scene_ids is distinct from old.scene_ids or new.kind is distinct from old.kind then
      if not nomad_sceneflow_private.cut_scenes_valid(new.storyboard_id, new.kind, new.scene_ids) then
        raise exception 'sceneflow: cut scenes must be distinct % scenes of the storyboard',
          case when new.kind = 'short' then 'consecutive' else 'existing' end using errcode = '22023';
      end if;
    end if;
    if new.kind = 'short' and (tg_op = 'INSERT' or old.kind is distinct from 'short') then
      v_max := least(10, nomad_sceneflow_private.limit_int(new.organization_id, 'shorts_extract_max', 0));
      select count(*) into v_cnt from nomad_sceneflow.storyboard_cuts c where c.storyboard_id = new.storyboard_id and c.kind = 'short' and c.id <> new.id;
      if v_cnt >= v_max then
        raise exception 'sceneflow: shorts cut limit % reached', v_max using errcode = 'VD021';
      end if;
    end if;
    if new.kind = 'variant' then
      select * into v_sb from nomad_sceneflow.storyboards where id = new.storyboard_id;
      if new.aspect = v_sb.aspect or not nomad_sceneflow.storyboard_aspect_allowed(v_sb.format, new.aspect) then
        raise exception 'sceneflow: variant aspect % is not allowed for % (master %)', new.aspect, v_sb.format, v_sb.aspect using errcode = '22023';
      end if;
      if tg_op = 'INSERT' or old.kind is distinct from 'variant' then
        v_max := least(3, nomad_sceneflow_private.limit_int(new.organization_id, 'aspect_variants_max', 0));
        select count(*) into v_cnt from nomad_sceneflow.storyboard_cuts c where c.storyboard_id = new.storyboard_id and c.kind = 'variant' and c.id <> new.id;
        if v_cnt >= v_max then
          raise exception 'sceneflow: aspect variant limit % reached', v_max using errcode = 'VD022';
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- 장면 revision: 내용 컬럼이 바뀔 때만 +1. 부모·조직 이동 금지.
create function nomad_sceneflow_private.scenes_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.storyboard_id is distinct from old.storyboard_id or new.organization_id is distinct from old.organization_id then
    raise exception 'sceneflow: scene cannot move to another storyboard' using errcode = '22023';
  end if;
  if (new.chapter, new.kind, new.duration_ms, new.narration, new.on_screen_text, new.visual_prompt, new.motion_preset, new.music_cue,
      new.sources, new.source_required, new.focus_x, new.focus_y, new.transition, new.transition_ms, new.clip_in_ms, new.clip_out_ms,
      new.cut_ranges, new.caption_emphasis)
     is distinct from
     (old.chapter, old.kind, old.duration_ms, old.narration, old.on_screen_text, old.visual_prompt, old.motion_preset, old.music_cue,
      old.sources, old.source_required, old.focus_x, old.focus_y, old.transition, old.transition_ms, old.clip_in_ms, old.clip_out_ms,
      old.cut_ranges, old.caption_emphasis) then
    new.revision := old.revision + 1;
  else
    new.revision := old.revision;
  end if;
  return new;
end;
$$;

create function nomad_sceneflow_private.storyboard_snapshots_readonly() returns trigger
language plpgsql set search_path = ''
as $$ begin raise exception 'sceneflow: storyboard snapshots are read-only' using errcode = '42501'; end; $$;

-- 편집 표 검사: 편집안 내용 불변, 프리셋 한도 edit_presets_max(키 없으면 0, VD009), 발음 사전 2,000개(54000),
--   전사는 clip 소재만, 스토리보드 프리셋은 같은 고객(또는 공용)만.
create function nomad_sceneflow_private.check_edit_refs() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_kind text; v_cnt integer; v_max integer; v_client uuid;
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 플랜 한도(VD009)을 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'sceneflow: not a member of this organization' using errcode = '42501';
  end if;
  if tg_table_name = 'edit_plans' then
    if tg_op = 'UPDATE' and (new.storyboard_id, new.organization_id, new.commands, new.base_fingerprint)
                            is distinct from (old.storyboard_id, old.organization_id, old.commands, old.base_fingerprint) then
      raise exception 'sceneflow: edit plan content is immutable' using errcode = '22023';
    end if;
  elsif tg_table_name = 'edit_presets' then
    if tg_op = 'INSERT' then
      v_max := nomad_sceneflow_private.limit_int(new.organization_id, 'edit_presets_max', 0);
      select count(*) into v_cnt from nomad_sceneflow.edit_presets where organization_id = new.organization_id;
      if v_cnt >= v_max then raise exception 'sceneflow: edit preset limit % reached', v_max using errcode = 'VD009'; end if;
    end if;
  elsif tg_table_name = 'pronunciation_lexicon' then
    if tg_op = 'INSERT' then
      select count(*) into v_cnt from nomad_sceneflow.pronunciation_lexicon where organization_id = new.organization_id;
      if v_cnt >= 2000 then raise exception 'sceneflow: pronunciation lexicon limit 2000 reached' using errcode = '54000'; end if;
    end if;
  elsif tg_table_name = 'clip_transcripts' then
    select kind into v_kind from nomad_sceneflow.scene_assets where id = new.scene_asset_id;
    if v_kind <> 'clip' then raise exception 'sceneflow: transcripts are for clip assets only' using errcode = '22023'; end if;
  elsif tg_table_name = 'storyboards' then
    if new.edit_preset_id is not null then
      select client_id into v_client from nomad_sceneflow.edit_presets where id = new.edit_preset_id;
      if v_client is not null and v_client is distinct from new.client_id then
        raise exception 'sceneflow: edit preset belongs to another client' using errcode = 'VD002';
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- ---------- 4. 트리거 연결 ----------
do $$
declare t text;
begin
  foreach t in array array['channels', 'sources', 'clients', 'productions', 'longform_projects', 'longform_sections', 'longform_highlights',
                           'music_tracks', 'music_library', 'playlists', 'playlist_items', 'landing_pages', 'linkinbio_profiles',
                           'linkinbio_items', 'storyboard_templates', 'edit_presets', 'storyboards', 'scenes', 'scene_assets',
                           'storyboard_cuts', 'outputs', 'uploads', 'workflows', 'client_reviews', 'client_reports',
                           'pronunciation_lexicon', 'edit_plans'] loop
    execute format('create trigger %I before update on nomad_sceneflow.%I for each row execute function nomad_core.touch_updated_at()', t || '_touch_updated_at', t);
  end loop;
  foreach t in array array['channels', 'sources', 'productions', 'outputs', 'longform_projects', 'longform_sections', 'longform_highlights',
                           'music_tracks', 'music_library', 'playlists', 'landing_pages', 'uploads', 'clients', 'client_reports',
                           'storyboard_templates', 'storyboards', 'scene_assets', 'storyboard_cuts', 'edit_plans'] loop
    execute format('create trigger %I before update of status on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.enforce_status_transition(''status'')', t || '_status_transition', t);
  end loop;
  foreach t in array array['playlist_items', 'landing_pages', 'uploads', 'upload_links'] loop
    execute format('create trigger %I before insert or update on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.check_refs()', t || '_check_refs', t);
  end loop;
  foreach t in array array['longform_projects', 'longform_sections', 'playlists', 'playlist_items'] loop
    execute format('create trigger %I before insert or update or delete on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.guard_user_edit()', t || '_guard_user_edit', t);
  end loop;
  foreach t in array array['clients', 'music_library', 'playlists', 'storyboards', 'workflows'] loop
    execute format('create trigger %I before update of deleted_at on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.soft_delete_guard()', t || '_soft_delete', t);
  end loop;
  foreach t in array array['radar_reports', 'productions', 'longform_projects', 'music_tracks', 'playlists', 'uploads', 'compliance_checks', 'storyboard_cuts'] loop
    execute format('create trigger %I before insert or update of credit_ledger_id on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.check_ledger_org()', t || '_ledger_org', t);
  end loop;
  foreach t in array array['music_tracks', 'sources', 'client_reports', 'storyboard_cuts'] loop
    execute format('create trigger %I before insert or update of status on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.guard_job_delivery(''job_id'')', t || '_job_delivery', t);
  end loop;
  foreach t in array array['scene_assets', 'storyboard_cuts'] loop
    execute format('create trigger %I before insert or update on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.check_storyboard_refs()', t || '_check_refs', t);
  end loop;
  foreach t in array array['edit_plans', 'edit_presets', 'pronunciation_lexicon', 'clip_transcripts', 'storyboards'] loop
    execute format('create trigger %I before insert or update on nomad_sceneflow.%I for each row execute function nomad_sceneflow_private.check_edit_refs()', t || '_check_edit_refs', t);
  end loop;
end $$;
create trigger outputs_job_delivery before insert or update of status on nomad_sceneflow.outputs
  for each row execute function nomad_sceneflow_private.guard_job_delivery();
create trigger music_tracks_distribution_transition before update of distribution_status on nomad_sceneflow.music_tracks
  for each row execute function nomad_sceneflow_private.enforce_status_transition('distribution_status');
create trigger client_reviews_decision_transition before update of decision on nomad_sceneflow.client_reviews
  for each row execute function nomad_sceneflow_private.enforce_status_transition('decision');
create trigger channels_limit before insert or update of status on nomad_sceneflow.channels
  for each row execute function nomad_sceneflow_private.enforce_channel_limit();
create trigger storyboards_guard_user_edit before update or delete on nomad_sceneflow.storyboards
  for each row execute function nomad_sceneflow_private.guard_storyboard_edit();
create trigger storyboards_limits before insert or update of format, target_seconds, resolution, fps on nomad_sceneflow.storyboards
  for each row execute function nomad_sceneflow_private.enforce_storyboard_limits();
create trigger storyboards_render_settings before update of aspect, resolution, fps, shorts_aspect on nomad_sceneflow.storyboards
  for each row execute function nomad_sceneflow_private.storyboard_render_settings_changed();
create trigger scenes_before_update before update on nomad_sceneflow.scenes
  for each row execute function nomad_sceneflow_private.scenes_before_update();
create trigger storyboard_snapshots_readonly before update on nomad_sceneflow.storyboard_snapshots
  for each row execute function nomad_sceneflow_private.storyboard_snapshots_readonly();

-- ---------- 5. RLS 와 grant. anon 표 grant 없음(공개는 RPC 만). 쓰기는 컬럼 grant + 정책(역할 + 기능 = 구독 끊기면 잠김). ----------
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_sceneflow' and c.relkind = 'r' loop
    execute format('alter table nomad_sceneflow.%I enable row level security', t);
    execute format('revoke all on nomad_sceneflow.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on nomad_sceneflow.%I to service_role', t);
  end loop;
  -- 읽기: 같은 조직 멤버 + studio(C 포함 — 구독이 끊겨도 무료 플랜처럼 읽기는 남는다)
  foreach t in array array['channels', 'radar_reports', 'sources', 'clients', 'productions', 'longform_projects', 'longform_sections',
                           'longform_highlights', 'music_tracks', 'music_library', 'playlists', 'playlist_items', 'landing_pages',
                           'linkinbio_profiles', 'linkinbio_items', 'edit_presets', 'storyboards', 'scenes', 'scene_assets',
                           'storyboard_cuts', 'storyboard_snapshots', 'outputs', 'uploads', 'upload_links', 'compliance_checks',
                           'analytics_snapshots', 'workflows', 'banned_words', 'client_channels', 'client_reports',
                           'pronunciation_lexicon', 'clip_transcripts', 'edit_plans'] loop
    execute format('grant select on nomad_sceneflow.%I to authenticated', t);
    execute format('create policy %I on nomad_sceneflow.%I for select to authenticated using (nomad_sceneflow.has_access(organization_id))', t || '_select', t);
  end loop;
end $$;
grant usage, select on all sequences in schema nomad_sceneflow to service_role;

-- 공용 카탈로그: 기능이 있는 조직의 멤버
grant select on nomad_sceneflow.trend_videos, nomad_sceneflow.storyboard_templates to authenticated;
create policy trend_videos_select on nomad_sceneflow.trend_videos for select to authenticated
  using (nomad_sceneflow.caller_has_feature('radar'));
create policy storyboard_templates_select on nomad_sceneflow.storyboard_templates for select to authenticated
  using (nomad_sceneflow.caller_has_feature('storyboard'));

-- client_reviews: token_hash 는 주지 않는다(컬럼 grant). 쓰기는 서버만.
grant select (id, organization_id, client_id, upload_id, expires_at, decision, reviewer_name, comment, decided_at, requested_by, created_at, updated_at)
  on nomad_sceneflow.client_reviews to authenticated;
create policy client_reviews_select on nomad_sceneflow.client_reviews for select to authenticated
  using (nomad_sceneflow.has_access(organization_id));

-- 콘텐츠 표 쓰기(원본 member → editor). 정책 식에 기능을 넣어 구독이 끊기면 기존 행 수정도 잠긴다.
grant insert (organization_id, title, category, topic, languages, storyline, target_minutes) on nomad_sceneflow.longform_projects to authenticated;
grant update (title, category, topic, languages, storyline, target_minutes) on nomad_sceneflow.longform_projects to authenticated;
grant insert (organization_id, longform_id, position, heading, script, image_prompt) on nomad_sceneflow.longform_sections to authenticated;
grant update (heading, script, image_prompt) on nomad_sceneflow.longform_sections to authenticated;
grant update (title) on nomad_sceneflow.music_tracks to authenticated;
grant insert (organization_id, title, artist, license_type, license_source, license_proof_path, license_expires_at,
              youtube_monetization_allowed, attribution_text, audio_path, duration_sec) on nomad_sceneflow.music_library to authenticated;
grant update (title, artist, license_source, license_proof_path, license_expires_at, attribution_text, deleted_at) on nomad_sceneflow.music_library to authenticated;
grant insert (organization_id, title, mood, target_duration_min, language, visual_style, cover_prompt, description_body) on nomad_sceneflow.playlists to authenticated;
grant update (title, mood, target_duration_min, language, visual_style, cover_prompt, description_body, deleted_at) on nomad_sceneflow.playlists to authenticated;
grant insert (organization_id, playlist_id, position, music_track_id, library_track_id) on nomad_sceneflow.playlist_items to authenticated;
grant update (position) on nomad_sceneflow.playlist_items to authenticated;
grant update (product_name, headline, features) on nomad_sceneflow.landing_pages to authenticated;
grant insert (organization_id, handle, display_name, bio, avatar_path, is_published) on nomad_sceneflow.linkinbio_profiles to authenticated;
grant update (handle, display_name, bio, avatar_path, is_published) on nomad_sceneflow.linkinbio_profiles to authenticated;
grant insert (organization_id, profile_id, kind, title, url, landing_page_id, affiliate_link_id, position, is_active) on nomad_sceneflow.linkinbio_items to authenticated;
grant update (kind, title, url, landing_page_id, affiliate_link_id, position, is_active) on nomad_sceneflow.linkinbio_items to authenticated;
grant insert (organization_id, name, graph) on nomad_sceneflow.workflows to authenticated;
grant update (name, graph, deleted_at) on nomad_sceneflow.workflows to authenticated;
grant insert (organization_id, word, severity) on nomad_sceneflow.banned_words to authenticated;
grant insert (organization_id, name, brand_name, business_no, contact_name, contact_email, contact_phone, brand_guide_path, brand_wiki_ref,
              package_code, contract_start, contract_end, monthly_quota, review_required, report_day, notes) on nomad_sceneflow.clients to authenticated;
grant update (name, brand_name, business_no, contact_name, contact_email, contact_phone, brand_guide_path, brand_wiki_ref,
              package_code, contract_start, contract_end, monthly_quota, review_required, report_day, notes, deleted_at) on nomad_sceneflow.clients to authenticated;
grant insert (organization_id, client_id, channel_id, ownership) on nomad_sceneflow.client_channels to authenticated;
grant insert (organization_id, client_id, title, format, aspect, target_seconds, template_code, topic, languages, voice_provider, voice_id,
              resolution, fps, shorts_aspect, caption_style, caption_hanja, bgm_level_db, loudnorm, edit_preset_id) on nomad_sceneflow.storyboards to authenticated;
grant update (client_id, title, topic, languages, aspect, resolution, fps, shorts_aspect, caption_style, caption_hanja, bgm_level_db, loudnorm,
              edit_preset_id, deleted_at) on nomad_sceneflow.storyboards to authenticated;
grant insert (organization_id, client_id, name, settings, is_default) on nomad_sceneflow.edit_presets to authenticated;
grant update (name, settings, is_default) on nomad_sceneflow.edit_presets to authenticated;
grant insert (organization_id, lang, term, reading, note) on nomad_sceneflow.pronunciation_lexicon to authenticated;
grant update (term, reading, note) on nomad_sceneflow.pronunciation_lexicon to authenticated;
grant delete on nomad_sceneflow.longform_projects, nomad_sceneflow.longform_sections, nomad_sceneflow.music_library, nomad_sceneflow.playlists,
  nomad_sceneflow.playlist_items, nomad_sceneflow.linkinbio_profiles, nomad_sceneflow.linkinbio_items, nomad_sceneflow.workflows,
  nomad_sceneflow.banned_words, nomad_sceneflow.clients, nomad_sceneflow.client_channels, nomad_sceneflow.storyboards,
  nomad_sceneflow.edit_presets, nomad_sceneflow.pronunciation_lexicon to authenticated;

-- 정책: (표, 쓰기 역할 owner/admin 여부, 필요한 기능). 삭제는 원본대로 owner/admin(편집 프리셋·발음 사전은 editor 도).
do $$
declare r record;
begin
  for r in select * from (values
      ('longform_projects', false, 'track_d'), ('longform_sections', false, 'track_d'), ('music_library', false, 'track_f'),
      ('playlists', false, 'track_f'), ('playlist_items', false, 'track_f'), ('linkinbio_profiles', true, null),
      ('linkinbio_items', false, null), ('workflows', false, null), ('clients', true, 'agency'), ('storyboards', false, 'storyboard'),
      ('edit_presets', false, null), ('pronunciation_lexicon', false, null)) v(t, adm, feat) loop
    execute format('create policy %1$s_insert on nomad_sceneflow.%1$I for insert to authenticated with check (nomad_sceneflow.can_write(organization_id, %2$L, %3$L))', r.t, r.adm, r.feat);
    execute format('create policy %1$s_update on nomad_sceneflow.%1$I for update to authenticated using (nomad_sceneflow.can_write(organization_id, %2$L, %3$L)) with check (nomad_sceneflow.can_write(organization_id, %2$L, %3$L))', r.t, r.adm, r.feat);
    execute format('create policy %1$s_delete on nomad_sceneflow.%1$I for delete to authenticated using (nomad_sceneflow.can_write(organization_id, %2$L))', r.t,
                   r.adm or r.t not in ('edit_presets', 'pronunciation_lexicon'));
  end loop;
end $$;
create policy music_tracks_update on nomad_sceneflow.music_tracks for update to authenticated
  using (nomad_sceneflow.can_write(organization_id, false, 'track_e')) with check (nomad_sceneflow.can_write(organization_id, false, 'track_e'));
create policy landing_pages_update on nomad_sceneflow.landing_pages for update to authenticated
  using (nomad_sceneflow.can_write(organization_id, false, 'coupang_landing')) with check (nomad_sceneflow.can_write(organization_id, false, 'coupang_landing'));
create policy banned_words_insert on nomad_sceneflow.banned_words for insert to authenticated
  with check (nomad_sceneflow.can_write(organization_id));
create policy banned_words_delete on nomad_sceneflow.banned_words for delete to authenticated
  using (nomad_sceneflow.can_write(organization_id, true));
create policy client_channels_insert on nomad_sceneflow.client_channels for insert to authenticated
  with check (nomad_sceneflow.can_write(organization_id, true, 'agency'));
create policy client_channels_delete on nomad_sceneflow.client_channels for delete to authenticated
  using (nomad_sceneflow.can_write(organization_id, true));

-- ---------- 6. 사용자 RPC (SECURITY DEFINER, authenticated). 반환은 사용자가 select 로 볼 수 있는 표 행·jsonb 만. ----------
-- 채널 역할·언어·국가·일시정지 (owner/admin)
create function nomad_sceneflow.update_channel_settings(
  p_channel_id uuid, p_role text default null, p_target_language text default null, p_target_country text default null, p_status text default null
) returns nomad_sceneflow.channels
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.channels; v_before jsonb;
begin
  select * into v_row from nomad_sceneflow.channels where id = p_channel_id for update;
  if not found then raise exception 'update_channel_settings: channel not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, true, 'update_channel_settings');
  if p_status is not null and p_status not in ('active', 'paused') then
    raise exception 'update_channel_settings: status must be active or paused' using errcode = '22023';
  end if;
  v_before := to_jsonb(v_row);
  update nomad_sceneflow.channels
     set role = coalesce(p_role, role), target_language = coalesce(p_target_language, target_language),
         target_country = coalesce(p_target_country, target_country), status = coalesce(p_status, status)
   where id = p_channel_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.channel.update', 'channel', p_channel_id::text, v_before, to_jsonb(v_row));
  return v_row;
end;
$$;

-- 채널 연결 해제 (owner/admin): revoked + 키 폐기(nomad_core.revoke_provider_credential, 재폐기 no-op)
create function nomad_sceneflow.disconnect_channel(p_channel_id uuid) returns nomad_sceneflow.channels
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.channels;
begin
  select * into v_row from nomad_sceneflow.channels where id = p_channel_id for update;
  if not found then raise exception 'disconnect_channel: channel not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller() and not coalesce(nomad_core.organization_role(v_row.organization_id), '') in ('owner', 'admin') then
    raise exception 'disconnect_channel: owner/admin only' using errcode = '42501';
  end if;
  if v_row.status = 'revoked' then return v_row; end if;
  if v_row.credential_id is not null then
    perform nomad_core.revoke_provider_credential(v_row.credential_id);
  end if;
  update nomad_sceneflow.channels set status = 'revoked' where id = p_channel_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.channel.disconnect', 'channel', p_channel_id::text);
  return v_row;
end;
$$;

-- 컴플라이언스 WARN 수동 확인 (editor 이상): awaiting_confirm → approved
create function nomad_sceneflow.acknowledge_compliance_warning(p_upload_id uuid, p_note text default null) returns nomad_sceneflow.uploads
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.uploads; v_verdict text;
begin
  select * into v_row from nomad_sceneflow.uploads where id = p_upload_id for update;
  if not found then raise exception 'acknowledge_compliance_warning: upload not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, false, 'acknowledge_compliance_warning');
  if v_row.status <> 'awaiting_confirm' then
    raise exception 'acknowledge_compliance_warning: invalid state %', v_row.status using errcode = 'VD008';
  end if;
  select verdict into v_verdict from nomad_sceneflow.compliance_checks where id = v_row.compliance_check_id;
  if coalesce(v_verdict, '') <> 'warn' then
    raise exception 'acknowledge_compliance_warning: latest verdict is %', coalesce(v_verdict, 'none') using errcode = 'VD011';
  end if;
  update nomad_sceneflow.uploads set compliance_ack_by = auth.uid(), compliance_ack_at = now(), status = 'approved'
   where id = p_upload_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.upload.compliance_ack', 'upload', p_upload_id::text, null, null,
                                 jsonb_build_object('compliance_check_id', v_row.compliance_check_id, 'note', p_note));
  return v_row;
end;
$$;

-- 업로드 취소 (editor 이상). 대기 중 업로드 잡은 nomad_core.cancel_job(생성자 또는 owner/admin, 환불 포함)
create function nomad_sceneflow.cancel_upload(p_upload_id uuid) returns nomad_sceneflow.uploads
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.uploads; v_job_status text;
begin
  select * into v_row from nomad_sceneflow.uploads where id = p_upload_id for update;
  if not found then raise exception 'cancel_upload: upload not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, false, 'cancel_upload');
  if v_row.status not in ('draft', 'blocked', 'awaiting_confirm', 'approved', 'scheduled', 'failed') then
    raise exception 'cancel_upload: invalid state %', v_row.status using errcode = 'VD008';
  end if;
  if v_row.job_id is not null then
    select j.status into v_job_status from nomad_core.jobs j where j.id = v_row.job_id;
    if v_job_status = 'running' then
      raise exception 'cancel_upload: upload is in progress' using errcode = 'VD008';
    elsif v_job_status = 'queued' then
      perform nomad_core.cancel_job(v_row.job_id);
    end if;
  end if;
  update nomad_sceneflow.uploads set status = 'canceled' where id = p_upload_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.upload.cancel', 'upload', p_upload_id::text);
  return v_row;
end;
$$;

-- 랜딩 공개·비공개 (editor 이상). 공개는 coupang_landing + 제휴 링크. 비공개 전환은 잠긴 조직도 할 수 있다.
create function nomad_sceneflow.set_landing_status(p_landing_id uuid, p_status text) returns nomad_sceneflow.landing_pages
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.landing_pages;
begin
  select * into v_row from nomad_sceneflow.landing_pages where id = p_landing_id for update;
  if not found then raise exception 'set_landing_status: landing not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, false, 'set_landing_status',
                                               case when p_status = 'published' then 'coupang_landing' end);
  if p_status is null or p_status not in ('draft', 'published', 'unpublished') then
    raise exception 'set_landing_status: invalid status' using errcode = '22023';
  end if;
  if p_status = 'published' and v_row.primary_link_id is null then
    raise exception 'set_landing_status: affiliate link required' using errcode = 'VD001';
  end if;
  update nomad_sceneflow.landing_pages
     set status = p_status, published_at = case when p_status = 'published' then now() else published_at end
   where id = p_landing_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.landing.' || p_status, 'landing_page', p_landing_id::text);
  return v_row;
end;
$$;

-- 음원 DSP 유통 상태 수동 기록 (editor 이상, track_e)
create function nomad_sceneflow.set_music_distribution_status(p_track_id uuid, p_status text, p_note text default null, p_isrc text default null)
returns nomad_sceneflow.music_tracks
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.music_tracks;
begin
  select * into v_row from nomad_sceneflow.music_tracks where id = p_track_id for update;
  if not found then raise exception 'set_music_distribution_status: track not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, false, 'set_music_distribution_status', 'track_e');
  if p_status is null or p_status not in ('submitted', 'live', 'rejected', 'takedown') then
    raise exception 'set_music_distribution_status: status % is server-managed or invalid', p_status using errcode = '22023';
  end if;
  update nomad_sceneflow.music_tracks
     set distribution_status = p_status, distribution_note = coalesce(p_note, distribution_note), isrc = coalesce(p_isrc, isrc),
         distributed_at = case when p_status = 'live' then now() else distributed_at end
   where id = p_track_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.music.distribution_' || p_status, 'music_track', p_track_id::text);
  return v_row;
end;
$$;

-- 네이버 클립 자동 업로드 위험 동의 (owner/admin, multi_platform). 고지문 버전이 현재 버전이어야 한다(VD015).
create function nomad_sceneflow.consent_clip_automation_risk(p_channel_id uuid, p_version text) returns nomad_sceneflow.channels
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.channels;
begin
  select * into v_row from nomad_sceneflow.channels where id = p_channel_id for update;
  if not found then raise exception 'consent_clip_automation_risk: channel not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, true, 'consent_clip_automation_risk', 'multi_platform');
  if v_row.platform <> 'naver_clip' then
    raise exception 'consent_clip_automation_risk: not a naver_clip channel' using errcode = '22023';
  end if;
  if p_version is distinct from nomad_sceneflow_private.clip_notice_version() then
    raise exception 'consent_clip_automation_risk: notice version % is not current (%)', p_version, nomad_sceneflow_private.clip_notice_version()
      using errcode = 'VD015';
  end if;
  update nomad_sceneflow.channels
     set automation_consent_version = p_version, automation_consented_at = now(), automation_consented_by = auth.uid()
   where id = p_channel_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.channel.clip_risk_consent', 'channel', p_channel_id::text, null, null,
                                 jsonb_build_object('notice_version', p_version));
  return v_row;
end;
$$;

-- 위험 동의 철회 (owner/admin). 잠긴 조직도 철회는 할 수 있다.
create function nomad_sceneflow.revoke_clip_automation_consent(p_channel_id uuid) returns nomad_sceneflow.channels
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.channels;
begin
  select * into v_row from nomad_sceneflow.channels where id = p_channel_id for update;
  if not found then raise exception 'revoke_clip_automation_consent: channel not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, true, 'revoke_clip_automation_consent');
  update nomad_sceneflow.channels set automation_consent_version = null, automation_consented_at = null, automation_consented_by = null
   where id = p_channel_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.channel.clip_risk_revoke', 'channel', p_channel_id::text);
  return v_row;
end;
$$;

-- 대행 고객 상태 (owner/admin, agency). ended 는 되돌릴 수 없다(전이 트리거).
create function nomad_sceneflow.set_client_status(p_client_id uuid, p_status text) returns nomad_sceneflow.clients
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.clients;
begin
  select * into v_row from nomad_sceneflow.clients where id = p_client_id for update;
  if not found then raise exception 'set_client_status: client not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_row.organization_id, true, 'set_client_status', 'agency');
  update nomad_sceneflow.clients set status = p_status where id = p_client_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.client.status', 'client', p_client_id::text, null, null,
                                 jsonb_build_object('status', p_status));
  return v_row;
end;
$$;

-- ---------- 7. 스토리보드 RPC (원본 12.6·13.13 최종 정의) ----------
-- 내부: 스토리보드를 잠그고 편집 가능 여부 확인(역할 42501, 기능 VD009, 렌더 중 VD020, 보관·삭제 VD005, revision VD409)
create function nomad_sceneflow_private.lock_storyboard_for_edit(p_storyboard_id uuid, p_fn text, p_revision integer default null,
                                                                 p_check_revision boolean default false)
returns nomad_sceneflow.storyboards
language plpgsql security definer set search_path = ''
as $$
declare v_sb nomad_sceneflow.storyboards;
begin
  select * into v_sb from nomad_sceneflow.storyboards where id = p_storyboard_id for update;
  if not found then raise exception '%: storyboard not found', p_fn using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_sb.organization_id, false, p_fn, 'storyboard');
  if v_sb.status = 'rendering' then raise exception '%: storyboard is rendering', p_fn using errcode = 'VD020'; end if;
  if v_sb.status = 'archived' or v_sb.deleted_at is not null then raise exception '%: storyboard is archived', p_fn using errcode = 'VD005'; end if;
  if p_check_revision and v_sb.revision is distinct from p_revision then
    raise exception '%: storyboard revision conflict (current %)', p_fn, v_sb.revision using errcode = 'VD409';
  end if;
  return v_sb;
end;
$$;

create function nomad_sceneflow_private.storyboard_fingerprint(p_storyboard_id uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select md5(concat_ws('|', b.revision, b.aspect, b.resolution, b.fps, b.shorts_aspect, b.caption_style, b.caption_hanja, b.bgm_level_db, b.loudnorm,
                       (select string_agg(s.id::text || ':' || s.revision || ':' || s.ord || ':' || s.shorts_candidate, ',' order by s.ord)
                          from nomad_sceneflow.scenes s where s.storyboard_id = b.id)))
  from nomad_sceneflow.storyboards b where b.id = p_storyboard_id
$$;

-- 장면 저장. p_revision 불일치 VD409. 내레이션이 바뀌면 ready 내레이션 소재 superseded, rendered → ready.
create function nomad_sceneflow.save_scene(p_scene_id uuid, p_revision integer, p_patch jsonb) returns nomad_sceneflow.scenes
language plpgsql security definer set search_path = ''
as $$
declare v_sb_id uuid; v_sb nomad_sceneflow.storyboards; v_old nomad_sceneflow.scenes; v_row nomad_sceneflow.scenes;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'save_scene: patch must be an object' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_patch) as k(key)
             where k.key not in ('chapter', 'duration_ms', 'narration', 'on_screen_text', 'visual_prompt', 'motion_preset', 'music_cue', 'sources',
                                 'focus_x', 'focus_y', 'transition', 'transition_ms', 'caption_emphasis', 'clip_in_ms', 'clip_out_ms', 'cut_ranges')) then
    raise exception 'save_scene: unknown key in patch' using errcode = '22023';
  end if;
  if p_patch ? 'caption_emphasis' and jsonb_typeof(p_patch -> 'caption_emphasis') <> 'array' then
    raise exception 'save_scene: caption_emphasis must be an array' using errcode = '22023';
  end if;
  select storyboard_id into v_sb_id from nomad_sceneflow.scenes where id = p_scene_id;
  if v_sb_id is null then raise exception 'save_scene: scene not found' using errcode = 'P0002'; end if;
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(v_sb_id, 'save_scene');
  select * into v_old from nomad_sceneflow.scenes where id = p_scene_id for update;
  if v_old.revision is distinct from p_revision then
    raise exception 'save_scene: revision conflict (current %)', v_old.revision using errcode = 'VD409';
  end if;
  update nomad_sceneflow.scenes s
     set chapter          = case when p_patch ? 'chapter'          then p_patch ->> 'chapter'                  else s.chapter end,
         duration_ms      = case when p_patch ? 'duration_ms'      then (p_patch ->> 'duration_ms')::integer   else s.duration_ms end,
         narration        = case when p_patch ? 'narration'        then p_patch ->> 'narration'                else s.narration end,
         on_screen_text   = case when p_patch ? 'on_screen_text'   then p_patch ->> 'on_screen_text'           else s.on_screen_text end,
         visual_prompt    = case when p_patch ? 'visual_prompt'    then p_patch ->> 'visual_prompt'            else s.visual_prompt end,
         motion_preset    = case when p_patch ? 'motion_preset'    then p_patch ->> 'motion_preset'            else s.motion_preset end,
         music_cue        = case when p_patch ? 'music_cue'        then p_patch ->> 'music_cue'                else s.music_cue end,
         sources          = case when p_patch ? 'sources'          then p_patch -> 'sources'                   else s.sources end,
         focus_x          = case when p_patch ? 'focus_x'          then (p_patch ->> 'focus_x')::numeric       else s.focus_x end,
         focus_y          = case when p_patch ? 'focus_y'          then (p_patch ->> 'focus_y')::numeric       else s.focus_y end,
         transition       = case when p_patch ? 'transition'       then p_patch ->> 'transition'               else s.transition end,
         transition_ms    = case when p_patch ? 'transition_ms'    then (p_patch ->> 'transition_ms')::integer else s.transition_ms end,
         caption_emphasis = case when p_patch ? 'caption_emphasis'
                                 then coalesce((select array_agg(x) from jsonb_array_elements_text(p_patch -> 'caption_emphasis') as e(x)), '{}'::text[])
                                 else s.caption_emphasis end,
         clip_in_ms       = case when p_patch ? 'clip_in_ms'       then (p_patch ->> 'clip_in_ms')::integer    else s.clip_in_ms end,
         clip_out_ms      = case when p_patch ? 'clip_out_ms'      then (p_patch ->> 'clip_out_ms')::integer   else s.clip_out_ms end,
         cut_ranges       = case when p_patch ? 'cut_ranges'       then p_patch -> 'cut_ranges'                else s.cut_ranges end
   where s.id = p_scene_id returning * into v_row;
  if v_row.narration is distinct from v_old.narration then
    update nomad_sceneflow.scene_assets set status = 'superseded' where scene_id = p_scene_id and kind = 'narration' and status = 'ready';
  end if;
  if v_sb.status = 'rendered' then
    update nomad_sceneflow.storyboards set status = 'ready' where id = v_sb.id;
  end if;
  return v_row;
end;
$$;

-- 장면 순서 변경(스토리보드 장면 id 전부). revision +1.
create function nomad_sceneflow.reorder_scenes(p_storyboard_id uuid, p_scene_ids uuid[], p_revision integer) returns nomad_sceneflow.storyboards
language plpgsql security definer set search_path = ''
as $$
declare v_sb nomad_sceneflow.storyboards; v_count integer;
begin
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(p_storyboard_id, 'reorder_scenes', p_revision, true);
  select count(*) into v_count from nomad_sceneflow.scenes s where s.storyboard_id = p_storyboard_id;
  if v_count = 0 or coalesce(cardinality(p_scene_ids), 0) <> v_count
     or (select count(distinct x) from unnest(p_scene_ids) as u(x)) <> v_count
     or exists (select 1 from unnest(p_scene_ids) as u(x)
                where not exists (select 1 from nomad_sceneflow.scenes s where s.id = u.x and s.storyboard_id = p_storyboard_id)) then
    raise exception 'reorder_scenes: id list does not match the storyboard scenes' using errcode = '22023';
  end if;
  update nomad_sceneflow.scenes s set ord = o.n::integer
    from unnest(p_scene_ids) with ordinality as o(id, n)
   where s.id = o.id and s.storyboard_id = p_storyboard_id and s.ord <> o.n;
  update nomad_sceneflow.storyboards set revision = revision + 1, status = case when status = 'rendered' then 'ready' else status end
   where id = p_storyboard_id returning * into v_sb;
  return v_sb;
end;
$$;

-- 장면 추가(장면 수 상한 VD018). 챕터는 앞 장면 값을 잇는다.
create function nomad_sceneflow.add_scene(p_storyboard_id uuid, p_revision integer, p_ord integer default null,
                                          p_kind text default 'image', p_duration_ms integer default 6000) returns nomad_sceneflow.scenes
language plpgsql security definer set search_path = ''
as $$
declare v_sb nomad_sceneflow.storyboards; v_count integer; v_max integer; v_ord integer; v_chapter text; v_row nomad_sceneflow.scenes;
begin
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(p_storyboard_id, 'add_scene', p_revision, true);
  select count(*) into v_count from nomad_sceneflow.scenes where storyboard_id = p_storyboard_id;
  select l.max_scenes into v_max from nomad_sceneflow_private.scene_count_limits(v_sb.format, v_sb.target_seconds) as l;
  if v_count >= v_max then raise exception 'add_scene: scene limit % reached', v_max using errcode = 'VD018'; end if;
  v_ord := coalesce(p_ord, v_count + 1);
  if v_ord < 1 or v_ord > v_count + 1 then raise exception 'add_scene: position out of range' using errcode = '22023'; end if;
  select chapter into v_chapter from nomad_sceneflow.scenes where storyboard_id = p_storyboard_id and ord = v_ord - 1;
  update nomad_sceneflow.scenes set ord = ord + 1 where storyboard_id = p_storyboard_id and ord >= v_ord;
  insert into nomad_sceneflow.scenes (organization_id, storyboard_id, ord, chapter, kind, duration_ms)
  values (v_sb.organization_id, p_storyboard_id, v_ord, v_chapter, coalesce(p_kind, 'image'), coalesce(p_duration_ms, 6000))
  returning * into v_row;
  update nomad_sceneflow.storyboards set revision = revision + 1, status = case when status = 'rendered' then 'ready' else status end
   where id = p_storyboard_id;
  return v_row;
end;
$$;

-- 장면 삭제. 그 장면을 포함한 렌더 전(proposed/failed) 쇼츠 컷도 지운다.
create function nomad_sceneflow.delete_scene(p_scene_id uuid, p_revision integer, p_scene_revision integer default null) returns nomad_sceneflow.storyboards
language plpgsql security definer set search_path = ''
as $$
declare v_sb_id uuid; v_sb nomad_sceneflow.storyboards; v_old nomad_sceneflow.scenes;
begin
  select storyboard_id into v_sb_id from nomad_sceneflow.scenes where id = p_scene_id;
  if v_sb_id is null then raise exception 'delete_scene: scene not found' using errcode = 'P0002'; end if;
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(v_sb_id, 'delete_scene', p_revision, true);
  select * into v_old from nomad_sceneflow.scenes where id = p_scene_id for update;
  if p_scene_revision is not null and v_old.revision is distinct from p_scene_revision then
    raise exception 'delete_scene: revision conflict (current %)', v_old.revision using errcode = 'VD409';
  end if;
  delete from nomad_sceneflow.storyboard_cuts c
   where c.storyboard_id = v_sb_id and c.kind = 'short' and c.status in ('proposed', 'failed') and p_scene_id = any (c.scene_ids);
  delete from nomad_sceneflow.scenes where id = p_scene_id;
  update nomad_sceneflow.scenes set ord = ord - 1 where storyboard_id = v_sb_id and ord > v_old.ord;
  update nomad_sceneflow.storyboards set revision = revision + 1, status = case when status = 'rendered' then 'ready' else status end
   where id = v_sb_id returning * into v_sb;
  return v_sb;
end;
$$;

-- 쇼츠 후보 표시(revision 을 올리지 않는다)
create function nomad_sceneflow.set_shorts_candidate(p_scene_id uuid, p_value boolean) returns nomad_sceneflow.scenes
language plpgsql security definer set search_path = ''
as $$
declare v_sb_id uuid; v_sb nomad_sceneflow.storyboards; v_row nomad_sceneflow.scenes;
begin
  if p_value is null then raise exception 'set_shorts_candidate: value required' using errcode = '22023'; end if;
  select storyboard_id into v_sb_id from nomad_sceneflow.scenes where id = p_scene_id;
  if v_sb_id is null then raise exception 'set_shorts_candidate: scene not found' using errcode = 'P0002'; end if;
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(v_sb_id, 'set_shorts_candidate');
  update nomad_sceneflow.scenes set shorts_candidate = p_value where id = p_scene_id returning * into v_row;
  return v_row;
end;
$$;

-- AI 편집안 적용(ai_edit). regenerate 명령은 적용하지 않고 돌려준다(서버가 선차감 후 잡). 하나라도 실패하면 전체 롤백.
create function nomad_sceneflow.apply_edit_plan(p_plan_id uuid, p_command_ids integer[] default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_plan nomad_sceneflow.edit_plans; v_sb nomad_sceneflow.storyboards; v_cmd jsonb; v_args jsonb; v_op text; v_scene nomad_sceneflow.scenes;
  v_sid uuid; v_order uuid[]; v_pos integer; v_count integer; v_max integer; v_struct boolean := false; v_applied integer[] := '{}';
  v_pending jsonb := '[]'::jsonb; v_deleted jsonb := '[]'::jsonb; v_added uuid[] := '{}'; v_cuts uuid[] := '{}'; v_supers uuid[] := '{}';
  v_undo jsonb; v_new_id uuid; v_ord integer; v_chapter text; v_fp text;
begin
  select * into v_plan from nomad_sceneflow.edit_plans where id = p_plan_id for update;
  if not found then raise exception 'apply_edit_plan: plan not found' using errcode = 'P0002'; end if;
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(v_plan.storyboard_id, 'apply_edit_plan');
  if not nomad_sceneflow_private.feat(v_sb.organization_id, 'ai_edit') then
    raise exception 'apply_edit_plan: plan does not include ai edit' using errcode = 'VD009';
  end if;
  if v_plan.status <> 'proposed' then raise exception 'apply_edit_plan: plan is %', v_plan.status using errcode = 'VD005'; end if;
  if nomad_sceneflow_private.storyboard_fingerprint(v_sb.id) is distinct from v_plan.base_fingerprint then
    raise exception 'apply_edit_plan: storyboard changed since the plan was made' using errcode = 'VD409';
  end if;
  if not nomad_sceneflow_private.valid_edit_commands(v_plan.commands) then
    raise exception 'apply_edit_plan: commands are not in the allow list' using errcode = 'VD023';
  end if;
  if p_command_ids is not null and exists (
       select 1 from unnest(p_command_ids) as u(x)
       where not exists (select 1 from jsonb_array_elements(v_plan.commands) as e(c) where (e.c ->> 'id')::integer = u.x)) then
    raise exception 'apply_edit_plan: unknown command id' using errcode = '22023';
  end if;
  v_undo := jsonb_build_object(
    'storyboard', jsonb_build_object('aspect', v_sb.aspect, 'resolution', v_sb.resolution, 'fps', v_sb.fps, 'shorts_aspect', v_sb.shorts_aspect,
                                     'caption_style', v_sb.caption_style, 'caption_hanja', v_sb.caption_hanja,
                                     'bgm_level_db', v_sb.bgm_level_db, 'loudnorm', v_sb.loudnorm),
    'scenes', coalesce((select jsonb_agg(to_jsonb(s) order by s.ord) from nomad_sceneflow.scenes s where s.storyboard_id = v_sb.id), '[]'::jsonb));

  for v_cmd in
    select e.c from jsonb_array_elements(v_plan.commands) as e(c)
    where p_command_ids is null or (e.c ->> 'id')::integer = any (p_command_ids)
    order by (e.c ->> 'id')::integer
  loop
    v_op := v_cmd ->> 'op';
    v_args := coalesce(v_cmd -> 'args', '{}'::jsonb);
    v_sid := nullif(v_cmd ->> 'scene_id', '')::uuid;
    if v_sid is not null then
      select * into v_scene from nomad_sceneflow.scenes where id = v_sid and storyboard_id = v_sb.id for update;
      if not found then
        raise exception 'apply_edit_plan: command % targets a scene outside the storyboard', v_cmd ->> 'id' using errcode = 'VD023';
      end if;
    end if;
    if v_op = 'regenerate' then
      v_pending := v_pending || jsonb_build_array(v_cmd);
      continue;
    elsif v_op = 'set_duration' then
      update nomad_sceneflow.scenes set duration_ms = (v_args ->> 'duration_ms')::integer where id = v_sid;
    elsif v_op = 'move_scene' then
      select array_agg(id order by ord) into v_order from nomad_sceneflow.scenes where storyboard_id = v_sb.id;
      v_pos := greatest(1, least(cardinality(v_order), (v_args ->> 'to_ord')::integer));
      v_order := array_remove(v_order, v_sid);
      v_order := v_order[1:v_pos - 1] || v_sid || v_order[v_pos:];
      update nomad_sceneflow.scenes s set ord = o.n::integer from unnest(v_order) with ordinality as o(id, n) where s.id = o.id and s.ord <> o.n;
      v_struct := true;
    elsif v_op = 'delete_scene' then
      select count(*) into v_count from nomad_sceneflow.scenes where storyboard_id = v_sb.id;
      if v_count <= 1 then raise exception 'apply_edit_plan: cannot delete the last scene' using errcode = '22023'; end if;
      v_deleted := v_deleted || coalesce((select jsonb_agg(to_jsonb(a)) from nomad_sceneflow.scene_assets a where a.scene_id = v_sid), '[]'::jsonb);
      delete from nomad_sceneflow.storyboard_cuts c
       where c.storyboard_id = v_sb.id and c.kind = 'short' and c.status in ('proposed', 'failed') and v_sid = any (c.scene_ids);
      delete from nomad_sceneflow.scenes where id = v_sid;
      update nomad_sceneflow.scenes set ord = ord - 1 where storyboard_id = v_sb.id and ord > v_scene.ord;
      v_struct := true;
    elsif v_op = 'add_scene' then
      select count(*) into v_count from nomad_sceneflow.scenes where storyboard_id = v_sb.id;
      select l.max_scenes into v_max from nomad_sceneflow_private.scene_count_limits(v_sb.format, v_sb.target_seconds) as l;
      if v_count >= v_max then raise exception 'apply_edit_plan: scene limit % reached', v_max using errcode = 'VD018'; end if;
      v_ord := least(v_count, greatest(0, coalesce((v_args ->> 'after_ord')::integer, v_count))) + 1;
      select chapter into v_chapter from nomad_sceneflow.scenes where storyboard_id = v_sb.id and ord = v_ord - 1;
      update nomad_sceneflow.scenes set ord = ord + 1 where storyboard_id = v_sb.id and ord >= v_ord;
      insert into nomad_sceneflow.scenes (organization_id, storyboard_id, ord, chapter, kind, duration_ms, on_screen_text, visual_prompt, narration)
      values (v_sb.organization_id, v_sb.id, v_ord, v_chapter, coalesce(v_args ->> 'kind', 'image'), coalesce((v_args ->> 'duration_ms')::integer, 6000),
              v_args ->> 'on_screen_text', v_args ->> 'visual_prompt', v_args ->> 'narration')
      returning id into v_new_id;
      v_added := v_added || v_new_id;
      v_struct := true;
    elsif v_op = 'set_text' then
      if coalesce(v_args ->> 'field', '') not in ('narration', 'on_screen_text', 'visual_prompt', 'chapter') then
        raise exception 'apply_edit_plan: set_text field not allowed' using errcode = 'VD023';
      end if;
      update nomad_sceneflow.scenes s
         set narration      = case when v_args ->> 'field' = 'narration'      then v_args ->> 'value' else s.narration end,
             on_screen_text = case when v_args ->> 'field' = 'on_screen_text' then v_args ->> 'value' else s.on_screen_text end,
             visual_prompt  = case when v_args ->> 'field' = 'visual_prompt'  then v_args ->> 'value' else s.visual_prompt end,
             chapter        = case when v_args ->> 'field' = 'chapter'        then v_args ->> 'value' else s.chapter end
       where s.id = v_sid;
      if v_args ->> 'field' = 'narration' and (v_args ->> 'value') is distinct from v_scene.narration then
        v_supers := v_supers || coalesce((select array_agg(a.id) from nomad_sceneflow.scene_assets a
                                           where a.scene_id = v_sid and a.kind = 'narration' and a.status = 'ready'), '{}'::uuid[]);
        update nomad_sceneflow.scene_assets set status = 'superseded' where scene_id = v_sid and kind = 'narration' and status = 'ready';
      end if;
    elsif v_op = 'set_motion' then
      update nomad_sceneflow.scenes set motion_preset = v_args ->> 'preset' where id = v_sid;
    elsif v_op = 'set_transition' then
      update nomad_sceneflow.scenes set transition = v_args ->> 'name', transition_ms = coalesce((v_args ->> 'ms')::integer, 0) where id = v_sid;
    elsif v_op = 'set_focus' then
      update nomad_sceneflow.scenes set focus_x = (v_args ->> 'x')::numeric, focus_y = (v_args ->> 'y')::numeric where id = v_sid;
    elsif v_op = 'set_music_cue' then
      update nomad_sceneflow.scenes set music_cue = v_args ->> 'cue' where id = v_sid;
    elsif v_op = 'set_caption_emphasis' then
      update nomad_sceneflow.scenes
         set caption_emphasis = coalesce((select array_agg(x) from jsonb_array_elements_text(v_args -> 'words') as e(x)), '{}'::text[])
       where id = v_sid;
    elsif v_op = 'set_clip_trim' then
      update nomad_sceneflow.scenes set clip_in_ms = (v_args ->> 'in_ms')::integer, clip_out_ms = (v_args ->> 'out_ms')::integer where id = v_sid;
    elsif v_op = 'remove_ranges' then
      update nomad_sceneflow.scenes set cut_ranges = coalesce(v_args -> 'ranges', '[]'::jsonb) where id = v_sid;
    elsif v_op = 'set_shorts_candidate' then
      if v_sb.format <> 'longform' then raise exception 'apply_edit_plan: shorts candidates are for longform' using errcode = 'VD023'; end if;
      update nomad_sceneflow.scenes set shorts_candidate = coalesce((v_args ->> 'value')::boolean, true) where id = v_sid;
    elsif v_op = 'propose_short' then
      if v_sb.format <> 'longform' then raise exception 'apply_edit_plan: shorts are cut from longform' using errcode = 'VD023'; end if;
      select min(n) into v_ord from generate_series(1, 10) as g(n)
       where not exists (select 1 from nomad_sceneflow.storyboard_cuts c where c.storyboard_id = v_sb.id and c.kind = 'short' and c.ord = g.n);
      insert into nomad_sceneflow.storyboard_cuts (organization_id, storyboard_id, kind, aspect, scene_ids, hook_text, status, ord)
      values (v_sb.organization_id, v_sb.id, 'short', v_sb.shorts_aspect,
              (select array_agg(x::uuid) from jsonb_array_elements_text(v_args -> 'scene_ids') as e(x)),
              v_args ->> 'hook_text', 'proposed', coalesce(v_ord, 11))
      returning id into v_new_id;
      v_cuts := v_cuts || v_new_id;
    elsif v_op = 'set_render' then
      update nomad_sceneflow.storyboards b
         set aspect = coalesce(v_args ->> 'aspect', b.aspect), resolution = coalesce(v_args ->> 'resolution', b.resolution),
             fps = coalesce((v_args ->> 'fps')::smallint, b.fps), shorts_aspect = coalesce(v_args ->> 'shorts_aspect', b.shorts_aspect)
       where b.id = v_sb.id;
    elsif v_op = 'set_style' then
      update nomad_sceneflow.storyboards b
         set caption_style = coalesce(v_args ->> 'caption_style', b.caption_style),
             caption_hanja = coalesce((v_args ->> 'caption_hanja')::boolean, b.caption_hanja),
             bgm_level_db = coalesce((v_args ->> 'bgm_level_db')::smallint, b.bgm_level_db),
             loudnorm = coalesce((v_args ->> 'loudnorm')::boolean, b.loudnorm)
       where b.id = v_sb.id;
    end if;
    v_applied := v_applied || (v_cmd ->> 'id')::integer;
  end loop;

  update nomad_sceneflow.storyboards b
     set revision = case when v_struct then b.revision + 1 else b.revision end,
         status = case when b.status = 'rendered' and cardinality(v_applied) > 0 then 'ready' else b.status end
   where b.id = v_sb.id returning * into v_sb;
  v_fp := nomad_sceneflow_private.storyboard_fingerprint(v_sb.id);
  v_undo := v_undo || jsonb_build_object('deleted_assets', v_deleted, 'added_scene_ids', to_jsonb(v_added),
                                         'added_cut_ids', to_jsonb(v_cuts), 'superseded_asset_ids', to_jsonb(v_supers));
  update nomad_sceneflow.edit_plans
     set status = 'applied', applied_command_ids = v_applied, undo_state = v_undo, after_fingerprint = v_fp, applied_by = auth.uid(), applied_at = now()
   where id = p_plan_id;
  perform nomad_core.write_audit(v_sb.organization_id, 'sceneflow.storyboard.edit_plan.apply', 'storyboard', v_sb.id::text, null, null,
                                 jsonb_build_object('plan_id', p_plan_id, 'source', v_plan.source, 'applied', to_jsonb(v_applied),
                                                    'pending_regenerate', jsonb_array_length(v_pending)));
  return jsonb_build_object('plan_id', p_plan_id, 'applied', to_jsonb(v_applied), 'pending_regenerate', v_pending,
                            'storyboard_revision', v_sb.revision, 'fingerprint', v_fp);
end;
$$;

-- 편집안 되돌리기: 가장 최근 적용안만, 적용 뒤 상태 그대로일 때만(VD409)
create function nomad_sceneflow.undo_edit_plan(p_plan_id uuid) returns nomad_sceneflow.storyboards
language plpgsql security definer set search_path = ''
as $$
declare v_plan nomad_sceneflow.edit_plans; v_sb nomad_sceneflow.storyboards; v_undo jsonb; v_rec jsonb;
        v_s nomad_sceneflow.scenes; v_a nomad_sceneflow.scene_assets; v_aid uuid;
begin
  select * into v_plan from nomad_sceneflow.edit_plans where id = p_plan_id for update;
  if not found then raise exception 'undo_edit_plan: plan not found' using errcode = 'P0002'; end if;
  v_sb := nomad_sceneflow_private.lock_storyboard_for_edit(v_plan.storyboard_id, 'undo_edit_plan');
  if v_plan.status <> 'applied' then raise exception 'undo_edit_plan: plan is %', v_plan.status using errcode = 'VD005'; end if;
  if exists (select 1 from nomad_sceneflow.edit_plans p where p.storyboard_id = v_plan.storyboard_id and p.status = 'applied' and p.applied_at > v_plan.applied_at) then
    raise exception 'undo_edit_plan: undo the later plan first' using errcode = 'VD409';
  end if;
  if nomad_sceneflow_private.storyboard_fingerprint(v_sb.id) is distinct from v_plan.after_fingerprint then
    raise exception 'undo_edit_plan: storyboard changed after the plan was applied' using errcode = 'VD409';
  end if;
  v_undo := v_plan.undo_state;
  delete from nomad_sceneflow.storyboard_cuts c
   where c.id in (select x::uuid from jsonb_array_elements_text(coalesce(v_undo -> 'added_cut_ids', '[]')) as e(x)) and c.status = 'proposed';
  delete from nomad_sceneflow.scenes s
   where s.id in (select x::uuid from jsonb_array_elements_text(coalesce(v_undo -> 'added_scene_ids', '[]')) as e(x));
  for v_rec in select e.x from jsonb_array_elements(coalesce(v_undo -> 'scenes', '[]')) as e(x) loop
    v_s := jsonb_populate_record(null::nomad_sceneflow.scenes, v_rec);
    if exists (select 1 from nomad_sceneflow.scenes where id = v_s.id) then
      update nomad_sceneflow.scenes s
         set ord = v_s.ord, chapter = v_s.chapter, kind = v_s.kind, duration_ms = v_s.duration_ms, narration = v_s.narration,
             on_screen_text = v_s.on_screen_text, visual_prompt = v_s.visual_prompt, motion_preset = v_s.motion_preset, music_cue = v_s.music_cue,
             shorts_candidate = v_s.shorts_candidate, sources = v_s.sources, source_required = v_s.source_required, focus_x = v_s.focus_x,
             focus_y = v_s.focus_y, transition = v_s.transition, transition_ms = v_s.transition_ms, clip_in_ms = v_s.clip_in_ms,
             clip_out_ms = v_s.clip_out_ms, cut_ranges = v_s.cut_ranges, caption_emphasis = v_s.caption_emphasis
       where s.id = v_s.id;
    else
      insert into nomad_sceneflow.scenes select v_s.*;
    end if;
  end loop;
  for v_rec in select e.x from jsonb_array_elements(coalesce(v_undo -> 'deleted_assets', '[]')) as e(x) loop
    v_a := jsonb_populate_record(null::nomad_sceneflow.scene_assets, v_rec);
    if not exists (select 1 from nomad_sceneflow.scene_assets where id = v_a.id) then
      insert into nomad_sceneflow.scene_assets select v_a.*;
    end if;
  end loop;
  for v_aid in select x::uuid from jsonb_array_elements_text(coalesce(v_undo -> 'superseded_asset_ids', '[]')) as e(x) loop
    select * into v_a from nomad_sceneflow.scene_assets where id = v_aid;
    if found and v_a.status = 'superseded' then
      update nomad_sceneflow.scene_assets set status = 'superseded'
       where scene_id = v_a.scene_id and kind = v_a.kind and coalesce(lang, '') = coalesce(v_a.lang, '')
         and coalesce(aspect, '') = coalesce(v_a.aspect, '') and status = 'ready';
      update nomad_sceneflow.scene_assets set status = 'ready' where id = v_aid;
    end if;
  end loop;
  update nomad_sceneflow.storyboards b
     set aspect = v_undo -> 'storyboard' ->> 'aspect', resolution = v_undo -> 'storyboard' ->> 'resolution',
         fps = (v_undo -> 'storyboard' ->> 'fps')::smallint, shorts_aspect = v_undo -> 'storyboard' ->> 'shorts_aspect',
         caption_style = v_undo -> 'storyboard' ->> 'caption_style', caption_hanja = (v_undo -> 'storyboard' ->> 'caption_hanja')::boolean,
         bgm_level_db = (v_undo -> 'storyboard' ->> 'bgm_level_db')::smallint, loudnorm = (v_undo -> 'storyboard' ->> 'loudnorm')::boolean,
         revision = b.revision + 1, status = case when b.status = 'rendered' then 'ready' else b.status end
   where b.id = v_sb.id returning * into v_sb;
  update nomad_sceneflow.edit_plans set status = 'undone', undone_at = now() where id = p_plan_id;
  perform nomad_core.write_audit(v_sb.organization_id, 'sceneflow.storyboard.edit_plan.undo', 'storyboard', v_sb.id::text, null, null,
                                 jsonb_build_object('plan_id', p_plan_id));
  return v_sb;
end;
$$;

-- 편집안 거절(proposed → rejected). 크레딧은 편집안 생성 때 이미 정산(환불 없음).
create function nomad_sceneflow.reject_edit_plan(p_plan_id uuid) returns nomad_sceneflow.edit_plans
language plpgsql security definer set search_path = ''
as $$
declare v_plan nomad_sceneflow.edit_plans;
begin
  select * into v_plan from nomad_sceneflow.edit_plans where id = p_plan_id for update;
  if not found then raise exception 'reject_edit_plan: plan not found' using errcode = 'P0002'; end if;
  perform nomad_sceneflow_private.require_role(v_plan.organization_id, false, 'reject_edit_plan');
  if v_plan.status <> 'proposed' then raise exception 'reject_edit_plan: plan is %', v_plan.status using errcode = 'VD005'; end if;
  update nomad_sceneflow.edit_plans set status = 'rejected' where id = p_plan_id returning * into v_plan;
  return v_plan;
end;
$$;

-- ---------- 8. 서버 RPC (service_role 전용, nomad_core.is_service_caller) ----------
-- 고객 승인 요청 열기(agency). Route Handler 가 토큰을 만들고 해시만 넘긴다. approved → client_review, 이전 pending 은 canceled.
create function nomad_sceneflow.open_client_review(p_upload_id uuid, p_token_hash text, p_expires_at timestamptz, p_requested_by uuid default null)
returns nomad_sceneflow.client_reviews
language plpgsql security definer set search_path = ''
as $$
declare v_up nomad_sceneflow.uploads; v_client uuid; v_row nomad_sceneflow.client_reviews;
begin
  if not nomad_core.is_service_caller() then raise exception 'open_client_review: server only' using errcode = '42501'; end if;
  select * into v_up from nomad_sceneflow.uploads where id = p_upload_id for update;
  if not found then raise exception 'open_client_review: upload not found' using errcode = 'P0002'; end if;
  if not nomad_sceneflow_private.feat(v_up.organization_id, 'agency') then
    raise exception 'open_client_review: plan does not include agency' using errcode = 'VD009';
  end if;
  if v_up.status not in ('approved', 'client_review') then
    raise exception 'open_client_review: invalid state %', v_up.status using errcode = 'VD008';
  end if;
  select cc.client_id into v_client from nomad_sceneflow.client_channels cc where cc.channel_id = v_up.channel_id;
  if v_client is null then raise exception 'open_client_review: channel is not linked to a client' using errcode = 'VD016'; end if;
  if p_expires_at is null or p_expires_at <= now() or p_expires_at > now() + interval '14 days' then
    raise exception 'open_client_review: expires_at must be within 14 days' using errcode = '22023';
  end if;
  update nomad_sceneflow.client_reviews set decision = 'canceled' where upload_id = p_upload_id and decision = 'pending';
  insert into nomad_sceneflow.client_reviews (organization_id, client_id, upload_id, token_hash, expires_at, requested_by)
  values (v_up.organization_id, v_client, p_upload_id, p_token_hash, p_expires_at, p_requested_by) returning * into v_row;
  if v_up.status = 'approved' then
    update nomad_sceneflow.uploads set status = 'client_review' where id = p_upload_id;
  end if;
  perform nomad_core.write_audit(v_up.organization_id, 'sceneflow.upload.client_review_open', 'upload', p_upload_id::text, null, null,
                                 jsonb_build_object('review_id', v_row.id, 'expires_at', p_expires_at));
  return v_row;
end;
$$;

-- 고객 결정 기록. 만료면 expired 로 닫아 돌려준다. 수정 요청 → 업로드 draft.
create function nomad_sceneflow.decide_client_review(p_token_hash text, p_decision text, p_reviewer_name text default null, p_comment text default null)
returns nomad_sceneflow.client_reviews
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_sceneflow.client_reviews;
begin
  if not nomad_core.is_service_caller() then raise exception 'decide_client_review: server only' using errcode = '42501'; end if;
  select * into v_row from nomad_sceneflow.client_reviews where token_hash = p_token_hash for update;
  if not found then raise exception 'decide_client_review: review not found' using errcode = 'P0002'; end if;
  if v_row.decision <> 'pending' then raise exception 'decide_client_review: already %', v_row.decision using errcode = 'VD008'; end if;
  if v_row.expires_at <= now() then
    update nomad_sceneflow.client_reviews set decision = 'expired' where id = v_row.id returning * into v_row;
    return v_row;
  end if;
  if p_decision is null or p_decision not in ('approved', 'changes_requested') then
    raise exception 'decide_client_review: invalid decision %', p_decision using errcode = '22023';
  end if;
  update nomad_sceneflow.client_reviews set decision = p_decision, reviewer_name = p_reviewer_name, comment = p_comment, decided_at = now()
   where id = v_row.id returning * into v_row;
  if p_decision = 'changes_requested' then
    update nomad_sceneflow.uploads set status = 'draft' where id = v_row.upload_id and status = 'client_review';
  end if;
  perform nomad_core.write_audit(v_row.organization_id, 'sceneflow.upload.client_review_decide', 'upload', v_row.upload_id::text, null, null,
                                 jsonb_build_object('review_id', v_row.id, 'decision', p_decision));
  return v_row;
end;
$$;

-- 원본 보존 정책: ready 원본 중 purge_after 지난 행 → purged, Storage 경로 반환(워커가 객체 삭제)
create function nomad_sceneflow.purge_expired_sources(p_limit integer default 500)
returns table (source_id uuid, organization_id uuid, storage_path text)
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then raise exception 'purge_expired_sources: server only' using errcode = '42501'; end if;
  return query
  with c as (
    select s.id from nomad_sceneflow.sources s where s.status = 'ready' and s.purge_after <= now()
    order by s.purge_after limit greatest(coalesce(p_limit, 500), 1) for update skip locked)
  update nomad_sceneflow.sources s set status = 'purged', purged_at = now() from c where s.id = c.id
  returning s.id, s.organization_id, s.storage_path;
end;
$$;

-- YouTube 일일 쿼터 리셋(스케줄러)
create function nomad_sceneflow.reset_channel_quotas() returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_cnt integer;
begin
  if not nomad_core.is_service_caller() then raise exception 'reset_channel_quotas: server only' using errcode = '42501'; end if;
  update nomad_sceneflow.channels set quota_used_today = 0, quota_reset_at = now() where platform = 'youtube' and quota_used_today > 0;
  get diagnostics v_cnt = row_count;
  return v_cnt;
end;
$$;

-- 랜딩 조회수 +1(공개 라우트가 앞단 요청 제한 뒤 service_role 로 호출). 잠긴 조직 랜딩은 세지 않는다.
create function nomad_sceneflow.record_landing_view(p_slug text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then raise exception 'record_landing_view: server only' using errcode = '42501'; end if;
  update nomad_sceneflow.landing_pages l set view_count = l.view_count + 1
   where l.slug = p_slug and l.status = 'published' and nomad_sceneflow_private.feat(l.organization_id, 'coupang_landing');
end;
$$;

-- 그래프 결과 반영(draft 에서만, 장면 수 VD018·길이 합계 ±10% VD017) → ready, revision + 1
create function nomad_sceneflow.apply_storyboard_result(p_storyboard_id uuid, p_scenes jsonb, p_ai_run_id uuid default null)
returns nomad_sceneflow.storyboards
language plpgsql security definer set search_path = ''
as $$
declare v_sb nomad_sceneflow.storyboards; v_default integer; v_n integer; v_min integer; v_max integer; v_sum bigint;
begin
  if not nomad_core.is_service_caller() then raise exception 'apply_storyboard_result: server only' using errcode = '42501'; end if;
  select * into v_sb from nomad_sceneflow.storyboards where id = p_storyboard_id for update;
  if not found then raise exception 'apply_storyboard_result: storyboard not found' using errcode = 'P0002'; end if;
  if not nomad_sceneflow_private.feat(v_sb.organization_id, 'storyboard') then
    raise exception 'apply_storyboard_result: plan does not include storyboards' using errcode = 'VD009';
  end if;
  if v_sb.status <> 'draft' then raise exception 'apply_storyboard_result: storyboard is %', v_sb.status using errcode = 'VD005'; end if;
  if p_scenes is null or jsonb_typeof(p_scenes) <> 'array' then
    raise exception 'apply_storyboard_result: scenes must be an array' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_scenes) as e(item) where jsonb_typeof(e.item) <> 'object')
     or exists (select 1 from jsonb_array_elements(p_scenes) as e(item), jsonb_object_keys(e.item) as k(key)
                where k.key not in ('chapter', 'kind', 'duration_ms', 'narration', 'on_screen_text', 'visual_prompt',
                                    'motion_preset', 'music_cue', 'shorts_candidate', 'sources', 'source_required')) then
    raise exception 'apply_storyboard_result: unknown scene key' using errcode = '22023';
  end if;
  select default_scene_seconds * 1000 into v_default from nomad_sceneflow.storyboard_templates where code = v_sb.template_code;
  v_n := jsonb_array_length(p_scenes);
  select l.min_scenes, l.max_scenes into v_min, v_max from nomad_sceneflow_private.scene_count_limits(v_sb.format, v_sb.target_seconds) as l;
  if v_n < v_min or v_n > v_max then
    raise exception 'apply_storyboard_result: % scenes is outside % ~ %', v_n, v_min, v_max using errcode = 'VD018';
  end if;
  select sum(coalesce((e.item ->> 'duration_ms')::integer, v_default)) into v_sum from jsonb_array_elements(p_scenes) as e(item);
  if v_sum < v_sb.target_seconds * 900 or v_sum > v_sb.target_seconds * 1100 then
    raise exception 'apply_storyboard_result: total % ms is outside target % s ±10%%', v_sum, v_sb.target_seconds using errcode = 'VD017';
  end if;
  delete from nomad_sceneflow.storyboard_cuts where storyboard_id = p_storyboard_id and status in ('proposed', 'failed');
  delete from nomad_sceneflow.scenes where storyboard_id = p_storyboard_id;
  insert into nomad_sceneflow.scenes (organization_id, storyboard_id, ord, chapter, kind, duration_ms, narration, on_screen_text, visual_prompt,
                                      motion_preset, music_cue, shorts_candidate, sources, source_required)
  select v_sb.organization_id, p_storyboard_id, e.n::integer, e.item ->> 'chapter', coalesce(e.item ->> 'kind', 'image'),
         coalesce((e.item ->> 'duration_ms')::integer, v_default), e.item ->> 'narration', e.item ->> 'on_screen_text',
         e.item ->> 'visual_prompt', coalesce(e.item ->> 'motion_preset', 'static'), e.item ->> 'music_cue',
         coalesce((e.item ->> 'shorts_candidate')::boolean, false), coalesce(e.item -> 'sources', '[]'::jsonb),
         coalesce((e.item ->> 'source_required')::boolean, false)
  from jsonb_array_elements(p_scenes) with ordinality as e(item, n);
  update nomad_sceneflow.storyboards set status = 'ready', revision = revision + 1, root_job_id = null, last_error = null
   where id = p_storyboard_id returning * into v_sb;
  perform nomad_core.write_audit(v_sb.organization_id, 'sceneflow.storyboard.generate', 'storyboard', p_storyboard_id::text, null, null,
                                 jsonb_build_object('scenes', v_n, 'total_ms', v_sum, 'ai_run_id', p_ai_run_id));
  return v_sb;
end;
$$;

-- 장면 소재 기록. 같은 (장면, 종류, 언어, 화면비)의 이전 ready 는 superseded. clip 은 권리 근거·메모 필수(VD019).
create function nomad_sceneflow.finish_scene_asset(
  p_scene_id uuid, p_kind text, p_storage_path text, p_lang text default null, p_aspect text default null, p_ai_generated boolean default true,
  p_rights_basis text default null, p_rights_note text default null, p_reused_from_asset_id uuid default null, p_meta jsonb default '{}'::jsonb
) returns nomad_sceneflow.scene_assets
language plpgsql security definer set search_path = ''
as $$
declare v_scene nomad_sceneflow.scenes; v_src nomad_sceneflow.scene_assets; v_row nomad_sceneflow.scene_assets; v_aspect text;
begin
  if not nomad_core.is_service_caller() then raise exception 'finish_scene_asset: server only' using errcode = '42501'; end if;
  select * into v_scene from nomad_sceneflow.scenes where id = p_scene_id for update;
  if not found then raise exception 'finish_scene_asset: scene not found' using errcode = 'P0002'; end if;
  if p_kind is null or p_kind not in ('image', 'narration', 'clip') then
    raise exception 'finish_scene_asset: invalid kind %', p_kind using errcode = '22023';
  end if;
  if p_kind = 'clip' and (p_rights_basis is null or coalesce(length(btrim(p_rights_note)), 0) < 2) then
    raise exception 'finish_scene_asset: clip needs rights basis and note' using errcode = 'VD019';
  end if;
  if p_reused_from_asset_id is not null then
    select * into v_src from nomad_sceneflow.scene_assets where id = p_reused_from_asset_id and organization_id = v_scene.organization_id;
    if not found then raise exception 'finish_scene_asset: reused asset not found' using errcode = 'P0002'; end if;
  end if;
  v_aspect := coalesce(p_aspect, v_src.aspect);
  if p_kind = 'image' and v_aspect is null then
    select b.aspect into v_aspect from nomad_sceneflow.storyboards b where b.id = v_scene.storyboard_id;
  end if;
  update nomad_sceneflow.scene_assets set status = 'superseded'
   where scene_id = p_scene_id and kind = p_kind and lang is not distinct from p_lang and aspect is not distinct from v_aspect and status = 'ready';
  insert into nomad_sceneflow.scene_assets (organization_id, scene_id, kind, lang, aspect, storage_path, rights_basis, rights_note, ai_generated,
                                            reused_from_asset_id, meta)
  values (v_scene.organization_id, p_scene_id, p_kind, p_lang, v_aspect, coalesce(p_storage_path, v_src.storage_path), p_rights_basis, p_rights_note,
          case when p_reused_from_asset_id is not null then v_src.ai_generated else coalesce(p_ai_generated, true) end,
          p_reused_from_asset_id, coalesce(p_meta, '{}'::jsonb))
  returning * into v_row;
  return v_row;
end;
$$;

-- 렌더 스냅샷(원본 13.14 최종). p_cut_id null = 마스터 컷(없으면 만든다). 스냅샷 1행(version + 1), 컷 → rendering, 마스터면 스토리보드 → rendering.
create function nomad_sceneflow.snapshot_storyboard(p_storyboard_id uuid, p_cut_id uuid default null) returns nomad_sceneflow.storyboard_snapshots
language plpgsql security definer set search_path = ''
as $$
declare v_sb nomad_sceneflow.storyboards; v_cut nomad_sceneflow.storyboard_cuts; v_ids uuid[]; v_min integer; v_max integer; v_sum bigint;
        v_bad integer; v_version integer; v_dim record; v_snap jsonb; v_row nomad_sceneflow.storyboard_snapshots;
begin
  if not nomad_core.is_service_caller() then raise exception 'snapshot_storyboard: server only' using errcode = '42501'; end if;
  select * into v_sb from nomad_sceneflow.storyboards where id = p_storyboard_id for update;
  if not found then raise exception 'snapshot_storyboard: storyboard not found' using errcode = 'P0002'; end if;
  if not nomad_sceneflow_private.feat(v_sb.organization_id, 'storyboard') then
    raise exception 'snapshot_storyboard: plan does not include storyboards' using errcode = 'VD009';
  end if;
  if v_sb.status not in ('ready', 'rendered') or v_sb.deleted_at is not null then
    raise exception 'snapshot_storyboard: storyboard is %', v_sb.status using errcode = 'VD005';
  end if;
  if p_cut_id is not null then
    select * into v_cut from nomad_sceneflow.storyboard_cuts where id = p_cut_id and storyboard_id = p_storyboard_id for update;
    if not found then raise exception 'snapshot_storyboard: cut not found' using errcode = 'P0002'; end if;
  else
    select * into v_cut from nomad_sceneflow.storyboard_cuts where storyboard_id = p_storyboard_id and kind = 'master' for update;
  end if;
  if v_cut.id is not null and v_cut.status = 'rendering' then
    raise exception 'snapshot_storyboard: cut is already rendering' using errcode = 'VD020';
  end if;

  if v_cut.id is null or v_cut.kind in ('master', 'variant') then
    select array_agg(s.id order by s.ord), sum(s.duration_ms) into v_ids, v_sum from nomad_sceneflow.scenes s where s.storyboard_id = p_storyboard_id;
    select l.min_scenes, l.max_scenes into v_min, v_max from nomad_sceneflow_private.scene_count_limits(v_sb.format, v_sb.target_seconds) as l;
    if coalesce(cardinality(v_ids), 0) < v_min or coalesce(cardinality(v_ids), 0) > v_max then
      raise exception 'snapshot_storyboard: % scenes is outside % ~ %', coalesce(cardinality(v_ids), 0), v_min, v_max using errcode = 'VD018';
    end if;
    if v_sum < v_sb.target_seconds * 900 or v_sum > v_sb.target_seconds * 1100 then
      raise exception 'snapshot_storyboard: total % ms is outside target % s ±10%%', v_sum, v_sb.target_seconds using errcode = 'VD017';
    end if;
    if v_cut.id is null then
      insert into nomad_sceneflow.storyboard_cuts (organization_id, storyboard_id, kind, aspect, scene_ids, status, ord)
      values (v_sb.organization_id, p_storyboard_id, 'master', v_sb.aspect, v_ids, 'rendering', 0) returning * into v_cut;
    elsif v_cut.kind = 'master' then
      update nomad_sceneflow.storyboard_cuts set scene_ids = v_ids, aspect = v_sb.aspect, status = 'rendering', last_error = null
       where id = v_cut.id returning * into v_cut;
    else
      update nomad_sceneflow.storyboard_cuts set scene_ids = v_ids, status = 'rendering', last_error = null where id = v_cut.id returning * into v_cut;
    end if;
  else
    if not nomad_sceneflow_private.cut_scenes_valid(p_storyboard_id, 'short', v_cut.scene_ids) then
      raise exception 'snapshot_storyboard: short cut scenes are no longer consecutive' using errcode = '22023';
    end if;
    select sum(s.duration_ms) into v_sum from nomad_sceneflow.scenes s where s.id = any (v_cut.scene_ids);
    if v_sum > 90000 then raise exception 'snapshot_storyboard: short cut % ms is over 90 s', v_sum using errcode = 'VD017'; end if;
    update nomad_sceneflow.storyboard_cuts set status = 'rendering', last_error = null where id = v_cut.id returning * into v_cut;
  end if;

  select count(*) into v_bad from nomad_sceneflow.scenes s
  where s.id = any (v_cut.scene_ids) and s.kind = 'clip'
    and not exists (select 1 from nomad_sceneflow.scene_assets a where a.scene_id = s.id and a.kind = 'clip' and a.status = 'ready'
                    and a.rights_basis is not null and a.rights_note is not null);
  if v_bad > 0 then raise exception 'snapshot_storyboard: % clip scenes without rights basis', v_bad using errcode = 'VD019'; end if;
  select count(*) into v_bad from nomad_sceneflow.scenes s
  where s.id = any (v_cut.scene_ids) and s.kind = 'image'
    and not exists (select 1 from nomad_sceneflow.scene_assets a where a.scene_id = s.id and a.kind = 'image' and a.status = 'ready');
  if v_bad > 0 then raise exception 'snapshot_storyboard: % image scenes without a ready image', v_bad using errcode = '22023'; end if;

  select * into v_dim from nomad_sceneflow_private.render_dimensions(v_cut.aspect, v_sb.resolution);
  v_version := v_sb.version + 1;
  v_snap := jsonb_build_object(
    'storyboard', jsonb_build_object('id', v_sb.id, 'title', v_sb.title, 'format', v_sb.format, 'aspect', v_sb.aspect,
                                     'target_seconds', v_sb.target_seconds, 'template_code', v_sb.template_code, 'topic', v_sb.topic,
                                     'languages', to_jsonb(v_sb.languages), 'revision', v_sb.revision,
                                     'voice_provider', v_sb.voice_provider, 'voice_id', v_sb.voice_id),
    'cut', jsonb_build_object('id', v_cut.id, 'kind', v_cut.kind, 'aspect', v_cut.aspect, 'hook_text', v_cut.hook_text),
    'render', jsonb_build_object('resolution', v_sb.resolution, 'fps', v_sb.fps, 'width', v_dim.width, 'height', v_dim.height,
                                 'watermark', not nomad_sceneflow_private.feat(v_sb.organization_id, 'no_watermark')),
    'style', jsonb_build_object('caption_style', v_sb.caption_style, 'caption_hanja', v_sb.caption_hanja,
                                'bgm_level_db', v_sb.bgm_level_db, 'loudnorm', v_sb.loudnorm),
    'scenes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'ord', s.ord, 'chapter', s.chapter, 'kind', s.kind, 'duration_ms', s.duration_ms,
               'narration', s.narration, 'on_screen_text', s.on_screen_text, 'visual_prompt', s.visual_prompt,
               'motion_preset', s.motion_preset, 'music_cue', s.music_cue, 'sources', s.sources, 'source_required', s.source_required,
               'revision', s.revision, 'focus', jsonb_build_object('x', s.focus_x, 'y', s.focus_y),
               'transition', jsonb_build_object('name', s.transition, 'ms', s.transition_ms),
               'clip', case when s.kind = 'clip' then jsonb_build_object('in_ms', s.clip_in_ms, 'out_ms', s.clip_out_ms, 'cut_ranges', s.cut_ranges) end,
               'caption_emphasis', to_jsonb(s.caption_emphasis),
               'crop_from', case when s.kind = 'image'
                                  and not exists (select 1 from nomad_sceneflow.scene_assets a where a.scene_id = s.id and a.kind = 'image'
                                                  and a.status = 'ready' and a.aspect = v_cut.aspect)
                                 then (select a.aspect from nomad_sceneflow.scene_assets a
                                        where a.scene_id = s.id and a.kind = 'image' and a.status = 'ready'
                                        order by (a.aspect = v_sb.aspect) desc, a.created_at desc limit 1) end,
               'assets', coalesce((select jsonb_object_agg(a.kind || coalesce(':' || a.lang, '') || coalesce(':' || a.aspect, ''),
                                          jsonb_build_object('id', a.id, 'path', a.storage_path, 'ai_generated', a.ai_generated,
                                                             'aspect', a.aspect, 'rights_basis', a.rights_basis))
                                   from nomad_sceneflow.scene_assets a where a.scene_id = s.id and a.status = 'ready'), '{}'::jsonb))
             order by u.n)
      from unnest(v_cut.scene_ids) with ordinality as u(id, n) join nomad_sceneflow.scenes s on s.id = u.id), '[]'::jsonb));
  insert into nomad_sceneflow.storyboard_snapshots (organization_id, storyboard_id, cut_id, version, snapshot)
  values (v_sb.organization_id, p_storyboard_id, v_cut.id, v_version, v_snap) returning * into v_row;
  update nomad_sceneflow.storyboards set version = v_version, status = case when v_cut.kind = 'master' then 'rendering' else status end
   where id = p_storyboard_id;
  perform nomad_core.write_audit(v_sb.organization_id, 'sceneflow.storyboard.snapshot', 'storyboard', p_storyboard_id::text, null, null,
                                 jsonb_build_object('version', v_version, 'cut_id', v_cut.id, 'cut_kind', v_cut.kind,
                                                    'aspect', v_cut.aspect, 'resolution', v_sb.resolution));
  return v_row;
end;
$$;

-- ---------- 9. 컷 렌더 1건(이식 추가): 스냅샷 → 크레딧 선차감(nomad_core.consume_credits) → nomad_core.enqueue_job 한 트랜잭션 ----------
--   차감액은 서버가 정한다(p_credits, 0 이면 차감 없음). 같은 request_id 는 기존 렌더를 돌려준다(재차감 없음).
--   워커: claim_jobs('sceneflow.orchestrate') → outputs(ready) 기록 → finish_cut_render → complete_job. 최종 실패면 fail_job → fail_cut_render.
create function nomad_sceneflow.start_cut_render(p_storyboard_id uuid, p_actor uuid, p_request_id uuid, p_credits integer, p_cut_id uuid default null)
returns table (cut_id uuid, snapshot_id uuid, job_id uuid, credits integer)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare v_sb nomad_sceneflow.storyboards; v_cut nomad_sceneflow.storyboard_cuts; v_snap nomad_sceneflow.storyboard_snapshots;
        v_ledger uuid; v_job nomad_core.jobs;
begin
  if not nomad_core.is_service_caller() then raise exception 'start_cut_render: server only' using errcode = '42501'; end if;
  if p_storyboard_id is null or p_actor is null or p_request_id is null or p_credits is null or p_credits < 0 then
    raise exception 'start_cut_render: storyboard, actor, request_id, credits >= 0 required' using errcode = '22023';
  end if;
  select * into v_cut from nomad_sceneflow.storyboard_cuts c where c.request_id = p_request_id;
  if found then
    if v_cut.storyboard_id <> p_storyboard_id then
      raise exception 'start_cut_render: request_id belongs to another storyboard' using errcode = '22023';
    end if;
    return query select v_cut.id, (select s.id from nomad_sceneflow.storyboard_snapshots s where s.cut_id = v_cut.id order by s.version desc limit 1),
                        v_cut.job_id, v_cut.credits_charged;
    return;
  end if;
  select * into v_sb from nomad_sceneflow.storyboards b where b.id = p_storyboard_id;
  if not found then raise exception 'start_cut_render: storyboard not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
                 where m.organization_id = v_sb.organization_id and m.user_id = p_actor and o.active and m.role in ('owner', 'admin', 'editor')) then
    raise exception 'start_cut_render: actor cannot write in this organization' using errcode = '42501';
  end if;
  v_snap := nomad_sceneflow.snapshot_storyboard(p_storyboard_id, p_cut_id);
  if p_credits > 0 then
    select c.ledger_id into v_ledger
    from nomad_core.consume_credits(v_sb.organization_id, p_credits, 'sceneflow.render', 'sceneflow:consume:' || p_request_id::text,
                                    'sceneflow', 'storyboard_cut', v_snap.cut_id::text) c;
  end if;
  select * into v_job from nomad_core.enqueue_job(
    v_sb.organization_id, 'sceneflow', 'sceneflow.render',
    jsonb_build_object('cut_id', v_snap.cut_id, 'snapshot_id', v_snap.id, 'version', v_snap.version),
    'sceneflow.orchestrate', 100, now(), 3, v_ledger, 'sceneflow:render:' || p_request_id::text, null, p_actor, true);
  update nomad_sceneflow.storyboard_cuts c set job_id = v_job.id, credit_ledger_id = v_ledger, credits_charged = p_credits, request_id = p_request_id
   where c.id = v_snap.cut_id returning * into v_cut;
  if v_cut.kind = 'master' then
    update nomad_sceneflow.storyboards b set root_job_id = v_job.id where b.id = p_storyboard_id;
  end if;
  perform nomad_core.write_audit(v_sb.organization_id, 'sceneflow.render.start', 'storyboard_cut', v_cut.id::text, null, null,
                                 jsonb_build_object('job_id', v_job.id, 'credits', p_credits, 'version', v_snap.version));
  return query select v_cut.id, v_snap.id, v_job.id, p_credits;
end;
$$;

-- 렌더 완료: 잡이 failed·canceled(이미 환불)면 거부(55000). ready 출력물이 있어야 한다. 컷 ready(전달 표시는 트리거), 마스터면 rendered.
create function nomad_sceneflow.finish_cut_render(p_cut_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_cut nomad_sceneflow.storyboard_cuts; v_job_status text;
begin
  if not nomad_core.is_service_caller() then raise exception 'finish_cut_render: server only' using errcode = '42501'; end if;
  select * into v_cut from nomad_sceneflow.storyboard_cuts where id = p_cut_id for update;
  if not found then raise exception 'finish_cut_render: cut not found' using errcode = 'P0002'; end if;
  if v_cut.status <> 'rendering' then raise exception 'finish_cut_render: cut is %', v_cut.status using errcode = '22023'; end if;
  if v_cut.job_id is not null then
    select j.status into v_job_status from nomad_core.jobs j where j.id = v_cut.job_id for update;
    if v_job_status in ('failed', 'canceled') then
      raise exception 'finish_cut_render: job is % (credits already refunded)', v_job_status using errcode = '55000';
    end if;
  end if;
  if not exists (select 1 from nomad_sceneflow.outputs o where o.storyboard_cut_id = p_cut_id and o.status = 'ready') then
    raise exception 'finish_cut_render: no ready output for the cut' using errcode = '22023';
  end if;
  update nomad_sceneflow.storyboard_cuts set status = 'ready', last_error = null where id = p_cut_id;
  if v_cut.kind = 'master' then
    update nomad_sceneflow.storyboards set status = 'rendered' where id = v_cut.storyboard_id and status = 'rendering';
  end if;
  return jsonb_build_object('cut_id', p_cut_id, 'status', 'ready');
end;
$$;

-- 렌더 실패: 최종 실패에서만(잡이 queued·running 이면 55000). 컷 failed, 마스터면 스토리보드 ready,
--   선차감 환불(nomad_core.refund_credits, 키 sceneflow:refund:<ledger>; 잡 실패·취소로 core 가 이미 환불했으면 0).
create function nomad_sceneflow.fail_cut_render(p_cut_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_cut nomad_sceneflow.storyboard_cuts; v_job_status text; v_refunded integer := 0;
begin
  if not nomad_core.is_service_caller() then raise exception 'fail_cut_render: server only' using errcode = '42501'; end if;
  select * into v_cut from nomad_sceneflow.storyboard_cuts where id = p_cut_id for update;
  if not found then raise exception 'fail_cut_render: cut not found' using errcode = 'P0002'; end if;
  if v_cut.status <> 'rendering' then raise exception 'fail_cut_render: cut is %', v_cut.status using errcode = '22023'; end if;
  if v_cut.job_id is not null then
    select j.status into v_job_status from nomad_core.jobs j where j.id = v_cut.job_id for update;
    if v_job_status in ('queued', 'running') then
      raise exception 'fail_cut_render: job is still % (call only after final failure)', v_job_status using errcode = '55000';
    end if;
  end if;
  update nomad_sceneflow.storyboard_cuts set status = 'failed', last_error = left(coalesce(p_reason, 'failed'), 1000) where id = p_cut_id;
  if v_cut.kind = 'master' then
    update nomad_sceneflow.storyboards set status = 'ready' where id = v_cut.storyboard_id and status = 'rendering';
  end if;
  if v_cut.credit_ledger_id is not null then
    select coalesce(r.refunded, 0) into v_refunded
    from nomad_core.refund_credits(v_cut.credit_ledger_id, 'sceneflow.render_failed', 'sceneflow:refund:' || v_cut.credit_ledger_id::text, null) r;
  end if;
  perform nomad_core.write_audit(v_cut.organization_id, 'sceneflow.render.fail', 'storyboard_cut', p_cut_id::text, null, null,
                                 jsonb_build_object('refunded', coalesce(v_refunded, 0)));
  return jsonb_build_object('cut_id', p_cut_id, 'status', 'failed', 'refunded', coalesce(v_refunded, 0));
end;
$$;

-- ---------- 10. 공개 읽기 RPC (D8): 방문자(anon)의 유일한 경로. 공개 상태 행의 공개 컬럼만 jsonb, 없으면 null.
--     DB 요청 제한 없음(공개 읽기 — slug·handle 키로는 남의 페이지를 닫을 수 있다). 과부하는 앞단 CDN 캐시·WAF 몫.
--     구독이 끊겨 coupang_landing 이 없는 조직의 랜딩은 not found(null). 링크인바이오는 무료(studio) 기능이라 남는다. ----------
create function nomad_sceneflow.get_public_landing(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_slug text := lower(btrim(coalesce(p_slug, ''))); v_l nomad_sceneflow.landing_pages;
begin
  if v_slug !~ '^[a-z0-9][a-z0-9-]{2,63}$' then return null; end if;
  select l.* into v_l from nomad_sceneflow.landing_pages l join nomad_core.organizations o on o.id = l.organization_id and o.active
  where l.slug = v_slug and l.status = 'published';
  if not found or not nomad_sceneflow_private.feat(v_l.organization_id, 'coupang_landing') then return null; end if;
  return jsonb_build_object(
    'slug', v_l.slug, 'product_name', v_l.product_name, 'headline', v_l.headline, 'features', v_l.features, 'youtube_video_id', v_l.youtube_video_id,
    'primary', (select jsonb_build_object('short_code', a.short_code, 'product_name', a.product_name, 'provider', a.provider)
                from nomad_core.affiliate_links a where a.id = v_l.primary_link_id and a.is_active),
    'related', coalesce((select jsonb_agg(jsonb_build_object('short_code', a.short_code, 'product_name', a.product_name, 'provider', a.provider)
                                          order by array_position(v_l.related_link_ids, a.id))
                         from nomad_core.affiliate_links a where a.id = any (v_l.related_link_ids) and a.is_active
                           and a.organization_id = v_l.organization_id), '[]'::jsonb),
    'disclosure', (select d.body from nomad_core.affiliate_disclosures d join nomad_core.affiliate_links a on a.id = v_l.primary_link_id
                   where d.provider = a.provider and d.placement = 'video_description'
                     and (d.organization_id = v_l.organization_id or d.organization_id is null)
                   order by d.organization_id nulls last limit 1));
end;
$$;

create function nomad_sceneflow.get_public_linkinbio(p_handle text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_handle text := lower(btrim(coalesce(p_handle, ''))); v_p nomad_sceneflow.linkinbio_profiles; v_landing boolean;
begin
  if v_handle !~ '^[a-z0-9_]{3,30}$' then return null; end if;
  select p.* into v_p from nomad_sceneflow.linkinbio_profiles p join nomad_core.organizations o on o.id = p.organization_id and o.active
  where p.handle = v_handle and p.is_published;
  if not found or not nomad_sceneflow_private.feat(v_p.organization_id, 'studio') then return null; end if;
  v_landing := nomad_sceneflow_private.feat(v_p.organization_id, 'coupang_landing');
  return jsonb_build_object(
    'handle', v_p.handle, 'display_name', v_p.display_name, 'bio', v_p.bio, 'avatar_path', v_p.avatar_path,
    'items', coalesce((
      select jsonb_agg(x.item order by x.position, x.created_at)
      from (
        select i.position, i.created_at,
               jsonb_build_object('kind', i.kind, 'title', i.title, 'url', i.url, 'landing_slug', lp.slug, 'short_code', a.short_code,
                 'disclosure', case when a.id is not null then (
                    select d.body from nomad_core.affiliate_disclosures d
                    where d.provider = a.provider and d.placement = 'video_description'
                      and (d.organization_id = v_p.organization_id or d.organization_id is null)
                    order by d.organization_id nulls last limit 1) end) as item
        from nomad_sceneflow.linkinbio_items i
        left join nomad_sceneflow.landing_pages lp on lp.id = i.landing_page_id and lp.status = 'published' and v_landing
        left join nomad_core.affiliate_links a on a.id = i.affiliate_link_id and a.is_active
        where i.profile_id = v_p.id and i.is_active and (i.kind in ('link', 'video') or lp.id is not null or a.id is not null)
      ) x), '[]'::jsonb));
end;
$$;

-- ---------- 11. 함수 실행 권한 ----------
revoke execute on all functions in schema nomad_sceneflow from public, anon, authenticated;
revoke execute on all functions in schema nomad_sceneflow_private from public, anon, authenticated;
grant usage on schema nomad_sceneflow_private to service_role;   -- 서버가 직접 쓰는 표의 CHECK 헬퍼 실행용
grant execute on all functions in schema nomad_sceneflow, nomad_sceneflow_private to service_role;
grant execute on function nomad_sceneflow.get_public_landing(text), nomad_sceneflow.get_public_linkinbio(text) to anon, authenticated;
grant execute on function
  nomad_sceneflow.has_access(uuid), nomad_sceneflow.can_write(uuid, boolean, text), nomad_sceneflow.has_feature(uuid, text),
  nomad_sceneflow.caller_has_feature(text), nomad_sceneflow.storage_org_id(text),
  nomad_sceneflow.storyboard_aspect_allowed(text, text), nomad_sceneflow.valid_preset_settings(jsonb),
  nomad_sceneflow.update_channel_settings(uuid, text, text, text, text), nomad_sceneflow.disconnect_channel(uuid),
  nomad_sceneflow.acknowledge_compliance_warning(uuid, text), nomad_sceneflow.cancel_upload(uuid),
  nomad_sceneflow.set_landing_status(uuid, text), nomad_sceneflow.set_music_distribution_status(uuid, text, text, text),
  nomad_sceneflow.consent_clip_automation_risk(uuid, text), nomad_sceneflow.revoke_clip_automation_consent(uuid),
  nomad_sceneflow.set_client_status(uuid, text),
  nomad_sceneflow.save_scene(uuid, integer, jsonb), nomad_sceneflow.reorder_scenes(uuid, uuid[], integer),
  nomad_sceneflow.add_scene(uuid, integer, integer, text, integer), nomad_sceneflow.delete_scene(uuid, integer, integer),
  nomad_sceneflow.set_shorts_candidate(uuid, boolean), nomad_sceneflow.apply_edit_plan(uuid, integer[]),
  nomad_sceneflow.undo_edit_plan(uuid), nomad_sceneflow.reject_edit_plan(uuid)
to authenticated;

-- ---------- 12. Storage: 대용량 미디어(제품 전용 비공개 버킷, 경로 <organization_id>/sceneflow/<entity>/...). 쓰기는 서버만.
--     읽기 정책은 원본대로 같은 조직 멤버 + studio. 사용자 업로드(라이선스 증빙·라이브러리 음원)는 코어 공용 버킷 계약(existing.md). ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sceneflow-media', 'sceneflow-media', false, 5368709120,
        array['video/mp4', 'video/webm', 'video/quicktime', 'audio/mpeg', 'audio/wav', 'audio/x-wav', 'audio/mp4',
              'image/png', 'image/jpeg', 'image/webp', 'text/vtt', 'text/plain', 'application/zip'])
on conflict (id) do nothing;
create policy sceneflow_media_select on storage.objects for select to authenticated
  using (bucket_id = 'sceneflow-media' and nomad_sceneflow.has_access(nomad_sceneflow.storage_org_id(name)));

-- ---------- 13. 데이터: 스토리보드 템플릿 5종(원본 12.9, 문구 카탈로그 — 수치 한도 아님) ----------
insert into nomad_sceneflow.storyboard_templates (code, label, beats, default_scene_seconds, status) values
  ('knowledge_explainer', '지식 해설',
   '[{"key":"hook","label":"질문 던지기","share":0.08,"kind":"title"},{"key":"context","label":"배경","share":0.17,"kind":"image"},
     {"key":"explain","label":"핵심 설명","share":0.45,"kind":"image"},{"key":"example","label":"예시·숫자","share":0.15,"kind":"text_card"},
     {"key":"recap","label":"정리","share":0.15,"kind":"text_card"}]', 6, 'active'),
  ('history_documentary', '역사 다큐',
   '[{"key":"cold_open","label":"장면으로 시작","share":0.08,"kind":"image"},{"key":"title","label":"제목·시대","share":0.04,"kind":"title"},
     {"key":"background","label":"시대 배경","share":0.18,"kind":"image"},{"key":"events","label":"사건 전개","share":0.40,"kind":"image"},
     {"key":"turning_point","label":"전환점","share":0.15,"kind":"image"},{"key":"legacy","label":"남긴 것·출처","share":0.15,"kind":"text_card"}]', 7, 'active'),
  ('list_topn', 'TOP N 리스트',
   '[{"key":"hook","label":"목록 예고","share":0.08,"kind":"title"},{"key":"items","label":"순위 항목","share":0.80,"kind":"image"},
     {"key":"outro","label":"정리","share":0.12,"kind":"text_card"}]', 5, 'active'),
  ('story_radio', '사연 라디오',
   '[{"key":"intro","label":"사연 소개","share":0.10,"kind":"title"},{"key":"story","label":"사연","share":0.60,"kind":"image"},
     {"key":"reflection","label":"생각 나누기","share":0.20,"kind":"text_card"},{"key":"outro","label":"마무리","share":0.10,"kind":"text_card"}]', 8, 'active'),
  ('product_review', '제품 리뷰',
   '[{"key":"hook","label":"한 줄 결론","share":0.08,"kind":"title"},{"key":"overview","label":"제품 소개","share":0.17,"kind":"image"},
     {"key":"points","label":"장점·단점","share":0.45,"kind":"image"},{"key":"compare","label":"비교·숫자","share":0.15,"kind":"text_card"},
     {"key":"verdict","label":"추천 대상","share":0.15,"kind":"text_card"}]', 5, 'active')
on conflict (code) do nothing;

commit;
