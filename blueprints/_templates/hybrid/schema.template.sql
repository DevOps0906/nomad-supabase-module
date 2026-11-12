create schema if not exists nomad_{{slug}};
revoke all on schema nomad_{{slug}} from public, anon, authenticated;
grant usage on schema nomad_{{slug}} to authenticated, service_role;

-- 혼합형: 행은 항상 작성자(user_id) 소유. organization_id가 있으면 그 조직 멤버와 공유한다.
create table nomad_{{slug}}.example_items (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  organization_id uuid references nomad_core.organizations(id) on delete cascade,
  name            text not null,
  created_at      timestamptz not null default now()
);
create index idx_example_items_user_id on nomad_{{slug}}.example_items(user_id);
create index idx_example_items_org_id on nomad_{{slug}}.example_items(organization_id);

alter table nomad_{{slug}}.example_items enable row level security;
create policy example_items_select_owner_or_member on nomad_{{slug}}.example_items for select
  using (user_id = (select auth.uid()) or (organization_id is not null and nomad_core.organization_role(organization_id) is not null));
create policy example_items_insert_owner on nomad_{{slug}}.example_items for insert
  with check (user_id = (select auth.uid()) and (organization_id is null or nomad_core.organization_role(organization_id) is not null));
create policy example_items_update_owner_or_member on nomad_{{slug}}.example_items for update
  using (user_id = (select auth.uid()) or (organization_id is not null and nomad_core.organization_role(organization_id) is not null))
  with check (user_id = (select auth.uid()) or (organization_id is not null and nomad_core.organization_role(organization_id) is not null));
create policy example_items_delete_owner_or_admin on nomad_{{slug}}.example_items for delete
  using (user_id = (select auth.uid()) or (organization_id is not null and nomad_core.organization_role(organization_id) in ('owner', 'admin')));

grant select, insert, update, delete on all tables in schema nomad_{{slug}} to authenticated;
