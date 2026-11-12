-- 동네장터(jangter) · 개인형(두 당사자 마켓플레이스) · 원본: blueprints/user/jangter/schema.draft.sql
-- 되돌림: drop schema nomad_jangter cascade; delete from nomad_core.products where code = 'jangter';
begin;

create schema nomad_jangter;
revoke all on schema nomad_jangter from public, anon, authenticated;
grant usage on schema nomad_jangter to authenticated, service_role;

insert into nomad_core.products (code, name) values ('jangter', '동네장터');

create table nomad_jangter.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  price bigint not null check (price >= 0),
  status text not null default 'on_sale' check (status in ('on_sale','reserved','sold','hidden')),
  dong text,  -- 동네
  created_at timestamptz not null default now()
);

create table nomad_jangter.listing_photos (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references nomad_jangter.listings(id) on delete cascade,
  storage_path text,
  "position" text,
  created_at timestamptz not null default now()
);

create table nomad_jangter.favorites (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  listing_id uuid not null references nomad_jangter.listings(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (user_id, listing_id)
);

create table nomad_jangter.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references nomad_jangter.listings(id) on delete set null,
  buyer_id uuid default auth.uid() references auth.users(id) on delete set null,
  seller_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (listing_id, buyer_id)
);

create table nomad_jangter.messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid references nomad_jangter.chat_rooms(id) on delete cascade,
  sender_id uuid default auth.uid() references auth.users(id) on delete set null,
  body text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create table nomad_jangter.reviews (
  id uuid primary key default gen_random_uuid(),
  room_id uuid references nomad_jangter.chat_rooms(id) on delete cascade,
  writer_id uuid default auth.uid() references auth.users(id) on delete set null,
  score int check (score between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  unique (room_id, writer_id)
);

comment on table nomad_jangter.listings is '판매 글(판매자 소유)';
comment on table nomad_jangter.listing_photos is '판매 글 사진';
comment on table nomad_jangter.favorites is '관심 글(사용자 소유)';
comment on table nomad_jangter.chat_rooms is '구매자-판매자 채팅방(두 당사자)';
comment on table nomad_jangter.messages is '채팅 메시지(수정·삭제 불가)';
comment on table nomad_jangter.reviews is '거래 후기(채팅방당 작성자 1건)';
comment on column nomad_jangter.listings.status is 'on_sale=판매중, reserved=예약중, sold=판매완료, hidden=숨김';

create index listings_seller_created_idx on nomad_jangter.listings (seller_id, created_at desc);
create index listing_photos_listing_idx on nomad_jangter.listing_photos (listing_id);
create index favorites_listing_idx on nomad_jangter.favorites (listing_id);
create index chat_rooms_listing_idx on nomad_jangter.chat_rooms (listing_id);
create index chat_rooms_buyer_idx on nomad_jangter.chat_rooms (buyer_id);
create index chat_rooms_seller_idx on nomad_jangter.chat_rooms (seller_id);
create index messages_room_idx on nomad_jangter.messages (room_id, created_at);
create index messages_sender_idx on nomad_jangter.messages (sender_id);
create index reviews_writer_idx on nomad_jangter.reviews (writer_id);

alter table nomad_jangter.listings enable row level security;
alter table nomad_jangter.listing_photos enable row level security;
alter table nomad_jangter.favorites enable row level security;
alter table nomad_jangter.chat_rooms enable row level security;
alter table nomad_jangter.messages enable row level security;
alter table nomad_jangter.reviews enable row level security;

-- listings
create policy listings_select on nomad_jangter.listings for select to authenticated
  using (status <> 'hidden' or seller_id = (select auth.uid()));
create policy listings_insert on nomad_jangter.listings for insert to authenticated with check ((select auth.uid()) = seller_id);
create policy listings_update on nomad_jangter.listings for update to authenticated using ((select auth.uid()) = seller_id) with check ((select auth.uid()) = seller_id);
create policy listings_delete on nomad_jangter.listings for delete to authenticated using ((select auth.uid()) = seller_id);

-- listing_photos
create policy listing_photos_select on nomad_jangter.listing_photos for select to authenticated
  using (exists (select 1 from nomad_jangter.listings l where l.id = listing_id and (l.status <> 'hidden' or l.seller_id = (select auth.uid()))));
create policy listing_photos_insert on nomad_jangter.listing_photos for insert to authenticated
  with check (exists (select 1 from nomad_jangter.listings l where l.id = listing_id and l.seller_id = (select auth.uid())));
create policy listing_photos_update on nomad_jangter.listing_photos for update to authenticated
  using (exists (select 1 from nomad_jangter.listings l where l.id = listing_id and l.seller_id = (select auth.uid())))
  with check (exists (select 1 from nomad_jangter.listings l where l.id = listing_id and l.seller_id = (select auth.uid())));
create policy listing_photos_delete on nomad_jangter.listing_photos for delete to authenticated
  using (exists (select 1 from nomad_jangter.listings l where l.id = listing_id and l.seller_id = (select auth.uid())));

-- favorites
create policy favorites_select on nomad_jangter.favorites for select to authenticated using ((select auth.uid()) = user_id);
create policy favorites_insert on nomad_jangter.favorites for insert to authenticated with check ((select auth.uid()) = user_id);
create policy favorites_delete on nomad_jangter.favorites for delete to authenticated using ((select auth.uid()) = user_id);

-- chat_rooms (update·delete 없음)
create policy chat_rooms_select on nomad_jangter.chat_rooms for select to authenticated
  using ((select auth.uid()) = buyer_id or (select auth.uid()) = seller_id);
create policy chat_rooms_insert on nomad_jangter.chat_rooms for insert to authenticated
  with check (
    buyer_id = (select auth.uid())
    and seller_id = (select l.seller_id from nomad_jangter.listings l where l.id = listing_id)
    and buyer_id <> seller_id
  );

-- messages (update·delete 없음)
create policy messages_select on nomad_jangter.messages for select to authenticated
  using (exists (select 1 from nomad_jangter.chat_rooms r where r.id = room_id and ((select auth.uid()) = r.buyer_id or (select auth.uid()) = r.seller_id)));
create policy messages_insert on nomad_jangter.messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and exists (select 1 from nomad_jangter.chat_rooms r where r.id = room_id and ((select auth.uid()) = r.buyer_id or (select auth.uid()) = r.seller_id))
  );

-- reviews
create policy reviews_select on nomad_jangter.reviews for select to authenticated using (true);
create policy reviews_insert on nomad_jangter.reviews for insert to authenticated
  with check (
    writer_id = (select auth.uid())
    and exists (
      select 1 from nomad_jangter.chat_rooms r
      join nomad_jangter.listings l on l.id = r.listing_id
      where r.id = room_id
        and ((select auth.uid()) = r.buyer_id or (select auth.uid()) = r.seller_id)
        and l.status = 'sold'
    )
  );
create policy reviews_update on nomad_jangter.reviews for update to authenticated using ((select auth.uid()) = writer_id) with check ((select auth.uid()) = writer_id);
create policy reviews_delete on nomad_jangter.reviews for delete to authenticated using ((select auth.uid()) = writer_id);

revoke all on all tables in schema nomad_jangter from public, anon, authenticated;
grant all on all tables in schema nomad_jangter to service_role;
grant select, insert, delete on nomad_jangter.listings, nomad_jangter.listing_photos, nomad_jangter.favorites, nomad_jangter.reviews to authenticated;
grant select, insert on nomad_jangter.chat_rooms, nomad_jangter.messages to authenticated;
grant update (title, price, status, dong) on nomad_jangter.listings to authenticated;
grant update (storage_path, "position") on nomad_jangter.listing_photos to authenticated;
grant update (score, comment) on nomad_jangter.reviews to authenticated;

commit;
