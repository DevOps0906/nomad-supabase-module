-- flora · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists flora;

create table flora.personas (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  name text,
  writing_dna text,  -- Taste 고정
  created_at timestamptz not null default now()
);
create index idx_personas_org_id on flora.personas(org_id);
alter table flora.personas enable row level security;
create policy personas_select_member on flora.personas for select using (core.is_member(org_id));
create policy personas_insert_member on flora.personas for insert with check (core.is_member(org_id));
create policy personas_update_member on flora.personas for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy personas_delete_admin on flora.personas for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table flora.projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  persona_id uuid references flora.personas(id) on delete cascade,
  title text,
  mode text,  -- 글·시·그림책·기술서
  tier text,  -- 요금제
  created_at timestamptz not null default now()
);
create index idx_projects_org_id on flora.projects(org_id);
alter table flora.projects enable row level security;
create policy projects_select_member on flora.projects for select using (core.is_member(org_id));
create policy projects_insert_member on flora.projects for insert with check (core.is_member(org_id));
create policy projects_update_member on flora.projects for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy projects_delete_admin on flora.projects for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table flora.chapters (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references flora.projects(id) on delete cascade,
  step numeric,  -- 10단계 중
  body text,
  created_at timestamptz not null default now()
);
create index idx_chapters_org_id on flora.chapters(org_id);
alter table flora.chapters enable row level security;
create policy chapters_select_member on flora.chapters for select using (core.is_member(org_id));
create policy chapters_insert_member on flora.chapters for insert with check (core.is_member(org_id));
create policy chapters_update_member on flora.chapters for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy chapters_delete_admin on flora.chapters for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table flora.assets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  chapter_id uuid references flora.chapters(id) on delete cascade,
  kind text,  -- 이미지·캡처
  storage_path text,
  created_at timestamptz not null default now()
);
create index idx_assets_org_id on flora.assets(org_id);
alter table flora.assets enable row level security;
create policy assets_select_member on flora.assets for select using (core.is_member(org_id));
create policy assets_insert_member on flora.assets for insert with check (core.is_member(org_id));
create policy assets_update_member on flora.assets for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy assets_delete_admin on flora.assets for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table flora.pipeline_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  project_id uuid references flora.projects(id) on delete cascade,
  mode text,  -- React Flow·n8n·Make
  status text,
  created_at timestamptz not null default now()
);
create index idx_pipeline_runs_org_id on flora.pipeline_runs(org_id);
alter table flora.pipeline_runs enable row level security;
create policy pipeline_runs_select_member on flora.pipeline_runs for select using (core.is_member(org_id));
create policy pipeline_runs_insert_member on flora.pipeline_runs for insert with check (core.is_member(org_id));
create policy pipeline_runs_update_member on flora.pipeline_runs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy pipeline_runs_delete_admin on flora.pipeline_runs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table flora.audiobooks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  chapter_id uuid references flora.chapters(id) on delete cascade,
  voice text,  -- F5-TTS
  file_path text,
  created_at timestamptz not null default now()
);
create index idx_audiobooks_org_id on flora.audiobooks(org_id);
alter table flora.audiobooks enable row level security;
create policy audiobooks_select_member on flora.audiobooks for select using (core.is_member(org_id));
create policy audiobooks_insert_member on flora.audiobooks for insert with check (core.is_member(org_id));
create policy audiobooks_update_member on flora.audiobooks for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy audiobooks_delete_admin on flora.audiobooks for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

