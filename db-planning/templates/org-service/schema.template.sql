create schema if not exists {{slug}};

create table {{slug}}.example_items (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references core.organizations(id) on delete cascade,
  name       text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index idx_example_items_org_id on {{slug}}.example_items(org_id);

alter table {{slug}}.example_items enable row level security;
create policy example_items_select_member on {{slug}}.example_items for select using (core.is_member(org_id));
create policy example_items_insert_member on {{slug}}.example_items for insert with check (core.is_member(org_id));
create policy example_items_update_member on {{slug}}.example_items for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy example_items_delete_admin  on {{slug}}.example_items for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));
