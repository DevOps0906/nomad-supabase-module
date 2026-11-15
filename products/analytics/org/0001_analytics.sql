-- Analytics Flow Studio 이식 · 조직형(org안). 원본: D:\WorkSpace\DEV\analytics-flow-studio\supabase\migrations 8개(public 스키마, 개인 owner_id)
-- 청사진 supabase/migrations/*_analytics.sql 은 참고만(같은 스키마 이름이라 검사는 청사진을 drop 한 뒤 적용, 함께 설치하지 않는다).
-- owner_id(개인) → organization_id(조직) + created_by·user_id(행위자), public.profiles·handle_new_user → nomad_core 프로필(코어),
-- public.url_token → nomad_analytics.new_token(서버 전용), 버킷 datasets·reports → analytics-datasets·analytics-reports(경로 <조직>/analytics/…).
-- 플랜: 원본은 플랜 없음(전부 무료). data_analysis(작업 공간)=A·B·C, automation(파이프라인·예약·웹훅)=A·B, share_links(공유 링크)=A.
--   구독 끊김(구독 없음·inactive·만료 = C): 자동화·공유 생성 잠김, 읽기·기존 공유 열람·공유 해제·자동화 끄기는 유지.
-- plan_limits 키(수치 시드 안 함, 키 없으면 0 = fail-closed): max_files_per_project(DB 트리거) · ai_calls_per_day(서버). 대응표: products/analytics/existing.md
-- 전제: core 20261116000100(org_has_feature) · 20261118000100(org_plan_limit) · 20261119000100(touch_updated_at) · 20261120000100(audit·is_privileged_session).
-- 되돌림: drop schema nomad_analytics cascade; delete from storage.buckets where id in ('analytics-datasets', 'analytics-reports');
--   delete from nomad_core.plan_features where product_code = 'analytics' and feature_code in ('automation'); delete from nomad_core.features where product_code = 'analytics' and code = 'automation';
-- SQLSTATE: 23503 실행이 참조하는 데이터셋 삭제 · AN001 프로젝트당 파일 한도 · AN002 플랜 기능 잠김 · AN003 참조 데이터셋이 다른 조직·프로젝트 · 42501 권한·비멤버 · P0002 없음(존재 비노출)
begin;

create schema nomad_analytics;
revoke all on schema nomad_analytics from public, anon, authenticated;
grant usage on schema nomad_analytics to anon, authenticated, service_role;  -- anon: 공개 읽기 RPC get_shared_report 하나만, 표 권한 0
alter default privileges in schema nomad_analytics revoke execute on functions from public;
comment on schema nomad_analytics is 'Analytics Flow Studio: CSV·엑셀 업로드 → 7단계 분석 → 대시보드·보고서·공유·자동화';

insert into nomad_core.products (code, name) values ('analytics', 'Analytics Flow') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values ('analytics', 'A', 'A'), ('analytics', 'B', 'B'), ('analytics', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('analytics', 'data_analysis', '작업 공간(프로젝트·데이터셋·분석·질문·보고서)'),
  ('analytics', 'automation', '자동화(파이프라인·예약·웹훅)'),
  ('analytics', 'share_links', '보고서 외부 공유 링크')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('analytics', 'A', 'data_analysis'), ('analytics', 'B', 'data_analysis'), ('analytics', 'C', 'data_analysis'),
  ('analytics', 'A', 'automation'), ('analytics', 'B', 'automation'),
  ('analytics', 'A', 'share_links')
on conflict do nothing;

-- =====================================================================
-- 1. 도우미
-- =====================================================================
-- 정책용(사용자 문맥): 멤버십 + 작업 공간 기능(has_feature 가 둘 다 본다, 조직 비활성 = 거짓)
create function nomad_analytics.has_access(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.has_feature(target_organization, 'analytics', 'data_analysis'), false) $$;

-- 쓰기: owner·admin·editor(원본 본인) + 작업 공간
create function nomad_analytics.can_edit(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin', 'editor'), false)
     and nomad_analytics.has_access(target_organization)
$$;

-- 관리: owner·admin + 작업 공간(프로젝트 삭제, 공유 링크)
create function nomad_analytics.can_manage(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(nomad_core.organization_role(target_organization) in ('owner', 'admin'), false)
     and nomad_analytics.has_access(target_organization)
$$;

-- 서버·트리거 전용(사용자 실행 권한 없음): 기능(조직 활성 포함, 멤버십 무관) · 수량 한도(키 없으면 0)
create function nomad_analytics.org_feature(target_organization uuid, target_feature text) returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_has_feature(target_organization, 'analytics', target_feature), false) $$;

create function nomad_analytics.limit_of(target_organization uuid, target_key text) returns integer
language sql stable security definer set search_path = ''
as $$ select coalesce(nomad_core.org_plan_limit(target_organization, 'analytics', target_key), 0) $$;

-- URL 안전 토큰(24자). 원본 public.url_token. 표 기본값으로 서버·RPC 안에서만 쓴다.
create function nomad_analytics.new_token() returns text
language sql volatile set search_path = ''
as $$ select translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/=', '-_') $$;

-- =====================================================================
-- 2. 표 (원본 public 17개, profiles 는 코어로 대체)
-- =====================================================================
create table nomad_analytics.projects (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name            text not null constraint projects_name_check check (char_length(name) between 1 and 100),
  status          text not null default 'draft'
                  constraint projects_status_check check (status in ('draft', 'analyzing', 'waiting_user', 'completed', 'failed')),
  goal            jsonb,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id)
);
create index projects_org_updated_idx on nomad_analytics.projects (organization_id, updated_at desc);
comment on table nomad_analytics.projects is '분석 프로젝트. 이름만 편집자, 상태·목표는 분석 서버, 삭제는 owner·admin.';

create table nomad_analytics.datasets (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id      uuid not null,
  file_name       text not null constraint datasets_file_name_check check (char_length(file_name) between 1 and 255),
  file_type       text not null constraint datasets_file_type_check check (file_type in ('csv', 'xlsx')),
  size_bytes      bigint not null constraint datasets_size_check check (size_bytes > 0 and size_bytes <= 52428800),
  sheet_name      text constraint datasets_sheet_name_check check (char_length(sheet_name) <= 100),
  row_count       integer,
  column_count    integer,
  profile         jsonb,
  inspection      jsonb,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint datasets_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade
);
create index datasets_org_project_idx on nomad_analytics.datasets (organization_id, project_id);
create index datasets_project_idx on nomad_analytics.datasets (project_id);
comment on table nomad_analytics.datasets is '업로드 파일(CSV·엑셀). 프로젝트당 개수는 plan_limits max_files_per_project(키 없으면 0). 검사 결과는 서버.';

-- 원본 불변: 사용자는 raw v1 만 넣고 수정·삭제 없음(데이터셋 삭제 시 연쇄 삭제). 정제본은 서버가 새 버전으로.
create table nomad_analytics.dataset_versions (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dataset_id      uuid not null,
  version         integer not null constraint dataset_versions_version_check check (version between 1 and 9999),
  kind            text not null constraint dataset_versions_kind_check check (kind in ('raw', 'cleaned')),
  storage_path    text not null,
  row_count       integer,
  created_at      timestamptz not null default now(),
  unique (dataset_id, version),
  constraint dataset_versions_path_check check (storage_path ~ ('^' || organization_id::text
    || '/analytics/datasets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(raw/source\.(csv|xlsx)|v[0-9]{1,4}\.parquet)$')),
  constraint dataset_versions_dataset_fk foreign key (dataset_id, organization_id)
    references nomad_analytics.datasets (id, organization_id) on delete cascade
);
create index dataset_versions_org_idx on nomad_analytics.dataset_versions (organization_id);
comment on table nomad_analytics.dataset_versions is '데이터셋 버전(원본 raw·정제 cleaned). 파일은 analytics-datasets 버킷 <조직>/analytics/datasets/<프로젝트>/<데이터셋>/….';

create table nomad_analytics.analysis_runs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id      uuid not null,
  dataset_id      uuid not null,
  dataset_ids     uuid[] not null constraint analysis_runs_dataset_ids_check check (cardinality(dataset_ids) between 1 and 100),
  status          text not null default 'pending'
                  constraint analysis_runs_status_check check (status in ('pending', 'running', 'waiting_user', 'done', 'failed')),
  current_step    integer not null default 0 constraint analysis_runs_step_check check (current_step between 0 and 7),
  trigger         text not null default 'manual'
                  constraint analysis_runs_trigger_check check (trigger in ('manual', 'schedule', 'webhook', 'upload')),
  error           text,
  started_at      timestamptz,
  finished_at     timestamptz,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint analysis_runs_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade,
  -- 데이터셋을 지워도 실행·보고서·대시보드·공유가 따라 지워지지 않게 no action(프로젝트 삭제는 프로젝트 FK 로 함께 지운다)
  constraint analysis_runs_dataset_fk foreign key (dataset_id, organization_id)
    references nomad_analytics.datasets (id, organization_id)
);
create index analysis_runs_org_project_idx on nomad_analytics.analysis_runs (organization_id, project_id, created_at desc);
create index analysis_runs_dataset_idx on nomad_analytics.analysis_runs (dataset_id);
comment on table nomad_analytics.analysis_runs is '7단계 분석 실행. 편집자는 수동 실행만 만들고 진행 상태는 서버. 예약·웹훅 실행은 기능 automation.';

create table nomad_analytics.run_steps (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  run_id          uuid not null,
  step_no         integer not null constraint run_steps_step_check check (step_no between 1 and 7),
  status          text not null default 'pending'
                  constraint run_steps_status_check check (status in ('pending', 'running', 'waiting_user', 'done', 'failed', 'skipped')),
  output          jsonb,
  error           text,
  started_at      timestamptz,
  finished_at     timestamptz,
  created_at      timestamptz not null default now(),
  unique (run_id, step_no),
  constraint run_steps_run_fk foreign key (run_id, organization_id)
    references nomad_analytics.analysis_runs (id, organization_id) on delete cascade
);
create index run_steps_org_idx on nomad_analytics.run_steps (organization_id);
comment on table nomad_analytics.run_steps is '실행 단계별 결과(서버 기록).';

create table nomad_analytics.cleaning_proposals (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  run_id          uuid not null,
  kind            text not null,
  title           text not null,
  description     text,
  column_name     text,
  plan            jsonb not null,
  preview         jsonb,
  affected_rows   integer not null default 0,
  decision        text not null default 'pending'
                  constraint cleaning_proposals_decision_check check (decision in ('pending', 'applied', 'skipped')),
  chosen          jsonb,
  sort            integer not null default 0,
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint cleaning_proposals_run_fk foreign key (run_id, organization_id)
    references nomad_analytics.analysis_runs (id, organization_id) on delete cascade
);
create index cleaning_proposals_run_idx on nomad_analytics.cleaning_proposals (run_id, sort);
create index cleaning_proposals_org_idx on nomad_analytics.cleaning_proposals (organization_id);
comment on table nomad_analytics.cleaning_proposals is '정제 제안. 생성·결정 반영은 서버(사용자 결정은 분석 서버 API 경유).';

create table nomad_analytics.change_logs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  proposal_id     uuid,
  run_id          uuid not null,
  detail          jsonb not null,
  affected_rows   integer not null default 0,
  created_at      timestamptz not null default now(),
  constraint change_logs_proposal_fk foreign key (proposal_id, organization_id)
    references nomad_analytics.cleaning_proposals (id, organization_id) on delete set null (proposal_id),
  constraint change_logs_run_fk foreign key (run_id, organization_id)
    references nomad_analytics.analysis_runs (id, organization_id) on delete cascade
);
create index change_logs_run_idx on nomad_analytics.change_logs (run_id);
create index change_logs_org_idx on nomad_analytics.change_logs (organization_id);
create index change_logs_proposal_idx on nomad_analytics.change_logs (proposal_id);
comment on table nomad_analytics.change_logs is '정제 변경 기록(서버).';

create table nomad_analytics.dashboards (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  run_id          uuid not null unique,
  project_id      uuid not null,
  spec            jsonb not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint dashboards_run_fk foreign key (run_id, organization_id)
    references nomad_analytics.analysis_runs (id, organization_id) on delete cascade,
  constraint dashboards_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade
);
create index dashboards_org_project_idx on nomad_analytics.dashboards (organization_id, project_id);
create index dashboards_project_idx on nomad_analytics.dashboards (project_id);
comment on table nomad_analytics.dashboards is '실행 결과 대시보드(서버 생성·말로 수정 반영도 서버).';

create table nomad_analytics.widgets (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dashboard_id    uuid not null,
  chart_type      text not null,
  config          jsonb not null,
  sort            integer not null default 0,
  created_at      timestamptz not null default now(),
  constraint widgets_dashboard_fk foreign key (dashboard_id, organization_id)
    references nomad_analytics.dashboards (id, organization_id) on delete cascade
);
create index widgets_dashboard_idx on nomad_analytics.widgets (dashboard_id, sort);
create index widgets_org_idx on nomad_analytics.widgets (organization_id);
comment on table nomad_analytics.widgets is '대시보드 위젯(서버).';

create table nomad_analytics.reports (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  run_id          uuid not null,
  project_id      uuid not null,
  version         integer not null default 1,
  summary         text,
  html_path       text,
  pdf_path        text,
  pdf_error       text,
  docx_path       text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint reports_run_fk foreign key (run_id, organization_id)
    references nomad_analytics.analysis_runs (id, organization_id) on delete cascade,
  constraint reports_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade,
  constraint reports_paths_check check (
    (html_path is null or html_path ~ ('^' || organization_id::text || '/analytics/reports/[A-Za-z0-9_/-]+\.html$'))
    and (pdf_path is null or pdf_path ~ ('^' || organization_id::text || '/analytics/reports/[A-Za-z0-9_/-]+\.pdf$'))
    and (docx_path is null or docx_path ~ ('^' || organization_id::text || '/analytics/reports/[A-Za-z0-9_/-]+\.docx$')))
);
create index reports_org_project_idx on nomad_analytics.reports (organization_id, project_id, created_at desc);
create index reports_run_idx on nomad_analytics.reports (run_id);
comment on table nomad_analytics.reports is '분석 보고서(서버). 파일은 analytics-reports 버킷 <조직>/analytics/reports/….';

create table nomad_analytics.report_sections (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  report_id       uuid not null,
  kind            text not null,
  content         jsonb not null,
  sort            integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint report_sections_report_fk foreign key (report_id, organization_id)
    references nomad_analytics.reports (id, organization_id) on delete cascade,
  -- chart 는 공개 RPC 로 anon 에게 나가므로 짧은 식별자만
  constraint report_sections_chart_check check (not (content ? 'chart')
    or (jsonb_typeof(content -> 'chart') = 'string' and (content ->> 'chart') ~ '^[a-z][a-z0-9_]{0,31}$'))
);
create index report_sections_report_idx on nomad_analytics.report_sections (report_id, sort);
create index report_sections_org_idx on nomad_analytics.report_sections (organization_id);
comment on table nomad_analytics.report_sections is '보고서 섹션. 편집자는 content.chart(그래프 유형)만 바꾼다(트리거).';

create table nomad_analytics.pipelines (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id      uuid not null unique,
  name            text not null default '자동 분석' constraint pipelines_name_check check (char_length(name) between 1 and 100),
  settings        jsonb not null default '{}'::jsonb,
  enabled         boolean not null default true,
  webhook_token   text not null unique default nomad_analytics.new_token(),
  last_run_at     timestamptz,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, organization_id),
  constraint pipelines_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade
);
create index pipelines_org_idx on nomad_analytics.pipelines (organization_id);
comment on table nomad_analytics.pipelines is '자동화 파이프라인(프로젝트당 1). 생성·설정은 서버, 켜기·끄기는 편집자(켜기는 기능 automation). webhook_token 은 사용자 SELECT 제외(owner·admin RPC).';

create table nomad_analytics.schedules (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  pipeline_id     uuid not null unique,
  frequency       text not null default 'weekly' constraint schedules_frequency_check check (frequency in ('daily', 'weekly', 'monthly')),
  hour            integer not null default 9 constraint schedules_hour_check check (hour between 0 and 23),
  weekday         integer constraint schedules_weekday_check check (weekday between 0 and 6),
  cron            text,
  channel         text,
  enabled         boolean not null default true,
  next_run_at     timestamptz,
  last_run_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint schedules_pipeline_fk foreign key (pipeline_id, organization_id)
    references nomad_analytics.pipelines (id, organization_id) on delete cascade
);
create index schedules_org_idx on nomad_analytics.schedules (organization_id);
create index schedules_next_run_idx on nomad_analytics.schedules (next_run_at) where enabled;
comment on table nomad_analytics.schedules is '파이프라인 예약(서버).';

create table nomad_analytics.usage_events (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id         uuid,
  kind            text not null,
  amount          integer not null default 1,
  created_at      timestamptz not null default now()
);
create index usage_events_org_kind_idx on nomad_analytics.usage_events (organization_id, kind, created_at desc);
comment on table nomad_analytics.usage_events is '사용량 기록(서버, AI 호출 등). 한도는 서버가 plan_limits ai_calls_per_day 로 본다.';

create table nomad_analytics.questions (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id      uuid not null,
  question        text not null,
  answer          jsonb not null,
  pinned          boolean not null default false,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint questions_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade
);
create index questions_org_project_idx on nomad_analytics.questions (organization_id, project_id, created_at desc);
create index questions_project_idx on nomad_analytics.questions (project_id);
comment on table nomad_analytics.questions is '질문 창 기록(답변은 서버 계산값). 고정·삭제는 편집자.';

create table nomad_analytics.report_shares (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  report_id       uuid not null,
  token           text not null unique default nomad_analytics.new_token(),
  expires_at      timestamptz,
  revoked         boolean not null default false,
  revoked_at      timestamptz,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  constraint report_shares_report_fk foreign key (report_id, organization_id)
    references nomad_analytics.reports (id, organization_id) on delete cascade
);
create index report_shares_org_report_idx on nomad_analytics.report_shares (organization_id, report_id);
create index report_shares_report_idx on nomad_analytics.report_shares (report_id);
comment on table nomad_analytics.report_shares is '보고서 읽기 전용 공유 링크. 만들기·해제는 RPC(owner·admin), 공개 열람은 get_shared_report.';

create table nomad_analytics.notifications (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id         uuid not null,
  project_id      uuid,
  kind            text not null,
  title           text not null,
  body            text,
  link            text,
  read_at         timestamptz,
  created_at      timestamptz not null default now(),
  -- 받는 사람은 그 조직 멤버만, 탈퇴하면 함께 지운다
  constraint notifications_member_fk foreign key (organization_id, user_id)
    references nomad_core.memberships (organization_id, user_id) on delete cascade,
  constraint notifications_project_fk foreign key (project_id, organization_id)
    references nomad_analytics.projects (id, organization_id) on delete cascade
);
create index notifications_user_idx on nomad_analytics.notifications (user_id, organization_id, created_at desc);
create index notifications_project_idx on nomad_analytics.notifications (project_id);
comment on table nomad_analytics.notifications is '사용자별 알림(서버 생성). 본인 행만 읽고 read_at 만 바꾼다.';

-- =====================================================================
-- 3. 트리거
--   서버 판별: current_user 가 authenticated·anon 이 아니면 서버(service_role 직접 또는 소유자 DEFINER 함수 안).
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['projects', 'datasets', 'dashboards', 'report_sections', 'pipelines', 'schedules', 'questions'] loop
    execute format('create trigger %1$s_touch_updated_at before update on nomad_analytics.%1$I for each row execute function nomad_core.touch_updated_at()', t);
  end loop;
end $$;

-- 서버 기록 표: 사용자 세션 쓰기 42501(grant 없음과 이중 잠금). 삭제는 연쇄 삭제가 지나가도록 막지 않는다(사용자 grant 없음).
create function nomad_analytics.guard_server_write() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    raise exception 'nomad_analytics.%: server-managed', tg_table_name using errcode = '42501';
  end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['run_steps', 'cleaning_proposals', 'change_logs', 'dashboards', 'widgets', 'reports',
                           'schedules', 'usage_events', 'report_shares'] loop
    execute format('create trigger %1$s_guard_write before insert or update on nomad_analytics.%1$I for each row execute function nomad_analytics.guard_server_write()', t);
  end loop;
  foreach t in array array['report_sections', 'pipelines', 'questions', 'notifications'] loop
    execute format('create trigger %1$s_guard_insert before insert on nomad_analytics.%1$I for each row execute function nomad_analytics.guard_server_write()', t);
  end loop;
end $$;

-- 프로젝트당 파일 수(AN001). 서버 경로 포함. 키 없으면 0(fail-closed).
create function nomad_analytics.enforce_file_limit() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_limit integer; v_count integer;
begin
  -- BEFORE 트리거는 RLS 보다 먼저 돈다: 비멤버에게 남의 조직 플랜·한도를 알려주지 않도록 먼저 거부
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'analytics: not a member of this organization' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.project_id is not distinct from old.project_id then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('analytics:files:' || new.project_id::text, 0));
  v_limit := nomad_analytics.limit_of(new.organization_id, 'max_files_per_project');
  select count(*) into v_count from nomad_analytics.datasets d where d.project_id = new.project_id and d.id <> new.id;
  if v_count >= v_limit then
    raise exception 'datasets: plan limit reached (max_files_per_project=%)', v_limit using errcode = 'AN001';
  end if;
  return new;
end;
$$;
create trigger datasets_file_limit before insert or update of project_id on nomad_analytics.datasets
  for each row execute function nomad_analytics.enforce_file_limit();

-- 사용자 데이터셋 삭제: 실행(dataset_id·dataset_ids)이 참조하면 거부(23503). 실행 결과는 프로젝트 삭제(owner·admin)로만 지운다.
create function nomad_analytics.datasets_before_delete() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- 프로젝트 삭제 연쇄(부모 행이 이미 지워짐)는 통과시킨다
  if not nomad_core.is_privileged_session()
     and exists (select 1 from nomad_analytics.projects p where p.id = old.project_id)
     and exists (select 1 from nomad_analytics.analysis_runs r
                  where r.organization_id = old.organization_id and old.id = any (r.dataset_ids)) then
    raise exception 'datasets: dataset has analysis runs' using errcode = '23503';
  end if;
  return old;
end;
$$;
create trigger datasets_before_delete before delete on nomad_analytics.datasets
  for each row execute function nomad_analytics.datasets_before_delete();

-- 사용자 원본 버전: raw v1, 경로 = <조직>/analytics/datasets/<그 데이터셋의 프로젝트>/<데이터셋>/raw/source.<형식>
create function nomad_analytics.dataset_versions_before_insert() returns trigger
language plpgsql set search_path = ''
as $$
declare v_project uuid; v_type text;
begin
  if current_user in ('authenticated', 'anon') then
    select d.project_id, d.file_type into v_project, v_type
      from nomad_analytics.datasets d where d.id = new.dataset_id and d.organization_id = new.organization_id;
    if v_project is null then
      raise exception 'dataset_versions: dataset not found' using errcode = '42501';
    end if;
    if new.kind <> 'raw' or new.version <> 1
       or new.storage_path <> format('%s/analytics/datasets/%s/%s/raw/source.%s', new.organization_id, v_project, new.dataset_id, v_type) then
      raise exception 'dataset_versions: users may only record the raw v1 upload path' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger dataset_versions_before_insert before insert on nomad_analytics.dataset_versions
  for each row execute function nomad_analytics.dataset_versions_before_insert();

-- 실행 만들기: 비멤버 선거부 · 사용자 경로 강제값 · 데이터셋 목록은 같은 조직·프로젝트(AN003) · 예약·웹훅은 automation(AN002)
create function nomad_analytics.analysis_runs_before_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_bad integer;
begin
  if not nomad_core.is_privileged_session() and nomad_core.organization_role(new.organization_id) is null then
    raise exception 'analytics: not a member of this organization' using errcode = '42501';
  end if;
  if not nomad_core.is_privileged_session() then
    new.status := 'pending';
    new.current_step := 0;
    new.trigger := 'manual';
    new.error := null;
    new.started_at := null;
    new.finished_at := null;
    new.created_by := auth.uid();
  end if;
  if new.dataset_ids is null then
    new.dataset_ids := array[new.dataset_id];
  end if;
  if not new.dataset_id = any (new.dataset_ids) then
    raise exception 'analysis_runs: dataset_id must be one of dataset_ids' using errcode = 'AN003';
  end if;
  select count(*) into v_bad from unnest(new.dataset_ids) x(id)
   where not exists (select 1 from nomad_analytics.datasets d
                      where d.id = x.id and d.organization_id = new.organization_id and d.project_id = new.project_id);
  if v_bad > 0 then
    raise exception 'analysis_runs: datasets must belong to the same organization and project' using errcode = 'AN003';
  end if;
  if new.trigger in ('schedule', 'webhook') and not nomad_analytics.org_feature(new.organization_id, 'automation') then
    raise exception 'analysis_runs: automation needs a higher plan' using errcode = 'AN002';
  end if;
  return new;
end;
$$;
create trigger analysis_runs_before_insert before insert on nomad_analytics.analysis_runs
  for each row execute function nomad_analytics.analysis_runs_before_insert();

-- 서버 경로의 실행 상태 갱신은 막지 않는다. 사용자 경로는 grant 가 없다(이중 잠금).
create trigger analysis_runs_guard_update before update on nomad_analytics.analysis_runs
  for each row execute function nomad_analytics.guard_server_write();
create trigger dataset_versions_guard_update before update on nomad_analytics.dataset_versions
  for each row execute function nomad_analytics.guard_server_write();

-- 보고서 섹션: 사용자는 content.chart 만 바꾼다(숫자·문장 불변)
create function nomad_analytics.report_sections_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if (new.content - 'chart') is distinct from (old.content - 'chart')
       or (new.content ? 'chart' and jsonb_typeof(new.content -> 'chart') <> 'string') then
      raise exception 'report_sections: only content.chart can be changed' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger report_sections_before_update before update on nomad_analytics.report_sections
  for each row execute function nomad_analytics.report_sections_before_update();

-- 알림 읽음: 사용자 경로의 read_at 은 서버 시각
create function nomad_analytics.notifications_before_update() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') and new.read_at is not null then
    new.read_at := coalesce(old.read_at, now());
  end if;
  return new;
end;
$$;
create trigger notifications_before_update before update on nomad_analytics.notifications
  for each row execute function nomad_analytics.notifications_before_update();

-- =====================================================================
-- 4. 사용자 RPC (SECURITY DEFINER, authenticated). 남의 조직 행은 존재도 알리지 않는다(P0002).
-- =====================================================================
-- 공유 링크 만들기: owner·admin + 기능 share_links. 돌려주는 값은 호출자가 SELECT 할 수 있는 컬럼만.
create function nomad_analytics.create_report_share(p_report_id uuid, p_expires_at timestamptz default null)
returns table (id uuid, token text, expires_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
declare v_org uuid; v_row nomad_analytics.report_shares;
begin
  select r.organization_id into v_org from nomad_analytics.reports r where r.id = p_report_id;
  if v_org is null or nomad_core.organization_role(v_org) is null then
    raise exception 'create_report_share: not found' using errcode = 'P0002';
  end if;
  if not nomad_analytics.can_manage(v_org) then
    raise exception 'create_report_share: owner or admin required' using errcode = '42501';
  end if;
  if not nomad_core.has_feature(v_org, 'analytics', 'share_links') then
    raise exception 'create_report_share: share_links needs a higher plan' using errcode = 'AN002';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'create_report_share: expires_at must be in the future' using errcode = '22023';
  end if;
  insert into nomad_analytics.report_shares (organization_id, report_id, expires_at, created_by)
  values (v_org, p_report_id, p_expires_at, auth.uid()) returning * into v_row;
  perform nomad_core.write_audit(v_org, 'analytics.report_share.create', 'report_share', v_row.id::text);
  return query select v_row.id, v_row.token, v_row.expires_at;
end;
$$;

-- 공유 해제: owner·admin. 구독이 끊겨도 가능(잠긴 조직도 노출을 줄일 수 있게). 이미 해제면 그대로.
create function nomad_analytics.revoke_report_share(p_share_id uuid) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_analytics.report_shares;
begin
  select * into v_row from nomad_analytics.report_shares s where s.id = p_share_id for update;
  if v_row.id is null or nomad_core.organization_role(v_row.organization_id) is null then
    raise exception 'revoke_report_share: not found' using errcode = 'P0002';
  end if;
  if nomad_core.organization_role(v_row.organization_id) not in ('owner', 'admin') then
    raise exception 'revoke_report_share: owner or admin required' using errcode = '42501';
  end if;
  if not v_row.revoked then
    update nomad_analytics.report_shares set revoked = true, revoked_at = now() where id = p_share_id;
    perform nomad_core.write_audit(v_row.organization_id, 'analytics.report_share.revoke', 'report_share', p_share_id::text);
  end if;
end;
$$;

-- 웹훅 주소용 토큰 보기: owner·admin + 기능 automation(토큰은 실행을 일으키는 비밀이라 SELECT grant 에서 뺐다)
create function nomad_analytics.pipeline_webhook_token(p_project_id uuid) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare v_row nomad_analytics.pipelines;
begin
  select * into v_row from nomad_analytics.pipelines p where p.project_id = p_project_id;
  if v_row.id is null or nomad_core.organization_role(v_row.organization_id) is null then
    raise exception 'pipeline_webhook_token: not found' using errcode = 'P0002';
  end if;
  if not nomad_analytics.can_manage(v_row.organization_id) then
    raise exception 'pipeline_webhook_token: owner or admin required' using errcode = '42501';
  end if;
  if not nomad_core.has_feature(v_row.organization_id, 'analytics', 'automation') then
    raise exception 'pipeline_webhook_token: automation needs a higher plan' using errcode = 'AN002';
  end if;
  return v_row.webhook_token;
end;
$$;

-- =====================================================================
-- 5. 공개 RPC: anon 의 유일한 경로. 읽기 전용, 토큰 형식 검사, 공개 컬럼만.
--    DB 요청 제한 없음(과부하는 앞단 몫), 섹션은 200개 상한. 구독이 끊겨도 이미 만든 공유의 열람은 유지(새 공유만 잠금).
--    해제·만료·조직 비활성은 null(원본과 같은 반환).
-- =====================================================================
create function nomad_analytics.get_shared_report(share_token text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_report uuid; v_org uuid; v_result jsonb;
begin
  if share_token is null or share_token !~ '^[A-Za-z0-9_-]{24}$' then
    return null;
  end if;
  select sh.report_id, sh.organization_id into v_report, v_org
    from nomad_analytics.report_shares sh
   where sh.token = share_token and not sh.revoked and (sh.expires_at is null or sh.expires_at > now());
  if v_report is null or not exists (select 1 from nomad_core.organizations o where o.id = v_org and o.active) then
    return null;
  end if;
  select jsonb_build_object(
    'project_name', p.name,
    'version', r.version,
    'created_at', r.created_at,
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object('kind', s.kind, 'content', s.content) order by s.sort)
      from (select s2.kind, s2.content, s2.sort from nomad_analytics.report_sections s2
             where s2.report_id = r.id order by s2.sort limit 200) s
    ), '[]'::jsonb))
  into v_result
  from nomad_analytics.reports r join nomad_analytics.projects p on p.id = r.project_id
  where r.id = v_report;
  return v_result;
end;
$$;

-- =====================================================================
-- 6. RLS 정책과 GRANT (anon: 테이블 권한 0, 사용자 insert 에 id grant 없음)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['projects', 'datasets', 'dataset_versions', 'analysis_runs', 'run_steps', 'cleaning_proposals', 'change_logs',
                           'dashboards', 'widgets', 'reports', 'report_sections', 'pipelines', 'schedules', 'usage_events',
                           'questions', 'report_shares', 'notifications'] loop
    execute format('alter table nomad_analytics.%I enable row level security', t);
  end loop;
  -- 읽기: 작업 공간 멤버(구독이 끊겨도 C 로 유지)
  foreach t in array array['projects', 'datasets', 'dataset_versions', 'analysis_runs', 'run_steps', 'cleaning_proposals', 'change_logs',
                           'dashboards', 'widgets', 'reports', 'report_sections', 'pipelines', 'schedules', 'usage_events', 'questions'] loop
    execute format('create policy %1$s_select on nomad_analytics.%1$I for select to authenticated using (nomad_analytics.has_access(organization_id))', t);
  end loop;
end $$;
revoke all on all tables in schema nomad_analytics from public, anon, authenticated;
grant all on all tables in schema nomad_analytics to service_role;

-- projects: 만들기·이름 바꾸기 편집자, 삭제 owner·admin(원본: 본인)
grant select, delete on nomad_analytics.projects to authenticated;
grant insert (organization_id, name) on nomad_analytics.projects to authenticated;
grant update (name) on nomad_analytics.projects to authenticated;
create policy projects_insert on nomad_analytics.projects for insert to authenticated with check (nomad_analytics.can_edit(organization_id));
create policy projects_update on nomad_analytics.projects for update to authenticated
  using (nomad_analytics.can_edit(organization_id)) with check (nomad_analytics.can_edit(organization_id));
create policy projects_delete on nomad_analytics.projects for delete to authenticated using (nomad_analytics.can_manage(organization_id));

-- datasets: 올리기·시트 선택·프로젝트 옮기기(같은 조직, 복합 FK)·빼기 편집자
grant select, delete on nomad_analytics.datasets to authenticated;
grant insert (organization_id, project_id, file_name, file_type, size_bytes, sheet_name) on nomad_analytics.datasets to authenticated;
grant update (project_id, sheet_name) on nomad_analytics.datasets to authenticated;
create policy datasets_insert on nomad_analytics.datasets for insert to authenticated with check (nomad_analytics.can_edit(organization_id));
create policy datasets_update on nomad_analytics.datasets for update to authenticated
  using (nomad_analytics.can_edit(organization_id)) with check (nomad_analytics.can_edit(organization_id));
create policy datasets_delete on nomad_analytics.datasets for delete to authenticated using (nomad_analytics.can_edit(organization_id));

-- dataset_versions: 원본 raw 기록만(수정·삭제 없음 = 원본 불변)
grant select on nomad_analytics.dataset_versions to authenticated;
grant insert (organization_id, dataset_id, version, kind, storage_path) on nomad_analytics.dataset_versions to authenticated;
create policy dataset_versions_insert on nomad_analytics.dataset_versions for insert to authenticated
  with check (nomad_analytics.can_edit(organization_id) and kind = 'raw');

-- analysis_runs: 수동 실행 만들기 편집자
grant select on nomad_analytics.analysis_runs to authenticated;
grant insert (organization_id, project_id, dataset_id, dataset_ids) on nomad_analytics.analysis_runs to authenticated;
create policy analysis_runs_insert on nomad_analytics.analysis_runs for insert to authenticated with check (nomad_analytics.can_edit(organization_id));

-- 서버 기록 표: 읽기만
grant select on nomad_analytics.run_steps, nomad_analytics.cleaning_proposals, nomad_analytics.change_logs, nomad_analytics.dashboards,
  nomad_analytics.widgets, nomad_analytics.reports, nomad_analytics.schedules, nomad_analytics.usage_events to authenticated;

-- report_sections: 그래프 유형 바꾸기 편집자(트리거가 chart 외 변경 거부)
grant select on nomad_analytics.report_sections to authenticated;
grant update (content) on nomad_analytics.report_sections to authenticated;
create policy report_sections_update on nomad_analytics.report_sections for update to authenticated
  using (nomad_analytics.can_edit(organization_id)) with check (nomad_analytics.can_edit(organization_id));

-- pipelines: webhook_token 제외 읽기, 켜기·끄기 편집자. 켜기는 automation, 끄기는 잠긴 조직도 가능.
grant select (id, organization_id, project_id, name, settings, enabled, last_run_at, created_by, created_at, updated_at)
  on nomad_analytics.pipelines to authenticated;
grant update (enabled) on nomad_analytics.pipelines to authenticated;
create policy pipelines_update on nomad_analytics.pipelines for update to authenticated
  using (nomad_analytics.can_edit(organization_id))
  with check (nomad_analytics.can_edit(organization_id)
              and (not enabled or nomad_core.has_feature(organization_id, 'analytics', 'automation')));

-- questions: 고정·삭제 편집자(만들기는 서버)
grant select, delete on nomad_analytics.questions to authenticated;
grant update (pinned) on nomad_analytics.questions to authenticated;
create policy questions_update on nomad_analytics.questions for update to authenticated
  using (nomad_analytics.can_edit(organization_id)) with check (nomad_analytics.can_edit(organization_id));
create policy questions_delete on nomad_analytics.questions for delete to authenticated using (nomad_analytics.can_edit(organization_id));

-- report_shares: 읽기 owner·admin(토큰 = 외부 열람 권한), 쓰기는 RPC
grant select on nomad_analytics.report_shares to authenticated;
create policy report_shares_select on nomad_analytics.report_shares for select to authenticated
  using (coalesce(nomad_core.organization_role(organization_id) in ('owner', 'admin'), false));

-- notifications: 본인 + 현재 멤버, 읽음 표시만
grant select on nomad_analytics.notifications to authenticated;
grant update (read_at) on nomad_analytics.notifications to authenticated;
create policy notifications_select on nomad_analytics.notifications for select to authenticated
  using (user_id = (select auth.uid()) and nomad_core.organization_role(organization_id) is not null);
create policy notifications_update on nomad_analytics.notifications for update to authenticated
  using (user_id = (select auth.uid()) and nomad_core.organization_role(organization_id) is not null)
  with check (user_id = (select auth.uid()) and nomad_core.organization_role(organization_id) is not null);

-- Realtime: 진행 상태·알림 푸시(RLS 적용)
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['projects', 'analysis_runs', 'run_steps', 'cleaning_proposals', 'notifications'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_analytics' and tablename = t) then
        execute format('alter publication supabase_realtime add table nomad_analytics.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- =====================================================================
-- 7. 함수 실행 권한: 기본 0, service_role 전부, authenticated 는 정책 도우미·사용자 RPC, anon 은 공개 RPC 하나.
-- =====================================================================
revoke execute on all functions in schema nomad_analytics from public, anon, authenticated;
grant execute on all functions in schema nomad_analytics to service_role;
grant execute on function
  nomad_analytics.has_access(uuid), nomad_analytics.can_edit(uuid), nomad_analytics.can_manage(uuid),
  nomad_analytics.create_report_share(uuid, timestamptz), nomad_analytics.revoke_report_share(uuid),
  nomad_analytics.pipeline_webhook_token(uuid)
to authenticated;
grant execute on function nomad_analytics.get_shared_report(text) to anon, authenticated;

-- =====================================================================
-- 8. Storage (제품 전용 버킷, 경로 <organization_id>/analytics/...). 원본 datasets·reports(첫 폴더 = 사용자) 대체.
--   analytics-datasets 비공개 50MB. 원본 raw 는 편집자가 서명 업로드(경로 고정), 정제본 parquet 은 서버.
--     편집자 삭제는 raw 업로드 직후(버전 행 기록 전)만 — 기록된 원본·정제본을 지우고 같은 경로로 다시 올리는 우회 차단.
--   analytics-reports  비공개 50MB. HTML·PDF·DOCX 는 서버. 지우기는 owner·admin.
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('analytics-datasets', 'analytics-datasets', false, 52428800, null),
  ('analytics-reports',  'analytics-reports',  false, 52428800, array['application/pdf', 'text/html', 'text/html; charset=utf-8',
     'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;

create policy nomad_analytics_files_select on storage.objects for select to authenticated
  using (bucket_id in ('analytics-datasets', 'analytics-reports') and (storage.foldername(name))[2] = 'analytics'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then nomad_analytics.has_access(((storage.foldername(name))[1])::uuid) else false end);
create policy nomad_analytics_datasets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'analytics-datasets'
              and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/analytics/datasets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/raw/source\.(csv|xlsx)$'
              and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                       then nomad_analytics.can_edit(((storage.foldername(name))[1])::uuid) else false end);
create policy nomad_analytics_files_delete on storage.objects for delete to authenticated
  using (bucket_id in ('analytics-datasets', 'analytics-reports') and (storage.foldername(name))[2] = 'analytics'
         and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  then case when bucket_id = 'analytics-datasets'
                            then name ~ '/raw/source\.(csv|xlsx)$'
                                 and nomad_analytics.can_edit(((storage.foldername(name))[1])::uuid)
                                 and not exists (select 1 from nomad_analytics.dataset_versions v where v.storage_path = name)
                            else nomad_analytics.can_manage(((storage.foldername(name))[1])::uuid) end
                  else false end);

commit;
