-- jangter user안 검사: 판매자 A · 구매자 B · 제3자 C 교차 접근 거부 · anon 표 0(공개 RPC 만) · 존재 노출 금지(P0002)
-- · 공개 RPC 컬럼 최소 · offset 상한 · 쓰기 잠금(공개 열람 유지). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/jangter/run_check.sh user

create schema zz_check;
grant usage on schema zz_check to anon, authenticated, service_role;
create function zz_check.fails_with(q text, code text) returns void language plpgsql as $$
declare got text;
begin
  begin execute q; got := null; exception when others then got := sqlstate; end;
  if got is null then raise exception 'NOT DENIED: %', q; end if;
  if got <> code then raise exception 'wrong error for %: got [%], want [%]', q, got, code; end if;
end $$;
create function zz_check.expect(q text, want bigint) returns void language plpgsql as $$
declare r bigint; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
create function zz_check.login(u text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function zz_check.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- 구조: 전 표 RLS, anon 표 권한 0
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_jangter' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_jangter'$$, 6);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_jangter' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_jangter' and grantee = 'authenticated' and column_name = 'id' and privilege_type = 'INSERT'$$, 0);

-- 합성 사용자(가입 트리거가 개인 조직·프로필을 만든다)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'seller@example.test'),
  ('00000000-0000-0000-0000-0000000000b2', 'buyer@example.test'),
  ('00000000-0000-0000-0000-0000000000c3', 'other@example.test'),
  ('00000000-0000-0000-0000-0000000000d4', 'loser@example.test');   -- 같은 글에 채팅만 한 다른 구매자

-- ===== A(판매자) =====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_jangter.listings (title, price, dong) values ('A자전거', 50000, '역삼동');
insert into nomad_jangter.listings (title, price, dong, status) values ('A숨김', 1000, '역삼동', 'hidden');
select set_config('jz.l1', (select id::text from nomad_jangter.listings where title = 'A자전거'), false);
select set_config('jz.l2', (select id::text from nomad_jangter.listings where title = 'A숨김'), false);
insert into nomad_jangter.listing_photos (listing_id, storage_path, "position")
  values (current_setting('jz.l1')::uuid, '00000000-0000-0000-0000-0000000000a1/' || current_setting('jz.l1') || '/1.jpg', '1');
-- 남의 경로·상위 경로 금지
select zz_check.fails_with(format($q$insert into nomad_jangter.listing_photos (listing_id, storage_path) values (%L, %L)$q$,
  current_setting('jz.l1'), '00000000-0000-0000-0000-0000000000b2/' || current_setting('jz.l1') || '/x.jpg'), '23514');
select zz_check.fails_with(format($q$insert into nomad_jangter.listing_photos (listing_id, storage_path) values (%L, %L)$q$,
  current_setting('jz.l1'), '00000000-0000-0000-0000-0000000000a1/' || current_setting('jz.l1') || '/../x.jpg'), '23514');
-- 소유·id 위조 금지(컬럼 grant 없음), 금액 음수 금지
select zz_check.fails_with($q$insert into nomad_jangter.listings (seller_id, title, price) values ('00000000-0000-0000-0000-0000000000b2', 'x', 1)$q$, '42501');
select zz_check.fails_with($q$insert into nomad_jangter.listings (id, title, price) values (gen_random_uuid(), 'x', 1)$q$, '42501');
select zz_check.fails_with($q$insert into nomad_jangter.listings (title, price) values ('x', -1)$q$, '23514');
select zz_check.fails_with($q$update nomad_jangter.listings set seller_id = '00000000-0000-0000-0000-0000000000b2'$q$, '42501');
select zz_check.expect('select count(*) from nomad_jangter.listings', 2);
-- 본인 글로 채팅 금지
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L)', current_setting('jz.l1')), '22023');

-- ===== B(구매자) =====
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.expect('select count(*) from nomad_jangter.listings', 0);          -- 표는 본인 것만
select zz_check.expect('select count(*) from nomad_jangter.listing_photos', 0);
select zz_check.expect('select count(*) from nomad_jangter.list_listings()', 1);    -- 숨김 제외
select zz_check.expect($$select count(*) from nomad_jangter.list_listings('역삼동')$$, 1);
select zz_check.expect($$select count(*) from nomad_jangter.list_listings('삼성동')$$, 0);
select zz_check.expect(format('select count(*) from nomad_jangter.get_listing(%L)', current_setting('jz.l2')), 0);
select zz_check.expect(format($q$select count(*) from nomad_jangter.get_listing(%L) where jsonb_array_length(photos) = 1$q$, current_setting('jz.l1')), 1);
-- 숨김·없음은 같은 오류(P0002)
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L)', current_setting('jz.l2')), 'P0002');
select zz_check.fails_with('select nomad_jangter.open_chat(gen_random_uuid())', 'P0002');
select set_config('jz.room', nomad_jangter.open_chat(current_setting('jz.l1')::uuid)::text, false);
select zz_check.expect(format('select (nomad_jangter.open_chat(%L) = %L::uuid)::int', current_setting('jz.l1'), current_setting('jz.room')), 1);
insert into nomad_jangter.messages (room_id, body) values (current_setting('jz.room')::uuid, '안녕하세요, 구매 가능할까요?');
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, body, sender_id) values (%L, 'x', '00000000-0000-0000-0000-0000000000a1')$q$, current_setting('jz.room')), '42501');
select zz_check.fails_with('update nomad_jangter.messages set body = $$x$$', '42501');
select zz_check.fails_with('delete from nomad_jangter.messages', '42501');
select zz_check.fails_with($q$insert into nomad_jangter.chat_rooms (listing_id, buyer_id, seller_id) values (null, null, null)$q$, '42501');
-- 관심: 공개 글만(숨김·없음 같은 거부)
insert into nomad_jangter.favorites (listing_id) values (current_setting('jz.l1')::uuid);
select zz_check.fails_with(format('insert into nomad_jangter.favorites (listing_id) values (%L)', current_setting('jz.l2')), '42501');
select zz_check.fails_with('insert into nomad_jangter.favorites (listing_id) values (gen_random_uuid())', '42501');
-- A 글 수정·삭제·사진 추가 불가
select zz_check.expect($q$with x as (update nomad_jangter.listings set price = 1 returning 1) select count(*) from x$q$, 0);
select zz_check.expect($q$with x as (delete from nomad_jangter.listings returning 1) select count(*) from x$q$, 0);
select zz_check.fails_with(format($q$insert into nomad_jangter.listing_photos (listing_id, storage_path) values (%L, %L)$q$,
  current_setting('jz.l1'), '00000000-0000-0000-0000-0000000000b2/' || current_setting('jz.l1') || '/x.jpg'), '23503');
-- 판매 완료 전 후기 불가
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, score) values (%L, 5)$q$, current_setting('jz.room')), '42501');
-- 상대방 노출은 표시 이름만
select zz_check.expect($q$select count(*) from nomad_jangter.my_chat_rooms() where my_side = 'buyer' and counterpart_name = 'seller'$q$, 1);
select zz_check.fails_with('select seller_id from nomad_jangter.list_listings()', '42703');
-- 공개 RPC 는 저장 경로(소유 id 접두)를 돌려주지 않는다: 사진은 id 만
select zz_check.fails_with('select thumbnail_path from nomad_jangter.list_listings()', '42703');
select zz_check.expect('select count(*) from nomad_jangter.list_listings() where thumbnail_photo_id is not null', 1);
select zz_check.expect(format($q$select count(*) from nomad_jangter.get_listing(%L) where photos::text like '%%0000000000a1%%' or photos::text like '%%/%%'$q$, current_setting('jz.l1')), 0);

-- ===== A: 다른 글 L3 / D: L1·L3 에 채팅(구매 방이 아닌 방) =====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_jangter.listings (title, price, dong) values ('A의자', 20000, '역삼동');
select set_config('jz.l3', (select id::text from nomad_jangter.listings where title = 'A의자'), false);
select zz_check.login('00000000-0000-0000-0000-0000000000d4');
select set_config('jz.room_d', nomad_jangter.open_chat(current_setting('jz.l1')::uuid)::text, false);
select set_config('jz.room3', nomad_jangter.open_chat(current_setting('jz.l3')::uuid)::text, false);

-- ===== A: 방·메시지 보임, 판매 완료 처리 =====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_jangter.chat_rooms', 3);
select zz_check.expect('select count(*) from nomad_jangter.messages', 1);
select zz_check.expect('select count(*) from nomad_jangter.favorites', 0);           -- B 의 관심은 B 만
insert into nomad_jangter.messages (room_id, body) values (current_setting('jz.room')::uuid, '네 가능합니다');
-- 판매 완료는 구매 방 기록 필수, 그 글의 방이어야 한다
select zz_check.fails_with(format($q$update nomad_jangter.listings set status = 'sold' where id = %L$q$, current_setting('jz.l1')), '23514');
select zz_check.fails_with(format($q$update nomad_jangter.listings set status = 'sold', sold_room_id = %L where id = %L$q$, current_setting('jz.room3'), current_setting('jz.l1')), '23503');
update nomad_jangter.listings set status = 'sold', sold_room_id = current_setting('jz.room')::uuid where id = current_setting('jz.l1')::uuid;
insert into nomad_jangter.reviews (room_id, score, comment) values (current_setting('jz.room')::uuid, 5, '친절한 구매자');

-- ===== B: 후기, 판매 완료 글 채팅 불가 =====
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L)', current_setting('jz.l1')), '22023');
insert into nomad_jangter.reviews (room_id, score, comment) values (current_setting('jz.room')::uuid, 4, '좋은 거래');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, score) values (%L, 3)$q$, current_setting('jz.room')), '23505');
select zz_check.expect('select count(*) from nomad_jangter.reviews', 2);
select zz_check.expect($q$with x as (update nomad_jangter.reviews set score = 1 returning 1) select count(*) from x$q$, 1);  -- 본인 후기만

-- ===== D: 채팅만 한 구매자는 판매 완료 글에 후기 불가 =====
select zz_check.login('00000000-0000-0000-0000-0000000000d4');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, score) values (%L, 1)$q$, current_setting('jz.room_d')), '42501');

-- ===== C(제3자): 방·메시지·후기·관심 0, 끼어들기 거부 =====
select zz_check.login('00000000-0000-0000-0000-0000000000c3');
select zz_check.expect('select count(*) from nomad_jangter.chat_rooms', 0);
select zz_check.expect('select count(*) from nomad_jangter.messages', 0);
select zz_check.expect('select count(*) from nomad_jangter.reviews', 0);
select zz_check.expect('select count(*) from nomad_jangter.favorites', 0);
select zz_check.expect('select count(*) from nomad_jangter.my_chat_rooms()', 0);
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, body) values (%L, 'x')$q$, current_setting('jz.room')), '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, score) values (%L, 1)$q$, current_setting('jz.room')), '42501');
select zz_check.expect($q$with x as (update nomad_jangter.reviews set score = 1 returning 1) select count(*) from x$q$, 0);
select zz_check.expect(format('select nomad_jangter_private.room_sold_for_me(%L)::int', current_setting('jz.room')), 0);

-- ===== anon: 표 0, 공개 RPC 만 =====
select zz_check.as_anon();
select zz_check.fails_with('select 1 from nomad_jangter.listings', '42501');
select zz_check.fails_with('select 1 from nomad_jangter.listing_photos', '42501');
select zz_check.fails_with('select 1 from nomad_jangter.favorites', '42501');
select zz_check.fails_with('select 1 from nomad_jangter.chat_rooms', '42501');
select zz_check.fails_with('select 1 from nomad_jangter.messages', '42501');
select zz_check.fails_with('select 1 from nomad_jangter.reviews', '42501');
select zz_check.expect('select count(*) from nomad_jangter.list_listings()', 2);
select zz_check.expect(format('select count(*) from nomad_jangter.get_listing(%L)', current_setting('jz.l1')), 1);
select zz_check.expect(format('select count(*) from nomad_jangter.listing_seller_reviews(%L)', current_setting('jz.l1')), 1);  -- 구매자가 쓴 것만
select zz_check.expect(format('select count(*) from nomad_jangter.listing_seller_reviews(%L)', current_setting('jz.l2')), 0);  -- 숨김
select zz_check.fails_with('select * from nomad_jangter.list_listings(null, 20, 1001)', '22023');
select zz_check.expect('select count(*) from nomad_jangter.list_listings(null, 1000, 0)', 2);  -- limit 은 50 으로 자름
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L)', current_setting('jz.l1')), '42501');
select zz_check.fails_with('select * from nomad_jangter.my_chat_rooms()', '42501');
select zz_check.fails_with('select nomad_jangter_private.can_trade()', '42501');

-- ===== 쓰기 잠금(trade_core 이용권 없음): 쓰기 거부, 공개 열람·본인 열람·삭제 유지 =====
reset role;
delete from nomad_core.plan_features where product_code = 'jangter' and feature_code = 'trade_core';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($q$insert into nomad_jangter.listings (title, price) values ('잠금', 1)$q$, '42501');
select zz_check.fails_with($q$update nomad_jangter.listings set price = 2$q$, '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, body) values (%L, 'x')$q$, current_setting('jz.room')), '42501');
select zz_check.expect('select count(*) from nomad_jangter.listings', 3);
select zz_check.login('00000000-0000-0000-0000-0000000000c3');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L)', current_setting('jz.l1')), '42501');
select zz_check.as_anon();
select zz_check.expect('select count(*) from nomad_jangter.list_listings()', 2);
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.expect($q$with x as (delete from nomad_jangter.favorites returning 1) select count(*) from x$q$, 1);

-- 판매 완료 글 삭제: 방은 남고 listing_id 만 비운다
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect(format($q$with x as (delete from nomad_jangter.listings where id = %L returning 1) select count(*) from x$q$, current_setting('jz.l1')), 1);
select zz_check.expect(format($q$select count(*) from nomad_jangter.chat_rooms where id = %L and listing_id is null$q$, current_setting('jz.room')), 1);

reset role;
select 'jangter user checks passed' as result;
