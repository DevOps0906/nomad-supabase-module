-- astro-ai(신비로운AI) 이식 · 개인형(user안). 원본: platform-docs _supabase-modular/migrations/1100_astro.sql 1~12절(13절 AI는 0002_ai.sql)
-- 소유 = auth.users(user_id), RLS user_id = auth.uid(). 원본 org_id(1인 조직)→user_id. 크레딧·작업·감사는 코어가 조직 단위이므로
-- 사용자의 개인 조직(owner, kind personal)을 쓴다(nomad_astro.personal_organization). 잠금: 개인 조직의 nomad_core.org_has_feature('astro', 'reading')(과금 조직과 같은 조직).
-- guard_privileged_write→권한(GRANT) 미부여로 대체, themes anon 직접 읽기→공개 definer RPC list_themes(D8). 대응표: products/astro/existing.md
-- 기존 nomad_personal(사주 등)과 별도 제품(D4). 전제: nomad_core.touch_updated_at() (core 20261119000100). 되돌림: drop schema nomad_astro cascade;
begin;

create schema nomad_astro;
revoke all on schema nomad_astro from public, anon, authenticated;
grant usage on schema nomad_astro to anon, authenticated, service_role;

insert into nomad_core.products (code, name) values ('astro', '신비로운AI') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('astro', 'A', 'A'), ('astro', 'B', 'B'), ('astro', 'C', 'C') on conflict do nothing;
-- 원본은 무료 starter 플랜 하나(크레딧팩 과금)뿐이고 리딩 기능이 모두 들어 있다 → 원본 무료 기능 = C까지 연다.
-- 구독이 끊겨도(C 취급) 리딩은 크레딧으로 계속 쓴다. 잠기는 경우는 활성 개인(owner) 조직이 없을 때뿐.
insert into nomad_core.features (product_code, code, name) values ('astro', 'reading', '사주·타로 리딩, 프로필 보관함, PDF·이메일 발송')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('astro', 'A', 'reading'), ('astro', 'B', 'reading'), ('astro', 'C', 'reading') on conflict do nothing;
-- plan_limits 키(수치 시드 안 함): max_subjects(원본 20) · welcome_credits(원본 30, 서버가 grant_credits 멱등 키 signup:<org>:astro로 지급)

-- 개인 조직: 코어(기능 판정·감사·크레딧·작업)는 모두 이 조직 하나로 본다(내부, API 역할 실행 권한 없음).
create function nomad_astro.personal_organization(p_user uuid) returns uuid
language sql stable security definer set search_path = ''
as $$
  select o.id from nomad_core.organizations o
    join nomad_core.memberships m on m.organization_id = o.id and m.user_id = p_user and m.role = 'owner'
   where o.kind = 'personal' and o.active
   order by o.created_at limit 1
$$;

-- 정책 도우미: 본인 행 + 개인 조직 이용권(과금 조직과 같은 조직)
create function nomad_astro.has_access(p_user uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_user is not null and p_user = (select auth.uid())
     and coalesce(nomad_core.org_has_feature(nomad_astro.personal_organization(p_user), 'astro', 'reading'), false)
$$;

-- ---------- 1. themes: PDF 테마 레지스트리 (전역, 쓰기 service_role) ----------
create table nomad_astro.themes (
  key          text primary key constraint themes_key_check check (key ~ '^[a-z][a-z0-9-]{1,40}$'),
  name         text not null,
  config       jsonb not null constraint themes_config_check check (jsonb_typeof(config) = 'object'),
  tier         text not null default 'basic' constraint themes_tier_check check (tier in ('basic', 'premium')),
  is_active    boolean not null default true,
  sort_order   integer not null default 0,
  preview_path text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table nomad_astro.themes is 'PDF 테마(ThemeConfig). 로그인 사용자는 활성 테마 읽기, 비로그인은 list_themes RPC만.';

-- ---------- 2. subjects: 프로필 보관함 (이름·생년월일시는 앱 계층 AES-256-GCM 암호문만) ----------
create table nomad_astro.subjects (
  id                     uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  alias                  text not null constraint subjects_alias_check check (char_length(alias) between 1 and 20),
  relation               text not null constraint subjects_relation_check check (relation in ('self', 'family', 'partner', 'friend', 'other')),
  gender                 text not null constraint subjects_gender_check check (gender in ('male', 'female')),
  calendar_type          text not null default 'solar' constraint subjects_calendar_type_check check (calendar_type in ('solar', 'lunar')),
  is_leap_month          boolean not null default false,
  birth_time_unknown     boolean not null default false,
  zi_hour_mode           text not null default 'unified' constraint subjects_zi_hour_mode_check check (zi_hour_mode in ('unified', 'split')),
  birth_place_label      text constraint subjects_birth_place_label_check check (char_length(birth_place_label) <= 40),
  birth_longitude        numeric(7,4) constraint subjects_birth_longitude_check check (birth_longitude between -180 and 180),
  name_ciphertext        text not null,
  birth_ciphertext       text not null,
  key_version            smallint not null constraint subjects_key_version_check check (key_version > 0),
  third_party_consent_at timestamptz,
  consent_version        text,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  deleted_at             timestamptz,
  constraint subjects_leap_check check (not is_leap_month or calendar_type = 'lunar'),
  constraint subjects_consent_check check (relation = 'self' or (third_party_consent_at is not null and consent_version is not null)),
  constraint subjects_id_user_uniq unique (id, user_id)
);
comment on table nomad_astro.subjects is '프로필 보관함(본인·가족·지인). 암호문 컬럼은 사용자에게 권한 없음. 쓰기는 서버만(암호화가 서버에서만 가능).';
create unique index subjects_one_self_per_user_idx on nomad_astro.subjects (user_id) where relation = 'self' and deleted_at is null;
create index subjects_user_created_idx on nomad_astro.subjects (user_id, created_at desc);
create index subjects_user_updated_idx on nomad_astro.subjects (user_id, updated_at);

-- ---------- 3. readings: 리딩 1건 = 크레딧 차감 1건(consume:astro:<request_id>) = 작업 1건(nomad_core.jobs) ----------
create table nomad_astro.readings (
  id                  uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  subject_id          uuid,
  kind                text not null constraint readings_kind_check check (kind in ('saju', 'tarot', 'combined')),
  theme_key           text not null references nomad_astro.themes(key),
  question_ciphertext text,
  key_version         smallint,
  tarot_cards         jsonb,
  chart               jsonb,
  engine_version      text,
  status              text not null default 'queued'
                      constraint readings_status_check check (status in ('queued', 'generating', 'rendering', 'completed', 'failed', 'canceled')),
  progress            smallint not null default 0 constraint readings_progress_check check (progress between 0 and 100),
  credits_charged     integer not null constraint readings_credits_check check (credits_charged >= 0),
  credit_ledger_id    uuid references nomad_core.credit_ledger(id),
  job_id              uuid references nomad_core.jobs(id) on delete set null,
  request_id          uuid not null,
  content             jsonb,
  content_chars       integer,
  current_render_id   uuid,
  error_code          text,
  error_message       text,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  started_at          timestamptz,
  completed_at        timestamptz,
  failed_at           timestamptz,
  canceled_at         timestamptz,
  constraint readings_request_uniq unique (request_id),
  constraint readings_id_user_uniq unique (id, user_id),
  constraint readings_subject_fk foreign key (subject_id, user_id) references nomad_astro.subjects (id, user_id) on delete cascade,
  constraint readings_subject_required_check check (kind = 'tarot' or subject_id is not null),
  constraint readings_tarot_cards_check check (
    (kind = 'saju' and tarot_cards is null)
    or (kind in ('tarot', 'combined') and jsonb_typeof(tarot_cards) = 'array' and jsonb_array_length(tarot_cards) = 3)
  ),
  constraint readings_question_key_check check (question_ciphertext is null or key_version is not null)
);
comment on table nomad_astro.readings is '리딩(사주·타로·통합). request_id 멱등, 상태 전이 트리거. 질문 암호문은 사용자 권한 없음.';
create index readings_user_created_idx on nomad_astro.readings (user_id, created_at desc);
create index readings_user_updated_idx on nomad_astro.readings (user_id, updated_at);
create index readings_subject_idx on nomad_astro.readings (subject_id) where subject_id is not null;
create index readings_active_idx on nomad_astro.readings (status, created_at) where status in ('queued', 'generating', 'rendering');

-- 상태 전이 강제(service_role 쓰기에도). 소유자·종류·과금 컬럼은 바꿀 수 없다.
create function nomad_astro.readings_check_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'queued' then
      raise exception 'readings: initial status must be queued (got %)', new.status using errcode = 'AS001';
    end if;
    return new;
  end if;
  if new.user_id <> old.user_id or new.kind <> old.kind or new.request_id <> old.request_id
     or new.credits_charged <> old.credits_charged
     or (new.credit_ledger_id is distinct from old.credit_ledger_id and old.credit_ledger_id is not null) then
    raise exception 'readings: immutable column changed' using errcode = 'AS001';
  end if;
  if new.status = old.status then return new; end if;
  if not (
       (old.status = 'queued'     and new.status in ('generating', 'failed', 'canceled'))
    or (old.status = 'generating' and new.status in ('rendering', 'queued', 'failed'))
    or (old.status = 'rendering'  and new.status in ('completed', 'queued', 'failed'))
  ) then
    raise exception 'readings: invalid transition % -> %', old.status, new.status using errcode = 'AS001';
  end if;
  if new.status = 'generating' and new.started_at is null then new.started_at := now(); end if;
  if new.status = 'completed' then new.completed_at := now(); new.progress := 100; end if;
  if new.status = 'failed'    then new.failed_at := now(); end if;
  if new.status = 'canceled'  then new.canceled_at := now(); end if;
  return new;
end;
$$;
create trigger readings_check_transition before insert or update on nomad_astro.readings
  for each row execute function nomad_astro.readings_check_transition();

-- ---------- 4. reading_renders: PDF 렌더 이력(최초 0cr + 테마 변경 재생성) ----------
create table nomad_astro.reading_renders (
  id               uuid primary key default gen_random_uuid(),
  user_id  uuid not null references auth.users(id) on delete cascade,
  reading_id       uuid not null,
  theme_key        text not null references nomad_astro.themes(key),
  is_initial       boolean not null default false,
  status           text not null default 'queued' constraint reading_renders_status_check check (status in ('queued', 'rendering', 'succeeded', 'failed')),
  pdf_path         text constraint reading_renders_pdf_path_check check (pdf_path is null or pdf_path like (user_id::text || '/astro/pdf/%')),
  pdf_pages        integer,
  pdf_bytes        integer,
  credits_charged  integer not null default 0 constraint reading_renders_credits_check check (credits_charged >= 0),
  credit_ledger_id uuid references nomad_core.credit_ledger(id),
  job_id           uuid references nomad_core.jobs(id) on delete set null,
  request_id       uuid not null,
  error_code       text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  completed_at     timestamptz,
  constraint reading_renders_request_uniq unique (request_id),
  constraint reading_renders_id_user_uniq unique (id, user_id),
  constraint reading_renders_reading_fk foreign key (reading_id, user_id) references nomad_astro.readings (id, user_id) on delete cascade
);
comment on table nomad_astro.reading_renders is 'PDF 렌더 이력. 경로 <user_id>/astro/pdf/…(사용자 폴더), request_id 멱등.';
create index reading_renders_reading_idx on nomad_astro.reading_renders (reading_id, created_at desc);
create index reading_renders_user_idx on nomad_astro.reading_renders (user_id);
create unique index reading_renders_one_initial_idx on nomad_astro.reading_renders (reading_id) where is_initial;

-- 크레딧 원장·작업은 같은 소유자 개인 조직의 것만 연결한다(원장은 차감 행, 작업은 product astro).
create function nomad_astro.check_billing_links() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_org uuid := nomad_astro.personal_organization(new.user_id);
begin
  if new.credit_ledger_id is not null and not exists (
       select 1 from nomad_core.credit_ledger l where l.id = new.credit_ledger_id and l.organization_id = v_org and l.delta < 0) then
    raise exception '%: credit entry must be a consume of the same organization', tg_table_name using errcode = 'AS005';
  end if;
  if new.job_id is not null and not exists (
       select 1 from nomad_core.jobs j where j.id = new.job_id and j.organization_id = v_org and j.product_code = 'astro') then
    raise exception '%: job must belong to the same organization and product', tg_table_name using errcode = 'AS005';
  end if;
  return new;
end;
$$;
create trigger readings_check_billing before insert or update of credit_ledger_id, job_id, user_id on nomad_astro.readings
  for each row execute function nomad_astro.check_billing_links();
create trigger reading_renders_check_billing before insert or update of credit_ledger_id, job_id, user_id on nomad_astro.reading_renders
  for each row execute function nomad_astro.check_billing_links();

-- 결과가 전달되면(completed) 이후 작업 실패로 환불되지 않게 표시한다(nomad_core.mark_job_delivered).
create function nomad_astro.mark_delivered() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.job_id is not null and new.status is distinct from old.status and new.status in ('completed', 'succeeded') then
    perform nomad_core.mark_job_delivered(new.job_id);
  end if;
  return null;
end;
$$;
create trigger readings_mark_delivered after update of status on nomad_astro.readings
  for each row execute function nomad_astro.mark_delivered();
create trigger reading_renders_mark_delivered after update of status on nomad_astro.reading_renders
  for each row execute function nomad_astro.mark_delivered();
alter table nomad_astro.readings
  add constraint readings_current_render_fk foreign key (current_render_id) references nomad_astro.reading_renders (id) on delete set null;

create function nomad_astro.reading_renders_check_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'queued' then
      raise exception 'reading_renders: initial status must be queued' using errcode = 'AS001';
    end if;
    return new;
  end if;
  if new.user_id <> old.user_id or new.reading_id <> old.reading_id or new.credits_charged <> old.credits_charged then
    raise exception 'reading_renders: immutable column changed' using errcode = 'AS001';
  end if;
  if new.status = old.status then return new; end if;
  if not (
       (old.status = 'queued'    and new.status in ('rendering', 'failed'))
    or (old.status = 'rendering' and new.status in ('succeeded', 'queued', 'failed'))
  ) then
    raise exception 'reading_renders: invalid transition % -> %', old.status, new.status using errcode = 'AS001';
  end if;
  if new.status in ('succeeded', 'failed') then new.completed_at := now(); end if;
  if new.status = 'succeeded' and new.pdf_path is null then
    raise exception 'reading_renders: succeeded requires pdf_path' using errcode = 'AS001';
  end if;
  return new;
end;
$$;
create trigger reading_renders_check_transition before insert or update on nomad_astro.reading_renders
  for each row execute function nomad_astro.reading_renders_check_transition();

-- ---------- 5. deliveries: 발송 outbox(email). 재시도 5분 × 3회 ----------
create table nomad_astro.deliveries (
  id                   bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  reading_id           uuid not null,
  render_id            uuid not null,
  channel              text not null default 'email' constraint deliveries_channel_check check (channel in ('email')),
  status               text not null default 'pending' constraint deliveries_status_check check (status in ('pending', 'sending', 'sent', 'dead', 'skipped')),
  recipient_masked     text,
  recipient_ciphertext text,
  key_version          smallint,
  attempts             integer not null default 0,
  max_attempts         integer not null default 3 constraint deliveries_max_attempts_check check (max_attempts between 1 and 10),
  next_attempt_at      timestamptz not null default now(),
  locked_by            text,
  provider_message_id  text,
  last_error           text,
  sent_at              timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint deliveries_render_channel_uniq unique (render_id, channel),
  constraint deliveries_reading_fk foreign key (reading_id, user_id) references nomad_astro.readings (id, user_id) on delete cascade,
  constraint deliveries_render_fk foreign key (render_id, user_id) references nomad_astro.reading_renders (id, user_id) on delete cascade
);
comment on table nomad_astro.deliveries is '발송 outbox. 수신자 암호문은 사용자 권한 없음. 처리는 claim_due_deliveries·finish_delivery(service_role).';
comment on column nomad_astro.deliveries.last_error is '제공자 오류 코드만(예: smtp_451, bounce_hard). 응답 원문·수신자 주소 금지 — 사용자에게 보이는 컬럼(200자 절단)';
create index deliveries_due_idx on nomad_astro.deliveries (next_attempt_at) where status = 'pending';
create index deliveries_user_created_idx on nomad_astro.deliveries (user_id, created_at desc);

create function nomad_astro.deliveries_check_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('pending', 'skipped') then
      raise exception 'deliveries: initial status must be pending or skipped' using errcode = 'AS001';
    end if;
    return new;
  end if;
  if new.user_id <> old.user_id or new.render_id <> old.render_id then
    raise exception 'deliveries: immutable column changed' using errcode = 'AS001';
  end if;
  if new.status = old.status then return new; end if;
  if not (
       (old.status = 'pending' and new.status in ('sending', 'skipped', 'dead'))
    or (old.status = 'sending' and new.status in ('sent', 'pending', 'dead'))
    or (old.status = 'dead'    and new.status = 'pending')
  ) then
    raise exception 'deliveries: invalid transition % -> %', old.status, new.status using errcode = 'AS001';
  end if;
  if new.status = 'sent' then new.sent_at := now(); end if;
  return new;
end;
$$;
create trigger deliveries_check_transition before insert or update on nomad_astro.deliveries
  for each row execute function nomad_astro.deliveries_check_transition();

-- ---------- 6. consents: 동의 증빙(서버만 INSERT, 철회는 granted=false 새 행) ----------
create table nomad_astro.consents (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  subject_id      uuid references nomad_astro.subjects(id) on delete set null,
  kind            text not null constraint consents_kind_check check (kind in (
                    'terms_required', 'privacy_required', 'third_party_birth', 'overseas_transfer', 'marketing_email', 'voice_processing')),
  version         text not null,
  granted         boolean not null,
  ip_hash         text,
  created_at      timestamptz not null default now()
);
comment on table nomad_astro.consents is '동의 증빙(약관·개인정보·제3자 생년월일시·국외 이전·마케팅·음성). append-only, 쓰기 service_role.';
create index consents_user_idx on nomad_astro.consents (user_id, user_id, kind, created_at desc);

-- ---------- 7. preferences: 사용자별 설정(권한·과금·상태 컬럼 없음 → 본인 직접 쓰기) ----------
create table nomad_astro.preferences (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  default_theme_key      text not null default 'mystical-dark' references nomad_astro.themes(key),
  email_delivery_enabled boolean not null default true,
  updated_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on table nomad_astro.preferences is '사용자별 기본 테마·이메일 발송 on/off. 본인 직접 쓰기.';

-- ---------- 8. 트리거(updated_at) ----------
do $$
declare t text;
begin
  foreach t in array array['themes', 'subjects', 'readings', 'reading_renders', 'deliveries', 'preferences']
  loop
    execute format('create trigger %I_touch before update on nomad_astro.%I for each row execute function nomad_core.touch_updated_at()', t, t);
  end loop;
end $$;

-- ---------- 9. RLS·권한 ----------
do $$
declare t text;
begin
  foreach t in array array['themes', 'subjects', 'readings', 'reading_renders', 'deliveries', 'consents', 'preferences']
  loop
    execute format('alter table nomad_astro.%I enable row level security', t);
    execute format('revoke all on table nomad_astro.%I from public, anon, authenticated', t);
    execute format('grant all on table nomad_astro.%I to service_role', t);
  end loop;
end $$;

grant select on nomad_astro.themes to authenticated;
create policy themes_select on nomad_astro.themes for select to authenticated using (is_active);

-- subjects: 암호문 컬럼 제외 컬럼 권한
grant select (id, user_id, alias, relation, gender, calendar_type, is_leap_month, birth_time_unknown, zi_hour_mode,
              birth_place_label, birth_longitude, third_party_consent_at, consent_version, created_by, created_at, updated_at, deleted_at)
  on nomad_astro.subjects to authenticated;
create policy subjects_select on nomad_astro.subjects for select to authenticated using (nomad_astro.has_access(user_id));

-- readings: 질문 암호문 제외
grant select (id, user_id, subject_id, kind, theme_key, tarot_cards, chart, engine_version, status, progress,
              credits_charged, job_id, request_id, content, content_chars, current_render_id, error_code, error_message,
              created_by, created_at, updated_at, started_at, completed_at, failed_at, canceled_at)
  on nomad_astro.readings to authenticated;
create policy readings_select on nomad_astro.readings for select to authenticated using (nomad_astro.has_access(user_id));

grant select on nomad_astro.reading_renders to authenticated;
create policy reading_renders_select on nomad_astro.reading_renders for select to authenticated using (nomad_astro.has_access(user_id));

-- deliveries: 수신자 암호문 제외
grant select (id, user_id, reading_id, render_id, channel, status, recipient_masked, attempts, max_attempts,
              next_attempt_at, last_error, sent_at, created_at, updated_at)
  on nomad_astro.deliveries to authenticated;
create policy deliveries_select on nomad_astro.deliveries for select to authenticated using (nomad_astro.has_access(user_id));

-- consents: 본인 것만 읽기(잠김과 무관한 증빙)
grant select on nomad_astro.consents to authenticated;
create policy consents_select on nomad_astro.consents for select to authenticated
  using (user_id = (select auth.uid()));

grant select, insert (user_id, default_theme_key, email_delivery_enabled),
      update (default_theme_key, email_delivery_enabled) on nomad_astro.preferences to authenticated;
-- updated_by는 항상 실제 호출자(auth.uid())로 덮어쓴다(위조 금지).
create function nomad_astro.preferences_set_actor() returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_by := (select auth.uid());
  return new;
end;
$$;
create trigger preferences_set_actor before insert or update on nomad_astro.preferences
  for each row execute function nomad_astro.preferences_set_actor();
create policy preferences_select on nomad_astro.preferences for select to authenticated using (nomad_astro.has_access(user_id));
create policy preferences_insert on nomad_astro.preferences for insert to authenticated
  with check (nomad_astro.has_access(user_id));
create policy preferences_update on nomad_astro.preferences for update to authenticated
  using (nomad_astro.has_access(user_id))
  with check (nomad_astro.has_access(user_id));
-- DELETE 정책 없음: 사용자 삭제 cascade로만.

-- ---------- 10. 함수 ----------
-- 10.1 공개 테마 목록(anon 포함, D8 공개 RPC). 입력 없음·읽기 전용·고정 소량 결과라 DB 속도 제한은 두지 않는다(엣지 캐시·게이트웨이 제한 권장).
create function nomad_astro.list_themes()
returns table (key text, name text, config jsonb, tier text, sort_order integer, preview_path text)
language sql stable security definer set search_path = ''
as $$
  select t.key, t.name, t.config, t.tier, t.sort_order, t.preview_path
    from nomad_astro.themes t where t.is_active order by t.sort_order, t.key
$$;

-- 10.2 cancel_reading(authenticated, 본인): queued 리딩만 취소. 작업이 있으면 nomad_core.cancel_job, 없으면 원장 환불, 과금 근거가 없으면 거부.
create function nomad_astro.cancel_reading(p_reading_id uuid)
returns nomad_astro.readings language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_astro.readings;
begin
  select * into v_row from nomad_astro.readings where id = p_reading_id for update;
  if not found then raise exception 'cancel_reading: not found' using errcode = 'P0002'; end if;
  if not nomad_core.is_service_caller() then
    -- 남의 리딩은 존재 여부도 알리지 않는다
    if v_row.user_id is distinct from (select auth.uid()) then
      raise exception 'cancel_reading: not found' using errcode = 'P0002';
    end if;
    if not nomad_astro.has_access(v_row.user_id) then
      raise exception 'cancel_reading: no entitlement' using errcode = '42501';
    end if;
  end if;
  if v_row.status <> 'queued' then
    raise exception 'cancel_reading: only queued readings can be canceled (status=%)', v_row.status using errcode = 'AS002';
  end if;
  if v_row.job_id is not null then
    perform nomad_core.cancel_job(v_row.job_id);   -- 작업 취소 + 크레딧 환불 + job.cancel 감사
  elsif v_row.credit_ledger_id is not null then
    -- 작업 없이 차감만 된 리딩: core 환불 본문(refund_credits와 같은 동작, 멱등 키 reading:<id>)
    perform nomad_core.refund_credits_internal(v_row.credit_ledger_id, 'reading_canceled', 'reading:' || v_row.id::text);
  elsif v_row.credits_charged > 0 then
    raise exception 'cancel_reading: charged reading without credit entry cannot be refunded' using errcode = 'AS004';
  end if;
  update nomad_astro.readings set status = 'canceled', error_code = 'canceled_by_user'
   where id = p_reading_id returning * into v_row;
  perform nomad_core.write_audit(nomad_astro.personal_organization(v_row.user_id), 'reading.cancel', 'reading', p_reading_id::text);
  return v_row;
end;
$$;

-- 10.3 claim_due_deliveries(service_role): due 행을 SKIP LOCKED로 집는다.
create function nomad_astro.claim_due_deliveries(p_worker_id text, p_limit integer default 20)
returns setof nomad_astro.deliveries language plpgsql security definer set search_path = ''
as $$
begin
  if not nomad_core.is_service_caller() then
    raise exception 'claim_due_deliveries: service_role only' using errcode = '42501';
  end if;
  return query
  update nomad_astro.deliveries d
     set status = 'sending', attempts = d.attempts + 1, locked_by = p_worker_id
   where d.id in (
     select x.id from nomad_astro.deliveries x
      where x.status = 'pending' and x.next_attempt_at <= now()
      order by x.next_attempt_at
      limit greatest(p_limit, 1)
      for update skip locked)
  returning d.*;
end;
$$;

-- 10.4 finish_delivery(service_role): 성공 → sent, 실패 → 재시도(기본 5분 뒤), attempts 소진 → dead.
create function nomad_astro.finish_delivery(
  p_delivery_id bigint, p_ok boolean, p_error text default null, p_provider_message_id text default null,
  p_retry_after_seconds integer default 300
)
returns nomad_astro.deliveries language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_astro.deliveries;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'finish_delivery: service_role only' using errcode = '42501';
  end if;
  select * into v_row from nomad_astro.deliveries where id = p_delivery_id for update;
  if not found then raise exception 'finish_delivery: not found' using errcode = 'P0002'; end if;
  if v_row.status <> 'sending' then
    raise exception 'finish_delivery: delivery is not sending (status=%)', v_row.status using errcode = 'AS003';
  end if;
  if p_ok then
    update nomad_astro.deliveries set status = 'sent', provider_message_id = p_provider_message_id, last_error = null, locked_by = null
     where id = p_delivery_id returning * into v_row;
  elsif v_row.attempts >= v_row.max_attempts then
    update nomad_astro.deliveries set status = 'dead', last_error = left(p_error, 200), locked_by = null
     where id = p_delivery_id returning * into v_row;
  else
    update nomad_astro.deliveries
       set status = 'pending', last_error = left(p_error, 200), locked_by = null,
           next_attempt_at = now() + make_interval(secs => greatest(p_retry_after_seconds, 30))
     where id = p_delivery_id returning * into v_row;
  end if;
  return v_row;
end;
$$;

-- ---------- 11. Realtime: 진행률은 readings·reading_renders postgres_changes(RLS 적용) ----------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['readings', 'reading_renders']
    loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_astro' and tablename = t) then
        execute format('alter publication supabase_realtime add table nomad_astro.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ---------- 12. 참조 데이터: MVP 기본 테마 2종(팔레트는 초안) ----------
insert into nomad_astro.themes (key, name, config, tier, is_active, sort_order) values
  ('mystical-dark', '먹과 금박', '{"colors":{"background":"#16161D","primary":"#C9A45C","accent":"#7E8FB3","text":"#EDE7DA","muted":"#9A968C","border":"#2E2D36"},"typography":{"headline":"Noto Serif CJK KR","body":"Noto Sans CJK KR"},"pdf":{"pageSize":"A4","margins":{"top":22,"right":20,"bottom":24,"left":22},"coverStyle":"pillars-grid"}}'::jsonb, 'basic', true, 1),
  ('oracle-gold',   '한지와 주묵', '{"colors":{"background":"#F3EEE3","primary":"#8C2F25","accent":"#2F4A3A","text":"#22201C","muted":"#6F6A60","border":"#D8CFBD"},"typography":{"headline":"Noto Serif CJK KR","body":"Noto Sans CJK KR"},"pdf":{"pageSize":"A4","margins":{"top":22,"right":20,"bottom":24,"left":22},"coverStyle":"seal"}}'::jsonb, 'basic', true, 2)
on conflict (key) do nothing;

-- ---------- 13. 함수 권한: PUBLIC 회수 후 허용 목록만 ----------
revoke all on all functions in schema nomad_astro from public, anon, authenticated;
grant execute on all functions in schema nomad_astro to service_role;
revoke all on function nomad_astro.personal_organization(uuid) from service_role;
grant execute on function nomad_astro.has_access(uuid), nomad_astro.cancel_reading(uuid) to authenticated;
grant execute on function nomad_astro.list_themes() to anon, authenticated;

commit;
