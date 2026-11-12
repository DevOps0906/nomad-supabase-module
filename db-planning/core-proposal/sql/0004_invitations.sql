-- 0004: invitations
create table if not exists core.invitations (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references core.organizations(id) on delete cascade,
  email      text not null,
  role       core.member_role not null default 'member',
  token      text not null unique default encode(gen_random_bytes(24), 'hex'),
  invited_by uuid references auth.users(id),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_invitations_org_id on core.invitations(org_id);
alter table core.invitations enable row level security;
