-- jangter org안 검사: 판매 조직 OA(A owner · E editor · V viewer) · 구매 조직 OB(B) · 제3 조직 OC(C) 교차 접근 거부
-- · anon 표 0(공개 RPC 만) · 존재 노출 금지(P0002) · 비멤버 42501 선거부 · 복합 FK 조직 일치 · 쓰기 잠금(공개 열람 유지). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/jangter/run_check.sh org

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

-- 구조: 전 표 RLS, anon 표 권한 0, 사용자 insert 에 id 없음
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_jangter' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_jangter'$$, 6);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_jangter' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_jangter' and grantee = 'authenticated' and column_name in ('id', 'created_by') and privilege_type = 'INSERT'$$, 0);

-- 합성 사용자(가입 트리거가 1인 조직을 만든다). V 는 OA viewer, E 는 OA editor
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'seller@example.test'),
  ('00000000-0000-0000-0000-0000000000b2', 'buyer@example.test'),
  ('00000000-0000-0000-0000-0000000000c3', 'other@example.test'),
  ('00000000-0000-0000-0000-0000000000d4', 'viewer@example.test'),
  ('00000000-0000-0000-0000-0000000000e5', 'editor@example.test'),
  ('00000000-0000-0000-0000-0000000000f6', 'loser@example.test');   -- OD: 같은 글에 채팅만 한 다른 구매 조직
select set_config('jz.oa', (select organization_id::text from nomad_core.memberships where user_id = '00000000-0000-0000-0000-0000000000a1' and role = 'owner'), false);
select set_config('jz.ob', (select organization_id::text from nomad_core.memberships where user_id = '00000000-0000-0000-0000-0000000000b2' and role = 'owner'), false);
select set_config('jz.oc', (select organization_id::text from nomad_core.memberships where user_id = '00000000-0000-0000-0000-0000000000c3' and role = 'owner'), false);
select set_config('jz.od', (select organization_id::text from nomad_core.memberships where user_id = '00000000-0000-0000-0000-0000000000f6' and role = 'owner'), false);
insert into nomad_core.memberships (organization_id, user_id, role) values
  (current_setting('jz.oa')::uuid, '00000000-0000-0000-0000-0000000000d4', 'viewer'),
  (current_setting('jz.oa')::uuid, '00000000-0000-0000-0000-0000000000e5', 'editor');

-- ===== A(OA owner) =====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_jangter.listings (organization_id, title, price, dong) values (current_setting('jz.oa')::uuid, 'A자전거', 50000, '역삼동');
insert into nomad_jangter.listings (organization_id, title, price, dong, status) values (current_setting('jz.oa')::uuid, 'A숨김', 1000, '역삼동', 'hidden');
select set_config('jz.l1', (select id::text from nomad_jangter.listings where title = 'A자전거'), false);
select set_config('jz.l2', (select id::text from nomad_jangter.listings where title = 'A숨김'), false);
insert into nomad_jangter.listing_photos (organization_id, listing_id, storage_path, "position")
  values (current_setting('jz.oa')::uuid, current_setting('jz.l1')::uuid, current_setting('jz.oa') || '/' || current_setting('jz.l1') || '/1.jpg', '1');
select zz_check.fails_with(format($q$insert into nomad_jangter.listing_photos (organization_id, listing_id, storage_path) values (%L, %L, %L)$q$,
  current_setting('jz.oa'), current_setting('jz.l1'), current_setting('jz.ob') || '/' || current_setting('jz.l1') || '/x.jpg'), '23514');
-- 남의 조직으로 글 등록 금지, 조직 이동 금지(update grant 없음), id 위조 금지
select zz_check.fails_with(format($q$insert into nomad_jangter.listings (organization_id, title, price) values (%L, 'x', 1)$q$, current_setting('jz.ob')), '42501');
select zz_check.fails_with(format($q$update nomad_jangter.listings set organization_id = %L$q$, current_setting('jz.ob')), '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.listings (id, organization_id, title, price) values (gen_random_uuid(), %L, 'x', 1)$q$, current_setting('jz.oa')), '42501');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L, %L)', current_setting('jz.l1'), current_setting('jz.oa')), '22023');

-- ===== V(OA viewer): 읽기만 =====
select zz_check.login('00000000-0000-0000-0000-0000000000d4');
select zz_check.expect('select count(*) from nomad_jangter.listings', 2);
select zz_check.fails_with(format($q$insert into nomad_jangter.listings (organization_id, title, price) values (%L, 'x', 1)$q$, current_setting('jz.oa')), '42501');
select zz_check.expect($q$with x as (update nomad_jangter.listings set price = 1 returning 1) select count(*) from x$q$, 0);

-- ===== E(OA editor): 쓰기 가능, 글 삭제는 owner·admin 만 =====
select zz_check.login('00000000-0000-0000-0000-0000000000e5');
select zz_check.expect($q$with x as (update nomad_jangter.listings set price = 45000 where title = 'A자전거' returning 1) select count(*) from x$q$, 1);
select zz_check.expect($q$with x as (delete from nomad_jangter.listings returning 1) select count(*) from x$q$, 0);

-- ===== B(OB owner, 구매 조직) =====
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.expect('select count(*) from nomad_jangter.listings', 0);
select zz_check.expect('select count(*) from nomad_jangter.listing_photos', 0);
select zz_check.expect('select count(*) from nomad_jangter.list_listings()', 1);
select zz_check.expect($$select count(*) from nomad_jangter.list_listings('역삼동')$$, 1);
select zz_check.expect(format('select count(*) from nomad_jangter.get_listing(%L)', current_setting('jz.l2')), 0);
select zz_check.expect(format($q$select count(*) from nomad_jangter.get_listing(%L) where jsonb_array_length(photos) = 1$q$, current_setting('jz.l1')), 1);
-- 비멤버 조직 명의는 존재 확인 전에 42501, 숨김·없음은 P0002
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L, %L)', current_setting('jz.l1'), current_setting('jz.oc')), '42501');
select zz_check.fails_with(format('select nomad_jangter.open_chat(gen_random_uuid(), %L)', current_setting('jz.oc')), '42501');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L, %L)', current_setting('jz.l2'), current_setting('jz.ob')), 'P0002');
select zz_check.fails_with(format('select nomad_jangter.open_chat(gen_random_uuid(), %L)', current_setting('jz.ob')), 'P0002');
select set_config('jz.room', nomad_jangter.open_chat(current_setting('jz.l1')::uuid, current_setting('jz.ob')::uuid)::text, false);
select zz_check.expect(format('select (nomad_jangter.open_chat(%L, %L) = %L::uuid)::int', current_setting('jz.l1'), current_setting('jz.ob'), current_setting('jz.room')), 1);
insert into nomad_jangter.messages (room_id, organization_id, body) values (current_setting('jz.room')::uuid, current_setting('jz.ob')::uuid, '구매 가능할까요?');
-- 남의 조직 명의·발신자 위조 금지
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, organization_id, body) values (%L, %L, 'x')$q$, current_setting('jz.room'), current_setting('jz.oa')), '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, organization_id, body, sender_id) values (%L, %L, 'x', '00000000-0000-0000-0000-0000000000a1')$q$, current_setting('jz.room'), current_setting('jz.ob')), '42501');
select zz_check.fails_with('update nomad_jangter.messages set body = $$x$$', '42501');
select zz_check.fails_with('delete from nomad_jangter.messages', '42501');
select zz_check.fails_with($q$insert into nomad_jangter.chat_rooms (listing_id) values (null)$q$, '42501');
-- 관심: 공개 글만, 남의 조직 명의 금지
insert into nomad_jangter.favorites (organization_id, listing_id) values (current_setting('jz.ob')::uuid, current_setting('jz.l1')::uuid);
select zz_check.fails_with(format('insert into nomad_jangter.favorites (organization_id, listing_id) values (%L, %L)', current_setting('jz.ob'), current_setting('jz.l2')), '42501');
select zz_check.fails_with(format('insert into nomad_jangter.favorites (organization_id, listing_id) values (%L, %L)', current_setting('jz.oa'), current_setting('jz.l1')), '42501');
-- OA 글 수정·삭제 불가, 내 조직 명의로 OA 글 사진 추가는 복합 FK 로 거부
select zz_check.expect($q$with x as (update nomad_jangter.listings set price = 1 returning 1) select count(*) from x$q$, 0);
select zz_check.expect($q$with x as (delete from nomad_jangter.listings returning 1) select count(*) from x$q$, 0);
select zz_check.fails_with(format($q$insert into nomad_jangter.listing_photos (organization_id, listing_id, storage_path) values (%L, %L, %L)$q$,
  current_setting('jz.ob'), current_setting('jz.l1'), current_setting('jz.ob') || '/' || current_setting('jz.l1') || '/x.jpg'), '23503');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, writer_organization_id, score) values (%L, %L, 5)$q$, current_setting('jz.room'), current_setting('jz.ob')), '42501');
select zz_check.expect($q$select count(*) from nomad_jangter.my_chat_rooms(current_setting('jz.ob')::uuid) where my_side = 'buyer' and counterpart_name = 'seller'$q$, 1);
select zz_check.fails_with('select nomad_jangter.my_chat_rooms(current_setting($$jz.oa$$)::uuid)', '42501');
select zz_check.fails_with('select seller_organization_id from nomad_jangter.list_listings()', '42703');
-- 공개 RPC 는 저장 경로(조직 id 접두)를 돌려주지 않는다: 사진은 id 만
select zz_check.fails_with('select thumbnail_path from nomad_jangter.list_listings()', '42703');
select zz_check.expect('select count(*) from nomad_jangter.list_listings() where thumbnail_photo_id is not null', 1);
select zz_check.expect(format($q$select count(*) from nomad_jangter.get_listing(%L) where photos::text like %L or photos::text like '%%/%%'$q$, current_setting('jz.l1'), '%' || current_setting('jz.oa') || '%'), 0);

-- ===== V(OA viewer): 판매 쪽 방·메시지는 보이지만 보낼 수 없다 =====
select zz_check.login('00000000-0000-0000-0000-0000000000d4');
select zz_check.expect('select count(*) from nomad_jangter.chat_rooms', 1);
select zz_check.expect('select count(*) from nomad_jangter.messages', 1);
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, organization_id, body) values (%L, %L, 'x')$q$, current_setting('jz.room'), current_setting('jz.oa')), '42501');

-- ===== A: 다른 글 L3 / F(OD): L1·L3 에 채팅(구매 방이 아닌 방) =====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_jangter.listings (organization_id, title, price, dong) values (current_setting('jz.oa')::uuid, 'A의자', 20000, '역삼동');
select set_config('jz.l3', (select id::text from nomad_jangter.listings where title = 'A의자'), false);
select zz_check.login('00000000-0000-0000-0000-0000000000f6');
select set_config('jz.room_d', nomad_jangter.open_chat(current_setting('jz.l1')::uuid, current_setting('jz.od')::uuid)::text, false);
select set_config('jz.room3', nomad_jangter.open_chat(current_setting('jz.l3')::uuid, current_setting('jz.od')::uuid)::text, false);

-- ===== A: 답장, 판매 완료, 후기 =====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_jangter.favorites', 0);           -- OB 의 관심은 OB 만
insert into nomad_jangter.messages (room_id, organization_id, body) values (current_setting('jz.room')::uuid, current_setting('jz.oa')::uuid, '네 가능합니다');
-- 판매 완료는 구매 방 기록 필수, 그 글의 방이어야 한다
select zz_check.fails_with(format($q$update nomad_jangter.listings set status = 'sold' where id = %L$q$, current_setting('jz.l1')), '23514');
select zz_check.fails_with(format($q$update nomad_jangter.listings set status = 'sold', sold_room_id = %L where id = %L$q$, current_setting('jz.room3'), current_setting('jz.l1')), '23503');
update nomad_jangter.listings set status = 'sold', sold_room_id = current_setting('jz.room')::uuid where id = current_setting('jz.l1')::uuid;
insert into nomad_jangter.reviews (room_id, writer_organization_id, score, comment) values (current_setting('jz.room')::uuid, current_setting('jz.oa')::uuid, 5, '친절한 구매자');

-- ===== B: 후기 =====
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L, %L)', current_setting('jz.l1'), current_setting('jz.ob')), '22023');
insert into nomad_jangter.reviews (room_id, writer_organization_id, score, comment) values (current_setting('jz.room')::uuid, current_setting('jz.ob')::uuid, 4, '좋은 거래');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, writer_organization_id, score) values (%L, %L, 3)$q$, current_setting('jz.room'), current_setting('jz.ob')), '23505');
select zz_check.expect('select count(*) from nomad_jangter.reviews', 2);
select zz_check.expect($q$with x as (update nomad_jangter.reviews set score = 1 returning 1) select count(*) from x$q$, 1);  -- 내 조직 후기만

-- ===== F(OD): 채팅만 한 구매 조직은 판매 완료 글에 후기 불가 =====
select zz_check.login('00000000-0000-0000-0000-0000000000f6');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, writer_organization_id, score) values (%L, %L, 1)$q$, current_setting('jz.room_d'), current_setting('jz.od')), '42501');

-- ===== C(OC owner, 제3자) =====
select zz_check.login('00000000-0000-0000-0000-0000000000c3');
select zz_check.expect('select count(*) from nomad_jangter.listings', 0);
select zz_check.expect('select count(*) from nomad_jangter.chat_rooms', 0);
select zz_check.expect('select count(*) from nomad_jangter.messages', 0);
select zz_check.expect('select count(*) from nomad_jangter.reviews', 0);
select zz_check.expect('select count(*) from nomad_jangter.favorites', 0);
select zz_check.expect($q$select count(*) from nomad_jangter.my_chat_rooms(current_setting('jz.oc')::uuid)$q$, 0);
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, organization_id, body) values (%L, %L, 'x')$q$, current_setting('jz.room'), current_setting('jz.oc')), '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, writer_organization_id, score) values (%L, %L, 1)$q$, current_setting('jz.room'), current_setting('jz.oc')), '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.reviews (room_id, writer_organization_id, score) values (%L, %L, 1)$q$, current_setting('jz.room'), current_setting('jz.ob')), '42501');
select zz_check.expect(format('select nomad_jangter_private.room_sold_for(%L, %L)::int', current_setting('jz.room'), current_setting('jz.ob')), 0);  -- 비멤버 탐색 금지
select zz_check.expect($q$with x as (update nomad_jangter.reviews set score = 1 returning 1) select count(*) from x$q$, 0);

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
select zz_check.expect(format('select count(*) from nomad_jangter.listing_seller_reviews(%L)', current_setting('jz.l1')), 1);  -- 구매 조직이 쓴 것만
select zz_check.expect(format('select count(*) from nomad_jangter.listing_seller_reviews(%L)', current_setting('jz.l2')), 0);
select zz_check.fails_with('select * from nomad_jangter.list_listings(null, 20, 1001)', '22023');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L, %L)', current_setting('jz.l1'), current_setting('jz.ob')), '42501');
select zz_check.fails_with(format('select * from nomad_jangter.my_chat_rooms(%L)', current_setting('jz.ob')), '42501');
select zz_check.fails_with(format('select nomad_jangter_private.can_write(%L)', current_setting('jz.ob')), '42501');

-- ===== 쓰기 잠금(trade_core 이용권 없음): 쓰기 거부, 공개 열람·조직 열람·삭제 유지 =====
reset role;
delete from nomad_core.plan_features where product_code = 'jangter' and feature_code = 'trade_core';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with(format($q$insert into nomad_jangter.listings (organization_id, title, price) values (%L, '잠금', 1)$q$, current_setting('jz.oa')), '42501');
select zz_check.fails_with('update nomad_jangter.listings set price = 2', '42501');
select zz_check.fails_with(format($q$insert into nomad_jangter.messages (room_id, organization_id, body) values (%L, %L, 'x')$q$, current_setting('jz.room'), current_setting('jz.oa')), '42501');
select zz_check.expect('select count(*) from nomad_jangter.listings', 3);
select zz_check.login('00000000-0000-0000-0000-0000000000c3');
select zz_check.fails_with(format('select nomad_jangter.open_chat(%L, %L)', current_setting('jz.l1'), current_setting('jz.oc')), '42501');
select zz_check.as_anon();
select zz_check.expect('select count(*) from nomad_jangter.list_listings()', 2);
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.expect($q$with x as (delete from nomad_jangter.favorites returning 1) select count(*) from x$q$, 1);

-- 비활성 판매 조직 = 없음: 공개 후기·목록·상세 0
reset role;
update nomad_core.organizations set active = false where id = current_setting('jz.oa')::uuid;
select zz_check.as_anon();
select zz_check.expect(format('select count(*) from nomad_jangter.listing_seller_reviews(%L)', current_setting('jz.l1')), 0);
select zz_check.expect('select count(*) from nomad_jangter.list_listings()', 0);
select zz_check.expect(format('select count(*) from nomad_jangter.get_listing(%L)', current_setting('jz.l3')), 0);
reset role;
update nomad_core.organizations set active = true where id = current_setting('jz.oa')::uuid;

-- 판매 완료 글 삭제(owner): 방은 남고 listing_id 만 비운다
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect(format($q$with x as (delete from nomad_jangter.listings where id = %L returning 1) select count(*) from x$q$, current_setting('jz.l1')), 1);
select zz_check.expect(format($q$select count(*) from nomad_jangter.chat_rooms where id = %L and listing_id is null$q$, current_setting('jz.room')), 1);

reset role;
select 'jangter org checks passed' as result;
