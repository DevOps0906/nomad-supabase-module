-- 0003: organizations & memberships
create table if not exists core.organizations (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  type       core.org_type not null default 'personal',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists core.memberships (
  org_id        uuid not null references core.organizations(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  role          core.member_role not null default 'member',
  service_roles jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index if not exists idx_memberships_user_id on core.memberships(user_id);

alter table core.organizations enable row level security;
alter table core.memberships  enable row level security;
