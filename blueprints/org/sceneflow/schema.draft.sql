-- sceneflow · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create schema if not exists nomad_sceneflow;
revoke all on schema nomad_sceneflow from public, anon, authenticated;
grant usage on schema nomad_sceneflow to authenticated, service_role;

create table nomad_sceneflow.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  title text,
  aspect text,  -- 가로·세로
  resolution text,
  created_at timestamptz not null default now()
);
create index idx_projects_org_id on nomad_sceneflow.projects(organization_id);
alter table nomad_sceneflow.projects enable row level security;
create policy projects_select_member on nomad_sceneflow.projects for select using (nomad_core.organization_role(organization_id) is not null);
create policy projects_insert_member on nomad_sceneflow.projects for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy projects_update_member on nomad_sceneflow.projects for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy projects_delete_admin on nomad_sceneflow.projects for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  kind text,  -- 영상·이미지·음성
  storage_path text,
  created_at timestamptz not null default now()
);
create index idx_assets_org_id on nomad_sceneflow.assets(organization_id);
alter table nomad_sceneflow.assets enable row level security;
create policy assets_select_member on nomad_sceneflow.assets for select using (nomad_core.organization_role(organization_id) is not null);
create policy assets_insert_member on nomad_sceneflow.assets for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy assets_update_member on nomad_sceneflow.assets for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy assets_delete_admin on nomad_sceneflow.assets for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.scenes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_sceneflow.projects(id) on delete cascade,
  "position" text,
  script text,
  asset_id uuid references nomad_sceneflow.assets(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index idx_scenes_org_id on nomad_sceneflow.scenes(organization_id);
alter table nomad_sceneflow.scenes enable row level security;
create policy scenes_select_member on nomad_sceneflow.scenes for select using (nomad_core.organization_role(organization_id) is not null);
create policy scenes_insert_member on nomad_sceneflow.scenes for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy scenes_update_member on nomad_sceneflow.scenes for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy scenes_delete_admin on nomad_sceneflow.scenes for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.edit_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_sceneflow.projects(id) on delete cascade,
  kind text,  -- AI 자동편집
  status text,
  created_at timestamptz not null default now()
);
create index idx_edit_jobs_org_id on nomad_sceneflow.edit_jobs(organization_id);
alter table nomad_sceneflow.edit_jobs enable row level security;
create policy edit_jobs_select_member on nomad_sceneflow.edit_jobs for select using (nomad_core.organization_role(organization_id) is not null);
create policy edit_jobs_insert_member on nomad_sceneflow.edit_jobs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy edit_jobs_update_member on nomad_sceneflow.edit_jobs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy edit_jobs_delete_admin on nomad_sceneflow.edit_jobs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.render_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_sceneflow.projects(id) on delete cascade,
  engine text,  -- FFmpeg
  queue text,  -- BullMQ
  created_at timestamptz not null default now()
);
create index idx_render_jobs_org_id on nomad_sceneflow.render_jobs(organization_id);
alter table nomad_sceneflow.render_jobs enable row level security;
create policy render_jobs_select_member on nomad_sceneflow.render_jobs for select using (nomad_core.organization_role(organization_id) is not null);
create policy render_jobs_insert_member on nomad_sceneflow.render_jobs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy render_jobs_update_member on nomad_sceneflow.render_jobs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy render_jobs_delete_admin on nomad_sceneflow.render_jobs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.channels (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  platform text,  -- YouTube·릴스
  token_ref text,  -- 암호화 보관
  created_at timestamptz not null default now()
);
create index idx_channels_org_id on nomad_sceneflow.channels(organization_id);
alter table nomad_sceneflow.channels enable row level security;
create policy channels_select_member on nomad_sceneflow.channels for select using (nomad_core.organization_role(organization_id) is not null);
create policy channels_insert_member on nomad_sceneflow.channels for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy channels_update_member on nomad_sceneflow.channels for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy channels_delete_admin on nomad_sceneflow.channels for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.uploads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  render_id uuid references nomad_sceneflow.render_jobs(id) on delete cascade,
  channel_id uuid references nomad_sceneflow.channels(id) on delete cascade,
  scheduled_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_uploads_org_id on nomad_sceneflow.uploads(organization_id);
alter table nomad_sceneflow.uploads enable row level security;
create policy uploads_select_member on nomad_sceneflow.uploads for select using (nomad_core.organization_role(organization_id) is not null);
create policy uploads_insert_member on nomad_sceneflow.uploads for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy uploads_update_member on nomad_sceneflow.uploads for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy uploads_delete_admin on nomad_sceneflow.uploads for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

