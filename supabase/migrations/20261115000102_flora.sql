-- FLORA V2 · 조직형
-- 원본 청사진: blueprints/org/flora/schema.draft.sql
-- 되돌림: drop schema nomad_flora cascade; delete from nomad_core.products where code = 'flora';
begin;

create schema nomad_flora;
revoke all on schema nomad_flora from public, anon, authenticated;
grant usage on schema nomad_flora to authenticated, service_role;

insert into nomad_core.products (code, name) values ('flora', 'FLORA V2');

create table nomad_flora.personas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text not null,
  writing_dna text,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_flora.personas is '집필 페르소나(문체 고정)';
comment on column nomad_flora.personas.writing_dna is 'Taste 고정';
create index idx_personas_org_created on nomad_flora.personas(organization_id, created_at desc);
alter table nomad_flora.personas enable row level security;
create policy personas_select on nomad_flora.personas for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy personas_insert on nomad_flora.personas for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy personas_update on nomad_flora.personas for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy personas_delete on nomad_flora.personas for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  persona_id uuid,
  title text not null,
  mode text not null default 'prose' check (mode in ('prose', 'poem', 'picture_book', 'tech_book')),
  tier text,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, persona_id) references nomad_flora.personas(organization_id, id) on delete cascade
);
comment on table nomad_flora.projects is '집필 프로젝트';
comment on column nomad_flora.projects.mode is '집필 모드: prose 글, poem 시, picture_book 그림책, tech_book 기술서';
comment on column nomad_flora.projects.tier is '요금제';
create index idx_projects_org_created on nomad_flora.projects(organization_id, created_at desc);
create index idx_projects_persona_id on nomad_flora.projects(organization_id, persona_id);
alter table nomad_flora.projects enable row level security;
create policy projects_select on nomad_flora.projects for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy projects_insert on nomad_flora.projects for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy projects_update on nomad_flora.projects for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy projects_delete on nomad_flora.projects for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.chapters (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  step numeric,
  body text,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, project_id) references nomad_flora.projects(organization_id, id) on delete cascade
);
comment on table nomad_flora.chapters is '프로젝트의 챕터(단계별 본문)';
comment on column nomad_flora.chapters.step is '10단계 중 몇 번째';
create index idx_chapters_org_created on nomad_flora.chapters(organization_id, created_at desc);
create index idx_chapters_project_id on nomad_flora.chapters(organization_id, project_id);
alter table nomad_flora.chapters enable row level security;
create policy chapters_select on nomad_flora.chapters for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy chapters_insert on nomad_flora.chapters for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy chapters_update on nomad_flora.chapters for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy chapters_delete on nomad_flora.chapters for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  chapter_id uuid,
  kind text not null default 'image' check (kind in ('image', 'capture')),
  storage_path text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, chapter_id) references nomad_flora.chapters(organization_id, id) on delete cascade
);
comment on table nomad_flora.assets is '챕터에 붙는 이미지·캡처 파일';
comment on column nomad_flora.assets.kind is '자산 종류: image 이미지, capture 캡처';
create index idx_assets_org_created on nomad_flora.assets(organization_id, created_at desc);
create index idx_assets_chapter_id on nomad_flora.assets(organization_id, chapter_id);
alter table nomad_flora.assets enable row level security;
create policy assets_select on nomad_flora.assets for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy assets_insert on nomad_flora.assets for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy assets_update on nomad_flora.assets for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy assets_delete on nomad_flora.assets for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.pipeline_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  project_id uuid,
  mode text not null default 'react_flow' check (mode in ('react_flow', 'n8n', 'make')),
  status text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, project_id) references nomad_flora.projects(organization_id, id) on delete cascade
);
comment on table nomad_flora.pipeline_runs is '프로젝트 파이프라인 실행 기록';
comment on column nomad_flora.pipeline_runs.mode is '실행 방식: react_flow, n8n, make';
create index idx_pipeline_runs_org_created on nomad_flora.pipeline_runs(organization_id, created_at desc);
create index idx_pipeline_runs_project_id on nomad_flora.pipeline_runs(organization_id, project_id);
alter table nomad_flora.pipeline_runs enable row level security;
create policy pipeline_runs_select on nomad_flora.pipeline_runs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy pipeline_runs_insert on nomad_flora.pipeline_runs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy pipeline_runs_update on nomad_flora.pipeline_runs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy pipeline_runs_delete on nomad_flora.pipeline_runs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_flora.audiobooks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  chapter_id uuid,
  voice text,
  file_path text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, chapter_id) references nomad_flora.chapters(organization_id, id) on delete cascade
);
comment on table nomad_flora.audiobooks is '챕터 오디오북 파일';
comment on column nomad_flora.audiobooks.voice is 'F5-TTS 음성';
create index idx_audiobooks_org_created on nomad_flora.audiobooks(organization_id, created_at desc);
create index idx_audiobooks_chapter_id on nomad_flora.audiobooks(organization_id, chapter_id);
alter table nomad_flora.audiobooks enable row level security;
create policy audiobooks_select on nomad_flora.audiobooks for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy audiobooks_insert on nomad_flora.audiobooks for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy audiobooks_update on nomad_flora.audiobooks for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy audiobooks_delete on nomad_flora.audiobooks for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

revoke all on all tables in schema nomad_flora from public, anon, authenticated;
grant all on all tables in schema nomad_flora to service_role;
grant select, insert, delete on nomad_flora.personas to authenticated;
grant update (name, writing_dna) on nomad_flora.personas to authenticated;
grant select, insert, delete on nomad_flora.projects to authenticated;
grant update (persona_id, title, mode, tier) on nomad_flora.projects to authenticated;
grant select, insert, delete on nomad_flora.chapters to authenticated;
grant update (project_id, step, body) on nomad_flora.chapters to authenticated;
grant select, insert, delete on nomad_flora.assets to authenticated;
grant update (chapter_id, kind, storage_path) on nomad_flora.assets to authenticated;
grant select, insert, delete on nomad_flora.pipeline_runs to authenticated;
grant update (project_id, mode, status) on nomad_flora.pipeline_runs to authenticated;
grant select, insert, delete on nomad_flora.audiobooks to authenticated;
grant update (chapter_id, voice, file_path) on nomad_flora.audiobooks to authenticated;

commit;
