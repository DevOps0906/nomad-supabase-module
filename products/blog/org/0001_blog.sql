-- nomad-blog 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/1300_blog.sql 0~8장(4표)
-- D4: contentflow 에 흡수하지 않는 별도 제품(slug 'blog', 스키마 nomad_blog). 제휴(Af)는 core C6(nomad_core.affiliate_* · brandconnect_applications)를 참조만 한다.
-- core.organizations→nomad_core.organizations, org_members(member)→nomad_core.memberships(editor), has_entitlement→nomad_core.has_feature,
-- core.encrypted_credentials·revoke_credential→nomad_core.provider_credentials·revoke_provider_credential, core.jobs·cancel_job→nomad_core 같은 이름,
-- core.affiliate_links(source_app)→nomad_core.affiliate_links(product_code), core.write_audit→nomad_core.write_audit.
-- 플랜 features jsonb → A/B/C 기능(features) + plan_limits 키(수치 시드 안 함). 대응표: products/blog/existing.md
-- AI 라우팅·AI 기능(원본 9장)은 org/0002_ai.sql. 전제: core 20261119000100(touch_updated_at) · 20261120000100~0600(audit·credits·jobs·ai·affiliate) · 20261120000800.
-- 되돌림: drop schema nomad_blog cascade; delete from storage.buckets where id = 'blog-files';
--   delete from nomad_core.plan_features where product_code = 'blog'; delete from nomad_core.features where product_code = 'blog';
--   delete from nomad_core.plans where product_code = 'blog'; delete from nomad_core.products where code = 'blog'; (api_providers 채널 4행은 남겨도 무해)
-- SQLSTATE(원본 유지): BL001 상태 불가 · BL002 취소 불가 · BL003 컴플라이언스 미통과 · BL005 채널 사용 불가(동의·상태)
--   · (이식 추가) BL006 플랜 기능 잠김 · BL007 작업이 이미 실패·취소(결과 저장 거부)
begin;

create schema nomad_blog;
revoke all on schema nomad_blog from public, anon, authenticated;
grant usage on schema nomad_blog to authenticated, service_role;  -- anon 0(공개 경로 없음, D8)
alter default privileges in schema nomad_blog revoke execute on functions from public;
comment on schema nomad_blog is 'nomad-blog: AI 블로그 원고 + 네이버·티스토리·워드프레스·인스타그램 발행 + 제휴 링크 매핑';

insert into nomad_core.products (code, name) values ('blog', 'NOMAD Blog') on conflict (code) do nothing;
-- 플랜: 원본 business→A, pro→B, free→C. 구독이 끊기면(구독 없음·inactive·만료 = C) 원본 free 기능만 남는다.
insert into nomad_core.plans (product_code, code, name) values ('blog', 'A', 'A'), ('blog', 'B', 'B'), ('blog', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('blog', 'blog', '블로그 작업 공간(원고·발행·제휴 링크)'),
  ('blog', 'quality_mode', 'quality AI 모드'),
  ('blog', 'affiliate_auto_insert', '제휴 링크 자동 삽입'),
  ('blog', 'brandconnect', '브랜드커넥트 원고'),
  ('blog', 'schedule', '예약 발행'),
  ('blog', 'instagram_channel', '인스타그램 채널'),
  ('blog', 'automation', '자동화(n8n·Make·발신 웹훅)')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'blog', p, 'blog' from unnest(array['A', 'B', 'C']) p
union all
select 'blog', p, f from unnest(array['A', 'B']) p, unnest(array['quality_mode', 'affiliate_auto_insert', 'brandconnect', 'schedule']) f
union all
select 'blog', 'A', f from unnest(array['instagram_channel', 'automation']) f
on conflict do nothing;
-- plan_limits 키(수치 시드 안 함, 없으면 원본 free 값, 서버 검사): posts_per_month(10, monthly_post_usage) · max_channel_accounts(2) · members_max(1)
-- 채널 비밀(세션 쿠키·아이디/비밀번호·WP 애플리케이션 비밀번호)은 nomad_core.provider_credentials(Vault)에만. 제공자 코드를 등록한다(표시 이름만).
insert into nomad_core.api_providers (code, name) values
  ('naver_blog', '네이버 블로그'), ('tistory', '티스토리'), ('wordpress', '워드프레스'), ('instagram', '인스타그램')
on conflict (code) do nothing;

-- =====================================================================
-- 1. 도우미
-- =====================================================================
create function nomad_blog.has_access(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.has_feature(target_organization, 'blog', 'blog'), false) $$;

create function nomad_blog.can_edit(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin', 'editor'), false)
     and nomad_blog.has_access(target_organization)
$$;

create function nomad_blog.can_manage(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin'), false)
     and nomad_blog.has_access(target_organization)
$$;

-- 서버·트리거 전용: 기능(조직 활성 포함, 멤버십 무관)
create function nomad_blog.org_feature(target_organization uuid, target_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_has_feature(target_organization, 'blog', target_feature), false) $$;

-- =====================================================================
-- 2. 표 (4개)
-- =====================================================================
-- 2.1 channel_accounts: 발행 채널 계정. 쓰기는 서버(연결·검증 워커) 또는 아래 RPC 만.
create table nomad_blog.channel_accounts (
  id                             uuid primary key default gen_random_uuid(),
  organization_id                uuid not null references nomad_core.organizations(id) on delete cascade,
  channel                        text not null constraint channel_accounts_channel_check check (channel in ('naver', 'tistory', 'wordpress', 'instagram')),
  label                          text not null default '' constraint channel_accounts_label_check check (length(label) <= 60),
  blog_url                       text constraint channel_accounts_blog_url_check check (blog_url is null or blog_url ~* '^https://[^/@[:space:]]+'),
  external_account_id            text,                  -- 네이버 blog_id, 티스토리 블로그 이름, WP 사용자 id
  credential_id                  uuid,
  status                         text not null default 'pending'
                                 constraint channel_accounts_status_check check (status in ('pending', 'active', 'needs_reauth', 'error', 'revoked')),
  automation_risk_consented_at   timestamptz,           -- 네이버·티스토리 Playwright 자동 게시 위험 동의
  automation_risk_consented_by   uuid,
  automation_risk_notice_version text,
  session_expires_at             timestamptz,
  last_verified_at               timestamptz,
  last_published_at              timestamptz,
  last_error                     text,
  locked_by_job                  uuid,                  -- 계정당 동시 브라우저 세션 1개(acquire_channel_lock)
  locked_until                   timestamptz,
  created_by                     uuid,
  created_at                     timestamptz not null default now(),
  updated_at                     timestamptz not null default now(),
  unique (id, organization_id),
  constraint channel_accounts_org_channel_ext_uniq unique (organization_id, channel, external_account_id),
  -- 비밀은 같은 조직 자격만. 자격이 지워지면 credential_id 만 비운다.
  constraint channel_accounts_credential_fk foreign key (credential_id, organization_id)
    references nomad_core.provider_credentials (id, organization_id) on delete set null (credential_id)
);
create index channel_accounts_org_idx on nomad_blog.channel_accounts (organization_id, channel);
create index channel_accounts_credential_idx on nomad_blog.channel_accounts (credential_id) where credential_id is not null;
comment on table nomad_blog.channel_accounts is '발행 채널 계정(비밀은 provider_credentials). 서버 쓰기, 동의·연결 해제는 owner·admin RPC.';

-- 2.2 posts: 원고. 사용자는 콘텐츠 컬럼만(컬럼 GRANT 1차, 트리거 2차). body_html 은 서버 렌더러가 body_json 에서 만든 sanitize 결과만.
create table nomad_blog.posts (
  id                          uuid primary key default gen_random_uuid(),
  organization_id             uuid not null references nomad_core.organizations(id) on delete cascade,
  title                       text not null default '' constraint posts_title_check check (length(title) <= 200),
  body_json                   jsonb not null default '{"type":"doc","content":[]}'::jsonb
                              constraint posts_body_json_check check (octet_length(body_json::text) <= 500000),
  body_html                   text,
  excerpt                     text constraint posts_excerpt_check check (excerpt is null or length(excerpt) <= 300),
  tags                        text[] not null default '{}' constraint posts_tags_check check (cardinality(tags) <= 30),
  category                    text constraint posts_category_check check (category is null or length(category) <= 60),
  target_keyword              text constraint posts_target_keyword_check check (target_keyword is null or length(target_keyword) <= 100),
  template                    text not null default 'info'
                              constraint posts_template_check check (template in ('info', 'compare', 'guide', 'essay', 'experience')),
  experience_note             text,                    -- experience 템플릿: 사용자 본인의 실제 사용 메모(50자 이상)
  cover_image_path            text,
  seo_score                   integer constraint posts_seo_score_check check (seo_score is null or seo_score between 0 and 100),
  seo_feedback                jsonb not null default '[]'::jsonb,
  brandconnect_application_id uuid references nomad_core.brandconnect_applications(id) on delete set null,
  status                      text not null default 'draft'
                              constraint posts_status_check check (status in ('draft', 'generating', 'scheduled', 'publishing', 'published',
                                                                              'partially_published', 'failed', 'archived')),
  compliance_verdict          text not null default 'unchecked'
                              constraint posts_compliance_verdict_check check (compliance_verdict in ('unchecked', 'pass', 'warn', 'fail')),
  compliance_issues           jsonb not null default '[]'::jsonb,
  compliance_checked_at       timestamptz,
  compliance_ack_by           uuid,
  compliance_ack_at           timestamptz,
  ai_job_id                   uuid,
  version                     integer not null default 1,
  last_error                  text,
  created_by                  uuid,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  archived_at                 timestamptz,
  unique (id, organization_id),
  constraint posts_experience_check check (template <> 'experience' or length(btrim(coalesce(experience_note, ''))) >= 50),
  constraint posts_cover_path_check check (cover_image_path is null or cover_image_path like (organization_id::text || '/blog/%')),
  constraint posts_job_fk foreign key (ai_job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (ai_job_id)
);
create index posts_org_updated_idx on nomad_blog.posts (organization_id, updated_at);
create index posts_org_status_idx on nomad_blog.posts (organization_id, status);
create index posts_brandconnect_idx on nomad_blog.posts (brandconnect_application_id) where brandconnect_application_id is not null;
comment on table nomad_blog.posts is '블로그 원고. 사용자 콘텐츠 컬럼만, 상태·검사·렌더 결과는 서버. 보관은 set_post_archived.';

-- 2.3 post_affiliate_links: 원고 ↔ nomad_core.affiliate_links(같은 조직·product_code blog). 쓰기는 서버(제휴 링크 생성 라우트)만.
create table nomad_blog.post_affiliate_links (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  post_id         uuid not null,
  link_id         uuid not null,
  provider        text not null
                  constraint post_affiliate_links_provider_check check (provider in ('coupang', 'naver_brandconnect', 'tenping', 'naver_shopping_connect')),
  placement       text not null default 'card' constraint post_affiliate_links_placement_check check (placement in ('card', 'inline', 'cta')),
  position        integer not null default 0,
  card_snapshot   jsonb not null default '{}'::jsonb,   -- 삽입 시점 상품명·가격·이미지(가격 변동 표기용)
  inserted_by     text not null default 'user' constraint post_affiliate_links_inserted_by_check check (inserted_by in ('user', 'auto')),
  created_by      uuid,
  created_at      timestamptz not null default now(),
  constraint post_affiliate_links_post_link_uniq unique (post_id, link_id),
  constraint post_affiliate_links_post_fk foreign key (post_id, organization_id) references nomad_blog.posts (id, organization_id) on delete cascade,
  constraint post_affiliate_links_link_fk foreign key (link_id, organization_id)
    references nomad_core.affiliate_links (id, organization_id) on delete cascade
);
create index post_affiliate_links_post_idx on nomad_blog.post_affiliate_links (post_id, position);
create index post_affiliate_links_link_idx on nomad_blog.post_affiliate_links (link_id);
create index post_affiliate_links_org_idx on nomad_blog.post_affiliate_links (organization_id);
comment on table nomad_blog.post_affiliate_links is '원고-제휴 링크 매핑(같은 조직 blog 링크만, 자동 삽입 = 기능 affiliate_auto_insert). 서버 쓰기만.';

-- 2.4 post_publications: 원고 × 채널 계정 발행 1건. 쓰기는 서버(발행 라우트·워커)와 아래 RPC 만.
--   상태: queued | scheduled → publishing → published | unconfirmed | failed | queued(재시도)
--         unconfirmed → published | failed(사용자 확인, 자동 재시도 금지: 중복 발행 방지) · failed → queued · queued | scheduled → canceled
create table nomad_blog.post_publications (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  post_id              uuid not null,
  channel_account_id   uuid,
  channel              text not null constraint post_publications_channel_check check (channel in ('naver', 'tistory', 'wordpress', 'instagram')),
  status               text not null default 'queued'
                       constraint post_publications_status_check
                       check (status in ('queued', 'scheduled', 'publishing', 'published', 'unconfirmed', 'failed', 'canceled')),
  scheduled_at         timestamptz,
  job_id               uuid,
  attempts             integer not null default 0,
  external_post_id     text,
  published_url        text constraint post_publications_url_check check (published_url is null or published_url ~* '^https://'),
  published_at         timestamptz,
  rendered_hash        text,                         -- 실제로 보낸 HTML 의 sha256(감사·재발행 비교)
  requires_disclosure  boolean not null default false,
  disclosure_included  boolean not null default false,
  affiliate_link_count integer not null default 0,
  last_error           text,
  idempotency_key      text unique,
  created_by           uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  canceled_at          timestamptz,
  -- 제휴 링크·스폰서 원고는 대가성 문구 없이 발행 단계로 들어갈 수 없다(끌 수 없음)
  constraint post_publications_disclosure_check
    check (status not in ('publishing', 'published', 'unconfirmed') or not requires_disclosure or disclosure_included),
  constraint post_publications_schedule_check check (status <> 'scheduled' or scheduled_at is not null),
  constraint post_publications_post_fk foreign key (post_id, organization_id) references nomad_blog.posts (id, organization_id) on delete cascade,
  constraint post_publications_account_fk foreign key (channel_account_id, organization_id)
    references nomad_blog.channel_accounts (id, organization_id) on delete set null (channel_account_id),
  constraint post_publications_job_fk foreign key (job_id, organization_id) references nomad_core.jobs (id, organization_id) on delete set null (job_id)
);
create unique index post_publications_external_uniq on nomad_blog.post_publications (channel_account_id, external_post_id) where external_post_id is not null;
create unique index post_publications_active_uniq on nomad_blog.post_publications (post_id, channel_account_id)
  where status in ('queued', 'scheduled', 'publishing', 'unconfirmed');
create index post_publications_org_created_idx on nomad_blog.post_publications (organization_id, created_at desc);
create index post_publications_org_updated_idx on nomad_blog.post_publications (organization_id, updated_at);
create index post_publications_org_schedule_idx on nomad_blog.post_publications (organization_id, scheduled_at) where scheduled_at is not null;
create index post_publications_post_idx on nomad_blog.post_publications (post_id);
create index post_publications_job_idx on nomad_blog.post_publications (job_id) where job_id is not null;
comment on table nomad_blog.post_publications is '원고×채널 발행 1건(상태 전이·대가성 문구·컴플라이언스 게이트·예약 = 기능 schedule). 서버 쓰기만.';

-- =====================================================================
-- 3. 트리거
--   서버 판별(보호 컬럼·서버 표 잠금): current_user가 authenticated·anon이 아니면 서버(service_role 직접 또는 소유자 DEFINER 함수 안).
--   원본 core.is_privileged_session(current_user 기준)과 같은 뜻.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['channel_accounts', 'posts', 'post_publications'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_blog.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
end $$;

create function nomad_blog.guard_server_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'nomad_blog.%: server-managed', tg_table_name using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['channel_accounts', 'post_affiliate_links', 'post_publications'] loop
    execute format('create trigger %1$s_guard_write before insert or update or delete on nomad_blog.%1$I for each row execute function nomad_blog.guard_server_write()', t);
  end loop;
end $$;

-- posts: 콘텐츠 변경 감지(version·검사 무효), 보호 컬럼 2차 잠금, 생성자 기록
create function nomad_blog.posts_guard() returns trigger
language plpgsql set search_path = ''
as $$
declare v_user boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'INSERT' then
    if v_user then
      new.status := 'draft';
      new.compliance_verdict := 'unchecked';
      new.body_html := null;
      new.ai_job_id := null;
      new.created_by := auth.uid();
    end if;
  else
    if v_user and (
         new.organization_id is distinct from old.organization_id
      or new.status is distinct from old.status
      or new.compliance_verdict is distinct from old.compliance_verdict
      or new.compliance_issues is distinct from old.compliance_issues
      or new.compliance_ack_by is distinct from old.compliance_ack_by
      or new.body_html is distinct from old.body_html
      or new.ai_job_id is distinct from old.ai_job_id
      or new.created_by is distinct from old.created_by
      or new.version is distinct from old.version
    ) then
      raise exception 'nomad_blog.posts: protected column change' using errcode = '42501';
    end if;
    if (new.title, new.body_json, new.tags, new.template, new.experience_note, new.brandconnect_application_id)
       is distinct from
       (old.title, old.body_json, old.tags, old.template, old.experience_note, old.brandconnect_application_id) then
      new.version := old.version + 1;
      -- 같은 UPDATE 에서 검사 결과를 직접 쓰지 않았으면 이전 검사는 무효
      if new.compliance_verdict is not distinct from old.compliance_verdict then
        new.compliance_verdict := 'unchecked';
        new.compliance_issues := '[]'::jsonb;
        new.compliance_checked_at := null;
        new.compliance_ack_by := null;
        new.compliance_ack_at := null;
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger posts_guard before insert or update on nomad_blog.posts for each row execute function nomad_blog.posts_guard();

-- posts: 브랜드커넥트 지원서는 같은 조직의 블로그형만(서버 쓰기에도 적용) + 기능 brandconnect(구독 끊긴 뒤 새로 연결 불가)
create function nomad_blog.posts_brandconnect_check() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_app_org uuid;
begin
  if new.brandconnect_application_id is not null
     and (tg_op = 'INSERT' or new.brandconnect_application_id is distinct from old.brandconnect_application_id) then
    select a.organization_id into v_app_org from nomad_core.brandconnect_applications a
     where a.id = new.brandconnect_application_id and a.target_kind = 'blog';
    if v_app_org is null or v_app_org <> new.organization_id then
      raise exception 'nomad_blog.posts: brandconnect application belongs to another organization or is not a blog campaign' using errcode = '42501';
    end if;
    if not nomad_blog.org_feature(new.organization_id, 'brandconnect') then
      raise exception 'blog: posts needs a higher plan (brandconnect)' using errcode = 'BL006';
    end if;
  end if;
  return new;
end;
$$;
create trigger posts_brandconnect_check before insert or update of brandconnect_application_id on nomad_blog.posts
  for each row execute function nomad_blog.posts_brandconnect_check();

-- posts 상태 전이: generating 은 draft 와만 오가고, archived 는 draft 로만 복원. 발행 집계 상태는 sync_post_status 가 계산.
create function nomad_blog.posts_status_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if (new.status = 'generating' and old.status <> 'draft')
       or (old.status = 'generating' and new.status <> 'draft')
       or (new.status = 'archived' and old.status in ('generating', 'scheduled', 'publishing'))
       or (old.status = 'archived' and new.status <> 'draft') then
      raise exception 'nomad_blog.posts: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'archived' then
      new.archived_at := now();
    elsif old.status = 'archived' then
      new.archived_at := null;
    end if;
  end if;
  return new;
end;
$$;
create trigger posts_status_transition before update on nomad_blog.posts for each row execute function nomad_blog.posts_status_transition();

-- post_affiliate_links: 같은 조직은 복합 FK 가 보장. 링크는 blog 제품·같은 제공자만, 자동 삽입은 기능 affiliate_auto_insert.
create function nomad_blog.post_affiliate_links_consistency() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_link nomad_core.affiliate_links;
begin
  select * into v_link from nomad_core.affiliate_links where id = new.link_id;
  if v_link.id is null or v_link.product_code <> 'blog' or v_link.provider <> new.provider then
    raise exception 'nomad_blog.post_affiliate_links: link is not a blog link of provider %', new.provider using errcode = '22023';
  end if;
  if new.inserted_by = 'auto' and (tg_op = 'INSERT' or old.inserted_by is distinct from 'auto')
     and not nomad_blog.org_feature(new.organization_id, 'affiliate_auto_insert') then
    raise exception 'blog: post_affiliate_links needs a higher plan (affiliate_auto_insert)' using errcode = 'BL006';
  end if;
  return new;
end;
$$;
create trigger post_affiliate_links_consistency before insert or update on nomad_blog.post_affiliate_links
  for each row execute function nomad_blog.post_affiliate_links_consistency();

-- 발행 게이트(INSERT·발행 시작): 채널 계정 활성 + 자동화 동의, 원고 상태, 컴플라이언스 통과, 플랜 기능(예약·인스타그램·브랜드커넥트).
-- 대가성 문구 필요 여부와 링크 수는 서버 값이 아니라 DB 에서 계산한다. 같은 조직은 복합 FK 가 보장.
create function nomad_blog.post_publications_gate() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_post nomad_blog.posts; v_acc nomad_blog.channel_accounts; v_start boolean; v_need text[] := '{}'; f text;
begin
  select * into v_post from nomad_blog.posts where id = new.post_id;
  v_start := tg_op = 'INSERT' or (new.status = 'publishing' and old.status is distinct from 'publishing');

  if tg_op = 'INSERT' then
    if new.status not in ('queued', 'scheduled') then
      raise exception 'post_publications: initial status must be queued or scheduled' using errcode = '22023';
    end if;
    select * into v_acc from nomad_blog.channel_accounts where id = new.channel_account_id;
    if v_acc.id is null then
      raise exception 'post_publications: channel account required' using errcode = 'BL005';
    end if;
    if v_acc.channel <> new.channel or v_acc.status <> 'active' then
      raise exception 'post_publications: channel account is % (%)', v_acc.status, v_acc.channel using errcode = 'BL005';
    end if;
    if v_acc.channel in ('naver', 'tistory') and v_acc.automation_risk_consented_at is null then
      raise exception 'post_publications: automation risk consent required for %', v_acc.channel using errcode = 'BL005';
    end if;
    if v_post.status in ('generating', 'archived') then
      raise exception 'post_publications: post is %', v_post.status using errcode = 'BL001';
    end if;
  end if;

  -- 컴플라이언스: 새 발행과 기존 대기·예약 행의 발행 시작 모두(예약 뒤 판정이 바뀐 원고가 그대로 나가지 않게)
  if v_start and not (v_post.compliance_verdict = 'pass' or (v_post.compliance_verdict = 'warn' and v_post.compliance_ack_at is not null)) then
    raise exception 'post_publications: compliance gate not passed (%)', v_post.compliance_verdict using errcode = 'BL003';
  end if;

  -- 플랜 기능: 새 발행과 기존 대기·예약 행의 발행 시작 모두(구독이 끊긴 뒤 기존 유료 행 경로 포함)
  if v_start then
    if (tg_op = 'INSERT' and new.status = 'scheduled') or (tg_op = 'UPDATE' and old.status = 'scheduled') then
      v_need := v_need || 'schedule'::text;
    end if;
    if new.channel = 'instagram' then v_need := v_need || 'instagram_channel'::text; end if;
    if v_post.brandconnect_application_id is not null then v_need := v_need || 'brandconnect'::text; end if;
    foreach f in array v_need loop
      if not nomad_blog.org_feature(new.organization_id, f) then
        raise exception 'blog: post_publications needs a higher plan (%)', f using errcode = 'BL006';
      end if;
    end loop;
    select count(*) into new.affiliate_link_count from nomad_blog.post_affiliate_links l where l.post_id = new.post_id;
    new.requires_disclosure := new.affiliate_link_count > 0 or v_post.brandconnect_application_id is not null;
  end if;
  return new;
end;
$$;
create trigger post_publications_gate before insert or update on nomad_blog.post_publications
  for each row execute function nomad_blog.post_publications_gate();

-- 발행 상태 전이와 불변 컬럼(서버 경로 포함)
create function nomad_blog.post_publications_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if not (
         (old.status in ('queued', 'scheduled') and new.status in ('publishing', 'canceled'))
      or (old.status = 'scheduled'   and new.status = 'queued')
      or (old.status = 'publishing'  and new.status in ('published', 'unconfirmed', 'failed', 'queued'))
      or (old.status = 'unconfirmed' and new.status in ('published', 'failed'))
      or (old.status = 'failed'      and new.status = 'queued')
    ) then
      raise exception 'post_publications: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'publishing' then
      new.attempts := old.attempts + 1;
    elsif new.status = 'published' and new.published_at is null then
      new.published_at := now();
    elsif new.status = 'canceled' then
      new.canceled_at := now();
    end if;
  end if;
  if new.post_id is distinct from old.post_id or new.organization_id is distinct from old.organization_id
     or new.channel is distinct from old.channel then
    raise exception 'post_publications: immutable columns' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger post_publications_transition before update on nomad_blog.post_publications
  for each row execute function nomad_blog.post_publications_transition();

-- 결과 전달(이식 추가): 서버가 결과를 저장할 때 작업이 이미 failed·canceled(= 환불 끝)면 거부(BL007),
-- 아니면 nomad_core.mark_job_delivered(결과를 넘긴 뒤 작업이 실패해도 환불하지 않음). core 표 직접 쓰기 없음.
--   posts: generating → draft 이면서 body_html 이 바뀐 경우(생성 결과). 본문 없이 draft 로 돌리는 실패 정리는 검사하지 않는다.
--   post_publications: publishing → published | unconfirmed(워커 발행 결과). 사용자 확인(unconfirmed → published)은 제외.
create function nomad_blog.deliver_job_result() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_job uuid; v_done boolean := false; v_status text;
begin
  if tg_table_name = 'posts' then
    v_done := old.status = 'generating' and new.status = 'draft' and new.body_html is distinct from old.body_html;
    v_job := new.ai_job_id;
  elsif tg_table_name = 'post_publications' then
    v_done := old.status = 'publishing' and new.status in ('published', 'unconfirmed');
    v_job := new.job_id;
  end if;
  if v_done and v_job is not null then
    -- 잡 행을 잠근 뒤 판정: 동시에 fail_job(환불)이 끝나는 경합에서 환불 + 결과 전달이 함께 일어나지 않게
    select j.status into v_status from nomad_core.jobs j where j.id = v_job for update;
    if v_status in ('failed', 'canceled') then
      raise exception '%: job is already finished without result', tg_table_name using errcode = 'BL007';
    end if;
    perform nomad_core.mark_job_delivered(v_job);
  end if;
  return new;
end;
$$;
create trigger posts_deliver_result before update on nomad_blog.posts for each row execute function nomad_blog.deliver_job_result();
create trigger post_publications_deliver_result before update on nomad_blog.post_publications
  for each row execute function nomad_blog.deliver_job_result();

-- 원고 집계 상태 계산(발행 행이 바뀔 때마다)
create function nomad_blog.sync_post_status() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_active int; v_sched int; v_ok int; v_bad int; v_status text;
begin
  select count(*) filter (where p.status in ('queued', 'publishing')),
         count(*) filter (where p.status = 'scheduled'),
         count(*) filter (where p.status in ('published', 'unconfirmed')),
         count(*) filter (where p.status = 'failed')
    into v_active, v_sched, v_ok, v_bad
    from nomad_blog.post_publications p where p.post_id = new.post_id;
  v_status := case
    when v_active > 0 then 'publishing'
    when v_sched > 0 then 'scheduled'
    when v_ok > 0 and v_bad > 0 then 'partially_published'
    when v_ok > 0 then 'published'
    when v_bad > 0 then 'failed'
    else 'draft' end;
  update nomad_blog.posts set status = v_status
   where id = new.post_id and status not in ('archived', 'generating') and status is distinct from v_status;
  if new.status = 'published' and new.channel_account_id is not null then
    update nomad_blog.channel_accounts set last_published_at = coalesce(new.published_at, now()) where id = new.channel_account_id;
  end if;
  return null;
end;
$$;
create trigger post_publications_sync_post after insert or update on nomad_blog.post_publications
  for each row execute function nomad_blog.sync_post_status();

-- 채널 계정: 인스타그램은 기능 instagram_channel(새 연결·재활성화)
create function nomad_blog.channel_accounts_features() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.channel = 'instagram' and new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active')
     and not nomad_blog.org_feature(new.organization_id, 'instagram_channel') then
    raise exception 'blog: channel_accounts needs a higher plan (instagram_channel)' using errcode = 'BL006';
  end if;
  return new;
end;
$$;
create trigger channel_accounts_features before insert or update of status on nomad_blog.channel_accounts
  for each row execute function nomad_blog.channel_accounts_features();

-- =====================================================================
-- 4. 사용자 RPC (authenticated). 남의 조직 행은 존재도 알리지 않는다(P0002). 반환 행은 SELECT 권한이 있는 표만.
-- =====================================================================
-- 예약·대기 발행 취소. 워커가 이미 잡은 작업(running)은 nomad_core.cancel_job 이 거부한다.
create function nomad_blog.cancel_publication(p_publication_id uuid) returns nomad_blog.post_publications
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_blog.post_publications; v_server boolean := nomad_core.is_service_caller();
begin
  select * into v_row from nomad_blog.post_publications where id = p_publication_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'cancel_publication: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_blog.can_edit(v_row.organization_id) then
    raise exception 'cancel_publication: editor role required' using errcode = '42501';
  end if;
  if v_row.status not in ('queued', 'scheduled') then
    raise exception 'cancel_publication: status % cannot be canceled', v_row.status using errcode = 'BL002';
  end if;
  if v_row.job_id is not null then
    perform nomad_core.cancel_job(v_row.job_id);
  end if;
  update nomad_blog.post_publications set status = 'canceled' where id = p_publication_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'blog.publication.cancel', 'post_publication', v_row.id::text);
  return v_row;
end;
$$;

-- 발행 결과 불확실(unconfirmed) 건을 사용자가 확인. URL 을 주면 published, null 이면 failed.
create function nomad_blog.resolve_unconfirmed_publication(p_publication_id uuid, p_published_url text default null)
returns nomad_blog.post_publications
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_blog.post_publications; v_server boolean := nomad_core.is_service_caller();
begin
  select * into v_row from nomad_blog.post_publications where id = p_publication_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'resolve_unconfirmed_publication: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_blog.can_edit(v_row.organization_id) then
    raise exception 'resolve_unconfirmed_publication: editor role required' using errcode = '42501';
  end if;
  if v_row.status <> 'unconfirmed' then
    raise exception 'resolve_unconfirmed_publication: status is %', v_row.status using errcode = 'BL001';
  end if;
  if p_published_url is not null then
    if p_published_url !~* '^https://' or length(p_published_url) > 2000 then
      raise exception 'resolve_unconfirmed_publication: https url required' using errcode = '22023';
    end if;
    update nomad_blog.post_publications set status = 'published', published_url = p_published_url
     where id = p_publication_id returning * into v_row;
  else
    update nomad_blog.post_publications set status = 'failed', last_error = 'user_marked_not_published'
     where id = p_publication_id returning * into v_row;
  end if;
  perform nomad_core.write_audit(v_row.organization_id, 'blog.publication.resolve', 'post_publication', v_row.id::text,
                                 null, jsonb_build_object('status', v_row.status));
  return v_row;
end;
$$;

-- 컴플라이언스 WARN 확인(감사 기록). FAIL 은 확인으로 넘길 수 없다.
create function nomad_blog.acknowledge_compliance_warning(p_post_id uuid) returns nomad_blog.posts
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_blog.posts; v_server boolean := nomad_core.is_service_caller();
begin
  select * into v_row from nomad_blog.posts where id = p_post_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'acknowledge_compliance_warning: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_blog.can_edit(v_row.organization_id) then
    raise exception 'acknowledge_compliance_warning: editor role required' using errcode = '42501';
  end if;
  if v_row.compliance_verdict <> 'warn' then
    raise exception 'acknowledge_compliance_warning: verdict is %', v_row.compliance_verdict using errcode = 'BL003';
  end if;
  update nomad_blog.posts set compliance_ack_by = auth.uid(), compliance_ack_at = now() where id = p_post_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'blog.compliance.warn_ack', 'post', v_row.id::text,
                                 null, jsonb_build_object('issues', v_row.compliance_issues));
  return v_row;
end;
$$;

-- 원고 보관·복원(사용자는 status 컬럼을 직접 바꿀 수 없다)
create function nomad_blog.set_post_archived(p_post_id uuid, p_archived boolean) returns nomad_blog.posts
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_blog.posts; v_server boolean := nomad_core.is_service_caller();
begin
  if p_archived is null then
    raise exception 'set_post_archived: archived flag required' using errcode = '22023';
  end if;
  select * into v_row from nomad_blog.posts where id = p_post_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'set_post_archived: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_blog.can_edit(v_row.organization_id) then
    raise exception 'set_post_archived: editor role required' using errcode = '42501';
  end if;
  -- 복원은 보관된 원고만(생성 중·발행 중 원고를 draft 로 되돌려 상태 머신을 건너뛰지 못하게)
  if not p_archived and v_row.status <> 'archived' then
    raise exception 'set_post_archived: post is not archived (%)', v_row.status using errcode = '22023';
  end if;
  update nomad_blog.posts set status = case when p_archived then 'archived' else 'draft' end
   where id = p_post_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, case when p_archived then 'blog.post.archive' else 'blog.post.restore' end,
                                 'post', v_row.id::text);
  return v_row;
end;
$$;

-- 네이버·티스토리 Playwright 자동 게시 위험 동의(owner·admin). 고지문 버전을 함께 남긴다.
create function nomad_blog.consent_channel_automation_risk(p_account_id uuid, p_notice_version text) returns nomad_blog.channel_accounts
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_blog.channel_accounts; v_server boolean := nomad_core.is_service_caller();
begin
  select * into v_row from nomad_blog.channel_accounts where id = p_account_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'consent_channel_automation_risk: not found' using errcode = 'P0002';
  end if;
  if not v_server and not nomad_blog.can_manage(v_row.organization_id) then
    raise exception 'consent_channel_automation_risk: owner/admin only' using errcode = '42501';
  end if;
  if v_row.channel not in ('naver', 'tistory') then
    raise exception 'consent_channel_automation_risk: not an automated channel' using errcode = '22023';
  end if;
  if coalesce(btrim(p_notice_version), '') = '' or length(p_notice_version) > 64 then
    raise exception 'consent_channel_automation_risk: notice version required' using errcode = '22023';
  end if;
  update nomad_blog.channel_accounts
     set automation_risk_consented_at = now(), automation_risk_consented_by = auth.uid(), automation_risk_notice_version = p_notice_version
   where id = p_account_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'blog.channel.automation_risk_consent', 'channel_account', v_row.id::text,
                                 null, null, jsonb_build_object('notice_version', p_notice_version, 'channel', v_row.channel));
  return v_row;
end;
$$;

-- 채널 연결 해제(owner·admin). 같은 자격을 다른 활성 연결(채널 계정·제휴 계정)이 쓰면 자격은 남긴다.
create function nomad_blog.disconnect_channel_account(p_account_id uuid) returns nomad_blog.channel_accounts
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_blog.channel_accounts; v_shared boolean; v_server boolean := nomad_core.is_service_caller();
begin
  select * into v_row from nomad_blog.channel_accounts where id = p_account_id for update;
  if v_row.id is null or (not v_server and nomad_core.organization_role(v_row.organization_id) is null) then
    raise exception 'disconnect_channel_account: not found' using errcode = 'P0002';
  end if;
  if not v_server and not coalesce(nomad_core.organization_role(v_row.organization_id) in ('owner', 'admin'), false) then
    raise exception 'disconnect_channel_account: owner/admin only' using errcode = '42501';
  end if;
  if v_row.credential_id is not null then
    select exists (select 1 from nomad_blog.channel_accounts c
                    where c.credential_id = v_row.credential_id and c.id <> v_row.id and c.status <> 'revoked')
        or exists (select 1 from nomad_core.affiliate_accounts a
                    where a.credential_id = v_row.credential_id and a.status <> 'revoked')
      into v_shared;
    if not v_shared then
      perform nomad_core.revoke_provider_credential(v_row.credential_id);
    end if;
  end if;
  update nomad_blog.channel_accounts
     set status = 'revoked', credential_id = null, locked_by_job = null, locked_until = null
   where id = p_account_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'blog.channel.disconnect', 'channel_account', v_row.id::text);
  return v_row;
end;
$$;

-- 이번 달(KST) 발행 사용량: 발행 행이 하나라도 살아 있는(실패·취소 아님) 원고 수. 한도 posts_per_month 비교는 서버.
create function nomad_blog.monthly_post_usage(p_organization_id uuid) returns integer
language plpgsql stable security definer set search_path = ''
as $$
declare v_from timestamptz; v_count integer;
begin
  if not nomad_core.is_service_caller() and nomad_core.organization_role(p_organization_id) is null then
    raise exception 'monthly_post_usage: not a member' using errcode = '42501';
  end if;
  v_from := date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  select count(distinct p.post_id) into v_count
    from nomad_blog.post_publications p
   where p.organization_id = p_organization_id and p.created_at >= v_from and p.status not in ('failed', 'canceled');
  return v_count;
end;
$$;

-- =====================================================================
-- 5. 워커 전용 RPC (service_role). 채널 계정당 브라우저 세션 1개를 보장하는 임대 잠금.
-- =====================================================================
create function nomad_blog.acquire_channel_lock(p_account_id uuid, p_job_id uuid, p_ttl_seconds integer default 300) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_ok boolean;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'acquire_channel_lock: service_role only' using errcode = '42501';
  end if;
  update nomad_blog.channel_accounts
     set locked_by_job = p_job_id, locked_until = now() + make_interval(secs => least(greatest(coalesce(p_ttl_seconds, 300), 30), 3600))
   where id = p_account_id and status = 'active'
     and (locked_by_job is null or locked_until < now() or locked_by_job = p_job_id)
  returning true into v_ok;
  return coalesce(v_ok, false);
end;
$$;

create function nomad_blog.release_channel_lock(p_account_id uuid, p_job_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'release_channel_lock: service_role only' using errcode = '42501';
  end if;
  update nomad_blog.channel_accounts set locked_by_job = null, locked_until = null where id = p_account_id and locked_by_job = p_job_id;
end;
$$;

-- =====================================================================
-- 6. RLS 정책과 GRANT (anon: 테이블 권한 0)
-- =====================================================================
alter table nomad_blog.channel_accounts enable row level security;
alter table nomad_blog.posts enable row level security;
alter table nomad_blog.post_affiliate_links enable row level security;
alter table nomad_blog.post_publications enable row level security;
revoke all on all tables in schema nomad_blog from public, anon, authenticated;
grant all on all tables in schema nomad_blog to service_role;

grant select on nomad_blog.channel_accounts, nomad_blog.posts, nomad_blog.post_affiliate_links, nomad_blog.post_publications to authenticated;
grant insert (id, organization_id, title, body_json, excerpt, tags, category, target_keyword, template, experience_note,
              cover_image_path, brandconnect_application_id) on nomad_blog.posts to authenticated;
grant update (title, body_json, excerpt, tags, category, target_keyword, template, experience_note,
              cover_image_path, brandconnect_application_id) on nomad_blog.posts to authenticated;
grant delete on nomad_blog.posts to authenticated;

create policy channel_accounts_select on nomad_blog.channel_accounts for select to authenticated using (nomad_blog.has_access(organization_id));
create policy posts_select on nomad_blog.posts for select to authenticated using (nomad_blog.has_access(organization_id));
create policy posts_insert on nomad_blog.posts for insert to authenticated with check (nomad_blog.can_edit(organization_id));
create policy posts_update on nomad_blog.posts for update to authenticated
  using (nomad_blog.can_edit(organization_id) and status not in ('generating', 'publishing'))
  with check (nomad_blog.can_edit(organization_id));
create policy posts_delete on nomad_blog.posts for delete to authenticated
  using (nomad_blog.can_manage(organization_id) and status in ('draft', 'failed', 'archived'));
create policy post_affiliate_links_select on nomad_blog.post_affiliate_links for select to authenticated using (nomad_blog.has_access(organization_id));
create policy post_publications_select on nomad_blog.post_publications for select to authenticated using (nomad_blog.has_access(organization_id));

-- Realtime: 발행 진행 상태는 core jobs 가 정본이고, 목록 갱신용으로 발행 행도 내보낸다(RLS 적용).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_blog' and tablename = 'post_publications') then
    execute 'alter publication supabase_realtime add table nomad_blog.post_publications';
  end if;
end $$;

-- =====================================================================
-- 7. 함수 실행 권한: 기본 0, service_role 전부, authenticated 는 정책 도우미·사용자 RPC. anon 0.
-- =====================================================================
revoke execute on all functions in schema nomad_blog from public, anon, authenticated;
grant execute on all functions in schema nomad_blog to service_role;
grant execute on function
  nomad_blog.has_access(uuid), nomad_blog.can_edit(uuid), nomad_blog.can_manage(uuid),
  nomad_blog.cancel_publication(uuid), nomad_blog.resolve_unconfirmed_publication(uuid, text),
  nomad_blog.acknowledge_compliance_warning(uuid), nomad_blog.set_post_archived(uuid, boolean),
  nomad_blog.consent_channel_automation_risk(uuid, text), nomad_blog.disconnect_channel_account(uuid),
  nomad_blog.monthly_post_usage(uuid)
to authenticated;

-- =====================================================================
-- 8. Storage (제품 전용 버킷, 경로 <organization_id>/blog/...). 원본 core org-files 대체.
--   blog-files 비공개. 대표 이미지(covers/). 이용권 멤버 읽기, editor 이상 업로드·삭제(svg 금지).
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('blog-files', 'blog-files', false, 10485760, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do nothing;

create policy nomad_blog_files_select on storage.objects for select to authenticated
  using (bucket_id = 'blog-files' and (storage.foldername(name))[2] = 'blog'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_blog.has_access(((storage.foldername(name))[1])::uuid) else false end);
create policy nomad_blog_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'blog-files' and (storage.foldername(name))[2] = 'blog' and (storage.foldername(name))[3] = 'covers'
              and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                       then nomad_blog.can_edit(((storage.foldername(name))[1])::uuid) else false end);
create policy nomad_blog_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'blog-files' and (storage.foldername(name))[2] = 'blog'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_blog.can_edit(((storage.foldername(name))[1])::uuid) else false end);

commit;
