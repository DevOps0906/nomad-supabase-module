-- ERP org안 검사: 조직 2곳 교차 접근 거부 · ERP 역할별 권한(master_admin/inventory/sales/staff/무역할) · 승인제 가입 · 재고·판매 RPC(멱등) · 함수 권한 · 동기화 컬럼.
-- 합성 데이터만. 실행: bash products/erp/run_check.sh  (begin → 청사진 drop → 임시 touch_updated_at → org/0001·0002 → 이 파일 → rollback)

create schema zz_check;
grant usage on schema zz_check to anon, authenticated, service_role;
create function zz_check.denied(q text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin execute q; ok := true; exception when others then null; end;
  if ok then raise exception 'NOT DENIED: %', q; end if;
end $$;
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
grant execute on all functions in schema zz_check to anon, authenticated, service_role;
create function zz_check.login(u text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
grant execute on function zz_check.login(text) to authenticated;

-- ---- 합성 데이터: 조직 A(a1 owner · a3 재고 · a4 판매 · a5 직원 · a9 ERP 행 없는 editor), 조직 B(a2 owner), a6 가입 신청자 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'a2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'a4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'a5@example.test'), ('00000000-0000-0000-0000-0000000000a6', 'a6@example.test'),
  ('00000000-0000-0000-0000-0000000000a9', 'a9@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a9', 'editor'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
-- 기능 잠금: 두 조직 모두 B 구독(erp/workspace). 구독 없음·C는 잠김(10장)
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'erp', 'B', 'active'), ('00000000-0000-0000-0000-00000000000b', 'erp', 'B', 'active');

-- ==== 0. 서버 프로비저닝(세션 사용자 postgres = 서버 호출) ====
select nomad_erp.register_workspace('00000000-0000-0000-0000-00000000000a', 'A 상사');
select nomad_erp.register_workspace('00000000-0000-0000-0000-00000000000b', 'B 상사');
insert into nomad_erp.employees (organization_id, user_id, display_name, erp_role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', '재고', 'inventory_manager'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', '판매', 'sales_manager'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', '직원', 'staff');
create temp table t_ids (k text primary key, v text);
grant all on t_ids to public;
insert into t_ids select 'code_a', join_code from nomad_erp.join_codes where organization_id = '00000000-0000-0000-0000-00000000000a';
select zz_check.expect($$select count(*) from nomad_erp.join_codes$$, 2);

-- ==== 1. anon: 테이블·함수 모두 거부 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_erp.products');
select zz_check.denied('select count(*) from nomad_erp.workspaces');
select zz_check.denied($$select nomad_erp.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_erp.request_join('XXXXXXXX', 'anon')$$);
reset role;

-- ==== 2. 조직 A owner(a1 = master_admin): 부서·상품·재고·판매 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 1);
insert into nomad_erp.departments (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', '영업부');
insert into nomad_erp.products (organization_id, sku, name, price) values ('00000000-0000-0000-0000-00000000000a', 'SKU-1', '상품1', 1000);
select zz_check.fails_with($$insert into nomad_erp.products (organization_id, sku, name, image_path) values ('00000000-0000-0000-0000-00000000000a', 'SKU-2', 'x', 'other/path.png')$$, 'image_path must be under');
select zz_check.denied($$update nomad_erp.products set quantity = 999$$);
insert into t_ids select 'p1', id::text from nomad_erp.products where sku = 'SKU-1';
select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 10, null, 'move-0001');
select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 10, null, 'move-0001');
select zz_check.expect($$select quantity from nomad_erp.products where sku = 'SKU-1'$$, 10);
select zz_check.fails_with($$select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'ADJUSTMENT', -1)$$, 'reason required');
select zz_check.fails_with($$select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'OUT', 11)$$, 'insufficient stock');
select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 3, 'sale-req-0001');
select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 3, 'sale-req-0001');
select zz_check.expect($$select count(*) from nomad_erp.sales$$, 1);
select zz_check.expect($$select quantity from nomad_erp.products where sku = 'SKU-1'$$, 7);
select zz_check.fails_with($$select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 100, 'sale-req-0002')$$, 'insufficient stock');
select zz_check.fails_with($$select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 1, 'short')$$, 'request_id required');
insert into t_ids select 's1', id::text from nomad_erp.sales where request_id = 'sale-req-0001';
select zz_check.expect($$select length(nomad_erp.get_join_code('00000000-0000-0000-0000-00000000000a'))$$, 8);
select zz_check.expect($$select count(*) from nomad_erp.audit_logs$$, 1);
reset role;

-- ==== 3. 재고 담당(a3): 상품·이력 조회·입고 가능, 판매 조회·등록·부서 쓰기 불가 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect($$select count(*) from nomad_erp.products$$, 1);
select zz_check.expect($$select count(*) from nomad_erp.sales$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.employees$$, 1);
select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 5);
select zz_check.fails_with($$select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 1, 'sale-req-0003')$$, 'master_admin/sales_manager only');
select zz_check.denied($$insert into nomad_erp.departments (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', '재고부')$$);
select zz_check.fails_with($$select nomad_erp.get_join_code('00000000-0000-0000-0000-00000000000a')$$, 'master_admin only');
reset role;

-- ==== 4. 판매 담당(a4): 판매 가능, 입고 불가·출고 가능 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.expect($$select count(*) from nomad_erp.sales$$, 1);
select zz_check.fails_with($$select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 1)$$, 'role not allowed');
select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'OUT', 1);
select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 1, 'sale-req-0004', 'pending');
select zz_check.denied($$insert into nomad_erp.products (organization_id, sku, name) values ('00000000-0000-0000-0000-00000000000a', 'SKU-S', 'x')$$);
reset role;

-- ==== 5. 직원(a5): 상품·판매 안 보임, 대시보드 RPC만 / ERP 행 없는 editor(a9): 접근 없음 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect($$select count(*) from nomad_erp.products$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.sales$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 1);
select zz_check.expect($$select count(*) from (select nomad_erp.dashboard_metrics('00000000-0000-0000-0000-00000000000a')) t$$, 1);
select zz_check.fails_with($$select * from nomad_erp.sales_trend('00000000-0000-0000-0000-00000000000a', now() - interval '1 day', now())$$, 'master_admin/sales_manager only');
select zz_check.login('00000000-0000-0000-0000-0000000000a9');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 0);
select zz_check.fails_with($$select nomad_erp.dashboard_metrics('00000000-0000-0000-0000-00000000000a')$$, 'no access');
reset role;

-- ==== 6. 조직 B owner(a2): 조직 A 전부 안 보이고 쓰기·RPC 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 1);
select zz_check.expect($$select count(*) from nomad_erp.products$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.sales$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.departments$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.audit_logs where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.denied($$insert into nomad_erp.products (organization_id, sku, name) values ('00000000-0000-0000-0000-00000000000a', 'EVIL', 'x')$$);
select zz_check.denied($$insert into nomad_erp.departments (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'EVIL')$$);
select zz_check.fails_with($$select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 1)$$, 'role not allowed');
select zz_check.fails_with($$select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 1, 'sale-req-evil')$$, 'master_admin/sales_manager only');
select zz_check.fails_with($$select nomad_erp.cancel_sale((select v::uuid from t_ids where k = 's1'), 'evil')$$, 'master_admin/sales_manager only');
select zz_check.fails_with($$select nomad_erp.get_join_code('00000000-0000-0000-0000-00000000000a')$$, 'master_admin only');
select zz_check.fails_with($$select nomad_erp.update_workspace_settings('00000000-0000-0000-0000-00000000000a', 'evil', null, null)$$, 'master_admin only');
select zz_check.fails_with($$select nomad_erp.set_employee_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'staff')$$, 'master_admin only');
select zz_check.denied($$select nomad_erp.register_workspace('00000000-0000-0000-0000-00000000000a', 'evil')$$);
reset role;

-- ==== 7. 승인제 가입: 신청(a6) → 승인(a1) → 초대 생성, 재신청 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a6');
select zz_check.expect($$select count(*) from (select nomad_erp.request_join('ZZZZZZZZ', '신청자') r) t where r->>'ok' = 'false' and r->>'code' = 'P0002'$$, 1);
select nomad_erp.request_join((select v from t_ids where k = 'code_a'), '신청자', '가입 희망');
select nomad_erp.request_join((select v from t_ids where k = 'code_a'), '신청자');
select zz_check.expect($$select count(*) from nomad_erp.join_requests$$, 1);
select zz_check.expect($$select count(*) from nomad_erp.products$$, 0);
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect($$select count(*) from nomad_erp.join_requests$$, 0);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$select nomad_erp.decide_join_request((select id from nomad_erp.join_requests limit 1), true, 'boss')$$, 'invalid erp_role');
select nomad_erp.decide_join_request((select id from nomad_erp.join_requests limit 1), true, 'staff');
select zz_check.fails_with($$select nomad_erp.decide_join_request((select id from nomad_erp.join_requests limit 1), false)$$, 'request is approved');
select zz_check.fails_with($$select nomad_erp.set_employee_role('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'staff')$$, 'cannot change your own role');
-- 7 + 입고 5 - 출고 1 + 취소 복원 3 = 14 (pending 판매는 차감 안 함)
select nomad_erp.cancel_sale((select v::uuid from t_ids where k = 's1'), '고객 취소');
select zz_check.expect($$select quantity from nomad_erp.products where sku = 'SKU-1'$$, 14);
reset role;
select zz_check.expect($$select count(*) from nomad_core.invitations where organization_id = '00000000-0000-0000-0000-00000000000a' and email = 'a6@example.test' and role = 'viewer'$$, 1);
select zz_check.expect($$select count(*) from nomad_erp.employees where user_id = '00000000-0000-0000-0000-0000000000a6' and erp_role = 'staff'$$, 1);
select zz_check.login('00000000-0000-0000-0000-0000000000a6');
select zz_check.fails_with($$select nomad_erp.request_join((select v from t_ids where k = 'code_a'), '신청자')$$, 'already a member or invited');
reset role;

-- ==== 8. 불변 이력 · 함수 권한 · 동기화 컬럼 ====
select zz_check.fails_with($$update nomad_erp.inventory_moves set reason = 'x'$$, 'append-only');
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_erp', 'nomad_erp_private') and has_function_privilege('anon', p.oid, 'execute')
    and p.prorettype <> 'trigger'::regtype$$, 0);
select zz_check.expect($$select count(*) from pg_trigger where tgname in ('workspaces_touch','departments_touch','employees_touch','join_requests_touch','products_touch','sales_touch') and not tgisinternal$$, 6);
update nomad_erp.products set name = '상품1-수정' where sku = 'SKU-1';
select zz_check.expect($$select count(*) from nomad_erp.products where sku = 'SKU-1' and updated_at > created_at$$, 1);

-- ==== 9. P1 보안 회귀 ====
-- inventory_moves: 직접 DELETE 도 거부(service_role 포함), 조직 삭제 cascade 는 허용
select zz_check.fails_with($$delete from nomad_erp.inventory_moves$$, 'append-only');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$delete from nomad_erp.inventory_moves$$, 'append-only');
reset role;
select set_config('request.jwt.claims', '', true);
insert into nomad_core.organizations (id, name, kind) values ('00000000-0000-0000-0000-00000000000c', 'org C', 'team');
select nomad_erp.register_workspace('00000000-0000-0000-0000-00000000000c', 'C 상사');
insert into nomad_erp.products (organization_id, sku, name, price) values ('00000000-0000-0000-0000-00000000000c', 'SKU-C', '상품C', 1000);
select nomad_erp.record_inventory_move((select id from nomad_erp.products where sku = 'SKU-C'), 'IN', 3, null, 'move-c-0001');
delete from nomad_core.organizations where id = '00000000-0000-0000-0000-00000000000c';
select zz_check.expect($$select count(*) from nomad_erp.inventory_moves where organization_id = '00000000-0000-0000-0000-00000000000c'$$, 0);
-- record_inventory_move: request_id 길이 8~100
select zz_check.fails_with($$select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 1, null, 'short')$$, 'request_id length');
select zz_check.fails_with($$select nomad_erp.record_inventory_move((select v::uuid from t_ids where k = 'p1'), 'IN', 1, null, repeat('r', 101))$$, 'request_id length');
-- storage: 폴더가 정확한 uuid 형식일 때만 캐스트(하이픈 36자 등은 캐스트 오류 대신 거부/숨김)
insert into storage.objects (bucket_id, name) values ('erp-product-images', '------------------------------------/erp/product/x.png');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from storage.objects where bucket_id = 'erp-product-images' and name like '----%'$$, 0);
select zz_check.fails_with($$insert into storage.objects (bucket_id, name, owner) values ('erp-product-images', '------------------------------------/erp/product/y.png', '00000000-0000-0000-0000-0000000000a1')$$, 'row-level security');
select zz_check.fails_with($$insert into storage.objects (bucket_id, name, owner) values ('erp-product-images', '0000000-00000-0000-0000-00000000000a/erp/product/y.png', '00000000-0000-0000-0000-0000000000a1')$$, 'row-level security');
insert into storage.objects (bucket_id, name, owner) values ('erp-product-images', '00000000-0000-0000-0000-00000000000a/erp/product/ok.png', '00000000-0000-0000-0000-0000000000a1');
reset role;

-- ==== 10. 기능 잠금: 구독이 끊기면 잠김 · export_xlsx(A만) · request_join 시도 제한 ====
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'erp' and plan_code = 'C'$$, 0);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 1);
select zz_check.expect($$select nomad_core.has_feature('00000000-0000-0000-0000-00000000000a', 'erp', 'export_xlsx')::int$$, 0);
reset role;
update nomad_core.subscriptions set plan_code = 'A' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'erp';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select nomad_core.has_feature('00000000-0000-0000-0000-00000000000a', 'erp', 'export_xlsx')::int$$, 1);
reset role;
-- 구독 끊김(inactive): owner·직원 모두 테이블·RPC 잠김, 다른 조직(B)은 그대로
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'erp';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select nomad_erp.has_access('00000000-0000-0000-0000-00000000000a')::int$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 0);
select zz_check.expect($$select count(*) from nomad_erp.products$$, 0);
select zz_check.expect($$select nomad_core.has_feature('00000000-0000-0000-0000-00000000000a', 'erp', 'export_xlsx')::int$$, 0);
select zz_check.denied($$insert into nomad_erp.departments (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', '잠김부')$$);
select zz_check.fails_with($$select nomad_erp.dashboard_metrics('00000000-0000-0000-0000-00000000000a')$$, 'no access');
select zz_check.fails_with($$select nomad_erp.record_sale((select v::uuid from t_ids where k = 'p1'), 1, 'sale-req-lock')$$, 'master_admin/sales_manager only');
select zz_check.fails_with($$select nomad_erp.get_join_code('00000000-0000-0000-0000-00000000000a')$$, 'master_admin only');
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect($$select count(*) from nomad_erp.products$$, 0);
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 1);
reset role;
-- 만료(ends_at 지남)·C 구독도 잠김, 재구독(B)하면 풀림
update nomad_core.subscriptions set status = 'active', plan_code = 'B', starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
  where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'erp';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 0);
reset role;
update nomad_core.subscriptions set plan_code = 'C', ends_at = null where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'erp';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 0);
reset role;
update nomad_core.subscriptions set plan_code = 'B' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'erp';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_erp.workspaces$$, 1);
select zz_check.expect($$select count(*) from nomad_erp.products$$, 1);
reset role;
-- request_join 시도 제한: 사용자당 10회/시간. 잘못된 코드도 세고(롤백 안 됨), 11번째는 맞는 코드여도 ER006
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a7', 'a7@example.test');
select zz_check.login('00000000-0000-0000-0000-0000000000a7');
select zz_check.expect($$select count(*) from generate_series(1, 10) g, lateral (select nomad_erp.request_join('WRONG' || g, '추측') r) t
  where r->>'code' = 'P0002'$$, 10);
select zz_check.expect($$select count(*) from (select nomad_erp.request_join((select v from t_ids where k = 'code_a'), '추측') r) t
  where r->>'ok' = 'false' and r->>'code' = 'ER006' and (r->>'reset_at') is not null$$, 1);
select zz_check.denied($$select nomad_core.rate_limit_take('erp:join:x', 10, 3600)$$);
reset role;
select zz_check.expect($$select count from nomad_core.rate_limit_buckets where key = 'erp:join:00000000-0000-0000-0000-0000000000a7'$$, 11);
select zz_check.expect($$select count(*) from nomad_erp.join_requests where user_id = '00000000-0000-0000-0000-0000000000a7'$$, 0);
-- 존재 노출 금지: 없는 코드 · 교체된(만료) 코드 · 정지된 다른 조직 코드 응답이 글자까지 같다. 셋 다 시도 횟수에 든다.
insert into t_ids select 'code_b_old', join_code from nomad_erp.join_codes where organization_id = '00000000-0000-0000-0000-00000000000b';
insert into t_ids values ('code_b_new', nomad_erp.rotate_join_code('00000000-0000-0000-0000-00000000000b'));
update nomad_erp.workspaces set status = 'suspended' where organization_id = '00000000-0000-0000-0000-00000000000b';
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a8', 'a8@example.test');
create temp table t_join_resp (k text primary key, r jsonb);
grant all on t_join_resp to public;
select zz_check.login('00000000-0000-0000-0000-0000000000a8');
insert into t_join_resp select 'none', nomad_erp.request_join('ZZZZZZZZ', '추측');
insert into t_join_resp select 'rotated', nomad_erp.request_join((select v from t_ids where k = 'code_b_old'), '추측');
insert into t_join_resp select 'suspended', nomad_erp.request_join((select v from t_ids where k = 'code_b_new'), '추측');
reset role;
select zz_check.expect($$select count(distinct r::text) from t_join_resp$$, 1);
select zz_check.expect($$select count(*) from t_join_resp where r = '{"ok": false, "code": "P0002"}'::jsonb$$, 3);
select zz_check.expect($$select count from nomad_core.rate_limit_buckets where key = 'erp:join:00000000-0000-0000-0000-0000000000a8'$$, 3);
-- task-019: 구독이 끊긴(기능 잠긴) 조직의 가입 코드도 없는 코드와 글자까지 같은 응답. 시도 횟수에 든다.
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'erp';
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000aa', 'aa@example.test');
select zz_check.login('00000000-0000-0000-0000-0000000000aa');
insert into t_join_resp select 'locked', nomad_erp.request_join((select v from t_ids where k = 'code_a'), '추측');
reset role;
select zz_check.expect($$select count(distinct r::text) from t_join_resp$$, 1);
select zz_check.expect($$select count(*) from t_join_resp where k = 'locked' and r = '{"ok": false, "code": "P0002"}'::jsonb$$, 1);
select zz_check.expect($$select count from nomad_core.rate_limit_buckets where key = 'erp:join:00000000-0000-0000-0000-0000000000aa'$$, 1);
select zz_check.expect($$select count(*) from nomad_erp.join_requests where user_id = '00000000-0000-0000-0000-0000000000aa'$$, 0);
