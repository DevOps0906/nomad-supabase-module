-- 동네배달(baedal) · 개인형(user안) · 원본(기존): 레포 없음 → 청사진 blueprints/user/baedal + supabase/migrations/*_baedal.sql(nomad_baedal) 최종 상태
-- 소유 = auth.users. 가게 = owner_id(점주), 주문 = buyer_id(주문자), 배달 = rider_id(배달원). 잠금: 점주의 개인(owner) 조직 이용권 baedal/order_core.
-- 개인정보(주소·전화)는 order_contacts에만 두고 해당 주문 당사자(주문자·가게 점주·진행 중 배정 배달원)만 읽는다.
-- 금액은 정수(원, bigint). 주문 = (buyer_id, idempotency_key) 멱등, 결제 반영 = pg_event_id(필수, 유일) 멱등.
-- 전제: nomad_core.touch_updated_at()(core 20261119000100). 되돌림: drop schema nomad_baedal cascade; drop schema nomad_baedal_private cascade;
begin;

create schema nomad_baedal;
create schema nomad_baedal_private;
revoke all on schema nomad_baedal, nomad_baedal_private from public, anon, authenticated;
grant usage on schema nomad_baedal to authenticated, service_role;   -- anon 사용 없음(공개 RPC 없음)
grant usage on schema nomad_baedal_private to authenticated, service_role;  -- 정책 판정 함수만(노출 금지 스키마)

insert into nomad_core.products (code, name) values ('baedal', '동네배달') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('baedal', 'C', '무료'), ('baedal', 'B', '프로'), ('baedal', 'A', '비즈니스') on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values ('baedal', 'order_core', '가게·메뉴·후기') on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('baedal', 'C', 'order_core'), ('baedal', 'B', 'order_core'), ('baedal', 'A', 'order_core') on conflict do nothing;

-- ===== 테이블 =====
create table nomad_baedal.stores (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 100),
  category    text check (category is null or char_length(category) <= 50),
  open_hours  text check (open_hours is null or char_length(open_hours) <= 200),
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index stores_owner_created_idx on nomad_baedal.stores (owner_id, created_at desc);
comment on table nomad_baedal.stores is '가게(점주 소유). 로그인 사용자 열람(폐점 제외), 점주만 수정, 폐점은 close_store(소프트 삭제)';

create table nomad_baedal.menus (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references nomad_baedal.stores (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 100),
  price       bigint not null check (price between 0 and 100000000),
  options     jsonb check (options is null or (jsonb_typeof(options) = 'object' and octet_length(options::text) <= 8192)),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index menus_store_idx on nomad_baedal.menus (store_id);
comment on table nomad_baedal.menus is '가게 메뉴. 가격 정수(원)';

create table nomad_baedal.orders (
  id               uuid primary key default gen_random_uuid(),
  buyer_id         uuid references auth.users (id) on delete set null,
  store_id         uuid references nomad_baedal.stores (id) on delete set null,
  status           text not null default 'requested'
                   check (status in ('requested', 'accepted', 'cooking', 'delivering', 'delivered', 'cancelled')),
  total            bigint not null check (total >= 0),
  idempotency_key  text not null check (char_length(idempotency_key) between 8 and 128),
  paid_at          timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint orders_buyer_idem_key unique (buyer_id, idempotency_key)
);
create index orders_buyer_created_idx on nomad_baedal.orders (buyer_id, created_at desc);
create index orders_store_created_idx on nomad_baedal.orders (store_id, created_at desc);
comment on table nomad_baedal.orders is '주문(쓰기는 RPC만). 합계는 서버가 메뉴 가격으로 계산, (buyer_id, idempotency_key) 멱등';
comment on column nomad_baedal.orders.status is 'requested=요청, accepted=접수, cooking=조리중, delivering=배달중, delivered=배달완료, cancelled=취소';

create table nomad_baedal.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references nomad_baedal.orders (id) on delete cascade,
  menu_id     uuid references nomad_baedal.menus (id) on delete set null,
  menu_name   text not null,
  unit_price  bigint not null check (unit_price >= 0),
  qty         int not null check (qty between 1 and 99),
  created_at  timestamptz not null default now()
);
create index order_items_order_idx on nomad_baedal.order_items (order_id);
create index order_items_menu_idx on nomad_baedal.order_items (menu_id);
comment on table nomad_baedal.order_items is '주문 항목(주문 시점 메뉴 이름·단가 스냅숏, 쓰기는 place_order만)';

create table nomad_baedal.order_contacts (
  order_id          uuid primary key references nomad_baedal.orders (id) on delete cascade,
  delivery_address  text not null check (char_length(delivery_address) between 1 and 300),
  buyer_phone       text not null check (buyer_phone ~ '^[0-9+-]{8,20}$'),
  rider_phone       text check (rider_phone is null or rider_phone ~ '^[0-9+-]{8,20}$'),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table nomad_baedal.order_contacts is '주문 개인정보(배달 주소·주문자 전화·배달원 전화). 주문자·점주·진행 중 배정 배달원만 열람';

create table nomad_baedal.deliveries (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null unique references nomad_baedal.orders (id) on delete cascade,
  rider_id    uuid references auth.users (id) on delete set null,
  status      text not null default 'assigned' check (status in ('waiting', 'assigned', 'picked_up', 'delivered', 'cancelled')),
  eta         text check (eta is null or char_length(eta) <= 50),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index deliveries_rider_idx on nomad_baedal.deliveries (rider_id, created_at desc);
comment on table nomad_baedal.deliveries is '배달 배정(assign_rider, 서버)·진행(update_delivery, 배정 배달원). 주문당 1건';
comment on column nomad_baedal.deliveries.status is 'waiting=대기, assigned=배정, picked_up=픽업, delivered=배달완료, cancelled=주문 취소로 종료';

create table nomad_baedal.payments (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references nomad_baedal.orders (id) on delete cascade,
  amount       bigint not null check (amount > 0),
  pg_event_id  text not null unique check (char_length(pg_event_id) between 1 and 200),
  created_at   timestamptz not null default now()
);
create index payments_order_idx on nomad_baedal.payments (order_id);
comment on table nomad_baedal.payments is '결제 반영(apply_payment, 서버 전용). PG 이벤트 id 필수·유일 = 멱등';

create table nomad_baedal.reviews (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null unique references nomad_baedal.orders (id) on delete cascade,
  writer_id   uuid default auth.uid() references auth.users (id) on delete set null,
  rating      int not null check (rating between 1 and 5),
  created_at  timestamptz not null default now()
);
create index reviews_writer_idx on nomad_baedal.reviews (writer_id);
comment on table nomad_baedal.reviews is '주문 후기(배달완료 주문의 주문자만, 주문당 1건). 작성자·해당 가게 점주만 열람';

create trigger stores_touch before update on nomad_baedal.stores for each row execute function nomad_core.touch_updated_at();
create trigger menus_touch before update on nomad_baedal.menus for each row execute function nomad_core.touch_updated_at();
create trigger orders_touch before update on nomad_baedal.orders for each row execute function nomad_core.touch_updated_at();
create trigger order_contacts_touch before update on nomad_baedal.order_contacts for each row execute function nomad_core.touch_updated_at();
create trigger deliveries_touch before update on nomad_baedal.deliveries for each row execute function nomad_core.touch_updated_at();

-- ===== 판정 함수(private, security definer — RLS 재귀 없이 표를 본다, boolean만 반환) =====
-- 사용자(점주)의 개인(owner) 조직 중 하나라도 baedal/order_core가 열려 있는가(내부 전용)
create function nomad_baedal_private.owner_has_feature(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from nomad_core.memberships m
    join nomad_core.organizations o on o.id = m.organization_id
    where m.user_id = p_user and m.role = 'owner' and o.active
      and nomad_core.org_has_feature(m.organization_id, 'baedal', 'order_core'))
$$;

-- 호출자가 가게 점주인가(폐점 포함)
create function nomad_baedal_private.manages_store(p_store uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from nomad_baedal.stores s where s.id = p_store and s.owner_id = (select auth.uid()))
$$;

-- 호출자가 가게를 고칠 수 있는가: 점주 + 영업 중 + 이용권
create function nomad_baedal_private.store_writable(p_store uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from nomad_baedal.stores s
    where s.id = p_store and s.owner_id = (select auth.uid()) and s.deleted_at is null
      and nomad_baedal_private.owner_has_feature(s.owner_id))
$$;

-- 주문 당사자(주문자·점주) 여부 — 결제·항목·후기 열람
create function nomad_baedal_private.is_order_buyer_or_store(p_order uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from nomad_baedal.orders o
    where o.id = p_order
      and (o.buyer_id = (select auth.uid()) or nomad_baedal_private.manages_store(o.store_id)))
$$;

-- 주문 열람: 주문자·점주·배정 배달원
create function nomad_baedal_private.order_visible(p_order uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select nomad_baedal_private.is_order_buyer_or_store(p_order)
      or exists (select 1 from nomad_baedal.deliveries d where d.order_id = p_order and d.rider_id = (select auth.uid()))
$$;

-- 개인정보 열람: 주문자·점주·진행 중(assigned·picked_up) 배정 배달원
create function nomad_baedal_private.contacts_visible(p_order uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select nomad_baedal_private.is_order_buyer_or_store(p_order)
      or exists (select 1 from nomad_baedal.deliveries d
                 join nomad_baedal.orders o on o.id = d.order_id
                 where d.order_id = p_order and d.rider_id = (select auth.uid()) and d.status in ('assigned', 'picked_up')
                   and o.status in ('accepted', 'cooking', 'delivering'))
$$;

-- ===== RLS =====
alter table nomad_baedal.stores enable row level security;
alter table nomad_baedal.menus enable row level security;
alter table nomad_baedal.orders enable row level security;
alter table nomad_baedal.order_items enable row level security;
alter table nomad_baedal.order_contacts enable row level security;
alter table nomad_baedal.deliveries enable row level security;
alter table nomad_baedal.payments enable row level security;
alter table nomad_baedal.reviews enable row level security;

create policy stores_select on nomad_baedal.stores for select to authenticated
  using (deleted_at is null or owner_id = (select auth.uid()));
create policy stores_insert on nomad_baedal.stores for insert to authenticated
  with check (owner_id = (select auth.uid()) and deleted_at is null
              and (select nomad_core.user_has_feature('baedal', 'order_core')));
create policy stores_update on nomad_baedal.stores for update to authenticated
  using (nomad_baedal_private.store_writable(id)) with check (nomad_baedal_private.store_writable(id));

create policy menus_select on nomad_baedal.menus for select to authenticated
  using (exists (select 1 from nomad_baedal.stores s where s.id = store_id));  -- stores RLS(폐점 제외·점주는 전부) 적용
create policy menus_insert on nomad_baedal.menus for insert to authenticated with check (nomad_baedal_private.store_writable(store_id));
create policy menus_update on nomad_baedal.menus for update to authenticated
  using (nomad_baedal_private.store_writable(store_id)) with check (nomad_baedal_private.store_writable(store_id));
create policy menus_delete on nomad_baedal.menus for delete to authenticated using (nomad_baedal_private.store_writable(store_id));

-- 주문·항목·연락처·배달·결제: 쓰기는 RPC(security definer)·service_role만 → select 정책만
create policy orders_select on nomad_baedal.orders for select to authenticated using (nomad_baedal_private.order_visible(id));
create policy order_items_select on nomad_baedal.order_items for select to authenticated using (nomad_baedal_private.order_visible(order_id));
create policy order_contacts_select on nomad_baedal.order_contacts for select to authenticated using (nomad_baedal_private.contacts_visible(order_id));
create policy deliveries_select on nomad_baedal.deliveries for select to authenticated
  using (rider_id = (select auth.uid()) or nomad_baedal_private.is_order_buyer_or_store(order_id));
create policy payments_select on nomad_baedal.payments for select to authenticated using (nomad_baedal_private.is_order_buyer_or_store(order_id));

create policy reviews_select on nomad_baedal.reviews for select to authenticated
  using (writer_id = (select auth.uid()) or nomad_baedal_private.is_order_buyer_or_store(order_id));
create policy reviews_insert on nomad_baedal.reviews for insert to authenticated
  with check (
    writer_id = (select auth.uid())
    and exists (select 1 from nomad_baedal.orders o
                where o.id = order_id and o.buyer_id = (select auth.uid()) and o.status = 'delivered'));
create policy reviews_update on nomad_baedal.reviews for update to authenticated
  using (writer_id = (select auth.uid())) with check (writer_id = (select auth.uid()));
create policy reviews_delete on nomad_baedal.reviews for delete to authenticated using (writer_id = (select auth.uid()));

-- ===== RPC =====
-- 주문 생성(주문자). 합계 = 서버가 메뉴 가격 × 수량. 같은 (주문자, 멱등 키)면 기존 주문 id를 돌려준다.
-- p_items = [{"menu_id": uuid, "qty": 1~99}] 1~50개, 모두 그 가게 메뉴. 가게 없음·폐점·잠김 = P0002(존재 노출 없음).
create function nomad_baedal.place_order(
  p_store_id uuid, p_items jsonb, p_delivery_address text, p_buyer_phone text, p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_total bigint;
  v_n int;
  v_ok int;
begin
  if v_uid is null then
    raise exception 'login required' using errcode = '42501';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 128 then
    raise exception 'idempotency key required (8~128)' using errcode = '22023';
  end if;
  select o.id into v_id from nomad_baedal.orders o where o.buyer_id = v_uid and o.idempotency_key = p_idempotency_key;
  if found then
    return v_id;
  end if;

  if not exists (select 1 from nomad_baedal.stores s
                 where s.id = p_store_id and s.deleted_at is null
                   and nomad_baedal_private.owner_has_feature(s.owner_id)) then
    raise exception 'store not found' using errcode = 'P0002';
  end if;
  if p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array'
     or pg_catalog.jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'items must be an array of 1~50' using errcode = '22023';
  end if;
  v_n := pg_catalog.jsonb_array_length(p_items);
  -- 이 가게 메뉴를 잠가(for share) 합계 계산과 항목 스냅숏 사이에 가격이 바뀌지 않게 한다
  perform 1 from nomad_baedal.menus m where m.store_id = p_store_id for share;
  select pg_catalog.count(*), coalesce(pg_catalog.sum(m.price * (e.v ->> 'qty')::int), 0) into v_ok, v_total
  from pg_catalog.jsonb_array_elements(p_items) as e(v)
  join nomad_baedal.menus m
    on m.store_id = p_store_id
   and pg_catalog.jsonb_typeof(e.v) = 'object'
   and (e.v ->> 'menu_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   and m.id = (case when (e.v ->> 'menu_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                    then (e.v ->> 'menu_id')::uuid end)
   and pg_catalog.jsonb_typeof(e.v -> 'qty') = 'number'
   and (e.v ->> 'qty') ~ '^[0-9]{1,2}$' and (e.v ->> 'qty')::int between 1 and 99;
  if v_ok <> v_n then
    raise exception 'invalid items (menu of this store, qty 1~99)' using errcode = '22023';
  end if;

  insert into nomad_baedal.orders (buyer_id, store_id, total, idempotency_key)
  values (v_uid, p_store_id, v_total, p_idempotency_key)
  on conflict (buyer_id, idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then  -- 동시 같은 키
    select o.id into v_id from nomad_baedal.orders o where o.buyer_id = v_uid and o.idempotency_key = p_idempotency_key;
    return v_id;
  end if;

  insert into nomad_baedal.order_items (order_id, menu_id, menu_name, unit_price, qty)
  select v_id, m.id, m.name, m.price, (e.v ->> 'qty')::int
  from pg_catalog.jsonb_array_elements(p_items) as e(v)
  join nomad_baedal.menus m on m.store_id = p_store_id and m.id = (e.v ->> 'menu_id')::uuid;
  -- 합계 = 저장된 항목 합(정의상 일치 보장)
  update nomad_baedal.orders o
     set total = (select coalesce(pg_catalog.sum(i.unit_price * i.qty), 0) from nomad_baedal.order_items i where i.order_id = v_id)
   where o.id = v_id;
  insert into nomad_baedal.order_contacts (order_id, delivery_address, buyer_phone)
  values (v_id, p_delivery_address, p_buyer_phone);
  return v_id;
end;
$$;

-- 주문 상태 변경. 점주: requested→accepted(결제 반영 후)·accepted→cooking(이용권 필요), requested|accepted→cancelled.
-- 주문자: requested→cancelled. 당사자가 아니면 P0002.
create function nomad_baedal.set_order_status(p_order_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_o nomad_baedal.orders%rowtype;
  v_store boolean;
begin
  select * into v_o from nomad_baedal.orders o where o.id = p_order_id for update;
  if not found or v_uid is null then
    raise exception 'order not found' using errcode = 'P0002';
  end if;
  v_store := nomad_baedal_private.manages_store(v_o.store_id);
  if not v_store and v_o.buyer_id is distinct from v_uid then
    raise exception 'order not found' using errcode = 'P0002';
  end if;

  if v_store and (
       (v_o.status = 'requested' and p_status = 'accepted')
       or (v_o.status = 'accepted' and p_status = 'cooking')) then
    if not nomad_baedal_private.store_writable(v_o.store_id) then
      raise exception 'store locked' using errcode = '42501';
    end if;
    if p_status = 'accepted' and v_o.paid_at is null then
      raise exception 'order not paid' using errcode = '22023';
    end if;
  elsif p_status = 'cancelled' and (
       (v_store and v_o.status in ('requested', 'accepted'))
       or (v_o.buyer_id = v_uid and v_o.status = 'requested')) then
    null;
  else
    raise exception 'invalid transition % -> %', v_o.status, p_status using errcode = '22023';
  end if;
  update nomad_baedal.orders set status = p_status where id = p_order_id;
  if p_status = 'cancelled' then  -- 배정된 배달 종료 → 배달원 개인정보 열람 종료
    update nomad_baedal.deliveries set status = 'cancelled' where order_id = p_order_id and status in ('waiting', 'assigned', 'picked_up');
  end if;
end;
$$;

-- 배달 진행(배정 배달원만): assigned→picked_up(주문 delivering), picked_up→delivered(주문 delivered). 아니면 P0002.
create function nomad_baedal.update_delivery(p_order_id uuid, p_status text, p_eta text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_d nomad_baedal.deliveries%rowtype;
begin
  select * into v_d from nomad_baedal.deliveries d where d.order_id = p_order_id and d.rider_id = auth.uid() for update;
  if not found or auth.uid() is null then
    raise exception 'delivery not found' using errcode = 'P0002';
  end if;
  perform 1 from nomad_baedal.orders o where o.id = p_order_id for update;
  if v_d.status = 'assigned' and p_status = 'picked_up' then
    update nomad_baedal.orders set status = 'delivering' where id = p_order_id and status in ('accepted', 'cooking');
  elsif v_d.status = 'picked_up' and p_status = 'delivered' then
    update nomad_baedal.orders set status = 'delivered' where id = p_order_id and status = 'delivering';
  else
    raise exception 'invalid transition % -> %', v_d.status, p_status using errcode = '22023';
  end if;
  if not found then
    raise exception 'order not in deliverable state' using errcode = '22023';
  end if;
  update nomad_baedal.deliveries set status = p_status, eta = coalesce(p_eta, eta) where id = v_d.id;
end;
$$;

-- 폐점(점주만, 소프트 삭제 now()). 메뉴·주문 기록은 남는다.
create function nomad_baedal.close_store(p_store_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update nomad_baedal.stores set deleted_at = pg_catalog.now()
  where id = p_store_id and owner_id = auth.uid() and deleted_at is null;
  if not found then
    raise exception 'store not found' using errcode = 'P0002';
  end if;
end;
$$;

-- [서버] 결제 반영. PG 이벤트 id 필수·유일 → 같은 이벤트 재전송은 기존 결제 id. 금액은 주문 합계와 같아야 한다.
create function nomad_baedal.apply_payment(p_order_id uuid, p_amount bigint, p_pg_event_id text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_o nomad_baedal.orders%rowtype;
  v_p nomad_baedal.payments%rowtype;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'server only' using errcode = '42501';
  end if;
  if p_pg_event_id is null or char_length(p_pg_event_id) not between 1 and 200 then
    raise exception 'pg_event_id required' using errcode = '22023';
  end if;
  select * into v_p from nomad_baedal.payments p where p.pg_event_id = p_pg_event_id;
  if found then
    if v_p.order_id is distinct from p_order_id or v_p.amount is distinct from p_amount then
      raise exception 'pg_event_id reused with different order or amount' using errcode = '22023';
    end if;
    return v_p.id;
  end if;
  select * into v_o from nomad_baedal.orders o where o.id = p_order_id for update;
  if not found then
    raise exception 'order not found' using errcode = 'P0002';
  end if;
  -- 잠금 뒤 재조회: 같은 이벤트가 동시에 들어와 먼저 반영됐으면 그 결제 id
  select * into v_p from nomad_baedal.payments p where p.pg_event_id = p_pg_event_id;
  if found then
    if v_p.order_id is distinct from p_order_id or v_p.amount is distinct from p_amount then
      raise exception 'pg_event_id reused with different order or amount' using errcode = '22023';
    end if;
    return v_p.id;
  end if;
  if v_o.status = 'cancelled' or v_o.paid_at is not null then
    raise exception 'order not payable' using errcode = '22023';
  end if;
  if p_amount is distinct from v_o.total then
    raise exception 'amount mismatch' using errcode = '22023';
  end if;
  insert into nomad_baedal.payments (order_id, amount, pg_event_id) values (p_order_id, p_amount, p_pg_event_id)
  returning id into v_id;
  update nomad_baedal.orders set paid_at = pg_catalog.now() where id = p_order_id;
  return v_id;
end;
$$;

-- [서버] 배달원 배정(접수·조리중 주문, 주문당 1회). 같은 배달원 재호출은 무시(멱등).
create function nomad_baedal.assign_rider(p_order_id uuid, p_rider_id uuid, p_rider_phone text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_rider uuid;
begin
  if not nomad_core.is_service_caller() then
    raise exception 'server only' using errcode = '42501';
  end if;
  perform 1 from nomad_baedal.orders o where o.id = p_order_id and o.status in ('accepted', 'cooking') for update;
  if not found then
    raise exception 'order not assignable' using errcode = '22023';
  end if;
  select d.rider_id into v_rider from nomad_baedal.deliveries d where d.order_id = p_order_id;
  if found then
    if v_rider is distinct from p_rider_id then
      raise exception 'already assigned' using errcode = '23505';
    end if;
    return;
  end if;
  insert into nomad_baedal.deliveries (order_id, rider_id, status) values (p_order_id, p_rider_id, 'assigned');
  update nomad_baedal.order_contacts set rider_phone = p_rider_phone where order_id = p_order_id;
end;
$$;

-- ===== 권한 =====
revoke all on all tables in schema nomad_baedal from public, anon, authenticated;
revoke all on all functions in schema nomad_baedal from public, anon, authenticated;
revoke all on all functions in schema nomad_baedal_private from public, anon, authenticated;
grant all on all tables in schema nomad_baedal to service_role;
grant select on all tables in schema nomad_baedal to authenticated;
grant insert (name, category, open_hours) on nomad_baedal.stores to authenticated;
grant update (name, category, open_hours) on nomad_baedal.stores to authenticated;
grant insert (store_id, name, price, options), update (name, price, options), delete on nomad_baedal.menus to authenticated;
grant insert (order_id, rating), update (rating), delete on nomad_baedal.reviews to authenticated;
grant execute on function
  nomad_baedal_private.manages_store(uuid), nomad_baedal_private.store_writable(uuid),
  nomad_baedal_private.is_order_buyer_or_store(uuid), nomad_baedal_private.order_visible(uuid),
  nomad_baedal_private.contacts_visible(uuid)
  to authenticated, service_role;
grant execute on function
  nomad_baedal.place_order(uuid, jsonb, text, text, text), nomad_baedal.set_order_status(uuid, text),
  nomad_baedal.update_delivery(uuid, text, text), nomad_baedal.close_store(uuid)
  to authenticated, service_role;
grant execute on function nomad_baedal.apply_payment(uuid, bigint, text), nomad_baedal.assign_rider(uuid, uuid, text) to service_role;

commit;
