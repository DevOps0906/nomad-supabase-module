create schema if not exists nomad_{{slug}};
revoke all on schema nomad_{{slug}} from public, anon, authenticated;
grant usage on schema nomad_{{slug}} to authenticated, service_role;

create table nomad_{{slug}}.example_items (
  id         uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references nomad_core.organizations(id) on delete cascade,
  name       text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index idx_example_items_org_id on nomad_{{slug}}.example_items(organization_id);

alter table nomad_{{slug}}.example_items enable row level security;
create policy example_items_select_member on nomad_{{slug}}.example_items for select using (nomad_core.organization_role(organization_id) is not null);
create policy example_items_insert_member on nomad_{{slug}}.example_items for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy example_items_update_member on nomad_{{slug}}.example_items for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy example_items_delete_admin  on nomad_{{slug}}.example_items for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

grant select, insert, update, delete on all tables in schema nomad_{{slug}} to authenticated;
