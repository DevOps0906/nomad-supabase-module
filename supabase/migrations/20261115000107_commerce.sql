begin;

-- 커머스 (셀러) · 조직형 · 원본 청사진: blueprints/org/commerce/schema.draft.sql
-- 되돌림: drop schema nomad_commerce cascade; delete from nomad_core.products where code = 'commerce';

create schema nomad_commerce;
revoke all on schema nomad_commerce from public, anon, authenticated;
grant usage on schema nomad_commerce to authenticated, service_role;

insert into nomad_core.products (code, name) values ('commerce', '커머스 (셀러)');

create table nomad_commerce.sourcing_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  source text not null default 'domeggook' check (source in ('domeggook','coupang')),
  source_url text,
  cost bigint not null check (cost >= 0),
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_commerce.sourcing_items is '소싱 상품';
comment on column nomad_commerce.sourcing_items.source is '도매꾹·쿠팡';
comment on column nomad_commerce.sourcing_items.cost is '원 단위';
create index sourcing_items_org_created on nomad_commerce.sourcing_items(organization_id, created_at desc);
alter table nomad_commerce.sourcing_items enable row level security;
create policy sourcing_items_select on nomad_commerce.sourcing_items for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy sourcing_items_insert on nomad_commerce.sourcing_items for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy sourcing_items_update on nomad_commerce.sourcing_items for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy sourcing_items_delete on nomad_commerce.sourcing_items for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  item_id uuid,
  title text not null,
  detail_page text,
  price bigint not null check (price >= 0),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, item_id) references nomad_commerce.sourcing_items(organization_id, id) on delete cascade
);
comment on table nomad_commerce.products is '판매 상품';
comment on column nomad_commerce.products.price is '원 단위';
create index products_org_created on nomad_commerce.products(organization_id, created_at desc);
create index products_item_id on nomad_commerce.products(item_id);
alter table nomad_commerce.products enable row level security;
create policy products_select on nomad_commerce.products for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy products_insert on nomad_commerce.products for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy products_update on nomad_commerce.products for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy products_delete on nomad_commerce.products for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.marketplace_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  marketplace text,
  token_ref text,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_commerce.marketplace_accounts is '마켓 계정 연결';
comment on column nomad_commerce.marketplace_accounts.token_ref is '암호화 참조';
create index marketplace_accounts_org_created on nomad_commerce.marketplace_accounts(organization_id, created_at desc);
alter table nomad_commerce.marketplace_accounts enable row level security;
create policy marketplace_accounts_select on nomad_commerce.marketplace_accounts for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy marketplace_accounts_insert on nomad_commerce.marketplace_accounts for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy marketplace_accounts_update on nomad_commerce.marketplace_accounts for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy marketplace_accounts_delete on nomad_commerce.marketplace_accounts for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.listings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_id uuid,
  account_id uuid,
  status text not null default 'on_sale' check (status in ('on_sale','stopped')),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, product_id) references nomad_commerce.products(organization_id, id) on delete cascade,
  foreign key (organization_id, account_id) references nomad_commerce.marketplace_accounts(organization_id, id) on delete cascade
);
comment on table nomad_commerce.listings is '마켓 등록 상품';
comment on column nomad_commerce.listings.status is '판매·중지';
create index listings_org_created on nomad_commerce.listings(organization_id, created_at desc);
create index listings_product_id on nomad_commerce.listings(product_id);
create index listings_account_id on nomad_commerce.listings(account_id);
alter table nomad_commerce.listings enable row level security;
create policy listings_select on nomad_commerce.listings for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy listings_insert on nomad_commerce.listings for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy listings_update on nomad_commerce.listings for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy listings_delete on nomad_commerce.listings for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.automation_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  kind text not null default 'image' check (kind in ('image','translation','excel')),
  credits_used numeric not null default 0 check (credits_used >= 0),
  status text,
  created_at timestamptz not null default now()
);
comment on table nomad_commerce.automation_jobs is '자동화 작업';
comment on column nomad_commerce.automation_jobs.kind is '이미지·번역·엑셀';
create index automation_jobs_org_created on nomad_commerce.automation_jobs(organization_id, created_at desc);
alter table nomad_commerce.automation_jobs enable row level security;
create policy automation_jobs_select on nomad_commerce.automation_jobs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy automation_jobs_insert on nomad_commerce.automation_jobs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy automation_jobs_update on nomad_commerce.automation_jobs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy automation_jobs_delete on nomad_commerce.automation_jobs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_commerce.orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  listing_id uuid,
  status text,
  total bigint not null check (total >= 0),
  created_at timestamptz not null default now(),
  foreign key (organization_id, listing_id) references nomad_commerce.listings(organization_id, id) on delete cascade
);
comment on table nomad_commerce.orders is '주문';
comment on column nomad_commerce.orders.total is '원 단위';
create index orders_org_created on nomad_commerce.orders(organization_id, created_at desc);
create index orders_listing_id on nomad_commerce.orders(listing_id);
alter table nomad_commerce.orders enable row level security;
create policy orders_select on nomad_commerce.orders for select to authenticated using (nomad_core.organization_role(organization_id) is not null);

revoke all on all tables in schema nomad_commerce from public, anon, authenticated;
grant all on all tables in schema nomad_commerce to service_role;
grant select, insert, delete on nomad_commerce.sourcing_items to authenticated;
grant update (source, source_url, cost) on nomad_commerce.sourcing_items to authenticated;
grant select, insert, delete on nomad_commerce.products to authenticated;
grant update (item_id, title, detail_page, price) on nomad_commerce.products to authenticated;
grant select (id, organization_id, marketplace, created_at) on nomad_commerce.marketplace_accounts to authenticated;
grant delete on nomad_commerce.marketplace_accounts to authenticated;
grant insert (organization_id, marketplace) on nomad_commerce.marketplace_accounts to authenticated;
grant update (marketplace) on nomad_commerce.marketplace_accounts to authenticated;
grant select, insert, delete on nomad_commerce.listings to authenticated;
grant update (product_id, account_id, status) on nomad_commerce.listings to authenticated;
grant select on nomad_commerce.automation_jobs to authenticated;
grant delete on nomad_commerce.automation_jobs to authenticated;
grant insert (organization_id, kind, status) on nomad_commerce.automation_jobs to authenticated;
grant update (kind, status) on nomad_commerce.automation_jobs to authenticated;
grant select on nomad_commerce.orders to authenticated;

commit;
