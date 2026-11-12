-- flora · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create schema if not exists nomad_flora;
revoke all on schema nomad_flora from public, anon, authenticated;
grant usage on schema nomad_flora to authenticated, service_role;

create table nomad_flora.personas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text,
  writing_dna text,  -- Taste 고정
  created_at timestamptz not null default now()
);
create index idx_personas_org_id on nomad_flora.personas(organization_id);
alter table nomad_flora.personas enable row level security;
create policy personas_select_member on nomad_flora.personas for select using (nomad_core.organization_role(organization_id) is not null);
create policy personas_insert_member on nomad_flora.personas for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy personas_update_member on nomad_flora.personas for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy personas_delete_admin on nomad_flora.personas for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  persona_id uuid references nomad_flora.personas(id) on delete cascade,
  title text,
  mode text,  -- 글·시·그림책·기술서
  tier text,  -- 요금제
  created_at timestamptz not null default now()
);
create index idx_projects_org_id on nomad_flora.projects(organization_id);
alter table nomad_flora.projects enable row level security;
create policy projects_select_member on nomad_flora.projects for select using (nomad_core.organization_role(organization_id) is not null);
create policy projects_insert_member on nomad_flora.projects for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy projects_update_member on nomad_flora.projects for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy projects_delete_admin on nomad_flora.projects for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.chapters (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_flora.projects(id) on delete cascade,
  step numeric,  -- 10단계 중
  body text,
  created_at timestamptz not null default now()
);
create index idx_chapters_org_id on nomad_flora.chapters(organization_id);
alter table nomad_flora.chapters enable row level security;
create policy chapters_select_member on nomad_flora.chapters for select using (nomad_core.organization_role(organization_id) is not null);
create policy chapters_insert_member on nomad_flora.chapters for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy chapters_update_member on nomad_flora.chapters for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy chapters_delete_admin on nomad_flora.chapters for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  chapter_id uuid references nomad_flora.chapters(id) on delete cascade,
  kind text,  -- 이미지·캡처
  storage_path text,
  created_at timestamptz not null default now()
);
create index idx_assets_org_id on nomad_flora.assets(organization_id);
alter table nomad_flora.assets enable row level security;
create policy assets_select_member on nomad_flora.assets for select using (nomad_core.organization_role(organization_id) is not null);
create policy assets_insert_member on nomad_flora.assets for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy assets_update_member on nomad_flora.assets for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy assets_delete_admin on nomad_flora.assets for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.pipeline_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid references nomad_flora.projects(id) on delete cascade,
  mode text,  -- React Flow·n8n·Make
  status text,
  created_at timestamptz not null default now()
);
create index idx_pipeline_runs_org_id on nomad_flora.pipeline_runs(organization_id);
alter table nomad_flora.pipeline_runs enable row level security;
create policy pipeline_runs_select_member on nomad_flora.pipeline_runs for select using (nomad_core.organization_role(organization_id) is not null);
create policy pipeline_runs_insert_member on nomad_flora.pipeline_runs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy pipeline_runs_update_member on nomad_flora.pipeline_runs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy pipeline_runs_delete_admin on nomad_flora.pipeline_runs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.audiobooks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  chapter_id uuid references nomad_flora.chapters(id) on delete cascade,
  voice text,  -- F5-TTS
  file_path text,
  created_at timestamptz not null default now()
);
create index idx_audiobooks_org_id on nomad_flora.audiobooks(organization_id);
alter table nomad_flora.audiobooks enable row level security;
create policy audiobooks_select_member on nomad_flora.audiobooks for select using (nomad_core.organization_role(organization_id) is not null);
create policy audiobooks_insert_member on nomad_flora.audiobooks for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy audiobooks_update_member on nomad_flora.audiobooks for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy audiobooks_delete_admin on nomad_flora.audiobooks for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

