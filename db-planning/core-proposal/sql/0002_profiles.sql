-- 0002: profiles (auth.users 1:1)
create table if not exists core.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text,
  email      text,
  avatar_url text,
  created_at timestamptz not null default now()
);
alter table core.profiles enable row level security;
