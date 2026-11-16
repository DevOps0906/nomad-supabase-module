-- news(local-news) 이식 · 조직형(org안). 원본: platform-docs _supabase-modular/migrations/2500_news.sql 0~13절(스키마 news, 표 37개)
-- 정본 설계: docs/design/03-port/news-port-notes.md (D10·N1~N3·변환 규칙 — 원본과 다르면 메모를 따른다). 대응표: products/news/existing.md
-- 변환: core.organizations·org_id → nomad_core.organizations·organization_id(하위 표 복합 FK 그대로),
--   core.has_entitlement(org,'news')·plans.features jsonb → nomad_core.org_has_feature('news', 기능) + plan_limits 키(수치 시드 없음, 키 없으면 0),
--   core.org_members(active) + staff → nomad_core.organization_role(owner·admin·editor) + staff(active). 도메인 역할 6종은 core editor(N3),
--   core.encrypted_credentials → nomad_core.provider_credentials('toss_merchant', 복합 FK), core.rate_limit_hit → nomad_core.rate_limit_take,
--   core.guard_privileged_write 는 없앴다(사용자 표 쓰기 grant 0, 쓰기는 definer RPC·service_role 만). core 표 직접 쓰기·트리거 없음.
-- D8: anon 표 grant 0. 원본 anon SELECT(컬럼 grant 16표·전체 grant 5표)는 공개 RPC(get_public_newspaper·list_public_articles·
--   list_public_items·read_article 등, 공개 컬럼만)로 바꿨다. 조직 판정 헬퍼(is_public_newspaper 등)는 anon EXECUTE 없음.
-- N1 구독 끊김(= C, 기능 newsroom 없음): 공개 기사·법정 공고·정정문 열람과 기존 유료 독자 열람은 유지, 편집국 읽기 유지.
--   새 발행·편집·새 결제·새 독자 가입은 잠금(NW014). 법정 의무·권리 보호 경로(정정 청구 처리·임시조치·게시 중단·탈퇴·수신 거부)는 열어 둔다.
-- N2 개설: 신청자가 nomad_core.create_team_organization 으로 조직(owner)을 만든 뒤 request_newspaper. 승인은 이 스키마 표만 바꾼다(service_role).
--   체험·플랜 부여는 외부 결제 서버(D1). 슬러그 유일성은 nomad_news.newspapers.slug.
-- N3: 가맹 키는 nomad_core.api_providers 'toss_merchant'(데이터 1행) + core set_provider_credential(owner·admin 만).
--   편집국 초대는 core 초대(email+token, editor) + nomad_news.staff_invitations → accept_staff_invitation 이 staff 행을 만든다.
-- Storage: 경로 CHECK(<organization_id>/news/<folder>/<파일>)만 둔다. 버킷 정책은 코어 버킷 계약 확정 시(원본 Storage 제한 정책 제외).
-- 되돌림: drop schema nomad_news cascade; delete from nomad_core.plan_features where product_code = 'news';
--   delete from nomad_core.features where product_code = 'news'; delete from nomad_core.plans where product_code = 'news';
--   delete from nomad_core.products where code = 'news'; delete from nomad_core.api_providers where code = 'toss_merchant';
--
-- 사용자 정의 SQLSTATE (원본 그대로)
--   NW001 개설 신청 중복·슬러그 사용 중       NW002 신문사 비공개·비활성(독자 기능 불가)
--   NW003 필요적 게재사항 미완성              NW004 현재 상태에서 허용되지 않는 작업(워크플로)
--   NW005 전재 계약 없음·만료                 NW006 AI 초안 사람 승인 없음
--   NW007 선거 여론조사 공표 금지 기간        NW008 독자 미가입·차단·탈퇴
--   NW009 댓글 꺼짐(신문사·기사·선거 정책)    NW010 금칙어 포함
--   NW011 레이트 리밋                         NW012 토큰 무효·만료(뉴스레터)
--   NW013 정부광고 직판 금지                  NW014 플랜 한도 초과·구독 끊김(기능 없음)
--   NW015 입력 오류                         NW016 자기 기사 자기 승인 금지(발행인 1인 신문사 예외)
--   그 밖: 42501 권한, P0002 없음, 22023 상태 전이·불변 컬럼 위반, 23514 CHECK, 23503 교차 조직 참조, 23505 중복
begin;

create schema nomad_news;
comment on schema nomad_news is 'news(local-news): 지역신문 멀티테넌트 뉴스룸(편집국·독자 사이트·광고·뉴스레터·법정 준수)';
revoke all on schema nomad_news from public, anon, authenticated;
-- anon usage: 공개 읽기 RPC 가 있어서만 준다. 표 grant 는 없다.
grant usage on schema nomad_news to anon, authenticated, service_role;
alter default privileges in schema nomad_news grant all on tables to service_role;
alter default privileges in schema nomad_news grant all on sequences to service_role;
alter default privileges in schema nomad_news revoke execute on functions from public;

-- 검색: tsvector('simple') + pg_trgm(원본 결정 D-7).
-- pg_trgm은 core 마이그레이션(*_nomad_core_pg_trgm.sql)이 extensions 스키마에 설치한다(2026-11-16 결정 5). 없으면 분명하게 중단
do $$
begin
  if not exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_trgm' and n.nspname = 'extensions') then
    raise exception 'pg_trgm 확장이 extensions 스키마에 없다 — core 마이그레이션 *_nomad_core_pg_trgm.sql을 먼저 적용한다' using errcode = '55000';
  end if;
end $$;

insert into nomad_core.products (code, name) values ('news', 'Local News Cloud') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values ('news', 'A', 'A'), ('news', 'B', 'B'), ('news', 'C', 'C')
  on conflict do nothing;
-- 원본 plans.features 불리언 → 기능 이용권. 수치 키 → plan_limits(시드 없음).
insert into nomad_core.features (product_code, code, name) values
  ('news', 'newsroom',          '편집국·독자 사이트 운영(원본 has_entitlement news). 없으면 쓰기 잠금'),
  ('news', 'print_pdf',         '지면 PDF(원본 news_print_pdf)'),
  ('news', 'regional_editions', '지역판(원본 news_regional_editions, 서버 판정)'),
  ('news', 'api',               'API 접근(원본 news_api, 서버 판정)'),
  ('news', 'support_reports',   '지원 리포트(원본 news_support_reports, 서버 판정)')
on conflict do nothing;
-- A = 원본 pro(엔터프라이즈 포함), B = 원본 starter·standard(체험 포함), C = 구독 없음·끊김(기능 없음 → 공개분 열람만). 팀장 확인 필요.
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'news', p, 'newsroom' from unnest(array['A', 'B']) p
union all
select 'news', 'A', f from unnest(array['print_pdf', 'regional_editions', 'api', 'support_reports']) f
on conflict do nothing;
-- plan_limits 키(시드 없음, 키 없으면 0 = fail-closed): news_staff_max(DB, 발행인 포함 편집국 인원) · news_reader_fee_bps(DB, 플랫폼 수수료)
--   · 서버 몫: news_newsletter_monthly · news_custom_domains · news_storage_gb · ai_monthly_credits · theming_level. 무제한 = 2147483647.

-- N3: 신문사 자기 Toss 가맹 키(조직별 provider_credentials, 등록·교체·폐기는 core owner·admin 만). D10 예외 — 데이터 1행.
insert into nomad_core.api_providers (code, name) values ('toss_merchant', '토스페이먼츠 가맹(신문사)') on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 0. 검증 헬퍼 (IMMUTABLE, CHECK 제약에서 사용)
--    Storage 경로 규칙: <organization_id>/news/<folder>/<파일>. 첫 폴더가 organization_id(버킷 정책은 코어 버킷 계약 확정 시).
-- ---------------------------------------------------------------------
create function nomad_news.is_org_path(p_org uuid, p_path text, p_folder text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_org is not null and p_path is not null
     and char_length(p_path) <= 300
     and p_path like p_org::text || '/news/' || p_folder || '/%'
     and p_path ~ '^[0-9a-f-]{36}/news/[a-z]+/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
     and p_path !~ '(^|/)\.\.?(/|$)';
$$;

create function nomad_news.are_org_paths(p_org uuid, p_paths text[], p_folder text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(bool_and(nomad_news.is_org_path(p_org, x, p_folder)), true) from unnest(p_paths) as x;
$$;

-- =====================================================================
-- M1. newsroom-cms (+ M7 매체정보)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1.1 newspaper_applications: 신문사 개설 신청(N2). 신청자가 먼저 nomad_core.create_team_organization 으로 조직(owner)을 만든다.
--     원본은 조직이 승인 때 생겨 org_id nullable·applicant_org_id(개인 조직)였다 → 이식은 organization_id not null(신청 조직).
--     상태: pending -> approved | rejected | withdrawn
-- ---------------------------------------------------------------------
create table nomad_news.newspaper_applications (
  id                 uuid primary key default gen_random_uuid(),
  applicant_id       uuid not null references auth.users(id) on delete cascade,
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  slug               text not null constraint newspaper_applications_slug_check check (slug ~ '^[a-z][a-z0-9-]{1,30}[a-z0-9]$'),
  title              text not null constraint newspaper_applications_title_check check (char_length(btrim(title)) between 1 and 80),
  media_kind         text not null constraint newspaper_applications_media_kind_check check (media_kind in ('internet', 'daily', 'weekly', 'monthly', 'other')),
  registration_no    text not null constraint newspaper_applications_registration_no_check check (char_length(btrim(registration_no)) between 2 and 40),
  registration_date  date not null,
  publisher_name     text not null constraint newspaper_applications_publisher_name_check check (char_length(btrim(publisher_name)) between 1 and 40),
  contact_email      text not null constraint newspaper_applications_contact_email_check check (char_length(contact_email) <= 254 and contact_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  contact_phone      text not null constraint newspaper_applications_contact_phone_check check (contact_phone ~ '^[0-9+() -]{6,30}$'),
  certificate_path   text not null,
  message            text constraint newspaper_applications_message_check check (message is null or char_length(message) <= 2000),
  plan_code          text constraint newspaper_applications_plan_code_check check (plan_code is null or plan_code in ('A', 'B')),
  status             text not null default 'pending'
                     constraint newspaper_applications_status_check check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  decided_at         timestamptz,
  decided_by         uuid,
  decision_note      text constraint newspaper_applications_decision_note_check check (decision_note is null or char_length(decision_note) <= 1000),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint newspaper_applications_certificate_path_check check (nomad_news.is_org_path(organization_id, certificate_path, 'applications'))
);
create unique index newspaper_applications_pending_slug_uniq on nomad_news.newspaper_applications (slug) where status = 'pending';
create unique index newspaper_applications_pending_org_uniq on nomad_news.newspaper_applications (organization_id) where status = 'pending';
create index newspaper_applications_applicant_idx on nomad_news.newspaper_applications (applicant_id);
create index newspaper_applications_org_idx on nomad_news.newspaper_applications (organization_id);
create index newspaper_applications_status_idx on nomad_news.newspaper_applications (status, created_at);
comment on table nomad_news.newspaper_applications is '신문사 개설 신청(신청 조직 owner). 등록증 사본 경로 <organization_id>/news/applications/. 승인·반려는 service_role(운영자 서버)만, 플랜 부여는 외부 결제 서버';

-- ---------------------------------------------------------------------
-- 1.2 newspapers: 신문사 1곳 1행. 매체정보(신문법 제21조 필요적 게재사항 + 시행령 제7조의2 청소년보호책임자).
--     profile_completed_at 은 트리거가 계산한다(사용자·서버 모두 직접 지정 불가). null 이면 독자 사이트 비공개.
--     상태: active -> suspended | closed, suspended -> active | closed
-- ---------------------------------------------------------------------
create table nomad_news.newspapers (
  id                    uuid primary key default gen_random_uuid(),
  organization_id                uuid not null unique references nomad_core.organizations(id) on delete cascade,
  application_id        uuid references nomad_news.newspaper_applications(id) on delete set null,
  slug                  text not null unique constraint newspapers_slug_check check (slug ~ '^[a-z][a-z0-9-]{1,30}[a-z0-9]$'),
  status                text not null default 'active'
                        constraint newspapers_status_check check (status in ('active', 'suspended', 'closed')),
  title                 text not null constraint newspapers_title_check check (char_length(btrim(title)) between 1 and 80),
  legal_name            text constraint newspapers_legal_name_check check (legal_name is null or char_length(btrim(legal_name)) between 1 and 80),
  media_kind            text not null default 'internet'
                        constraint newspapers_media_kind_check check (media_kind in ('internet', 'daily', 'weekly', 'monthly', 'other')),
  registration_no       text constraint newspapers_registration_no_check check (registration_no is null or char_length(btrim(registration_no)) between 2 and 40),
  registration_date     date,
  publisher_name        text constraint newspapers_publisher_name_check check (publisher_name is null or char_length(btrim(publisher_name)) between 1 and 40),
  editor_name           text constraint newspapers_editor_name_check check (editor_name is null or char_length(btrim(editor_name)) between 1 and 40),
  youth_officer_name    text constraint newspapers_youth_officer_name_check check (youth_officer_name is null or char_length(btrim(youth_officer_name)) between 1 and 40),
  privacy_officer_name  text constraint newspapers_privacy_officer_name_check check (privacy_officer_name is null or char_length(btrim(privacy_officer_name)) between 1 and 40),
  publish_address       text constraint newspapers_publish_address_check check (publish_address is null or char_length(btrim(publish_address)) between 5 and 200),
  phone                 text constraint newspapers_phone_check check (phone is null or phone ~ '^[0-9+() -]{6,30}$'),
  email                 text constraint newspapers_email_check check (email is null or (char_length(email) <= 254 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  first_published_on    date,
  ethics_code_url       text constraint newspapers_ethics_code_url_check check (ethics_code_url is null or (char_length(ethics_code_url) <= 300 and ethics_code_url ~ '^(https://[^[:space:]]{3,}|/[A-Za-z0-9/_-]{0,100})$')),
  comments_enabled      boolean not null default false,
  banned_words          text[] not null default '{}' constraint newspapers_banned_words_check check (cardinality(banned_words) <= 500),
  profile_completed_at  timestamptz,
  status_reason         text constraint newspapers_status_reason_check check (status_reason is null or char_length(status_reason) <= 500),
  plan_lapsed_at        timestamptz,
  created_by            uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on column nomad_news.newspapers.profile_completed_at is '필요적 게재사항 10개가 모두 채워진 시각(트리거 계산). null 이면 nomad_news.is_public_newspaper = false';
comment on column nomad_news.newspapers.plan_lapsed_at is '구독 끊김(기능 newsroom 없음)을 처음 본 시각. run_scheduled_publishing 이 매분 기록·해제. 끊김 중 이 시각 뒤에 풀린 엠바고 기사는 비공개(S2)';
comment on column nomad_news.newspapers.comments_enabled is '신문사 댓글 스위치. 기본 끔(결정 D-6). 기사별 articles.comments_enabled 와 AND';

create function nomad_news.newspapers_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_complete boolean;
begin
  if tg_op = 'UPDATE' then
    if new.organization_id is distinct from old.organization_id or new.slug is distinct from old.slug then
      raise exception 'newspapers: organization_id/slug are immutable' using errcode = '22023';
    end if;
    if new.status is distinct from old.status and not (
         (old.status = 'active'    and new.status in ('suspended', 'closed'))
      or (old.status = 'suspended' and new.status in ('active', 'closed'))
    ) then
      raise exception 'newspapers: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
  end if;
  v_complete := new.title is not null and new.legal_name is not null and new.registration_no is not null
            and new.registration_date is not null and new.publisher_name is not null and new.editor_name is not null
            and new.youth_officer_name is not null and new.publish_address is not null and new.phone is not null
            and new.first_published_on is not null;
  if v_complete then
    new.profile_completed_at := case when tg_op = 'UPDATE' and old.profile_completed_at is not null then old.profile_completed_at else now() end;
  else
    new.profile_completed_at := null;
  end if;
  return new;
end;
$$;
create trigger newspapers_before_write before insert or update on nomad_news.newspapers
  for each row execute function nomad_news.newspapers_before_write();

-- ---------------------------------------------------------------------
-- 1.3 staff: 편집국 구성원과 도메인 역할. nomad_core.memberships 와 1:1(같은 organization_id, user_id).
--     코어 역할 매핑(N3): publisher = 조직 owner(승인 때 1회), 나머지 5종 = core editor(초대 역할). core admin 은 주지 않는다.
--     상태: invited -> active | removed, active -> removed, removed -> invited (재초대)
-- ---------------------------------------------------------------------
create table nomad_news.staff (
  id                 uuid primary key default gen_random_uuid(),
  organization_id             uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  role               text not null
                     constraint staff_role_check check (role in ('publisher', 'editor', 'desk', 'reporter', 'contributor', 'ad_manager')),
  status             text not null default 'invited'
                     constraint staff_status_check check (status in ('invited', 'active', 'removed')),
  byline_name        text not null constraint staff_byline_name_check check (char_length(btrim(byline_name)) between 1 and 40),
  title_label        text constraint staff_title_label_check check (title_label is null or char_length(btrim(title_label)) between 1 and 40),
  bio                text constraint staff_bio_check check (bio is null or char_length(bio) <= 500),
  photo_path         text,
  email_public       text constraint staff_email_public_check check (email_public is null or (char_length(email_public) <= 254 and email_public ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  is_public_profile  boolean not null default true,
  invited_by         uuid,
  joined_at          timestamptz,
  removed_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (organization_id, user_id),
  constraint staff_photo_path_check check (photo_path is null or nomad_news.is_org_path(organization_id, photo_path, 'staff'))
);
create unique index staff_one_publisher_idx on nomad_news.staff (organization_id) where role = 'publisher' and status <> 'removed';
create index staff_user_idx on nomad_news.staff (user_id) where status = 'active';
create index staff_org_idx on nomad_news.staff (organization_id, status);

create function nomad_news.staff_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.user_id is distinct from old.user_id then
    raise exception 'staff: organization_id/user_id are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'invited' and new.status in ('active', 'removed'))
      or (old.status = 'active'  and new.status = 'removed')
      or (old.status = 'removed' and new.status = 'invited')
    ) then
      raise exception 'staff: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'active'  then new.joined_at := coalesce(new.joined_at, now()); end if;
    if new.status = 'removed' then new.removed_at := now(); end if;
    if new.status = 'invited' then new.removed_at := null; new.joined_at := null; end if;
  end if;
  return new;
end;
$$;
create trigger staff_before_update before update on nomad_news.staff
  for each row execute function nomad_news.staff_before_update();

-- 1.3b staff_invitations(이식 추가): core 초대(nomad_core.invitations, email+token, 역할 editor)에 붙는 도메인 역할·바이라인.
--     invite_staff 가 core create_invitation 과 함께 만들고, accept_staff_invitation 이 core accept_invitation 뒤 staff 행으로 옮긴다.
--     core 초대가 취소(revoke_invitation)되면 같이 지워진다.
create table nomad_news.staff_invitations (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  invitation_id   uuid not null unique references nomad_core.invitations(id) on delete cascade,
  role            text not null constraint staff_invitations_role_check check (role in ('editor', 'desk', 'reporter', 'contributor', 'ad_manager')),
  byline_name     text not null constraint staff_invitations_byline_name_check check (char_length(btrim(byline_name)) between 1 and 40),
  title_label     text constraint staff_invitations_title_label_check check (title_label is null or char_length(btrim(title_label)) between 1 and 40),
  invited_by      uuid,
  accepted_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index staff_invitations_org_idx on nomad_news.staff_invitations (organization_id, created_at desc);
comment on table nomad_news.staff_invitations is '편집국 초대의 도메인 역할(core 초대 1:1). 쓰기는 invite_staff·accept_staff_invitation 만';

-- ---------------------------------------------------------------------
-- 1.4 sections / regions / tags: 분류. 삭제하지 않고 is_active=false 로 내린다(기사 FK 보존).
-- ---------------------------------------------------------------------
create table nomad_news.sections (
  id          uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  slug        text not null constraint sections_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  name        text not null constraint sections_name_check check (char_length(btrim(name)) between 1 and 40),
  parent_id   uuid,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (organization_id, slug),
  unique (id, organization_id),
  foreign key (parent_id, organization_id) references nomad_news.sections (id, organization_id)
);

create table nomad_news.regions (
  id          uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  slug        text not null constraint regions_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  name        text not null constraint regions_name_check check (char_length(btrim(name)) between 1 and 40),
  level       text not null default 'sigungu'
              constraint regions_level_check check (level in ('sido', 'sigungu', 'eupmyeondong', 'custom')),
  admin_code  text constraint regions_admin_code_check check (admin_code is null or admin_code ~ '^[0-9]{2,10}$'),
  parent_id   uuid,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (organization_id, slug),
  unique (id, organization_id),
  foreign key (parent_id, organization_id) references nomad_news.regions (id, organization_id)
);

create table nomad_news.tags (
  id          uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  slug        text not null constraint tags_slug_check check (slug ~ '^[0-9a-z가-힣][0-9a-z가-힣-]{0,39}$'),
  name        text not null constraint tags_name_check check (char_length(btrim(name)) between 1 and 40),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (organization_id, slug),
  unique (id, organization_id)
);

-- ---------------------------------------------------------------------
-- 6.1(선행) wire_contracts: 통신사 전재 계약(M6). articles 가 참조하므로 먼저 만든다.
--     만료(ends_on < KST 오늘) 또는 terminated 이면 그 계약의 wire 기사는 공개 조건에서 빠진다.
-- ---------------------------------------------------------------------
create table nomad_news.wire_contracts (
  id                uuid primary key default gen_random_uuid(),
  organization_id            uuid not null references nomad_core.organizations(id) on delete cascade,
  provider          text not null constraint wire_contracts_provider_check check (provider in ('yonhap', 'newsis', 'news1', 'other')),
  name              text not null constraint wire_contracts_name_check check (char_length(btrim(name)) between 1 and 80),
  contract_no       text constraint wire_contracts_contract_no_check check (contract_no is null or char_length(contract_no) <= 60),
  starts_on         date not null,
  ends_on           date,
  attribution_text  text not null constraint wire_contracts_attribution_text_check check (char_length(btrim(attribution_text)) between 2 and 100),
  allow_full_text   boolean not null default true,
  status            text not null default 'active' constraint wire_contracts_status_check check (status in ('active', 'terminated')),
  note              text constraint wire_contracts_note_check check (note is null or char_length(note) <= 1000),
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, organization_id),
  constraint wire_contracts_period_check check (ends_on is null or ends_on >= starts_on)
);

-- ---------------------------------------------------------------------
-- 1.5 media_assets: 미디어 라이브러리. 저작권·출처(credit)·대체텍스트(alt) 필수(NW-F-014).
--     published_at: 공개 기사가 처음 참조한 시각(publish_article 이 기록). null 인 사진은 anon 이 목록으로 볼 수 없다.
-- ---------------------------------------------------------------------
create table nomad_news.media_assets (
  id                uuid primary key default gen_random_uuid(),
  organization_id            uuid not null references nomad_core.organizations(id) on delete cascade,
  bucket            text not null default 'public-assets' constraint media_assets_bucket_check check (bucket in ('public-assets', 'org-files')),
  storage_path      text not null,
  kind              text not null default 'image' constraint media_assets_kind_check check (kind in ('image', 'video', 'audio', 'document')),
  mime              text not null constraint media_assets_mime_check check (mime ~ '^(image|video|audio|application)/[a-z0-9.+-]{1,60}$'),
  width             integer constraint media_assets_width_check check (width is null or width between 1 and 20000),
  height            integer constraint media_assets_height_check check (height is null or height between 1 and 20000),
  bytes             bigint constraint media_assets_bytes_check check (bytes is null or bytes between 1 and 524288000),
  alt_text          text not null constraint media_assets_alt_text_check check (char_length(btrim(alt_text)) between 1 and 300),
  caption           text constraint media_assets_caption_check check (caption is null or char_length(caption) <= 500),
  credit            text not null constraint media_assets_credit_check check (char_length(btrim(credit)) between 1 and 200),
  copyright_holder  text constraint media_assets_copyright_holder_check check (copyright_holder is null or char_length(copyright_holder) <= 200),
  license           text not null default 'own'
                    constraint media_assets_license_check check (license in ('own', 'wire', 'licensed', 'cc', 'reader', 'press_release', 'other')),
  ai_generated      boolean not null default false,
  ai_disclosure     text,
  status            text not null default 'active' constraint media_assets_status_check check (status in ('active', 'archived')),
  published_at      timestamptz,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, organization_id),
  unique (bucket, storage_path),
  constraint media_assets_storage_path_check check (nomad_news.is_org_path(organization_id, storage_path, 'media')),
  constraint media_assets_ai_disclosure_check check (not ai_generated or (ai_disclosure is not null and char_length(btrim(ai_disclosure)) between 5 and 300))
);
create index media_assets_org_created_idx on nomad_news.media_assets (organization_id, created_at desc);

-- ---------------------------------------------------------------------
-- 1.6 articles: 기사. 워크플로(NW-F-012)는 트리거가 강제하고 누가 하는지는 RPC 가 강제한다.
--     draft -> submitted | archived
--     submitted -> approved | draft(반려·회수)
--     approved -> scheduled | published | draft
--     scheduled -> published | approved(예약 취소)
--     published -> unpublished | archived
--     unpublished -> published(재게시) | draft | archived
--     archived -> (없음)
--     유형(type): original 자체 / wire 전재 / press_release 보도자료 / contribution 기고 / sponsored 기사형 광고
--     출처(origin): human / ai_press_release(보도자료 AI 초안, type 은 press_release 고정) / import(이관). 만든 뒤 바꿀 수 없다.
-- ---------------------------------------------------------------------
create table nomad_news.articles (
  id                  uuid primary key default gen_random_uuid(),
  organization_id              uuid not null references nomad_core.organizations(id) on delete cascade,
  slug                text not null constraint articles_slug_check check (slug ~ '^[0-9a-z가-힣][0-9a-z가-힣-]{0,119}$'),
  title               text not null constraint articles_title_check check (char_length(btrim(title)) between 1 and 300),
  subtitle            text constraint articles_subtitle_check check (subtitle is null or char_length(subtitle) <= 300),
  summary             text constraint articles_summary_check check (summary is null or char_length(summary) <= 1000),
  body                jsonb not null default '[]'::jsonb constraint articles_body_check check (jsonb_typeof(body) = 'array' and jsonb_array_length(body) <= 2000),
  body_text           text not null default '' constraint articles_body_text_check check (char_length(body_text) <= 200000),
  type                text not null default 'original'
                      constraint articles_type_check check (type in ('original', 'wire', 'press_release', 'contribution', 'sponsored')),
  origin              text not null default 'human'
                      constraint articles_origin_check check (origin in ('human', 'ai_press_release', 'import')),
  section_id          uuid,
  author_id           uuid,
  byline              text not null constraint articles_byline_check check (char_length(btrim(byline)) between 1 and 100),
  status              text not null default 'draft'
                      constraint articles_status_check check (status in ('draft', 'submitted', 'approved', 'scheduled', 'published', 'unpublished', 'archived')),
  is_premium          boolean not null default false,
  sponsor_label       text,
  ai_assisted         boolean not null default false,
  ai_disclosure       text,
  wire_contract_id    uuid,
  source_note         text constraint articles_source_note_check check (source_note is null or char_length(source_note) <= 300),
  is_poll             boolean not null default false,
  poll_disclosure     text,
  is_breaking         boolean not null default false,
  is_live             boolean not null default false,
  comments_enabled    boolean not null default true,
  embargo_until       timestamptz,
  hero_media_id       uuid,
  media_ids           uuid[] not null default '{}' constraint articles_media_ids_check check (cardinality(media_ids) <= 200),
  seo                 jsonb not null default '{}'::jsonb constraint articles_seo_check check (jsonb_typeof(seo) = 'object'),
  review_note         text constraint articles_review_note_check check (review_note is null or char_length(review_note) <= 2000),
  submitted_at        timestamptz,
  submitted_by        uuid,
  approved_at         timestamptz,
  approved_by         uuid,
  scheduled_for       timestamptz,
  published_at        timestamptz,
  first_published_at  timestamptz,
  unpublished_at      timestamptz,
  unpublish_reason    text constraint articles_unpublish_reason_check check (unpublish_reason is null or char_length(unpublish_reason) <= 500),
  archived_at         timestamptz,
  revised_at          timestamptz,
  revision_note       text constraint articles_revision_note_check check (revision_note is null or char_length(revision_note) <= 500),
  revision_count      integer not null default 0,
  last_corrected_at   timestamptz,
  correction_count    integer not null default 0,
  legacy_id           text constraint articles_legacy_id_check check (legacy_id is null or char_length(legacy_id) <= 200),
  legacy_url          text constraint articles_legacy_url_check check (legacy_url is null or char_length(legacy_url) <= 1000),
  search_tsv          tsvector,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (organization_id, slug),
  unique (id, organization_id),
  foreign key (section_id, organization_id) references nomad_news.sections (id, organization_id),
  foreign key (wire_contract_id, organization_id) references nomad_news.wire_contracts (id, organization_id),
  foreign key (hero_media_id, organization_id) references nomad_news.media_assets (id, organization_id),
  -- 신문법 제6조 제3항: 기사형 광고는 허용 목록의 라벨이 반드시 붙고, 다른 유형에는 라벨을 붙이지 않는다
  constraint articles_sponsor_label_check check (
    (type = 'sponsored' and sponsor_label is not null and sponsor_label in ('광고', '기사형 광고', '후원 콘텐츠', '협찬', 'AD'))
    or (type <> 'sponsored' and sponsor_label is null)),
  -- AI기본법·언론계 생성형 AI 준칙: AI 보조 기사는 고지 문구 필수
  constraint articles_ai_disclosure_check check (not ai_assisted or (ai_disclosure is not null and char_length(btrim(ai_disclosure)) between 5 and 300)),
  -- 보도자료 AI 초안은 보도자료 유형과 AI 표시를 유지한다(자체기사로 세탁 금지, 결정 D-9)
  constraint articles_ai_origin_check check (origin <> 'ai_press_release' or (type = 'press_release' and ai_assisted)),
  constraint articles_wire_contract_check check (wire_contract_id is null or type = 'wire'),
  -- 공직선거법 제108조: 여론조사 보도는 조사기관·표본 등 필수 표시
  constraint articles_poll_disclosure_check check (not is_poll or (poll_disclosure is not null and char_length(btrim(poll_disclosure)) between 10 and 1000)),
  constraint articles_published_at_check check (status not in ('published', 'unpublished') or (published_at is not null and first_published_at is not null)),
  constraint articles_scheduled_for_check check (status <> 'scheduled' or scheduled_for is not null)
);
create index articles_org_status_idx on nomad_news.articles (organization_id, status, updated_at desc);
create index articles_public_idx on nomad_news.articles (organization_id, published_at desc) where status = 'published';
create index articles_section_public_idx on nomad_news.articles (organization_id, section_id, published_at desc) where status = 'published';
create index articles_scheduled_idx on nomad_news.articles (scheduled_for) where status = 'scheduled';
create index articles_first_published_idx on nomad_news.articles (organization_id, first_published_at) where first_published_at is not null;
create index articles_author_idx on nomad_news.articles (organization_id, created_by, status);
create index articles_search_idx on nomad_news.articles using gin (search_tsv);
create index articles_title_trgm_idx on nomad_news.articles using gin (title extensions.gin_trgm_ops);
create unique index articles_legacy_uniq on nomad_news.articles (organization_id, legacy_id) where legacy_id is not null;

create function nomad_news.articles_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.organization_id is distinct from old.organization_id or new.origin is distinct from old.origin
       or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
      raise exception 'articles: organization_id/origin/created_by/created_at are immutable' using errcode = '22023';
    end if;
    if old.first_published_at is not null and new.first_published_at is distinct from old.first_published_at then
      raise exception 'articles: first_published_at is immutable' using errcode = '22023';
    end if;
    if new.status is distinct from old.status then
      if not (
           (old.status = 'draft'       and new.status in ('submitted', 'archived'))
        or (old.status = 'submitted'   and new.status in ('approved', 'draft'))
        or (old.status = 'approved'    and new.status in ('scheduled', 'published', 'draft'))
        or (old.status = 'scheduled'   and new.status in ('published', 'approved'))
        or (old.status = 'published'   and new.status in ('unpublished', 'archived'))
        or (old.status = 'unpublished' and new.status in ('published', 'draft', 'archived'))
      ) then
        raise exception 'articles: invalid status transition % -> %', old.status, new.status using errcode = '22023';
      end if;
      if new.status = 'submitted' then new.submitted_at := now(); end if;
      if new.status = 'approved' and old.status = 'submitted' then new.approved_at := now(); end if;
      if new.status = 'draft' then new.approved_at := null; new.approved_by := null; new.scheduled_for := null; end if;
      if new.status = 'approved' and old.status = 'scheduled' then new.scheduled_for := null; end if;
      if new.status = 'published' then
        new.published_at := coalesce(case when old.status = 'scheduled' then old.scheduled_for end, now());
        new.first_published_at := coalesce(old.first_published_at, new.published_at);
        new.unpublished_at := null;
      end if;
      if new.status = 'unpublished' then new.unpublished_at := now(); end if;
      if new.status = 'archived' then new.archived_at := now(); end if;
    end if;
  else
    if new.status <> 'draft' then
      raise exception 'articles: new articles start as draft' using errcode = '22023';
    end if;
  end if;
  new.search_tsv :=
       setweight(to_tsvector('simple'::regconfig, coalesce(new.title, '')), 'A')
    || setweight(to_tsvector('simple'::regconfig, coalesce(new.subtitle, '') || ' ' || coalesce(new.summary, '')), 'B')
    -- 프리미엄 본문은 색인하지 않는다(공개 검색으로 유료 본문 단어 존재가 드러나지 않게, S4). 제목·부제·요약만
    || setweight(to_tsvector('simple'::regconfig, case when new.is_premium then '' else left(coalesce(new.body_text, ''), 100000) end), 'C');
  return new;
end;
$$;
create trigger articles_before_write before insert or update on nomad_news.articles
  for each row execute function nomad_news.articles_before_write();

-- ---------------------------------------------------------------------
-- 1.7 article_revisions: 저장·워크플로·정정 이력(append-only). is_public=true 인 행의 note 만 독자에게 보인다
--     (nomad_news.read_article 이 수정·정정 이력으로 돌려준다. NW-F-017).
-- ---------------------------------------------------------------------
create table nomad_news.article_revisions (
  id                     uuid primary key default gen_random_uuid(),
  organization_id                 uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id             uuid not null,
  kind                   text not null constraint article_revisions_kind_check check (kind in (
                           'save', 'submit', 'approve', 'reject', 'schedule', 'publish', 'unpublish', 'archive',
                           'update', 'correction', 'clarification', 'rebuttal', 'follow_up')),
  status_after           text not null,
  title                  text,
  body                   jsonb,
  note                   text constraint article_revisions_note_check check (note is null or char_length(note) <= 2000),
  is_public              boolean not null default false,
  correction_request_id  uuid,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete cascade,
  constraint article_revisions_public_note_check check (not is_public or (note is not null and kind in ('update', 'correction', 'clarification', 'rebuttal', 'follow_up')))
);
create index article_revisions_article_idx on nomad_news.article_revisions (article_id, created_at desc);

create function nomad_news.article_revisions_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'nomad_news.article_revisions is append-only' using errcode = '22023';
end;
$$;
create trigger article_revisions_immutable before update on nomad_news.article_revisions
  for each row execute function nomad_news.article_revisions_immutable();

-- ---------------------------------------------------------------------
-- 1.8 article_regions / article_tags: 기사-지역, 기사-태그 (save_article 이 통째로 바꾼다)
-- ---------------------------------------------------------------------
create table nomad_news.article_regions (
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id  uuid not null,
  region_id   uuid not null,
  created_at  timestamptz not null default now(),
  primary key (article_id, region_id),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete cascade,
  foreign key (region_id, organization_id) references nomad_news.regions (id, organization_id)
);
create index article_regions_region_idx on nomad_news.article_regions (organization_id, region_id);

create table nomad_news.article_tags (
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id  uuid not null,
  tag_id      uuid not null,
  created_at  timestamptz not null default now(),
  primary key (article_id, tag_id),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete cascade,
  foreign key (tag_id, organization_id) references nomad_news.tags (id, organization_id)
);
create index article_tags_tag_idx on nomad_news.article_tags (organization_id, tag_id);

-- ---------------------------------------------------------------------
-- 1.9 home_layouts: 홈 편집(NW-F-013). 템플릿 traditional(A)·magazine(B)·feed(C), 블록 배열.
--     draft -> scheduled | published | archived, scheduled -> draft | published, published -> archived, archived -> (없음)
--     조직당 published 1개(부분 유니크). 새 판을 게시하면 이전 게시본은 archived.
-- ---------------------------------------------------------------------
create table nomad_news.home_layouts (
  id            uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references nomad_core.organizations(id) on delete cascade,
  name          text not null constraint home_layouts_name_check check (char_length(btrim(name)) between 1 and 80),
  template      text not null constraint home_layouts_template_check check (template in ('traditional', 'magazine', 'feed')),
  blocks        jsonb not null default '[]'::jsonb constraint home_layouts_blocks_check check (jsonb_typeof(blocks) = 'array' and jsonb_array_length(blocks) <= 60),
  status        text not null default 'draft' constraint home_layouts_status_check check (status in ('draft', 'scheduled', 'published', 'archived')),
  publish_at    timestamptz,
  published_at  timestamptz,
  published_by  uuid,
  version       integer not null default 0,
  archived_at   timestamptz,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint home_layouts_publish_at_check check (status <> 'scheduled' or publish_at is not null)
);
create unique index home_layouts_one_published_idx on nomad_news.home_layouts (organization_id) where status = 'published';
create index home_layouts_scheduled_idx on nomad_news.home_layouts (publish_at) where status = 'scheduled';

create function nomad_news.home_layouts_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'home_layouts: organization_id is immutable' using errcode = '22023';
  end if;
  if old.status in ('published', 'archived') and (new.blocks is distinct from old.blocks or new.template is distinct from old.template) then
    raise exception 'home_layouts: published layouts are read-only (clone instead)' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'draft'     and new.status in ('scheduled', 'published', 'archived'))
      or (old.status = 'scheduled' and new.status in ('draft', 'published'))
      or (old.status = 'published' and new.status = 'archived')
    ) then
      raise exception 'home_layouts: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'published' then new.published_at := now(); end if;
    if new.status = 'archived'  then new.archived_at := now(); end if;
    if new.status = 'draft'     then new.publish_at := null; end if;
  end if;
  return new;
end;
$$;
create trigger home_layouts_before_update before update on nomad_news.home_layouts
  for each row execute function nomad_news.home_layouts_before_update();

-- ---------------------------------------------------------------------
-- 1.10 print_editions: 지면 PDF(NW-F-015, Pro). PDF 는 org-files/<org>/news/print/ (서명 URL 로 제공)
-- ---------------------------------------------------------------------
create table nomad_news.print_editions (
  id            uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references nomad_core.organizations(id) on delete cascade,
  edition_date  date not null,
  issue_no      integer constraint print_editions_issue_no_check check (issue_no is null or issue_no between 1 and 1000000),
  title         text constraint print_editions_title_check check (title is null or char_length(title) <= 120),
  pdf_path      text not null,
  page_count    integer constraint print_editions_page_count_check check (page_count is null or page_count between 1 and 400),
  status        text not null default 'draft' constraint print_editions_status_check check (status in ('draft', 'published', 'archived')),
  published_at  timestamptz,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint print_editions_pdf_path_check check (nomad_news.is_org_path(organization_id, pdf_path, 'print') and pdf_path like '%.pdf')
);
create unique index print_editions_issue_uniq on nomad_news.print_editions (organization_id, issue_no) where issue_no is not null;
create index print_editions_org_date_idx on nomad_news.print_editions (organization_id, edition_date desc);

-- ---------------------------------------------------------------------
-- 1.11 live_updates: 라이브 기사 타임라인(NW-F-016)
-- ---------------------------------------------------------------------
create table nomad_news.live_updates (
  id          uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id  uuid not null,
  body        text not null constraint live_updates_body_check check (char_length(btrim(body)) between 1 and 5000),
  is_pinned   boolean not null default false,
  status      text not null default 'visible' constraint live_updates_status_check check (status in ('visible', 'hidden')),
  posted_at   timestamptz not null default now(),
  posted_by   uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete cascade
);
create index live_updates_article_idx on nomad_news.live_updates (article_id, posted_at desc);

-- =====================================================================
-- M2. reader-membership
-- =====================================================================

-- ---------------------------------------------------------------------
-- 2.1 readers: 신문사별 독자 행. 같은 사람이 A·B 신문의 독자가 될 수 있다(플랫폼 공통 계정). 조직 멤버가 아니다.
--     만 14세 미만 가입은 받지 않는다(is_over_14 = true 필수, 법정대리인 동의 흐름은 Phase 2).
--     상태: active -> blocked | withdrawn, blocked -> active | withdrawn, withdrawn -> active(재가입)
-- ---------------------------------------------------------------------
create table nomad_news.readers (
  id                   uuid primary key default gen_random_uuid(),
  organization_id               uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id              uuid not null references auth.users(id) on delete cascade,
  nickname             text not null constraint readers_nickname_check check (char_length(btrim(nickname)) between 2 and 20),
  email                text constraint readers_email_check check (email is null or (char_length(email) <= 254 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  status               text not null default 'active' constraint readers_status_check check (status in ('active', 'blocked', 'withdrawn')),
  blocked_reason       text constraint readers_blocked_reason_check check (blocked_reason is null or char_length(blocked_reason) <= 500),
  blocked_at           timestamptz,
  is_over_14           boolean not null constraint readers_is_over_14_check check (is_over_14),
  terms_version        text not null constraint readers_terms_version_check check (char_length(terms_version) between 1 and 32),
  privacy_version      text not null constraint readers_privacy_version_check check (char_length(privacy_version) between 1 and 32),
  consent_at           timestamptz not null default now(),
  marketing_opt_in     boolean not null default false,
  marketing_opt_in_at  timestamptz,
  region_id            uuid,
  last_seen_at         timestamptz,
  withdrawn_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (organization_id, user_id),
  unique (id, organization_id),
  foreign key (region_id, organization_id) references nomad_news.regions (id, organization_id)
);
create unique index readers_nickname_uniq on nomad_news.readers (organization_id, lower(nickname)) where status <> 'withdrawn';
create index readers_org_created_idx on nomad_news.readers (organization_id, created_at desc);

create function nomad_news.readers_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.user_id is distinct from old.user_id then
    raise exception 'readers: organization_id/user_id are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'active'    and new.status in ('blocked', 'withdrawn'))
      or (old.status = 'blocked'   and new.status in ('active', 'withdrawn'))
      or (old.status = 'withdrawn' and new.status = 'active')
    ) then
      raise exception 'readers: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'blocked'   then new.blocked_at := now(); end if;
    if new.status = 'active'    then new.blocked_at := null; new.blocked_reason := null; new.withdrawn_at := null; end if;
    if new.status = 'withdrawn' then new.withdrawn_at := now(); new.email := null; new.marketing_opt_in := false; end if;
  end if;
  if new.marketing_opt_in and not old.marketing_opt_in then new.marketing_opt_in_at := now(); end if;
  return new;
end;
$$;
create trigger readers_before_update before update on nomad_news.readers
  for each row execute function nomad_news.readers_before_update();

-- ---------------------------------------------------------------------
-- 2.2 membership_tiers / memberships / donations / paywall_rules
--     결제는 신문사 자기 Toss 가맹(결정 D-4). 가맹 키는 nomad_core.provider_credentials(provider 'toss_merchant')에만 둔다(N3).
--     memberships·donations 는 service_role(결제 확인 Route Handler, 웹훅)만 쓴다.
-- ---------------------------------------------------------------------
create table nomad_news.membership_tiers (
  id                uuid primary key default gen_random_uuid(),
  organization_id            uuid not null references nomad_core.organizations(id) on delete cascade,
  code              text not null constraint membership_tiers_code_check check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name              text not null constraint membership_tiers_name_check check (char_length(btrim(name)) between 1 and 40),
  description       text constraint membership_tiers_description_check check (description is null or char_length(description) <= 1000),
  price_krw         integer not null constraint membership_tiers_price_check check (price_krw between 1000 and 10000000),
  billing_interval  text not null default 'month' constraint membership_tiers_interval_check check (billing_interval in ('month', 'year')),
  benefits          jsonb not null default '[]'::jsonb constraint membership_tiers_benefits_check check (jsonb_typeof(benefits) = 'array'),
  is_active         boolean not null default true,
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id)
);

create table nomad_news.memberships (
  id                     uuid primary key default gen_random_uuid(),
  organization_id                 uuid not null references nomad_core.organizations(id) on delete cascade,
  reader_id              uuid not null,
  tier_id                uuid not null,
  status                 text not null default 'pending'
                         constraint memberships_status_check check (status in ('pending', 'active', 'past_due', 'canceled', 'expired')),
  started_at             timestamptz,
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean not null default false,
  canceled_at            timestamptz,
  ended_at               timestamptz,
  provider               text not null default 'toss' constraint memberships_provider_check check (provider in ('toss')),
  billing_credential_id  uuid,
  external_ref           text constraint memberships_external_ref_check check (external_ref is null or char_length(external_ref) <= 200),
  last_event_id          text,
  platform_fee_bps       integer not null default 0 constraint memberships_platform_fee_bps_check check (platform_fee_bps between 0 and 3000),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete cascade,
  foreign key (tier_id, organization_id) references nomad_news.membership_tiers (id, organization_id),
  foreign key (billing_credential_id, organization_id) references nomad_core.provider_credentials (id, organization_id) on delete set null (billing_credential_id)
);
create unique index memberships_one_live_idx on nomad_news.memberships (reader_id) where status in ('pending', 'active', 'past_due');
create index memberships_org_status_idx on nomad_news.memberships (organization_id, status);

-- 2.2b membership_events(이식 추가, S6): record_membership 이 처리한 결제 이벤트 id(조직별 유일). 같은 이벤트를 다시 받으면 아무것도 바꾸지 않는다.
--      memberships.last_event_id 는 마지막 1건만 남아 예전 이벤트 재전송을 막지 못하므로 따로 둔다. service_role 전용(정책 없음)
create table nomad_news.membership_events (
  organization_id  uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id         text not null constraint membership_events_event_id_check check (char_length(event_id) between 1 and 200),
  membership_id    uuid not null references nomad_news.memberships(id) on delete cascade,
  created_at       timestamptz not null default now(),
  primary key (organization_id, event_id)
);
create index membership_events_membership_idx on nomad_news.membership_events (membership_id);

create function nomad_news.memberships_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.reader_id is distinct from old.reader_id then
    raise exception 'memberships: organization_id/reader_id are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'pending'  and new.status in ('active', 'canceled', 'expired'))
      or (old.status = 'active'   and new.status in ('past_due', 'canceled', 'expired'))
      or (old.status = 'past_due' and new.status in ('active', 'canceled', 'expired'))
      or (old.status = 'canceled' and new.status in ('active', 'expired'))
    ) then
      raise exception 'memberships: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'active'   then new.started_at := coalesce(old.started_at, now()); new.canceled_at := null; new.cancel_at_period_end := false; end if;
    if new.status = 'canceled' then new.canceled_at := now(); end if;
    if new.status = 'expired'  then new.ended_at := now(); end if;
  end if;
  return new;
end;
$$;
create trigger memberships_before_update before update on nomad_news.memberships
  for each row execute function nomad_news.memberships_before_update();

create table nomad_news.donations (
  id                   uuid primary key default gen_random_uuid(),
  organization_id               uuid not null references nomad_core.organizations(id) on delete cascade,
  reader_id            uuid,
  donor_display_name   text constraint donations_donor_display_name_check check (donor_display_name is null or char_length(btrim(donor_display_name)) between 1 and 40),
  is_anonymous         boolean not null default true,
  message              text constraint donations_message_check check (message is null or char_length(message) <= 300),
  amount_krw           integer not null constraint donations_amount_check check (amount_krw between 1000 and 10000000),
  kind                 text not null default 'once' constraint donations_kind_check check (kind in ('once', 'recurring')),
  status               text not null default 'pending' constraint donations_status_check check (status in ('pending', 'paid', 'failed', 'canceled', 'refunded')),
  order_id             text not null unique constraint donations_order_id_check check (order_id ~ '^[A-Za-z0-9_-]{6,64}$'),
  payment_key          text unique,
  paid_at              timestamptz,
  canceled_at          timestamptz,
  refunded_amount_krw  integer not null default 0 constraint donations_refunded_check check (refunded_amount_krw >= 0),
  platform_fee_bps     integer not null default 0 constraint donations_platform_fee_bps_check check (platform_fee_bps between 0 and 3000),
  platform_fee_krw     integer not null default 0 constraint donations_platform_fee_krw_check check (platform_fee_krw >= 0),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (reader_id),
  constraint donations_refund_le_amount_check check (refunded_amount_krw <= amount_krw)
);
create index donations_org_created_idx on nomad_news.donations (organization_id, created_at desc);

create function nomad_news.donations_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.order_id is distinct from old.order_id or new.amount_krw is distinct from old.amount_krw then
    raise exception 'donations: organization_id/order_id/amount_krw are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'pending' and new.status in ('paid', 'failed', 'canceled'))
      or (old.status = 'paid'    and new.status in ('canceled', 'refunded'))
    ) then
      raise exception 'donations: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'paid' then new.paid_at := coalesce(new.paid_at, now()); end if;
    if new.status in ('canceled', 'refunded') then new.canceled_at := now(); end if;
  end if;
  return new;
end;
$$;
create trigger donations_before_update before update on nomad_news.donations
  for each row execute function nomad_news.donations_before_update();

create table nomad_news.paywall_rules (
  id                       uuid primary key default gen_random_uuid(),
  organization_id                   uuid not null unique references nomad_core.organizations(id) on delete cascade,
  mode                     text not null default 'off' constraint paywall_rules_mode_check check (mode in ('off', 'meter', 'premium_only', 'meter_and_premium')),
  free_articles_per_month  integer not null default 10 constraint paywall_rules_free_articles_check check (free_articles_per_month between 0 and 100),
  exempt_types             text[] not null default '{press_release}'
                           constraint paywall_rules_exempt_types_check check (exempt_types <@ array['original', 'wire', 'press_release', 'contribution', 'sponsored']),
  cta_text                 text constraint paywall_rules_cta_text_check check (cta_text is null or char_length(cta_text) <= 200),
  updated_by               uuid,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

-- =====================================================================
-- M3. ad-manager (광고, 업소 디렉토리, 지자체 공고)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3.1 ad_slots: IAB 고정 슬롯. 폭·높이는 레이아웃 공간 예약(CLS)용이라 필수.
-- ---------------------------------------------------------------------
create table nomad_news.ad_slots (
  id          uuid primary key default gen_random_uuid(),
  organization_id      uuid not null references nomad_core.organizations(id) on delete cascade,
  code        text not null constraint ad_slots_code_check check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name        text not null constraint ad_slots_name_check check (char_length(btrim(name)) between 1 and 60),
  placement   text not null constraint ad_slots_placement_check check (placement in ('home', 'section', 'article', 'mobile', 'all')),
  width       integer not null constraint ad_slots_width_check check (width between 1 and 2000),
  height      integer not null constraint ad_slots_height_check check (height between 1 and 2000),
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id)
);

-- ---------------------------------------------------------------------
-- 3.2 advertisers: 광고주. 정부·지자체(is_government)는 직판 캠페인을 만들 수 없다(정부광고법: 언론진흥재단 대행, NW013).
-- ---------------------------------------------------------------------
create table nomad_news.advertisers (
  id             uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references nomad_core.organizations(id) on delete cascade,
  name           text not null constraint advertisers_name_check check (char_length(btrim(name)) between 1 and 80),
  kind           text not null default 'local_business'
                 constraint advertisers_kind_check check (kind in ('local_business', 'agency', 'institution', 'house', 'other')),
  is_government  boolean not null default false,
  business_no    text constraint advertisers_business_no_check check (business_no is null or business_no ~ '^[0-9]{3}-?[0-9]{2}-?[0-9]{5}$'),
  contact_name   text constraint advertisers_contact_name_check check (contact_name is null or char_length(contact_name) <= 40),
  contact_email  text constraint advertisers_contact_email_check check (contact_email is null or (char_length(contact_email) <= 254 and contact_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  contact_phone  text constraint advertisers_contact_phone_check check (contact_phone is null or contact_phone ~ '^[0-9+() -]{6,30}$'),
  note           text constraint advertisers_note_check check (note is null or char_length(note) <= 1000),
  status         text not null default 'active' constraint advertisers_status_check check (status in ('active', 'archived')),
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (id, organization_id)
);

-- ---------------------------------------------------------------------
-- 3.3 ad_campaigns: draft -> active | canceled, active -> paused | ended, paused -> active | ended
-- ---------------------------------------------------------------------
create table nomad_news.ad_campaigns (
  id             uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references nomad_core.organizations(id) on delete cascade,
  advertiser_id  uuid not null,
  name           text not null constraint ad_campaigns_name_check check (char_length(btrim(name)) between 1 and 80),
  pricing        text not null default 'flat' constraint ad_campaigns_pricing_check check (pricing in ('flat', 'cpm', 'cpc', 'house')),
  price_krw      integer not null default 0 constraint ad_campaigns_price_check check (price_krw between 0 and 1000000000),
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  priority       smallint not null default 5 constraint ad_campaigns_priority_check check (priority between 1 and 10),
  status         text not null default 'draft' constraint ad_campaigns_status_check check (status in ('draft', 'active', 'paused', 'ended', 'canceled')),
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (advertiser_id, organization_id) references nomad_news.advertisers (id, organization_id),
  constraint ad_campaigns_period_check check (ends_at > starts_at)
);
create index ad_campaigns_org_status_idx on nomad_news.ad_campaigns (organization_id, status, starts_at);

create function nomad_news.ad_campaigns_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'ad_campaigns: organization_id is immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'draft'  and new.status in ('active', 'canceled'))
    or (old.status = 'active' and new.status in ('paused', 'ended'))
    or (old.status = 'paused' and new.status in ('active', 'ended'))
  ) then
    raise exception 'ad_campaigns: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger ad_campaigns_before_update before update on nomad_news.ad_campaigns
  for each row execute function nomad_news.ad_campaigns_before_update();

-- ---------------------------------------------------------------------
-- 3.4 ad_creatives: 소재. 임의 HTML 은 받지 않는다(라벨 우회·XSS 차단). 외부 광고망은 네트워크 + 단위 ID 만.
--     label 은 허용 목록(광고, AD, 협찬, 후원)만. 노출은 nomad_news.serve_ads 가 라벨과 함께만 돌려준다.
--     pending_review -> approved | rejected, approved -> archived | pending_review(수정), rejected -> pending_review
-- ---------------------------------------------------------------------
create table nomad_news.ad_creatives (
  id                uuid primary key default gen_random_uuid(),
  organization_id            uuid not null references nomad_core.organizations(id) on delete cascade,
  campaign_id       uuid not null,
  slot_id           uuid not null,
  kind              text not null constraint ad_creatives_kind_check check (kind in ('image', 'text', 'external')),
  media_path        text,
  external_network  text constraint ad_creatives_external_network_check check (external_network is null or external_network in ('gam', 'adsense')),
  external_unit_id  text constraint ad_creatives_external_unit_id_check check (external_unit_id is null or external_unit_id ~ '^[A-Za-z0-9/_.-]{3,120}$'),
  headline          text constraint ad_creatives_headline_check check (headline is null or char_length(headline) <= 80),
  click_url         text constraint ad_creatives_click_url_check check (click_url is null or (char_length(click_url) <= 1000 and click_url ~ '^https://[^[:space:]<>"]{3,}$')),
  alt_text          text constraint ad_creatives_alt_text_check check (alt_text is null or char_length(alt_text) <= 200),
  label             text not null default '광고' constraint ad_creatives_label_check check (label in ('광고', 'AD', '협찬', '후원')),
  status            text not null default 'pending_review'
                    constraint ad_creatives_status_check check (status in ('pending_review', 'approved', 'rejected', 'archived')),
  reviewed_by       uuid,
  reviewed_at       timestamptz,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (campaign_id, organization_id) references nomad_news.ad_campaigns (id, organization_id) on delete cascade,
  foreign key (slot_id, organization_id) references nomad_news.ad_slots (id, organization_id),
  constraint ad_creatives_kind_fields_check check (
       (kind = 'image'    and media_path is not null and alt_text is not null and click_url is not null and external_network is null)
    or (kind = 'text'     and headline is not null and click_url is not null and media_path is null and external_network is null)
    or (kind = 'external' and external_network is not null and external_unit_id is not null and media_path is null)),
  constraint ad_creatives_media_path_check check (media_path is null or nomad_news.is_org_path(organization_id, media_path, 'ads'))
);
create index ad_creatives_campaign_idx on nomad_news.ad_creatives (campaign_id, status);

create function nomad_news.ad_creatives_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'ad_creatives: organization_id is immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'pending_review' and new.status in ('approved', 'rejected', 'archived'))
    or (old.status = 'approved'       and new.status in ('archived', 'pending_review'))
    or (old.status = 'rejected'       and new.status in ('pending_review', 'archived'))
  ) then
    raise exception 'ad_creatives: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger ad_creatives_before_update before update on nomad_news.ad_creatives
  for each row execute function nomad_news.ad_creatives_before_update();

-- ---------------------------------------------------------------------
-- 3.5 ad_daily_stats: 소재별 일(KST) 집계. record_ad_stats(service_role)만 증분한다.
-- ---------------------------------------------------------------------
create table nomad_news.ad_daily_stats (
  id           bigint generated always as identity primary key,
  organization_id       uuid not null references nomad_core.organizations(id) on delete cascade,
  creative_id  uuid not null,
  day          date not null,
  impressions  bigint not null default 0 constraint ad_daily_stats_impressions_check check (impressions >= 0),
  clicks       bigint not null default 0 constraint ad_daily_stats_clicks_check check (clicks >= 0),
  updated_at   timestamptz not null default now(),
  unique (creative_id, day),
  foreign key (creative_id, organization_id) references nomad_news.ad_creatives (id, organization_id) on delete cascade
);
create index ad_daily_stats_org_day_idx on nomad_news.ad_daily_stats (organization_id, day);

-- ---------------------------------------------------------------------
-- 3.6 local_listings: 지역 업소 셀프 광고·디렉토리(NW-F-033)
--     pending -> approved | rejected | canceled, approved -> active | canceled, active -> expired | canceled
-- ---------------------------------------------------------------------
create table nomad_news.local_listings (
  id                 uuid primary key default gen_random_uuid(),
  organization_id             uuid not null references nomad_core.organizations(id) on delete cascade,
  reader_id          uuid,
  applicant_user_id  uuid,
  business_name      text not null constraint local_listings_business_name_check check (char_length(btrim(business_name)) between 1 and 80),
  category           text not null constraint local_listings_category_check check (category in ('restaurant', 'cafe', 'shop', 'service', 'medical', 'education', 'lodging', 'other')),
  region_id          uuid,
  address            text constraint local_listings_address_check check (address is null or char_length(address) <= 200),
  phone              text constraint local_listings_phone_check check (phone is null or phone ~ '^[0-9+() -]{6,30}$'),
  url                text constraint local_listings_url_check check (url is null or (char_length(url) <= 500 and url ~ '^https://[^[:space:]<>"]{3,}$')),
  description        text constraint local_listings_description_check check (description is null or char_length(description) <= 1000),
  photo_path         text,
  contact_email      text constraint local_listings_contact_email_check check (contact_email is null or (char_length(contact_email) <= 254 and contact_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  status             text not null default 'pending'
                     constraint local_listings_status_check check (status in ('pending', 'approved', 'rejected', 'active', 'expired', 'canceled')),
  starts_at          timestamptz,
  ends_at            timestamptz,
  paid_at            timestamptz,
  payment_order_id   text constraint local_listings_payment_order_id_check check (payment_order_id is null or payment_order_id ~ '^[A-Za-z0-9_-]{6,64}$'),
  reviewed_by        uuid,
  reviewed_at        timestamptz,
  review_note        text constraint local_listings_review_note_check check (review_note is null or char_length(review_note) <= 500),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (reader_id),
  foreign key (region_id, organization_id) references nomad_news.regions (id, organization_id),
  constraint local_listings_photo_path_check check (photo_path is null or nomad_news.is_org_path(organization_id, photo_path, 'listings')),
  constraint local_listings_active_period_check check (status <> 'active' or (starts_at is not null and ends_at is not null and ends_at > starts_at))
);
create index local_listings_org_status_idx on nomad_news.local_listings (organization_id, status, ends_at);

create function nomad_news.local_listings_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'local_listings: organization_id is immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'pending'  and new.status in ('approved', 'rejected', 'canceled'))
    or (old.status = 'approved' and new.status in ('active', 'canceled'))
    or (old.status = 'active'   and new.status in ('expired', 'canceled'))
  ) then
    raise exception 'local_listings: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger local_listings_before_update before update on nomad_news.local_listings
  for each row execute function nomad_news.local_listings_before_update();

-- ---------------------------------------------------------------------
-- 3.7 public_notices: 지자체 공고 게재(NW-F-034). 정부광고 대금은 언론진흥재단 경유라 결제 컬럼이 없고 청약 참조만 둔다.
--     draft -> published | archived, published -> archived
-- ---------------------------------------------------------------------
create table nomad_news.public_notices (
  id                 uuid primary key default gen_random_uuid(),
  organization_id             uuid not null references nomad_core.organizations(id) on delete cascade,
  issuer_name        text not null constraint public_notices_issuer_name_check check (char_length(btrim(issuer_name)) between 1 and 80),
  notice_no          text constraint public_notices_notice_no_check check (notice_no is null or char_length(notice_no) <= 60),
  title              text not null constraint public_notices_title_check check (char_length(btrim(title)) between 1 and 200),
  body               text not null constraint public_notices_body_check check (char_length(body) between 1 and 20000),
  region_id          uuid,
  attachment_path    text,
  government_ad_ref  text constraint public_notices_government_ad_ref_check check (government_ad_ref is null or char_length(government_ad_ref) <= 60),
  posted_from        timestamptz,
  posted_until       timestamptz,
  status             text not null default 'draft' constraint public_notices_status_check check (status in ('draft', 'published', 'archived')),
  published_at       timestamptz,
  archived_at        timestamptz,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  foreign key (region_id, organization_id) references nomad_news.regions (id, organization_id),
  constraint public_notices_attachment_path_check check (attachment_path is null or nomad_news.is_org_path(organization_id, attachment_path, 'notices')),
  constraint public_notices_period_check check (posted_until is null or posted_from is null or posted_until > posted_from)
);
create index public_notices_org_status_idx on nomad_news.public_notices (organization_id, status, published_at desc);

create function nomad_news.public_notices_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'public_notices: organization_id is immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'draft' and new.status in ('published', 'archived')) or (old.status = 'published' and new.status = 'archived')) then
      raise exception 'public_notices: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'published' then new.published_at := now(); end if;
    if new.status = 'archived'  then new.archived_at := now(); end if;
  end if;
  return new;
end;
$$;
create trigger public_notices_before_update before update on nomad_news.public_notices
  for each row execute function nomad_news.public_notices_before_update();

-- =====================================================================
-- M4. notify-newsletter
-- =====================================================================

-- ---------------------------------------------------------------------
-- 4.1 newsletter_lists
-- ---------------------------------------------------------------------
create table nomad_news.newsletter_lists (
  id               uuid primary key default gen_random_uuid(),
  organization_id           uuid not null references nomad_core.organizations(id) on delete cascade,
  slug             text not null constraint newsletter_lists_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  name             text not null constraint newsletter_lists_name_check check (char_length(btrim(name)) between 1 and 60),
  description      text constraint newsletter_lists_description_check check (description is null or char_length(description) <= 500),
  kind             text not null default 'custom' constraint newsletter_lists_kind_check check (kind in ('morning_brief', 'breaking', 'weekly', 'custom')),
  is_public        boolean not null default true,
  contains_ads     boolean not null default false,
  consent_version  text not null default 'v1' constraint newsletter_lists_consent_version_check check (char_length(consent_version) between 1 and 32),
  status           text not null default 'active' constraint newsletter_lists_status_check check (status in ('active', 'archived')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (organization_id, slug),
  unique (id, organization_id)
);

-- ---------------------------------------------------------------------
-- 4.2 newsletter_subscriptions: 이중 동의. 토큰 원문은 저장하지 않는다(sha256 해시만). 원문은 발급 RPC 가 service_role 에게 한 번만 돌려준다.
--     reconfirm_due_at = 확인(또는 재확인) 시각 + 2년(정보통신망법 수신동의 2년 확인). 트리거가 계산한다.
--     pending -> confirmed | unsubscribed, confirmed -> unsubscribed | bounced, unsubscribed -> pending, bounced -> pending
-- ---------------------------------------------------------------------
create table nomad_news.newsletter_subscriptions (
  id                      uuid primary key default gen_random_uuid(),
  organization_id                  uuid not null references nomad_core.organizations(id) on delete cascade,
  list_id                 uuid not null,
  reader_id               uuid,
  email                   text constraint newsletter_subscriptions_email_check check (email is null or (char_length(email) <= 254 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  email_hash              text not null constraint newsletter_subscriptions_email_hash_check check (email_hash ~ '^[0-9a-f]{64}$'),
  status                  text not null default 'pending'
                          constraint newsletter_subscriptions_status_check check (status in ('pending', 'confirmed', 'unsubscribed', 'bounced')),
  confirm_token_hash      text constraint newsletter_subscriptions_confirm_token_hash_check check (confirm_token_hash is null or confirm_token_hash ~ '^[0-9a-f]{64}$'),
  confirm_expires_at      timestamptz,
  confirm_sent_count      smallint not null default 0,
  unsubscribe_token_hash  text not null constraint newsletter_subscriptions_unsub_token_hash_check check (unsubscribe_token_hash ~ '^[0-9a-f]{64}$'),
  consent_version         text not null,
  consent_at              timestamptz not null default now(),
  ad_consent              boolean not null default false,
  night_consent           boolean not null default false,
  confirmed_at            timestamptz,
  reconfirmed_at          timestamptz,
  reconfirm_due_at        timestamptz,
  unsubscribed_at         timestamptz,
  unsubscribe_reason      text constraint newsletter_subscriptions_unsub_reason_check check (unsubscribe_reason is null or char_length(unsubscribe_reason) <= 200),
  source_path             text constraint newsletter_subscriptions_source_path_check check (source_path is null or (char_length(source_path) <= 200 and source_path like '/%')),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (list_id, email_hash),
  foreign key (list_id, organization_id) references nomad_news.newsletter_lists (id, organization_id) on delete cascade,
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (reader_id),
  constraint newsletter_subscriptions_email_present_check check (email is not null or status in ('unsubscribed', 'bounced')),
  constraint newsletter_subscriptions_pending_token_check check (status <> 'pending' or confirm_token_hash is not null)
);
create unique index newsletter_subscriptions_confirm_token_uniq on nomad_news.newsletter_subscriptions (confirm_token_hash) where confirm_token_hash is not null;
create unique index newsletter_subscriptions_unsub_token_uniq on nomad_news.newsletter_subscriptions (unsubscribe_token_hash);
create index newsletter_subscriptions_list_status_idx on nomad_news.newsletter_subscriptions (list_id, status);
create index newsletter_subscriptions_reconfirm_idx on nomad_news.newsletter_subscriptions (reconfirm_due_at) where status = 'confirmed';

create function nomad_news.newsletter_subscriptions_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.organization_id is distinct from old.organization_id or new.list_id is distinct from old.list_id or new.email_hash is distinct from old.email_hash then
      raise exception 'newsletter_subscriptions: organization_id/list_id/email_hash are immutable' using errcode = '22023';
    end if;
    if new.status is distinct from old.status then
      if not (
           (old.status = 'pending'      and new.status in ('confirmed', 'unsubscribed'))
        or (old.status = 'confirmed'    and new.status in ('unsubscribed', 'bounced'))
        or (old.status = 'unsubscribed' and new.status = 'pending')
        or (old.status = 'bounced'      and new.status = 'pending')
      ) then
        raise exception 'newsletter_subscriptions: invalid status transition % -> %', old.status, new.status using errcode = '22023';
      end if;
      if new.status = 'confirmed' then new.confirmed_at := now(); new.reconfirmed_at := null; end if;
      if new.status = 'unsubscribed' then new.unsubscribed_at := now(); new.confirm_token_hash := null; end if;
      if new.status = 'pending' then new.confirmed_at := null; new.unsubscribed_at := null; new.reconfirmed_at := null; end if;
    end if;
    if new.reconfirm_due_at is distinct from old.reconfirm_due_at then
      raise exception 'newsletter_subscriptions: reconfirm_due_at is computed' using errcode = '22023';
    end if;
  end if;
  new.reconfirm_due_at := case when new.status = 'confirmed'
                               then coalesce(new.reconfirmed_at, new.confirmed_at) + interval '2 years' end;
  return new;
end;
$$;
create trigger newsletter_subscriptions_before_write before insert or update on nomad_news.newsletter_subscriptions
  for each row execute function nomad_news.newsletter_subscriptions_before_write();

-- ---------------------------------------------------------------------
-- 4.3 newsletter_issues: 발송 회차. 광고 포함이면 제목이 '(광고)'로 시작해야 한다(정보통신망법 제50조).
--     draft -> scheduled | canceled, scheduled -> draft | sending | canceled, sending -> sent | failed
-- ---------------------------------------------------------------------
create table nomad_news.newsletter_issues (
  id                uuid primary key default gen_random_uuid(),
  organization_id            uuid not null references nomad_core.organizations(id) on delete cascade,
  list_id           uuid not null,
  subject           text not null constraint newsletter_issues_subject_check check (char_length(btrim(subject)) between 1 and 200),
  preheader         text constraint newsletter_issues_preheader_check check (preheader is null or char_length(preheader) <= 200),
  body              jsonb not null default '[]'::jsonb constraint newsletter_issues_body_check check (jsonb_typeof(body) = 'array'),
  article_ids       uuid[] not null default '{}' constraint newsletter_issues_article_ids_check check (cardinality(article_ids) <= 50),
  contains_ad       boolean not null default false,
  status            text not null default 'draft'
                    constraint newsletter_issues_status_check check (status in ('draft', 'scheduled', 'sending', 'sent', 'canceled', 'failed')),
  scheduled_at      timestamptz,
  sent_at           timestamptz,
  recipients_count  integer not null default 0,
  delivered_count   integer not null default 0,
  open_count        integer not null default 0,
  click_count       integer not null default 0,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (list_id, organization_id) references nomad_news.newsletter_lists (id, organization_id) on delete cascade,
  constraint newsletter_issues_ad_subject_check check (not contains_ad or subject like '(광고)%'),
  constraint newsletter_issues_scheduled_check check (status <> 'scheduled' or scheduled_at is not null)
);
create index newsletter_issues_due_idx on nomad_news.newsletter_issues (scheduled_at) where status = 'scheduled';
create index newsletter_issues_list_idx on nomad_news.newsletter_issues (list_id, created_at desc);

create function nomad_news.newsletter_issues_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.list_id is distinct from old.list_id then
    raise exception 'newsletter_issues: organization_id/list_id are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'draft'     and new.status in ('scheduled', 'canceled'))
      or (old.status = 'scheduled' and new.status in ('draft', 'sending', 'canceled'))
      or (old.status = 'sending'   and new.status in ('sent', 'failed'))
    ) then
      raise exception 'newsletter_issues: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'sent' then new.sent_at := now(); end if;
  end if;
  if old.status not in ('draft', 'scheduled') and (new.subject is distinct from old.subject or new.body is distinct from old.body) then
    raise exception 'newsletter_issues: content is read-only after sending starts' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger newsletter_issues_before_update before update on nomad_news.newsletter_issues
  for each row execute function nomad_news.newsletter_issues_before_update();

-- ---------------------------------------------------------------------
-- 4.4 push_subscriptions: 속보 웹 푸시(NW-F-038). 브라우저 구독 정보라 사용자·방문자 모두 직접 접근 불가(service_role 전용).
-- ---------------------------------------------------------------------
create table nomad_news.push_subscriptions (
  id             uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references nomad_core.organizations(id) on delete cascade,
  reader_id      uuid,
  endpoint       text not null constraint push_subscriptions_endpoint_check check ((char_length(endpoint) <= 2000 and endpoint ~ '^https://[^[:space:]]{10,}$')),
  endpoint_hash  text not null constraint push_subscriptions_endpoint_hash_check check (endpoint_hash ~ '^[0-9a-f]{64}$'),
  p256dh         text not null constraint push_subscriptions_p256dh_check check (char_length(p256dh) between 40 and 200),
  auth_secret    text not null constraint push_subscriptions_auth_secret_check check (char_length(auth_secret) between 16 and 100),
  topics         text[] not null default '{breaking}' constraint push_subscriptions_topics_check check (topics <@ array['breaking', 'morning', 'local']),
  status         text not null default 'active' constraint push_subscriptions_status_check check (status in ('active', 'revoked')),
  failure_count  integer not null default 0,
  last_sent_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (organization_id, endpoint_hash),
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (reader_id)
);
create index push_subscriptions_org_active_idx on nomad_news.push_subscriptions (organization_id) where status = 'active';

-- =====================================================================
-- M5. community (댓글, 신고, 제보·투고, 경조사)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 5.1 comments: 로그인 독자만 작성. 방문자 공개 목록은 nomad_news.list_comments(닉네임만)로만 나간다.
--     visible -> hidden | temp_blocked | deleted, hidden -> visible | deleted, temp_blocked -> visible | hidden | deleted
--     temp_blocked: 정보통신망법 제44조의2 임시조치(30일 이내)
-- ---------------------------------------------------------------------
create table nomad_news.comments (
  id                  uuid primary key default gen_random_uuid(),
  organization_id              uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id          uuid not null,
  reader_id           uuid not null,
  parent_id           uuid,
  body                text not null constraint comments_body_check check (char_length(btrim(body)) between 1 and 1000),
  status              text not null default 'visible' constraint comments_status_check check (status in ('visible', 'hidden', 'temp_blocked', 'deleted')),
  status_reason       text constraint comments_status_reason_check check (status_reason is null or char_length(status_reason) <= 200),
  temp_blocked_until  timestamptz,
  report_count        integer not null default 0,
  moderation_label    text constraint comments_moderation_label_check check (moderation_label is null or moderation_label in ('ok', 'review', 'toxic')),
  moderated_by        uuid,
  moderated_at        timestamptz,
  deleted_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, organization_id),
  unique (id, article_id),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete cascade,
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete cascade,
  foreign key (parent_id, article_id) references nomad_news.comments (id, article_id) on delete cascade,
  constraint comments_temp_block_check check (status <> 'temp_blocked' or temp_blocked_until is not null)
);
create index comments_article_idx on nomad_news.comments (article_id, created_at desc) where status = 'visible';
create index comments_org_status_idx on nomad_news.comments (organization_id, status, created_at desc);
create index comments_reader_idx on nomad_news.comments (reader_id, created_at desc);

create function nomad_news.comments_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.article_id is distinct from old.article_id
     or new.reader_id is distinct from old.reader_id or new.body is distinct from old.body then
    raise exception 'comments: organization_id/article_id/reader_id/body are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'visible'      and new.status in ('hidden', 'temp_blocked', 'deleted'))
      or (old.status = 'hidden'       and new.status in ('visible', 'deleted'))
      or (old.status = 'temp_blocked' and new.status in ('visible', 'hidden', 'deleted'))
    ) then
      raise exception 'comments: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'deleted' then new.deleted_at := now(); end if;
    if new.status <> 'temp_blocked' then new.temp_blocked_until := null; end if;
  end if;
  return new;
end;
$$;
create trigger comments_before_update before update on nomad_news.comments
  for each row execute function nomad_news.comments_before_update();

create table nomad_news.comment_reports (
  id                  uuid primary key default gen_random_uuid(),
  organization_id              uuid not null references nomad_core.organizations(id) on delete cascade,
  comment_id          uuid not null,
  reporter_reader_id  uuid not null,
  reason              text not null constraint comment_reports_reason_check check (reason in ('defamation', 'privacy', 'obscene', 'hate', 'spam', 'other')),
  detail              text constraint comment_reports_detail_check check (detail is null or char_length(detail) <= 1000),
  is_rights_claim     boolean not null default false,
  status              text not null default 'open' constraint comment_reports_status_check check (status in ('open', 'actioned', 'dismissed')),
  handled_by          uuid,
  handled_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (comment_id, reporter_reader_id),
  foreign key (comment_id, organization_id) references nomad_news.comments (id, organization_id) on delete cascade,
  foreign key (reporter_reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete cascade
);
create index comment_reports_org_open_idx on nomad_news.comment_reports (organization_id, created_at) where status = 'open';

-- ---------------------------------------------------------------------
-- 5.2 tips: 독자 제보·투고(NW-F-025). Route Handler(service_role)만 접수한다. 첨부는 org-files/<org>/news/tips/ (서버 업로드).
--     제보자 보호: 데스크 이상 + 배정된 기자만 읽는다. 첨부 폴더는 아래 Storage 제한 정책이 같은 기준으로 막는다.
--     new -> reviewing | assigned | dismissed | spam, reviewing -> assigned | used | dismissed | spam,
--     assigned -> reviewing | used | dismissed, spam -> new
-- ---------------------------------------------------------------------
create table nomad_news.tips (
  id                uuid primary key default gen_random_uuid(),
  organization_id            uuid not null references nomad_core.organizations(id) on delete cascade,
  kind              text not null default 'tip' constraint tips_kind_check check (kind in ('tip', 'contribution')),
  reader_id         uuid,
  title             text not null constraint tips_title_check check (char_length(btrim(title)) between 1 and 200),
  body              text not null constraint tips_body_check check (char_length(btrim(body)) between 10 and 20000),
  contact_name      text constraint tips_contact_name_check check (contact_name is null or char_length(contact_name) <= 40),
  contact_email     text constraint tips_contact_email_check check (contact_email is null or (char_length(contact_email) <= 254 and contact_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  contact_phone     text constraint tips_contact_phone_check check (contact_phone is null or contact_phone ~ '^[0-9+() -]{6,30}$'),
  wants_anonymity   boolean not null default true,
  attachment_paths  text[] not null default '{}' constraint tips_attachment_count_check check (cardinality(attachment_paths) <= 5),
  consent_version   text not null constraint tips_consent_version_check check (char_length(consent_version) between 1 and 32),
  consent_at        timestamptz not null default now(),
  status            text not null default 'new' constraint tips_status_check check (status in ('new', 'reviewing', 'assigned', 'used', 'dismissed', 'spam')),
  assigned_to       uuid,
  staff_note        text constraint tips_staff_note_check check (staff_note is null or char_length(staff_note) <= 2000),
  retention_until   timestamptz not null default (now() + interval '1 year'),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (reader_id),
  constraint tips_attachment_paths_check check (nomad_news.are_org_paths(organization_id, attachment_paths, 'tips')),
  constraint tips_assigned_check check (status <> 'assigned' or assigned_to is not null)
);
create index tips_org_status_idx on nomad_news.tips (organization_id, status, created_at desc);
create index tips_assigned_idx on nomad_news.tips (assigned_to) where assigned_to is not null;

create function nomad_news.tips_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id or new.body is distinct from old.body or new.consent_at is distinct from old.consent_at then
    raise exception 'tips: organization_id/body/consent_at are immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status and not (
       (old.status = 'new'       and new.status in ('reviewing', 'assigned', 'dismissed', 'spam'))
    or (old.status = 'reviewing' and new.status in ('assigned', 'used', 'dismissed', 'spam'))
    or (old.status = 'assigned'  and new.status in ('reviewing', 'used', 'dismissed'))
    or (old.status = 'spam'      and new.status = 'new')
  ) then
    raise exception 'tips: invalid status transition % -> %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger tips_before_update before update on nomad_news.tips
  for each row execute function nomad_news.tips_before_update();

-- ---------------------------------------------------------------------
-- 5.3 life_events: 경조사(부고·인사·동정·화촉, NW-F-024). 독자 신청 → 편집국 검토 → 게재.
--     pending -> approved | rejected | withdrawn, approved -> archived
-- ---------------------------------------------------------------------
create table nomad_news.life_events (
  id                   uuid primary key default gen_random_uuid(),
  organization_id               uuid not null references nomad_core.organizations(id) on delete cascade,
  kind                 text not null constraint life_events_kind_check check (kind in ('obituary', 'personnel', 'people', 'wedding')),
  title                text not null constraint life_events_title_check check (char_length(btrim(title)) between 1 and 200),
  body                 text not null constraint life_events_body_check check (char_length(btrim(body)) between 1 and 5000),
  event_at             timestamptz,
  applicant_reader_id  uuid,
  applicant_name       text not null constraint life_events_applicant_name_check check (char_length(btrim(applicant_name)) between 1 and 40),
  applicant_phone      text constraint life_events_applicant_phone_check check (applicant_phone is null or applicant_phone ~ '^[0-9+() -]{6,30}$'),
  consent_version      text not null constraint life_events_consent_version_check check (char_length(consent_version) between 1 and 32),
  consent_at           timestamptz not null default now(),
  is_paid              boolean not null default false,
  paid_at              timestamptz,
  status               text not null default 'pending' constraint life_events_status_check check (status in ('pending', 'approved', 'rejected', 'withdrawn', 'archived')),
  published_at         timestamptz,
  reviewed_by          uuid,
  reviewed_at          timestamptz,
  review_note          text constraint life_events_review_note_check check (review_note is null or char_length(review_note) <= 500),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  foreign key (applicant_reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (applicant_reader_id)
);
create index life_events_org_status_idx on nomad_news.life_events (organization_id, status, published_at desc);

create function nomad_news.life_events_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'life_events: organization_id is immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'pending' and new.status in ('approved', 'rejected', 'withdrawn')) or (old.status = 'approved' and new.status = 'archived')) then
      raise exception 'life_events: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'approved' then new.published_at := now(); end if;
  end if;
  return new;
end;
$$;
create trigger life_events_before_update before update on nomad_news.life_events
  for each row execute function nomad_news.life_events_before_update();

-- =====================================================================
-- M6. distribution-seo (wire_contracts 는 1절 앞에서 만들었다)
-- =====================================================================
create table nomad_news.syndication_settings (
  id                    uuid primary key default gen_random_uuid(),
  organization_id                uuid not null unique references nomad_core.organizations(id) on delete cascade,
  rss_enabled           boolean not null default true,
  news_sitemap_enabled  boolean not null default true,
  google_news           boolean not null default false,
  naver_partnership     text not null default 'none' constraint syndication_settings_naver_check check (naver_partnership in ('none', 'search', 'content')),
  daum_partnership      text not null default 'none' constraint syndication_settings_daum_check check (daum_partnership in ('none', 'search', 'content')),
  ai_crawler_policy     text not null default 'block_training'
                        constraint syndication_settings_ai_crawler_policy_check check (ai_crawler_policy in ('allow', 'block_training', 'block_all')),
  llms_txt_enabled      boolean not null default false,
  robots_extra          text constraint syndication_settings_robots_extra_check check (robots_extra is null or (char_length(robots_extra) <= 2000 and robots_extra !~ '[<>]')),
  sns_autoshare         jsonb not null default '{}'::jsonb constraint syndication_settings_sns_check check (jsonb_typeof(sns_autoshare) = 'object'),
  updated_by            uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- =====================================================================
-- M7. compliance-desk (정정·반론·추후보도 청구, 선거 기간)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 7.1 correction_requests: 언론중재법 제14·15조. 접수 시각과 기한은 트리거가 정하고 바꿀 수 없다.
--     notify_due_at = received_at + 3일(수용 여부 통지 기한), publish_due_at = 수용 결정 시각 + 7일(게재 기한).
--     received -> reviewing | accepted | rejected | withdrawn, reviewing -> accepted | rejected | withdrawn,
--     accepted -> published | withdrawn
-- ---------------------------------------------------------------------
create table nomad_news.correction_requests (
  id                     uuid primary key default gen_random_uuid(),
  organization_id                 uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id             uuid,
  article_url            text constraint correction_requests_article_url_check check (article_url is null or char_length(article_url) <= 1000),
  kind                   text not null constraint correction_requests_kind_check check (kind in ('correction', 'rebuttal', 'follow_up')),
  requester_name         text not null constraint correction_requests_requester_name_check check (char_length(btrim(requester_name)) between 1 and 80),
  requester_email        text constraint correction_requests_requester_email_check check (requester_email is null or (char_length(requester_email) <= 254 and requester_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  requester_phone        text constraint correction_requests_requester_phone_check check (requester_phone is null or requester_phone ~ '^[0-9+() -]{6,30}$'),
  requester_reader_id    uuid,
  claim_text             text not null constraint correction_requests_claim_text_check check (char_length(btrim(claim_text)) between 10 and 10000),
  requested_text         text constraint correction_requests_requested_text_check check (requested_text is null or char_length(requested_text) <= 10000),
  attachment_paths       text[] not null default '{}' constraint correction_requests_attachment_count_check check (cardinality(attachment_paths) <= 5),
  channel                text not null default 'web' constraint correction_requests_channel_check check (channel in ('web', 'email', 'mail', 'phone', 'arbitration')),
  received_at            timestamptz not null default now(),
  notify_due_at          timestamptz not null,
  status                 text not null default 'received'
                         constraint correction_requests_status_check check (status in ('received', 'reviewing', 'accepted', 'rejected', 'published', 'withdrawn')),
  decided_at             timestamptz,
  decided_by             uuid,
  decision_note          text constraint correction_requests_decision_note_check check (decision_note is null or char_length(decision_note) <= 2000),
  notified_at            timestamptz,
  publish_due_at         timestamptz,
  published_at           timestamptz,
  published_revision_id  uuid,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete set null (article_id),
  foreign key (requester_reader_id, organization_id) references nomad_news.readers (id, organization_id) on delete set null (requester_reader_id),
  constraint correction_requests_target_check check (article_id is not null or article_url is not null),
  constraint correction_requests_contact_check check (requester_email is not null or requester_phone is not null),
  constraint correction_requests_attachment_paths_check check (nomad_news.are_org_paths(organization_id, attachment_paths, 'corrections')),
  constraint correction_requests_publish_due_check check (status not in ('accepted', 'published') or publish_due_at is not null)
);
create index correction_requests_org_status_idx on nomad_news.correction_requests (organization_id, status, received_at desc);
create index correction_requests_notify_due_idx on nomad_news.correction_requests (notify_due_at) where status in ('received', 'reviewing');
create index correction_requests_publish_due_idx on nomad_news.correction_requests (publish_due_at) where status = 'accepted';

create function nomad_news.correction_requests_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'received' then
      raise exception 'correction_requests: new requests start as received' using errcode = '22023';
    end if;
    new.notify_due_at := new.received_at + interval '3 days';
    new.publish_due_at := null;
    return new;
  end if;
  if new.organization_id is distinct from old.organization_id or new.received_at is distinct from old.received_at
     or new.notify_due_at is distinct from old.notify_due_at or new.kind is distinct from old.kind
     or new.claim_text is distinct from old.claim_text then
    raise exception 'correction_requests: organization_id/received_at/notify_due_at/kind/claim_text are immutable' using errcode = '22023';
  end if;
  if old.article_id is not null and new.article_id is distinct from old.article_id then
    raise exception 'correction_requests: linked article cannot be changed' using errcode = '22023';
  end if;
  if old.publish_due_at is not null and new.publish_due_at is distinct from old.publish_due_at then
    raise exception 'correction_requests: publish_due_at is immutable once set' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'received'  and new.status in ('reviewing', 'accepted', 'rejected', 'withdrawn'))
      or (old.status = 'reviewing' and new.status in ('accepted', 'rejected', 'withdrawn'))
      or (old.status = 'accepted'  and new.status in ('published', 'withdrawn'))
    ) then
      raise exception 'correction_requests: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status in ('accepted', 'rejected') then
      new.decided_at := now();
      new.notified_at := coalesce(new.notified_at, now());
    end if;
    if new.status = 'accepted' then new.publish_due_at := new.decided_at + interval '7 days'; end if;
    if new.status = 'published' then new.published_at := now(); end if;
  end if;
  return new;
end;
$$;
create trigger correction_requests_before_write before insert or update on nomad_news.correction_requests
  for each row execute function nomad_news.correction_requests_before_write();

-- ---------------------------------------------------------------------
-- 7.2 election_periods: 선거 모드(NW-F-044). 여론조사 공표 금지 기간(공직선거법 제108조: 선거일 전 6일 ~ 투표 마감)과 댓글 정책.
--     전국 선거는 운영자 서버(service_role)가 신문사마다 행을 넣는다(source='platform').
-- ---------------------------------------------------------------------
create table nomad_news.election_periods (
  id                   uuid primary key default gen_random_uuid(),
  organization_id               uuid not null references nomad_core.organizations(id) on delete cascade,
  name                 text not null constraint election_periods_name_check check (char_length(btrim(name)) between 1 and 80),
  election_day         date not null,
  poll_blackout_from   timestamptz not null,
  poll_blackout_until  timestamptz not null,
  comment_policy       text not null default 'normal' constraint election_periods_comment_policy_check check (comment_policy in ('normal', 'disabled')),
  source               text not null default 'newsroom' constraint election_periods_source_check check (source in ('platform', 'newsroom')),
  status               text not null default 'active' constraint election_periods_status_check check (status in ('active', 'canceled')),
  created_by           uuid,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint election_periods_blackout_check check (poll_blackout_until > poll_blackout_from)
);
create index election_periods_org_idx on nomad_news.election_periods (organization_id, poll_blackout_from, poll_blackout_until) where status = 'active';

-- =====================================================================
-- M8. search-analytics
-- =====================================================================
-- 조회 집계(시간 버킷, UTC 정시). nomad_news.increment_article_views(service_role)만 증분한다.
create table nomad_news.article_view_hourly (
  organization_id        uuid not null references nomad_core.organizations(id) on delete cascade,
  article_id    uuid not null,
  bucket_start  timestamptz not null constraint article_view_hourly_bucket_check check (extract(epoch from bucket_start)::bigint % 3600 = 0),
  views         bigint not null default 0 constraint article_view_hourly_views_check check (views >= 0),
  updated_at    timestamptz not null default now(),
  primary key (article_id, bucket_start),
  foreign key (article_id, organization_id) references nomad_news.articles (id, organization_id) on delete cascade
);
create index article_view_hourly_org_bucket_idx on nomad_news.article_view_hourly (organization_id, bucket_start desc);

-- =====================================================================
-- local-life: 행사 캘린더(NW-F-023). 날씨·미세먼지는 외부 API 캐시라 테이블이 없다.
--     draft -> published | archived, published -> canceled | archived, canceled -> archived
-- =====================================================================
create table nomad_news.events (
  id           uuid primary key default gen_random_uuid(),
  organization_id       uuid not null references nomad_core.organizations(id) on delete cascade,
  title        text not null constraint events_title_check check (char_length(btrim(title)) between 1 and 200),
  description  text constraint events_description_check check (description is null or char_length(description) <= 5000),
  venue        text constraint events_venue_check check (venue is null or char_length(venue) <= 120),
  address      text constraint events_address_check check (address is null or char_length(address) <= 200),
  region_id    uuid,
  starts_at    timestamptz not null,
  ends_at      timestamptz,
  is_all_day   boolean not null default false,
  url          text constraint events_url_check check (url is null or (char_length(url) <= 500 and url ~ '^https://[^[:space:]<>"]{3,}$')),
  image_path   text,
  organizer    text constraint events_organizer_check check (organizer is null or char_length(organizer) <= 80),
  price_text   text constraint events_price_text_check check (price_text is null or char_length(price_text) <= 80),
  status       text not null default 'draft' constraint events_status_check check (status in ('draft', 'published', 'canceled', 'archived')),
  published_at timestamptz,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  foreign key (region_id, organization_id) references nomad_news.regions (id, organization_id),
  constraint events_image_path_check check (image_path is null or nomad_news.is_org_path(organization_id, image_path, 'events')),
  constraint events_period_check check (ends_at is null or ends_at >= starts_at)
);
create index events_org_starts_idx on nomad_news.events (organization_id, starts_at) where status in ('published', 'canceled');

create function nomad_news.events_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'events: organization_id is immutable' using errcode = '22023';
  end if;
  if new.status is distinct from old.status then
    if not (
         (old.status = 'draft'     and new.status in ('published', 'archived'))
      or (old.status = 'published' and new.status in ('canceled', 'archived'))
      or (old.status = 'canceled'  and new.status = 'archived')
    ) then
      raise exception 'events: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'published' then new.published_at := now(); end if;
  end if;
  return new;
end;
$$;
create trigger events_before_update before update on nomad_news.events
  for each row execute function nomad_news.events_before_update();


-- ---------------------------------------------------------------------
-- 공통: updated_at 트리거 · RLS · 사용자 권한 회수. 원본 guard_privileged_write 이중 잠금은 없앴다
--   (사용자 역할에 INSERT/UPDATE/DELETE grant 가 어느 표에도 없다 — check_org.sql 이 고정한다).
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'newspaper_applications', 'newspapers', 'staff', 'staff_invitations', 'sections', 'regions', 'tags', 'wire_contracts', 'media_assets',
    'articles', 'home_layouts', 'print_editions', 'live_updates', 'readers', 'membership_tiers', 'memberships', 'donations',
    'paywall_rules', 'ad_slots', 'advertisers', 'ad_campaigns', 'ad_creatives', 'ad_daily_stats', 'local_listings', 'public_notices',
    'newsletter_lists', 'newsletter_subscriptions', 'newsletter_issues', 'push_subscriptions', 'comments', 'comment_reports',
    'tips', 'life_events', 'syndication_settings', 'correction_requests', 'election_periods', 'article_view_hourly', 'events']
  loop
    execute format('create trigger %I_touch_updated_at before update on nomad_news.%I for each row execute function nomad_core.touch_updated_at()', t, t);
  end loop;
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'nomad_news' and c.relkind = 'r'
  loop
    execute format('alter table nomad_news.%I enable row level security', t);
    execute format('revoke all on table nomad_news.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on table nomad_news.%I to service_role', t);
  end loop;
end $$;

-- =====================================================================
-- 9. 판정 헬퍼 (SECURITY DEFINER, STABLE). 정책 안에서 memberships·staff 를 직접 조회하지 않는다(42P17 방지).
--   staff_role(org)            현재 사용자의 활성 도메인 역할(발행인은 core owner, 나머지는 owner·admin·editor + core 재가입 아님 + 조직 활성 + staff active). 없으면 null
--   has_staff_role(org, roles) 위 역할이 roles 안에 있는가(NULL 없음)
--   is_newsroom(org, roles)    has_staff_role 과 같다. N1: 편집국 읽기는 구독이 끊겨도 유지 → 정책에 플랜 조건 없음
--   plan_active(org)           기능 newsroom(A·B). 없으면 쓰기 RPC 가 NW014(구독 끊김 잠금)
--   is_public_newspaper(org)   신문사 active + 필요적 게재사항 완성 + 조직 활성. N1: 플랜과 무관(공개분 열람 유지)
--   article_is_live(...)       기사 공개 조건(게시 + 시각 도래 + 엠바고 해제 + 신문사 공개 + wire 계약 유효)
--   can_view_article(id)       편집국 안의 기사 열람 범위(기고자는 자기 기사, 광고담당은 기사형 광고만)
--   current_reader_id(org)     현재 사용자의 활성 독자 id
-- 역할 묶음: ALL publisher·editor·desk·reporter·contributor·ad_manager / EDITORIAL publisher·editor·desk·reporter
--   / DESK publisher·editor·desk / CHIEF publisher·editor / ADS publisher·editor·ad_manager
-- =====================================================================
create function nomad_news.staff_role(p_org uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- 발행인은 core owner 일 때만. 나머지는 core owner·admin·editor 이고, staff 합류(joined_at) 뒤에 편집국 초대가 아닌
  -- core 초대로 멤버십이 다시 생겼으면(core 에서 제거 후 재가입) 예전 도메인 역할을 인정하지 않는다 → invite_staff 로 다시 초대
  select s.role
  from nomad_news.staff s
  where s.organization_id = p_org and s.user_id = (select auth.uid()) and s.status = 'active'
    and case when s.role = 'publisher' then coalesce(nomad_core.organization_role(p_org), '') = 'owner'
             else coalesce(nomad_core.organization_role(p_org), '') in ('owner', 'admin', 'editor')
                  and not exists (select 1 from nomad_core.invitations i
                                  where i.organization_id = p_org and i.accepted_by = s.user_id and i.accepted_at > s.joined_at
                                    and not exists (select 1 from nomad_news.staff_invitations si where si.invitation_id = i.id))
        end;
$$;

create function nomad_news.has_staff_role(p_org uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nomad_news.staff_role(p_org) = any (p_roles), false);
$$;

create function nomad_news.is_newsroom(p_org uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select nomad_news.has_staff_role(p_org, p_roles);
$$;

create function nomad_news.plan_active(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select nomad_core.org_has_feature(p_org, 'news', 'newsroom');
$$;

-- 기능 판정(서버·내부): newsroom + 기능
create function nomad_news.has_feature(p_org uuid, p_feature text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select nomad_core.org_has_feature(p_org, 'news', 'newsroom') and nomad_core.org_has_feature(p_org, 'news', p_feature);
$$;

-- plan_limits 정수(키 없으면 0 = fail-closed)
create function nomad_news.limit_int(p_org uuid, p_key text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nomad_core.org_plan_limit(p_org, 'news', p_key), 0);
$$;

create function nomad_news.is_public_newspaper(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from nomad_news.newspapers n
    join nomad_core.organizations o on o.id = n.organization_id and o.active
    where n.organization_id = p_org and n.status = 'active' and n.profile_completed_at is not null
  );
$$;

create function nomad_news.article_is_live(p_org uuid, p_status text, p_published_at timestamptz,
                                           p_embargo_until timestamptz, p_type text, p_wire_contract_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- 엠바고: 구독이 끊긴 동안(plan_active 거짓)에는 끊긴 시각(plan_lapsed_at) 전에 풀린 것만 공개한다(끊김 중 해제 = 새 발행, N1).
  --   끊긴 시각이 아직 기록되지 않았으면(예약 실행 전) 엠바고 기사는 비공개(fail-closed)
  select p_status = 'published'
     and p_published_at is not null and p_published_at <= now()
     and (p_embargo_until is null or (p_embargo_until <= now() and (
            nomad_news.plan_active(p_org)
            or p_embargo_until <= coalesce((select n.plan_lapsed_at from nomad_news.newspapers n where n.organization_id = p_org), '-infinity'::timestamptz))))
     and nomad_news.is_public_newspaper(p_org)
     and (p_type <> 'wire' or exists (
           select 1 from nomad_news.wire_contracts w
           where w.id = p_wire_contract_id and w.organization_id = p_org and w.status = 'active'
             and w.starts_on <= (now() at time zone 'Asia/Seoul')::date
             and (w.ends_on is null or w.ends_on >= (now() at time zone 'Asia/Seoul')::date)));
$$;

create function nomad_news.is_article_live(p_article_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select nomad_news.article_is_live(a.organization_id, a.status, a.published_at, a.embargo_until, a.type, a.wire_contract_id)
                   from nomad_news.articles a where a.id = p_article_id), false);
$$;

create function nomad_news.can_view_article(p_article_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from nomad_news.articles a
    where a.id = p_article_id
      and (   nomad_news.has_staff_role(a.organization_id, array['publisher', 'editor', 'desk', 'reporter'])
           or (nomad_news.has_staff_role(a.organization_id, array['contributor']) and (a.created_by = (select auth.uid()) or a.author_id = (select auth.uid())))
           or (nomad_news.has_staff_role(a.organization_id, array['ad_manager']) and a.type = 'sponsored'))
  );
$$;

create function nomad_news.current_reader_id(p_org uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select r.id from nomad_news.readers r where r.organization_id = p_org and r.user_id = (select auth.uid()) and r.status = 'active';
$$;

-- =====================================================================
-- 10. RLS 정책과 GRANT (authenticated SELECT 만)
--   - 편집국은 is_newsroom 으로, 독자는 자기 행(user_id = auth.uid())으로만 SELECT.
--   - anon 은 어느 표에도 정책·grant 가 없다(D8). 방문자와 로그인 독자의 공개 콘텐츠는 공개 RPC(12절)로만 읽는다.
--   - INSERT/UPDATE/DELETE 정책과 GRANT 는 어느 표에도 없다(쓰기는 11절 RPC 와 service_role).
-- =====================================================================
create policy newspaper_applications_select on nomad_news.newspaper_applications for select to authenticated
  using (applicant_id = (select auth.uid()));
grant select on nomad_news.newspaper_applications to authenticated;

create policy newspapers_select on nomad_news.newspapers for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk', 'reporter', 'contributor', 'ad_manager']));
grant select on nomad_news.newspapers to authenticated;

create policy staff_select on nomad_news.staff for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk', 'reporter', 'contributor', 'ad_manager']) or user_id = (select auth.uid()));
grant select on nomad_news.staff to authenticated;

create policy staff_invitations_select on nomad_news.staff_invitations for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor']));
grant select on nomad_news.staff_invitations to authenticated;

do $$
declare t text;
begin
  foreach t in array array['sections', 'regions', 'tags', 'membership_tiers', 'paywall_rules', 'newsletter_lists', 'syndication_settings', 'election_periods'] loop
    execute format('create policy %I_select on nomad_news.%I for select to authenticated using (nomad_news.is_newsroom(organization_id, array[''publisher'', ''editor'', ''desk'', ''reporter'', ''contributor'', ''ad_manager'']))', t, t);
    execute format('grant select on nomad_news.%I to authenticated', t);
  end loop;
  foreach t in array array['wire_contracts', 'home_layouts', 'print_editions', 'article_view_hourly', 'events'] loop
    execute format('create policy %I_select on nomad_news.%I for select to authenticated using (nomad_news.is_newsroom(organization_id, array[''publisher'', ''editor'', ''desk'', ''reporter'']))', t, t);
    execute format('grant select on nomad_news.%I to authenticated', t);
  end loop;
  foreach t in array array['advertisers', 'ad_campaigns', 'ad_creatives', 'ad_daily_stats'] loop
    execute format('create policy %I_select on nomad_news.%I for select to authenticated using (nomad_news.is_newsroom(organization_id, array[''publisher'', ''editor'', ''ad_manager'']))', t, t);
    execute format('grant select on nomad_news.%I to authenticated', t);
  end loop;
  foreach t in array array['article_revisions', 'article_regions', 'article_tags', 'live_updates'] loop
    execute format('create policy %I_select on nomad_news.%I for select to authenticated using (nomad_news.can_view_article(article_id))', t, t);
    execute format('grant select on nomad_news.%I to authenticated', t);
  end loop;
end $$;

create policy media_assets_select on nomad_news.media_assets for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk', 'reporter', 'contributor', 'ad_manager']));
grant select on nomad_news.media_assets to authenticated;

create policy articles_select on nomad_news.articles for select to authenticated
  using (   nomad_news.has_staff_role(organization_id, array['publisher', 'editor', 'desk', 'reporter'])
         or (nomad_news.has_staff_role(organization_id, array['contributor']) and (created_by = (select auth.uid()) or author_id = (select auth.uid())))
         or (nomad_news.has_staff_role(organization_id, array['ad_manager']) and type = 'sponsored'));
grant select on nomad_news.articles to authenticated;

-- readers: 본인 행 + 발행인·편집인(자기 신문사 독자만, email 포함). 독자는 조직 멤버가 아니다
create policy readers_select on nomad_news.readers for select to authenticated
  using (user_id = (select auth.uid()) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor']));
grant select on nomad_news.readers to authenticated;

create policy memberships_select on nomad_news.memberships for select to authenticated
  using (reader_id = nomad_news.current_reader_id(organization_id) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor']));
-- 결제 키·수수료·이벤트 id·외부 참조는 서버(service_role)만(S7)
grant select (id, organization_id, reader_id, tier_id, status, started_at, current_period_start, current_period_end, cancel_at_period_end,
              canceled_at, ended_at, provider, created_at, updated_at)
  on nomad_news.memberships to authenticated;
create policy donations_select on nomad_news.donations for select to authenticated
  using ((reader_id is not null and reader_id = nomad_news.current_reader_id(organization_id)) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor']));
grant select on nomad_news.donations to authenticated;

create policy ad_slots_select on nomad_news.ad_slots for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk', 'ad_manager']));
grant select on nomad_news.ad_slots to authenticated;

create policy local_listings_select on nomad_news.local_listings for select to authenticated
  using (applicant_user_id = (select auth.uid()) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'ad_manager']));
grant select on nomad_news.local_listings to authenticated;

create policy public_notices_select on nomad_news.public_notices for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk', 'ad_manager']));
grant select on nomad_news.public_notices to authenticated;

create policy newsletter_subscriptions_select on nomad_news.newsletter_subscriptions for select to authenticated
  using ((reader_id is not null and reader_id = nomad_news.current_reader_id(organization_id)) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor']));
-- 토큰 해시 컬럼은 누구에게도 주지 않는다
grant select (id, organization_id, list_id, reader_id, email, status, consent_version, consent_at, ad_consent, night_consent,
              confirmed_at, reconfirmed_at, reconfirm_due_at, unsubscribed_at, unsubscribe_reason, source_path, created_at, updated_at)
  on nomad_news.newsletter_subscriptions to authenticated;
create policy newsletter_issues_select on nomad_news.newsletter_issues for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk']));
grant select on nomad_news.newsletter_issues to authenticated;
-- push_subscriptions: 정책 없음(service_role 전용)

create policy comments_select on nomad_news.comments for select to authenticated
  using (reader_id = nomad_news.current_reader_id(organization_id) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk']));
grant select on nomad_news.comments to authenticated;
create policy comment_reports_select on nomad_news.comment_reports for select to authenticated
  using (reporter_reader_id = nomad_news.current_reader_id(organization_id) or nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk']));
grant select on nomad_news.comment_reports to authenticated;

-- 제보: 데스크 이상 + 배정된 기자(제보자 보호)
create policy tips_select on nomad_news.tips for select to authenticated
  using (nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk'])
         or (assigned_to = (select auth.uid()) and nomad_news.is_newsroom(organization_id, array['reporter'])));
grant select on nomad_news.tips to authenticated;

create policy life_events_select on nomad_news.life_events for select to authenticated
  using ((applicant_reader_id is not null and applicant_reader_id = nomad_news.current_reader_id(organization_id))
         or nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk']));
grant select on nomad_news.life_events to authenticated;

create policy correction_requests_select on nomad_news.correction_requests for select to authenticated
  using ((requester_reader_id is not null and requester_reader_id = nomad_news.current_reader_id(organization_id))
         or nomad_news.is_newsroom(organization_id, array['publisher', 'editor', 'desk']));
grant select on nomad_news.correction_requests to authenticated;

-- 정정 기한 현황 뷰(security_invoker: correction_requests 의 RLS 를 그대로 통과한다)
create view nomad_news.correction_sla with (security_invoker = true) as
  select c.id, c.organization_id, c.article_id, c.kind, c.status, c.received_at, c.notify_due_at, c.notified_at,
         c.decided_at, c.publish_due_at, c.published_at,
         (c.status in ('received', 'reviewing') and now() > c.notify_due_at) as notify_overdue,
         (c.status = 'accepted' and now() > c.publish_due_at)                as publish_overdue
  from nomad_news.correction_requests c;
revoke all on nomad_news.correction_sla from public, anon, authenticated;
grant select on nomad_news.correction_sla to authenticated, service_role;

-- =====================================================================
-- 11. RPC (SECURITY DEFINER). 점검표: set search_path = '' / 스키마 한정 / is_service_caller / 역할 헬퍼 / 상태 검사 / 감사 / EXECUTE 정리(12절)
--     독자가 부르는 함수(ensure_reader, post_comment 등)는 nomad_core.write_audit 를 부르지 않는다(원본 유지):
--     독자는 조직 멤버가 아니라 조직 감사 로그 대상이 아니다. 독자 행위의 기록은 각 행의 시각 컬럼이 맡는다.
--     N1 잠금: 쓰기 RPC 는 plan_active(기능 newsroom)가 없으면 NW014. assert_staff(..., true) 와 독자 경로 일부는 잠그지 않는다
--     (법정 의무·권리 보호: 게시 중단·보관, 정정 청구 접수·처리·정정문, 댓글 임시조치·신고·삭제, 독자 차단, 탈퇴, 수신 거부, 내 프로필).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 11.0 내부 헬퍼 (EXECUTE 는 service_role 만. DEFINER 함수 안에서만 쓴다)
-- ---------------------------------------------------------------------
-- 호출자가 서버면 'service', 편집국이면 도메인 역할을 돌려주고, 아니면 42501.
-- p_allow_lapsed = false(기본)면 구독 끊김(기능 newsroom 없음)에 NW014 — 서버 호출도 같다(예약 게시 포함).
create function nomad_news.assert_staff(p_org uuid, p_roles text[], p_ctx text, p_allow_lapsed boolean default false)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_role text;
begin
  if nomad_core.is_service_caller() then
    v_role := 'service';
  else
    v_role := nomad_news.staff_role(p_org);
    if v_role is null or not (v_role = any (p_roles)) then
      raise exception '%: role not allowed', p_ctx using errcode = '42501';
    end if;
  end if;
  if not coalesce(p_allow_lapsed, false) and not nomad_news.plan_active(p_org) then
    raise exception '%: newspaper subscription inactive', p_ctx using errcode = 'NW014';
  end if;
  return v_role;
end;
$$;

-- 행 id 로 부르는 RPC 용(W7): 그 행의 조직 편집국이 아니면(서버 제외) 권한 없음과 행 없음을 구분하지 않게 P0002.
-- 같은 조직 편집국의 역할 부족은 assert_staff 그대로 42501(행 존재는 이미 볼 수 있다).
create function nomad_news.assert_staff_row(p_org uuid, p_roles text[], p_ctx text, p_allow_lapsed boolean default false)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_org is null or (not nomad_core.is_service_caller() and nomad_news.staff_role(p_org) is null) then
    raise exception '%: not found', p_ctx using errcode = 'P0002';
  end if;
  return nomad_news.assert_staff(p_org, p_roles, p_ctx, p_allow_lapsed);
end;
$$;

create function nomad_news.token_hash(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(convert_to(coalesce(p_token, ''), 'UTF8'), 'sha256'), 'hex');
$$;

create function nomad_news.election_blackout_active(p_org uuid, p_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from nomad_news.election_periods e
                 where e.organization_id = p_org and e.status = 'active'
                   and p_at >= e.poll_blackout_from and p_at < e.poll_blackout_until);
$$;

create function nomad_news.wire_contract_valid(p_org uuid, p_contract_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from nomad_news.wire_contracts w
                 where w.id = p_contract_id and w.organization_id = p_org and w.status = 'active'
                   and w.starts_on <= p_on and (w.ends_on is null or w.ends_on >= p_on));
$$;

-- 허용 키 밖의 키가 있으면 NW015
create function nomad_news.assert_keys(p_fields jsonb, p_allowed text[], p_ctx text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare v_bad text;
begin
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception '%: fields must be an object', p_ctx using errcode = 'NW015';
  end if;
  select string_agg(k, ', ') into v_bad from jsonb_object_keys(p_fields) as k where not (k = any (p_allowed));
  if v_bad is not null then
    raise exception '%: unknown fields %', p_ctx, v_bad using errcode = 'NW015';
  end if;
end;
$$;

create function nomad_news.add_revision(p_article nomad_news.articles, p_kind text, p_note text, p_is_public boolean,
                                             p_snapshot boolean, p_request_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  insert into nomad_news.article_revisions (organization_id, article_id, kind, status_after, title, body, note, is_public, correction_request_id, created_by)
  values (p_article.organization_id, p_article.id, p_kind, p_article.status,
          case when p_snapshot then p_article.title end, case when p_snapshot then p_article.body end,
          p_note, coalesce(p_is_public, false), p_request_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.1 신문사 개설 (NW-F-001): request(사용자) → approve/reject(운영자 서버)
-- ---------------------------------------------------------------------
create function nomad_news.request_newspaper(
  p_org               uuid,
  p_slug              text,
  p_title             text,
  p_media_kind        text,
  p_registration_no   text,
  p_registration_date date,
  p_publisher_name    text,
  p_contact_email     text,
  p_contact_phone     text,
  p_certificate_path  text,
  p_message           text default null,
  p_plan_code         text default null
)
returns nomad_news.newspaper_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_slug, '')));
  v_ok   boolean;
  v_row  nomad_news.newspaper_applications;
begin
  if v_uid is null then
    raise exception 'request_newspaper: login required' using errcode = '42501';
  end if;
  -- N2: 신청 조직은 호출자가 owner 인 팀 조직(개인 조직 불가)
  if coalesce(nomad_core.organization_role(p_org), '') <> 'owner'
     or not exists (select 1 from nomad_core.organizations o where o.id = p_org and o.kind = 'team') then
    raise exception 'request_newspaper: owner of a team organization required' using errcode = '42501';
  end if;
  select r.allowed into v_ok from nomad_core.rate_limit_take('news:apply:' || v_uid::text, 5, 86400) r;
  if not v_ok then
    raise exception 'request_newspaper: rate limited' using errcode = 'NW011';
  end if;
  if exists (select 1 from nomad_news.newspapers n where n.organization_id = p_org) then
    raise exception 'request_newspaper: organization already has a newspaper' using errcode = 'NW001';
  end if;
  if v_slug in ('www', 'newsroom', 'login', 'admin', 'api', 'ops', 'app', 'mail', 'static', 'cdn', 'auth', 'help', 'status', 'news', 'assets')
     or exists (select 1 from nomad_news.newspapers n where n.slug = v_slug)
     or exists (select 1 from nomad_news.newspaper_applications a where a.slug = v_slug and a.status = 'pending') then
    raise exception 'request_newspaper: slug unavailable' using errcode = 'NW001';
  end if;
  if exists (select 1 from nomad_news.newspaper_applications a where a.organization_id = p_org and a.status = 'pending') then
    raise exception 'request_newspaper: a pending application already exists' using errcode = 'NW001';
  end if;
  insert into nomad_news.newspaper_applications (applicant_id, organization_id, slug, title, media_kind, registration_no, registration_date,
                                                 publisher_name, contact_email, contact_phone, certificate_path, message, plan_code)
  values (v_uid, p_org, v_slug, btrim(p_title), p_media_kind, btrim(p_registration_no), p_registration_date,
          btrim(p_publisher_name), lower(btrim(p_contact_email)), btrim(p_contact_phone), p_certificate_path, p_message, p_plan_code)
  returning * into v_row;
  perform nomad_core.write_audit(p_org, 'newspaper.request', 'newspaper_application', v_row.id::text, null,
                                 jsonb_build_object('slug', v_row.slug, 'title', v_row.title));
  return v_row;
end;
$$;

create function nomad_news.withdraw_newspaper_request(p_application_id uuid)
returns nomad_news.newspaper_applications
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newspaper_applications;
begin
  select * into v_row from nomad_news.newspaper_applications where id = p_application_id for update;
  if not found or (not nomad_core.is_service_caller() and v_row.applicant_id is distinct from auth.uid()) then
    raise exception 'withdraw_newspaper_request: not found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'withdraw_newspaper_request: invalid state %', v_row.status using errcode = 'NW004';
  end if;
  update nomad_news.newspaper_applications set status = 'withdrawn', decided_at = now() where id = p_application_id returning * into v_row;
  return v_row;
end;
$$;

-- 운영자 승인(service_role): 이 스키마 표만 바꾼다(N2). 조직·owner 멤버십은 신청 전에 core 가 만들었고,
-- 구독·체험·크레딧은 외부 결제 서버(D1)가 nomad_core 경로로 부여한다. 원본의 core 표 쓰기(조직·멤버·구독·이용권·크레딧)는 없앴다.
create function nomad_news.approve_newspaper(p_application_id uuid, p_note text default null)
returns nomad_news.newspapers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app nomad_news.newspaper_applications;
  v_row nomad_news.newspapers;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'approve_newspaper: service_role only' using errcode = '42501';
  end if;
  select * into v_app from nomad_news.newspaper_applications where id = p_application_id for update;
  if not found then
    raise exception 'approve_newspaper: application not found' using errcode = 'P0002';
  end if;
  if v_app.status <> 'pending' then
    raise exception 'approve_newspaper: invalid state %', v_app.status using errcode = 'NW004';
  end if;
  if not exists (select 1 from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
                 where m.organization_id = v_app.organization_id and m.user_id = v_app.applicant_id and m.role = 'owner' and o.active) then
    raise exception 'approve_newspaper: applicant is no longer the owner of an active organization' using errcode = 'NW004';
  end if;
  if exists (select 1 from nomad_news.newspapers n where n.slug = v_app.slug or n.organization_id = v_app.organization_id) then
    raise exception 'approve_newspaper: slug or organization already used' using errcode = 'NW001';
  end if;

  insert into nomad_news.newspapers (organization_id, application_id, slug, title, media_kind, registration_no, registration_date, publisher_name, created_by)
  values (v_app.organization_id, v_app.id, v_app.slug, v_app.title, v_app.media_kind, v_app.registration_no, v_app.registration_date,
          v_app.publisher_name, auth.uid())
  returning * into v_row;
  insert into nomad_news.staff (organization_id, user_id, role, status, byline_name, title_label, joined_at)
  values (v_app.organization_id, v_app.applicant_id, 'publisher', 'active', v_app.publisher_name, '발행인', now());
  insert into nomad_news.syndication_settings (organization_id) values (v_app.organization_id) on conflict (organization_id) do nothing;
  insert into nomad_news.paywall_rules (organization_id) values (v_app.organization_id) on conflict (organization_id) do nothing;

  update nomad_news.newspaper_applications
     set status = 'approved', decided_at = now(), decided_by = auth.uid(), decision_note = p_note
   where id = v_app.id;
  perform nomad_core.write_audit(v_app.organization_id, 'newspaper.approve', 'newspaper', v_row.id::text, null,
                                 jsonb_build_object('slug', v_app.slug, 'requested_plan', v_app.plan_code, 'application_id', v_app.id));
  return v_row;
end;
$$;

create function nomad_news.reject_newspaper(p_application_id uuid, p_note text)
returns nomad_news.newspaper_applications
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newspaper_applications;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'reject_newspaper: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_news.newspaper_applications where id = p_application_id for update;
  if not found then
    raise exception 'reject_newspaper: application not found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'reject_newspaper: invalid state %', v_row.status using errcode = 'NW004';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'reject_newspaper: reason required' using errcode = 'NW015';
  end if;
  update nomad_news.newspaper_applications set status = 'rejected', decided_at = now(), decided_by = auth.uid(), decision_note = p_note
   where id = p_application_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'newspaper.reject', 'newspaper_application', v_row.id::text);
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.2 매체정보(NW-F-002)와 신문사 상태
-- ---------------------------------------------------------------------
create function nomad_news.set_newspaper_profile(p_org uuid, p_profile jsonb)
returns nomad_news.newspapers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old nomad_news.newspapers;
  v_row nomad_news.newspapers;
  r     nomad_news.newspapers;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'set_newspaper_profile');
  perform nomad_news.assert_keys(p_profile, array['title', 'legal_name', 'media_kind', 'registration_no', 'registration_date',
    'publisher_name', 'editor_name', 'youth_officer_name', 'privacy_officer_name', 'publish_address', 'phone', 'email',
    'first_published_on', 'ethics_code_url', 'comments_enabled', 'banned_words'], 'set_newspaper_profile');
  select * into v_old from nomad_news.newspapers where organization_id = p_org for update;
  if not found then
    raise exception 'set_newspaper_profile: newspaper not found' using errcode = 'P0002';
  end if;
  if v_old.status = 'closed' then
    raise exception 'set_newspaper_profile: newspaper is closed' using errcode = 'NW002';
  end if;
  r := jsonb_populate_record(null::nomad_news.newspapers, p_profile);
  update nomad_news.newspapers set
    title                = case when p_profile ? 'title'                then btrim(r.title)                else title end,
    legal_name           = case when p_profile ? 'legal_name'           then nullif(btrim(r.legal_name), '') else legal_name end,
    media_kind           = case when p_profile ? 'media_kind'           then r.media_kind                  else media_kind end,
    registration_no      = case when p_profile ? 'registration_no'      then nullif(btrim(r.registration_no), '') else registration_no end,
    registration_date    = case when p_profile ? 'registration_date'    then r.registration_date           else registration_date end,
    publisher_name       = case when p_profile ? 'publisher_name'       then nullif(btrim(r.publisher_name), '') else publisher_name end,
    editor_name          = case when p_profile ? 'editor_name'          then nullif(btrim(r.editor_name), '') else editor_name end,
    youth_officer_name   = case when p_profile ? 'youth_officer_name'   then nullif(btrim(r.youth_officer_name), '') else youth_officer_name end,
    privacy_officer_name = case when p_profile ? 'privacy_officer_name' then nullif(btrim(r.privacy_officer_name), '') else privacy_officer_name end,
    publish_address      = case when p_profile ? 'publish_address'      then nullif(btrim(r.publish_address), '') else publish_address end,
    phone                = case when p_profile ? 'phone'                then nullif(btrim(r.phone), '')    else phone end,
    email                = case when p_profile ? 'email'                then nullif(lower(btrim(r.email)), '') else email end,
    first_published_on   = case when p_profile ? 'first_published_on'   then r.first_published_on          else first_published_on end,
    ethics_code_url      = case when p_profile ? 'ethics_code_url'      then r.ethics_code_url             else ethics_code_url end,
    comments_enabled     = case when p_profile ? 'comments_enabled'     then coalesce(r.comments_enabled, false) else comments_enabled end,
    banned_words         = case when p_profile ? 'banned_words'         then coalesce(r.banned_words, '{}') else banned_words end
  where organization_id = p_org
  returning * into v_row;
  perform nomad_core.write_audit(p_org, 'newspaper.profile', 'newspaper', v_row.id::text,
    jsonb_build_object('complete', v_old.profile_completed_at is not null, 'comments_enabled', v_old.comments_enabled),
    jsonb_build_object('complete', v_row.profile_completed_at is not null, 'comments_enabled', v_row.comments_enabled,
                       'fields', (select jsonb_agg(k) from jsonb_object_keys(p_profile) k where k <> 'banned_words')));
  return v_row;
end;
$$;

create function nomad_news.set_newspaper_status(p_org uuid, p_status text, p_reason text default null)
returns nomad_news.newspapers
language plpgsql
security definer
set search_path = ''
as $$
declare v_old nomad_news.newspapers; v_row nomad_news.newspapers;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'set_newspaper_status: service_role only' using errcode = '42501';
  end if;
  select * into v_old from nomad_news.newspapers where organization_id = p_org for update;
  if not found then
    raise exception 'set_newspaper_status: newspaper not found' using errcode = 'P0002';
  end if;
  update nomad_news.newspapers set status = p_status, status_reason = p_reason where organization_id = p_org returning * into v_row;
  perform nomad_core.write_audit(p_org, 'newspaper.status', 'newspaper', v_row.id::text,
                           jsonb_build_object('status', v_old.status), jsonb_build_object('status', v_row.status, 'reason', p_reason));
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.3 편집국 구성원(NW-F-004). 초대는 core 초대(email+token, 역할 editor)를 거친다(core 역할 검사·좌석 한도 재사용, N3).
--      publisher 는 승인 때 한 번 만들어지고 이 함수들로는 바뀌지 않는다(소유권 이전은 core 절차 + 운영, 팀장 확인).
--      core 초대·멤버 제거는 owner·admin 만이므로 초대·타인 제거는 publisher(owner)만 한다(원본은 editor 도 가능).
-- ---------------------------------------------------------------------
create function nomad_news.invite_staff(p_org uuid, p_email text, p_role text, p_byline_name text, p_title_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max   integer;
  v_used  integer;
  v_token text;
  v_inv   uuid;
  v_row   nomad_news.staff_invitations;
begin
  perform nomad_news.assert_staff(p_org, array['publisher'], 'invite_staff');
  if p_role is null or p_role not in ('editor', 'desk', 'reporter', 'contributor', 'ad_manager') then
    raise exception 'invite_staff: invalid role %', p_role using errcode = 'NW015';
  end if;
  -- 인원 한도(news_staff_max, 키 없으면 0 → 초대 불가). 발행인 포함 활성·초대 중 staff + 아직 유효한 초대
  perform 1 from nomad_core.organizations where id = p_org for update;
  v_max := nomad_news.limit_int(p_org, 'news_staff_max');
  select (select count(*) from nomad_news.staff s where s.organization_id = p_org and s.status <> 'removed')
       + (select count(*) from nomad_news.staff_invitations si join nomad_core.invitations i on i.id = si.invitation_id
          where si.organization_id = p_org and si.accepted_at is null and i.accepted_at is null and i.expires_at > now())
    into v_used;
  if v_used >= v_max then
    raise exception 'invite_staff: staff limit % reached', v_max using errcode = 'NW014';
  end if;
  v_token := nomad_core.create_invitation(p_org, p_email, 'editor');
  select i.id into v_inv from nomad_core.invitations i where i.token = v_token;
  insert into nomad_news.staff_invitations (organization_id, invitation_id, role, byline_name, title_label, invited_by)
  values (p_org, v_inv, p_role, btrim(p_byline_name), p_title_label, auth.uid())
  returning * into v_row;
  perform nomad_core.write_audit(p_org, 'staff.invite', 'staff_invitation', v_row.id::text, null, jsonb_build_object('role', p_role));
  -- 토큰 원문은 초대 메일용으로 호출자(publisher)에게 한 번만 돌려준다(core create_invitation 과 같은 계약)
  return jsonb_build_object('invitation_id', v_inv, 'staff_invitation_id', v_row.id, 'token', v_token);
end;
$$;

-- 초대 수락: core accept_invitation(이메일 일치·좌석 검사) 뒤 staff 행을 만든다(재초대면 removed → invited → active).
create function nomad_news.accept_staff_invitation(p_token text)
returns nomad_news.staff
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_inv nomad_core.invitations;
  v_si  nomad_news.staff_invitations;
  v_old nomad_news.staff;
  v_row nomad_news.staff;
begin
  if v_uid is null then
    raise exception 'accept_staff_invitation: login required' using errcode = '42501';
  end if;
  select * into v_inv from nomad_core.invitations where token = p_token;
  if found then
    select * into v_si from nomad_news.staff_invitations where invitation_id = v_inv.id for update;
  end if;
  if v_inv.id is null or v_si.id is null then
    raise exception 'accept_staff_invitation: invitation not found' using errcode = 'P0002';
  end if;
  if not nomad_news.plan_active(v_si.organization_id) then
    raise exception 'accept_staff_invitation: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  perform nomad_core.accept_invitation(p_token);
  update nomad_news.staff_invitations set accepted_at = now() where id = v_si.id;
  select * into v_old from nomad_news.staff where organization_id = v_si.organization_id and user_id = v_uid for update;
  if v_old.id is null then
    insert into nomad_news.staff (organization_id, user_id, role, status, byline_name, title_label, invited_by)
    values (v_si.organization_id, v_uid, v_si.role, 'invited', v_si.byline_name, v_si.title_label, v_si.invited_by);
  else
    -- core accept_invitation 이 통과했으므로 core 멤버십이 없던 사람이다. active 로 남은 행은 core 에서 따로 제거된 흔적(S1)
    -- → removed 로 닫고 새 초대 역할로 다시 연다(joined_at 도 새로 잡힌다)
    if v_old.status = 'active' then
      update nomad_news.staff set status = 'removed' where id = v_old.id;
    end if;
    if v_old.status in ('active', 'removed') then
      update nomad_news.staff set status = 'invited', role = v_si.role, byline_name = v_si.byline_name, title_label = v_si.title_label,
             invited_by = v_si.invited_by
       where id = v_old.id;
    end if;
  end if;
  update nomad_news.staff set status = 'active' where organization_id = v_si.organization_id and user_id = v_uid returning * into v_row;
  perform nomad_core.write_audit(v_si.organization_id, 'staff.accept', 'user', v_uid::text, null, jsonb_build_object('role', v_row.role));
  return v_row;
end;
$$;

-- 도메인 역할만 바꾼다(core 역할은 모두 editor 라 그대로). 발행인·편집인, 편집인은 편집인 역할을 다루지 못한다.
create function nomad_news.set_staff_role(p_org uuid, p_user_id uuid, p_role text)
returns nomad_news.staff
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller text;
  v_old    nomad_news.staff;
  v_row    nomad_news.staff;
begin
  v_caller := nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'set_staff_role');
  if p_user_id = auth.uid() then
    raise exception 'set_staff_role: cannot change your own role' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('editor', 'desk', 'reporter', 'contributor', 'ad_manager') then
    raise exception 'set_staff_role: invalid role %', p_role using errcode = 'NW015';
  end if;
  select * into v_old from nomad_news.staff where organization_id = p_org and user_id = p_user_id and status in ('invited', 'active') for update;
  if not found then
    raise exception 'set_staff_role: staff not found' using errcode = 'P0002';
  end if;
  if v_old.role = 'publisher' then
    raise exception 'set_staff_role: publisher role changes only by ownership transfer' using errcode = '42501';
  end if;
  if v_caller = 'editor' and (v_old.role = 'editor' or p_role = 'editor') then
    raise exception 'set_staff_role: editor cannot change editor roles' using errcode = '42501';
  end if;
  update nomad_news.staff set role = p_role where id = v_old.id returning * into v_row;
  perform nomad_core.write_audit(p_org, 'staff.role', 'user', p_user_id::text,
                                 jsonb_build_object('role', v_old.role), jsonb_build_object('role', p_role));
  return v_row;
end;
$$;

-- 제거: 본인 탈퇴 또는 발행인(core owner). core 멤버십은 nomad_core.remove_member 가 지운다(구독 끊김에도 가능).
create function nomad_news.remove_staff(p_org uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_caller text; v_old nomad_news.staff;
begin
  if auth.uid() is null then
    raise exception 'remove_staff: login required' using errcode = '42501';
  end if;
  v_caller := nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk', 'reporter', 'contributor', 'ad_manager'], 'remove_staff', true);
  if p_user_id <> auth.uid() and v_caller <> 'publisher' then
    raise exception 'remove_staff: not allowed' using errcode = '42501';
  end if;
  select * into v_old from nomad_news.staff where organization_id = p_org and user_id = p_user_id and status in ('invited', 'active') for update;
  if not found then
    raise exception 'remove_staff: staff not found' using errcode = 'P0002';
  end if;
  if v_old.role = 'publisher' then
    raise exception 'remove_staff: publisher cannot be removed' using errcode = '42501';
  end if;
  perform nomad_core.remove_member(p_org, p_user_id);
  update nomad_news.staff set status = 'removed' where id = v_old.id;
  perform nomad_core.write_audit(p_org, 'staff.remove', 'user', p_user_id::text, jsonb_build_object('role', v_old.role), null);
end;
$$;

create function nomad_news.update_my_staff_profile(p_org uuid, p_fields jsonb)
returns nomad_news.staff
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.staff; r nomad_news.staff;
begin
  perform nomad_news.assert_keys(p_fields, array['byline_name', 'title_label', 'bio', 'photo_path', 'email_public', 'is_public_profile'], 'update_my_staff_profile');
  if auth.uid() is null then
    raise exception 'update_my_staff_profile: login required' using errcode = '42501';
  end if;
  r := jsonb_populate_record(null::nomad_news.staff, p_fields);
  update nomad_news.staff set
    byline_name       = case when p_fields ? 'byline_name'       then btrim(r.byline_name) else byline_name end,
    title_label       = case when p_fields ? 'title_label'       then r.title_label        else title_label end,
    bio               = case when p_fields ? 'bio'               then r.bio                else bio end,
    photo_path        = case when p_fields ? 'photo_path'        then r.photo_path         else photo_path end,
    email_public      = case when p_fields ? 'email_public'      then r.email_public       else email_public end,
    is_public_profile = case when p_fields ? 'is_public_profile' then coalesce(r.is_public_profile, true) else is_public_profile end
  where organization_id = p_org and user_id = auth.uid() and status = 'active'
  returning * into v_row;
  if not found then
    raise exception 'update_my_staff_profile: not an active staff member' using errcode = '42501';
  end if;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.4 분류(섹션·지역·태그): DESK
-- ---------------------------------------------------------------------
create function nomad_news.upsert_taxonomy(p_org uuid, p_kind text, p_id uuid, p_fields jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid; s nomad_news.sections; g nomad_news.regions; t nomad_news.tags;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk'], 'upsert_taxonomy');
  if p_kind = 'section' then
    perform nomad_news.assert_keys(p_fields, array['slug', 'name', 'parent_id', 'sort_order', 'is_active'], 'upsert_taxonomy');
    s := jsonb_populate_record(null::nomad_news.sections, p_fields);
    if p_id is null then
      insert into nomad_news.sections (organization_id, slug, name, parent_id, sort_order, is_active)
      values (p_org, s.slug, s.name, s.parent_id, coalesce(s.sort_order, 0), coalesce(s.is_active, true)) returning id into v_id;
    else
      update nomad_news.sections set
        slug = case when p_fields ? 'slug' then s.slug else slug end, name = case when p_fields ? 'name' then s.name else name end,
        parent_id = case when p_fields ? 'parent_id' then s.parent_id else parent_id end,
        sort_order = case when p_fields ? 'sort_order' then coalesce(s.sort_order, 0) else sort_order end,
        is_active = case when p_fields ? 'is_active' then coalesce(s.is_active, true) else is_active end
      where id = p_id and organization_id = p_org returning id into v_id;
    end if;
  elsif p_kind = 'region' then
    perform nomad_news.assert_keys(p_fields, array['slug', 'name', 'level', 'admin_code', 'parent_id', 'sort_order', 'is_active'], 'upsert_taxonomy');
    g := jsonb_populate_record(null::nomad_news.regions, p_fields);
    if p_id is null then
      insert into nomad_news.regions (organization_id, slug, name, level, admin_code, parent_id, sort_order, is_active)
      values (p_org, g.slug, g.name, coalesce(g.level, 'sigungu'), g.admin_code, g.parent_id, coalesce(g.sort_order, 0), coalesce(g.is_active, true))
      returning id into v_id;
    else
      update nomad_news.regions set
        slug = case when p_fields ? 'slug' then g.slug else slug end, name = case when p_fields ? 'name' then g.name else name end,
        level = case when p_fields ? 'level' then g.level else level end,
        admin_code = case when p_fields ? 'admin_code' then g.admin_code else admin_code end,
        parent_id = case when p_fields ? 'parent_id' then g.parent_id else parent_id end,
        sort_order = case when p_fields ? 'sort_order' then coalesce(g.sort_order, 0) else sort_order end,
        is_active = case when p_fields ? 'is_active' then coalesce(g.is_active, true) else is_active end
      where id = p_id and organization_id = p_org returning id into v_id;
    end if;
  elsif p_kind = 'tag' then
    perform nomad_news.assert_keys(p_fields, array['slug', 'name', 'is_active'], 'upsert_taxonomy');
    t := jsonb_populate_record(null::nomad_news.tags, p_fields);
    if p_id is null then
      insert into nomad_news.tags (organization_id, slug, name, is_active) values (p_org, t.slug, t.name, coalesce(t.is_active, true)) returning id into v_id;
    else
      update nomad_news.tags set
        slug = case when p_fields ? 'slug' then t.slug else slug end, name = case when p_fields ? 'name' then t.name else name end,
        is_active = case when p_fields ? 'is_active' then coalesce(t.is_active, true) else is_active end
      where id = p_id and organization_id = p_org returning id into v_id;
    end if;
  else
    raise exception 'upsert_taxonomy: invalid kind %', p_kind using errcode = 'NW015';
  end if;
  if v_id is null then
    raise exception 'upsert_taxonomy: not found' using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.5 기사(NW-F-010~012, 017, 050)
--   save_article : 만들기(draft) 또는 고치기. 기자·기고자는 자기 draft 만, 데스크 이상은 draft/submitted/approved/published/unpublished.
--                  게시 후 수정은 change_note(공개 수정 사유) 필수 → revised_at, revision_note, 공개 이력 1행.
--                  기고자의 유형은 contribution 으로 고정. origin(ai_press_release, import)은 서버만 지정한다.
-- ---------------------------------------------------------------------
create function nomad_news.save_article(p_org uuid, p_article_id uuid, p_fields jsonb)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role   text;
  v_old    nomad_news.articles;
  v_row    nomad_news.articles;
  r        nomad_news.articles;
  v_own    boolean;
  v_byline text;
  v_slug   text;
  v_note   text := nullif(btrim(coalesce(p_fields ->> 'change_note', '')), '');
  v_auto   boolean := coalesce((p_fields ->> 'autosave')::boolean, false);
  v_ids    uuid[];
  -- 독자에게 보이는 내용 필드. 게시 후 이 필드를 바꾸면 공개 수정 사유가 필요하다(댓글·SEO·속보 표시 같은 설정 변경은 아님)
  v_content boolean := p_fields ?| array['title', 'subtitle', 'summary', 'body', 'body_text', 'type', 'byline', 'sponsor_label',
                                         'ai_assisted', 'ai_disclosure', 'wire_contract_id', 'source_note', 'is_poll', 'poll_disclosure',
                                         'hero_media_id', 'media_ids', 'is_premium'];
  v_public_edit boolean := false;
begin
  v_role := nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk', 'reporter', 'contributor'], 'save_article');
  perform nomad_news.assert_keys(p_fields, array['slug', 'title', 'subtitle', 'summary', 'body', 'body_text', 'type', 'origin',
    'section_id', 'author_id', 'byline', 'is_premium', 'sponsor_label', 'ai_assisted', 'ai_disclosure', 'wire_contract_id',
    'source_note', 'is_poll', 'poll_disclosure', 'is_breaking', 'is_live', 'comments_enabled', 'embargo_until', 'hero_media_id',
    'media_ids', 'seo', 'legacy_id', 'legacy_url', 'region_ids', 'tag_ids', 'change_note', 'autosave'], 'save_article');
  r := jsonb_populate_record(null::nomad_news.articles, p_fields - 'region_ids' - 'tag_ids' - 'change_note' - 'autosave');
  if p_fields ? 'origin' and coalesce(r.origin, 'human') <> 'human' and v_role <> 'service' then
    raise exception 'save_article: only the server can set origin %', r.origin using errcode = '42501';
  end if;
  -- W4: 데스크 미만(기자·기고자)은 저자를 본인으로만, 광고·전재 유형과 속보 표시는 데스크 이상
  if v_role in ('reporter', 'contributor') then
    if p_fields ? 'author_id' and r.author_id is distinct from auth.uid() then
      raise exception 'save_article: reporters can only author their own articles' using errcode = '42501';
    end if;
    if p_fields ? 'type' and r.type in ('sponsored', 'wire') then
      raise exception 'save_article: type % requires desk', r.type using errcode = '42501';
    end if;
    if p_fields ? 'is_breaking' and coalesce(r.is_breaking, false) then
      raise exception 'save_article: breaking flag requires desk' using errcode = '42501';
    end if;
  end if;
  if p_fields ? 'author_id' and r.author_id is not null
     and not exists (select 1 from nomad_news.staff s where s.organization_id = p_org and s.user_id = r.author_id and s.status = 'active') then
    raise exception 'save_article: author must be active staff' using errcode = 'NW015';
  end if;
  if r.media_ids is not null and exists (select 1 from unnest(r.media_ids) m
       where not exists (select 1 from nomad_news.media_assets x where x.id = m and x.organization_id = p_org)) then
    raise exception 'save_article: media must belong to the newspaper' using errcode = '23503';
  end if;
  if v_role = 'contributor' then
    r.type := 'contribution';
  end if;

  if p_article_id is null then
    select s.byline_name into v_byline from nomad_news.staff s where s.organization_id = p_org and s.user_id = coalesce(r.author_id, auth.uid());
    v_slug := coalesce(nullif(btrim(r.slug), ''), 'a' || encode(extensions.gen_random_bytes(6), 'hex'));
    insert into nomad_news.articles (organization_id, slug, title, subtitle, summary, body, body_text, type, origin, section_id, author_id, byline,
      is_premium, sponsor_label, ai_assisted, ai_disclosure, wire_contract_id, source_note, is_poll, poll_disclosure,
      is_breaking, is_live, comments_enabled, embargo_until, hero_media_id, media_ids, seo, legacy_id, legacy_url, created_by)
    values (p_org, v_slug, btrim(r.title), r.subtitle, r.summary, coalesce(r.body, '[]'::jsonb), coalesce(r.body_text, ''),
      coalesce(case when v_role = 'contributor' then 'contribution' else r.type end, 'original'), coalesce(r.origin, 'human'),
      r.section_id, coalesce(r.author_id, auth.uid()), coalesce(nullif(btrim(r.byline), ''), v_byline, '편집국'),
      coalesce(r.is_premium, false), r.sponsor_label, coalesce(r.ai_assisted, false), r.ai_disclosure, r.wire_contract_id, r.source_note,
      coalesce(r.is_poll, false), r.poll_disclosure, coalesce(r.is_breaking, false), coalesce(r.is_live, false),
      coalesce(r.comments_enabled, true), r.embargo_until, r.hero_media_id, coalesce(r.media_ids, '{}'), coalesce(r.seo, '{}'::jsonb),
      r.legacy_id, r.legacy_url, auth.uid())
    returning * into v_row;
  else
    select * into v_old from nomad_news.articles where id = p_article_id and organization_id = p_org for update;
    if not found then
      raise exception 'save_article: not found' using errcode = 'P0002';
    end if;
    if p_fields ? 'origin' and r.origin is distinct from v_old.origin then
      raise exception 'save_article: origin is immutable' using errcode = '22023';
    end if;
    v_own := v_old.created_by = auth.uid() or v_old.author_id = auth.uid();
    if v_role in ('reporter', 'contributor') then
      if not v_own then
        raise exception 'save_article: only your own articles' using errcode = '42501';
      end if;
      if v_old.status <> 'draft' then
        raise exception 'save_article: reporters edit drafts only (state %)', v_old.status using errcode = 'NW004';
      end if;
    elsif v_role = 'service' and v_old.status <> 'draft' then
      -- W3: 서버(AI 초안·가져오기)는 draft 만 고친다. 승인 뒤 내용은 사람만 바꾼다
      raise exception 'save_article: the server edits drafts only (state %)', v_old.status using errcode = 'NW004';
    elsif v_old.status in ('scheduled', 'archived') then
      raise exception 'save_article: cannot edit in state %', v_old.status using errcode = 'NW004';
    end if;
    v_public_edit := v_old.status in ('published', 'unpublished') and v_content;
    if v_public_edit and v_note is null then
      raise exception 'save_article: change_note is required after publication' using errcode = 'NW015';
    end if;
    update nomad_news.articles set
      slug             = case when p_fields ? 'slug'             then r.slug             else slug end,
      title            = case when p_fields ? 'title'            then btrim(r.title)     else title end,
      subtitle         = case when p_fields ? 'subtitle'         then r.subtitle         else subtitle end,
      summary          = case when p_fields ? 'summary'          then r.summary          else summary end,
      body             = case when p_fields ? 'body'             then coalesce(r.body, '[]'::jsonb) else body end,
      body_text        = case when p_fields ? 'body_text'        then coalesce(r.body_text, '') else body_text end,
      type             = case when v_role = 'contributor' then 'contribution' when p_fields ? 'type' then r.type else type end,
      section_id       = case when p_fields ? 'section_id'       then r.section_id       else section_id end,
      author_id        = case when p_fields ? 'author_id'        then r.author_id        else author_id end,
      byline           = case when p_fields ? 'byline'           then btrim(r.byline)    else byline end,
      is_premium       = case when p_fields ? 'is_premium'       then coalesce(r.is_premium, false) else is_premium end,
      sponsor_label    = case when p_fields ? 'sponsor_label'    then r.sponsor_label    else sponsor_label end,
      ai_assisted      = case when p_fields ? 'ai_assisted'      then coalesce(r.ai_assisted, false) else ai_assisted end,
      ai_disclosure    = case when p_fields ? 'ai_disclosure'    then r.ai_disclosure    else ai_disclosure end,
      wire_contract_id = case when p_fields ? 'wire_contract_id' then r.wire_contract_id else wire_contract_id end,
      source_note      = case when p_fields ? 'source_note'      then r.source_note      else source_note end,
      is_poll          = case when p_fields ? 'is_poll'          then coalesce(r.is_poll, false) else is_poll end,
      poll_disclosure  = case when p_fields ? 'poll_disclosure'  then r.poll_disclosure  else poll_disclosure end,
      is_breaking      = case when p_fields ? 'is_breaking'      then coalesce(r.is_breaking, false) else is_breaking end,
      is_live          = case when p_fields ? 'is_live'          then coalesce(r.is_live, false) else is_live end,
      comments_enabled = case when p_fields ? 'comments_enabled' then coalesce(r.comments_enabled, true) else comments_enabled end,
      embargo_until    = case when p_fields ? 'embargo_until'    then r.embargo_until    else embargo_until end,
      hero_media_id    = case when p_fields ? 'hero_media_id'    then r.hero_media_id    else hero_media_id end,
      media_ids        = case when p_fields ? 'media_ids'        then coalesce(r.media_ids, '{}') else media_ids end,
      seo              = case when p_fields ? 'seo'              then coalesce(r.seo, '{}'::jsonb) else seo end,
      legacy_id        = case when p_fields ? 'legacy_id'        then r.legacy_id        else legacy_id end,
      legacy_url       = case when p_fields ? 'legacy_url'       then r.legacy_url       else legacy_url end,
      revised_at       = case when v_public_edit then now() else revised_at end,
      revision_note    = case when v_public_edit then v_note else revision_note end,
      revision_count   = case when v_public_edit then revision_count + 1 else revision_count end
    where id = p_article_id
    returning * into v_row;
  end if;

  if p_fields ? 'region_ids' then
    select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(p_fields -> 'region_ids', '[]'::jsonb)) x;
    delete from nomad_news.article_regions where article_id = v_row.id;
    insert into nomad_news.article_regions (organization_id, article_id, region_id) select p_org, v_row.id, u from unnest(v_ids) u;
  end if;
  if p_fields ? 'tag_ids' then
    select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(p_fields -> 'tag_ids', '[]'::jsonb)) x;
    delete from nomad_news.article_tags where article_id = v_row.id;
    insert into nomad_news.article_tags (organization_id, article_id, tag_id) select p_org, v_row.id, u from unnest(v_ids) u;
  end if;

  if v_public_edit then
    perform nomad_news.add_revision(v_row, 'update', v_note, true, true);
  elsif not v_auto then
    perform nomad_news.add_revision(v_row, 'save', null, false, true);
  end if;
  return v_row;
end;
$$;

create function nomad_news.submit_article(p_article_id uuid)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare v_role text; v_a nomad_news.articles;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  v_role := nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk', 'reporter', 'contributor'], 'submit_article');
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'submit_article: not found' using errcode = 'P0002';
  end if;
  if v_role in ('reporter', 'contributor') and not (v_a.created_by = auth.uid() or v_a.author_id = auth.uid()) then
    raise exception 'submit_article: only your own articles' using errcode = '42501';
  end if;
  if v_a.status <> 'draft' then
    raise exception 'submit_article: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  update nomad_news.articles set status = 'submitted', submitted_by = auth.uid(), review_note = null where id = p_article_id returning * into v_a;
  perform nomad_news.add_revision(v_a, 'submit', null, false, false);
  return v_a;
end;
$$;

-- 데스크 승인·반려. 승인은 사람만 한다(서버·AI 단독 승인 금지, NW006). 반려는 사유 필수.
-- 자기 기사(작성자 created_by 또는 필자 author_id가 승인자)는 승인 금지(NW016, 2026-11-16 결정 6).
-- 예외: 승인자가 발행인이고 신문사의 활성 staff가 발행인 1명뿐일 때(승인해 줄 사람이 없다)
create function nomad_news.review_article(p_article_id uuid, p_decision text, p_note text default null)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare v_a nomad_news.articles;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk'], 'review_article');
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'review_article: not found' using errcode = 'P0002';
  end if;
  if v_a.status <> 'submitted' then
    raise exception 'review_article: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  if p_decision = 'approve' then
    if auth.uid() is null then
      raise exception 'review_article: approval requires a human editor' using errcode = 'NW006';
    end if;
    if not (auth.uid() is distinct from v_a.created_by and auth.uid() is distinct from v_a.author_id)
       and not (coalesce(nomad_news.staff_role(v_a.organization_id) = 'publisher', false)
                and (select count(*) from nomad_news.staff s where s.organization_id = v_a.organization_id and s.status = 'active') = 1) then
      raise exception 'review_article: cannot approve your own article' using errcode = 'NW016';
    end if;
    update nomad_news.articles set status = 'approved', approved_by = auth.uid(), review_note = p_note where id = p_article_id returning * into v_a;
    perform nomad_news.add_revision(v_a, 'approve', p_note, false, true);
  elsif p_decision = 'reject' then
    if coalesce(btrim(p_note), '') = '' then
      raise exception 'review_article: rejection reason required' using errcode = 'NW015';
    end if;
    update nomad_news.articles set status = 'draft', review_note = p_note where id = p_article_id returning * into v_a;
    perform nomad_news.add_revision(v_a, 'reject', p_note, false, false);
  else
    raise exception 'review_article: decision must be approve or reject' using errcode = 'NW015';
  end if;
  perform nomad_core.write_audit(v_a.organization_id, 'article.' || p_decision, 'article', p_article_id::text, null,
                           jsonb_build_object('origin', v_a.origin, 'type', v_a.type));
  return v_a;
end;
$$;

-- 게시 요건(게시·예약 공통): 매체정보 완성, 신문사 활성, 사람 승인, 전재 계약, 선거 공표 금지
create function nomad_news.assert_publishable(p_a nomad_news.articles, p_at timestamptz)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_np nomad_news.newspapers;
begin
  select * into v_np from nomad_news.newspapers where organization_id = p_a.organization_id;
  if not found or v_np.status <> 'active' then
    raise exception 'publish: newspaper is not active' using errcode = 'NW002';
  end if;
  if v_np.profile_completed_at is null then
    raise exception 'publish: legally required newspaper information is incomplete' using errcode = 'NW003';
  end if;
  if p_a.approved_by is null then
    raise exception 'publish: human approval missing' using errcode = 'NW006';
  end if;
  if p_a.type = 'wire' and not nomad_news.wire_contract_valid(p_a.organization_id, p_a.wire_contract_id, (p_at at time zone 'Asia/Seoul')::date) then
    raise exception 'publish: wire contract missing or expired' using errcode = 'NW005';
  end if;
  if p_a.is_poll and nomad_news.election_blackout_active(p_a.organization_id, p_at) then
    raise exception 'publish: poll publication blackout period' using errcode = 'NW007';
  end if;
end;
$$;

create function nomad_news.schedule_article(p_article_id uuid, p_at timestamptz)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare v_a nomad_news.articles;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk'], 'schedule_article');
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'schedule_article: not found' using errcode = 'P0002';
  end if;
  if v_a.status <> 'approved' then
    raise exception 'schedule_article: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  if p_at is null or p_at <= now() or p_at > now() + interval '90 days' then
    raise exception 'schedule_article: time must be within the next 90 days' using errcode = 'NW015';
  end if;
  perform nomad_news.assert_publishable(v_a, p_at);
  update nomad_news.articles set status = 'scheduled', scheduled_for = p_at where id = p_article_id returning * into v_a;
  perform nomad_news.add_revision(v_a, 'schedule', to_char(p_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI'), false, false);
  perform nomad_core.write_audit(v_a.organization_id, 'article.schedule', 'article', p_article_id::text, null, jsonb_build_object('at', p_at));
  return v_a;
end;
$$;

-- 게시: 데스크 이상이 approved/unpublished 를, 서버(예약 실행)가 scheduled 를 게시한다. 서버는 approved 를 바로 게시할 수 없다.
create function nomad_news.publish_article(p_article_id uuid)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare v_role text; v_a nomad_news.articles;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  v_role := nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk'], 'publish_article');
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'publish_article: not found' using errcode = 'P0002';
  end if;
  if v_a.status not in ('approved', 'scheduled', 'unpublished') then
    raise exception 'publish_article: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  if v_role = 'service' and v_a.status <> 'scheduled' then
    raise exception 'publish_article: the server publishes scheduled articles only' using errcode = '42501';
  end if;
  perform nomad_news.assert_publishable(v_a, now());
  update nomad_news.articles set status = 'published' where id = p_article_id returning * into v_a;
  update nomad_news.media_assets set published_at = coalesce(published_at, now())
   where organization_id = v_a.organization_id and (id = v_a.hero_media_id or id = any (v_a.media_ids));
  perform nomad_news.add_revision(v_a, 'publish', null, false, true);
  perform nomad_core.write_audit(v_a.organization_id, 'article.publish', 'article', p_article_id::text, null,
                           jsonb_build_object('type', v_a.type, 'origin', v_a.origin, 'published_at', v_a.published_at));
  return v_a;
end;
$$;

create function nomad_news.unpublish_article(p_article_id uuid, p_reason text)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare v_a nomad_news.articles;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk'], 'unpublish_article', true);
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'unpublish_article: not found' using errcode = 'P0002';
  end if;
  if v_a.status <> 'published' then
    raise exception 'unpublish_article: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'unpublish_article: reason required' using errcode = 'NW015';
  end if;
  update nomad_news.articles set status = 'unpublished', unpublish_reason = p_reason where id = p_article_id returning * into v_a;
  perform nomad_news.add_revision(v_a, 'unpublish', p_reason, false, false);
  perform nomad_core.write_audit(v_a.organization_id, 'article.unpublish', 'article', p_article_id::text, null, jsonb_build_object('reason', p_reason));
  return v_a;
end;
$$;

create function nomad_news.archive_article(p_article_id uuid)
returns nomad_news.articles
language plpgsql
security definer
set search_path = ''
as $$
declare v_role text; v_a nomad_news.articles;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  v_role := nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk', 'reporter', 'contributor'], 'archive_article', true);
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'archive_article: not found' using errcode = 'P0002';
  end if;
  if v_role in ('reporter', 'contributor') and not (v_a.status = 'draft' and (v_a.created_by = auth.uid() or v_a.author_id = auth.uid())) then
    raise exception 'archive_article: reporters archive their own drafts only' using errcode = '42501';
  end if;
  if v_a.status not in ('draft', 'published', 'unpublished') then
    raise exception 'archive_article: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  update nomad_news.articles set status = 'archived' where id = p_article_id returning * into v_a;
  perform nomad_news.add_revision(v_a, 'archive', null, false, false);
  perform nomad_core.write_audit(v_a.organization_id, 'article.archive', 'article', p_article_id::text, null, jsonb_build_object('type', v_a.type));
  return v_a;
end;
$$;

-- 정정·반론·추후보도·해명 기록(NW-F-017, 027). 공개 이력 1행 + 기사 정정 표시. 청구 건과 연결하면 청구를 published 로.
create function nomad_news.record_article_correction(p_article_id uuid, p_kind text, p_note text, p_correction_request_id uuid default null)
returns nomad_news.article_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare v_a nomad_news.articles; v_req nomad_news.correction_requests; v_rev_id uuid; v_rev nomad_news.article_revisions;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk'], 'record_article_correction', true);
  select * into v_a from nomad_news.articles where id = p_article_id for update;
  if not found then
    raise exception 'record_article_correction: not found' using errcode = 'P0002';
  end if;
  if v_a.status not in ('published', 'unpublished') then
    raise exception 'record_article_correction: invalid state %', v_a.status using errcode = 'NW004';
  end if;
  if p_kind is null or p_kind not in ('correction', 'clarification', 'rebuttal', 'follow_up') then
    raise exception 'record_article_correction: invalid kind %', p_kind using errcode = 'NW015';
  end if;
  if char_length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'record_article_correction: public note required' using errcode = 'NW015';
  end if;
  if p_correction_request_id is not null then
    select * into v_req from nomad_news.correction_requests where id = p_correction_request_id and organization_id = v_a.organization_id for update;
    if not found then
      raise exception 'record_article_correction: request not found' using errcode = 'P0002';
    end if;
    if v_req.status <> 'accepted' then
      raise exception 'record_article_correction: request is not accepted (state %)', v_req.status using errcode = 'NW004';
    end if;
    if v_req.kind <> p_kind and not (v_req.kind = 'correction' and p_kind = 'clarification') then
      raise exception 'record_article_correction: kind % does not match request %', p_kind, v_req.kind using errcode = 'NW015';
    end if;
    -- W1: 청구가 기사를 가리키면 그 기사에만 정정문을 붙인다(URL 만 있는 청구는 처리자가 기사를 정한다)
    if v_req.article_id is not null and v_req.article_id <> p_article_id then
      raise exception 'record_article_correction: request is for another article' using errcode = 'NW015';
    end if;
  end if;
  update nomad_news.articles set last_corrected_at = now(), correction_count = correction_count + 1 where id = p_article_id returning * into v_a;
  v_rev_id := nomad_news.add_revision(v_a, p_kind, btrim(p_note), true, true, p_correction_request_id);
  if p_correction_request_id is not null then
    update nomad_news.correction_requests set status = 'published', published_revision_id = v_rev_id, article_id = coalesce(article_id, p_article_id)
     where id = p_correction_request_id;
  end if;
  perform nomad_core.write_audit(v_a.organization_id, 'article.' || p_kind, 'article', p_article_id::text, null,
                           jsonb_build_object('revision_id', v_rev_id, 'request_id', p_correction_request_id));
  select * into v_rev from nomad_news.article_revisions where id = v_rev_id;
  return v_rev;
end;
$$;

-- 예약 실행(service_role, 매분): 예약 기사 게시 + 예약 홈 편집 게시. 기사 게시가 요건 위반이면 approved 로 되돌리고 사유를 남긴다.
create function nomad_news.run_scheduled_publishing()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_ok integer := 0;
  v_fail integer := 0;
  v_layouts integer := 0;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'run_scheduled_publishing: service_role only' using errcode = '42501';
  end if;
  -- 구독 끊김 시각 기록·해제(S2: 끊김 중 풀린 엠바고 비공개의 기준)
  update nomad_news.newspapers n set plan_lapsed_at = now() where n.plan_lapsed_at is null and not nomad_news.plan_active(n.organization_id);
  update nomad_news.newspapers n set plan_lapsed_at = null where n.plan_lapsed_at is not null and nomad_news.plan_active(n.organization_id);
  for r in select a.id from nomad_news.articles a where a.status = 'scheduled' and a.scheduled_for <= now()
           order by a.scheduled_for limit 200 for update skip locked
  loop
    begin
      perform nomad_news.publish_article(r.id);
      v_ok := v_ok + 1;
    exception when others then
      update nomad_news.articles set status = 'approved', review_note = left('예약 게시 실패(' || sqlstate || '): ' || sqlerrm, 2000) where id = r.id;
      v_fail := v_fail + 1;
    end;
  end loop;
  for r in select h.id, h.organization_id from nomad_news.home_layouts h where h.status = 'scheduled' and h.publish_at <= now()
           order by h.publish_at for update skip locked
  loop
    begin
      perform nomad_news.publish_home_layout(r.id, null);
      v_layouts := v_layouts + 1;
    exception when others then
      -- 구독 끊김(NW014) 등: 예약 홈 편집은 draft 로 되돌린다
      update nomad_news.home_layouts set status = 'draft' where id = r.id;
      v_fail := v_fail + 1;
    end;
  end loop;
  return jsonb_build_object('published', v_ok, 'failed', v_fail, 'layouts', v_layouts);
end;
$$;

-- ---------------------------------------------------------------------
-- 11.6 미디어, 홈 편집, 지면, 라이브
-- ---------------------------------------------------------------------
create function nomad_news.save_media_asset(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.media_assets
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.media_assets; r nomad_news.media_assets; v_role text; v_old nomad_news.media_assets;
begin
  v_role := nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk', 'reporter', 'contributor'], 'save_media_asset');
  perform nomad_news.assert_keys(p_fields, array['bucket', 'storage_path', 'kind', 'mime', 'width', 'height', 'bytes', 'alt_text', 'caption',
                                           'credit', 'copyright_holder', 'license', 'ai_generated', 'ai_disclosure', 'status'], 'save_media_asset');
  r := jsonb_populate_record(null::nomad_news.media_assets, p_fields);
  if p_id is null then
    insert into nomad_news.media_assets (organization_id, bucket, storage_path, kind, mime, width, height, bytes, alt_text, caption, credit,
                                   copyright_holder, license, ai_generated, ai_disclosure, created_by)
    values (p_org, coalesce(r.bucket, 'public-assets'), r.storage_path, coalesce(r.kind, 'image'), r.mime, r.width, r.height, r.bytes,
            r.alt_text, r.caption, r.credit, r.copyright_holder, coalesce(r.license, 'own'), coalesce(r.ai_generated, false), r.ai_disclosure, auth.uid())
    returning * into v_row;
  else
    if p_fields ? 'storage_path' or p_fields ? 'bucket' then
      raise exception 'save_media_asset: file path is immutable' using errcode = '22023';
    end if;
    select * into v_old from nomad_news.media_assets where id = p_id and organization_id = p_org for update;
    if not found then
      raise exception 'save_media_asset: not found' using errcode = 'P0002';
    end if;
    -- R1: 기자·기고자는 자기가 올린 미게시 자산만. 게시된 자산(기사에 실려 나간 것)의 출처·라이선스 변경은 데스크 이상 + 감사 로그
    -- 승인~게시 사이 창: draft 가 아닌 기사(검토·승인·예약·게시)가 싣고 있는 자산도 기자·기고자는 못 고친다
    if v_role in ('reporter', 'contributor') and (v_old.created_by is distinct from auth.uid() or v_old.published_at is not null
        or exists (select 1 from nomad_news.articles a where a.organization_id = p_org and a.status <> 'draft'
                     and (a.hero_media_id = p_id or p_id = any (a.media_ids)))) then
      raise exception 'save_media_asset: reporters edit their own unpublished assets only' using errcode = '42501';
    end if;
    update nomad_news.media_assets set
      alt_text = case when p_fields ? 'alt_text' then r.alt_text else alt_text end,
      caption = case when p_fields ? 'caption' then r.caption else caption end,
      credit = case when p_fields ? 'credit' then r.credit else credit end,
      copyright_holder = case when p_fields ? 'copyright_holder' then r.copyright_holder else copyright_holder end,
      license = case when p_fields ? 'license' then r.license else license end,
      ai_generated = case when p_fields ? 'ai_generated' then coalesce(r.ai_generated, false) else ai_generated end,
      ai_disclosure = case when p_fields ? 'ai_disclosure' then r.ai_disclosure else ai_disclosure end,
      status = case when p_fields ? 'status' then r.status else status end,
      width = case when p_fields ? 'width' then r.width else width end,
      height = case when p_fields ? 'height' then r.height else height end
    where id = p_id returning * into v_row;
    if v_old.published_at is not null then
      perform nomad_core.write_audit(p_org, 'media_asset.update', 'media_asset', p_id::text,
        jsonb_build_object('status', v_old.status, 'credit', v_old.credit, 'license', v_old.license, 'copyright_holder', v_old.copyright_holder),
        jsonb_build_object('status', v_row.status, 'credit', v_row.credit, 'license', v_row.license, 'copyright_holder', v_row.copyright_holder,
                           'fields', (select jsonb_agg(k) from jsonb_object_keys(p_fields) k)));
    end if;
  end if;
  return v_row;
end;
$$;

create function nomad_news.save_home_layout(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.home_layouts
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.home_layouts; r nomad_news.home_layouts;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk'], 'save_home_layout');
  perform nomad_news.assert_keys(p_fields, array['name', 'template', 'blocks'], 'save_home_layout');
  r := jsonb_populate_record(null::nomad_news.home_layouts, p_fields);
  if p_id is null then
    insert into nomad_news.home_layouts (organization_id, name, template, blocks, created_by)
    values (p_org, coalesce(r.name, '새 홈 편집'), coalesce(r.template, 'traditional'), coalesce(r.blocks, '[]'::jsonb), auth.uid())
    returning * into v_row;
  else
    update nomad_news.home_layouts set
      name = case when p_fields ? 'name' then r.name else name end,
      template = case when p_fields ? 'template' then r.template else template end,
      blocks = case when p_fields ? 'blocks' then coalesce(r.blocks, '[]'::jsonb) else blocks end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'save_home_layout: not found' using errcode = 'P0002';
    end if;
  end if;
  return v_row;
end;
$$;

-- 홈 편집 게시(NW-F-013). p_at 이 미래면 예약, 아니면 즉시 게시(이전 게시본은 archived, version + 1)
create function nomad_news.publish_home_layout(p_layout_id uuid, p_at timestamptz default null)
returns nomad_news.home_layouts
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.home_layouts; v_ver integer;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.home_layouts x where x.id = p_layout_id), array['publisher', 'editor', 'desk'], 'publish_home_layout');
  select * into v_row from nomad_news.home_layouts where id = p_layout_id for update;
  if not found then
    raise exception 'publish_home_layout: not found' using errcode = 'P0002';
  end if;
  if v_row.status not in ('draft', 'scheduled') then
    raise exception 'publish_home_layout: invalid state %', v_row.status using errcode = 'NW004';
  end if;
  if p_at is not null and p_at > now() then
    update nomad_news.home_layouts set status = 'scheduled', publish_at = p_at where id = p_layout_id returning * into v_row;
    perform nomad_core.write_audit(v_row.organization_id, 'home_layout.schedule', 'home_layout', p_layout_id::text, null,
                             jsonb_build_object('publish_at', p_at, 'template', v_row.template));
    return v_row;
  end if;
  select coalesce(max(version), 0) + 1 into v_ver from nomad_news.home_layouts where organization_id = v_row.organization_id;
  update nomad_news.home_layouts set status = 'archived' where organization_id = v_row.organization_id and status = 'published';
  update nomad_news.home_layouts set status = 'published', version = v_ver, published_by = auth.uid() where id = p_layout_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'home_layout.publish', 'home_layout', p_layout_id::text, null,
                           jsonb_build_object('version', v_ver, 'template', v_row.template));
  return v_row;
end;
$$;

create function nomad_news.save_print_edition(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.print_editions
language plpgsql
security definer
set search_path = ''
as $$
declare v_old nomad_news.print_editions; v_row nomad_news.print_editions; r nomad_news.print_editions;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'save_print_edition');
  perform nomad_news.assert_keys(p_fields, array['edition_date', 'issue_no', 'title', 'pdf_path', 'page_count', 'status'], 'save_print_edition');
  if not nomad_news.has_feature(p_org, 'print_pdf') then
    raise exception 'save_print_edition: plan does not include print PDF' using errcode = 'NW014';
  end if;
  r := jsonb_populate_record(null::nomad_news.print_editions, p_fields);
  if p_id is null then
    insert into nomad_news.print_editions (organization_id, edition_date, issue_no, title, pdf_path, page_count, created_by)
    values (p_org, r.edition_date, r.issue_no, r.title, r.pdf_path, r.page_count, auth.uid()) returning * into v_row;
  else
    select * into v_old from nomad_news.print_editions where id = p_id and organization_id = p_org for update;
    if not found then
      raise exception 'save_print_edition: not found' using errcode = 'P0002';
    end if;
    if p_fields ? 'status' and r.status is distinct from v_old.status and not (
         (v_old.status = 'draft' and r.status in ('published', 'archived')) or (v_old.status = 'published' and r.status = 'archived')) then
      raise exception 'save_print_edition: invalid status transition % -> %', v_old.status, r.status using errcode = '22023';
    end if;
    update nomad_news.print_editions set
      edition_date = case when p_fields ? 'edition_date' then r.edition_date else edition_date end,
      issue_no = case when p_fields ? 'issue_no' then r.issue_no else issue_no end,
      title = case when p_fields ? 'title' then r.title else title end,
      pdf_path = case when p_fields ? 'pdf_path' then r.pdf_path else pdf_path end,
      page_count = case when p_fields ? 'page_count' then r.page_count else page_count end,
      status = case when p_fields ? 'status' then r.status else status end,
      published_at = case when p_fields ? 'status' and r.status = 'published' then now() else published_at end
    where id = p_id returning * into v_row;
    if v_row.status is distinct from v_old.status then
      perform nomad_core.write_audit(p_org, 'print_edition.' || case v_row.status when 'published' then 'publish' else 'archive' end, 'print_edition', p_id::text,
        jsonb_build_object('status', v_old.status), jsonb_build_object('status', v_row.status, 'edition_date', v_row.edition_date, 'issue_no', v_row.issue_no));
    end if;
  end if;
  return v_row;
end;
$$;

create function nomad_news.add_live_update(p_article_id uuid, p_body text, p_is_pinned boolean default false)
returns nomad_news.live_updates
language plpgsql
security definer
set search_path = ''
as $$
declare v_a nomad_news.articles; v_row nomad_news.live_updates;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.articles x where x.id = p_article_id), array['publisher', 'editor', 'desk', 'reporter'], 'add_live_update');
  select * into v_a from nomad_news.articles where id = p_article_id;
  if not found then
    raise exception 'add_live_update: not found' using errcode = 'P0002';
  end if;
  if not v_a.is_live or v_a.status = 'archived' then
    raise exception 'add_live_update: article is not a live article' using errcode = 'NW004';
  end if;
  insert into nomad_news.live_updates (organization_id, article_id, body, is_pinned, posted_by)
  values (v_a.organization_id, p_article_id, p_body, coalesce(p_is_pinned, false), auth.uid()) returning * into v_row;
  return v_row;
end;
$$;

create function nomad_news.set_live_update_status(p_id uuid, p_status text, p_is_pinned boolean default null)
returns nomad_news.live_updates
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.live_updates; v_role text;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  v_role := nomad_news.assert_staff_row((select x.organization_id from nomad_news.live_updates x where x.id = p_id), array['publisher', 'editor', 'desk', 'reporter'], 'set_live_update_status', true);
  select * into v_row from nomad_news.live_updates where id = p_id for update;
  if not found then
    raise exception 'set_live_update_status: not found' using errcode = 'P0002';
  end if;
  if v_role = 'reporter' and v_row.posted_by is distinct from auth.uid() then
    raise exception 'set_live_update_status: only your own updates' using errcode = '42501';
  end if;
  -- W2: 기자는 숨김 방향만(다시 보이기·고정은 데스크 이상). 구독 끊김 중 다시 보이기는 새 게시라 잠금(숨김은 열림)
  if v_role = 'reporter' and (p_status is distinct from 'hidden' or p_is_pinned is not null) then
    raise exception 'set_live_update_status: reporters can only hide updates' using errcode = '42501';
  end if;
  if p_status = 'visible' and v_row.status <> 'visible' and not nomad_news.plan_active(v_row.organization_id) then
    raise exception 'set_live_update_status: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  update nomad_news.live_updates set status = coalesce(p_status, status), is_pinned = coalesce(p_is_pinned, is_pinned)
   where id = p_id returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.7 독자(M2): 가입·탈퇴·차단, 멤버십·후원(서버 기록), 페이월, 기사 읽기
-- ---------------------------------------------------------------------
-- 독자 가입(NW-F-006): 그 신문사의 readers 행을 만들거나 갱신한다. 조직 멤버십은 만들지 않는다.
create function nomad_news.ensure_reader(
  p_org              uuid,
  p_nickname         text,
  p_terms_version    text,
  p_privacy_version  text,
  p_is_over_14       boolean,
  p_marketing_opt_in boolean default false
)
returns nomad_news.readers
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid(); v_row nomad_news.readers; v_email text;
begin
  if v_uid is null then
    raise exception 'ensure_reader: login required' using errcode = '42501';
  end if;
  if not nomad_news.is_public_newspaper(p_org) then
    raise exception 'ensure_reader: newspaper is not public' using errcode = 'NW002';
  end if;
  if not coalesce(p_is_over_14, false) then
    raise exception 'ensure_reader: readers under 14 are not supported' using errcode = 'NW015';
  end if;
  -- 호출자 자신의 이메일만 읽는다(auth.users 는 노출하지 않는다)
  select u.email into v_email from auth.users u where u.id = v_uid;
  select * into v_row from nomad_news.readers where organization_id = p_org and user_id = v_uid for update;
  -- N1: 새 가입·탈퇴 후 재가입은 구독 끊김이면 잠금(기존 독자의 동의 갱신은 허용)
  if (v_row.id is null or v_row.status = 'withdrawn') and not nomad_news.plan_active(p_org) then
    raise exception 'ensure_reader: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  if v_row.id is null then
    insert into nomad_news.readers (organization_id, user_id, nickname, email, is_over_14, terms_version, privacy_version, marketing_opt_in, marketing_opt_in_at)
    values (p_org, v_uid, btrim(p_nickname), v_email, true, p_terms_version, p_privacy_version, coalesce(p_marketing_opt_in, false),
            case when coalesce(p_marketing_opt_in, false) then now() end)
    returning * into v_row;
  elsif v_row.status = 'blocked' then
    raise exception 'ensure_reader: reader is blocked' using errcode = 'NW008';
  else
    update nomad_news.readers set
      status = 'active',
      nickname = coalesce(nullif(btrim(p_nickname), ''), nickname),
      email = coalesce(email, v_email),
      terms_version = coalesce(p_terms_version, terms_version),
      privacy_version = coalesce(p_privacy_version, privacy_version),
      consent_at = case when p_terms_version is distinct from terms_version or p_privacy_version is distinct from privacy_version then now() else consent_at end,
      marketing_opt_in = coalesce(p_marketing_opt_in, marketing_opt_in),
      last_seen_at = now()
    where id = v_row.id returning * into v_row;
  end if;
  return v_row;
end;
$$;

create function nomad_news.withdraw_reader(p_org uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.readers;
begin
  select * into v_row from nomad_news.readers where organization_id = p_org and user_id = auth.uid() and status <> 'withdrawn' for update;
  if not found then
    raise exception 'withdraw_reader: reader not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from nomad_news.memberships m where m.reader_id = v_row.id and m.status in ('pending', 'active', 'past_due')) then
    raise exception 'withdraw_reader: cancel the membership first' using errcode = 'NW004';
  end if;
  update nomad_news.newsletter_subscriptions set status = 'unsubscribed', unsubscribe_reason = 'reader_withdrawn'
   where reader_id = v_row.id and status in ('pending', 'confirmed');
  update nomad_news.readers set status = 'withdrawn' where id = v_row.id;
end;
$$;

create function nomad_news.set_reader_status(p_reader_id uuid, p_status text, p_reason text default null)
returns nomad_news.readers
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.readers; v_old text;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.readers x where x.id = p_reader_id), array['publisher', 'editor'], 'set_reader_status', true);
  select * into v_row from nomad_news.readers where id = p_reader_id for update;
  if not found then
    raise exception 'set_reader_status: not found' using errcode = 'P0002';
  end if;
  if p_status not in ('active', 'blocked') then
    raise exception 'set_reader_status: invalid status %', p_status using errcode = 'NW015';
  end if;
  v_old := v_row.status;
  update nomad_news.readers set status = p_status, blocked_reason = case when p_status = 'blocked' then p_reason end
   where id = p_reader_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'reader.status', 'reader', p_reader_id::text,
                           jsonb_build_object('status', v_old), jsonb_build_object('status', p_status));
  return v_row;
end;
$$;

create function nomad_news.upsert_membership_tier(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.membership_tiers
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.membership_tiers; r nomad_news.membership_tiers;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'upsert_membership_tier');
  perform nomad_news.assert_keys(p_fields, array['code', 'name', 'description', 'price_krw', 'billing_interval', 'benefits', 'is_active', 'sort_order'], 'upsert_membership_tier');
  r := jsonb_populate_record(null::nomad_news.membership_tiers, p_fields);
  if p_id is null then
    insert into nomad_news.membership_tiers (organization_id, code, name, description, price_krw, billing_interval, benefits, is_active, sort_order)
    values (p_org, r.code, r.name, r.description, r.price_krw, coalesce(r.billing_interval, 'month'), coalesce(r.benefits, '[]'::jsonb),
            coalesce(r.is_active, true), coalesce(r.sort_order, 0))
    returning * into v_row;
  else
    if p_fields ? 'price_krw' or p_fields ? 'billing_interval' or p_fields ? 'code' then
      raise exception 'upsert_membership_tier: price/interval/code are fixed; create a new tier' using errcode = '22023';
    end if;
    update nomad_news.membership_tiers set
      name = case when p_fields ? 'name' then r.name else name end,
      description = case when p_fields ? 'description' then r.description else description end,
      benefits = case when p_fields ? 'benefits' then coalesce(r.benefits, '[]'::jsonb) else benefits end,
      is_active = case when p_fields ? 'is_active' then coalesce(r.is_active, true) else is_active end,
      sort_order = case when p_fields ? 'sort_order' then coalesce(r.sort_order, 0) else sort_order end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'upsert_membership_tier: not found' using errcode = 'P0002';
    end if;
  end if;
  perform nomad_core.write_audit(p_org, 'membership_tier.save', 'membership_tier', v_row.id::text, null,
                           jsonb_build_object('code', v_row.code, 'price_krw', v_row.price_krw, 'is_active', v_row.is_active));
  return v_row;
end;
$$;

-- 멤버십 기록(service_role: 결제 승인 Route Handler, Toss 웹훅). 결제 금액 검증은 서버가 신문사 가맹 주문 기준으로 한다(04_API).
create function nomad_news.record_membership(
  p_org                    uuid,
  p_reader_id              uuid,
  p_tier_id                uuid,
  p_status                 text,
  p_period_start           timestamptz default null,
  p_period_end             timestamptz default null,
  p_external_ref           text default null,
  p_event_id               text default null,
  p_billing_credential_id  uuid default null
)
returns nomad_news.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.memberships; v_fee integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_membership: service_role only' using errcode = '42501';
  end if;
  -- 결제 반영에는 멱등 키 필수(AGENTS 4장). 인자 순서는 원본 계약 유지를 위해 default 를 남기고 여기서 거부한다
  if p_event_id is null or p_event_id = '' then
    raise exception 'record_membership: p_event_id is required' using errcode = 'NW015';
  end if;
  -- 멱등(S6): 이미 처리한 이벤트면 그 멤버십을 그대로 돌려준다. 같은 이벤트의 동시 요청은 트랜잭션 advisory 잠금으로 줄 세운다
  if p_event_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('news:membership_event:' || p_org::text || ':' || p_event_id, 0));
    select m.* into v_row from nomad_news.membership_events e join nomad_news.memberships m on m.id = e.membership_id
     where e.organization_id = p_org and e.event_id = p_event_id;
    if found then
      return v_row;
    end if;
  end if;
  if p_billing_credential_id is not null and not exists (
       select 1 from nomad_core.provider_credentials c where c.id = p_billing_credential_id and c.organization_id = p_org
         and c.provider_code = 'toss_merchant' and c.revoked_at is null) then
    raise exception 'record_membership: credential must be an active toss_merchant key of the newspaper' using errcode = '23503';
  end if;
  v_fee := nomad_news.limit_int(p_org, 'news_reader_fee_bps');
  select * into v_row from nomad_news.memberships
   where organization_id = p_org and reader_id = p_reader_id and status in ('pending', 'active', 'past_due') for update;
  -- N1 새 결제 잠금: 새 멤버십·(재)활성화·기간 연장은 구독 끊김이면 NW014. 해지·만료·연체 기록은 허용
  if not nomad_news.plan_active(p_org) and (
       v_row.id is null
       or (coalesce(p_status, v_row.status) = 'active' and v_row.status <> 'active')
       or (p_period_end is not null and p_period_end > coalesce(v_row.current_period_end, '-infinity'::timestamptz))) then
    raise exception 'record_membership: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  if v_row.id is null then
    insert into nomad_news.memberships (organization_id, reader_id, tier_id, status, platform_fee_bps)
    values (p_org, p_reader_id, p_tier_id, 'pending', v_fee) returning * into v_row;
  end if;
  update nomad_news.memberships set
    status = coalesce(p_status, status),
    tier_id = coalesce(p_tier_id, tier_id),
    current_period_start = coalesce(p_period_start, current_period_start),
    current_period_end = coalesce(p_period_end, current_period_end),
    external_ref = coalesce(p_external_ref, external_ref),
    billing_credential_id = coalesce(p_billing_credential_id, billing_credential_id),
    platform_fee_bps = case when coalesce(p_status, status) = 'active' and status <> 'active' then v_fee else platform_fee_bps end,
    last_event_id = coalesce(p_event_id, last_event_id)
  where id = v_row.id returning * into v_row;
  if p_event_id is not null then
    insert into nomad_news.membership_events (organization_id, event_id, membership_id) values (p_org, p_event_id, v_row.id);
  end if;
  perform nomad_core.write_audit(p_org, 'membership.record', 'membership', v_row.id::text, null,
                           jsonb_build_object('status', v_row.status, 'tier_id', v_row.tier_id, 'event_id', p_event_id));
  return v_row;
end;
$$;

-- 후원 기록(service_role). order_id 가 멱등 키. 금액은 처음 기록한 값과 같아야 한다.
create function nomad_news.record_donation(p_org uuid, p_order_id text, p_status text, p_amount_krw integer, p_fields jsonb default '{}'::jsonb)
returns nomad_news.donations
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.donations; v_fee integer; v_reader uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_donation: service_role only' using errcode = '42501';
  end if;
  perform nomad_news.assert_keys(coalesce(p_fields, '{}'::jsonb), array['reader_user_id', 'donor_display_name', 'is_anonymous', 'message', 'kind',
                                                                  'payment_key', 'refunded_amount_krw'], 'record_donation');
  select * into v_row from nomad_news.donations where order_id = p_order_id for update;
  if not found then
    if p_fields ? 'reader_user_id' then
      select r.id into v_reader from nomad_news.readers r where r.organization_id = p_org and r.user_id = (p_fields ->> 'reader_user_id')::uuid;
    end if;
    -- N1 새 결제 잠금: 새 후원 주문은 구독 끊김이면 NW014(이미 접수된 주문의 결제·환불 기록은 허용)
    if not nomad_news.plan_active(p_org) then
      raise exception 'record_donation: newspaper subscription inactive' using errcode = 'NW014';
    end if;
    v_fee := nomad_news.limit_int(p_org, 'news_reader_fee_bps');
    insert into nomad_news.donations (organization_id, reader_id, donor_display_name, is_anonymous, message, amount_krw, kind, order_id, platform_fee_bps)
    values (p_org, v_reader, p_fields ->> 'donor_display_name', coalesce((p_fields ->> 'is_anonymous')::boolean, true),
            p_fields ->> 'message', p_amount_krw, coalesce(p_fields ->> 'kind', 'once'), p_order_id, v_fee)
    returning * into v_row;
  elsif v_row.organization_id <> p_org or v_row.amount_krw <> p_amount_krw then
    raise exception 'record_donation: order does not match' using errcode = 'NW015';
  end if;
  update nomad_news.donations set
    status = coalesce(p_status, status),
    payment_key = coalesce(p_fields ->> 'payment_key', payment_key),
    refunded_amount_krw = coalesce((p_fields ->> 'refunded_amount_krw')::integer, refunded_amount_krw),
    platform_fee_krw = case when coalesce(p_status, status) = 'paid' then (amount_krw::bigint * platform_fee_bps / 10000)::integer else platform_fee_krw end
  where id = v_row.id returning * into v_row;
  return v_row;
end;
$$;

create function nomad_news.set_paywall_rule(p_org uuid, p_fields jsonb)
returns nomad_news.paywall_rules
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.paywall_rules; r nomad_news.paywall_rules;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'set_paywall_rule');
  perform nomad_news.assert_keys(p_fields, array['mode', 'free_articles_per_month', 'exempt_types', 'cta_text'], 'set_paywall_rule');
  r := jsonb_populate_record(null::nomad_news.paywall_rules, p_fields);
  insert into nomad_news.paywall_rules (organization_id, mode, free_articles_per_month, exempt_types, cta_text, updated_by)
  values (p_org, coalesce(r.mode, 'off'), coalesce(r.free_articles_per_month, 10), coalesce(r.exempt_types, '{press_release}'), r.cta_text, auth.uid())
  on conflict (organization_id) do update set
    mode = case when p_fields ? 'mode' then excluded.mode else nomad_news.paywall_rules.mode end,
    free_articles_per_month = case when p_fields ? 'free_articles_per_month' then excluded.free_articles_per_month else nomad_news.paywall_rules.free_articles_per_month end,
    exempt_types = case when p_fields ? 'exempt_types' then excluded.exempt_types else nomad_news.paywall_rules.exempt_types end,
    cta_text = case when p_fields ? 'cta_text' then excluded.cta_text else nomad_news.paywall_rules.cta_text end,
    updated_by = excluded.updated_by
  returning * into v_row;
  perform nomad_core.write_audit(p_org, 'paywall.save', 'paywall_rule', v_row.id::text, null, jsonb_build_object('mode', v_row.mode));
  return v_row;
end;
$$;

-- 기사 읽기(공개): 공개 조건을 만족한 기사만. 프리미엄 기사의 본문은 유효 멤버(또는 그 신문사 편집국)에게만 준다.
-- 미터형 페이월(월 N건)은 서버 쿠키 카운트로 보조한다(DB 강제 아님, 05장 7절 한계).
create function nomad_news.read_article(p_org uuid, p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_a nomad_news.articles; v_reader uuid; v_member boolean := false; v_locked boolean;
begin
  select * into v_a from nomad_news.articles where organization_id = p_org and slug = p_slug;
  if not found or not nomad_news.article_is_live(v_a.organization_id, v_a.status, v_a.published_at, v_a.embargo_until, v_a.type, v_a.wire_contract_id) then
    return null;
  end if;
  if v_a.is_premium then
    v_reader := nomad_news.current_reader_id(p_org);
    v_member := (v_reader is not null and exists (
                   select 1 from nomad_news.memberships m where m.reader_id = v_reader
                     and (m.status in ('active', 'past_due') or (m.status = 'canceled' and m.current_period_end > now()))))
                or nomad_news.has_staff_role(p_org, array['publisher', 'editor', 'desk', 'reporter', 'contributor', 'ad_manager']);
  end if;
  v_locked := v_a.is_premium and not v_member;
  return jsonb_build_object(
    'id', v_a.id, 'slug', v_a.slug, 'title', v_a.title, 'subtitle', v_a.subtitle, 'summary', v_a.summary,
    'type', v_a.type, 'byline', v_a.byline, 'section_id', v_a.section_id,
    'sponsor_label', v_a.sponsor_label, 'ai_assisted', v_a.ai_assisted, 'ai_disclosure', v_a.ai_disclosure,
    'source_note', v_a.source_note, 'is_poll', v_a.is_poll, 'poll_disclosure', v_a.poll_disclosure,
    'is_premium', v_a.is_premium, 'locked', v_locked,
    'body', case when v_locked then null else v_a.body end,
    'published_at', v_a.published_at, 'revised_at', v_a.revised_at, 'revision_note', v_a.revision_note,
    'comments_enabled', v_a.comments_enabled and coalesce((select n.comments_enabled from nomad_news.newspapers n where n.organization_id = p_org), false),
    'hero', (select jsonb_build_object('path', m.storage_path, 'bucket', m.bucket, 'alt', m.alt_text, 'caption', m.caption,
                                       'credit', m.credit, 'ai_generated', m.ai_generated, 'ai_disclosure', m.ai_disclosure)
             from nomad_news.media_assets m where m.id = v_a.hero_media_id and m.organization_id = p_org and m.status = 'active'),
    'wire_attribution', (select w.attribution_text from nomad_news.wire_contracts w where w.id = v_a.wire_contract_id),
    'corrections', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'note', r.note, 'at', r.created_at) order by r.created_at)
                             from nomad_news.article_revisions r where r.article_id = v_a.id and r.is_public), '[]'::jsonb),
    'regions', coalesce((select jsonb_agg(jsonb_build_object('slug', g.slug, 'name', g.name))
                         from nomad_news.article_regions ar join nomad_news.regions g on g.id = ar.region_id where ar.article_id = v_a.id), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name))
                      from nomad_news.article_tags at join nomad_news.tags t on t.id = at.tag_id where at.article_id = v_a.id), '[]'::jsonb),
    'media', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'path', m.storage_path, 'bucket', m.bucket, 'kind', m.kind, 'mime', m.mime,
                                                           'width', m.width, 'height', m.height, 'alt', m.alt_text, 'caption', m.caption,
                                                           'credit', m.credit, 'ai_generated', m.ai_generated, 'ai_disclosure', m.ai_disclosure))
                       from nomad_news.media_assets m where m.organization_id = p_org and m.id = any (v_a.media_ids) and m.status = 'active'
                         and not v_locked), '[]'::jsonb),
    'live_updates', case when v_a.is_live and not v_locked then coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'body', l.body, 'is_pinned', l.is_pinned,
                                                                                             'posted_at', l.posted_at) order by l.is_pinned desc, l.posted_at desc)
                                                         from nomad_news.live_updates l where l.article_id = v_a.id and l.status = 'visible'), '[]'::jsonb)
                    else '[]'::jsonb end);
end;
$$;

-- ---------------------------------------------------------------------
-- 11.8 광고(M3)
-- ---------------------------------------------------------------------
create function nomad_news.upsert_ad_slot(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.ad_slots
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.ad_slots; r nomad_news.ad_slots;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'ad_manager'], 'upsert_ad_slot');
  perform nomad_news.assert_keys(p_fields, array['code', 'name', 'placement', 'width', 'height', 'is_active', 'sort_order'], 'upsert_ad_slot');
  r := jsonb_populate_record(null::nomad_news.ad_slots, p_fields);
  if p_id is null then
    insert into nomad_news.ad_slots (organization_id, code, name, placement, width, height, is_active, sort_order)
    values (p_org, r.code, r.name, r.placement, r.width, r.height, coalesce(r.is_active, true), coalesce(r.sort_order, 0)) returning * into v_row;
  else
    update nomad_news.ad_slots set
      code = case when p_fields ? 'code' then r.code else code end, name = case when p_fields ? 'name' then r.name else name end,
      placement = case when p_fields ? 'placement' then r.placement else placement end,
      width = case when p_fields ? 'width' then r.width else width end, height = case when p_fields ? 'height' then r.height else height end,
      is_active = case when p_fields ? 'is_active' then coalesce(r.is_active, true) else is_active end,
      sort_order = case when p_fields ? 'sort_order' then coalesce(r.sort_order, 0) else sort_order end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'upsert_ad_slot: not found' using errcode = 'P0002';
    end if;
  end if;
  return v_row;
end;
$$;

create function nomad_news.upsert_advertiser(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.advertisers
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.advertisers; r nomad_news.advertisers;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'ad_manager'], 'upsert_advertiser');
  perform nomad_news.assert_keys(p_fields, array['name', 'kind', 'is_government', 'business_no', 'contact_name', 'contact_email', 'contact_phone', 'note', 'status'], 'upsert_advertiser');
  r := jsonb_populate_record(null::nomad_news.advertisers, p_fields);
  if p_id is null then
    insert into nomad_news.advertisers (organization_id, name, kind, is_government, business_no, contact_name, contact_email, contact_phone, note, created_by)
    values (p_org, r.name, coalesce(r.kind, 'local_business'), coalesce(r.is_government, false), r.business_no, r.contact_name,
            r.contact_email, r.contact_phone, r.note, auth.uid()) returning * into v_row;
  else
    -- W9: 진행 중 유료 캠페인이 있는 광고주를 정부·지자체로 바꾸면 직판 금지(NW013)를 우회하게 된다
    if p_fields ? 'is_government' and coalesce(r.is_government, false)
       and exists (select 1 from nomad_news.ad_campaigns k where k.advertiser_id = p_id and k.organization_id = p_org
                     and k.status = 'active' and k.price_krw > 0) then
      raise exception 'upsert_advertiser: advertiser has active paid campaigns' using errcode = 'NW013';
    end if;
    update nomad_news.advertisers set
      name = case when p_fields ? 'name' then r.name else name end, kind = case when p_fields ? 'kind' then r.kind else kind end,
      is_government = case when p_fields ? 'is_government' then coalesce(r.is_government, false) else is_government end,
      business_no = case when p_fields ? 'business_no' then r.business_no else business_no end,
      contact_name = case when p_fields ? 'contact_name' then r.contact_name else contact_name end,
      contact_email = case when p_fields ? 'contact_email' then r.contact_email else contact_email end,
      contact_phone = case when p_fields ? 'contact_phone' then r.contact_phone else contact_phone end,
      note = case when p_fields ? 'note' then r.note else note end,
      status = case when p_fields ? 'status' then r.status else status end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'upsert_advertiser: not found' using errcode = 'P0002';
    end if;
  end if;
  return v_row;
end;
$$;

-- 캠페인 저장. 정부·지자체 광고주는 직판 금액을 잡을 수 없다(정부광고법, NW013).
create function nomad_news.save_ad_campaign(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.ad_campaigns
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.ad_campaigns; r nomad_news.ad_campaigns; v_gov boolean;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'ad_manager'], 'save_ad_campaign');
  perform nomad_news.assert_keys(p_fields, array['advertiser_id', 'name', 'pricing', 'price_krw', 'starts_at', 'ends_at', 'priority', 'status'], 'save_ad_campaign');
  r := jsonb_populate_record(null::nomad_news.ad_campaigns, p_fields);
  if p_id is null then
    insert into nomad_news.ad_campaigns (organization_id, advertiser_id, name, pricing, price_krw, starts_at, ends_at, priority, created_by)
    values (p_org, r.advertiser_id, r.name, coalesce(r.pricing, 'flat'), coalesce(r.price_krw, 0), r.starts_at, r.ends_at, coalesce(r.priority, 5), auth.uid())
    returning * into v_row;
    if p_fields ? 'status' and r.status <> 'draft' then
      update nomad_news.ad_campaigns set status = r.status where id = v_row.id returning * into v_row;
    end if;
  else
    update nomad_news.ad_campaigns set
      advertiser_id = case when p_fields ? 'advertiser_id' then r.advertiser_id else advertiser_id end,
      name = case when p_fields ? 'name' then r.name else name end,
      pricing = case when p_fields ? 'pricing' then r.pricing else pricing end,
      price_krw = case when p_fields ? 'price_krw' then coalesce(r.price_krw, 0) else price_krw end,
      starts_at = case when p_fields ? 'starts_at' then r.starts_at else starts_at end,
      ends_at = case when p_fields ? 'ends_at' then r.ends_at else ends_at end,
      priority = case when p_fields ? 'priority' then coalesce(r.priority, 5) else priority end,
      status = case when p_fields ? 'status' then r.status else status end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'save_ad_campaign: not found' using errcode = 'P0002';
    end if;
  end if;
  select a.is_government into v_gov from nomad_news.advertisers a where a.id = v_row.advertiser_id;
  if coalesce(v_gov, false) and v_row.price_krw > 0 then
    raise exception 'save_ad_campaign: government advertising must go through the press foundation' using errcode = 'NW013';
  end if;
  perform nomad_core.write_audit(p_org, 'ad_campaign.save', 'ad_campaign', v_row.id::text, null,
                           jsonb_build_object('status', v_row.status, 'price_krw', v_row.price_krw));
  return v_row;
end;
$$;

-- 소재 저장: 내용을 바꾸면 다시 검토 대기(pending_review)
create function nomad_news.save_ad_creative(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.ad_creatives
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.ad_creatives; r nomad_news.ad_creatives;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'ad_manager'], 'save_ad_creative');
  perform nomad_news.assert_keys(p_fields, array['campaign_id', 'slot_id', 'kind', 'media_path', 'external_network', 'external_unit_id',
                                           'headline', 'click_url', 'alt_text', 'label'], 'save_ad_creative');
  r := jsonb_populate_record(null::nomad_news.ad_creatives, p_fields);
  if p_id is null then
    insert into nomad_news.ad_creatives (organization_id, campaign_id, slot_id, kind, media_path, external_network, external_unit_id, headline,
                                   click_url, alt_text, label, created_by)
    values (p_org, r.campaign_id, r.slot_id, r.kind, r.media_path, r.external_network, r.external_unit_id, r.headline,
            r.click_url, r.alt_text, coalesce(r.label, '광고'), auth.uid())
    returning * into v_row;
  else
    update nomad_news.ad_creatives set
      slot_id = case when p_fields ? 'slot_id' then r.slot_id else slot_id end,
      kind = case when p_fields ? 'kind' then r.kind else kind end,
      media_path = case when p_fields ? 'media_path' then r.media_path else media_path end,
      external_network = case when p_fields ? 'external_network' then r.external_network else external_network end,
      external_unit_id = case when p_fields ? 'external_unit_id' then r.external_unit_id else external_unit_id end,
      headline = case when p_fields ? 'headline' then r.headline else headline end,
      click_url = case when p_fields ? 'click_url' then r.click_url else click_url end,
      alt_text = case when p_fields ? 'alt_text' then r.alt_text else alt_text end,
      label = case when p_fields ? 'label' then r.label else label end,
      status = case when status = 'approved' then 'pending_review' else status end,
      reviewed_by = null, reviewed_at = null
    where id = p_id and organization_id = p_org and status <> 'archived' returning * into v_row;
    if not found then
      raise exception 'save_ad_creative: not found' using errcode = 'P0002';
    end if;
  end if;
  return v_row;
end;
$$;

create function nomad_news.review_ad_creative(p_id uuid, p_decision text)
returns nomad_news.ad_creatives
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.ad_creatives;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.ad_creatives x where x.id = p_id), array['publisher', 'editor'], 'review_ad_creative');
  select * into v_row from nomad_news.ad_creatives where id = p_id for update;
  if not found then
    raise exception 'review_ad_creative: not found' using errcode = 'P0002';
  end if;
  if p_decision not in ('approve', 'reject', 'archive') then
    raise exception 'review_ad_creative: invalid decision' using errcode = 'NW015';
  end if;
  update nomad_news.ad_creatives set
    status = case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'archived' end,
    reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'ad_creative.' || p_decision, 'ad_creative', p_id::text, null, jsonb_build_object('label', v_row.label));
  return v_row;
end;
$$;

-- 광고 노출(공개). 승인 소재 + 진행 중 캠페인 + 활성 슬롯만, 라벨과 함께. 임의 HTML 은 없다.
create function nomad_news.serve_ads(p_org uuid, p_placement text)
returns table (creative_id uuid, slot_code text, width integer, height integer, kind text, media_path text, headline text,
               click_url text, alt_text text, label text, external_network text, external_unit_id text, priority smallint)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, s.code, s.width, s.height, c.kind, c.media_path, c.headline, c.click_url, c.alt_text, c.label,
         c.external_network, c.external_unit_id, k.priority
  from nomad_news.ad_creatives c
  join nomad_news.ad_campaigns k on k.id = c.campaign_id
  join nomad_news.ad_slots s on s.id = c.slot_id
  where c.organization_id = p_org and nomad_news.is_public_newspaper(p_org)
    and c.status = 'approved' and k.status = 'active' and k.starts_at <= now() and k.ends_at > now()
    and s.is_active and (s.placement = p_placement or s.placement = 'all')
  order by s.sort_order, k.priority desc, c.created_at;
$$;

create function nomad_news.record_ad_stats(p_creative_id uuid, p_day date, p_impressions bigint, p_clicks bigint)
returns nomad_news.ad_daily_stats
language plpgsql
security definer
set search_path = ''
as $$
declare v_org uuid; v_row nomad_news.ad_daily_stats;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_ad_stats: service_role only' using errcode = '42501';
  end if;
  if p_impressions not between 0 and 10000000 or p_clicks not between 0 and 10000000 or p_day > (now() at time zone 'Asia/Seoul')::date then
    raise exception 'record_ad_stats: invalid counts' using errcode = 'NW015';
  end if;
  select organization_id into v_org from nomad_news.ad_creatives where id = p_creative_id;
  if v_org is null then
    raise exception 'record_ad_stats: creative not found' using errcode = 'P0002';
  end if;
  insert into nomad_news.ad_daily_stats as s (organization_id, creative_id, day, impressions, clicks)
  values (v_org, p_creative_id, p_day, p_impressions, p_clicks)
  on conflict (creative_id, day) do update
    set impressions = s.impressions + excluded.impressions, clicks = s.clicks + excluded.clicks, updated_at = now()
  returning * into v_row;
  return v_row;
end;
$$;

-- 업소 셀프 광고 신청(독자 로그인) → 검토(ADS) → 결제 확인 후 게재(service_role)
create function nomad_news.submit_listing(p_org uuid, p_fields jsonb)
returns nomad_news.local_listings
language plpgsql
security definer
set search_path = ''
as $$
declare v_reader uuid; v_ok boolean; v_row nomad_news.local_listings; r nomad_news.local_listings;
begin
  if auth.uid() is null then
    raise exception 'submit_listing: login required' using errcode = '42501';
  end if;
  v_reader := nomad_news.current_reader_id(p_org);
  if v_reader is null then
    raise exception 'submit_listing: reader registration required' using errcode = 'NW008';
  end if;
  perform nomad_news.assert_keys(p_fields, array['business_name', 'category', 'region_id', 'address', 'phone', 'url', 'description', 'contact_email'], 'submit_listing');
  if not nomad_news.plan_active(p_org) then
    raise exception 'submit_listing: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  select x.allowed into v_ok from nomad_core.rate_limit_take('news:listing:' || v_reader::text, 5, 86400) x;
  if not v_ok then
    raise exception 'submit_listing: rate limited' using errcode = 'NW011';
  end if;
  r := jsonb_populate_record(null::nomad_news.local_listings, p_fields);
  insert into nomad_news.local_listings (organization_id, reader_id, applicant_user_id, business_name, category, region_id, address, phone, url, description, contact_email)
  values (p_org, v_reader, auth.uid(), r.business_name, r.category, r.region_id, r.address, r.phone, r.url, r.description, r.contact_email)
  returning * into v_row;
  return v_row;
end;
$$;

create function nomad_news.review_listing(p_id uuid, p_decision text, p_note text default null)
returns nomad_news.local_listings
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.local_listings;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.local_listings x where x.id = p_id), array['publisher', 'editor', 'ad_manager'], 'review_listing');
  select * into v_row from nomad_news.local_listings where id = p_id for update;
  if not found then
    raise exception 'review_listing: not found' using errcode = 'P0002';
  end if;
  if p_decision not in ('approve', 'reject', 'cancel', 'expire') then
    raise exception 'review_listing: invalid decision' using errcode = 'NW015';
  end if;
  update nomad_news.local_listings set
    status = case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' when 'expire' then 'expired' else 'canceled' end,
    reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note
  where id = p_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'listing.' || p_decision, 'local_listing', p_id::text, null,
                           jsonb_build_object('status', v_row.status, 'note', p_note));
  return v_row;
end;
$$;

create function nomad_news.activate_listing(p_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_payment_order_id text default null)
returns nomad_news.local_listings
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.local_listings;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'activate_listing: service_role only' using errcode = '42501';
  end if;
  if not nomad_news.plan_active((select l.organization_id from nomad_news.local_listings l where l.id = p_id)) then
    raise exception 'activate_listing: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  update nomad_news.local_listings set status = 'active', starts_at = p_starts_at, ends_at = p_ends_at,
         payment_order_id = p_payment_order_id, paid_at = case when p_payment_order_id is not null then now() end
   where id = p_id returning * into v_row;
  if not found then
    raise exception 'activate_listing: not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

create function nomad_news.save_public_notice(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.public_notices
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.public_notices; r nomad_news.public_notices;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk', 'ad_manager'], 'save_public_notice');
  perform nomad_news.assert_keys(p_fields, array['issuer_name', 'notice_no', 'title', 'body', 'region_id', 'attachment_path',
                                           'government_ad_ref', 'posted_from', 'posted_until', 'status'], 'save_public_notice');
  r := jsonb_populate_record(null::nomad_news.public_notices, p_fields);
  if p_id is null then
    insert into nomad_news.public_notices (organization_id, issuer_name, notice_no, title, body, region_id, attachment_path, government_ad_ref,
                                     posted_from, posted_until, created_by)
    values (p_org, r.issuer_name, r.notice_no, r.title, r.body, r.region_id, r.attachment_path, r.government_ad_ref,
            r.posted_from, r.posted_until, auth.uid())
    returning * into v_row;
  end if;
  update nomad_news.public_notices set
    issuer_name = case when p_fields ? 'issuer_name' then r.issuer_name else issuer_name end,
    notice_no = case when p_fields ? 'notice_no' then r.notice_no else notice_no end,
    title = case when p_fields ? 'title' then r.title else title end,
    body = case when p_fields ? 'body' then r.body else body end,
    region_id = case when p_fields ? 'region_id' then r.region_id else region_id end,
    attachment_path = case when p_fields ? 'attachment_path' then r.attachment_path else attachment_path end,
    government_ad_ref = case when p_fields ? 'government_ad_ref' then r.government_ad_ref else government_ad_ref end,
    posted_from = case when p_fields ? 'posted_from' then r.posted_from else posted_from end,
    posted_until = case when p_fields ? 'posted_until' then r.posted_until else posted_until end,
    status = case when p_fields ? 'status' then r.status else status end
  where id = coalesce(p_id, v_row.id) and organization_id = p_org returning * into v_row;
  if not found then
    raise exception 'save_public_notice: not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.9 뉴스레터·푸시(M4)
-- ---------------------------------------------------------------------
create function nomad_news.upsert_newsletter_list(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.newsletter_lists
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newsletter_lists; r nomad_news.newsletter_lists;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'upsert_newsletter_list');
  perform nomad_news.assert_keys(p_fields, array['slug', 'name', 'description', 'kind', 'is_public', 'contains_ads', 'consent_version', 'status'], 'upsert_newsletter_list');
  r := jsonb_populate_record(null::nomad_news.newsletter_lists, p_fields);
  if p_id is null then
    insert into nomad_news.newsletter_lists (organization_id, slug, name, description, kind, is_public, contains_ads, consent_version)
    values (p_org, r.slug, r.name, r.description, coalesce(r.kind, 'custom'), coalesce(r.is_public, true), coalesce(r.contains_ads, false),
            coalesce(r.consent_version, 'v1'))
    returning * into v_row;
  else
    update nomad_news.newsletter_lists set
      slug = case when p_fields ? 'slug' then r.slug else slug end, name = case when p_fields ? 'name' then r.name else name end,
      description = case when p_fields ? 'description' then r.description else description end,
      kind = case when p_fields ? 'kind' then r.kind else kind end,
      is_public = case when p_fields ? 'is_public' then coalesce(r.is_public, true) else is_public end,
      contains_ads = case when p_fields ? 'contains_ads' then coalesce(r.contains_ads, false) else contains_ads end,
      consent_version = case when p_fields ? 'consent_version' then r.consent_version else consent_version end,
      status = case when p_fields ? 'status' then r.status else status end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'upsert_newsletter_list: not found' using errcode = 'P0002';
    end if;
  end if;
  return v_row;
end;
$$;

-- 구독 신청(service_role: 확인 메일을 보내야 하므로 Route Handler 만). 토큰 원문은 반환값으로 한 번만 나가고 DB 에는 해시만 남는다.
-- 응답 문구는 상태와 무관하게 같게 만든다(구독 여부 열거 방지, 04_API).
create function nomad_news.subscribe_newsletter(
  p_org             uuid,
  p_list_slug       text,
  p_email           text,
  p_consent_version text,
  p_ad_consent      boolean default false,
  p_night_consent   boolean default false,
  p_reader_user_id  uuid default null,
  p_source_path     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_list    nomad_news.newsletter_lists;
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_hash    text;
  v_ok      boolean;
  v_row     nomad_news.newsletter_subscriptions;
  v_confirm text := encode(extensions.gen_random_bytes(32), 'hex');
  v_unsub   text := encode(extensions.gen_random_bytes(32), 'hex');
  v_reader  uuid;
  v_send    boolean := false;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'subscribe_newsletter: service_role only' using errcode = '42501';
  end if;
  if not nomad_news.is_public_newspaper(p_org) then
    raise exception 'subscribe_newsletter: newspaper is not public' using errcode = 'NW002';
  end if;
  if not nomad_news.plan_active(p_org) then
    raise exception 'subscribe_newsletter: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  select * into v_list from nomad_news.newsletter_lists where organization_id = p_org and slug = p_list_slug and status = 'active';
  if not found then
    raise exception 'subscribe_newsletter: list not found' using errcode = 'P0002';
  end if;
  if char_length(v_email) > 254 or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'subscribe_newsletter: invalid email' using errcode = 'NW015';
  end if;
  if p_consent_version is distinct from v_list.consent_version then
    raise exception 'subscribe_newsletter: consent missing or outdated' using errcode = 'NW015';
  end if;
  if v_list.contains_ads and not coalesce(p_ad_consent, false) then
    raise exception 'subscribe_newsletter: advertising consent required for this list' using errcode = 'NW015';
  end if;
  v_hash := nomad_news.token_hash(v_email);
  select x.allowed into v_ok from nomad_core.rate_limit_take('news:nl:org:' || p_org::text, 300, 3600) x;
  if v_ok then
    select x.allowed into v_ok from nomad_core.rate_limit_take('news:nl:email:' || p_org::text || ':' || v_hash, 3, 3600) x;
  end if;
  if not v_ok then
    raise exception 'subscribe_newsletter: rate limited' using errcode = 'NW011';
  end if;
  if p_reader_user_id is not null then
    select r.id into v_reader from nomad_news.readers r where r.organization_id = p_org and r.user_id = p_reader_user_id and r.status = 'active';
  end if;
  select * into v_row from nomad_news.newsletter_subscriptions where list_id = v_list.id and email_hash = v_hash for update;
  if not found then
    insert into nomad_news.newsletter_subscriptions (organization_id, list_id, reader_id, email, email_hash, status, confirm_token_hash, confirm_expires_at,
      confirm_sent_count, unsubscribe_token_hash, consent_version, ad_consent, night_consent, source_path)
    values (p_org, v_list.id, v_reader, v_email, v_hash, 'pending', nomad_news.token_hash(v_confirm), now() + interval '7 days', 1,
            nomad_news.token_hash(v_unsub), p_consent_version, coalesce(p_ad_consent, false), coalesce(p_night_consent, false), p_source_path)
    returning * into v_row;
    v_send := true;
  elsif v_row.status = 'pending' then
    if v_row.confirm_sent_count < 5 then
      update nomad_news.newsletter_subscriptions set confirm_token_hash = nomad_news.token_hash(v_confirm), confirm_expires_at = now() + interval '7 days',
             confirm_sent_count = confirm_sent_count + 1, unsubscribe_token_hash = nomad_news.token_hash(v_unsub),
             consent_version = p_consent_version, consent_at = now(), ad_consent = coalesce(p_ad_consent, false),
             night_consent = coalesce(p_night_consent, false), reader_id = coalesce(v_reader, reader_id)
       where id = v_row.id returning * into v_row;
      v_send := true;
    end if;
  elsif v_row.status in ('unsubscribed', 'bounced') then
    update nomad_news.newsletter_subscriptions set status = 'pending', email = v_email, confirm_token_hash = nomad_news.token_hash(v_confirm),
           confirm_expires_at = now() + interval '7 days', confirm_sent_count = 1, unsubscribe_token_hash = nomad_news.token_hash(v_unsub),
           consent_version = p_consent_version, consent_at = now(), ad_consent = coalesce(p_ad_consent, false),
           night_consent = coalesce(p_night_consent, false), source_path = p_source_path, reader_id = coalesce(v_reader, reader_id)
     where id = v_row.id returning * into v_row;
    v_send := true;
  end if;
  return jsonb_build_object('ok', true, 'subscription_id', v_row.id, 'status', v_row.status, 'send_confirmation', v_send,
                            'confirm_token', case when v_send then v_confirm end, 'unsubscribe_token', case when v_send then v_unsub end);
end;
$$;

-- 확인(이중 동의) 또는 2년 재확인. 토큰은 링크 원문이고 DB 에는 해시만 있다. 앱은 GET 으로 이 함수를 부르지 않는다(POST 버튼).
create function nomad_news.confirm_newsletter(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newsletter_subscriptions;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'confirm_newsletter: invalid token' using errcode = 'NW012';
  end if;
  select * into v_row from nomad_news.newsletter_subscriptions where confirm_token_hash = nomad_news.token_hash(p_token) for update;
  if not found or v_row.confirm_expires_at < now() or v_row.status not in ('pending', 'confirmed') then
    raise exception 'confirm_newsletter: invalid or expired token' using errcode = 'NW012';
  end if;
  if v_row.status = 'pending' then
    update nomad_news.newsletter_subscriptions set status = 'confirmed', confirm_token_hash = null, confirm_expires_at = null
     where id = v_row.id returning * into v_row;
  else
    update nomad_news.newsletter_subscriptions set reconfirmed_at = now(), confirm_token_hash = null, confirm_expires_at = null
     where id = v_row.id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'status', v_row.status, 'reconfirm_due_at', v_row.reconfirm_due_at);
end;
$$;

create function nomad_news.unsubscribe_newsletter(p_token text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newsletter_subscriptions; v_changed boolean := false;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'unsubscribe_newsletter: invalid token' using errcode = 'NW012';
  end if;
  select * into v_row from nomad_news.newsletter_subscriptions where unsubscribe_token_hash = nomad_news.token_hash(p_token) for update;
  if not found then
    raise exception 'unsubscribe_newsletter: invalid token' using errcode = 'NW012';
  end if;
  if v_row.status in ('pending', 'confirmed') then
    update nomad_news.newsletter_subscriptions set status = 'unsubscribed', unsubscribe_reason = left(p_reason, 200) where id = v_row.id returning * into v_row;
    v_changed := true;
  end if;
  return jsonb_build_object('ok', true, 'status', v_row.status, 'changed', v_changed);
end;
$$;

-- 2년 재확인 메일용 토큰 발급(service_role). 확인된 구독에만. 원문은 반환값으로 한 번만.
create function nomad_news.issue_newsletter_reconfirm(p_subscription_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not nomad_core.is_service_caller() then
    raise exception 'issue_newsletter_reconfirm: service_role only' using errcode = '42501';
  end if;
  update nomad_news.newsletter_subscriptions set confirm_token_hash = nomad_news.token_hash(v_token), confirm_expires_at = now() + interval '30 days'
   where id = p_subscription_id and status = 'confirmed';
  if not found then
    raise exception 'issue_newsletter_reconfirm: confirmed subscription not found' using errcode = 'P0002';
  end if;
  return v_token;
end;
$$;

create function nomad_news.save_newsletter_issue(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.newsletter_issues
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newsletter_issues; r nomad_news.newsletter_issues;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk'], 'save_newsletter_issue');
  perform nomad_news.assert_keys(p_fields, array['list_id', 'subject', 'preheader', 'body', 'article_ids', 'contains_ad', 'status', 'scheduled_at'], 'save_newsletter_issue');
  r := jsonb_populate_record(null::nomad_news.newsletter_issues, p_fields);
  if p_fields ? 'status' and r.status not in ('draft', 'scheduled', 'canceled') then
    raise exception 'save_newsletter_issue: status % is set by the sender', r.status using errcode = '42501';
  end if;
  if p_fields ? 'scheduled_at' and r.scheduled_at is not null and r.scheduled_at < now() - interval '1 minute' then
    raise exception 'save_newsletter_issue: scheduled_at is in the past' using errcode = 'NW015';
  end if;
  -- W6: 실을 기사는 같은 신문사의 게시 기사만(남의 조직·미게시 기사 id 로 제목·요약을 끌어오지 못하게)
  if r.article_ids is not null and exists (select 1 from unnest(r.article_ids) x
       where not exists (select 1 from nomad_news.articles a where a.id = x and a.organization_id = p_org and a.status = 'published')) then
    raise exception 'save_newsletter_issue: articles must be published articles of the newspaper' using errcode = '23503';
  end if;
  if p_id is null then
    insert into nomad_news.newsletter_issues (organization_id, list_id, subject, preheader, body, article_ids, contains_ad, scheduled_at, created_by)
    values (p_org, r.list_id, r.subject, r.preheader, coalesce(r.body, '[]'::jsonb), coalesce(r.article_ids, '{}'), coalesce(r.contains_ad, false),
            r.scheduled_at, auth.uid())
    returning * into v_row;
  end if;
  update nomad_news.newsletter_issues set
    subject = case when p_fields ? 'subject' then r.subject else subject end,
    preheader = case when p_fields ? 'preheader' then r.preheader else preheader end,
    body = case when p_fields ? 'body' then coalesce(r.body, '[]'::jsonb) else body end,
    article_ids = case when p_fields ? 'article_ids' then coalesce(r.article_ids, '{}') else article_ids end,
    contains_ad = case when p_fields ? 'contains_ad' then coalesce(r.contains_ad, false) else contains_ad end,
    scheduled_at = case when p_fields ? 'scheduled_at' then r.scheduled_at else scheduled_at end,
    status = case when p_fields ? 'status' then r.status else status end
  where id = coalesce(p_id, v_row.id) and organization_id = p_org returning * into v_row;
  if not found then
    raise exception 'save_newsletter_issue: not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

create function nomad_news.record_newsletter_issue_status(p_id uuid, p_status text, p_counts jsonb default '{}'::jsonb)
returns nomad_news.newsletter_issues
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.newsletter_issues;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'record_newsletter_issue_status: service_role only' using errcode = '42501';
  end if;
  update nomad_news.newsletter_issues set
    status = coalesce(p_status, status),
    recipients_count = coalesce((p_counts ->> 'recipients')::integer, recipients_count),
    delivered_count = coalesce((p_counts ->> 'delivered')::integer, delivered_count),
    open_count = coalesce((p_counts ->> 'opens')::integer, open_count),
    click_count = coalesce((p_counts ->> 'clicks')::integer, click_count)
  where id = p_id returning * into v_row;
  if not found then
    raise exception 'record_newsletter_issue_status: not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

create function nomad_news.register_push_subscription(p_org uuid, p_endpoint text, p_p256dh text, p_auth text,
                                                           p_topics text[] default '{breaking}', p_reader_user_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid; v_reader uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'register_push_subscription: service_role only' using errcode = '42501';
  end if;
  if not nomad_news.plan_active(p_org) then
    raise exception 'register_push_subscription: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  if p_reader_user_id is not null then
    select r.id into v_reader from nomad_news.readers r where r.organization_id = p_org and r.user_id = p_reader_user_id and r.status = 'active';
  end if;
  insert into nomad_news.push_subscriptions as s (organization_id, reader_id, endpoint, endpoint_hash, p256dh, auth_secret, topics)
  values (p_org, v_reader, p_endpoint, nomad_news.token_hash(p_endpoint), p_p256dh, p_auth, coalesce(p_topics, '{breaking}'))
  on conflict (organization_id, endpoint_hash) do update
    set p256dh = excluded.p256dh, auth_secret = excluded.auth_secret, topics = excluded.topics, status = 'active',
        failure_count = 0, reader_id = coalesce(excluded.reader_id, s.reader_id)
  returning id into v_id;
  return v_id;
end;
$$;

create function nomad_news.revoke_push_subscription(p_org uuid, p_endpoint text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'revoke_push_subscription: service_role only' using errcode = '42501';
  end if;
  update nomad_news.push_subscriptions set status = 'revoked' where organization_id = p_org and endpoint_hash = nomad_news.token_hash(p_endpoint);
  return found;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.10 커뮤니티(M5): 댓글·신고·임시조치, 제보·투고, 경조사
-- ---------------------------------------------------------------------
create function nomad_news.post_comment(p_article_id uuid, p_body text, p_parent_id uuid default null)
returns nomad_news.comments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a      nomad_news.articles;
  v_np     nomad_news.newspapers;
  v_reader nomad_news.readers;
  v_ok     boolean;
  v_row    nomad_news.comments;
  v_body   text := btrim(coalesce(p_body, ''));
begin
  if auth.uid() is null then
    raise exception 'post_comment: login required' using errcode = '42501';
  end if;
  select * into v_a from nomad_news.articles where id = p_article_id;
  if not found or not nomad_news.article_is_live(v_a.organization_id, v_a.status, v_a.published_at, v_a.embargo_until, v_a.type, v_a.wire_contract_id) then
    raise exception 'post_comment: article not found' using errcode = 'P0002';
  end if;
  select * into v_reader from nomad_news.readers where organization_id = v_a.organization_id and user_id = auth.uid();
  if not found or v_reader.status <> 'active' then
    raise exception 'post_comment: active reader registration required' using errcode = 'NW008';
  end if;
  if not nomad_news.plan_active(v_a.organization_id) then
    raise exception 'post_comment: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  select * into v_np from nomad_news.newspapers where organization_id = v_a.organization_id;
  if not v_np.comments_enabled or not v_a.comments_enabled then
    raise exception 'post_comment: comments are off' using errcode = 'NW009';
  end if;
  if exists (select 1 from nomad_news.election_periods e where e.organization_id = v_a.organization_id and e.status = 'active' and e.comment_policy = 'disabled'
             and now() >= e.poll_blackout_from and now() < e.poll_blackout_until) then
    raise exception 'post_comment: comments are off during the election period' using errcode = 'NW009';
  end if;
  if char_length(v_body) not between 1 and 1000 then
    raise exception 'post_comment: invalid body' using errcode = 'NW015';
  end if;
  -- 한글은 \b 경계가 없으므로 부분 문자열로 비교한다(SECURITY_BASELINE 14장)
  if exists (select 1 from unnest(v_np.banned_words) w where btrim(w) <> '' and position(lower(btrim(w)) in lower(v_body)) > 0) then
    raise exception 'post_comment: contains a banned word' using errcode = 'NW010';
  end if;
  select x.allowed into v_ok from nomad_core.rate_limit_take('news:cmt:min:' || v_reader.id::text, 5, 60) x;
  if v_ok then
    select x.allowed into v_ok from nomad_core.rate_limit_take('news:cmt:day:' || v_reader.id::text, 100, 86400) x;
  end if;
  if not v_ok then
    raise exception 'post_comment: rate limited' using errcode = 'NW011';
  end if;
  if p_parent_id is not null and not exists (select 1 from nomad_news.comments c where c.id = p_parent_id and c.article_id = p_article_id and c.status = 'visible') then
    raise exception 'post_comment: parent comment not found' using errcode = 'P0002';
  end if;
  insert into nomad_news.comments (organization_id, article_id, reader_id, parent_id, body)
  values (v_a.organization_id, p_article_id, v_reader.id, p_parent_id, v_body) returning * into v_row;
  update nomad_news.readers set last_seen_at = now() where id = v_reader.id;
  return v_row;
end;
$$;

create function nomad_news.delete_my_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_c nomad_news.comments;
begin
  select * into v_c from nomad_news.comments where id = p_comment_id for update;
  if not found or v_c.reader_id is distinct from nomad_news.current_reader_id(v_c.organization_id) then
    raise exception 'delete_my_comment: not found' using errcode = 'P0002';
  end if;
  if v_c.status <> 'deleted' then
    update nomad_news.comments set status = 'deleted', status_reason = 'author' where id = p_comment_id;
  end if;
end;
$$;

-- 신고. 권리침해 주장(정보통신망법 제44조의2)은 즉시 임시조치(30일). 일반 신고 5건 누적이면 숨김(제안 수치).
create function nomad_news.report_comment(p_comment_id uuid, p_reason text, p_detail text default null, p_rights_claim boolean default false)
returns nomad_news.comment_reports
language plpgsql
security definer
set search_path = ''
as $$
declare v_c nomad_news.comments; v_reader uuid; v_ok boolean; v_row nomad_news.comment_reports;
begin
  if auth.uid() is null then
    raise exception 'report_comment: login required' using errcode = '42501';
  end if;
  select * into v_c from nomad_news.comments where id = p_comment_id for update;
  if not found or v_c.status not in ('visible', 'temp_blocked') then
    raise exception 'report_comment: comment not found' using errcode = 'P0002';
  end if;
  v_reader := nomad_news.current_reader_id(v_c.organization_id);
  if v_reader is null then
    raise exception 'report_comment: reader registration required' using errcode = 'NW008';
  end if;
  if v_reader = v_c.reader_id then
    raise exception 'report_comment: cannot report your own comment' using errcode = 'NW015';
  end if;
  select x.allowed into v_ok from nomad_core.rate_limit_take('news:report:' || v_reader::text, 20, 86400) x;
  if not v_ok then
    raise exception 'report_comment: rate limited' using errcode = 'NW011';
  end if;
  insert into nomad_news.comment_reports (organization_id, comment_id, reporter_reader_id, reason, detail, is_rights_claim)
  values (v_c.organization_id, p_comment_id, v_reader, p_reason, p_detail, coalesce(p_rights_claim, false)) returning * into v_row;
  update nomad_news.comments set report_count = report_count + 1 where id = p_comment_id returning * into v_c;
  if coalesce(p_rights_claim, false) and v_c.status = 'visible' then
    update nomad_news.comments set status = 'temp_blocked', temp_blocked_until = now() + interval '30 days', status_reason = 'rights_claim'
     where id = p_comment_id;
  elsif v_c.status = 'visible' and v_c.report_count >= 5 then
    update nomad_news.comments set status = 'hidden', status_reason = 'reports_threshold' where id = p_comment_id;
  end if;
  return v_row;
end;
$$;

create function nomad_news.moderate_comment(p_comment_id uuid, p_action text, p_reason text default null)
returns nomad_news.comments
language plpgsql
security definer
set search_path = ''
as $$
declare v_c nomad_news.comments; v_old text;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.comments x where x.id = p_comment_id), array['publisher', 'editor', 'desk'], 'moderate_comment', true);
  select * into v_c from nomad_news.comments where id = p_comment_id for update;
  if not found then
    raise exception 'moderate_comment: not found' using errcode = 'P0002';
  end if;
  if p_action not in ('show', 'hide', 'temp_block', 'delete') then
    raise exception 'moderate_comment: invalid action' using errcode = 'NW015';
  end if;
  v_old := v_c.status;
  update nomad_news.comments set
    status = case p_action when 'show' then 'visible' when 'hide' then 'hidden' when 'temp_block' then 'temp_blocked' else 'deleted' end,
    temp_blocked_until = case when p_action = 'temp_block' then now() + interval '30 days' end,
    status_reason = left(p_reason, 200), moderated_by = auth.uid(), moderated_at = now()
  where id = p_comment_id returning * into v_c;
  update nomad_news.comment_reports set status = case when p_action = 'show' then 'dismissed' else 'actioned' end,
         handled_by = auth.uid(), handled_at = now()
   where comment_id = p_comment_id and status = 'open';
  perform nomad_core.write_audit(v_c.organization_id, 'comment.' || p_action, 'comment', p_comment_id::text,
                           jsonb_build_object('status', v_old), jsonb_build_object('status', v_c.status, 'reason', p_reason));
  return v_c;
end;
$$;

-- 공개 댓글 목록: 닉네임·본문·시각만(작성자 id·이메일 없음). 탈퇴 독자는 '탈퇴한 독자'.
create function nomad_news.list_comments(p_article_id uuid, p_limit integer default 50, p_before timestamptz default null)
returns table (id uuid, parent_id uuid, nickname text, body text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, c.parent_id, case when r.status = 'withdrawn' then '탈퇴한 독자' else r.nickname end, c.body, c.created_at
  from nomad_news.comments c join nomad_news.readers r on r.id = c.reader_id
  where c.article_id = p_article_id and c.status = 'visible' and nomad_news.is_article_live(p_article_id)
    and (p_before is null or c.created_at < p_before)
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- 제보·투고 접수(service_role 경유: CAPTCHA·IP 제한·첨부 업로드를 Route Handler 가 먼저 한다)
create function nomad_news.submit_tip(p_org uuid, p_fields jsonb, p_reader_user_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_ok boolean; v_reader uuid; v_row nomad_news.tips; r nomad_news.tips;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'submit_tip: service_role only' using errcode = '42501';
  end if;
  if not nomad_news.is_public_newspaper(p_org) then
    raise exception 'submit_tip: newspaper is not public' using errcode = 'NW002';
  end if;
  if not nomad_news.plan_active(p_org) then
    raise exception 'submit_tip: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  perform nomad_news.assert_keys(p_fields, array['kind', 'title', 'body', 'contact_name', 'contact_email', 'contact_phone', 'wants_anonymity',
                                           'attachment_paths', 'consent_version'], 'submit_tip');
  select x.allowed into v_ok from nomad_core.rate_limit_take('news:tip:' || p_org::text, 100, 3600) x;
  if not v_ok then
    raise exception 'submit_tip: rate limited' using errcode = 'NW011';
  end if;
  if p_reader_user_id is not null then
    select x.id into v_reader from nomad_news.readers x where x.organization_id = p_org and x.user_id = p_reader_user_id and x.status = 'active';
  end if;
  r := jsonb_populate_record(null::nomad_news.tips, p_fields);
  insert into nomad_news.tips (organization_id, kind, reader_id, title, body, contact_name, contact_email, contact_phone, wants_anonymity, attachment_paths, consent_version)
  values (p_org, coalesce(r.kind, 'tip'), v_reader, r.title, r.body, r.contact_name, r.contact_email, r.contact_phone,
          coalesce(r.wants_anonymity, true), coalesce(r.attachment_paths, '{}'), r.consent_version)
  returning * into v_row;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'reference', upper(left(replace(v_row.id::text, '-', ''), 8)));
end;
$$;

create function nomad_news.set_tip_status(p_id uuid, p_status text, p_assigned_to uuid default null, p_note text default null)
returns nomad_news.tips
language plpgsql
security definer
set search_path = ''
as $$
declare v_t nomad_news.tips; v_role text;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  v_role := nomad_news.assert_staff_row((select x.organization_id from nomad_news.tips x where x.id = p_id), array['publisher', 'editor', 'desk', 'reporter'], 'set_tip_status');
  select * into v_t from nomad_news.tips where id = p_id for update;
  if not found then
    raise exception 'set_tip_status: not found' using errcode = 'P0002';
  end if;
  if v_role = 'reporter' and (v_t.assigned_to is distinct from auth.uid() or p_status not in ('reviewing', 'used') or p_assigned_to is not null) then
    raise exception 'set_tip_status: reporters update their assigned tips only' using errcode = '42501';
  end if;
  if p_assigned_to is not null and not exists (select 1 from nomad_news.staff s where s.organization_id = v_t.organization_id and s.user_id = p_assigned_to
                                                 and s.status = 'active' and s.role in ('publisher', 'editor', 'desk', 'reporter')) then
    raise exception 'set_tip_status: assignee must be editorial staff' using errcode = 'NW015';
  end if;
  update nomad_news.tips set status = coalesce(p_status, status), assigned_to = coalesce(p_assigned_to, assigned_to),
         staff_note = coalesce(p_note, staff_note)
   where id = p_id returning * into v_t;
  perform nomad_core.write_audit(v_t.organization_id, 'tip.status', 'tip', p_id::text, null, jsonb_build_object('status', v_t.status, 'assigned_to', v_t.assigned_to));
  return v_t;
end;
$$;

create function nomad_news.submit_life_event(p_org uuid, p_fields jsonb)
returns nomad_news.life_events
language plpgsql
security definer
set search_path = ''
as $$
declare v_reader uuid; v_ok boolean; v_row nomad_news.life_events; r nomad_news.life_events;
begin
  if auth.uid() is null then
    raise exception 'submit_life_event: login required' using errcode = '42501';
  end if;
  v_reader := nomad_news.current_reader_id(p_org);
  if v_reader is null then
    raise exception 'submit_life_event: reader registration required' using errcode = 'NW008';
  end if;
  perform nomad_news.assert_keys(p_fields, array['kind', 'title', 'body', 'event_at', 'applicant_name', 'applicant_phone', 'consent_version'], 'submit_life_event');
  if not nomad_news.plan_active(p_org) then
    raise exception 'submit_life_event: newspaper subscription inactive' using errcode = 'NW014';
  end if;
  select x.allowed into v_ok from nomad_core.rate_limit_take('news:life:' || v_reader::text, 5, 86400) x;
  if not v_ok then
    raise exception 'submit_life_event: rate limited' using errcode = 'NW011';
  end if;
  r := jsonb_populate_record(null::nomad_news.life_events, p_fields);
  insert into nomad_news.life_events (organization_id, kind, title, body, event_at, applicant_reader_id, applicant_name, applicant_phone, consent_version)
  values (p_org, r.kind, r.title, r.body, r.event_at, v_reader, r.applicant_name, r.applicant_phone, r.consent_version)
  returning * into v_row;
  return v_row;
end;
$$;

create function nomad_news.review_life_event(p_id uuid, p_decision text, p_note text default null)
returns nomad_news.life_events
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.life_events;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.life_events x where x.id = p_id), array['publisher', 'editor', 'desk'], 'review_life_event');
  select * into v_row from nomad_news.life_events where id = p_id for update;
  if not found then
    raise exception 'review_life_event: not found' using errcode = 'P0002';
  end if;
  if p_decision not in ('approve', 'reject', 'archive') then
    raise exception 'review_life_event: invalid decision' using errcode = 'NW015';
  end if;
  update nomad_news.life_events set
    status = case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'archived' end,
    reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_note
  where id = p_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'life_event.' || p_decision, 'life_event', p_id::text, null,
                           jsonb_build_object('status', v_row.status, 'kind', v_row.kind));
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.11 배포·SEO(M6)
-- ---------------------------------------------------------------------
create function nomad_news.upsert_wire_contract(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.wire_contracts
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.wire_contracts; r nomad_news.wire_contracts;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'upsert_wire_contract');
  perform nomad_news.assert_keys(p_fields, array['provider', 'name', 'contract_no', 'starts_on', 'ends_on', 'attribution_text', 'allow_full_text', 'status', 'note'], 'upsert_wire_contract');
  r := jsonb_populate_record(null::nomad_news.wire_contracts, p_fields);
  if p_id is null then
    insert into nomad_news.wire_contracts (organization_id, provider, name, contract_no, starts_on, ends_on, attribution_text, allow_full_text, note, created_by)
    values (p_org, r.provider, r.name, r.contract_no, r.starts_on, r.ends_on, r.attribution_text, coalesce(r.allow_full_text, true), r.note, auth.uid())
    returning * into v_row;
  else
    update nomad_news.wire_contracts set
      provider = case when p_fields ? 'provider' then r.provider else provider end,
      name = case when p_fields ? 'name' then r.name else name end,
      contract_no = case when p_fields ? 'contract_no' then r.contract_no else contract_no end,
      starts_on = case when p_fields ? 'starts_on' then r.starts_on else starts_on end,
      ends_on = case when p_fields ? 'ends_on' then r.ends_on else ends_on end,
      attribution_text = case when p_fields ? 'attribution_text' then r.attribution_text else attribution_text end,
      allow_full_text = case when p_fields ? 'allow_full_text' then coalesce(r.allow_full_text, true) else allow_full_text end,
      status = case when p_fields ? 'status' then r.status else status end,
      note = case when p_fields ? 'note' then r.note else note end
    where id = p_id and organization_id = p_org returning * into v_row;
    if not found then
      raise exception 'upsert_wire_contract: not found' using errcode = 'P0002';
    end if;
  end if;
  perform nomad_core.write_audit(p_org, 'wire_contract.save', 'wire_contract', v_row.id::text, null,
                           jsonb_build_object('provider', v_row.provider, 'ends_on', v_row.ends_on, 'status', v_row.status));
  return v_row;
end;
$$;

create function nomad_news.set_syndication_settings(p_org uuid, p_fields jsonb)
returns nomad_news.syndication_settings
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.syndication_settings; r nomad_news.syndication_settings;
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'set_syndication_settings');
  perform nomad_news.assert_keys(p_fields, array['rss_enabled', 'news_sitemap_enabled', 'google_news', 'naver_partnership', 'daum_partnership',
                                           'ai_crawler_policy', 'llms_txt_enabled', 'robots_extra', 'sns_autoshare'], 'set_syndication_settings');
  r := jsonb_populate_record(null::nomad_news.syndication_settings, p_fields);
  insert into nomad_news.syndication_settings (organization_id) values (p_org) on conflict (organization_id) do nothing;
  update nomad_news.syndication_settings set
    rss_enabled = case when p_fields ? 'rss_enabled' then coalesce(r.rss_enabled, true) else rss_enabled end,
    news_sitemap_enabled = case when p_fields ? 'news_sitemap_enabled' then coalesce(r.news_sitemap_enabled, true) else news_sitemap_enabled end,
    google_news = case when p_fields ? 'google_news' then coalesce(r.google_news, false) else google_news end,
    naver_partnership = case when p_fields ? 'naver_partnership' then r.naver_partnership else naver_partnership end,
    daum_partnership = case when p_fields ? 'daum_partnership' then r.daum_partnership else daum_partnership end,
    ai_crawler_policy = case when p_fields ? 'ai_crawler_policy' then r.ai_crawler_policy else ai_crawler_policy end,
    llms_txt_enabled = case when p_fields ? 'llms_txt_enabled' then coalesce(r.llms_txt_enabled, false) else llms_txt_enabled end,
    robots_extra = case when p_fields ? 'robots_extra' then r.robots_extra else robots_extra end,
    sns_autoshare = case when p_fields ? 'sns_autoshare' then coalesce(r.sns_autoshare, '{}'::jsonb) else sns_autoshare end,
    updated_by = auth.uid()
  where organization_id = p_org returning * into v_row;
  perform nomad_core.write_audit(p_org, 'syndication.save', 'syndication_settings', v_row.id::text, null,
                           jsonb_build_object('ai_crawler_policy', v_row.ai_crawler_policy, 'rss', v_row.rss_enabled));
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.12 법정 준수(M7): 정정 청구, 주간 자체기사 지표, 선거 기간
-- ---------------------------------------------------------------------
-- 정정·반론·추후보도 청구 접수. 웹 폼은 service_role(Route Handler), 우편·전화 접수는 데스크 이상이 직접 기록한다.
-- received_at 은 서버·편집국만 과거(90일 이내)로 지정할 수 있고, 기한(notify_due_at)은 트리거가 계산한다.
create function nomad_news.submit_correction_request(p_org uuid, p_fields jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_role text; v_ok boolean; v_reader uuid; v_row nomad_news.correction_requests; r nomad_news.correction_requests; v_received timestamptz;
begin
  v_role := nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk'], 'submit_correction_request', true);
  perform nomad_news.assert_keys(p_fields, array['article_id', 'article_url', 'kind', 'requester_name', 'requester_email', 'requester_phone',
                                           'requester_user_id', 'claim_text', 'requested_text', 'attachment_paths', 'channel', 'received_at'],
                           'submit_correction_request');
  if v_role = 'service' then
    select x.allowed into v_ok from nomad_core.rate_limit_take('news:corr:' || p_org::text, 50, 3600) x;
    if not v_ok then
      raise exception 'submit_correction_request: rate limited' using errcode = 'NW011';
    end if;
  end if;
  r := jsonb_populate_record(null::nomad_news.correction_requests, p_fields);
  v_received := coalesce(r.received_at, now());
  if v_received > now() + interval '1 minute' or v_received < now() - interval '90 days' then
    raise exception 'submit_correction_request: received_at out of range' using errcode = 'NW015';
  end if;
  if p_fields ? 'requester_user_id' then
    select x.id into v_reader from nomad_news.readers x where x.organization_id = p_org and x.user_id = (p_fields ->> 'requester_user_id')::uuid;
  end if;
  insert into nomad_news.correction_requests (organization_id, article_id, article_url, kind, requester_name, requester_email, requester_phone,
    requester_reader_id, claim_text, requested_text, attachment_paths, channel, received_at, notify_due_at, created_by)
  values (p_org, r.article_id, r.article_url, r.kind, r.requester_name, lower(r.requester_email), r.requester_phone, v_reader,
          r.claim_text, r.requested_text, coalesce(r.attachment_paths, '{}'), coalesce(r.channel, 'web'), v_received, v_received, auth.uid())
  returning * into v_row;
  perform nomad_core.write_audit(p_org, 'correction_request.receive', 'correction_request', v_row.id::text, null,
                           jsonb_build_object('kind', v_row.kind, 'channel', v_row.channel, 'notify_due_at', v_row.notify_due_at));
  return jsonb_build_object('ok', true, 'id', v_row.id, 'reference', upper(left(replace(v_row.id::text, '-', ''), 8)),
                            'received_at', v_row.received_at, 'notify_due_at', v_row.notify_due_at);
end;
$$;

-- 청구 처리: reviewing / accept(7일 게재 기한 시작) / reject(사유 필수) / withdrawn. 발행인·편집인만.
create function nomad_news.respond_correction_request(p_id uuid, p_decision text, p_note text default null)
returns nomad_news.correction_requests
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.correction_requests; v_old text;
begin
  -- W7: 인가 먼저(편집국이 아니면 존재를 드러내지 않게 P0002), 행 잠금은 인가 뒤
  perform nomad_news.assert_staff_row((select x.organization_id from nomad_news.correction_requests x where x.id = p_id), array['publisher', 'editor'], 'respond_correction_request', true);
  select * into v_row from nomad_news.correction_requests where id = p_id for update;
  if not found then
    raise exception 'respond_correction_request: not found' using errcode = 'P0002';
  end if;
  if p_decision not in ('reviewing', 'accept', 'reject', 'withdrawn') then
    raise exception 'respond_correction_request: invalid decision' using errcode = 'NW015';
  end if;
  if p_decision = 'reject' and coalesce(btrim(p_note), '') = '' then
    raise exception 'respond_correction_request: rejection reason required' using errcode = 'NW015';
  end if;
  if v_row.status not in ('received', 'reviewing') and p_decision <> 'withdrawn' then
    raise exception 'respond_correction_request: invalid state %', v_row.status using errcode = 'NW004';
  end if;
  v_old := v_row.status;
  update nomad_news.correction_requests set
    status = case p_decision when 'accept' then 'accepted' when 'reject' then 'rejected' else p_decision end,
    decided_by = case when p_decision in ('accept', 'reject') then auth.uid() else decided_by end,
    decision_note = coalesce(p_note, decision_note)
  where id = p_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'correction_request.' || p_decision, 'correction_request', p_id::text,
                           jsonb_build_object('status', v_old),
                           jsonb_build_object('status', v_row.status, 'notified_at', v_row.notified_at, 'publish_due_at', v_row.publish_due_at));
  return v_row;
end;
$$;

-- 주간 자체기사 지표(NW-F-041, 신문법 시행령 제2조: 주간 게재 기사 30% 이상 자체 생산, 주간 신규 게재).
--   기간: p_week_start(월요일, KST) 00:00 부터 7일. 그 주에 처음 게시된(first_published_at) 기사.
--   분모 = original + wire + press_release + contribution (sponsored 는 광고라 제외, 제안)
--   자체기사 = type original 이고 origin 이 ai_press_release 가 아닌 것. 보도자료와 보도자료 AI 초안은 자체기사가 아니다(D-9).
--   flags: no_new_articles(주간 0건), original_ratio_below_30, press_release_ratio_high(보도자료 50% 초과, 포털 감점 경고, 제안)
create function nomad_news.compliance_weekly_stats(p_org uuid, p_week_start date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from timestamptz;
  v_to   timestamptz;
  v_total integer; v_original integer; v_press integer; v_ai_press integer; v_wire integer; v_contrib integer; v_sponsored integer;
  v_ratio numeric;
  v_flags text[] := '{}';
begin
  perform nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk'], 'compliance_weekly_stats', true);
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'compliance_weekly_stats: week_start must be a Monday' using errcode = 'NW015';
  end if;
  v_from := (p_week_start::timestamp at time zone 'Asia/Seoul');
  v_to := v_from + interval '7 days';
  select count(*) filter (where a.type <> 'sponsored'),
         count(*) filter (where a.type = 'original' and a.origin <> 'ai_press_release'),
         count(*) filter (where a.type = 'press_release'),
         count(*) filter (where a.origin = 'ai_press_release'),
         count(*) filter (where a.type = 'wire'),
         count(*) filter (where a.type = 'contribution'),
         count(*) filter (where a.type = 'sponsored')
    into v_total, v_original, v_press, v_ai_press, v_wire, v_contrib, v_sponsored
  from nomad_news.articles a
  where a.organization_id = p_org and a.first_published_at >= v_from and a.first_published_at < v_to;
  v_ratio := case when v_total > 0 then round(v_original::numeric / v_total, 4) end;
  if v_total = 0 then
    v_flags := array_append(v_flags, 'no_new_articles');
  else
    if v_ratio < 0.30 then v_flags := array_append(v_flags, 'original_ratio_below_30'); end if;
    if v_press::numeric / v_total > 0.50 then v_flags := array_append(v_flags, 'press_release_ratio_high'); end if;
  end if;
  return jsonb_build_object(
    'organization_id', p_org, 'week_start', p_week_start, 'from', v_from, 'to', v_to,
    'total_published', v_total, 'original_count', v_original, 'press_release_count', v_press,
    'ai_press_release_count', v_ai_press, 'wire_count', v_wire, 'contribution_count', v_contrib, 'sponsored_count', v_sponsored,
    'original_ratio', v_ratio, 'flags', to_jsonb(v_flags));
end;
$$;

create function nomad_news.upsert_election_period(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.election_periods
language plpgsql
security definer
set search_path = ''
as $$
declare v_role text; v_row nomad_news.election_periods; r nomad_news.election_periods;
begin
  v_role := nomad_news.assert_staff(p_org, array['publisher', 'editor'], 'upsert_election_period');
  perform nomad_news.assert_keys(p_fields, array['name', 'election_day', 'poll_blackout_from', 'poll_blackout_until', 'comment_policy', 'status'], 'upsert_election_period');
  r := jsonb_populate_record(null::nomad_news.election_periods, p_fields);
  if p_id is null then
    insert into nomad_news.election_periods (organization_id, name, election_day, poll_blackout_from, poll_blackout_until, comment_policy, source, created_by)
    values (p_org, r.name, r.election_day, r.poll_blackout_from, r.poll_blackout_until, coalesce(r.comment_policy, 'normal'),
            case when v_role = 'service' then 'platform' else 'newsroom' end, auth.uid())
    returning * into v_row;
  else
    update nomad_news.election_periods set
      name = case when p_fields ? 'name' then r.name else name end,
      election_day = case when p_fields ? 'election_day' then r.election_day else election_day end,
      poll_blackout_from = case when p_fields ? 'poll_blackout_from' then r.poll_blackout_from else poll_blackout_from end,
      poll_blackout_until = case when p_fields ? 'poll_blackout_until' then r.poll_blackout_until else poll_blackout_until end,
      comment_policy = case when p_fields ? 'comment_policy' then r.comment_policy else comment_policy end,
      status = case when p_fields ? 'status' then r.status else status end
    where id = p_id and organization_id = p_org and (source = 'newsroom' or v_role = 'service') returning * into v_row;
    if not found then
      raise exception 'upsert_election_period: not found or platform-managed' using errcode = 'P0002';
    end if;
  end if;
  perform nomad_core.write_audit(p_org, 'election_period.save', 'election_period', v_row.id::text, null,
    jsonb_build_object('status', v_row.status, 'poll_blackout_from', v_row.poll_blackout_from, 'poll_blackout_until', v_row.poll_blackout_until,
                       'comment_policy', v_row.comment_policy));
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 11.13 검색·분석(M8)
-- ---------------------------------------------------------------------
-- 조회수 증분(service_role 전용). 봇 필터·레이트 리밋은 /api/r/view 가 먼저 한다. 공개 기사만, 1회 최대 1,000, 48시간 안의 시각만.
create function nomad_news.increment_article_views(p_article_id uuid, p_count integer default 1, p_at timestamptz default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_org uuid; v_at timestamptz := coalesce(p_at, now());
begin
  if not nomad_core.is_service_caller() then
    raise exception 'increment_article_views: service_role only' using errcode = '42501';
  end if;
  if p_count is null or p_count not between 1 and 1000 or v_at > now() + interval '5 minutes' or v_at < now() - interval '48 hours' then
    raise exception 'increment_article_views: invalid count or time' using errcode = 'NW015';
  end if;
  select a.organization_id into v_org from nomad_news.articles a where a.id = p_article_id;
  if v_org is null or not nomad_news.is_article_live(p_article_id) then
    return false;
  end if;
  insert into nomad_news.article_view_hourly as v (organization_id, article_id, bucket_start, views)
  values (v_org, p_article_id, date_trunc('hour', v_at, 'UTC'), p_count)
  on conflict (article_id, bucket_start) do update set views = v.views + excluded.views, updated_at = now();
  return true;
end;
$$;

-- 많이 본 뉴스(공개). 창: 1h(현재 시 + 직전 1시간 버킷) | 24h. 공개 기사만.
create function nomad_news.most_read(p_org uuid, p_window text default '24h', p_limit integer default 10)
returns table (article_id uuid, slug text, title text, views bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id, a.slug, a.title, sum(v.views)::bigint
  from nomad_news.article_view_hourly v
  join nomad_news.articles a on a.id = v.article_id
  where v.organization_id = p_org
    and p_window in ('1h', '24h')
    and v.bucket_start >= date_trunc('hour', now() - case when p_window = '1h' then interval '1 hour' else interval '24 hours' end, 'UTC')
    and nomad_news.article_is_live(a.organization_id, a.status, a.published_at, a.embargo_until, a.type, a.wire_contract_id)
  group by a.id, a.slug, a.title
  order by sum(v.views) desc, max(a.published_at) desc
  limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;

-- 기사 검색(공개). tsvector('simple') 일치 또는 제목 부분 일치(pg_trgm GIN 이 ILIKE 를 받친다). 공개 기사만, 본문은 돌려주지 않는다.
create function nomad_news.search_articles(p_org uuid, p_query text, p_limit integer default 20, p_offset integer default 0)
returns table (article_id uuid, slug text, title text, summary text, published_at timestamptz, rank real)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_q text := btrim(coalesce(p_query, '')); v_like text;
begin
  if char_length(v_q) not between 1 and 100 then
    raise exception 'search_articles: query length must be 1..100' using errcode = 'NW015';
  end if;
  if p_offset is not null and p_offset not between 0 and 1000 then
    raise exception 'search_articles: offset must be 0..1000' using errcode = 'NW015';
  end if;
  if not nomad_news.is_public_newspaper(p_org) then
    return;
  end if;
  v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return query
    select a.id, a.slug, a.title, a.summary, a.published_at,
           (ts_rank(a.search_tsv, plainto_tsquery('simple'::regconfig, v_q)) + case when a.title ilike v_like then 1 else 0 end)::real
    from nomad_news.articles a
    where a.organization_id = p_org and a.status = 'published'
      and (a.search_tsv @@ plainto_tsquery('simple'::regconfig, v_q) or a.title ilike v_like)
      and nomad_news.article_is_live(a.organization_id, a.status, a.published_at, a.embargo_until, a.type, a.wire_contract_id)
    order by 6 desc, a.published_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 50) offset coalesce(p_offset, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 11.14 행사(local-life)
-- ---------------------------------------------------------------------
create function nomad_news.save_event(p_org uuid, p_id uuid, p_fields jsonb)
returns nomad_news.events
language plpgsql
security definer
set search_path = ''
as $$
declare v_row nomad_news.events; r nomad_news.events; v_role text; v_old nomad_news.events;
begin
  v_role := nomad_news.assert_staff(p_org, array['publisher', 'editor', 'desk', 'reporter'], 'save_event');
  perform nomad_news.assert_keys(p_fields, array['title', 'description', 'venue', 'address', 'region_id', 'starts_at', 'ends_at', 'is_all_day',
                                           'url', 'image_path', 'organizer', 'price_text', 'status'], 'save_event');
  r := jsonb_populate_record(null::nomad_news.events, p_fields);
  -- W5: 기자는 자기 draft 행사만 만들고 고친다. 상태 변경(게시·취소·보관)은 데스크 이상
  if v_role = 'reporter' and p_fields ? 'status' and r.status is distinct from 'draft' then
    raise exception 'save_event: publishing requires desk' using errcode = '42501';
  end if;
  if p_id is not null then
    select * into v_old from nomad_news.events where id = p_id and organization_id = p_org for update;
    if not found then
      raise exception 'save_event: not found' using errcode = 'P0002';
    end if;
    if v_role = 'reporter' and (v_old.created_by is distinct from auth.uid() or v_old.status <> 'draft') then
      raise exception 'save_event: reporters edit their own draft events only' using errcode = '42501';
    end if;
  end if;
  if p_id is null then
    insert into nomad_news.events (organization_id, title, description, venue, address, region_id, starts_at, ends_at, is_all_day, url, image_path,
                             organizer, price_text, created_by)
    values (p_org, r.title, r.description, r.venue, r.address, r.region_id, r.starts_at, r.ends_at, coalesce(r.is_all_day, false), r.url,
            r.image_path, r.organizer, r.price_text, auth.uid())
    returning * into v_row;
  end if;
  update nomad_news.events set
    title = case when p_fields ? 'title' then r.title else title end,
    description = case when p_fields ? 'description' then r.description else description end,
    venue = case when p_fields ? 'venue' then r.venue else venue end,
    address = case when p_fields ? 'address' then r.address else address end,
    region_id = case when p_fields ? 'region_id' then r.region_id else region_id end,
    starts_at = case when p_fields ? 'starts_at' then r.starts_at else starts_at end,
    ends_at = case when p_fields ? 'ends_at' then r.ends_at else ends_at end,
    is_all_day = case when p_fields ? 'is_all_day' then coalesce(r.is_all_day, false) else is_all_day end,
    url = case when p_fields ? 'url' then r.url else url end,
    image_path = case when p_fields ? 'image_path' then r.image_path else image_path end,
    organizer = case when p_fields ? 'organizer' then r.organizer else organizer end,
    price_text = case when p_fields ? 'price_text' then r.price_text else price_text end,
    status = case when p_fields ? 'status' then r.status else status end
  where id = coalesce(p_id, v_row.id) and organization_id = p_org returning * into v_row;
  if not found then
    raise exception 'save_event: not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;


-- ---------------------------------------------------------------------
-- 11.15 공개 읽기 RPC(D8, 이식 추가): 원본 anon 컬럼 grant 를 대신한다. 공개 조건을 만족한 행의 공개 컬럼만 jsonb 로.
--   공개 판정은 is_public_newspaper(플랜 무관, N1). DB rate 키 없음(공개 읽기는 CDN·Route Handler 가 막는다).
-- ---------------------------------------------------------------------
-- 독자 사이트 부트스트랩: 매체정보(법정 푸터)·페이월·배포 설정·분류·멤버십 가격표·광고 슬롯 크기·뉴스레터 목록·게시 홈 편집·공개 기자 프로필
create function nomad_news.get_public_newspaper(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'organization_id', n.organization_id, 'slug', n.slug, 'title', n.title, 'legal_name', n.legal_name, 'media_kind', n.media_kind,
    'registration_no', n.registration_no, 'registration_date', n.registration_date, 'publisher_name', n.publisher_name,
    'editor_name', n.editor_name, 'youth_officer_name', n.youth_officer_name, 'privacy_officer_name', n.privacy_officer_name,
    'publish_address', n.publish_address, 'phone', n.phone, 'email', n.email, 'first_published_on', n.first_published_on,
    'ethics_code_url', n.ethics_code_url, 'comments_enabled', n.comments_enabled,
    'reader_signup_open', nomad_news.plan_active(n.organization_id),
    'paywall', (select jsonb_build_object('mode', w.mode, 'free_articles_per_month', w.free_articles_per_month,
                                          'exempt_types', to_jsonb(w.exempt_types), 'cta_text', w.cta_text)
                from nomad_news.paywall_rules w where w.organization_id = n.organization_id),
    'syndication', (select jsonb_build_object('rss_enabled', y.rss_enabled, 'news_sitemap_enabled', y.news_sitemap_enabled,
                                              'google_news', y.google_news, 'ai_crawler_policy', y.ai_crawler_policy,
                                              'llms_txt_enabled', y.llms_txt_enabled, 'robots_extra', y.robots_extra)
                    from nomad_news.syndication_settings y where y.organization_id = n.organization_id),
    'sections', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'slug', x.slug, 'name', x.name, 'parent_id', x.parent_id) order by x.sort_order, x.name)
                          from nomad_news.sections x where x.organization_id = n.organization_id and x.is_active), '[]'::jsonb),
    'regions', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'slug', x.slug, 'name', x.name, 'level', x.level,
                                                             'admin_code', x.admin_code, 'parent_id', x.parent_id) order by x.sort_order, x.name)
                         from nomad_news.regions x where x.organization_id = n.organization_id and x.is_active), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'slug', x.slug, 'name', x.name) order by x.name)
                      from nomad_news.tags x where x.organization_id = n.organization_id and x.is_active), '[]'::jsonb),
    'membership_tiers', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'code', x.code, 'name', x.name, 'description', x.description,
                                                                      'price_krw', x.price_krw, 'billing_interval', x.billing_interval,
                                                                      'benefits', x.benefits) order by x.sort_order, x.price_krw)
                                  from nomad_news.membership_tiers x where x.organization_id = n.organization_id and x.is_active), '[]'::jsonb),
    'ad_slots', coalesce((select jsonb_agg(jsonb_build_object('code', x.code, 'placement', x.placement, 'width', x.width, 'height', x.height)
                                           order by x.sort_order)
                          from nomad_news.ad_slots x where x.organization_id = n.organization_id and x.is_active), '[]'::jsonb),
    'newsletter_lists', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'slug', x.slug, 'name', x.name, 'description', x.description,
                                                                      'kind', x.kind, 'contains_ads', x.contains_ads,
                                                                      'consent_version', x.consent_version) order by x.name)
                                  from nomad_news.newsletter_lists x
                                  where x.organization_id = n.organization_id and x.status = 'active' and x.is_public), '[]'::jsonb),
    'home_layout', (select jsonb_build_object('template', h.template, 'blocks', h.blocks, 'version', h.version, 'published_at', h.published_at)
                    from nomad_news.home_layouts h where h.organization_id = n.organization_id and h.status = 'published'),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'role', x.role, 'byline_name', x.byline_name, 'title_label', x.title_label,
                                                           'bio', x.bio, 'photo_path', x.photo_path, 'email_public', x.email_public)
                                        order by x.byline_name)
                       from nomad_news.staff x where x.organization_id = n.organization_id and x.status = 'active' and x.is_public_profile), '[]'::jsonb))
  from nomad_news.newspapers n
  where n.slug = lower(btrim(coalesce(p_slug, ''))) and nomad_news.is_public_newspaper(n.organization_id);
$$;

-- 기사 목록(공개): 공개 기사의 목록 컬럼만(본문·검색 벡터·내부 메모 없음). 섹션·지역·태그 slug 로 거른다. p_before = published_at 커서.
create function nomad_news.list_public_articles(p_org uuid, p_section text default null, p_region text default null, p_tag text default null,
                                                p_before timestamptz default null, p_limit integer default 20)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(x.j order by x.published_at desc), '[]'::jsonb)
  from (
    select a.published_at, jsonb_build_object(
      'id', a.id, 'slug', a.slug, 'title', a.title, 'subtitle', a.subtitle, 'summary', a.summary, 'type', a.type,
      'section_id', a.section_id, 'byline', a.byline, 'is_premium', a.is_premium, 'sponsor_label', a.sponsor_label,
      'ai_assisted', a.ai_assisted, 'ai_disclosure', a.ai_disclosure, 'source_note', a.source_note, 'is_poll', a.is_poll,
      'poll_disclosure', a.poll_disclosure, 'is_breaking', a.is_breaking, 'is_live', a.is_live, 'comments_enabled', a.comments_enabled,
      'seo', a.seo, 'published_at', a.published_at, 'first_published_at', a.first_published_at, 'revised_at', a.revised_at,
      'revision_note', a.revision_note, 'last_corrected_at', a.last_corrected_at, 'correction_count', a.correction_count,
      'hero', (select jsonb_build_object('path', m.storage_path, 'bucket', m.bucket, 'alt', m.alt_text, 'caption', m.caption, 'credit', m.credit,
                                         'width', m.width, 'height', m.height, 'ai_generated', m.ai_generated, 'ai_disclosure', m.ai_disclosure)
               from nomad_news.media_assets m where m.id = a.hero_media_id and m.organization_id = a.organization_id and m.status = 'active')) as j
    from nomad_news.articles a
    where a.organization_id = p_org and a.status = 'published'
      and nomad_news.article_is_live(a.organization_id, a.status, a.published_at, a.embargo_until, a.type, a.wire_contract_id)
      and (p_before is null or a.published_at < p_before)
      and (p_section is null or exists (select 1 from nomad_news.sections s where s.id = a.section_id and s.slug = p_section and s.is_active))
      and (p_region is null or exists (select 1 from nomad_news.article_regions ar join nomad_news.regions g on g.id = ar.region_id
                                       where ar.article_id = a.id and g.slug = p_region))
      and (p_tag is null or exists (select 1 from nomad_news.article_tags at join nomad_news.tags t on t.id = at.tag_id
                                    where at.article_id = a.id and t.slug = p_tag))
    order by a.published_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
  ) x;
$$;

-- 기타 공개 목록: notices(법정 공고) · life_events(경조사) · events(행사, p_cursor = starts_at 하한) · listings(업소, 연락 이메일 없음)
--   · print_editions(지면 메타, PDF 경로 없음 — 서버가 서명 URL). 나머지는 p_cursor = published_at 커서.
create function nomad_news.list_public_items(p_org uuid, p_kind text, p_cursor timestamptz default null, p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50); v_out jsonb;
begin
  if p_kind is null or p_kind not in ('notices', 'life_events', 'events', 'listings', 'print_editions') then
    raise exception 'list_public_items: invalid kind' using errcode = 'NW015';
  end if;
  if not nomad_news.is_public_newspaper(p_org) then
    return '[]'::jsonb;
  end if;
  if p_kind = 'notices' then
    select coalesce(jsonb_agg(x.j order by x.k desc), '[]'::jsonb) into v_out from (
      select t.published_at as k, jsonb_build_object('id', t.id, 'issuer_name', t.issuer_name, 'notice_no', t.notice_no, 'title', t.title,
               'body', t.body, 'region_id', t.region_id, 'attachment_path', t.attachment_path, 'posted_from', t.posted_from,
               'posted_until', t.posted_until, 'published_at', t.published_at) as j
      from nomad_news.public_notices t
      where t.organization_id = p_org and t.status = 'published' and (p_cursor is null or t.published_at < p_cursor)
      order by t.published_at desc limit v_limit) x;
  elsif p_kind = 'life_events' then
    select coalesce(jsonb_agg(x.j order by x.k desc), '[]'::jsonb) into v_out from (
      select t.published_at as k, jsonb_build_object('id', t.id, 'kind', t.kind, 'title', t.title, 'body', t.body, 'event_at', t.event_at,
               'published_at', t.published_at) as j
      from nomad_news.life_events t
      where t.organization_id = p_org and t.status = 'approved' and (p_cursor is null or t.published_at < p_cursor)
      order by t.published_at desc limit v_limit) x;
  elsif p_kind = 'events' then
    select coalesce(jsonb_agg(x.j order by x.k), '[]'::jsonb) into v_out from (
      select t.starts_at as k, jsonb_build_object('id', t.id, 'title', t.title, 'description', t.description, 'venue', t.venue,
               'address', t.address, 'region_id', t.region_id, 'starts_at', t.starts_at, 'ends_at', t.ends_at, 'is_all_day', t.is_all_day,
               'url', t.url, 'image_path', t.image_path, 'organizer', t.organizer, 'price_text', t.price_text, 'status', t.status) as j
      from nomad_news.events t
      where t.organization_id = p_org and t.status in ('published', 'canceled') and (p_cursor is null or t.starts_at >= p_cursor)
      order by t.starts_at limit v_limit) x;
  elsif p_kind = 'listings' then
    select coalesce(jsonb_agg(x.j order by x.k desc), '[]'::jsonb) into v_out from (
      select t.starts_at as k, jsonb_build_object('id', t.id, 'business_name', t.business_name, 'category', t.category,
               'region_id', t.region_id, 'address', t.address, 'phone', t.phone, 'url', t.url, 'description', t.description,
               'photo_path', t.photo_path, 'starts_at', t.starts_at, 'ends_at', t.ends_at) as j
      from nomad_news.local_listings t
      where t.organization_id = p_org and t.status = 'active' and t.starts_at <= now() and t.ends_at > now()
        and (p_cursor is null or t.starts_at < p_cursor)
      order by t.starts_at desc limit v_limit) x;
  else
    select coalesce(jsonb_agg(x.j order by x.k desc), '[]'::jsonb) into v_out from (
      select t.published_at as k, jsonb_build_object('id', t.id, 'edition_date', t.edition_date, 'issue_no', t.issue_no, 'title', t.title,
               'page_count', t.page_count, 'published_at', t.published_at) as j
      from nomad_news.print_editions t
      where t.organization_id = p_org and t.status = 'published' and (p_cursor is null or t.published_at < p_cursor)
      order by t.published_at desc limit v_limit) x;
  end if;
  return v_out;
end;
$$;

-- =====================================================================
-- 12. EXECUTE 정리: 이 스키마 모든 함수에서 PUBLIC/anon/authenticated 를 회수하고 service_role 에 준 뒤 허용 목록만 다시 준다.
--   anon + authenticated : 공개 읽기 RPC 10개(get_public_newspaper · list_public_articles · list_public_items · read_article · serve_ads
--                          · list_comments · most_read · search_articles · confirm_newsletter · unsubscribe_newsletter)
--   authenticated        : 편집국·독자 RPC(함수 안에서 is_service_caller + 역할 + 구독 검사), 정책 헬퍼(불리언·자기 행 id·자기 역할만)
--   service_role 전용    : 그 밖 전부(서버 RPC, 내부 헬퍼, 조직 판정 헬퍼 is_public_newspaper·article_is_live 등, CHECK 헬퍼)
-- =====================================================================
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'nomad_news'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

grant execute on function nomad_news.get_public_newspaper(text) to anon, authenticated;
grant execute on function nomad_news.list_public_articles(uuid, text, text, text, timestamptz, integer) to anon, authenticated;
grant execute on function nomad_news.list_public_items(uuid, text, timestamptz, integer) to anon, authenticated;
grant execute on function nomad_news.read_article(uuid, text) to anon, authenticated;
grant execute on function nomad_news.serve_ads(uuid, text) to anon, authenticated;
grant execute on function nomad_news.list_comments(uuid, integer, timestamptz) to anon, authenticated;
grant execute on function nomad_news.most_read(uuid, text, integer) to anon, authenticated;
grant execute on function nomad_news.search_articles(uuid, text, integer, integer) to anon, authenticated;
grant execute on function nomad_news.confirm_newsletter(text) to anon, authenticated;
grant execute on function nomad_news.unsubscribe_newsletter(text, text) to anon, authenticated;

grant execute on function nomad_news.staff_role(uuid) to authenticated;
grant execute on function nomad_news.has_staff_role(uuid, text[]) to authenticated;
grant execute on function nomad_news.is_newsroom(uuid, text[]) to authenticated;
grant execute on function nomad_news.can_view_article(uuid) to authenticated;
grant execute on function nomad_news.current_reader_id(uuid) to authenticated;

grant execute on function nomad_news.request_newspaper(uuid, text, text, text, text, date, text, text, text, text, text, text) to authenticated;
grant execute on function nomad_news.withdraw_newspaper_request(uuid) to authenticated;
grant execute on function nomad_news.set_newspaper_profile(uuid, jsonb) to authenticated;
grant execute on function nomad_news.invite_staff(uuid, text, text, text, text) to authenticated;
grant execute on function nomad_news.accept_staff_invitation(text) to authenticated;
grant execute on function nomad_news.set_staff_role(uuid, uuid, text) to authenticated;
grant execute on function nomad_news.remove_staff(uuid, uuid) to authenticated;
grant execute on function nomad_news.update_my_staff_profile(uuid, jsonb) to authenticated;
grant execute on function nomad_news.upsert_taxonomy(uuid, text, uuid, jsonb) to authenticated;
grant execute on function nomad_news.save_article(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.submit_article(uuid) to authenticated;
grant execute on function nomad_news.review_article(uuid, text, text) to authenticated;
grant execute on function nomad_news.schedule_article(uuid, timestamptz) to authenticated;
grant execute on function nomad_news.publish_article(uuid) to authenticated;
grant execute on function nomad_news.unpublish_article(uuid, text) to authenticated;
grant execute on function nomad_news.archive_article(uuid) to authenticated;
grant execute on function nomad_news.record_article_correction(uuid, text, text, uuid) to authenticated;
grant execute on function nomad_news.save_media_asset(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.save_home_layout(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.publish_home_layout(uuid, timestamptz) to authenticated;
grant execute on function nomad_news.save_print_edition(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.add_live_update(uuid, text, boolean) to authenticated;
grant execute on function nomad_news.set_live_update_status(uuid, text, boolean) to authenticated;
grant execute on function nomad_news.ensure_reader(uuid, text, text, text, boolean, boolean) to authenticated;
grant execute on function nomad_news.withdraw_reader(uuid) to authenticated;
grant execute on function nomad_news.set_reader_status(uuid, text, text) to authenticated;
grant execute on function nomad_news.upsert_membership_tier(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.set_paywall_rule(uuid, jsonb) to authenticated;
grant execute on function nomad_news.upsert_ad_slot(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.upsert_advertiser(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.save_ad_campaign(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.save_ad_creative(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.review_ad_creative(uuid, text) to authenticated;
grant execute on function nomad_news.submit_listing(uuid, jsonb) to authenticated;
grant execute on function nomad_news.review_listing(uuid, text, text) to authenticated;
grant execute on function nomad_news.save_public_notice(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.upsert_newsletter_list(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.save_newsletter_issue(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.post_comment(uuid, text, uuid) to authenticated;
grant execute on function nomad_news.delete_my_comment(uuid) to authenticated;
grant execute on function nomad_news.report_comment(uuid, text, text, boolean) to authenticated;
grant execute on function nomad_news.moderate_comment(uuid, text, text) to authenticated;
grant execute on function nomad_news.set_tip_status(uuid, text, uuid, text) to authenticated;
grant execute on function nomad_news.submit_life_event(uuid, jsonb) to authenticated;
grant execute on function nomad_news.review_life_event(uuid, text, text) to authenticated;
grant execute on function nomad_news.upsert_wire_contract(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.set_syndication_settings(uuid, jsonb) to authenticated;
grant execute on function nomad_news.submit_correction_request(uuid, jsonb) to authenticated;
grant execute on function nomad_news.respond_correction_request(uuid, text, text) to authenticated;
grant execute on function nomad_news.compliance_weekly_stats(uuid, date) to authenticated;
grant execute on function nomad_news.upsert_election_period(uuid, uuid, jsonb) to authenticated;
grant execute on function nomad_news.save_event(uuid, uuid, jsonb) to authenticated;

-- =====================================================================
-- 13. 스케줄 (워커 크론이 service_role 로 호출하거나 pg_cron. 로컬 검증에서는 실행하지 않는다)
--   매분                       : select nomad_news.run_scheduled_publishing();   -- 예약 기사·예약 홈 편집 게시(구독 끊김이면 되돌림)
--   매시 5분                   : 조회 집계 롤업·오래된 시간 버킷 정리(워커, 90일 초과 버킷 삭제 제안)
--   매일 03:40 KST (40 18 * * *): 제보 보존 만료 삭제, 정정 기한 초과 알림, 수신동의 2년 재확인 대상 발송(워커)
-- 원본 14절: 플랜 시드는 파일 머리(기능 이용권, 수치 시드 없음), AI 라우팅은 org/0002_ai.sql.
-- =====================================================================

commit;
