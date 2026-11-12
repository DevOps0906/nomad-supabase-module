-- 0005: plans, subscriptions, credit ledger
-- NOTE: 수치는 초안값. 확정 시 새 마이그레이션으로 갱신.
create table if not exists core.plans (
  code            text primary key,
  name            text not null,
  seat_limit      int  not null,
  monthly_credits int  not null,
  is_active       boolean not null default true
);

insert into core.plans (code, name, seat_limit, monthly_credits) values
  ('free','Free',1,100),
  ('pro','Pro',1,1000),
  ('team','Team',5,5000),
  ('business','Business',20,30000)
on conflict (code) do nothing;

create table if not exists core.subscriptions (
  org_id     uuid primary key references core.organizations(id) on delete cascade,
  plan_code  text not null references core.plans(code),
  status     text not null default 'active',
  period_end timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists core.credit_ledger (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references core.organizations(id) on delete cascade,
  delta      int  not null,
  reason     text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_credit_ledger_org_id on core.credit_ledger(org_id);

create or replace view core.credit_balances with (security_invoker = true) as
  select org_id, coalesce(sum(delta),0)::int as balance
  from core.credit_ledger group by org_id;

alter table core.plans          enable row level security;
alter table core.subscriptions  enable row level security;
alter table core.credit_ledger  enable row level security;
