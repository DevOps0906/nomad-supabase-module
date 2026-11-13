-- website-floria 이식 · 조직형(org안). 원본: platform-docs _supabase-modular/migrations/2200_site.sql 1~10절(AI·음성은 0002_ai.sql)
-- core.organizations→nomad_core.organizations(org_id→organization_id), org_members→nomad_core.memberships(member→editor),
-- has_entitlement→nomad_core.has_feature / org_has_feature(기능 코드 floria/site). 대응표: products/floria/existing.md
-- 전제: nomad_core.touch_updated_at() (core 20261119000100). 되돌림: drop schema nomad_floria cascade;
begin;

create schema nomad_floria;
revoke all on schema nomad_floria from public, anon, authenticated;
grant usage on schema nomad_floria to anon, authenticated, service_role;

insert into nomad_core.products (code, name) values ('floria', 'Website Floria') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('floria', 'A', 'A'), ('floria', 'B', 'B'), ('floria', 'C', 'C') on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values ('floria', 'site', '브랜드 사이트 문의·뉴스레터') on conflict do nothing;
-- 구독이 끊기면 잠긴다: 구독 없음·만료·inactive는 C로 취급(core 규칙)되므로 C에는 site를 두지 않는다.
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('floria', 'A', 'site'), ('floria', 'B', 'site') on conflict do nothing;

-- ---------- 공통 도우미: nomad_core 사용(제품 사본 없음) ----------
-- 서버 판정 nomad_core.is_service_caller() · 요청 제한 nomad_core.rate_limit_take(키 접두사 'floria:', 정리는 purge_rate_limit_buckets 스케줄)
-- · 감사 nomad_core.write_audit(→ nomad_core.audit_log, 콘솔 조회는 public.nomad_audit_log).

-- ---------- 1. sites: 사이트 등록부 (쓰기는 provision_site·update_site_settings·update_ai_settings RPC뿐) ----------
create table nomad_floria.sites (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references nomad_core.organizations(id) on delete cascade,
  slug                   text not null unique
                         constraint sites_slug_check check (slug ~ '^[a-z][a-z0-9-]{1,38}[a-z0-9]$'),
  name                   text not null constraint sites_name_check check (char_length(name) between 1 and 80),
  brand_key              text not null default 'floria'
                         constraint sites_brand_key_check check (brand_key ~ '^[a-z][a-z0-9_]{1,30}$'),
  allowed_origins        text[] not null default '{}'
                         constraint sites_allowed_origins_check check (cardinality(allowed_origins) <= 10),
  notify_email           text
                         constraint sites_notify_email_check check (notify_email is null or (char_length(notify_email) <= 254 and notify_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  accepts_inquiries      boolean not null default true,
  accepts_newsletter     boolean not null default true,
  inquiry_retention_days integer not null default 365
                         constraint sites_retention_check check (inquiry_retention_days between 30 and 1095),
  privacy_policy_version text not null default 'v1'
                         constraint sites_policy_version_check check (char_length(privacy_policy_version) between 1 and 32),
  status                 text not null default 'active'
                         constraint sites_status_check check (status in ('active', 'paused')),
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on table nomad_floria.sites is '브랜드 사이트 등록부. 한 백엔드를 여러 사이트가 공유. 쓰기는 RPC 전용.';
comment on column nomad_floria.sites.inquiry_retention_days is '문의 보존 일수(제안 기본 365). spam 상태는 30일. purge_expired 가 삭제한다';
comment on column nomad_floria.sites.privacy_policy_version is '폼이 보여 준 개인정보 수집 동의 문구의 버전. 다르면 SI004 로 거부한다';
create index sites_org_idx on nomad_floria.sites (organization_id, updated_at);
create trigger sites_touch before update on nomad_floria.sites
  for each row execute function nomad_core.touch_updated_at();
alter table nomad_floria.sites enable row level security;

-- ---------- 2. inquiries: 문의 (new -> read -> replied -> archived, new/read -> spam, spam -> new) ----------
create table nomad_floria.inquiries (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  site_id            uuid not null references nomad_floria.sites(id) on delete cascade,
  kind               text not null
                     constraint inquiries_kind_check check (kind in ('custom_order', 'wedding', 'corporate', 'workshop', 'subscription', 'press', 'other')),
  name               text not null constraint inquiries_name_check check (char_length(name) between 1 and 80),
  email              text not null
                     constraint inquiries_email_check check (char_length(email) <= 254 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  phone              text constraint inquiries_phone_check check (phone is null or phone ~ '^[0-9+() -]{6,30}$'),
  message            text not null constraint inquiries_message_check check (char_length(message) between 10 and 2000),
  locale             text not null default 'ko' constraint inquiries_locale_check check (locale in ('ko', 'en')),
  source_path        text constraint inquiries_source_path_check check (source_path is null or (char_length(source_path) <= 200 and source_path like '/%')),
  consent_version    text not null,
  consent_at         timestamptz not null default now(),
  status             text not null default 'new'
                     constraint inquiries_status_check check (status in ('new', 'read', 'replied', 'archived', 'spam')),
  spam_score         smallint not null default 0 constraint inquiries_spam_score_check check (spam_score between 0 and 100),
  spam_reasons       text[] not null default '{}',
  staff_note         text constraint inquiries_staff_note_check check (staff_note is null or char_length(staff_note) <= 1000),
  notified_at        timestamptz,
  read_at            timestamptz,
  replied_at         timestamptz,
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table nomad_floria.inquiries is '방문자 문의(개인정보). 쓰기는 submit_inquiry·set_inquiry_status RPC 전용, 읽기는 owner/admin/editor.';
create index inquiries_site_status_idx on nomad_floria.inquiries (site_id, status, created_at desc);
create index inquiries_org_created_idx on nomad_floria.inquiries (organization_id, created_at desc);
create index inquiries_org_updated_idx on nomad_floria.inquiries (organization_id, updated_at);
create index inquiries_created_idx on nomad_floria.inquiries (created_at);
create index inquiries_notify_idx on nomad_floria.inquiries (created_at) where notified_at is null and status = 'new';
create trigger inquiries_touch before update on nomad_floria.inquiries
  for each row execute function nomad_core.touch_updated_at();
alter table nomad_floria.inquiries enable row level security;

create function nomad_floria.inquiry_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not (
         (old.status = 'new'      and new.status in ('read', 'replied', 'spam', 'archived'))
      or (old.status = 'read'     and new.status in ('new', 'replied', 'spam', 'archived'))
      or (old.status = 'replied'  and new.status = 'archived')
      or (old.status = 'archived' and new.status = 'read')
      or (old.status = 'spam'     and new.status = 'new')
    ) then
      raise exception 'inquiry: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'read'     and new.read_at     is null then new.read_at     := now(); end if;
    if new.status = 'replied'  then new.replied_at  := now(); if new.read_at is null then new.read_at := now(); end if; end if;
    if new.status = 'archived' then new.archived_at := now(); end if;
    if new.status = 'new'      then new.read_at := null; end if;
  end if;
  return new;
end;
$$;
create trigger inquiries_transition before update on nomad_floria.inquiries
  for each row execute function nomad_floria.inquiry_status_transition();

-- ---------- 3. newsletter_subscribers: 이중 동의(pending -> confirmed), 토큰은 DB에 저장하지 않음 ----------
create table nomad_floria.newsletter_subscribers (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  site_id             uuid not null references nomad_floria.sites(id) on delete cascade,
  email               text
                      constraint newsletter_email_check check (email is null or (char_length(email) <= 254 and email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  email_hash          text not null constraint newsletter_email_hash_check check (email_hash ~ '^[0-9a-f]{64}$'),
  locale              text not null default 'ko' constraint newsletter_locale_check check (locale in ('ko', 'en')),
  status              text not null default 'pending'
                      constraint newsletter_status_check check (status in ('pending', 'confirmed', 'unsubscribed')),
  consent_version     text not null,
  consent_at          timestamptz not null default now(),
  source_path         text constraint newsletter_source_path_check check (source_path is null or (char_length(source_path) <= 200 and source_path like '/%')),
  confirm_sent_at     timestamptz,
  confirm_sent_count  smallint not null default 0,
  confirmed_at        timestamptz,
  unsubscribed_at     timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint newsletter_email_present_check check (email is not null or status = 'unsubscribed'),
  unique (site_id, email_hash)
);
comment on table nomad_floria.newsletter_subscribers is '뉴스레터 구독자(개인정보). 쓰기는 service_role RPC 전용. 해지 30일 후 email 비우고 해시만 보존.';
create index newsletter_org_status_idx on nomad_floria.newsletter_subscribers (organization_id, status, created_at desc);
create index newsletter_org_updated_idx on nomad_floria.newsletter_subscribers (organization_id, updated_at);
create index newsletter_purge_idx on nomad_floria.newsletter_subscribers (status, updated_at);
create trigger newsletter_touch before update on nomad_floria.newsletter_subscribers
  for each row execute function nomad_core.touch_updated_at();
alter table nomad_floria.newsletter_subscribers enable row level security;

create function nomad_floria.newsletter_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not (
         (old.status = 'pending'      and new.status in ('confirmed', 'unsubscribed'))
      or (old.status = 'confirmed'    and new.status = 'unsubscribed')
      or (old.status = 'unsubscribed' and new.status = 'pending')
    ) then
      raise exception 'newsletter: invalid status transition % -> %', old.status, new.status using errcode = '22023';
    end if;
    if new.status = 'confirmed'    then new.confirmed_at := now(); end if;
    if new.status = 'unsubscribed' then new.unsubscribed_at := now(); end if;
    if new.status = 'pending'      then new.confirmed_at := null; new.unsubscribed_at := null; end if;
  end if;
  return new;
end;
$$;
create trigger newsletter_transition before update on nomad_floria.newsletter_subscribers
  for each row execute function nomad_floria.newsletter_status_transition();

-- ---------- 4. RLS: authenticated SELECT만. 쓰기 정책·권한 없음(RPC/service_role). 문의·구독자는 viewer 제외 ----------
create policy sites_select on nomad_floria.sites for select to authenticated
  using (nomad_core.organization_role(organization_id) is not null and nomad_core.has_feature(organization_id, 'floria', 'site'));
create policy inquiries_select on nomad_floria.inquiries for select to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'floria', 'site'));
create policy newsletter_select on nomad_floria.newsletter_subscribers for select to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'floria', 'site'));

revoke all on all tables in schema nomad_floria from public, anon, authenticated;
grant select on nomad_floria.sites, nomad_floria.inquiries, nomad_floria.newsletter_subscribers to authenticated;
grant select, insert, update, delete on all tables in schema nomad_floria to service_role;

-- ---------- 5. 공개 RPC (D8): submit_inquiry — 방문자(anon)의 유일한 쓰기 경로 ----------
-- 사이트 홍수 100/시간·500/일, 이메일(해시) 3/시간·6/일, 허니팟, 입력 검증, 스팸 점수. IP 제한·CAPTCHA는 앞단 Route Handler 몫(IP는 받지도 저장하지도 않음).
-- 접수·스팸·허니팟 모두 같은 형식으로 응답한다.
create function nomad_floria.submit_inquiry(
  p_site_slug text, p_kind text, p_name text, p_email text, p_phone text, p_message text,
  p_locale text, p_consent_version text, p_source_path text default null,
  p_honeypot text default null, p_elapsed_ms integer default null
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_site nomad_floria.sites; v_email text; v_name text; v_message text; v_phone text; v_hash text;
  v_score integer := 0; v_reasons text[] := '{}'; v_links integer; v_id uuid;
begin
  select * into v_site from nomad_floria.sites where slug = lower(coalesce(p_site_slug, ''));
  if not found or v_site.status <> 'active' or not v_site.accepts_inquiries
     or not nomad_core.org_has_feature(v_site.organization_id, 'floria', 'site') then
    raise exception 'submit_inquiry: site unavailable' using errcode = 'SI002';
  end if;
  -- 한도 초과는 raise 대신 {ok:false} 로 반환한다(raise 면 카운터 증가가 롤백돼 한도가 쌓이지 않는다)
  if not (select allowed from nomad_core.rate_limit_take('floria:inq:flood:' || v_site.id::text, 100, 3600)) then
    return jsonb_build_object('ok', false, 'code', 'SI001');
  end if;
  if coalesce(btrim(p_honeypot), '') <> '' then
    return jsonb_build_object('ok', true, 'reference', null);
  end if;
  v_email   := lower(btrim(coalesce(p_email, '')));
  v_name    := btrim(coalesce(p_name, ''));
  v_message := btrim(coalesce(p_message, ''));
  v_phone   := nullif(btrim(coalesce(p_phone, '')), '');
  if p_kind is null or p_kind not in ('custom_order', 'wedding', 'corporate', 'workshop', 'subscription', 'press', 'other') then
    raise exception 'submit_inquiry: invalid kind' using errcode = 'SI003';
  end if;
  if char_length(v_name) not between 1 and 80
     or char_length(v_email) > 254 or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     or char_length(v_message) not between 10 and 2000
     or (v_phone is not null and v_phone !~ '^[0-9+() -]{6,30}$')
     or coalesce(p_locale, '') not in ('ko', 'en')
     or (p_source_path is not null and (char_length(p_source_path) > 200 or p_source_path not like '/%')) then
    raise exception 'submit_inquiry: invalid input' using errcode = 'SI003';
  end if;
  if p_consent_version is distinct from v_site.privacy_policy_version then
    raise exception 'submit_inquiry: consent missing or outdated' using errcode = 'SI004';
  end if;
  v_hash := encode(extensions.digest(convert_to(v_email, 'UTF8'), 'sha256'), 'hex');
  if not (select allowed from nomad_core.rate_limit_take('floria:inq:email:' || v_site.id::text || ':' || v_hash, 3, 3600))
     or not (select allowed from nomad_core.rate_limit_take('floria:inq:emailday:' || v_site.id::text || ':' || v_hash, 6, 86400))
     or not (select allowed from nomad_core.rate_limit_take('floria:inq:day:' || v_site.id::text, 500, 86400)) then
    return jsonb_build_object('ok', false, 'code', 'SI001');
  end if;
  if p_elapsed_ms is null then
    v_score := v_score + 30; v_reasons := array_append(v_reasons, 'no_timing');
  elsif p_elapsed_ms < 3000 then
    v_score := v_score + 60; v_reasons := array_append(v_reasons, 'too_fast');
  end if;
  v_links := (char_length(v_message) - char_length(replace(lower(v_message), 'http', ''))) / 4;
  if v_links > 2 then v_score := v_score + 50; v_reasons := array_append(v_reasons, 'many_links'); end if;
  if v_message ~* '<[a-z/!]' then v_score := v_score + 50; v_reasons := array_append(v_reasons, 'html_tags'); end if;
  v_score := least(v_score, 100);
  insert into nomad_floria.inquiries (organization_id, site_id, kind, name, email, phone, message, locale, source_path,
                                      consent_version, status, spam_score, spam_reasons)
  values (v_site.organization_id, v_site.id, p_kind, v_name, v_email, v_phone, v_message, p_locale, p_source_path,
          p_consent_version, case when v_score >= 60 then 'spam' else 'new' end, v_score, v_reasons)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'reference', upper(left(replace(v_id::text, '-', ''), 8)));
end;
$$;

-- ---------- 6. 뉴스레터 RPC (service_role 전용: 확인 메일 발송은 Route Handler 가 호출) ----------
create function nomad_floria.subscribe_newsletter(
  p_site_slug text, p_email text, p_locale text, p_consent_version text,
  p_source_path text default null, p_honeypot text default null, p_elapsed_ms integer default null
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_site nomad_floria.sites; v_email text; v_hash text; v_row nomad_floria.newsletter_subscribers; v_send boolean := false;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'subscribe_newsletter: service_role only' using errcode = '42501';
  end if;
  select * into v_site from nomad_floria.sites where slug = lower(coalesce(p_site_slug, ''));
  if not found or v_site.status <> 'active' or not v_site.accepts_newsletter
     or not nomad_core.org_has_feature(v_site.organization_id, 'floria', 'site') then
    raise exception 'subscribe_newsletter: site unavailable' using errcode = 'SI002';
  end if;
  if not (select allowed from nomad_core.rate_limit_take('floria:nl:flood:' || v_site.id::text, 200, 3600)) then
    raise exception 'subscribe_newsletter: rate limited' using errcode = 'SI001';
  end if;
  if coalesce(btrim(p_honeypot), '') <> '' or (p_elapsed_ms is not null and p_elapsed_ms < 1500) then
    return jsonb_build_object('ok', true, 'subscriber_id', null, 'status', 'pending', 'send_confirmation', false);
  end if;
  v_email := lower(btrim(coalesce(p_email, '')));
  if char_length(v_email) > 254 or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     or coalesce(p_locale, '') not in ('ko', 'en')
     or (p_source_path is not null and (char_length(p_source_path) > 200 or p_source_path not like '/%')) then
    raise exception 'subscribe_newsletter: invalid input' using errcode = 'SI003';
  end if;
  if p_consent_version is distinct from v_site.privacy_policy_version then
    raise exception 'subscribe_newsletter: consent missing or outdated' using errcode = 'SI004';
  end if;
  v_hash := encode(extensions.digest(convert_to(v_email, 'UTF8'), 'sha256'), 'hex');
  if not (select allowed from nomad_core.rate_limit_take('floria:nl:email:' || v_site.id::text || ':' || v_hash, 3, 3600)) then
    raise exception 'subscribe_newsletter: rate limited' using errcode = 'SI001';
  end if;
  select * into v_row from nomad_floria.newsletter_subscribers where site_id = v_site.id and email_hash = v_hash for update;
  if not found then
    insert into nomad_floria.newsletter_subscribers (organization_id, site_id, email, email_hash, locale, status, consent_version, source_path,
                                                     confirm_sent_at, confirm_sent_count)
    values (v_site.organization_id, v_site.id, v_email, v_hash, p_locale, 'pending', p_consent_version, p_source_path, now(), 1)
    returning * into v_row;
    v_send := true;
  elsif v_row.status = 'pending' then
    if v_row.confirm_sent_count < 5 then
      update nomad_floria.newsletter_subscribers
         set confirm_sent_at = now(), confirm_sent_count = confirm_sent_count + 1,
             consent_version = p_consent_version, consent_at = now(), locale = p_locale
       where id = v_row.id returning * into v_row;
      v_send := true;
    end if;
  elsif v_row.status = 'unsubscribed' then
    update nomad_floria.newsletter_subscribers
       set status = 'pending', email = v_email, locale = p_locale, consent_version = p_consent_version, consent_at = now(),
           source_path = p_source_path, confirm_sent_at = now(), confirm_sent_count = 1
     where id = v_row.id returning * into v_row;
    v_send := true;
  end if;
  return jsonb_build_object('ok', true, 'subscriber_id', v_row.id, 'status', v_row.status, 'send_confirmation', v_send);
end;
$$;

create function nomad_floria.confirm_newsletter(p_subscriber_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.newsletter_subscribers;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'confirm_newsletter: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_floria.newsletter_subscribers where id = p_subscriber_id for update;
  if not found then raise exception 'confirm_newsletter: not found' using errcode = 'P0002'; end if;
  if v_row.status = 'pending' then
    update nomad_floria.newsletter_subscribers set status = 'confirmed' where id = v_row.id returning * into v_row;
    return jsonb_build_object('ok', true, 'status', v_row.status, 'changed', true);
  end if;
  return jsonb_build_object('ok', true, 'status', v_row.status, 'changed', false);
end;
$$;

create function nomad_floria.unsubscribe_newsletter(p_subscriber_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.newsletter_subscribers;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'unsubscribe_newsletter: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_floria.newsletter_subscribers where id = p_subscriber_id for update;
  if not found then raise exception 'unsubscribe_newsletter: not found' using errcode = 'P0002'; end if;
  if v_row.status in ('pending', 'confirmed') then
    update nomad_floria.newsletter_subscribers set status = 'unsubscribed' where id = v_row.id returning * into v_row;
    return jsonb_build_object('ok', true, 'status', v_row.status, 'changed', true);
  end if;
  return jsonb_build_object('ok', true, 'status', v_row.status, 'changed', false);
end;
$$;

-- ---------- 7. 운영 RPC (authenticated: 조직 멤버, 안에서 역할·기능 검사) ----------
create function nomad_floria.set_inquiry_status(p_id uuid, p_to text, p_note text default null)
returns nomad_floria.inquiries language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.inquiries; v_from text;
begin
  select * into v_row from nomad_floria.inquiries where id = p_id for update;
  if not found then raise exception 'set_inquiry_status: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller() then
    if coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin', 'editor') then
      raise exception 'set_inquiry_status: not a member' using errcode = '42501';
    end if;
    if not nomad_core.has_feature(v_row.organization_id, 'floria', 'site') then
      raise exception 'set_inquiry_status: no entitlement' using errcode = '42501';
    end if;
  end if;
  if p_to is null or p_to not in ('new', 'read', 'replied', 'archived', 'spam') then
    raise exception 'set_inquiry_status: invalid status %', p_to using errcode = '22023';
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    raise exception 'set_inquiry_status: note too long' using errcode = '22023';
  end if;
  v_from := v_row.status;
  update nomad_floria.inquiries set status = p_to, staff_note = coalesce(p_note, staff_note)
   where id = p_id returning * into v_row;
  if v_from is distinct from v_row.status then
    perform nomad_core.write_audit(v_row.organization_id, 'inquiry.status', 'inquiry', p_id::text,
                                             jsonb_build_object('status', v_from), jsonb_build_object('status', v_row.status));
  end if;
  return v_row;
end;
$$;

-- 기능 잠금(floria/site)을 일부러 보지 않는다: 구독이 끊긴 조직도 개인정보 삭제 요청은 처리할 수 있어야 한다(owner/admin·서버).
create function nomad_floria.delete_inquiry(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.inquiries;
begin
  select * into v_row from nomad_floria.inquiries where id = p_id for update;
  if not found then raise exception 'delete_inquiry: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller()
     and coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin') then
    raise exception 'delete_inquiry: owner/admin only' using errcode = '42501';
  end if;
  delete from nomad_floria.inquiries where id = p_id;
  -- 감사 로그에는 개인정보를 남기지 않는다(종류·상태·접수일만)
  perform nomad_core.write_audit(v_row.organization_id, 'inquiry.delete', 'inquiry', p_id::text,
                                           jsonb_build_object('kind', v_row.kind, 'status', v_row.status, 'created_at', v_row.created_at), null);
end;
$$;

-- 구독자 삭제 요청(delete_inquiry와 같이 기능 잠금 없음 — 잠긴 조직도 개인정보 삭제 허용): 이메일 원문을 지우고 해시와 해지 상태만 남긴다(재발송 방지 이력)
create function nomad_floria.erase_subscriber(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.newsletter_subscribers;
begin
  select * into v_row from nomad_floria.newsletter_subscribers where id = p_id for update;
  if not found then raise exception 'erase_subscriber: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller()
     and coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin') then
    raise exception 'erase_subscriber: owner/admin only' using errcode = '42501';
  end if;
  if v_row.status <> 'unsubscribed' then
    update nomad_floria.newsletter_subscribers set status = 'unsubscribed' where id = p_id;
  end if;
  update nomad_floria.newsletter_subscribers set email = null where id = p_id;
  perform nomad_core.write_audit(v_row.organization_id, 'subscriber.erase', 'subscriber', p_id::text,
                                           jsonb_build_object('status', v_row.status), jsonb_build_object('status', 'unsubscribed'));
end;
$$;

create function nomad_floria.update_site_settings(
  p_site_id uuid, p_name text default null, p_notify_email text default null,
  p_accepts_inquiries boolean default null, p_accepts_newsletter boolean default null,
  p_privacy_policy_version text default null
)
returns nomad_floria.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.sites; v_before jsonb;
begin
  select * into v_row from nomad_floria.sites where id = p_site_id for update;
  if not found then raise exception 'update_site_settings: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller() then
    if coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin') then
      raise exception 'update_site_settings: owner/admin only' using errcode = '42501';
    end if;
    if not nomad_core.has_feature(v_row.organization_id, 'floria', 'site') then
      raise exception 'update_site_settings: no entitlement' using errcode = '42501';
    end if;
  end if;
  v_before := jsonb_build_object('name', v_row.name, 'accepts_inquiries', v_row.accepts_inquiries,
                                 'accepts_newsletter', v_row.accepts_newsletter, 'privacy_policy_version', v_row.privacy_policy_version);
  update nomad_floria.sites
     set name = coalesce(p_name, name), notify_email = coalesce(p_notify_email, notify_email),
         accepts_inquiries = coalesce(p_accepts_inquiries, accepts_inquiries),
         accepts_newsletter = coalesce(p_accepts_newsletter, accepts_newsletter),
         privacy_policy_version = coalesce(p_privacy_policy_version, privacy_policy_version)
   where id = p_site_id returning * into v_row;
  perform nomad_core.write_audit(v_row.organization_id, 'site.settings', 'site', p_site_id::text, v_before,
                                           jsonb_build_object('name', v_row.name, 'accepts_inquiries', v_row.accepts_inquiries,
                                                              'accepts_newsletter', v_row.accepts_newsletter, 'privacy_policy_version', v_row.privacy_policy_version));
  return v_row;
end;
$$;

-- ---------- 8. 운영 RPC (service_role 전용): 사이트 등록, 만료 정리 ----------
create function nomad_floria.provision_site(
  p_organization_id uuid, p_slug text, p_name text, p_brand_key text default 'floria',
  p_allowed_origins text[] default '{}', p_notify_email text default null
)
returns nomad_floria.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.sites;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'provision_site: service_role only' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(p_organization_id, 'floria', 'site') then
    raise exception 'provision_site: organization has no site entitlement' using errcode = '42501';
  end if;
  insert into nomad_floria.sites (organization_id, slug, name, brand_key, allowed_origins, notify_email)
  values (p_organization_id, lower(p_slug), p_name, p_brand_key, coalesce(p_allowed_origins, '{}'), p_notify_email)
  returning * into v_row;
  perform nomad_core.write_audit(p_organization_id, 'site.provision', 'site', v_row.id::text, null,
                                           jsonb_build_object('slug', v_row.slug, 'brand_key', v_row.brand_key));
  return v_row;
end;
$$;

-- 매일 실행(pg_cron 또는 워커, service_role). 호스팅에서 pg_cron 켠 뒤: select cron.schedule('floria-purge-expired', '30 18 * * *', $$select nomad_floria.purge_expired()$$);
-- 문의 알림 메일은 DB 함수가 아니라 워커가 처리: select id, site_id from nomad_floria.inquiries where notified_at is null and status = 'new' order by created_at limit 50; 발송 후 notified_at 갱신.
create function nomad_floria.purge_expired()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_inq integer; v_pending integer; v_unsub integer;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'purge_expired: service_role only' using errcode = '42501';
  end if;
  delete from nomad_floria.inquiries i using nomad_floria.sites s
   where i.site_id = s.id
     and ((i.status = 'spam' and i.created_at < now() - interval '30 days')
          or i.created_at < now() - make_interval(days => s.inquiry_retention_days));
  get diagnostics v_inq = row_count;
  delete from nomad_floria.newsletter_subscribers where status = 'pending' and created_at < now() - interval '7 days';
  get diagnostics v_pending = row_count;
  update nomad_floria.newsletter_subscribers set email = null
   where status = 'unsubscribed' and email is not null and unsubscribed_at < now() - interval '30 days';
  get diagnostics v_unsub = row_count;
  if v_inq + v_pending + v_unsub > 0 then
    perform nomad_core.write_audit(null, 'site.purge', 'site', null, null,
                                             jsonb_build_object('inquiries', v_inq, 'pending_subscribers', v_pending, 'anonymized_subscribers', v_unsub));
  end if;
  return jsonb_build_object('inquiries', v_inq, 'pending_subscribers', v_pending, 'anonymized_subscribers', v_unsub);
end;
$$;

-- ---------- 9. EXECUTE 정리: 전부 회수 후 허용 목록만 ----------
-- anon·authenticated·service_role: submit_inquiry / authenticated·service_role: 운영 RPC / service_role 전용: 나머지
revoke all on function
  nomad_floria.submit_inquiry(text, text, text, text, text, text, text, text, text, text, integer),
  nomad_floria.subscribe_newsletter(text, text, text, text, text, text, integer),
  nomad_floria.confirm_newsletter(uuid), nomad_floria.unsubscribe_newsletter(uuid),
  nomad_floria.set_inquiry_status(uuid, text, text), nomad_floria.delete_inquiry(uuid), nomad_floria.erase_subscriber(uuid),
  nomad_floria.update_site_settings(uuid, text, text, boolean, boolean, text),
  nomad_floria.provision_site(uuid, text, text, text, text[], text), nomad_floria.purge_expired(),
  nomad_floria.inquiry_status_transition(), nomad_floria.newsletter_status_transition()
  from public, anon, authenticated;
grant execute on function nomad_floria.submit_inquiry(text, text, text, text, text, text, text, text, text, text, integer) to anon, authenticated, service_role;
grant execute on function
  nomad_floria.set_inquiry_status(uuid, text, text), nomad_floria.delete_inquiry(uuid), nomad_floria.erase_subscriber(uuid),
  nomad_floria.update_site_settings(uuid, text, text, boolean, boolean, text)
  to authenticated, service_role;
grant execute on function
  nomad_floria.subscribe_newsletter(text, text, text, text, text, text, integer),
  nomad_floria.confirm_newsletter(uuid), nomad_floria.unsubscribe_newsletter(uuid),
  nomad_floria.provision_site(uuid, text, text, text, text[], text), nomad_floria.purge_expired()
  to service_role;

commit;
