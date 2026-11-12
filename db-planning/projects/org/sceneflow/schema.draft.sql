-- sceneflow · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists sceneflow;

create table sceneflow.projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  title text,
  aspect text,  -- 가로·세로
  resolution text,
  created_at timestamptz not null default now()
);
create index idx_projects_org_id on sceneflow.projects(org_id);
alter table sceneflow.projects enable row level security;
create policy projects_select_member on sceneflow.projects for select using (core.is_member(org_id));
create policy projects_insert_member on sceneflow.projects for insert with check (core.is_member(org_id));
create policy projects_update_member on sceneflow.projects for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy projects_delete_admin on sceneflow.projects for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table sceneflow.assets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  kind text,  -- 영상·이미지·음성
  storage_path text,
  created_at timestamptz not null default now()
);
create index idx_assets_org_id on sceneflow.assets(org_id);
alter table sceneflow.assets enable row level security;
create policy assets_select_member on sceneflow.assets for select using (core.is_member(org_id));
create policy assets_insert_member on sceneflow.assets for insert with check (core.is_member(org_id));
create policy assets_update_member on sceneflow.assets for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy assets_delete_admin on sceneflow.assets for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table sceneflow.scenes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references sceneflow.projects(id) on delete cascade,
  "position" text,
  script text,
  asset_id uuid references sceneflow.assets(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index idx_scenes_org_id on sceneflow.scenes(org_id);
alter table sceneflow.scenes enable row level security;
create policy scenes_select_member on sceneflow.scenes for select using (core.is_member(org_id));
create policy scenes_insert_member on sceneflow.scenes for insert with check (core.is_member(org_id));
create policy scenes_update_member on sceneflow.scenes for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy scenes_delete_admin on sceneflow.scenes for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table sceneflow.edit_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references sceneflow.projects(id) on delete cascade,
  kind text,  -- AI 자동편집
  status text,
  created_at timestamptz not null default now()
);
create index idx_edit_jobs_org_id on sceneflow.edit_jobs(org_id);
alter table sceneflow.edit_jobs enable row level security;
create policy edit_jobs_select_member on sceneflow.edit_jobs for select using (core.is_member(org_id));
create policy edit_jobs_insert_member on sceneflow.edit_jobs for insert with check (core.is_member(org_id));
create policy edit_jobs_update_member on sceneflow.edit_jobs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy edit_jobs_delete_admin on sceneflow.edit_jobs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table sceneflow.render_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references sceneflow.projects(id) on delete cascade,
  engine text,  -- FFmpeg
  queue text,  -- BullMQ
  created_at timestamptz not null default now()
);
create index idx_render_jobs_org_id on sceneflow.render_jobs(org_id);
alter table sceneflow.render_jobs enable row level security;
create policy render_jobs_select_member on sceneflow.render_jobs for select using (core.is_member(org_id));
create policy render_jobs_insert_member on sceneflow.render_jobs for insert with check (core.is_member(org_id));
create policy render_jobs_update_member on sceneflow.render_jobs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy render_jobs_delete_admin on sceneflow.render_jobs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table sceneflow.channels (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  platform text,  -- YouTube·릴스
  token_ref text,  -- 암호화 보관
  created_at timestamptz not null default now()
);
create index idx_channels_org_id on sceneflow.channels(org_id);
alter table sceneflow.channels enable row level security;
create policy channels_select_member on sceneflow.channels for select using (core.is_member(org_id));
create policy channels_insert_member on sceneflow.channels for insert with check (core.is_member(org_id));
create policy channels_update_member on sceneflow.channels for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy channels_delete_admin on sceneflow.channels for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table sceneflow.uploads (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  render_id uuid references sceneflow.render_jobs(id) on delete cascade,
  channel_id uuid references sceneflow.channels(id) on delete cascade,
  scheduled_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_uploads_org_id on sceneflow.uploads(org_id);
alter table sceneflow.uploads enable row level security;
create policy uploads_select_member on sceneflow.uploads for select using (core.is_member(org_id));
create policy uploads_insert_member on sceneflow.uploads for insert with check (core.is_member(org_id));
create policy uploads_update_member on sceneflow.uploads for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy uploads_delete_admin on sceneflow.uploads for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

