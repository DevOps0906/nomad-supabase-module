create schema if not exists {{slug}};

create table {{slug}}.example_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);
create index idx_example_items_user_id on {{slug}}.example_items(user_id);

alter table {{slug}}.example_items enable row level security;
create policy example_items_own on {{slug}}.example_items
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
