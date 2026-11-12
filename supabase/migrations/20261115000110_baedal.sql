-- 동네배달(baedal) · 개인형(두 당사자 마켓플레이스) · 원본: blueprints/user/baedal/schema.draft.sql
-- 되돌림: drop schema nomad_baedal cascade; delete from nomad_core.products where code = 'baedal';
begin;

create schema nomad_baedal;
revoke all on schema nomad_baedal from public, anon, authenticated;
grant usage on schema nomad_baedal to authenticated, service_role;

insert into nomad_core.products (code, name) values ('baedal', '동네배달');

create table nomad_baedal.stores (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  category text,
  open_hours text,
  created_at timestamptz not null default now()
);

create table nomad_baedal.menus (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references nomad_baedal.stores(id) on delete cascade,
  name text not null,
  price bigint not null check (price >= 0),
  options jsonb,
  created_at timestamptz not null default now()
);

create table nomad_baedal.orders (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid default auth.uid() references auth.users(id) on delete set null,
  store_id uuid references nomad_baedal.stores(id) on delete set null,
  status text not null default 'requested' check (status in ('requested','accepted','cooking','delivering','delivered','cancelled')),
  total bigint not null check (total >= 0),
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create table nomad_baedal.reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references nomad_baedal.orders(id) on delete cascade,
  writer_id uuid default auth.uid() references auth.users(id) on delete set null,
  rating int check (rating between 1 and 5),
  created_at timestamptz not null default now(),
  unique (order_id)
);

create table nomad_baedal.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references nomad_baedal.orders(id) on delete cascade,
  menu_id uuid references nomad_baedal.menus(id) on delete set null,
  qty int not null check (qty > 0),
  created_at timestamptz not null default now()
);

create table nomad_baedal.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references nomad_baedal.orders(id) on delete cascade,
  rider_id uuid references auth.users(id) on delete set null,
  status text not null default 'waiting' check (status in ('waiting','assigned','picked_up','delivered')),
  eta text,
  created_at timestamptz not null default now()
);

comment on table nomad_baedal.stores is '가게(점주 소유)';
comment on table nomad_baedal.menus is '가게 메뉴';
comment on table nomad_baedal.orders is '주문(서버 전용 쓰기, 멱등 키 필수)';
comment on table nomad_baedal.reviews is '주문 후기(주문당 1건)';
comment on table nomad_baedal.order_items is '주문 항목(서버 전용 쓰기)';
comment on table nomad_baedal.deliveries is '배달 배정·진행(서버 전용 쓰기)';
comment on column nomad_baedal.orders.status is 'requested=요청, accepted=접수, cooking=조리중, delivering=배달중, delivered=배달완료, cancelled=취소';
comment on column nomad_baedal.deliveries.status is 'waiting=대기, assigned=배정, picked_up=픽업, delivered=배달완료';

create index stores_owner_created_idx on nomad_baedal.stores (owner_id, created_at desc);
create index menus_store_idx on nomad_baedal.menus (store_id);
create index orders_buyer_created_idx on nomad_baedal.orders (buyer_id, created_at desc);
create index orders_store_idx on nomad_baedal.orders (store_id);
create index reviews_writer_idx on nomad_baedal.reviews (writer_id);
create index order_items_order_idx on nomad_baedal.order_items (order_id);
create index order_items_menu_idx on nomad_baedal.order_items (menu_id);
create index deliveries_order_idx on nomad_baedal.deliveries (order_id);
create index deliveries_rider_idx on nomad_baedal.deliveries (rider_id);

alter table nomad_baedal.stores enable row level security;
alter table nomad_baedal.menus enable row level security;
alter table nomad_baedal.orders enable row level security;
alter table nomad_baedal.reviews enable row level security;
alter table nomad_baedal.order_items enable row level security;
alter table nomad_baedal.deliveries enable row level security;

-- stores
create policy stores_select on nomad_baedal.stores for select to authenticated using (true);
create policy stores_insert on nomad_baedal.stores for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy stores_update on nomad_baedal.stores for update to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy stores_delete on nomad_baedal.stores for delete to authenticated using ((select auth.uid()) = owner_id);

-- menus
create policy menus_select on nomad_baedal.menus for select to authenticated using (true);
create policy menus_insert on nomad_baedal.menus for insert to authenticated
  with check (exists (select 1 from nomad_baedal.stores s where s.id = store_id and s.owner_id = (select auth.uid())));
create policy menus_update on nomad_baedal.menus for update to authenticated
  using (exists (select 1 from nomad_baedal.stores s where s.id = store_id and s.owner_id = (select auth.uid())))
  with check (exists (select 1 from nomad_baedal.stores s where s.id = store_id and s.owner_id = (select auth.uid())));
create policy menus_delete on nomad_baedal.menus for delete to authenticated
  using (exists (select 1 from nomad_baedal.stores s where s.id = store_id and s.owner_id = (select auth.uid())));

-- orders (서버 전용 쓰기: select만)
create policy orders_select on nomad_baedal.orders for select to authenticated
  using (
    buyer_id = (select auth.uid())
    or exists (select 1 from nomad_baedal.stores s where s.id = store_id and s.owner_id = (select auth.uid()))
  );

-- order_items (서버 전용 쓰기: select만)
create policy order_items_select on nomad_baedal.order_items for select to authenticated
  using (exists (
    select 1 from nomad_baedal.orders o
    where o.id = order_id
      and (o.buyer_id = (select auth.uid())
           or exists (select 1 from nomad_baedal.stores s where s.id = o.store_id and s.owner_id = (select auth.uid())))
  ));

-- deliveries (서버 전용 쓰기: select만)
create policy deliveries_select on nomad_baedal.deliveries for select to authenticated
  using (
    rider_id = (select auth.uid())
    or exists (
      select 1 from nomad_baedal.orders o
      where o.id = order_id
        and (o.buyer_id = (select auth.uid())
             or exists (select 1 from nomad_baedal.stores s where s.id = o.store_id and s.owner_id = (select auth.uid())))
    )
  );

-- reviews
create policy reviews_select on nomad_baedal.reviews for select to authenticated
  using (
    writer_id = (select auth.uid())
    or exists (
      select 1 from nomad_baedal.orders o
      join nomad_baedal.stores s on s.id = o.store_id
      where o.id = order_id and s.owner_id = (select auth.uid())
    )
  );
create policy reviews_insert on nomad_baedal.reviews for insert to authenticated
  with check (
    writer_id = (select auth.uid())
    and exists (select 1 from nomad_baedal.orders o where o.id = order_id and o.buyer_id = (select auth.uid()) and o.status = 'delivered')
  );
create policy reviews_update on nomad_baedal.reviews for update to authenticated using ((select auth.uid()) = writer_id) with check ((select auth.uid()) = writer_id);
create policy reviews_delete on nomad_baedal.reviews for delete to authenticated using ((select auth.uid()) = writer_id);

revoke all on all tables in schema nomad_baedal from public, anon, authenticated;
grant all on all tables in schema nomad_baedal to service_role;
grant select, insert, delete on nomad_baedal.stores, nomad_baedal.menus, nomad_baedal.reviews to authenticated;
grant select on nomad_baedal.orders, nomad_baedal.order_items, nomad_baedal.deliveries to authenticated;
grant update (name, category, open_hours) on nomad_baedal.stores to authenticated;
grant update (name, price, options) on nomad_baedal.menus to authenticated;
grant update (rating) on nomad_baedal.reviews to authenticated;

commit;
