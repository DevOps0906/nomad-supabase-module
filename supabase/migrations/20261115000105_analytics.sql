begin;

-- Analytics Flow · 조직형 · 원본 청사진: blueprints/org/analytics/schema.draft.sql
-- 되돌림: drop schema nomad_analytics cascade; delete from nomad_core.products where code = 'analytics';

create schema nomad_analytics;
revoke all on schema nomad_analytics from public, anon, authenticated;
grant usage on schema nomad_analytics to authenticated, service_role;

insert into nomad_core.products (code, name) values ('analytics', 'Analytics Flow');

create table nomad_analytics.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text not null,
  owner_id uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_analytics.projects is '분석 프로젝트';
create index projects_org_created on nomad_analytics.projects(organization_id, created_at desc);
create index projects_owner_id on nomad_analytics.projects(owner_id);
alter table nomad_analytics.projects enable row level security;
create policy projects_select on nomad_analytics.projects for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy projects_insert on nomad_analytics.projects for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and owner_id = (select auth.uid()));
create policy projects_update on nomad_analytics.projects for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy projects_delete on nomad_analytics.projects for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.datasets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  file_path text,
  "rows" jsonb,
  schema_json jsonb,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, project_id) references nomad_analytics.projects(organization_id, id) on delete cascade
);
comment on table nomad_analytics.datasets is '프로젝트에 올린 데이터셋';
create index datasets_org_created on nomad_analytics.datasets(organization_id, created_at desc);
create index datasets_project_id on nomad_analytics.datasets(project_id);
alter table nomad_analytics.datasets enable row level security;
create policy datasets_select on nomad_analytics.datasets for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy datasets_insert on nomad_analytics.datasets for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy datasets_update on nomad_analytics.datasets for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy datasets_delete on nomad_analytics.datasets for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.analysis_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dataset_id uuid,
  step numeric,
  result_json jsonb,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, dataset_id) references nomad_analytics.datasets(organization_id, id) on delete cascade
);
comment on table nomad_analytics.analysis_runs is '데이터셋 분석 실행 기록';
create index analysis_runs_org_created on nomad_analytics.analysis_runs(organization_id, created_at desc);
create index analysis_runs_dataset_id on nomad_analytics.analysis_runs(dataset_id);
alter table nomad_analytics.analysis_runs enable row level security;
create policy analysis_runs_select on nomad_analytics.analysis_runs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy analysis_runs_insert on nomad_analytics.analysis_runs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy analysis_runs_update on nomad_analytics.analysis_runs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy analysis_runs_delete on nomad_analytics.analysis_runs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.dashboards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  name text not null,
  layout_json jsonb,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, project_id) references nomad_analytics.projects(organization_id, id) on delete cascade
);
comment on table nomad_analytics.dashboards is '프로젝트 대시보드';
create index dashboards_org_created on nomad_analytics.dashboards(organization_id, created_at desc);
create index dashboards_project_id on nomad_analytics.dashboards(project_id);
alter table nomad_analytics.dashboards enable row level security;
create policy dashboards_select on nomad_analytics.dashboards for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy dashboards_insert on nomad_analytics.dashboards for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy dashboards_update on nomad_analytics.dashboards for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy dashboards_delete on nomad_analytics.dashboards for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.widgets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dashboard_id uuid,
  type text not null default 'chart' check (type in ('chart','table','kpi')),
  query_json jsonb,
  created_at timestamptz not null default now(),
  foreign key (organization_id, dashboard_id) references nomad_analytics.dashboards(organization_id, id) on delete cascade
);
comment on table nomad_analytics.widgets is '대시보드 위젯';
comment on column nomad_analytics.widgets.type is '차트·표·KPI';
create index widgets_org_created on nomad_analytics.widgets(organization_id, created_at desc);
create index widgets_dashboard_id on nomad_analytics.widgets(dashboard_id);
alter table nomad_analytics.widgets enable row level security;
create policy widgets_select on nomad_analytics.widgets for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy widgets_insert on nomad_analytics.widgets for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy widgets_update on nomad_analytics.widgets for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy widgets_delete on nomad_analytics.widgets for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  run_id uuid,
  format text not null default 'pdf' check (format in ('pdf','ppt')),
  file_path text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, run_id) references nomad_analytics.analysis_runs(organization_id, id) on delete cascade
);
comment on table nomad_analytics.reports is '분석 실행 결과 보고서';
comment on column nomad_analytics.reports.format is 'PDF·PPT';
create index reports_org_created on nomad_analytics.reports(organization_id, created_at desc);
create index reports_run_id on nomad_analytics.reports(run_id);
alter table nomad_analytics.reports enable row level security;
create policy reports_select on nomad_analytics.reports for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy reports_insert on nomad_analytics.reports for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy reports_update on nomad_analytics.reports for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy reports_delete on nomad_analytics.reports for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_analytics.share_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  dashboard_id uuid,
  token text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id, dashboard_id) references nomad_analytics.dashboards(organization_id, id) on delete cascade
);
comment on table nomad_analytics.share_links is '대시보드 공유 링크';
create index share_links_org_created on nomad_analytics.share_links(organization_id, created_at desc);
create index share_links_dashboard_id on nomad_analytics.share_links(dashboard_id);
alter table nomad_analytics.share_links enable row level security;
create policy share_links_select on nomad_analytics.share_links for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy share_links_insert on nomad_analytics.share_links for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy share_links_update on nomad_analytics.share_links for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy share_links_delete on nomad_analytics.share_links for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

revoke all on all tables in schema nomad_analytics from public, anon, authenticated;
grant all on all tables in schema nomad_analytics to service_role;
grant select, insert, delete on nomad_analytics.projects to authenticated;
grant update (name) on nomad_analytics.projects to authenticated;
grant select, insert, delete on nomad_analytics.datasets to authenticated;
grant update (project_id, file_path, "rows", schema_json) on nomad_analytics.datasets to authenticated;
grant select, insert, delete on nomad_analytics.analysis_runs to authenticated;
grant update (dataset_id, step, result_json) on nomad_analytics.analysis_runs to authenticated;
grant select, insert, delete on nomad_analytics.dashboards to authenticated;
grant update (project_id, name, layout_json) on nomad_analytics.dashboards to authenticated;
grant select, insert, delete on nomad_analytics.widgets to authenticated;
grant update (dashboard_id, type, query_json) on nomad_analytics.widgets to authenticated;
grant select, insert, delete on nomad_analytics.reports to authenticated;
grant update (run_id, format, file_path) on nomad_analytics.reports to authenticated;
grant select on nomad_analytics.share_links to authenticated;
grant delete on nomad_analytics.share_links to authenticated;
grant insert (organization_id, dashboard_id, expires_at) on nomad_analytics.share_links to authenticated;
grant update (dashboard_id, expires_at) on nomad_analytics.share_links to authenticated;

commit;
