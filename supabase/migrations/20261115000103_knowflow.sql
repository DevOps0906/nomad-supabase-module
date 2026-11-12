-- KNOWFLOW AI · 조직형
-- 원본 청사진: blueprints/org/knowflow/schema.draft.sql
-- 되돌림: drop schema nomad_knowflow cascade; delete from nomad_core.products where code = 'knowflow';
begin;

create extension if not exists vector with schema extensions;

create schema nomad_knowflow;
revoke all on schema nomad_knowflow from public, anon, authenticated;
grant usage on schema nomad_knowflow to authenticated, service_role;

insert into nomad_core.products (code, name) values ('knowflow', 'KNOWFLOW AI');

create table nomad_knowflow.spaces (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text not null,
  visibility text not null default 'team' check (visibility in ('team', 'private')),
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_knowflow.spaces is '지식 공간(팀 공개·비공개)';
comment on column nomad_knowflow.spaces.visibility is '공개 범위: team 팀 공개, private 비공개';
create index idx_spaces_org_created on nomad_knowflow.spaces(organization_id, created_at desc);
alter table nomad_knowflow.spaces enable row level security;
create policy spaces_select on nomad_knowflow.spaces for select to authenticated using (nomad_core.organization_role(organization_id) is not null and (visibility <> 'private' or nomad_core.organization_role(organization_id) in ('owner', 'admin')));
create policy spaces_insert on nomad_knowflow.spaces for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy spaces_update on nomad_knowflow.spaces for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy spaces_delete on nomad_knowflow.spaces for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.sources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  space_id uuid,
  kind text not null default 'pdf' check (kind in ('pdf', 'web')),
  url text,
  status text not null default 'collecting' check (status in ('collecting', 'analyzing')),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, space_id) references nomad_knowflow.spaces(organization_id, id) on delete cascade
);
comment on table nomad_knowflow.sources is '공간에 수집한 자료 출처';
comment on column nomad_knowflow.sources.kind is '출처 종류: pdf, web 웹';
comment on column nomad_knowflow.sources.status is '처리 상태: collecting 수집, analyzing 분석';
create index idx_sources_org_created on nomad_knowflow.sources(organization_id, created_at desc);
create index idx_sources_space_id on nomad_knowflow.sources(organization_id, space_id);
alter table nomad_knowflow.sources enable row level security;
create policy sources_select on nomad_knowflow.sources for select to authenticated using (nomad_core.organization_role(organization_id) is not null and exists (select 1 from nomad_knowflow.spaces p where p.id = space_id));
create policy sources_insert on nomad_knowflow.sources for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy sources_update on nomad_knowflow.sources for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy sources_delete on nomad_knowflow.sources for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.chunks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  source_id uuid,
  "text" text,
  embedding extensions.vector(1536),
  created_at timestamptz not null default now(),
  foreign key (organization_id, source_id) references nomad_knowflow.sources(organization_id, id) on delete cascade
);
comment on table nomad_knowflow.chunks is '출처를 쪼갠 조각과 임베딩';
comment on column nomad_knowflow.chunks.embedding is 'pgvector 임베딩';
create index idx_chunks_org_created on nomad_knowflow.chunks(organization_id, created_at desc);
create index idx_chunks_source_id on nomad_knowflow.chunks(organization_id, source_id);
alter table nomad_knowflow.chunks enable row level security;
create policy chunks_select on nomad_knowflow.chunks for select to authenticated using (nomad_core.organization_role(organization_id) is not null and exists (select 1 from nomad_knowflow.sources p where p.id = source_id));
create policy chunks_insert on nomad_knowflow.chunks for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy chunks_update on nomad_knowflow.chunks for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy chunks_delete on nomad_knowflow.chunks for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  space_id uuid,
  title text not null,
  evidence jsonb,
  created_at timestamptz not null default now(),
  foreign key (organization_id, space_id) references nomad_knowflow.spaces(organization_id, id) on delete cascade
);
comment on table nomad_knowflow.reports is '공간 단위 분석 보고서';
comment on column nomad_knowflow.reports.evidence is '출처 연결';
create index idx_reports_org_created on nomad_knowflow.reports(organization_id, created_at desc);
create index idx_reports_space_id on nomad_knowflow.reports(organization_id, space_id);
alter table nomad_knowflow.reports enable row level security;
create policy reports_select on nomad_knowflow.reports for select to authenticated using (nomad_core.organization_role(organization_id) is not null and exists (select 1 from nomad_knowflow.spaces p where p.id = space_id));
create policy reports_insert on nomad_knowflow.reports for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy reports_update on nomad_knowflow.reports for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy reports_delete on nomad_knowflow.reports for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_knowflow.chats (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  space_id uuid,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, space_id) references nomad_knowflow.spaces(organization_id, id) on delete cascade
);
comment on table nomad_knowflow.chats is '공간 안의 대화방';
create index idx_chats_org_created on nomad_knowflow.chats(organization_id, created_at desc);
create index idx_chats_space_id on nomad_knowflow.chats(organization_id, space_id);
create index idx_chats_user_id on nomad_knowflow.chats(user_id);
alter table nomad_knowflow.chats enable row level security;
create policy chats_select on nomad_knowflow.chats for select to authenticated using (nomad_core.organization_role(organization_id) is not null and user_id = (select auth.uid()));
create policy chats_insert on nomad_knowflow.chats for insert to authenticated with check (nomad_core.organization_role(organization_id) is not null and user_id = (select auth.uid()));
create policy chats_update on nomad_knowflow.chats for update to authenticated using (nomad_core.organization_role(organization_id) is not null and user_id = (select auth.uid())) with check (nomad_core.organization_role(organization_id) is not null and user_id = (select auth.uid()));
create policy chats_delete on nomad_knowflow.chats for delete to authenticated using (nomad_core.organization_role(organization_id) is not null and user_id = (select auth.uid()));

create table nomad_knowflow.messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  chat_id uuid,
  role text,
  citations jsonb,
  created_at timestamptz not null default now(),
  foreign key (organization_id, chat_id) references nomad_knowflow.chats(organization_id, id) on delete cascade
);
comment on table nomad_knowflow.messages is '대화방 메시지';
comment on column nomad_knowflow.messages.citations is '출처 chunk';
create index idx_messages_org_created on nomad_knowflow.messages(organization_id, created_at desc);
create index idx_messages_chat_id on nomad_knowflow.messages(organization_id, chat_id);
alter table nomad_knowflow.messages enable row level security;
create policy messages_select on nomad_knowflow.messages for select to authenticated using (nomad_core.organization_role(organization_id) is not null and exists (select 1 from nomad_knowflow.chats c where c.id = chat_id));
create policy messages_insert on nomad_knowflow.messages for insert to authenticated with check (nomad_core.organization_role(organization_id) is not null and role = 'user' and exists (select 1 from nomad_knowflow.chats c where c.id = chat_id));
create policy messages_delete on nomad_knowflow.messages for delete to authenticated using (nomad_core.organization_role(organization_id) is not null and exists (select 1 from nomad_knowflow.chats c where c.id = chat_id));

revoke all on all tables in schema nomad_knowflow from public, anon, authenticated;
grant all on all tables in schema nomad_knowflow to service_role;
grant select, insert, delete on nomad_knowflow.spaces to authenticated;
grant update (name, visibility) on nomad_knowflow.spaces to authenticated;
grant select, insert, delete on nomad_knowflow.sources to authenticated;
grant update (space_id, kind, url, status) on nomad_knowflow.sources to authenticated;
grant select, insert, delete on nomad_knowflow.chunks to authenticated;
grant update (source_id, "text", embedding) on nomad_knowflow.chunks to authenticated;
grant select, insert, delete on nomad_knowflow.reports to authenticated;
grant update (space_id, title, evidence) on nomad_knowflow.reports to authenticated;
grant select, insert, delete on nomad_knowflow.chats to authenticated;
grant update (title) on nomad_knowflow.chats to authenticated;
grant select, insert, delete on nomad_knowflow.messages to authenticated;

commit;
