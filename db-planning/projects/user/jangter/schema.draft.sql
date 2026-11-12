-- jangter · 개인형 (마켓플레이스) · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 개인형(user_id 기준)

create schema if not exists jangter;

create table jangter.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid references core.profiles(user_id),
  title text,
  price numeric,
  status text,  -- 판매중·예약중
  dong text,  -- 동네
  created_at timestamptz not null default now()
);
alter table jangter.listings enable row level security;
create policy listings_select_public on jangter.listings for select using (true);
create policy listings_own on jangter.listings for all using (seller_id = auth.uid()) with check (seller_id = auth.uid());

create table jangter.listing_photos (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references jangter.listings(id) on delete cascade,
  storage_path text,
  "position" text,
  created_at timestamptz not null default now()
);
alter table jangter.listing_photos enable row level security;
create policy listing_photos_select_public on jangter.listing_photos for select using (true);
create policy listing_photos_own_via_listings on jangter.listing_photos for all using (exists (select 1 from jangter.listings p where p.id = listing_id and (p.seller_id = auth.uid())));

create table jangter.favorites (
  user_id uuid references core.profiles(user_id),
  listing_id uuid references jangter.listings(id) on delete cascade,
  created_at timestamptz,
  primary key (user_id, listing_id)
);
alter table jangter.favorites enable row level security;
create policy favorites_own on jangter.favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table jangter.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid references jangter.listings(id) on delete cascade,
  buyer_id uuid references core.profiles(user_id),
  seller_id uuid references core.profiles(user_id),
  created_at timestamptz not null default now()
);
alter table jangter.chat_rooms enable row level security;
create policy chat_rooms_own on jangter.chat_rooms for all using (buyer_id = auth.uid() or seller_id = auth.uid()) with check (buyer_id = auth.uid() or seller_id = auth.uid());

create table jangter.messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid references jangter.chat_rooms(id) on delete cascade,
  sender_id uuid references core.profiles(user_id),
  body text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
alter table jangter.messages enable row level security;
create policy messages_own_via_chat_rooms on jangter.messages for all using (exists (select 1 from jangter.chat_rooms p where p.id = room_id and (p.buyer_id = auth.uid() or p.seller_id = auth.uid())));

create table jangter.reviews (
  id uuid primary key default gen_random_uuid(),
  room_id uuid references jangter.chat_rooms(id) on delete cascade,
  writer_id uuid references core.profiles(user_id),
  score numeric,
  comment text,
  created_at timestamptz not null default now()
);
alter table jangter.reviews enable row level security;
create policy reviews_own on jangter.reviews for all using (writer_id = auth.uid()) with check (writer_id = auth.uid());

