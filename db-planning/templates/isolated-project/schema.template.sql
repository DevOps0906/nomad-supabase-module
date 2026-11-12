-- 별도 Supabase 프로젝트에 적용. core 스키마를 참조하지 않는다.
create schema if not exists {{slug}};

create table {{slug}}.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null,
  created_at timestamptz not null default now()
);

create table {{slug}}.audit_logs (
  id       uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  action   text not null,
  target   text,
  at       timestamptz not null default now()
);

alter table {{slug}}.staff      enable row level security;
alter table {{slug}}.audit_logs enable row level security;
-- TODO: 역할별 정책 작성 (기본 거부 상태)
