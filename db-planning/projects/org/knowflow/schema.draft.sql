-- knowflow · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists knowflow;

create table knowflow.spaces (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  name text,
  visibility text,  -- 팀 공개·비공개
  created_at timestamptz not null default now()
);
create index idx_spaces_org_id on knowflow.spaces(org_id);
alter table knowflow.spaces enable row level security;
create policy spaces_select_member on knowflow.spaces for select using (core.is_member(org_id));
create policy spaces_insert_member on knowflow.spaces for insert with check (core.is_member(org_id));
create policy spaces_update_member on knowflow.spaces for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy spaces_delete_admin on knowflow.spaces for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table knowflow.sources (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  space_id uuid references knowflow.spaces(id) on delete cascade,
  kind text,  -- PDF·웹
  url text,
  status text,  -- 수집·분석
  created_at timestamptz not null default now()
);
create index idx_sources_org_id on knowflow.sources(org_id);
alter table knowflow.sources enable row level security;
create policy sources_select_member on knowflow.sources for select using (core.is_member(org_id));
create policy sources_insert_member on knowflow.sources for insert with check (core.is_member(org_id));
create policy sources_update_member on knowflow.sources for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy sources_delete_admin on knowflow.sources for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table knowflow.chunks (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  source_id uuid references knowflow.sources(id) on delete cascade,
  "text" text,
  embedding vector(1536),  -- pgvector
  created_at timestamptz not null default now()
);
create index idx_chunks_org_id on knowflow.chunks(org_id);
alter table knowflow.chunks enable row level security;
create policy chunks_select_member on knowflow.chunks for select using (core.is_member(org_id));
create policy chunks_insert_member on knowflow.chunks for insert with check (core.is_member(org_id));
create policy chunks_update_member on knowflow.chunks for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy chunks_delete_admin on knowflow.chunks for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table knowflow.reports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  space_id uuid references knowflow.spaces(id) on delete cascade,
  title text,
  evidence jsonb,  -- 출처 연결
  created_at timestamptz not null default now()
);
create index idx_reports_org_id on knowflow.reports(org_id);
alter table knowflow.reports enable row level security;
create policy reports_select_member on knowflow.reports for select using (core.is_member(org_id));
create policy reports_insert_member on knowflow.reports for insert with check (core.is_member(org_id));
create policy reports_update_member on knowflow.reports for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy reports_delete_admin on knowflow.reports for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table knowflow.chats (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  space_id uuid references knowflow.spaces(id) on delete cascade,
  user_id uuid references core.profiles(user_id),
  title text,
  created_at timestamptz not null default now()
);
create index idx_chats_org_id on knowflow.chats(org_id);
alter table knowflow.chats enable row level security;
create policy chats_select_member on knowflow.chats for select using (core.is_member(org_id));
create policy chats_insert_member on knowflow.chats for insert with check (core.is_member(org_id));
create policy chats_update_member on knowflow.chats for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy chats_delete_admin on knowflow.chats for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table knowflow.messages (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  chat_id uuid references knowflow.chats(id) on delete cascade,
  role text,
  citations jsonb,  -- 출처 chunk
  created_at timestamptz not null default now()
);
create index idx_messages_org_id on knowflow.messages(org_id);
alter table knowflow.messages enable row level security;
create policy messages_select_member on knowflow.messages for select using (core.is_member(org_id));
create policy messages_insert_member on knowflow.messages for insert with check (core.is_member(org_id));
create policy messages_update_member on knowflow.messages for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy messages_delete_admin on knowflow.messages for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

