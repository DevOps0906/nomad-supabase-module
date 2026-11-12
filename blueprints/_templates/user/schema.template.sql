create schema if not exists nomad_{{slug}};
revoke all on schema nomad_{{slug}} from public, anon, authenticated;
grant usage on schema nomad_{{slug}} to authenticated, service_role;

create table nomad_{{slug}}.example_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);
create index idx_example_items_user_id on nomad_{{slug}}.example_items(user_id);

alter table nomad_{{slug}}.example_items enable row level security;
create policy example_items_own on nomad_{{slug}}.example_items
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
