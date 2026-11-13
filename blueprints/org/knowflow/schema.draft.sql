-- knowflow · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create extension if not exists vector with schema extensions;
create schema if not exists nomad_knowflow;
revoke all on schema nomad_knowflow from public, anon, authenticated;
grant usage on schema nomad_knowflow to authenticated, service_role;

create table nomad_knowflow.spaces (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text,
  visibility text,  -- 팀 공개·비공개
  created_at timestamptz not null default now()
);
create index idx_spaces_org_id on nomad_knowflow.spaces(organization_id);
alter table nomad_knowflow.spaces enable row level security;
create policy spaces_select_member on nomad_knowflow.spaces for select using (nomad_core.organization_role(organization_id) is not null);
create policy spaces_insert_member on nomad_knowflow.spaces for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy spaces_update_member on nomad_knowflow.spaces for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy spaces_delete_admin on nomad_knowflow.spaces for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.sources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  space_id uuid references nomad_knowflow.spaces(id) on delete cascade,
  kind text,  -- PDF·웹
  url text,
  status text,  -- 수집·분석
  created_at timestamptz not null default now()
);
create index idx_sources_org_id on nomad_knowflow.sources(organization_id);
alter table nomad_knowflow.sources enable row level security;
create policy sources_select_member on nomad_knowflow.sources for select using (nomad_core.organization_role(organization_id) is not null);
create policy sources_insert_member on nomad_knowflow.sources for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy sources_update_member on nomad_knowflow.sources for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy sources_delete_admin on nomad_knowflow.sources for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.chunks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  source_id uuid references nomad_knowflow.sources(id) on delete cascade,
  "text" text,
  embedding extensions.vector(1536),  -- pgvector
  created_at timestamptz not null default now()
);
create index idx_chunks_org_id on nomad_knowflow.chunks(organization_id);
alter table nomad_knowflow.chunks enable row level security;
create policy chunks_select_member on nomad_knowflow.chunks for select using (nomad_core.organization_role(organization_id) is not null);
create policy chunks_insert_member on nomad_knowflow.chunks for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy chunks_update_member on nomad_knowflow.chunks for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy chunks_delete_admin on nomad_knowflow.chunks for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  space_id uuid references nomad_knowflow.spaces(id) on delete cascade,
  title text,
  evidence jsonb,  -- 출처 연결
  created_at timestamptz not null default now()
);
create index idx_reports_org_id on nomad_knowflow.reports(organization_id);
alter table nomad_knowflow.reports enable row level security;
create policy reports_select_member on nomad_knowflow.reports for select using (nomad_core.organization_role(organization_id) is not null);
create policy reports_insert_member on nomad_knowflow.reports for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy reports_update_member on nomad_knowflow.reports for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy reports_delete_admin on nomad_knowflow.reports for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.chats (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  space_id uuid references nomad_knowflow.spaces(id) on delete cascade,
  user_id uuid references nomad_core.profiles(user_id),
  title text,
  created_at timestamptz not null default now()
);
create index idx_chats_org_id on nomad_knowflow.chats(organization_id);
alter table nomad_knowflow.chats enable row level security;
create policy chats_select_member on nomad_knowflow.chats for select using (nomad_core.organization_role(organization_id) is not null);
create policy chats_insert_member on nomad_knowflow.chats for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy chats_update_member on nomad_knowflow.chats for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy chats_delete_admin on nomad_knowflow.chats for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  chat_id uuid references nomad_knowflow.chats(id) on delete cascade,
  role text,
  citations jsonb,  -- 출처 chunk
  created_at timestamptz not null default now()
);
create index idx_messages_org_id on nomad_knowflow.messages(organization_id);
alter table nomad_knowflow.messages enable row level security;
create policy messages_select_member on nomad_knowflow.messages for select using (nomad_core.organization_role(organization_id) is not null);
create policy messages_insert_member on nomad_knowflow.messages for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy messages_update_member on nomad_knowflow.messages for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy messages_delete_admin on nomad_knowflow.messages for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));


grant select, insert, update, delete on all tables in schema nomad_knowflow to authenticated;
