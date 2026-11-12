-- analytics · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create schema if not exists nomad_analytics;
revoke all on schema nomad_analytics from public, anon, authenticated;
grant usage on schema nomad_analytics to authenticated, service_role;

create table nomad_analytics.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text,
  owner_id uuid references nomad_core.profiles(user_id),
  created_at timestamptz not null default now()
);
create index idx_projects_org_id on nomad_analytics.projects(organization_id);
alter table nomad_analytics.projects enable row level security;
create policy projects_select_member on nomad_analytics.projects for select using (nomad_core.organization_role(organization_id) is not null);
create policy projects_insert_member on nomad_analytics.projects for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy projects_update_member on nomad_analytics.projects for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy projects_delete_admin on nomad_analytics.projects for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.datasets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_analytics.projects(id) on delete cascade,
  file_path text,
  "rows" jsonb,
  schema_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_datasets_org_id on nomad_analytics.datasets(organization_id);
alter table nomad_analytics.datasets enable row level security;
create policy datasets_select_member on nomad_analytics.datasets for select using (nomad_core.organization_role(organization_id) is not null);
create policy datasets_insert_member on nomad_analytics.datasets for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy datasets_update_member on nomad_analytics.datasets for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy datasets_delete_admin on nomad_analytics.datasets for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.analysis_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dataset_id uuid references nomad_analytics.datasets(id) on delete cascade,
  step numeric,  -- 7단계 중
  result_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_analysis_runs_org_id on nomad_analytics.analysis_runs(organization_id);
alter table nomad_analytics.analysis_runs enable row level security;
create policy analysis_runs_select_member on nomad_analytics.analysis_runs for select using (nomad_core.organization_role(organization_id) is not null);
create policy analysis_runs_insert_member on nomad_analytics.analysis_runs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy analysis_runs_update_member on nomad_analytics.analysis_runs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy analysis_runs_delete_admin on nomad_analytics.analysis_runs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.dashboards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_analytics.projects(id) on delete cascade,
  name text,
  layout_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_dashboards_org_id on nomad_analytics.dashboards(organization_id);
alter table nomad_analytics.dashboards enable row level security;
create policy dashboards_select_member on nomad_analytics.dashboards for select using (nomad_core.organization_role(organization_id) is not null);
create policy dashboards_insert_member on nomad_analytics.dashboards for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy dashboards_update_member on nomad_analytics.dashboards for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy dashboards_delete_admin on nomad_analytics.dashboards for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.widgets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dashboard_id uuid references nomad_analytics.dashboards(id) on delete cascade,
  type text,  -- 차트·표·KPI
  query_json jsonb,
  created_at timestamptz not null default now()
);
create index idx_widgets_org_id on nomad_analytics.widgets(organization_id);
alter table nomad_analytics.widgets enable row level security;
create policy widgets_select_member on nomad_analytics.widgets for select using (nomad_core.organization_role(organization_id) is not null);
create policy widgets_insert_member on nomad_analytics.widgets for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy widgets_update_member on nomad_analytics.widgets for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy widgets_delete_admin on nomad_analytics.widgets for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  run_id uuid references nomad_analytics.analysis_runs(id) on delete cascade,
  format text,  -- PDF·PPT
  file_path text,
  created_at timestamptz not null default now()
);
create index idx_reports_org_id on nomad_analytics.reports(organization_id);
alter table nomad_analytics.reports enable row level security;
create policy reports_select_member on nomad_analytics.reports for select using (nomad_core.organization_role(organization_id) is not null);
create policy reports_insert_member on nomad_analytics.reports for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy reports_update_member on nomad_analytics.reports for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy reports_delete_admin on nomad_analytics.reports for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.share_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dashboard_id uuid references nomad_analytics.dashboards(id) on delete cascade,
  token text,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_share_links_org_id on nomad_analytics.share_links(organization_id);
alter table nomad_analytics.share_links enable row level security;
create policy share_links_select_member on nomad_analytics.share_links for select using (nomad_core.organization_role(organization_id) is not null);
create policy share_links_insert_member on nomad_analytics.share_links for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy share_links_update_member on nomad_analytics.share_links for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy share_links_delete_admin on nomad_analytics.share_links for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

