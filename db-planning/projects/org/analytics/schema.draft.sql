-- analytics · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists analytics;

create table analytics.projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  name text,
  owner_id uuid references core.profiles(user_id),
  created_at timestamptz not null default now()
);
create index idx_projects_org_id on analytics.projects(org_id);
alter table analytics.projects enable row level security;
create policy projects_select_member on analytics.projects for select using (core.is_member(org_id));
create policy projects_insert_member on analytics.projects for insert with check (core.is_member(org_id));
create policy projects_update_member on analytics.projects for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy projects_delete_admin on analytics.projects for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table analytics.datasets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references analytics.projects(id) on delete cascade,
  file_path text,
  "rows" jsonb,
  schema_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_datasets_org_id on analytics.datasets(org_id);
alter table analytics.datasets enable row level security;
create policy datasets_select_member on analytics.datasets for select using (core.is_member(org_id));
create policy datasets_insert_member on analytics.datasets for insert with check (core.is_member(org_id));
create policy datasets_update_member on analytics.datasets for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy datasets_delete_admin on analytics.datasets for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table analytics.analysis_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  dataset_id uuid references analytics.datasets(id) on delete cascade,
  step numeric,  -- 7단계 중
  result_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_analysis_runs_org_id on analytics.analysis_runs(org_id);
alter table analytics.analysis_runs enable row level security;
create policy analysis_runs_select_member on analytics.analysis_runs for select using (core.is_member(org_id));
create policy analysis_runs_insert_member on analytics.analysis_runs for insert with check (core.is_member(org_id));
create policy analysis_runs_update_member on analytics.analysis_runs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy analysis_runs_delete_admin on analytics.analysis_runs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table analytics.dashboards (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references analytics.projects(id) on delete cascade,
  name text,
  layout_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_dashboards_org_id on analytics.dashboards(org_id);
alter table analytics.dashboards enable row level security;
create policy dashboards_select_member on analytics.dashboards for select using (core.is_member(org_id));
create policy dashboards_insert_member on analytics.dashboards for insert with check (core.is_member(org_id));
create policy dashboards_update_member on analytics.dashboards for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy dashboards_delete_admin on analytics.dashboards for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table analytics.widgets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  dashboard_id uuid references analytics.dashboards(id) on delete cascade,
  type text,  -- 차트·표·KPI
  query_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_widgets_org_id on analytics.widgets(org_id);
alter table analytics.widgets enable row level security;
create policy widgets_select_member on analytics.widgets for select using (core.is_member(org_id));
create policy widgets_insert_member on analytics.widgets for insert with check (core.is_member(org_id));
create policy widgets_update_member on analytics.widgets for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy widgets_delete_admin on analytics.widgets for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table analytics.reports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  run_id uuid references analytics.analysis_runs(id) on delete cascade,
  format text,  -- PDF·PPT
  file_path text,
  created_at timestamptz not null default now()
);
create index idx_reports_org_id on analytics.reports(org_id);
alter table analytics.reports enable row level security;
create policy reports_select_member on analytics.reports for select using (core.is_member(org_id));
create policy reports_insert_member on analytics.reports for insert with check (core.is_member(org_id));
create policy reports_update_member on analytics.reports for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy reports_delete_admin on analytics.reports for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table analytics.share_links (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  dashboard_id uuid references analytics.dashboards(id) on delete cascade,
  token text,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_share_links_org_id on analytics.share_links(org_id);
alter table analytics.share_links enable row level security;
create policy share_links_select_member on analytics.share_links for select using (core.is_member(org_id));
create policy share_links_insert_member on analytics.share_links for insert with check (core.is_member(org_id));
create policy share_links_update_member on analytics.share_links for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy share_links_delete_admin on analytics.share_links for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

