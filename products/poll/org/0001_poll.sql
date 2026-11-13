-- live-poll 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/1800_poll.sql (core.* → nomad_core.*)
-- org_members→nomad_core.memberships(member→editor), org_id→organization_id, has_entitlement→nomad_core.has_feature('poll','host'),
-- plan features 수치→nomad_core.plan_limits 키(max_events·max_live_events·max_participants·polls_per_event·retention_days). 대응표: products/poll/existing.md
-- 결정 D8: 청중(무로그인)은 테이블 접근 없이 공개용 security definer RPC(anon 실행)만 쓴다. 입력 검증 + 제품 전용 요청 제한(nomad_poll_private.rate_limits).
-- AI·음성 기본값은 0002_ai.sql(core 웨이브 후). 전제: nomad_core.touch_updated_at() (core 20261119000100). pgcrypto는 extensions 스키마.
-- 되돌림: drop schema nomad_poll cascade; drop schema nomad_poll_private cascade; (realtime.messages 정책 poll_broadcast_read_member·poll_broadcast_read_audience 삭제)
begin;

create schema nomad_poll;
create schema nomad_poll_private;
comment on schema nomad_poll is 'live-poll: 실시간 청중 투표와 Q&A (API 노출)';
comment on schema nomad_poll_private is 'live-poll 내부(비노출): 요청 제한 카운터·호출자 판정·감사 기록';
revoke all on schema nomad_poll, nomad_poll_private from public, anon, authenticated;
grant usage on schema nomad_poll to anon, authenticated, service_role;
grant usage on schema nomad_poll_private to service_role;

insert into nomad_core.products (code, name) values ('poll', 'Live Poll') on conflict (code) do nothing;
-- 플랜 A/B/C 와 기능 잠금(수치 없음). 행사 진행 기능 'host'는 모든 플랜. 구독 없는 조직은 C(has_feature 규칙).
insert into nomad_core.plans (product_code, code, name) values ('poll', 'A', 'A'), ('poll', 'B', 'B'), ('poll', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values ('poll', 'host', '행사 진행') on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
  values ('poll', 'A', 'host'), ('poll', 'B', 'host'), ('poll', 'C', 'host') on conflict do nothing;

-- ---------------------------------------------------------------------
-- 0. 내부 도우미 (nomad_poll_private, 비노출)
-- ---------------------------------------------------------------------
-- 호출자가 서버(service_role·postgres)가 아니면 true. security definer 안에서도 role 설정은 유지되므로 클라이언트 판정에 쓸 수 있다.
create function nomad_poll_private.caller_is_client() returns boolean
language sql stable set search_path = ''
as $$
  select case
    when coalesce(current_setting('role', true), '') in ('service_role', 'postgres', 'supabase_admin') then false
    when coalesce(current_setting('role', true), '') in ('none', '') and session_user in ('postgres', 'supabase_admin') then false
    else true
  end
$$;

-- 진행자 권한: 서버는 통과, 클라이언트는 조직 역할이 p_roles 안일 때만.
create function nomad_poll_private.host_ok(p_org uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = ''
as $$
  select not nomad_poll_private.caller_is_client() or coalesce(nomad_core.organization_role(p_org) = any (p_roles), false)
$$;

create table nomad_poll_private.rate_limits (
  key text primary key,
  window_start timestamptz not null default now(),
  hits integer not null default 0
);
comment on table nomad_poll_private.rate_limits is '청중·진행자 요청 제한 카운터(비노출, 정책 없음). rate_hit/rate_peek 함수만 접근.';
alter table nomad_poll_private.rate_limits enable row level security;
revoke all on nomad_poll_private.rate_limits from public, anon, authenticated;
create index rate_limits_window_idx on nomad_poll_private.rate_limits (window_start);

-- 고정 윈도우 카운터. true = 한도 초과(차단).
create function nomad_poll_private.rate_hit(p_key text, p_max integer, p_window_seconds integer) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare h integer;
begin
  if p_max < 1 or p_window_seconds < 1 or p_window_seconds > 86400 then raise exception 'invalid rate limit'; end if;
  if random() < 0.02 then
    delete from nomad_poll_private.rate_limits where window_start < now() - interval '1 day';
  end if;
  insert into nomad_poll_private.rate_limits as r (key, window_start, hits) values (p_key, now(), 1)
  on conflict (key) do update set
    hits = case when r.window_start < now() - make_interval(secs => p_window_seconds) then 1 else r.hits + 1 end,
    window_start = case when r.window_start < now() - make_interval(secs => p_window_seconds) then now() else r.window_start end
  returning hits into h;
  return h > p_max;
end $$;

-- 카운트 없이 이미 한도에 닿았는지만 본다.
create function nomad_poll_private.rate_peek(p_key text, p_max integer, p_window_seconds integer) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from nomad_poll_private.rate_limits b
                  where b.key = p_key and b.window_start > now() - make_interval(secs => p_window_seconds) and b.hits >= p_max)
$$;

-- settings boolean 키 안전 읽기: JSON boolean 일 때만 값, 그 밖(없음·다른 타입)은 기본값. 캐스트 오류로 RPC가 깨지지 않게 한다.
create function nomad_poll_private.setting_bool(p_settings jsonb, p_key text, p_default boolean) returns boolean
language sql immutable set search_path = ''
as $$
  select case when jsonb_typeof(p_settings -> p_key) = 'boolean' then (p_settings -> p_key)::boolean else p_default end
$$;

-- 플랜 한도(plan_limits). 키가 없으면 원본 기본값. 무제한 = 2147483647.
create function nomad_poll_private.limit_int(p_org uuid, p_key text, p_default integer) returns integer
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.org_plan_limit(p_org, 'poll', p_key), p_default)
$$;

-- 금칙어 비교용 정규화(소문자, 공백/구두점 제거). generated 컬럼이 쓰므로 authenticated 실행 허용.
create function nomad_poll.normalize_text(p_text text) returns text
language sql immutable set search_path = ''
as $$ select regexp_replace(lower(coalesce(p_text, '')), '[[:space:][:punct:]]+', '', 'g') $$;

-- 사용자 입력 정리: 제어문자 제거 + 앞뒤 공백 제거. HTML은 저장 그대로 두고 렌더에서 텍스트로만 출력한다.
create function nomad_poll.clean_text(p_text text) returns text
language sql immutable set search_path = ''
as $$ select btrim(regexp_replace(coalesce(p_text, ''), '[[:cntrl:]]+', ' ', 'g')) $$;

-- Q&A 변경 감지용 단조 증가 번호
create sequence nomad_poll.poll_change_seq;

-- ---------------------------------------------------------------------
-- 1. events: 행사(방). 6자리 입장 코드
-- ---------------------------------------------------------------------
create table nomad_poll.events (
  id                          uuid primary key default gen_random_uuid(),
  organization_id             uuid not null references nomad_core.organizations(id) on delete cascade,
  code                        text not null constraint events_code_check check (code ~ '^[0-9]{6}$'),
  title                       text not null constraint events_title_check check (char_length(title) between 1 and 120),
  description                 text not null default '' constraint events_description_check check (char_length(description) <= 500),
  status                      text not null default 'draft'
                              constraint events_status_check check (status in ('draft', 'live', 'ended', 'archived')),
  join_locked                 boolean not null default false,
  passcode_hash               text,
  settings                    jsonb not null default '{}'::jsonb
                              constraint events_settings_check check (jsonb_typeof(settings) = 'object' and pg_column_size(settings) <= 4096
                                and coalesce(jsonb_typeof(settings -> 'qna_enabled'), 'boolean') = 'boolean'
                                and coalesce(jsonb_typeof(settings -> 'qna_moderation'), 'boolean') = 'boolean'
                                and coalesce(jsonb_typeof(settings -> 'allow_anonymous'), 'boolean') = 'boolean'
                                and coalesce(jsonb_typeof(settings -> 'share_results_after_end'), 'boolean') = 'boolean'
                                and coalesce(jsonb_typeof(settings -> 'require_captcha'), 'boolean') = 'boolean'),
  current_poll_id             uuid,
  max_participants            integer not null default 100 constraint events_max_participants_check check (max_participants between 1 and 100000),
  overlay_key_hash            text,
  state_version               bigint not null default 1,
  broadcast_state_version     bigint not null default 0,
  broadcast_vote_seq          bigint not null default 0,
  broadcast_qna_seq           bigint not null default 0,
  broadcast_participant_count integer not null default 0,
  broadcast_seq               bigint not null default 0,
  broadcast_at                timestamptz,
  started_at                  timestamptz,
  ended_at                    timestamptz,
  archived_at                 timestamptz,
  retention_until             timestamptz,
  purged_at                   timestamptz,
  created_by                  uuid,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  deleted_at                  timestamptz,
  constraint events_id_org_uniq unique (id, organization_id)
);
comment on table nomad_poll.events is '행사(방). 진행자(조직 멤버)만 읽는다. 청중은 RPC로만.';
comment on column nomad_poll.events.code is '6자리 숫자 입장 코드. archived/삭제 전까지 전역 유일(부분 유니크 인덱스)';
comment on column nomad_poll.events.settings is 'qna_enabled, qna_moderation, allow_anonymous, share_results_after_end, require_captcha (모두 boolean, 제약으로 검사)';
comment on column nomad_poll.events.passcode_hash is 'sha256(event_id:passcode) hex. null이면 코드만으로 입장';
comment on column nomad_poll.events.overlay_key_hash is 'OBS 오버레이 키의 sha256 hex. 원문은 rotate_overlay_key 반환값으로 1회만';
comment on column nomad_poll.events.state_version is '공개 상태가 바뀔 때마다 트리거가 1 올린다';
create unique index events_code_active_uniq on nomad_poll.events (code) where status <> 'archived' and deleted_at is null;
create index events_org_created_idx on nomad_poll.events (organization_id, created_at desc);
create index events_org_updated_idx on nomad_poll.events (organization_id, updated_at);
create index events_live_idx on nomad_poll.events (broadcast_at) where status = 'live' and deleted_at is null;

-- ---------------------------------------------------------------------
-- 2. polls: 행사 안의 투표 문항
-- ---------------------------------------------------------------------
create table nomad_poll.polls (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id           uuid not null,
  position           integer not null default 0,
  kind               text not null default 'single_choice'
                     constraint polls_kind_check check (kind in ('single_choice', 'multiple_choice', 'rating')),
  title              text not null constraint polls_title_check check (char_length(title) between 1 and 200),
  max_choices        smallint not null default 1 constraint polls_max_choices_check check (max_choices between 1 and 10),
  rating_scale       smallint not null default 5 constraint polls_rating_scale_check check (rating_scale between 2 and 10),
  results_visibility text not null default 'live'
                     constraint polls_results_visibility_check check (results_visibility in ('live', 'after_close', 'host_only')),
  status             text not null default 'draft'
                     constraint polls_status_check check (status in ('draft', 'open', 'closed')),
  opened_at          timestamptz,
  closed_at          timestamptz,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint polls_event_fk foreign key (event_id, organization_id) references nomad_poll.events (id, organization_id) on delete cascade,
  constraint polls_id_org_uniq unique (id, organization_id),
  constraint polls_id_event_uniq unique (id, event_id)
);
comment on table nomad_poll.polls is '행사 안의 투표 문항(단일·복수 선택, 평점). 열린 뒤에는 내용 변경 금지.';
create unique index polls_one_open_per_event_uniq on nomad_poll.polls (event_id) where status = 'open';
create index polls_event_position_idx on nomad_poll.polls (event_id, position);
create index polls_org_updated_idx on nomad_poll.polls (organization_id, updated_at);

alter table nomad_poll.events
  add constraint events_current_poll_fk foreign key (current_poll_id) references nomad_poll.polls (id) on delete set null;

-- ---------------------------------------------------------------------
-- 3. poll_options
-- ---------------------------------------------------------------------
create table nomad_poll.poll_options (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  poll_id         uuid not null,
  position        integer not null default 0,
  label           text not null constraint poll_options_label_check check (char_length(label) between 1 and 120),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint poll_options_poll_fk foreign key (poll_id, organization_id) references nomad_poll.polls (id, organization_id) on delete cascade
);
comment on table nomad_poll.poll_options is '선택지(문항당 2~10개, 열기 전 검사).';
create index poll_options_poll_idx on nomad_poll.poll_options (poll_id, position);
create index poll_options_org_updated_idx on nomad_poll.poll_options (organization_id, updated_at);

-- ---------------------------------------------------------------------
-- 4. participants: 청중. Supabase 사용자가 아니다. 토큰 원문은 저장하지 않는다
-- ---------------------------------------------------------------------
create table nomad_poll.participants (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id        uuid not null,
  token_hash      text not null constraint participants_token_hash_check check (token_hash ~ '^[0-9a-f]{64}$'),
  nickname        text constraint participants_nickname_check check (nickname is null or char_length(nickname) between 1 and 30),
  is_blocked      boolean not null default false,
  joined_at       timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  constraint participants_event_fk foreign key (event_id, organization_id) references nomad_poll.events (id, organization_id) on delete cascade,
  constraint participants_token_uniq unique (token_hash),
  constraint participants_id_event_uniq unique (id, event_id)
);
comment on table nomad_poll.participants is '청중(무로그인). 쓰기는 definer RPC만. token_hash는 진행자에게도 노출하지 않는다(컬럼 grant 제외).';
create index participants_event_idx on nomad_poll.participants (event_id, joined_at);
create index participants_org_idx on nomad_poll.participants (organization_id);

-- ---------------------------------------------------------------------
-- 5. votes: 1인 1문항 1제출
-- ---------------------------------------------------------------------
create table nomad_poll.votes (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id        uuid not null,
  poll_id         uuid not null,
  participant_id  uuid not null,
  option_ids      uuid[] not null default '{}',
  rating          smallint,
  created_at      timestamptz not null default now(),
  constraint votes_poll_fk foreign key (poll_id, event_id) references nomad_poll.polls (id, event_id) on delete cascade,
  constraint votes_participant_fk foreign key (participant_id, event_id) references nomad_poll.participants (id, event_id) on delete cascade,
  constraint votes_one_per_participant_uniq unique (poll_id, participant_id),
  constraint votes_payload_check check ((rating is null) <> (cardinality(option_ids) = 0)),
  constraint votes_option_count_check check (cardinality(option_ids) <= 10)
);
comment on table nomad_poll.votes is '투표 1건(poll_id, participant_id 유니크). 쓰기는 cast_vote RPC만.';
create index votes_poll_id_idx on nomad_poll.votes (poll_id, id);
create index votes_org_idx on nomad_poll.votes (organization_id);

-- ---------------------------------------------------------------------
-- 6. poll_results: 문항 종료 시 확정 집계(원본 투표를 지워도 남는다)
-- ---------------------------------------------------------------------
create table nomad_poll.poll_results (
  poll_id         uuid primary key references nomad_poll.polls (id) on delete cascade,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id        uuid not null,
  total_votes     integer not null default 0,
  counts          jsonb not null default '{}'::jsonb,
  finalized_at    timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table nomad_poll.poll_results is '문항 종료 시 확정 집계. 쓰기는 definer 내부 함수만.';
create index poll_results_event_idx on nomad_poll.poll_results (event_id);
create index poll_results_org_idx on nomad_poll.poll_results (organization_id);

-- ---------------------------------------------------------------------
-- 7. qna_questions / qna_upvotes
-- ---------------------------------------------------------------------
create table nomad_poll.qna_questions (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id        uuid not null,
  participant_id  uuid not null,
  body            text not null constraint qna_questions_body_check check (char_length(body) between 1 and 300),
  show_nickname   boolean not null default true,
  status          text not null default 'pending'
                  constraint qna_questions_status_check check (status in ('pending', 'visible', 'answered', 'hidden', 'rejected')),
  hidden_reason   text constraint qna_questions_hidden_reason_check check (hidden_reason is null or hidden_reason in ('banned_word', 'host', 'blocked_participant')),
  change_seq      bigint not null default nextval('nomad_poll.poll_change_seq'),
  moderated_by    uuid,
  moderated_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint qna_questions_event_fk foreign key (event_id, organization_id) references nomad_poll.events (id, organization_id) on delete cascade,
  constraint qna_questions_participant_fk foreign key (participant_id, event_id) references nomad_poll.participants (id, event_id) on delete cascade,
  constraint qna_questions_id_event_uniq unique (id, event_id)
);
comment on table nomad_poll.qna_questions is '청중 질문. 쓰기는 ask_question·moderate_question RPC만.';
create index qna_questions_event_status_idx on nomad_poll.qna_questions (event_id, status, created_at);
create index qna_questions_event_seq_idx on nomad_poll.qna_questions (event_id, change_seq);
create index qna_questions_org_idx on nomad_poll.qna_questions (organization_id);

create table nomad_poll.qna_upvotes (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  event_id        uuid not null,
  question_id     uuid not null,
  participant_id  uuid not null,
  change_seq      bigint not null default nextval('nomad_poll.poll_change_seq'),
  created_at      timestamptz not null default now(),
  constraint qna_upvotes_question_fk foreign key (question_id, event_id) references nomad_poll.qna_questions (id, event_id) on delete cascade,
  constraint qna_upvotes_participant_fk foreign key (participant_id, event_id) references nomad_poll.participants (id, event_id) on delete cascade,
  constraint qna_upvotes_once_uniq unique (question_id, participant_id)
);
comment on table nomad_poll.qna_upvotes is '질문 추천(1인 1회). 쓰기는 upvote_question RPC만.';
create index qna_upvotes_event_seq_idx on nomad_poll.qna_upvotes (event_id, change_seq);
create index qna_upvotes_org_idx on nomad_poll.qna_upvotes (organization_id);

-- ---------------------------------------------------------------------
-- 8. banned_words: organization_id null = 플랫폼 기본 목록(service_role만 관리)
-- ---------------------------------------------------------------------
create table nomad_poll.banned_words (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references nomad_core.organizations(id) on delete cascade,
  word            text not null constraint banned_words_word_check check (char_length(word) between 1 and 40),
  normalized      text generated always as (nomad_poll.normalize_text(word)) stored,
  created_by      uuid,
  created_at      timestamptz not null default now()
);
comment on table nomad_poll.banned_words is '닉네임·질문 금칙어. 조직 목록은 owner/admin이, 플랫폼 기본 목록은 service_role만 관리.';
create unique index banned_words_org_word_uniq
  on nomad_poll.banned_words (coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), normalized);

-- ---------------------------------------------------------------------
-- 9. audit_logs: 원본 core.write_audit 대체(제품 전용)
-- ---------------------------------------------------------------------
create table nomad_poll.audit_logs (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  actor_id        uuid,
  action          text not null,
  target_type     text,
  target_id       text,
  created_at      timestamptz not null default now()
);
comment on table nomad_poll.audit_logs is '진행자 작업 감사 기록. owner/admin 읽기, 쓰기는 write_audit(definer)만.';
create index audit_logs_org_idx on nomad_poll.audit_logs (organization_id, created_at desc);

create function nomad_poll_private.write_audit(p_org uuid, p_action text, p_target_type text, p_target_id text) returns void
language sql security definer set search_path = ''
as $$
  insert into nomad_poll.audit_logs (organization_id, actor_id, action, target_type, target_id)
  values (p_org, (select auth.uid()), p_action, p_target_type, p_target_id)
$$;

-- ---------------------------------------------------------------------
-- 10. 트리거: updated_at, 상태 전이 강제, state_version 증가, 작성자 기록
--   (원본의 guard_privileged_write 이중 잠금은 두지 않는다: 청중 테이블은 anon·authenticated에 쓰기 grant가 없고 definer RPC만 쓴다)
-- ---------------------------------------------------------------------
create trigger events_touch before update on nomad_poll.events
  for each row execute function nomad_core.touch_updated_at();
create trigger polls_touch before update on nomad_poll.polls
  for each row execute function nomad_core.touch_updated_at();
create trigger poll_options_touch before update on nomad_poll.poll_options
  for each row execute function nomad_core.touch_updated_at();
create trigger poll_results_touch before update on nomad_poll.poll_results
  for each row execute function nomad_core.touch_updated_at();
create trigger qna_questions_touch before update on nomad_poll.qna_questions
  for each row execute function nomad_core.touch_updated_at();

create function nomad_poll.events_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status then
    if not ((old.status, new.status) in (('draft', 'live'), ('draft', 'archived'), ('live', 'ended'),
                                         ('ended', 'live'), ('ended', 'archived'))) then
      raise exception 'events: transition % -> % not allowed', old.status, new.status using errcode = '22023';
    end if;
  end if;
  if new.organization_id is distinct from old.organization_id or new.code is distinct from old.code then
    raise exception 'events: organization_id/code are immutable' using errcode = '42501';
  end if;
  if (new.title, new.description, new.status, new.join_locked, new.settings, new.current_poll_id, new.passcode_hash)
     is distinct from
     (old.title, old.description, old.status, old.join_locked, old.settings, old.current_poll_id, old.passcode_hash) then
    new.state_version := old.state_version + 1;
  end if;
  return new;
end;
$$;
create trigger events_before_update before update on nomad_poll.events
  for each row execute function nomad_poll.events_before_update();

create function nomad_poll.polls_before_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, (select auth.uid()));
    if new.status <> 'draft' then
      raise exception 'polls: new poll must be draft' using errcode = '22023';
    end if;
    return new;
  end if;
  if new.organization_id is distinct from old.organization_id or new.event_id is distinct from old.event_id then
    raise exception 'polls: organization_id/event_id are immutable' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status, new.status) in (('draft', 'open'), ('open', 'closed'), ('closed', 'open'))) then
      raise exception 'polls: transition % -> % not allowed', old.status, new.status using errcode = '22023';
    end if;
  end if;
  if old.status <> 'draft' and (new.kind, new.title, new.max_choices, new.rating_scale)
                               is distinct from (old.kind, old.title, old.max_choices, old.rating_scale) then
    raise exception 'polls: content is frozen after opening' using errcode = 'PL011';
  end if;
  return new;
end;
$$;
create trigger polls_before_write before insert or update on nomad_poll.polls
  for each row execute function nomad_poll.polls_before_write();

create function nomad_poll.qna_questions_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  -- ('answered', 'hidden') 추가: 원본은 빠져 있어 답변된 질문이 있는 참가자를 block_participant 로 차단하면 실패했다.
  if new.status is distinct from old.status then
    if not ((old.status, new.status) in (('pending', 'visible'), ('pending', 'rejected'), ('pending', 'hidden'),
                                         ('visible', 'answered'), ('visible', 'hidden'), ('answered', 'visible'),
                                         ('answered', 'hidden'), ('hidden', 'visible'), ('rejected', 'visible'))) then
      raise exception 'qna_questions: transition % -> % not allowed', old.status, new.status using errcode = '22023';
    end if;
  end if;
  new.change_seq := nextval('nomad_poll.poll_change_seq');
  return new;
end;
$$;
create trigger qna_questions_before_update before update on nomad_poll.qna_questions
  for each row execute function nomad_poll.qna_questions_before_update();

-- ---------------------------------------------------------------------
-- 11. RLS와 GRANT. 진행자(authenticated): 자기 조직 + 'poll' 'host' 기능일 때만 읽는다. anon: 테이블 권한 없음(D8).
--   쓰기 역할: owner/admin/editor(원본 member → editor). viewer는 읽기만.
-- ---------------------------------------------------------------------
alter table nomad_poll.events        enable row level security;
alter table nomad_poll.polls         enable row level security;
alter table nomad_poll.poll_options  enable row level security;
alter table nomad_poll.participants  enable row level security;
alter table nomad_poll.votes         enable row level security;
alter table nomad_poll.poll_results  enable row level security;
alter table nomad_poll.qna_questions enable row level security;
alter table nomad_poll.qna_upvotes   enable row level security;
alter table nomad_poll.banned_words  enable row level security;
alter table nomad_poll.audit_logs    enable row level security;

revoke all on table nomad_poll.events, nomad_poll.polls, nomad_poll.poll_options, nomad_poll.participants, nomad_poll.votes,
                    nomad_poll.poll_results, nomad_poll.qna_questions, nomad_poll.qna_upvotes, nomad_poll.banned_words,
                    nomad_poll.audit_logs
  from public, anon, authenticated;
revoke all on sequence nomad_poll.poll_change_seq from public, anon, authenticated;
grant all on table nomad_poll.events, nomad_poll.polls, nomad_poll.poll_options, nomad_poll.participants, nomad_poll.votes,
                   nomad_poll.poll_results, nomad_poll.qna_questions, nomad_poll.qna_upvotes, nomad_poll.banned_words,
                   nomad_poll.audit_logs
  to service_role;
grant usage, select on sequence nomad_poll.poll_change_seq to service_role;

-- events
grant select on nomad_poll.events to authenticated;
grant update (title, description, settings, join_locked) on nomad_poll.events to authenticated;
create policy events_select on nomad_poll.events for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host') and deleted_at is null);
create policy events_update on nomad_poll.events for update to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
         and nomad_core.has_feature(organization_id, 'poll', 'host') and deleted_at is null and status <> 'archived')
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
              and nomad_core.has_feature(organization_id, 'poll', 'host'));

-- polls (draft 만 편집. 상태는 transition_poll 로만)
grant select, delete on nomad_poll.polls to authenticated;
grant insert (organization_id, event_id, position, kind, title, max_choices, rating_scale, results_visibility) on nomad_poll.polls to authenticated;
grant update (position, kind, title, max_choices, rating_scale, results_visibility) on nomad_poll.polls to authenticated;
create policy polls_select on nomad_poll.polls for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));
create policy polls_insert on nomad_poll.polls for insert to authenticated
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
              and nomad_core.has_feature(organization_id, 'poll', 'host')
              and exists (select 1 from nomad_poll.events e
                          where e.id = polls.event_id and e.organization_id = polls.organization_id
                            and e.status in ('draft', 'live') and e.deleted_at is null));
create policy polls_update on nomad_poll.polls for update to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
         and nomad_core.has_feature(organization_id, 'poll', 'host') and status = 'draft')
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and status = 'draft');
create policy polls_delete on nomad_poll.polls for delete to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin') and status <> 'open');

-- poll_options (부모 문항이 draft 일 때만)
grant select, delete on nomad_poll.poll_options to authenticated;
grant insert (organization_id, poll_id, position, label) on nomad_poll.poll_options to authenticated;
grant update (position, label) on nomad_poll.poll_options to authenticated;
create policy poll_options_select on nomad_poll.poll_options for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));
create policy poll_options_insert on nomad_poll.poll_options for insert to authenticated
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
              and nomad_core.has_feature(organization_id, 'poll', 'host')
              and exists (select 1 from nomad_poll.polls p
                          where p.id = poll_options.poll_id and p.organization_id = poll_options.organization_id and p.status = 'draft')
              and (select count(*) from nomad_poll.poll_options o where o.poll_id = poll_options.poll_id) < 10);
create policy poll_options_update on nomad_poll.poll_options for update to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
         and exists (select 1 from nomad_poll.polls p where p.id = poll_options.poll_id and p.status = 'draft'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
              and exists (select 1 from nomad_poll.polls p where p.id = poll_options.poll_id and p.status = 'draft'));
create policy poll_options_delete on nomad_poll.poll_options for delete to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')
         and exists (select 1 from nomad_poll.polls p where p.id = poll_options.poll_id and p.status = 'draft'));

-- participants: token_hash 컬럼은 진행자에게도 주지 않는다
grant select (id, organization_id, event_id, nickname, is_blocked, joined_at, last_seen_at) on nomad_poll.participants to authenticated;
create policy participants_select on nomad_poll.participants for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));

-- votes / poll_results / qna (읽기만)
grant select on nomad_poll.votes, nomad_poll.poll_results, nomad_poll.qna_questions, nomad_poll.qna_upvotes to authenticated;
create policy votes_select on nomad_poll.votes for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));
create policy poll_results_select on nomad_poll.poll_results for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));
create policy qna_questions_select on nomad_poll.qna_questions for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));
create policy qna_upvotes_select on nomad_poll.qna_upvotes for select to authenticated
  using (nomad_core.has_feature(organization_id, 'poll', 'host'));

-- banned_words: 자기 조직 목록만. 플랫폼 기본 목록(organization_id null)은 보이지 않는다
grant select, delete on nomad_poll.banned_words to authenticated;
grant insert (organization_id, word) on nomad_poll.banned_words to authenticated;
create policy banned_words_select on nomad_poll.banned_words for select to authenticated
  using (organization_id is not null and nomad_core.organization_role(organization_id) is not null);
create policy banned_words_insert on nomad_poll.banned_words for insert to authenticated
  with check (organization_id is not null and nomad_core.organization_role(organization_id) in ('owner', 'admin')
              and nomad_core.has_feature(organization_id, 'poll', 'host'));
create policy banned_words_delete on nomad_poll.banned_words for delete to authenticated
  using (organization_id is not null and nomad_core.organization_role(organization_id) in ('owner', 'admin'));

-- audit_logs: owner/admin 읽기
grant select on nomad_poll.audit_logs to authenticated;
create policy audit_logs_select on nomad_poll.audit_logs for select to authenticated
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

-- ---------------------------------------------------------------------
-- 12. 내부 헬퍼 (SECURITY DEFINER, 클라이언트 실행 없음)
-- ---------------------------------------------------------------------
create function nomad_poll.contains_banned_word(p_org uuid, p_text text) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from nomad_poll.banned_words w
    where (w.organization_id is null or w.organization_id = p_org)
      and w.normalized <> ''
      and position(w.normalized in nomad_poll.normalize_text(p_text)) > 0
  );
$$;

-- 암호학적 난수 6자리 코드. archived/삭제되지 않은 행사와 겹치지 않게 최대 20회 시도
create function nomad_poll.new_event_code() returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare v_code text; i integer;
begin
  for i in 1..20 loop
    v_code := lpad(((('x' || lpad(encode(extensions.gen_random_bytes(6), 'hex'), 16, '0'))::bit(64)::bigint) % 1000000)::text, 6, '0');
    if not exists (select 1 from nomad_poll.events e where e.code = v_code and e.status <> 'archived' and e.deleted_at is null) then
      return v_code;
    end if;
  end loop;
  raise exception 'new_event_code: no free code' using errcode = 'PL014';
end;
$$;

create function nomad_poll.token_hash(p_token text) returns text
language sql immutable set search_path = ''
as $$ select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') $$;

-- 문항 집계 jsonb: {total, counts: {option_id|rating: n}}
create function nomad_poll.build_poll_result(p_poll_id uuid) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'total', (select count(*) from nomad_poll.votes v where v.poll_id = p_poll_id),
    'counts', coalesce((
      select jsonb_object_agg(x.k, x.c) from (
        select o.option_id::text as k, count(*) as c
        from nomad_poll.votes v cross join lateral unnest(v.option_ids) as o(option_id)
        where v.poll_id = p_poll_id
        group by o.option_id
        union all
        select v.rating::text, count(*)
        from nomad_poll.votes v
        where v.poll_id = p_poll_id and v.rating is not null
        group by v.rating
      ) x
    ), '{}'::jsonb)
  );
$$;

create function nomad_poll.finalize_poll(p_poll_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_r jsonb; v_p nomad_poll.polls;
begin
  select * into v_p from nomad_poll.polls where id = p_poll_id;
  if not found then return; end if;
  v_r := nomad_poll.build_poll_result(p_poll_id);
  insert into nomad_poll.poll_results (poll_id, organization_id, event_id, total_votes, counts, finalized_at)
  values (p_poll_id, v_p.organization_id, v_p.event_id, (v_r ->> 'total')::integer, v_r -> 'counts', now())
  on conflict (poll_id) do update
    set total_votes = excluded.total_votes, counts = excluded.counts, finalized_at = excluded.finalized_at;
end;
$$;

-- 청중/오버레이에 공개되는 문항 상태. draft 는 공개하지 않는다. 결과는 results_visibility 규칙을 따른다
create function nomad_poll.build_public_poll(p_poll_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_p nomad_poll.polls; v_show boolean;
begin
  if p_poll_id is null then return null; end if;
  select * into v_p from nomad_poll.polls where id = p_poll_id;
  if not found or v_p.status = 'draft' then return null; end if;
  v_show := v_p.results_visibility = 'live' or (v_p.results_visibility = 'after_close' and v_p.status = 'closed');
  return jsonb_build_object(
    'id', v_p.id, 'kind', v_p.kind, 'title', v_p.title, 'status', v_p.status,
    'max_choices', v_p.max_choices, 'rating_scale', v_p.rating_scale, 'results_visibility', v_p.results_visibility,
    'options', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label) order by o.position, o.created_at)
                         from nomad_poll.poll_options o where o.poll_id = v_p.id), '[]'::jsonb),
    'results', case when v_show then nomad_poll.build_poll_result(v_p.id) end
  );
end;
$$;

-- 행사 공개 상태(브로드캐스트와 참가자/오버레이 스냅샷 공용)
create function nomad_poll.build_public_state(p_event_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_e nomad_poll.events; v_qna boolean; v_count integer;
begin
  select * into v_e from nomad_poll.events where id = p_event_id and deleted_at is null;
  if not found then return null; end if;
  v_qna := nomad_poll_private.setting_bool(v_e.settings, 'qna_enabled', true);
  select count(*) into v_count from nomad_poll.participants pa where pa.event_id = v_e.id;
  if v_e.status <> 'live' then
    return jsonb_build_object(
      'event', jsonb_build_object('id', v_e.id, 'title', v_e.title, 'status', v_e.status, 'state_version', v_e.state_version),
      'poll', case when v_e.status = 'ended' and nomad_poll_private.setting_bool(v_e.settings, 'share_results_after_end', false)
                   then nomad_poll.build_public_poll(v_e.current_poll_id) end,
      'qna', null);
  end if;
  return jsonb_build_object(
    'event', jsonb_build_object('id', v_e.id, 'title', v_e.title, 'status', v_e.status, 'join_locked', v_e.join_locked,
                                'participant_count', v_count, 'qna_enabled', v_qna, 'state_version', v_e.state_version),
    'poll', nomad_poll.build_public_poll(v_e.current_poll_id),
    'qna', case when v_qna then coalesce((
      select jsonb_agg(to_jsonb(x) order by x.upvotes desc, x.created_at asc) from (
        select q.id, q.body, case when q.show_nickname then pa.nickname end as nickname, q.status, q.created_at,
               (select count(*) from nomad_poll.qna_upvotes u where u.question_id = q.id) as upvotes
        from nomad_poll.qna_questions q
        join nomad_poll.participants pa on pa.id = q.participant_id
        where q.event_id = v_e.id and q.status in ('visible', 'answered')
        order by upvotes desc, q.created_at asc
        limit 30
      ) x), '[]'::jsonb) end
  );
end;
$$;

-- 행사 종료 내부 처리: 열린 문항 확정 → ended
create function nomad_poll.end_event_internal(p_event_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_poll uuid; v_e nomad_poll.events;
begin
  select * into v_e from nomad_poll.events where id = p_event_id for update;
  if not found or v_e.status <> 'live' then return; end if;
  for v_poll in select id from nomad_poll.polls where event_id = p_event_id and status = 'open' loop
    update nomad_poll.polls set status = 'closed', closed_at = now() where id = v_poll;
    perform nomad_poll.finalize_poll(v_poll);
  end loop;
  update nomad_poll.events
     set status = 'ended', ended_at = now(),
         retention_until = now() + make_interval(days => greatest(nomad_poll_private.limit_int(v_e.organization_id, 'retention_days', 30), 1))
   where id = p_event_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 13. 진행자 RPC (authenticated). 호출자 판정: nomad_poll_private.host_ok (서버는 통과, 클라이언트는 조직 역할)
-- ---------------------------------------------------------------------
create function nomad_poll.create_event(p_org_id uuid, p_title text, p_description text default '', p_settings jsonb default '{}'::jsonb)
returns nomad_poll.events
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_poll.events; v_limit integer; v_count integer;
begin
  if not nomad_poll_private.host_ok(p_org_id, array['owner', 'admin', 'editor']) then
    raise exception 'create_event: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(p_org_id, 'poll', 'host') then
    raise exception 'create_event: no entitlement' using errcode = '42501';
  end if;
  if nomad_poll_private.rate_hit('poll:create_event:' || p_org_id::text, 30, 3600) then
    raise exception 'create_event: rate limited' using errcode = 'PL429';
  end if;
  v_limit := nomad_poll_private.limit_int(p_org_id, 'max_events', 50);
  select count(*) into v_count from nomad_poll.events e
   where e.organization_id = p_org_id and e.status <> 'archived' and e.deleted_at is null;
  if v_count >= v_limit then
    raise exception 'create_event: plan limit % events', v_limit using errcode = 'PL012';
  end if;
  insert into nomad_poll.events (organization_id, code, title, description, settings, created_by)
  values (p_org_id, nomad_poll.new_event_code(), nomad_poll.clean_text(p_title), nomad_poll.clean_text(coalesce(p_description, '')),
          coalesce(p_settings, '{}'::jsonb), (select auth.uid()))
  returning * into v_row;
  perform nomad_poll_private.write_audit(p_org_id, 'event.create', 'poll_event', v_row.id::text);
  return v_row;
end;
$$;

-- 상태 전이: draft→live, draft→archived, live→ended, ended→live(종료 24시간 이내), ended→archived
create function nomad_poll.transition_event(p_event_id uuid, p_to text) returns nomad_poll.events
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_poll.events; v_limit integer; v_live integer;
begin
  select * into v_row from nomad_poll.events where id = p_event_id and deleted_at is null for update;
  if not found then
    raise exception 'transition_event: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_row.organization_id, array['owner', 'admin', 'editor']) then
    raise exception 'transition_event: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_row.organization_id, 'poll', 'host') then
    raise exception 'transition_event: no entitlement' using errcode = '42501';
  end if;
  if not ((v_row.status, p_to) in (('draft', 'live'), ('draft', 'archived'), ('live', 'ended'), ('ended', 'live'), ('ended', 'archived'))) then
    raise exception 'transition_event: % -> % not allowed', v_row.status, p_to using errcode = 'PL011';
  end if;
  if p_to = 'live' then
    if v_row.status = 'ended' and (v_row.ended_at < now() - interval '24 hours' or v_row.purged_at is not null) then
      raise exception 'transition_event: reopen window passed' using errcode = 'PL011';
    end if;
    v_limit := nomad_poll_private.limit_int(v_row.organization_id, 'max_live_events', 1);
    select count(*) into v_live from nomad_poll.events e
     where e.organization_id = v_row.organization_id and e.status = 'live' and e.deleted_at is null and e.id <> v_row.id;
    if v_live >= v_limit then
      raise exception 'transition_event: plan limit % live events', v_limit using errcode = 'PL012';
    end if;
    update nomad_poll.events
       set status = 'live', started_at = coalesce(started_at, now()), ended_at = null, retention_until = null,
           max_participants = greatest(nomad_poll_private.limit_int(v_row.organization_id, 'max_participants', 100), 1)
     where id = p_event_id returning * into v_row;
  elsif p_to = 'ended' then
    perform nomad_poll.end_event_internal(p_event_id);
    select * into v_row from nomad_poll.events where id = p_event_id;
  else
    update nomad_poll.events set status = 'archived', archived_at = now() where id = p_event_id returning * into v_row;
  end if;
  perform nomad_poll_private.write_audit(v_row.organization_id, 'event.' || p_to, 'poll_event', p_event_id::text);
  return v_row;
end;
$$;

-- 발표 화면의 현재 문항 지정(null 이면 대기 화면)
create function nomad_poll.set_current_poll(p_event_id uuid, p_poll_id uuid) returns nomad_poll.events
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_poll.events;
begin
  select * into v_row from nomad_poll.events where id = p_event_id and deleted_at is null for update;
  if not found then
    raise exception 'set_current_poll: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_row.organization_id, array['owner', 'admin', 'editor']) then
    raise exception 'set_current_poll: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_row.organization_id, 'poll', 'host') then
    raise exception 'set_current_poll: no entitlement' using errcode = '42501';
  end if;
  if v_row.status not in ('draft', 'live') then
    raise exception 'set_current_poll: event is %', v_row.status using errcode = 'PL011';
  end if;
  if p_poll_id is not null and not exists (select 1 from nomad_poll.polls p where p.id = p_poll_id and p.event_id = p_event_id) then
    raise exception 'set_current_poll: poll not in event' using errcode = '22023';
  end if;
  update nomad_poll.events set current_poll_id = p_poll_id where id = p_event_id returning * into v_row;
  return v_row;
end;
$$;

-- 문항 전이: draft→open, open→closed, closed→open. 열면 같은 행사의 다른 열린 문항을 닫고 현재 문항으로 지정
create function nomad_poll.transition_poll(p_poll_id uuid, p_to text) returns nomad_poll.polls
language plpgsql security definer set search_path = ''
as $$
declare v_p nomad_poll.polls; v_e nomad_poll.events; v_opts integer; v_other uuid; v_limit integer;
begin
  select * into v_p from nomad_poll.polls where id = p_poll_id for update;
  if not found then
    raise exception 'transition_poll: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_p.organization_id, array['owner', 'admin', 'editor']) then
    raise exception 'transition_poll: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_p.organization_id, 'poll', 'host') then
    raise exception 'transition_poll: no entitlement' using errcode = '42501';
  end if;
  select * into v_e from nomad_poll.events where id = v_p.event_id for update;
  if not ((v_p.status, p_to) in (('draft', 'open'), ('open', 'closed'), ('closed', 'open'))) then
    raise exception 'transition_poll: % -> % not allowed', v_p.status, p_to using errcode = 'PL011';
  end if;
  if p_to = 'open' then
    if v_e.status <> 'live' or v_e.deleted_at is not null then
      raise exception 'transition_poll: event is not live' using errcode = 'PL002';
    end if;
    if v_p.kind in ('single_choice', 'multiple_choice') then
      select count(*) into v_opts from nomad_poll.poll_options o where o.poll_id = v_p.id;
      if v_opts < 2 or v_opts > 10 then
        raise exception 'transition_poll: options must be 2..10 (got %)', v_opts using errcode = 'PL007';
      end if;
      if v_p.kind = 'multiple_choice' and v_p.max_choices > v_opts then
        raise exception 'transition_poll: max_choices exceeds options' using errcode = 'PL007';
      end if;
    end if;
    if v_p.status = 'draft' then
      v_limit := nomad_poll_private.limit_int(v_p.organization_id, 'polls_per_event', 50);
      if (select count(*) from nomad_poll.polls p where p.event_id = v_p.event_id and p.status <> 'draft') >= v_limit then
        raise exception 'transition_poll: plan limit % polls per event', v_limit using errcode = 'PL012';
      end if;
    end if;
    for v_other in select id from nomad_poll.polls where event_id = v_p.event_id and status = 'open' and id <> v_p.id loop
      update nomad_poll.polls set status = 'closed', closed_at = now() where id = v_other;
      perform nomad_poll.finalize_poll(v_other);
    end loop;
    update nomad_poll.polls set status = 'open', opened_at = now(), closed_at = null where id = p_poll_id returning * into v_p;
    update nomad_poll.events set current_poll_id = p_poll_id, state_version = state_version + 1 where id = v_p.event_id;
  else
    update nomad_poll.polls set status = 'closed', closed_at = now() where id = p_poll_id returning * into v_p;
    perform nomad_poll.finalize_poll(p_poll_id);
    update nomad_poll.events set state_version = state_version + 1 where id = v_p.event_id;
  end if;
  perform nomad_poll_private.write_audit(v_p.organization_id, 'poll_item.' || p_to, 'poll_item', p_poll_id::text);
  return v_p;
end;
$$;

-- Q&A 모더레이션
create function nomad_poll.moderate_question(p_question_id uuid, p_to text) returns nomad_poll.qna_questions
language plpgsql security definer set search_path = ''
as $$
declare v_q nomad_poll.qna_questions;
begin
  select * into v_q from nomad_poll.qna_questions where id = p_question_id for update;
  if not found then
    raise exception 'moderate_question: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_q.organization_id, array['owner', 'admin', 'editor']) then
    raise exception 'moderate_question: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_q.organization_id, 'poll', 'host') then
    raise exception 'moderate_question: no entitlement' using errcode = '42501';
  end if;
  if p_to not in ('visible', 'answered', 'hidden', 'rejected') then
    raise exception 'moderate_question: invalid target %', p_to using errcode = '22023';
  end if;
  update nomad_poll.qna_questions
     set status = p_to,
         hidden_reason = case when p_to = 'hidden' then 'host' when p_to = 'visible' then null else hidden_reason end,
         moderated_by = (select auth.uid()), moderated_at = now()
   where id = p_question_id returning * into v_q;
  perform nomad_poll_private.write_audit(v_q.organization_id, 'question.' || p_to, 'poll_question', p_question_id::text);
  return v_q;
end;
$$;

-- 참가자 차단/해제. 차단하면 그 참가자의 질문을 숨긴다(투표는 집계에 남는다)
create function nomad_poll.block_participant(p_participant_id uuid, p_blocked boolean default true) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_pa nomad_poll.participants;
begin
  select * into v_pa from nomad_poll.participants where id = p_participant_id for update;
  if not found then
    raise exception 'block_participant: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_pa.organization_id, array['owner', 'admin', 'editor']) then
    raise exception 'block_participant: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_pa.organization_id, 'poll', 'host') then
    raise exception 'block_participant: no entitlement' using errcode = '42501';
  end if;
  update nomad_poll.participants set is_blocked = coalesce(p_blocked, true) where id = p_participant_id;
  if coalesce(p_blocked, true) then
    update nomad_poll.qna_questions
       set status = 'hidden', hidden_reason = 'blocked_participant', moderated_by = (select auth.uid()), moderated_at = now()
     where participant_id = p_participant_id and status in ('pending', 'visible', 'answered');
  end if;
  perform nomad_poll_private.write_audit(v_pa.organization_id,
    case when coalesce(p_blocked, true) then 'participant.block' else 'participant.unblock' end, 'poll_participant', p_participant_id::text);
end;
$$;

-- 오버레이 키 재발급. 원문은 이 반환값으로 한 번만 보여 준다
create function nomad_poll.rotate_overlay_key(p_event_id uuid) returns text
language plpgsql security definer set search_path = ''
as $$
declare v_e nomad_poll.events; v_key text;
begin
  select * into v_e from nomad_poll.events where id = p_event_id and deleted_at is null for update;
  if not found then
    raise exception 'rotate_overlay_key: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_e.organization_id, array['owner', 'admin', 'editor']) then
    raise exception 'rotate_overlay_key: not a member' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_e.organization_id, 'poll', 'host') then
    raise exception 'rotate_overlay_key: no entitlement' using errcode = '42501';
  end if;
  v_key := encode(extensions.gen_random_bytes(24), 'hex');
  update nomad_poll.events set overlay_key_hash = nomad_poll.token_hash(v_key) where id = p_event_id;
  perform nomad_poll_private.write_audit(v_e.organization_id, 'event.overlay_key_rotate', 'poll_event', p_event_id::text);
  return v_key;
end;
$$;

-- 입장 비밀번호 설정/해제(4~12자). 저장은 sha256(event_id:passcode)
create function nomad_poll.set_event_passcode(p_event_id uuid, p_passcode text) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_e nomad_poll.events;
begin
  select * into v_e from nomad_poll.events where id = p_event_id and deleted_at is null for update;
  if not found then
    raise exception 'set_event_passcode: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_e.organization_id, array['owner', 'admin']) then
    raise exception 'set_event_passcode: owner/admin only' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_e.organization_id, 'poll', 'host') then
    raise exception 'set_event_passcode: no entitlement' using errcode = '42501';
  end if;
  if p_passcode is not null and char_length(p_passcode) not between 4 and 12 then
    raise exception 'set_event_passcode: length 4..12' using errcode = '22023';
  end if;
  update nomad_poll.events
     set passcode_hash = case when p_passcode is null then null else nomad_poll.token_hash(p_event_id::text || ':' || p_passcode) end
   where id = p_event_id;
  perform nomad_poll_private.write_audit(v_e.organization_id, 'event.passcode_set', 'poll_event', p_event_id::text);
end;
$$;

-- 행사 삭제(소프트). live 면 먼저 종료. 7일 뒤 purge_expired_events 가 물리 삭제
create function nomad_poll.delete_event(p_event_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_e nomad_poll.events;
begin
  select * into v_e from nomad_poll.events where id = p_event_id and deleted_at is null for update;
  if not found then
    raise exception 'delete_event: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_e.organization_id, array['owner', 'admin']) then
    raise exception 'delete_event: owner/admin only' using errcode = '42501';
  end if;
  if not nomad_core.org_has_feature(v_e.organization_id, 'poll', 'host') then
    raise exception 'delete_event: no entitlement' using errcode = '42501';
  end if;
  if v_e.status = 'live' then
    perform nomad_poll.end_event_internal(p_event_id);
  end if;
  update nomad_poll.events set deleted_at = now() where id = p_event_id;
  perform nomad_poll_private.write_audit(v_e.organization_id, 'event.delete', 'poll_event', p_event_id::text);
end;
$$;

-- 진행자 화면 실시간 집계(결과 공개 설정과 무관하게 진행자는 항상 본다)
create function nomad_poll.host_poll_results(p_poll_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_org uuid;
begin
  select organization_id into v_org from nomad_poll.polls where id = p_poll_id;
  if v_org is null then
    raise exception 'host_poll_results: not found' using errcode = 'P0002';
  end if;
  if not nomad_poll_private.host_ok(v_org, array['owner', 'admin', 'editor', 'viewer'])
     or not nomad_core.org_has_feature(v_org, 'poll', 'host') then
    raise exception 'host_poll_results: not a member' using errcode = '42501';
  end if;
  return nomad_poll.build_poll_result(p_poll_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 14. 청중 RPC (anon 실행, D8). 테이블 직접 접근 없이 이 함수들만 입장·투표·질문·추천·조회.
--     업무 오류는 {ok:false, code} 로 반환한다(요청 제한 히트가 롤백되지 않도록). 인자 형식 오류(토큰 길이)만 raise.
--     모든 입력은 길이·형식·개수를 먼저 검증하고, 토큰(32~128자)은 sha256 해시로만 저장·조회한다.
-- ---------------------------------------------------------------------
-- 참가자 토큰 → 참가자 (내부)
create function nomad_poll.resolve_participant(p_token text) returns nomad_poll.participants
language sql stable security definer set search_path = ''
as $$
  select pa.* from nomad_poll.participants pa where pa.token_hash = nomad_poll.token_hash(p_token);
$$;

create function nomad_poll.join_event(p_code text, p_token text, p_nickname text default null,
                                      p_ip_hash text default null, p_passcode text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash text; v_pa nomad_poll.participants; v_e nomad_poll.events; v_nick text; v_count integer;
  v_ip text; v_fail_key text; v_pass_key text; v_code_key text;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then
    raise exception 'join_event: bad token' using errcode = '22023';
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false, 'code', 'PL007', 'field', 'code');
  end if;
  if (p_nickname is not null and char_length(p_nickname) > 200) then
    return jsonb_build_object('ok', false, 'code', 'PL007', 'field', 'nickname');
  end if;
  if (p_passcode is not null and char_length(p_passcode) > 12) then
    return jsonb_build_object('ok', false, 'code', 'PL013');
  end if;
  v_hash := nomad_poll.token_hash(p_token);
  -- ip_hash 는 서버(service_role, Route Handler)가 넘길 때만 신뢰한다. 클라이언트 호출이거나 형식이 틀리면 토큰 단위로 센다.
  v_ip := case when not nomad_poll_private.caller_is_client() and p_ip_hash ~ '^[0-9a-f]{64}$' then p_ip_hash
               else 'tok:' || v_hash end;
  v_fail_key := 'poll:join_fail:' || v_ip;
  -- 전역 잠금 대신 코드 단위로 센다(한 사람이 모든 행사의 입장을 막지 못하게)
  v_code_key := 'poll:join_fail:code:' || p_code;

  -- 대입 차단: 실패 10분 30회(ip_hash/토큰 단위) 또는 같은 코드 10분 300회를 넘으면 조회 자체를 하지 않는다
  if nomad_poll_private.rate_peek(v_fail_key, 30, 600) or nomad_poll_private.rate_peek(v_code_key, 300, 600) then
    return jsonb_build_object('ok', false, 'code', 'PL429');
  end if;

  select * into v_e from nomad_poll.events e
   where e.code = p_code and e.status <> 'archived' and e.deleted_at is null;
  if not found then
    perform nomad_poll_private.rate_hit(v_code_key, 300, 600);
    return jsonb_build_object('ok', false,
      'code', case when nomad_poll_private.rate_hit(v_fail_key, 30, 600) then 'PL429' else 'PL001' end);
  end if;

  -- 같은 기기 재입장(토큰 동일)은 비밀번호를 다시 묻지 않는다. 그 밖에는 비밀번호를 상태·제목보다 먼저 검사한다
  select * into v_pa from nomad_poll.participants where token_hash = v_hash;
  if (v_pa.id is null or v_pa.event_id <> v_e.id) and v_e.passcode_hash is not null
     and v_e.passcode_hash is distinct from nomad_poll.token_hash(v_e.id::text || ':' || coalesce(p_passcode, '')) then
    -- 비밀번호 대입은 행사 단위로도 센다(ip_hash 를 바꿔 우회하지 못하게)
    v_pass_key := 'poll:pass_fail:' || v_e.id::text;
    if nomad_poll_private.rate_peek(v_pass_key, 60, 600) then
      return jsonb_build_object('ok', false, 'code', 'PL429');
    end if;
    perform nomad_poll_private.rate_hit(v_pass_key, 60, 600);
    return jsonb_build_object('ok', false,
      'code', case when nomad_poll_private.rate_hit(v_fail_key, 30, 600) then 'PL429' else 'PL013' end);
  end if;
  -- 비live 행사는 상태만 알려 주고 제목은 노출하지 않는다
  if v_e.status <> 'live' then
    return jsonb_build_object('ok', false, 'code', 'PL002', 'event_status', v_e.status);
  end if;
  if v_pa.id is not null then
    if v_pa.event_id <> v_e.id or v_pa.is_blocked then
      return jsonb_build_object('ok', false, 'code', 'PL009');
    end if;
    update nomad_poll.participants set last_seen_at = now() where id = v_pa.id;
    return jsonb_build_object('ok', true, 'rejoined', true, 'participant_id', v_pa.id, 'event_id', v_e.id,
                              'organization_id', v_e.organization_id,
                              'topic', 'poll:' || v_e.organization_id::text || ':' || v_e.id::text);
  end if;
  if v_e.join_locked then
    return jsonb_build_object('ok', false, 'code', 'PL003');
  end if;
  select count(*) into v_count from nomad_poll.participants pa where pa.event_id = v_e.id;
  if v_count >= v_e.max_participants then
    return jsonb_build_object('ok', false, 'code', 'PL004');
  end if;

  v_nick := nullif(nomad_poll.clean_text(p_nickname), '');
  if v_nick is not null then
    if char_length(v_nick) > 30 then
      return jsonb_build_object('ok', false, 'code', 'PL007', 'field', 'nickname');
    end if;
    if nomad_poll.contains_banned_word(v_e.organization_id, v_nick) then
      return jsonb_build_object('ok', false, 'code', 'PL008');
    end if;
  elsif not nomad_poll_private.setting_bool(v_e.settings, 'allow_anonymous', true) then
    return jsonb_build_object('ok', false, 'code', 'PL007', 'field', 'nickname');
  end if;

  insert into nomad_poll.participants (organization_id, event_id, token_hash, nickname)
  values (v_e.organization_id, v_e.id, v_hash, v_nick)
  returning * into v_pa;
  return jsonb_build_object('ok', true, 'rejoined', false, 'participant_id', v_pa.id, 'event_id', v_e.id,
                            'organization_id', v_e.organization_id,
                            'topic', 'poll:' || v_e.organization_id::text || ':' || v_e.id::text);
end;
$$;

create function nomad_poll.cast_vote(p_token text, p_poll_id uuid, p_option_ids uuid[] default '{}', p_rating integer default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_pa nomad_poll.participants; v_p nomad_poll.polls; v_e nomad_poll.events; v_opts uuid[]; v_valid integer; v_id bigint;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then
    raise exception 'cast_vote: bad token' using errcode = '22023';
  end if;
  if p_poll_id is null or cardinality(coalesce(p_option_ids, '{}'::uuid[])) > 10 then
    return jsonb_build_object('ok', false, 'code', 'PL007');
  end if;
  v_pa := nomad_poll.resolve_participant(p_token);
  if v_pa.id is null or v_pa.is_blocked then
    return jsonb_build_object('ok', false, 'code', 'PL009');
  end if;
  if nomad_poll_private.rate_hit('poll:vote:' || v_pa.id::text, 20, 60) then
    return jsonb_build_object('ok', false, 'code', 'PL429');
  end if;
  -- 다른 행사의 문항은 존재 여부도 알려 주지 않는다(같은 PL006)
  select * into v_p from nomad_poll.polls where id = p_poll_id and event_id = v_pa.event_id;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'PL006');
  end if;
  select * into v_e from nomad_poll.events where id = v_pa.event_id;
  if v_e.status <> 'live' or v_e.deleted_at is not null then
    return jsonb_build_object('ok', false, 'code', 'PL002');
  end if;
  if v_p.status <> 'open' then
    return jsonb_build_object('ok', false, 'code', 'PL006');
  end if;

  v_opts := coalesce((select array_agg(distinct x) from unnest(coalesce(p_option_ids, '{}'::uuid[])) as x where x is not null), '{}'::uuid[]);
  if v_p.kind = 'rating' then
    if cardinality(v_opts) > 0 or p_rating is null or p_rating < 1 or p_rating > v_p.rating_scale then
      return jsonb_build_object('ok', false, 'code', 'PL007');
    end if;
  else
    if p_rating is not null or cardinality(v_opts) < 1
       or (v_p.kind = 'single_choice' and cardinality(v_opts) <> 1)
       or (v_p.kind = 'multiple_choice' and cardinality(v_opts) > v_p.max_choices) then
      return jsonb_build_object('ok', false, 'code', 'PL007');
    end if;
    select count(*) into v_valid from nomad_poll.poll_options o where o.poll_id = v_p.id and o.id = any (v_opts);
    if v_valid <> cardinality(v_opts) then
      return jsonb_build_object('ok', false, 'code', 'PL007');
    end if;
  end if;

  insert into nomad_poll.votes (organization_id, event_id, poll_id, participant_id, option_ids, rating)
  values (v_p.organization_id, v_p.event_id, v_p.id, v_pa.id, v_opts, case when v_p.kind = 'rating' then p_rating end)
  on conflict (poll_id, participant_id) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('ok', false, 'code', 'PL005');
  end if;
  return jsonb_build_object('ok', true, 'vote_id', v_id);
end;
$$;

create function nomad_poll.ask_question(p_token text, p_body text, p_show_nickname boolean default true) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_pa nomad_poll.participants; v_e nomad_poll.events; v_body text; v_status text; v_reason text; v_q nomad_poll.qna_questions;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then
    raise exception 'ask_question: bad token' using errcode = '22023';
  end if;
  v_pa := nomad_poll.resolve_participant(p_token);
  if v_pa.id is null or v_pa.is_blocked then
    return jsonb_build_object('ok', false, 'code', 'PL009');
  end if;
  select * into v_e from nomad_poll.events where id = v_pa.event_id;
  if v_e.status <> 'live' or v_e.deleted_at is not null then
    return jsonb_build_object('ok', false, 'code', 'PL002');
  end if;
  if not nomad_poll_private.setting_bool(v_e.settings, 'qna_enabled', true) then
    return jsonb_build_object('ok', false, 'code', 'PL010');
  end if;
  if nomad_poll_private.rate_hit('poll:ask:' || v_pa.id::text, 3, 60) then
    return jsonb_build_object('ok', false, 'code', 'PL429');
  end if;
  if (select count(*) from nomad_poll.qna_questions q where q.participant_id = v_pa.id) >= 20 then
    return jsonb_build_object('ok', false, 'code', 'PL429', 'scope', 'event');
  end if;
  if p_body is null or char_length(p_body) > 2000 then
    return jsonb_build_object('ok', false, 'code', 'PL007', 'field', 'body');
  end if;
  v_body := nomad_poll.clean_text(p_body);
  if char_length(v_body) < 1 or char_length(v_body) > 300 then
    return jsonb_build_object('ok', false, 'code', 'PL007', 'field', 'body');
  end if;
  if nomad_poll.contains_banned_word(v_e.organization_id, v_body) then
    v_status := 'hidden'; v_reason := 'banned_word';
  elsif nomad_poll_private.setting_bool(v_e.settings, 'qna_moderation', false) then
    v_status := 'pending';
  else
    v_status := 'visible';
  end if;
  insert into nomad_poll.qna_questions (organization_id, event_id, participant_id, body, show_nickname, status, hidden_reason)
  values (v_e.organization_id, v_e.id, v_pa.id, v_body, coalesce(p_show_nickname, true), v_status, v_reason)
  returning * into v_q;
  -- 금칙어로 숨긴 질문도 작성자에게는 "검토 중"으로 보인다(우회 시도 유도 방지)
  return jsonb_build_object('ok', true, 'question_id', v_q.id,
                            'status', case when v_status = 'hidden' then 'pending' else v_status end);
end;
$$;

create function nomad_poll.upvote_question(p_token text, p_question_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_pa nomad_poll.participants; v_q nomad_poll.qna_questions; v_id bigint;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then
    raise exception 'upvote_question: bad token' using errcode = '22023';
  end if;
  v_pa := nomad_poll.resolve_participant(p_token);
  if v_pa.id is null or v_pa.is_blocked then
    return jsonb_build_object('ok', false, 'code', 'PL009');
  end if;
  if nomad_poll_private.rate_hit('poll:upvote:' || v_pa.id::text, 60, 60) then
    return jsonb_build_object('ok', false, 'code', 'PL429');
  end if;
  select * into v_q from nomad_poll.qna_questions
   where id = p_question_id and event_id = v_pa.event_id and status in ('visible', 'answered');
  if not found then
    return jsonb_build_object('ok', false, 'code', 'PL006');
  end if;
  if not exists (select 1 from nomad_poll.events e where e.id = v_pa.event_id and e.status = 'live' and e.deleted_at is null) then
    return jsonb_build_object('ok', false, 'code', 'PL002');
  end if;
  insert into nomad_poll.qna_upvotes (organization_id, event_id, question_id, participant_id)
  values (v_q.organization_id, v_q.event_id, v_q.id, v_pa.id)
  on conflict (question_id, participant_id) do nothing
  returning id into v_id;
  return jsonb_build_object('ok', true, 'already', v_id is null);
end;
$$;

-- 참가자 스냅샷: 입장 직후, 재연결 직후, seq 공백 감지 시 1회 호출(폴링 아님)
create function nomad_poll.participant_snapshot(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_pa nomad_poll.participants; v_e nomad_poll.events; v_state jsonb;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then
    raise exception 'participant_snapshot: bad token' using errcode = '22023';
  end if;
  v_pa := nomad_poll.resolve_participant(p_token);
  if v_pa.id is null then
    return jsonb_build_object('ok', false, 'code', 'PL009');
  end if;
  if nomad_poll_private.rate_hit('poll:snapshot:' || v_pa.id::text, 30, 60) then
    return jsonb_build_object('ok', false, 'code', 'PL429');
  end if;
  select * into v_e from nomad_poll.events where id = v_pa.event_id;
  if v_e.deleted_at is not null or v_e.status = 'archived' then
    return jsonb_build_object('ok', false, 'code', 'PL002');
  end if;
  update nomad_poll.participants set last_seen_at = now() where id = v_pa.id;
  v_state := nomad_poll.build_public_state(v_e.id);
  if v_e.status <> 'live' then
    return jsonb_build_object('ok', true, 'seq', v_e.broadcast_seq, 'state', v_state, 'blocked', v_pa.is_blocked);
  end if;
  return jsonb_build_object(
    'ok', true, 'seq', v_e.broadcast_seq, 'state', v_state, 'blocked', v_pa.is_blocked,
    'topic', 'poll:' || v_e.organization_id::text || ':' || v_e.id::text,
    'me', jsonb_build_object(
      'participant_id', v_pa.id, 'nickname', v_pa.nickname,
      'vote', (select jsonb_build_object('poll_id', v.poll_id, 'option_ids', to_jsonb(v.option_ids), 'rating', v.rating)
                 from nomad_poll.votes v where v.participant_id = v_pa.id and v.poll_id = v_e.current_poll_id),
      'questions', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'body', q.body,
                                    'status', case when q.status = 'hidden' and q.hidden_reason = 'banned_word' then 'pending' else q.status end)
                                    order by q.created_at desc)
                               from nomad_poll.qna_questions q where q.participant_id = v_pa.id), '[]'::jsonb),
      'upvoted', coalesce((select jsonb_agg(u.question_id) from nomad_poll.qna_upvotes u where u.participant_id = v_pa.id), '[]'::jsonb)
    )
  );
end;
$$;

-- OBS 오버레이 스냅샷: 오버레이 키(원문)를 넘긴다. 실패는 행사 단위로 센다
create function nomad_poll.overlay_snapshot(p_event_id uuid, p_overlay_key text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_e nomad_poll.events; v_key text;
begin
  if p_event_id is null or p_overlay_key is null or char_length(p_overlay_key) not between 16 and 128 then
    return jsonb_build_object('ok', false, 'code', 'PL009');
  end if;
  v_key := 'poll:overlay_fail:' || p_event_id::text;
  if nomad_poll_private.rate_peek(v_key, 30, 600) then
    return jsonb_build_object('ok', false, 'code', 'PL429');
  end if;
  select * into v_e from nomad_poll.events where id = p_event_id and deleted_at is null and status in ('live', 'ended');
  if not found or v_e.overlay_key_hash is null or v_e.overlay_key_hash <> nomad_poll.token_hash(p_overlay_key) then
    perform nomad_poll_private.rate_hit(v_key, 30, 600);
    return jsonb_build_object('ok', false, 'code', 'PL009');
  end if;
  return jsonb_build_object('ok', true, 'seq', v_e.broadcast_seq, 'state', nomad_poll.build_public_state(v_e.id),
                            'topic', 'poll:' || v_e.organization_id::text || ':' || v_e.id::text);
end;
$$;

-- ---------------------------------------------------------------------
-- 15. 브로드캐스터 워커 RPC (service_role 전용). 반환 행을 Realtime Broadcast(private 채널)로 보낸다.
-- ---------------------------------------------------------------------
create function nomad_poll.collect_broadcasts(p_limit integer default 200, p_heartbeat_seconds integer default 5)
returns table (event_id uuid, topic text, payload jsonb)
language plpgsql security definer set search_path = ''
as $$
declare
  r nomad_poll.events; v_vote_seq bigint; v_qna_seq bigint; v_count integer; v_dirty boolean; v_seq bigint; v_emit boolean;
begin
  if nomad_poll_private.caller_is_client() then
    raise exception 'collect_broadcasts: service_role only' using errcode = '42501';
  end if;
  for r in
    select e.* from nomad_poll.events e
    where e.deleted_at is null
      and (e.status = 'live' or e.state_version > e.broadcast_state_version)
    order by e.broadcast_at nulls first
    limit greatest(coalesce(p_limit, 200), 1)
    for update skip locked
  loop
    -- 행사별 격리: 한 행사의 오류가 전체 브로드캐스트를 멈추지 않게 한다. 실패한 행사는 이번 회차를 건너뛴다(갱신도 롤백)
    v_emit := false;
    begin
    v_vote_seq := 0;
    if r.current_poll_id is not null then
      select coalesce(max(v.id), 0) into v_vote_seq from nomad_poll.votes v where v.poll_id = r.current_poll_id;
    end if;
    v_qna_seq := greatest(
      coalesce((select max(q.change_seq) from nomad_poll.qna_questions q where q.event_id = r.id), 0),
      coalesce((select max(u.change_seq) from nomad_poll.qna_upvotes u where u.event_id = r.id), 0));
    select count(*) into v_count from nomad_poll.participants pa where pa.event_id = r.id;
    v_dirty := r.state_version > r.broadcast_state_version or v_vote_seq <> r.broadcast_vote_seq
               or v_qna_seq <> r.broadcast_qna_seq or v_count <> r.broadcast_participant_count;
    if v_dirty or r.broadcast_at is null
       or r.broadcast_at < now() - make_interval(secs => greatest(coalesce(p_heartbeat_seconds, 5), 1)) then
      v_seq := r.broadcast_seq + 1;
      update nomad_poll.events e
         set broadcast_state_version = r.state_version, broadcast_vote_seq = v_vote_seq, broadcast_qna_seq = v_qna_seq,
             broadcast_participant_count = v_count, broadcast_seq = v_seq, broadcast_at = now()
       where e.id = r.id;
      event_id := r.id;
      topic := 'poll:' || r.organization_id::text || ':' || r.id::text;
      if v_dirty then
        payload := jsonb_build_object('type', 'state', 'seq', v_seq, 'state', nomad_poll.build_public_state(r.id));
      else
        payload := jsonb_build_object('type', 'hb', 'seq', v_seq, 'event_id', r.id);
      end if;
      v_emit := true;
    end if;
    exception when others then
      raise warning 'collect_broadcasts: event % skipped (%: %)', r.id, sqlstate, sqlerrm;
      v_emit := false;
    end;
    if v_emit then
      return next;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 16. 보존/정리 (service_role, 매시간)
-- ---------------------------------------------------------------------
create function nomad_poll.purge_expired_events() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_ended integer := 0; v_archived integer := 0; v_purged integer := 0; v_deleted integer := 0;
begin
  if nomad_poll_private.caller_is_client() then
    raise exception 'purge_expired_events: service_role only' using errcode = '42501';
  end if;
  for v_id in select id from nomad_poll.events where status = 'live' and deleted_at is null
                and started_at < now() - interval '24 hours' loop
    perform nomad_poll.end_event_internal(v_id);
    v_ended := v_ended + 1;
  end loop;
  update nomad_poll.events set status = 'archived', archived_at = now()
   where status = 'ended' and deleted_at is null and ended_at < now() - interval '7 days';
  get diagnostics v_archived = row_count;
  for v_id in select id from nomad_poll.events where status in ('ended', 'archived') and purged_at is null
                and retention_until is not null and retention_until < now() loop
    delete from nomad_poll.participants where event_id = v_id;
    update nomad_poll.events set purged_at = now() where id = v_id;
    v_purged := v_purged + 1;
  end loop;
  delete from nomad_poll.events where deleted_at is not null and deleted_at < now() - interval '7 days';
  get diagnostics v_deleted = row_count;
  return jsonb_build_object('ended', v_ended, 'archived', v_archived, 'purged', v_purged, 'deleted', v_deleted);
end;
$$;

-- ---------------------------------------------------------------------
-- 17. 함수 EXECUTE 정리: 전부 회수한 뒤 허용 목록만
-- ---------------------------------------------------------------------
revoke all on all functions in schema nomad_poll from public, anon, authenticated;
revoke all on all functions in schema nomad_poll_private from public, anon, authenticated;
grant execute on all functions in schema nomad_poll to service_role;
grant execute on all functions in schema nomad_poll_private to service_role;

-- banned_words.normalized 생성 컬럼 계산
grant execute on function nomad_poll.normalize_text(text) to authenticated;
-- 진행자 RPC
grant execute on function nomad_poll.create_event(uuid, text, text, jsonb) to authenticated;
grant execute on function nomad_poll.transition_event(uuid, text) to authenticated;
grant execute on function nomad_poll.set_current_poll(uuid, uuid) to authenticated;
grant execute on function nomad_poll.transition_poll(uuid, text) to authenticated;
grant execute on function nomad_poll.moderate_question(uuid, text) to authenticated;
grant execute on function nomad_poll.block_participant(uuid, boolean) to authenticated;
grant execute on function nomad_poll.rotate_overlay_key(uuid) to authenticated;
grant execute on function nomad_poll.set_event_passcode(uuid, text) to authenticated;
grant execute on function nomad_poll.delete_event(uuid) to authenticated;
grant execute on function nomad_poll.host_poll_results(uuid) to authenticated;
-- 청중 공개 RPC(D8): anon·authenticated 모두(로그인한 진행자도 청중으로 참여 가능)
grant execute on function nomad_poll.join_event(text, text, text, text, text) to anon, authenticated;
grant execute on function nomad_poll.participant_snapshot(text) to anon, authenticated;
grant execute on function nomad_poll.cast_vote(text, uuid, uuid[], integer) to anon, authenticated;
grant execute on function nomad_poll.ask_question(text, text, boolean) to anon, authenticated;
grant execute on function nomad_poll.upvote_question(text, uuid) to anon, authenticated;
grant execute on function nomad_poll.overlay_snapshot(uuid, text) to anon, authenticated;
-- collect_broadcasts · purge_expired_events 는 service_role 만.

-- ---------------------------------------------------------------------
-- 18. Realtime Broadcast 권한(private 채널). realtime 스키마가 있는 Supabase 에서만 적용된다.
--   토픽: poll:<organization_id>:<event_id> (공개 상태), poll:<organization_id>:<event_id>:host (진행자 알림)
--   진행자: 조직 멤버면 수신. 청중/오버레이: 서버가 발급한 단기 JWT(role anon, claim poll_topic)의 토픽과 같을 때만. 송신 정책 없음(service_role만).
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('realtime.messages') is not null then
    execute 'drop policy if exists poll_broadcast_read_member on realtime.messages';
    execute $p$
      create policy poll_broadcast_read_member on realtime.messages for select to authenticated
      using (
        realtime.messages.extension = 'broadcast'
        and split_part((select realtime.topic()), ':', 1) = 'poll'
        and split_part((select realtime.topic()), ':', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and nomad_core.organization_role(split_part((select realtime.topic()), ':', 2)::uuid) is not null
      )$p$;
    execute 'drop policy if exists poll_broadcast_read_audience on realtime.messages';
    execute $p$
      create policy poll_broadcast_read_audience on realtime.messages for select to anon
      using (
        realtime.messages.extension = 'broadcast'
        and (select realtime.topic()) = (select auth.jwt() ->> 'poll_topic')
        and coalesce((select auth.jwt() ->> 'poll_aud'), '') in ('participant', 'overlay')
      )$p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 19. 플랫폼 기본 금칙어(최소 목록. 운영 목록은 service_role 이 관리)
-- ---------------------------------------------------------------------
insert into nomad_poll.banned_words (organization_id, word)
select null, w from unnest(array['시발', '씨발', '병신', '개새끼', '좆', 'fuck', 'shit']) as w
where not exists (select 1 from nomad_poll.banned_words b where b.organization_id is null and b.normalized = nomad_poll.normalize_text(w));

commit;
