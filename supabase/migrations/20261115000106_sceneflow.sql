begin;

-- SceneFlow · 조직형 · 원본 청사진: blueprints/org/sceneflow/schema.draft.sql
-- 되돌림: drop schema nomad_sceneflow cascade; delete from nomad_core.products where code = 'sceneflow';

create schema nomad_sceneflow;
revoke all on schema nomad_sceneflow from public, anon, authenticated;
grant usage on schema nomad_sceneflow to authenticated, service_role;

insert into nomad_core.products (code, name) values ('sceneflow', 'SceneFlow');

create table nomad_sceneflow.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  title text not null,
  aspect text not null default 'landscape' check (aspect in ('landscape','portrait')),
  resolution text,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_sceneflow.projects is '영상 프로젝트';
comment on column nomad_sceneflow.projects.aspect is '가로·세로';
create index projects_org_created on nomad_sceneflow.projects(organization_id, created_at desc);
alter table nomad_sceneflow.projects enable row level security;
create policy projects_select on nomad_sceneflow.projects for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy projects_insert on nomad_sceneflow.projects for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy projects_update on nomad_sceneflow.projects for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy projects_delete on nomad_sceneflow.projects for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  kind text not null default 'video' check (kind in ('video','image','audio')),
  storage_path text,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_sceneflow.assets is '영상·이미지·음성 자산';
comment on column nomad_sceneflow.assets.kind is '영상·이미지·음성';
create index assets_org_created on nomad_sceneflow.assets(organization_id, created_at desc);
alter table nomad_sceneflow.assets enable row level security;
create policy assets_select on nomad_sceneflow.assets for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy assets_insert on nomad_sceneflow.assets for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy assets_update on nomad_sceneflow.assets for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy assets_delete on nomad_sceneflow.assets for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.scenes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  "position" text,
  script text,
  asset_id uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, project_id) references nomad_sceneflow.projects(organization_id, id) on delete cascade,
  foreign key (organization_id, asset_id) references nomad_sceneflow.assets(organization_id, id) on delete cascade
);
comment on table nomad_sceneflow.scenes is '프로젝트 장면';
create index scenes_org_created on nomad_sceneflow.scenes(organization_id, created_at desc);
create index scenes_project_id on nomad_sceneflow.scenes(project_id);
create index scenes_asset_id on nomad_sceneflow.scenes(asset_id);
alter table nomad_sceneflow.scenes enable row level security;
create policy scenes_select on nomad_sceneflow.scenes for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy scenes_insert on nomad_sceneflow.scenes for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy scenes_update on nomad_sceneflow.scenes for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy scenes_delete on nomad_sceneflow.scenes for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.edit_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  kind text,
  status text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, project_id) references nomad_sceneflow.projects(organization_id, id) on delete cascade
);
comment on table nomad_sceneflow.edit_jobs is 'AI 자동편집 작업';
create index edit_jobs_org_created on nomad_sceneflow.edit_jobs(organization_id, created_at desc);
create index edit_jobs_project_id on nomad_sceneflow.edit_jobs(project_id);
alter table nomad_sceneflow.edit_jobs enable row level security;
create policy edit_jobs_select on nomad_sceneflow.edit_jobs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy edit_jobs_insert on nomad_sceneflow.edit_jobs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy edit_jobs_update on nomad_sceneflow.edit_jobs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy edit_jobs_delete on nomad_sceneflow.edit_jobs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.render_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  engine text,
  queue text,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, project_id) references nomad_sceneflow.projects(organization_id, id) on delete cascade
);
comment on table nomad_sceneflow.render_jobs is '렌더링 작업';
create index render_jobs_org_created on nomad_sceneflow.render_jobs(organization_id, created_at desc);
create index render_jobs_project_id on nomad_sceneflow.render_jobs(project_id);
alter table nomad_sceneflow.render_jobs enable row level security;
create policy render_jobs_select on nomad_sceneflow.render_jobs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy render_jobs_insert on nomad_sceneflow.render_jobs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy render_jobs_update on nomad_sceneflow.render_jobs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy render_jobs_delete on nomad_sceneflow.render_jobs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.channels (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  platform text not null default 'youtube' check (platform in ('youtube','reels')),
  token_ref text,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_sceneflow.channels is '업로드 채널 연결';
comment on column nomad_sceneflow.channels.platform is 'YouTube·릴스';
comment on column nomad_sceneflow.channels.token_ref is '암호화 보관 참조';
create index channels_org_created on nomad_sceneflow.channels(organization_id, created_at desc);
alter table nomad_sceneflow.channels enable row level security;
create policy channels_select on nomad_sceneflow.channels for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy channels_insert on nomad_sceneflow.channels for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy channels_update on nomad_sceneflow.channels for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy channels_delete on nomad_sceneflow.channels for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_sceneflow.uploads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  render_id uuid,
  channel_id uuid,
  scheduled_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id, render_id) references nomad_sceneflow.render_jobs(organization_id, id) on delete cascade,
  foreign key (organization_id, channel_id) references nomad_sceneflow.channels(organization_id, id) on delete cascade
);
comment on table nomad_sceneflow.uploads is '렌더 결과 채널 업로드 예약';
create index uploads_org_created on nomad_sceneflow.uploads(organization_id, created_at desc);
create index uploads_render_id on nomad_sceneflow.uploads(render_id);
create index uploads_channel_id on nomad_sceneflow.uploads(channel_id);
alter table nomad_sceneflow.uploads enable row level security;
create policy uploads_select on nomad_sceneflow.uploads for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy uploads_insert on nomad_sceneflow.uploads for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy uploads_update on nomad_sceneflow.uploads for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy uploads_delete on nomad_sceneflow.uploads for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

revoke all on all tables in schema nomad_sceneflow from public, anon, authenticated;
grant all on all tables in schema nomad_sceneflow to service_role;
grant select, insert, delete on nomad_sceneflow.projects to authenticated;
grant update (title, aspect, resolution) on nomad_sceneflow.projects to authenticated;
grant select, insert, delete on nomad_sceneflow.assets to authenticated;
grant update (kind, storage_path) on nomad_sceneflow.assets to authenticated;
grant select, insert, delete on nomad_sceneflow.scenes to authenticated;
grant update (project_id, "position", script, asset_id) on nomad_sceneflow.scenes to authenticated;
grant select, insert, delete on nomad_sceneflow.edit_jobs to authenticated;
grant update (project_id, kind, status) on nomad_sceneflow.edit_jobs to authenticated;
grant select, insert, delete on nomad_sceneflow.render_jobs to authenticated;
grant update (project_id, engine, queue) on nomad_sceneflow.render_jobs to authenticated;
grant select (id, organization_id, platform, created_at) on nomad_sceneflow.channels to authenticated;
grant delete on nomad_sceneflow.channels to authenticated;
grant insert (organization_id, platform) on nomad_sceneflow.channels to authenticated;
grant update (platform) on nomad_sceneflow.channels to authenticated;
grant select, insert, delete on nomad_sceneflow.uploads to authenticated;
grant update (render_id, channel_id, scheduled_at) on nomad_sceneflow.uploads to authenticated;

commit;
