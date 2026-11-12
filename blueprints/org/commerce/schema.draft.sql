-- commerce · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create schema if not exists nomad_commerce;
revoke all on schema nomad_commerce from public, anon, authenticated;
grant usage on schema nomad_commerce to authenticated, service_role;

create table nomad_commerce.sourcing_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  source text,  -- 도매꾹·쿠팡
  source_url text,
  cost numeric,
  created_at timestamptz not null default now()
);
create index idx_sourcing_items_org_id on nomad_commerce.sourcing_items(organization_id);
alter table nomad_commerce.sourcing_items enable row level security;
create policy sourcing_items_select_member on nomad_commerce.sourcing_items for select using (nomad_core.organization_role(organization_id) is not null);
create policy sourcing_items_insert_member on nomad_commerce.sourcing_items for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy sourcing_items_update_member on nomad_commerce.sourcing_items for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy sourcing_items_delete_admin on nomad_commerce.sourcing_items for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  item_id uuid references nomad_commerce.sourcing_items(id) on delete cascade,
  title text,
  detail_page text,  -- AI 상세
  price numeric,
  created_at timestamptz not null default now()
);
create index idx_products_org_id on nomad_commerce.products(organization_id);
alter table nomad_commerce.products enable row level security;
create policy products_select_member on nomad_commerce.products for select using (nomad_core.organization_role(organization_id) is not null);
create policy products_insert_member on nomad_commerce.products for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy products_update_member on nomad_commerce.products for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy products_delete_admin on nomad_commerce.products for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.marketplace_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  marketplace text,  -- 스마트스토어
  token_ref text,  -- 암호화
  created_at timestamptz not null default now()
);
create index idx_marketplace_accounts_org_id on nomad_commerce.marketplace_accounts(organization_id);
alter table nomad_commerce.marketplace_accounts enable row level security;
create policy marketplace_accounts_select_member on nomad_commerce.marketplace_accounts for select using (nomad_core.organization_role(organization_id) is not null);
create policy marketplace_accounts_insert_member on nomad_commerce.marketplace_accounts for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy marketplace_accounts_update_member on nomad_commerce.marketplace_accounts for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy marketplace_accounts_delete_admin on nomad_commerce.marketplace_accounts for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.listings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_id uuid references nomad_commerce.products(id) on delete cascade,
  account_id uuid references nomad_commerce.marketplace_accounts(id) on delete cascade,
  status text,  -- 판매·중지
  created_at timestamptz not null default now()
);
create index idx_listings_org_id on nomad_commerce.listings(organization_id);
alter table nomad_commerce.listings enable row level security;
create policy listings_select_member on nomad_commerce.listings for select using (nomad_core.organization_role(organization_id) is not null);
create policy listings_insert_member on nomad_commerce.listings for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy listings_update_member on nomad_commerce.listings for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy listings_delete_admin on nomad_commerce.listings for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.automation_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  kind text,  -- 이미지·번역·엑셀
  credits_used numeric,
  status text,
  created_at timestamptz not null default now()
);
create index idx_automation_jobs_org_id on nomad_commerce.automation_jobs(organization_id);
alter table nomad_commerce.automation_jobs enable row level security;
create policy automation_jobs_select_member on nomad_commerce.automation_jobs for select using (nomad_core.organization_role(organization_id) is not null);
create policy automation_jobs_insert_member on nomad_commerce.automation_jobs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy automation_jobs_update_member on nomad_commerce.automation_jobs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy automation_jobs_delete_admin on nomad_commerce.automation_jobs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  listing_id uuid references nomad_commerce.listings(id) on delete cascade,
  status text,
  total numeric,
  created_at timestamptz not null default now()
);
create index idx_orders_org_id on nomad_commerce.orders(organization_id);
alter table nomad_commerce.orders enable row level security;
create policy orders_select_member on nomad_commerce.orders for select using (nomad_core.organization_role(organization_id) is not null);
create policy orders_insert_member on nomad_commerce.orders for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy orders_update_member on nomad_commerce.orders for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy orders_delete_admin on nomad_commerce.orders for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

