-- commerce · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists commerce;

create table commerce.sourcing_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  source text,  -- 도매꾹·쿠팡
  source_url text,
  cost numeric,
  created_at timestamptz not null default now()
);
create index idx_sourcing_items_org_id on commerce.sourcing_items(org_id);
alter table commerce.sourcing_items enable row level security;
create policy sourcing_items_select_member on commerce.sourcing_items for select using (core.is_member(org_id));
create policy sourcing_items_insert_member on commerce.sourcing_items for insert with check (core.is_member(org_id));
create policy sourcing_items_update_member on commerce.sourcing_items for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy sourcing_items_delete_admin on commerce.sourcing_items for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table commerce.products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  item_id uuid references commerce.sourcing_items(id) on delete cascade,
  title text,
  detail_page text,  -- AI 상세
  price numeric,
  created_at timestamptz not null default now()
);
create index idx_products_org_id on commerce.products(org_id);
alter table commerce.products enable row level security;
create policy products_select_member on commerce.products for select using (core.is_member(org_id));
create policy products_insert_member on commerce.products for insert with check (core.is_member(org_id));
create policy products_update_member on commerce.products for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy products_delete_admin on commerce.products for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table commerce.marketplace_accounts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  marketplace text,  -- 스마트스토어
  token_ref text,  -- 암호화
  created_at timestamptz not null default now()
);
create index idx_marketplace_accounts_org_id on commerce.marketplace_accounts(org_id);
alter table commerce.marketplace_accounts enable row level security;
create policy marketplace_accounts_select_member on commerce.marketplace_accounts for select using (core.is_member(org_id));
create policy marketplace_accounts_insert_member on commerce.marketplace_accounts for insert with check (core.is_member(org_id));
create policy marketplace_accounts_update_member on commerce.marketplace_accounts for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy marketplace_accounts_delete_admin on commerce.marketplace_accounts for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table commerce.listings (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  product_id uuid references commerce.products(id) on delete cascade,
  account_id uuid references commerce.marketplace_accounts(id) on delete cascade,
  status text,  -- 판매·중지
  created_at timestamptz not null default now()
);
create index idx_listings_org_id on commerce.listings(org_id);
alter table commerce.listings enable row level security;
create policy listings_select_member on commerce.listings for select using (core.is_member(org_id));
create policy listings_insert_member on commerce.listings for insert with check (core.is_member(org_id));
create policy listings_update_member on commerce.listings for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy listings_delete_admin on commerce.listings for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table commerce.automation_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  kind text,  -- 이미지·번역·엑셀
  credits_used numeric,
  status text,
  created_at timestamptz not null default now()
);
create index idx_automation_jobs_org_id on commerce.automation_jobs(org_id);
alter table commerce.automation_jobs enable row level security;
create policy automation_jobs_select_member on commerce.automation_jobs for select using (core.is_member(org_id));
create policy automation_jobs_insert_member on commerce.automation_jobs for insert with check (core.is_member(org_id));
create policy automation_jobs_update_member on commerce.automation_jobs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy automation_jobs_delete_admin on commerce.automation_jobs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table commerce.orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  listing_id uuid references commerce.listings(id) on delete cascade,
  status text,
  total numeric,
  created_at timestamptz not null default now()
);
create index idx_orders_org_id on commerce.orders(org_id);
alter table commerce.orders enable row level security;
create policy orders_select_member on commerce.orders for select using (core.is_member(org_id));
create policy orders_insert_member on commerce.orders for insert with check (core.is_member(org_id));
create policy orders_update_member on commerce.orders for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy orders_delete_admin on commerce.orders for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

