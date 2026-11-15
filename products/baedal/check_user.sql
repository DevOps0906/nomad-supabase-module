-- baedal user안 검사: 점주 2·주문자 2·배달원 2 교차 접근 거부 · anon 0 · 개인정보(주소·전화) 당사자만 · 금액 서버 계산
-- · 주문·결제 멱등 · 상태 전이 · 후기 · 폐점 · 잠김(점주 개인 조직 비활성). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/baedal/run_check.sh user

create schema zz_check;
grant usage on schema zz_check to anon, authenticated, service_role;
create function zz_check.fails_with(q text, msg text) returns void language plpgsql as $$
declare got text;
begin
  begin execute q; got := null; exception when others then got := sqlstate || ' ' || sqlerrm; end;
  if got is null then raise exception 'NOT DENIED: %', q; end if;
  if got not like '%' || msg || '%' then raise exception 'wrong error for %: got [%], want [%]', q, got, msg; end if;
end $$;
create function zz_check.expect(q text, want bigint) returns void language plpgsql as $$
declare r bigint; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
create function zz_check.login(u text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function zz_check.as_role(r text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', r)::text, true);
  perform set_config('role', r, true);
end $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;
create table zz_check.ids (k text primary key, v uuid);
grant all on zz_check.ids to anon, authenticated, service_role;

-- 합성 사용자: 점주 o1(a1)·o2(a2), 주문자 b1(b1)·b2(b2), 배달원 r1(c1)·r2(c2). 가입 트리거가 개인 조직을 만든다(구독 없음 = C, order_core 열림).
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'o1@example.test', now()), ('00000000-0000-0000-0000-0000000000a2', 'o2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@example.test', now()), ('00000000-0000-0000-0000-0000000000b2', 'b2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000c1', 'r1@example.test', now()), ('00000000-0000-0000-0000-0000000000c2', 'r2@example.test', now());

-- ==== 1. 점주: 가게·메뉴 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_baedal.stores (name, category) values ('o1 분식', '분식');
insert into zz_check.ids select 's1', id from nomad_baedal.stores where name = 'o1 분식';
insert into nomad_baedal.menus (store_id, name, price) values ((select v from zz_check.ids where k = 's1'), '떡볶이', 4500), ((select v from zz_check.ids where k = 's1'), '김밥', 3000);
insert into zz_check.ids select 'm_ddeok', id from nomad_baedal.menus where name = '떡볶이';
insert into zz_check.ids select 'm_kimbap', id from nomad_baedal.menus where name = '김밥';
select zz_check.fails_with($$insert into nomad_baedal.stores (id, name) values (gen_random_uuid(), 'x')$$, '42501');           -- id grant 없음
select zz_check.fails_with($$insert into nomad_baedal.stores (owner_id, name) values ('00000000-0000-0000-0000-0000000000a2', 'x')$$, '42501');
select zz_check.fails_with($$insert into nomad_baedal.orders (store_id, total, idempotency_key) values ((select v from zz_check.ids where k = 's1'), 0, 'direct-0001')$$, '42501');
select zz_check.fails_with($$update nomad_baedal.menus set store_id = store_id$$, '42501');

select zz_check.login('00000000-0000-0000-0000-0000000000a2');
insert into nomad_baedal.stores (name) values ('o2 치킨');
insert into zz_check.ids select 's2', id from nomad_baedal.stores where name = 'o2 치킨';
insert into nomad_baedal.menus (store_id, name, price) values ((select v from zz_check.ids where k = 's2'), '치킨', 20000);
insert into zz_check.ids select 'm_chicken', id from nomad_baedal.menus where name = '치킨';
-- o2는 o1 가게·메뉴를 고칠 수 없다(0행 또는 거부)
select zz_check.fails_with($$insert into nomad_baedal.menus (store_id, name, price) values ((select v from zz_check.ids where k = 's1'), '침입', 1)$$, '42501');
update nomad_baedal.stores set name = '탈취' where id = (select v from zz_check.ids where k = 's1');
update nomad_baedal.menus set price = 1 where id = (select v from zz_check.ids where k = 'm_ddeok');
delete from nomad_baedal.menus where id = (select v from zz_check.ids where k = 'm_ddeok');
select zz_check.fails_with($$select nomad_baedal.close_store((select v from zz_check.ids where k = 's1'))$$, 'P0002');
select zz_check.expect($$select count(*) from nomad_baedal.stores$$, 2);   -- 영업 중 가게는 모두 열람

-- ==== 2. 주문자 b1: 주문(합계 서버 계산·멱등) ====
select zz_check.login('00000000-0000-0000-0000-0000000000b1');
select zz_check.expect($$select count(*) from nomad_baedal.menus$$, 3);
insert into zz_check.ids select 'ord1', nomad_baedal.place_order((select v from zz_check.ids where k = 's1'),
  jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_ddeok'), 'qty', 2),
                    jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_kimbap'), 'qty', 1)),
  '서울시 합성구 1-1', '010-1111-2222', 'b1-order-0001');
select zz_check.expect($$select total from nomad_baedal.orders where id = (select v from zz_check.ids where k = 'ord1')$$, 12000);
select zz_check.expect($$select count(*) from nomad_baedal.order_items where order_id = (select v from zz_check.ids where k = 'ord1')$$, 2);
-- 같은 멱등 키 재요청 = 같은 주문, 새 행 없음
select zz_check.expect($$select count(*) from (select 1 where nomad_baedal.place_order((select v from zz_check.ids where k = 's1'), '[]'::jsonb, 'x', '01000000000', 'b1-order-0001') = (select v from zz_check.ids where k = 'ord1')) t$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.orders$$, 1);
-- 다른 가게 메뉴 섞기·수량 범위·키 누락·없는 가게
select zz_check.fails_with($$select nomad_baedal.place_order((select v from zz_check.ids where k = 's1'), jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_chicken'), 'qty', 1)), 'a', '01012345678', 'b1-order-0002')$$, '22023');
select zz_check.fails_with($$select nomad_baedal.place_order((select v from zz_check.ids where k = 's1'), jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_ddeok'), 'qty', 0)), 'a', '01012345678', 'b1-order-0003')$$, '22023');
select zz_check.fails_with($$select nomad_baedal.place_order((select v from zz_check.ids where k = 's1'), jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_ddeok'), 'qty', 1)), 'a', '01012345678', null)$$, '22023');
select zz_check.fails_with($$select nomad_baedal.place_order(gen_random_uuid(), '[]'::jsonb, 'a', '01012345678', 'b1-order-0004')$$, 'P0002');
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts$$, 1);
-- 미결제 접수 금지는 점주 단계에서 확인. 주문자는 접수로 바꿀 수 없다
select zz_check.fails_with($$select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'accepted')$$, '22023');

-- b2: 같은 키를 써도 별개 주문, b1 주문·연락처는 0
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
insert into zz_check.ids select 'ord2', nomad_baedal.place_order((select v from zz_check.ids where k = 's2'),
  jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_chicken'), 'qty', 1)),
  '서울시 합성구 2-2', '010-3333-4444', 'b1-order-0001');
select zz_check.expect($$select count(*) from nomad_baedal.orders$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.order_items where order_id = (select v from zz_check.ids where k = 'ord1')$$, 0);
select zz_check.fails_with($$select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'cancelled')$$, 'P0002');

-- ==== 3. 결제 반영(서버, 이벤트 id 멱등) ====
select zz_check.as_role('authenticated');
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 12000, 'evt-1')$$, '42501');
select zz_check.as_role('service_role');
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 12000, null)$$, '22023');
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 11999, 'evt-1')$$, '22023');
insert into zz_check.ids select 'pay1', nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 12000, 'evt-1');
select zz_check.expect($$select count(*) from (select 1 where nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 12000, 'evt-1') = (select v from zz_check.ids where k = 'pay1')) t$$, 1);
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 12000, 'evt-2')$$, '22023');  -- 이중 결제
select zz_check.expect($$select count(*) from nomad_baedal.payments$$, 1);
-- 접수 전 배정 불가
select zz_check.fails_with($$select nomad_baedal.assign_rider((select v from zz_check.ids where k = 'ord1'), '00000000-0000-0000-0000-0000000000c1', '010-5555-6666')$$, '22023');

-- ==== 4. 점주 o1: 접수·조리, o2는 b1 주문 0 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select count(*) from nomad_baedal.orders where id = (select v from zz_check.ids where k = 'ord1')$$, 0);
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts where order_id = (select v from zz_check.ids where k = 'ord1')$$, 0);
select zz_check.expect($$select count(*) from nomad_baedal.payments where order_id = (select v from zz_check.ids where k = 'ord1')$$, 0);
select zz_check.fails_with($$select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'accepted')$$, 'P0002');
select zz_check.fails_with($$select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord2'), 'accepted')$$, 'not paid');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_baedal.orders$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts where buyer_phone = '010-1111-2222'$$, 1);
select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'accepted');
select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'cooking');
select zz_check.fails_with($$select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'delivered')$$, '22023');

-- ==== 5. 배정(서버) → 배달원 r1 진행, r2·다른 사람 0 ====
select zz_check.as_role('service_role');
select nomad_baedal.assign_rider((select v from zz_check.ids where k = 'ord1'), '00000000-0000-0000-0000-0000000000c1', '010-5555-6666');
select nomad_baedal.assign_rider((select v from zz_check.ids where k = 'ord1'), '00000000-0000-0000-0000-0000000000c1', '010-5555-6666');  -- 멱등
select zz_check.fails_with($$select nomad_baedal.assign_rider((select v from zz_check.ids where k = 'ord1'), '00000000-0000-0000-0000-0000000000c2', '010-7777-8888')$$, '23505');
select zz_check.login('00000000-0000-0000-0000-0000000000c2');
select zz_check.expect($$select count(*) from nomad_baedal.orders$$, 0);
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts$$, 0);
select zz_check.expect($$select count(*) from nomad_baedal.deliveries$$, 0);
select zz_check.fails_with($$select nomad_baedal.update_delivery((select v from zz_check.ids where k = 'ord1'), 'picked_up')$$, 'P0002');
select zz_check.login('00000000-0000-0000-0000-0000000000c1');
select zz_check.expect($$select count(*) from nomad_baedal.orders$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts where delivery_address = '서울시 합성구 1-1'$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.payments$$, 0);   -- 배달원은 결제 열람 없음
select zz_check.fails_with($$select nomad_baedal.update_delivery((select v from zz_check.ids where k = 'ord1'), 'delivered')$$, '22023');
select nomad_baedal.update_delivery((select v from zz_check.ids where k = 'ord1'), 'picked_up', '15분');
select nomad_baedal.update_delivery((select v from zz_check.ids where k = 'ord1'), 'delivered');
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts$$, 0);   -- 배달 끝나면 배달원 개인정보 열람 종료
select zz_check.fails_with($$select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord1'), 'cancelled')$$, 'P0002');
-- 주문자: 배달원 전화 열람, 상태 delivered
select zz_check.login('00000000-0000-0000-0000-0000000000b1');
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts where rider_phone = '010-5555-6666'$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.orders where status = 'delivered'$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.deliveries where status = 'delivered'$$, 1);

-- ==== 6. 후기: 배달완료 주문의 주문자만, 주문당 1건 ====
insert into nomad_baedal.reviews (order_id, rating) values ((select v from zz_check.ids where k = 'ord1'), 5);
select zz_check.fails_with($$insert into nomad_baedal.reviews (order_id, rating) values ((select v from zz_check.ids where k = 'ord1'), 4)$$, '23505');
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.fails_with($$insert into nomad_baedal.reviews (order_id, rating) values ((select v from zz_check.ids where k = 'ord2'), 4)$$, '42501');  -- 미배달
select zz_check.fails_with($$insert into nomad_baedal.reviews (order_id, rating) values ((select v from zz_check.ids where k = 'ord1'), 1)$$, '42501');  -- 남의 주문
select zz_check.expect($$select count(*) from nomad_baedal.reviews$$, 0);
update nomad_baedal.reviews set rating = 1;
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select count(*) from nomad_baedal.reviews$$, 0);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_baedal.reviews where rating = 5$$, 1);
-- 주문자 b2 주문 취소, 취소 후 결제 거부
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord2'), 'cancelled');
select zz_check.as_role('service_role');
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord2'), 20000, 'evt-3')$$, '22023');

-- ==== 6b. 보안 리뷰 반영: 배정 후 취소 시 배달원 개인정보 0 · 합계 = 항목 합 · 이벤트 id 재사용 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000b1');
insert into zz_check.ids select 'ord3', nomad_baedal.place_order((select v from zz_check.ids where k = 's1'),
  jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_kimbap'), 'qty', 3)),
  '서울시 합성구 3-3', '010-9999-0000', 'b1-order-0003');
select zz_check.expect($$select count(*) from nomad_baedal.orders o where o.id = (select v from zz_check.ids where k = 'ord3')
  and o.total = 9000 and o.total = (select sum(i.unit_price * i.qty) from nomad_baedal.order_items i where i.order_id = o.id)$$, 1);
select zz_check.as_role('service_role');
-- 같은 이벤트 id를 다른 주문·다른 금액에 재사용 → 거부(이전: 기존 결제 id를 그대로 돌려줌)
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord3'), 9000, 'evt-1')$$, 'reused');
select zz_check.fails_with($$select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord1'), 1, 'evt-1')$$, 'reused');
select nomad_baedal.apply_payment((select v from zz_check.ids where k = 'ord3'), 9000, 'evt-3a');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord3'), 'accepted');
select zz_check.as_role('service_role');
select nomad_baedal.assign_rider((select v from zz_check.ids where k = 'ord3'), '00000000-0000-0000-0000-0000000000c2', '010-7777-8888');
select zz_check.login('00000000-0000-0000-0000-0000000000c2');
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts where order_id = (select v from zz_check.ids where k = 'ord3')$$, 1);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_baedal.set_order_status((select v from zz_check.ids where k = 'ord3'), 'cancelled');
select zz_check.login('00000000-0000-0000-0000-0000000000c2');
select zz_check.expect($$select count(*) from nomad_baedal.order_contacts where order_id = (select v from zz_check.ids where k = 'ord3')$$, 0);
select zz_check.expect($$select count(*) from nomad_baedal.deliveries where order_id = (select v from zz_check.ids where k = 'ord3') and status = 'cancelled'$$, 1);
select zz_check.fails_with($$select nomad_baedal.update_delivery((select v from zz_check.ids where k = 'ord3'), 'picked_up')$$, '22023');

-- ==== 7. anon: 표 0·RPC 0 ====
select zz_check.as_role('anon');
select zz_check.fails_with($$select count(*) from nomad_baedal.stores$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.menus$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.orders$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.order_items$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.order_contacts$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.deliveries$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.payments$$, '42501');
select zz_check.fails_with($$select count(*) from nomad_baedal.reviews$$, '42501');
select zz_check.fails_with($$select nomad_baedal.place_order(null, null, null, null, null)$$, '42501');

-- ==== 8. 잠김: o1 개인 조직 비활성 → 가게·메뉴 쓰기·새 주문 거부, 열람 유지 ====
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = false
 where id in (select organization_id from nomad_core.memberships where user_id = '00000000-0000-0000-0000-0000000000a1' and role = 'owner');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$insert into nomad_baedal.menus (store_id, name, price) values ((select v from zz_check.ids where k = 's1'), '라면', 3500)$$, '42501');
select zz_check.fails_with($$insert into nomad_baedal.stores (name) values ('o1 2호점')$$, '42501');
update nomad_baedal.menus set price = 1;
select zz_check.expect($$select count(*) from nomad_baedal.menus where price = 1$$, 0);
select zz_check.expect($$select count(*) from nomad_baedal.orders$$, 2);   -- ord1·ord3(취소) 열람 유지
select zz_check.login('00000000-0000-0000-0000-0000000000b2');
select zz_check.fails_with($$select nomad_baedal.place_order((select v from zz_check.ids where k = 's1'), jsonb_build_array(jsonb_build_object('menu_id', (select v from zz_check.ids where k = 'm_kimbap'), 'qty', 1)), 'a', '01012345678', 'b2-order-0009')$$, 'P0002');

-- ==== 9. 폐점(소프트 삭제): o2 → 다른 사용자 목록·메뉴에서 사라짐, 점주는 열람 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select nomad_baedal.close_store((select v from zz_check.ids where k = 's2'));
select zz_check.expect($$select count(*) from nomad_baedal.stores where deleted_at is not null$$, 1);
select zz_check.fails_with($$insert into nomad_baedal.menus (store_id, name, price) values ((select v from zz_check.ids where k = 's2'), '양념', 21000)$$, '42501');
select zz_check.login('00000000-0000-0000-0000-0000000000b1');
select zz_check.expect($$select count(*) from nomad_baedal.stores$$, 1);
select zz_check.expect($$select count(*) from nomad_baedal.menus where store_id = (select v from zz_check.ids where k = 's2')$$, 0);
