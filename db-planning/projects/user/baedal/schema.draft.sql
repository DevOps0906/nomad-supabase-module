-- baedal · 개인형 (마켓플레이스) · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 개인형(user_id 기준)

create schema if not exists baedal;

create table baedal.stores (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references core.profiles(user_id),
  name text,
  category text,
  open_hours text,
  created_at timestamptz not null default now()
);
alter table baedal.stores enable row level security;
create policy stores_select_public on baedal.stores for select using (true);
create policy stores_own on baedal.stores for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create table baedal.menus (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references baedal.stores(id) on delete cascade,
  name text,
  price numeric,
  options jsonb,
  created_at timestamptz not null default now()
);
alter table baedal.menus enable row level security;
create policy menus_select_public on baedal.menus for select using (true);
create policy menus_own_via_stores on baedal.menus for all using (exists (select 1 from baedal.stores p where p.id = store_id and (p.owner_id = auth.uid())));

create table baedal.orders (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid references core.profiles(user_id),
  store_id uuid references baedal.stores(id) on delete cascade,
  status text,
  total numeric,
  created_at timestamptz not null default now()
);
alter table baedal.orders enable row level security;
create policy orders_own on baedal.orders for all using (buyer_id = auth.uid()) with check (buyer_id = auth.uid());

create table baedal.reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references baedal.orders(id) on delete cascade,
  writer_id uuid references core.profiles(user_id),
  rating numeric,
  created_at timestamptz not null default now()
);
alter table baedal.reviews enable row level security;
create policy reviews_own on baedal.reviews for all using (writer_id = auth.uid()) with check (writer_id = auth.uid());

create table baedal.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references baedal.orders(id) on delete cascade,
  menu_id uuid references baedal.menus(id) on delete cascade,
  qty numeric,
  created_at timestamptz not null default now()
);
alter table baedal.order_items enable row level security;
create policy order_items_own_via_orders on baedal.order_items for all using (exists (select 1 from baedal.orders p where p.id = order_id and (p.buyer_id = auth.uid())));

create table baedal.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references baedal.orders(id) on delete cascade,
  rider_id uuid references core.profiles(user_id),
  status text,
  eta text,
  created_at timestamptz not null default now()
);
alter table baedal.deliveries enable row level security;
create policy deliveries_own on baedal.deliveries for all using (rider_id = auth.uid()) with check (rider_id = auth.uid());

