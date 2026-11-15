-- 동네장터(jangter) · 개인형(user안) · 원본: supabase/migrations/20261115000109_jangter.sql(청사진 = "기존") + 20261116000109_jangter.sql(기능 카탈로그)
-- 소유 = auth.users(seller_id·user_id·writer_id). 잠금: nomad_core.user_has_feature('jangter', 'trade_core')(개인 조직 이용권) — 쓰기만 잠그고 읽기·공개 열람·삭제는 유지.
-- 공개 목록은 RPC(list_listings·get_listing·listing_seller_reviews)로만. 표는 본인·거래 당사자만. 대응표: products/jangter/existing.md
-- 금액(price)은 정수(bigint, 원). 되돌림: drop schema nomad_jangter cascade; drop schema nomad_jangter_private cascade;
begin;

create schema nomad_jangter;
create schema nomad_jangter_private;
revoke all on schema nomad_jangter, nomad_jangter_private from public, anon, authenticated;
grant usage on schema nomad_jangter to anon, authenticated, service_role;   -- anon 은 공개 RPC 만(표 권한 없음)
grant usage on schema nomad_jangter_private to authenticated, service_role; -- 정책이 부르는 판정 함수만

-- 카탈로그(이미 있으면 그대로). 플랜 수치 한도는 시드하지 않는다.
insert into nomad_core.products (code, name) values ('jangter', '동네장터') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values
  ('jangter', 'C', '무료'), ('jangter', 'B', '프로'), ('jangter', 'A', '비즈니스') on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('jangter', 'trade_core', '판매 글·사진·관심·채팅·후기') on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('jangter', 'C', 'trade_core'), ('jangter', 'B', 'trade_core'), ('jangter', 'A', 'trade_core') on conflict do nothing;

-- ===== 테이블 =====
create table nomad_jangter.listings (
  id          uuid primary key default gen_random_uuid(),
  seller_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title       text not null check (char_length(title) between 1 and 100),
  price       bigint not null check (price >= 0),
  status      text not null default 'on_sale' check (status in ('on_sale', 'reserved', 'sold', 'hidden')),
  dong        text check (dong is null or char_length(dong) <= 50),  -- 동네
  sold_room_id  uuid,  -- 판매 완료 시 거래한 구매 방(후기 자격)
  created_at  timestamptz not null default now(),
  unique (id, seller_id),
  -- sold ⇔ 구매 방 기록
  check ((status = 'sold') = (sold_room_id is not null))
);

create table nomad_jangter.listing_photos (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null,
  seller_id     uuid not null default auth.uid(),
  storage_path  text not null,
  "position"    text,
  created_at    timestamptz not null default now(),
  foreign key (listing_id, seller_id) references nomad_jangter.listings (id, seller_id) on delete cascade,
  -- 저장 경로는 <seller_id>/<listing_id>/ 로 시작(남의 경로 지정 금지)
  constraint listing_photos_path_prefix check (
    storage_path like seller_id::text || '/' || listing_id::text || '/%'
    and position('..' in storage_path) = 0 and char_length(storage_path) <= 300)
);

create table nomad_jangter.favorites (
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  listing_id  uuid not null references nomad_jangter.listings (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, listing_id)
);

create table nomad_jangter.chat_rooms (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid,
  buyer_id    uuid references auth.users (id) on delete set null,
  seller_id   uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (listing_id, buyer_id),
  unique (id, listing_id),
  -- 판매자는 글의 판매자와 같아야 한다. 글이 지워지면 listing_id 만 비운다(대화 보존)
  foreign key (listing_id, seller_id) references nomad_jangter.listings (id, seller_id) on delete set null (listing_id),
  check (buyer_id is distinct from seller_id or buyer_id is null)
);

-- 구매 방은 그 글의 방이어야 한다(복합 FK)
alter table nomad_jangter.listings add constraint listings_sold_room_fk
  foreign key (sold_room_id, id) references nomad_jangter.chat_rooms (id, listing_id);

create table nomad_jangter.messages (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references nomad_jangter.chat_rooms (id) on delete cascade,
  sender_id   uuid default auth.uid() references auth.users (id) on delete set null,
  body        text not null check (char_length(body) between 1 and 2000),
  sent_at     timestamptz,
  created_at  timestamptz not null default now()
);

create table nomad_jangter.reviews (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references nomad_jangter.chat_rooms (id) on delete cascade,
  writer_id   uuid default auth.uid() references auth.users (id) on delete set null,
  score       int not null check (score between 1 and 5),
  comment     text check (comment is null or char_length(comment) <= 1000),
  created_at  timestamptz not null default now(),
  unique (room_id, writer_id)
);

comment on table nomad_jangter.listings is '판매 글(판매자 소유). 공개 열람은 list_listings·get_listing RPC 로만';
comment on table nomad_jangter.listing_photos is '판매 글 사진(판매자 소유, 경로 <seller_id>/<listing_id>/…)';
comment on table nomad_jangter.favorites is '관심 글(사용자 소유)';
comment on table nomad_jangter.chat_rooms is '구매자-판매자 채팅방(두 당사자). 생성은 open_chat RPC';
comment on table nomad_jangter.messages is '채팅 메시지(수정·삭제 불가)';
comment on table nomad_jangter.reviews is '거래 후기(채팅방당 작성자 1건, 판매 완료 글만)';
comment on column nomad_jangter.listings.status is 'on_sale=판매중, reserved=예약중, sold=판매완료, hidden=숨김';

create index listings_seller_created_idx on nomad_jangter.listings (seller_id, created_at desc);
create index listings_public_idx on nomad_jangter.listings (dong, created_at desc) where status <> 'hidden';
create index listings_public_all_idx on nomad_jangter.listings (created_at desc) where status <> 'hidden';
create index listing_photos_listing_idx on nomad_jangter.listing_photos (listing_id, seller_id);
create index favorites_listing_idx on nomad_jangter.favorites (listing_id);
create index chat_rooms_listing_idx on nomad_jangter.chat_rooms (listing_id, seller_id);
create index chat_rooms_buyer_idx on nomad_jangter.chat_rooms (buyer_id);
create index chat_rooms_seller_idx on nomad_jangter.chat_rooms (seller_id);
create index messages_room_idx on nomad_jangter.messages (room_id, created_at);
create index messages_sender_idx on nomad_jangter.messages (sender_id);
create index reviews_room_idx on nomad_jangter.reviews (room_id);
create index reviews_writer_idx on nomad_jangter.reviews (writer_id);

-- ===== 판정 함수(private) =====
-- 쓰기 잠금: 호출자 개인 조직의 jangter/trade_core
create function nomad_jangter_private.can_trade() returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and nomad_core.user_has_feature('jangter', 'trade_core')
$$;

-- 공개(숨김 아님) 글인가. 숨김·없음은 구분하지 않는다(존재 노출 금지)
create function nomad_jangter_private.listing_visible(p_listing uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from nomad_jangter.listings l where l.id = p_listing and l.status <> 'hidden')
$$;

-- 호출자가 당사자인 방이고 글이 판매 완료이며 그 방이 기록된 구매 방인가(후기 작성 조건)
create function nomad_jangter_private.room_sold_for_me(p_room uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from nomad_jangter.chat_rooms r
    join nomad_jangter.listings l on l.id = r.listing_id and l.seller_id = r.seller_id and l.sold_room_id = r.id
    where r.id = p_room and l.status = 'sold'
      and (select auth.uid()) is not null
      and (select auth.uid()) in (r.buyer_id, r.seller_id))
$$;

-- ===== RLS =====
alter table nomad_jangter.listings enable row level security;
alter table nomad_jangter.listing_photos enable row level security;
alter table nomad_jangter.favorites enable row level security;
alter table nomad_jangter.chat_rooms enable row level security;
alter table nomad_jangter.messages enable row level security;
alter table nomad_jangter.reviews enable row level security;

-- listings: 표는 판매자 본인만(공개 열람은 RPC)
create policy listings_select on nomad_jangter.listings for select to authenticated using ((select auth.uid()) = seller_id);
create policy listings_insert on nomad_jangter.listings for insert to authenticated
  with check ((select auth.uid()) = seller_id and (select nomad_jangter_private.can_trade()));
create policy listings_update on nomad_jangter.listings for update to authenticated
  using ((select auth.uid()) = seller_id) with check ((select auth.uid()) = seller_id and (select nomad_jangter_private.can_trade()));
create policy listings_delete on nomad_jangter.listings for delete to authenticated using ((select auth.uid()) = seller_id);

-- listing_photos: 판매자 본인만(복합 FK 가 글 소유를 강제)
create policy listing_photos_select on nomad_jangter.listing_photos for select to authenticated using ((select auth.uid()) = seller_id);
create policy listing_photos_insert on nomad_jangter.listing_photos for insert to authenticated
  with check ((select auth.uid()) = seller_id and (select nomad_jangter_private.can_trade()));
create policy listing_photos_update on nomad_jangter.listing_photos for update to authenticated
  using ((select auth.uid()) = seller_id) with check ((select auth.uid()) = seller_id and (select nomad_jangter_private.can_trade()));
create policy listing_photos_delete on nomad_jangter.listing_photos for delete to authenticated using ((select auth.uid()) = seller_id);

-- favorites: 본인만, 공개 글만 담을 수 있다
create policy favorites_select on nomad_jangter.favorites for select to authenticated using ((select auth.uid()) = user_id);
create policy favorites_insert on nomad_jangter.favorites for insert to authenticated
  with check ((select auth.uid()) = user_id and (select nomad_jangter_private.can_trade())
              and nomad_jangter_private.listing_visible(listing_id));
create policy favorites_delete on nomad_jangter.favorites for delete to authenticated using ((select auth.uid()) = user_id);

-- chat_rooms: 당사자만 읽기. 생성은 open_chat(정의자) — insert 권한 없음, update·delete 없음
create policy chat_rooms_select on nomad_jangter.chat_rooms for select to authenticated
  using ((select auth.uid()) = buyer_id or (select auth.uid()) = seller_id);

-- messages: 당사자만(방 RLS 로 판정). update·delete 없음
create policy messages_select on nomad_jangter.messages for select to authenticated
  using (exists (select 1 from nomad_jangter.chat_rooms r where r.id = room_id));
create policy messages_insert on nomad_jangter.messages for insert to authenticated
  with check (
    sender_id = (select auth.uid()) and (select nomad_jangter_private.can_trade())
    and exists (select 1 from nomad_jangter.chat_rooms r where r.id = room_id));

-- reviews: 작성자·방 당사자만 읽기(공개 평점은 listing_seller_reviews RPC)
create policy reviews_select on nomad_jangter.reviews for select to authenticated
  using ((select auth.uid()) = writer_id or exists (select 1 from nomad_jangter.chat_rooms r where r.id = room_id));
create policy reviews_insert on nomad_jangter.reviews for insert to authenticated
  with check (writer_id = (select auth.uid()) and (select nomad_jangter_private.can_trade())
              and nomad_jangter_private.room_sold_for_me(room_id));
create policy reviews_update on nomad_jangter.reviews for update to authenticated
  using ((select auth.uid()) = writer_id) with check ((select auth.uid()) = writer_id and (select nomad_jangter_private.can_trade()));
create policy reviews_delete on nomad_jangter.reviews for delete to authenticated using ((select auth.uid()) = writer_id);

-- ===== 공개 RPC (anon·authenticated) — 저장 경로(소유 id 접두)는 돌려주지 않는다. 사진은 id 만, 서명 URL 은 서버가 발급 — 판매자 id 는 돌려주지 않는다 =====
create function nomad_jangter.list_listings(p_dong text default null, p_limit integer default 20, p_offset integer default 0)
returns table (id uuid, title text, price bigint, status text, dong text, created_at timestamptz, thumbnail_photo_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_offset is not null and p_offset not between 0 and 1000 then
    raise exception 'list_listings: offset must be 0..1000' using errcode = '22023';
  end if;
  return query
    select l.id, l.title, l.price, l.status, l.dong, l.created_at,
           (select p.id from nomad_jangter.listing_photos p
             where p.listing_id = l.id order by p."position" nulls last, p.created_at limit 1)
    from nomad_jangter.listings l
    where l.status <> 'hidden' and (p_dong is null or l.dong = p_dong)
    order by l.created_at desc, l.id
    limit least(greatest(coalesce(p_limit, 20), 1), 50) offset coalesce(p_offset, 0);
end;
$$;

-- 숨김·없음은 똑같이 빈 결과
create function nomad_jangter.get_listing(p_listing_id uuid)
returns table (id uuid, title text, price bigint, status text, dong text, created_at timestamptz, photos jsonb)
language sql stable security definer set search_path = '' as $$
  select l.id, l.title, l.price, l.status, l.dong, l.created_at,
         coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id', p.id, 'position', p."position")
                                               order by p."position" nulls last, p.created_at)
                   from nomad_jangter.listing_photos p where p.listing_id = l.id), '[]'::jsonb)
  from nomad_jangter.listings l
  where l.id = p_listing_id and l.status <> 'hidden'
$$;

-- 공개 글 판매자가 받은 후기(구매자가 쓴 것). 작성자·방 id 는 돌려주지 않는다
create function nomad_jangter.listing_seller_reviews(p_listing_id uuid, p_limit integer default 20, p_offset integer default 0)
returns table (score int, comment text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_offset is not null and p_offset not between 0 and 1000 then
    raise exception 'listing_seller_reviews: offset must be 0..1000' using errcode = '22023';
  end if;
  return query
    select rv.score, rv.comment, rv.created_at
    from nomad_jangter.listings l
    join nomad_jangter.chat_rooms r on r.seller_id = l.seller_id
    join nomad_jangter.reviews rv on rv.room_id = r.id and rv.writer_id = r.buyer_id
    where l.id = p_listing_id and l.status <> 'hidden'
    order by rv.created_at desc, rv.id
    limit least(greatest(coalesce(p_limit, 20), 1), 50) offset coalesce(p_offset, 0);
end;
$$;

-- ===== 당사자 RPC (authenticated) =====
-- 채팅 시작: 로그인·잠금(42501) → 글 존재(숨김·없음 P0002) → 판매 완료·본인 글(22023). 같은 글은 같은 방을 돌려준다
create function nomad_jangter.open_chat(p_listing_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_seller uuid;
  v_status text;
  v_id uuid;
begin
  if v_uid is null or not nomad_core.user_has_feature('jangter', 'trade_core') then
    raise exception 'open_chat: not allowed' using errcode = '42501';
  end if;
  select l.seller_id, l.status into v_seller, v_status
    from nomad_jangter.listings l where l.id = p_listing_id and l.status <> 'hidden';
  if not found then
    raise exception 'open_chat: listing not found' using errcode = 'P0002';
  end if;
  if v_status = 'sold' or v_seller = v_uid then
    raise exception 'open_chat: listing not open for chat' using errcode = '22023';
  end if;
  insert into nomad_jangter.chat_rooms (listing_id, buyer_id, seller_id) values (p_listing_id, v_uid, v_seller)
    on conflict (listing_id, buyer_id) do nothing
    returning chat_rooms.id into v_id;
  if v_id is null then
    select r.id into v_id from nomad_jangter.chat_rooms r where r.listing_id = p_listing_id and r.buyer_id = v_uid;
  end if;
  return v_id;
end;
$$;

-- 내 채팅방 목록: 상대방은 표시 이름만(이메일·연락처 없음)
create function nomad_jangter.my_chat_rooms()
returns table (room_id uuid, listing_id uuid, listing_title text, my_side text, counterpart_name text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.id, r.listing_id, l.title,
         case when r.buyer_id = (select auth.uid()) then 'buyer' else 'seller' end,
         pr.display_name, r.created_at
  from nomad_jangter.chat_rooms r
  left join nomad_jangter.listings l on l.id = r.listing_id
  left join nomad_core.profiles pr
    on pr.user_id = case when r.buyer_id = (select auth.uid()) then r.seller_id else r.buyer_id end
  where (select auth.uid()) is not null and (select auth.uid()) in (r.buyer_id, r.seller_id)
  order by r.created_at desc
$$;

-- ===== 권한 =====
revoke all on all tables in schema nomad_jangter from public, anon, authenticated;
revoke all on all functions in schema nomad_jangter, nomad_jangter_private from public, anon, authenticated;
grant all on all tables in schema nomad_jangter to service_role;
-- 사용자 insert 에 id·소유 컬럼 grant 없음(기본값 auth.uid())
grant select, delete on nomad_jangter.listings to authenticated;
grant insert (title, price, status, dong), update (title, price, status, dong, sold_room_id) on nomad_jangter.listings to authenticated;
grant select, delete on nomad_jangter.listing_photos to authenticated;
grant insert (listing_id, storage_path, "position"), update (storage_path, "position") on nomad_jangter.listing_photos to authenticated;
grant select, delete on nomad_jangter.favorites to authenticated;
grant insert (listing_id) on nomad_jangter.favorites to authenticated;
grant select on nomad_jangter.chat_rooms to authenticated;
grant select on nomad_jangter.messages to authenticated;
grant insert (room_id, body, sent_at) on nomad_jangter.messages to authenticated;
grant select, delete on nomad_jangter.reviews to authenticated;
grant insert (room_id, score, comment), update (score, comment) on nomad_jangter.reviews to authenticated;
grant execute on function nomad_jangter_private.can_trade(), nomad_jangter_private.listing_visible(uuid),
  nomad_jangter_private.room_sold_for_me(uuid) to authenticated, service_role;
grant execute on function nomad_jangter.list_listings(text, integer, integer), nomad_jangter.get_listing(uuid),
  nomad_jangter.listing_seller_reviews(uuid, integer, integer) to anon, authenticated, service_role;
grant execute on function nomad_jangter.open_chat(uuid), nomad_jangter.my_chat_rooms() to authenticated, service_role;

commit;
