-- Arch org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · 공개 RPC(D8) · 잠김(구독 끊김) 회귀 · 크레딧 선차감·환불·잡 · 주문(D1)·라이선스·기기 · AI 시드(0002).
-- 합성 데이터만, 마지막에 rollback. 실행: bash products/arch/run_check.sh

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
create function zz_check.expect_text(q text, want text) returns void language plpgsql as $$
declare r text; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
create table zz_check.vals (k text primary key, v text);
grant all on zz_check.vals to service_role, authenticated;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer, 플랜 A 구독), 조직 B(u2 owner, 구독 없음 → 잠김), u4 = 어느 조직에도 없음 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'arch', 'A', 'active');

-- ==== 0. 서버: 운영 상수·상품·규칙 팩(수치는 저장소 시드가 아니라 검사용) ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_arch.runtime_config (key, value_int) values
  ('price.render_std', 3), ('price.render_hq', 5), ('price.review', 15), ('price.proposal', 10), ('price_krw.updates_yearly', 290000);
insert into nomad_arch.license_skus (code, name, price_krw, bonus_credits, max_activations, fallback_features) values
  ('perpetual_standard', '영구 라이선스', 890000, 300, 2, '{"ai_render": true, "cloud_review": false, "render_max_px": 4096}'),
  ('perpetual_old', '판매 종료', 490000, 0, 2, '{}');
update nomad_arch.license_skus set is_active = false where code = 'perpetual_old';
insert into nomad_arch.rule_packs (version, status, basis_date, storage_path, sha256, signature, kid, bytes, published_at) values
  ('2026.11.1', 'published', '2026-11-01', 'rule-packs/2026.11.1/pack.json', repeat('a', 64), repeat('s', 16), 'k1', 100, now() - interval '1 day');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test', 'zz:grant:a', 'arch');
reset role;

-- ==== 1. anon: 공개 상품 목록 RPC 만 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect('select count(*) from nomad_arch.public_license_skus()', 1);
select zz_check.denied('select count(*) from nomad_arch.license_skus');
select zz_check.denied('select count(*) from nomad_arch.licenses');
select zz_check.denied('select count(*) from nomad_arch.rule_packs');
select zz_check.denied($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_arch.eligible_rule_packs('00000000-0000-0000-0000-00000000000a')$$);
reset role;

-- ==== 2. 조직 A owner(구독 A): 표제란·규칙 팩 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000a') ->> 'state'$$, 'subscribed');
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000a') ->> 'drafting_watermark'$$, 'false');
select zz_check.denied($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000b')$$);
select nomad_arch.upsert_drafting_profile('{"office_name":"A 사무소","layer_map":{"A-WALL":"WALL"}}', '00000000-0000-0000-0000-00000000000a');
select zz_check.fails_with($$select nomad_arch.upsert_drafting_profile('{"client_name":"홍길동"}', '00000000-0000-0000-0000-00000000000a')$$, '22023');
select zz_check.fails_with($$select nomad_arch.upsert_drafting_profile('{"office_name":"x"}', '00000000-0000-0000-0000-00000000000b')$$, '42501');
select zz_check.expect('select count(*) from nomad_arch.drafting_profiles', 1);
select zz_check.expect($$select count(*) from nomad_arch.eligible_rule_packs('00000000-0000-0000-0000-00000000000a')$$, 1);
select zz_check.expect('select count(*) from nomad_arch.rule_packs', 1);
select zz_check.denied('select storage_path from nomad_arch.rule_packs');
select zz_check.denied('select count(*) from nomad_arch.runtime_config');
select zz_check.denied($$insert into nomad_arch.cloud_projects (organization_id, local_id, name, storage_path) values ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 'x', 'x')$$);
select zz_check.denied($$select nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'render', 'render_std', gen_random_uuid(), gen_random_uuid())$$);
reset role;

-- ==== 3. 조직 A editor: 클라우드 사본(한도·버전), 표제란 불가 / viewer: 저장 불가 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_arch.upsert_drafting_profile('{"office_name":"x"}', '00000000-0000-0000-0000-00000000000a')$$, 'AR042');
select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a1', 'P1',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a1/00000000-0000-0000-0000-0000000002a1.arch', 0);
select zz_check.expect($$select version from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a1', 'P1',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a1/00000000-0000-0000-0000-0000000002a2.arch', 1)$$, 2);
select zz_check.fails_with($$select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a1', 'P1',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a1/00000000-0000-0000-0000-0000000002a3.arch', 1)$$, 'AR041');
select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a2', 'P2',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a2/00000000-0000-0000-0000-0000000002a4.arch', 0);
select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a3', 'P3',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a3/00000000-0000-0000-0000-0000000002a5.arch', 0);
-- plan_limits 시드 없음 → 원본 기본값 cloud_projects_max 3
select zz_check.fails_with($$select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a4', 'P4',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a4/00000000-0000-0000-0000-0000000002a6.arch', 0)$$, 'AR040');
-- 다른 조직 경로로 저장 거부
select zz_check.fails_with($$select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001b1', 'X',
  '00000000-0000-0000-0000-00000000000b/arch/project_snapshot/00000000-0000-0000-0000-0000000001b1/00000000-0000-0000-0000-0000000002b1.arch', 0)$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_arch.cloud_projects', 3);
select zz_check.fails_with($$select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001a1', 'P1',
  '00000000-0000-0000-0000-00000000000a/arch/project_snapshot/00000000-0000-0000-0000-0000000001a1/00000000-0000-0000-0000-0000000002a7.arch', 2)$$, '42501');
reset role;

-- ==== 4. 조직 B owner(구독·라이선스 없음 = 잠김) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000b') ->> 'state'$$, 'trial_expired');
select zz_check.expect('select count(*) from nomad_arch.cloud_projects', 0);
select zz_check.expect('select count(*) from nomad_arch.drafting_profiles', 0);
select zz_check.expect('select count(*) from nomad_arch.rule_packs', 0);
select zz_check.fails_with($$select nomad_arch.upsert_drafting_profile('{"office_name":"B"}', '00000000-0000-0000-0000-00000000000b')$$, '42501');
select zz_check.fails_with($$select * from nomad_arch.save_cloud_project('00000000-0000-0000-0000-0000000001b1', 'X',
  '00000000-0000-0000-0000-00000000000b/arch/project_snapshot/00000000-0000-0000-0000-0000000001b1/00000000-0000-0000-0000-0000000002b1.arch', 0)$$, '42501');
select zz_check.expect($$select count(*) from nomad_arch.eligible_rule_packs('00000000-0000-0000-0000-00000000000b')$$, 0);
reset role;

-- ==== 5. 서버: AI 실행 — 선차감·잡·멱등·환불 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into zz_check.vals
select 'run1', r.run_id::text from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'render', 'render_std',
  '00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000004a1',
  '{"inputs":{"depth_path":"00000000-0000-0000-0000-00000000000a/arch/render_input/00000000-0000-0000-0000-0000000005a1.png","edge_path":"00000000-0000-0000-0000-00000000000a/arch/render_input/00000000-0000-0000-0000-0000000005a2.png"}}') r;
-- 같은 request_id = 같은 실행(재차감 없음)
select zz_check.expect_text($$select r.run_id::text from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'render', 'render_std',
  '00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000004a1', '{}') r$$, (select v from zz_check.vals where k = 'run1'));
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'render', 'render_std',
  '00000000-0000-0000-0000-0000000003a1', gen_random_uuid(), '{}')$$, '42501');
-- 잠긴 조직 B / 비멤버 행위자 / viewer 행위자 / 다른 조직 경로 / 해상도 한도(plan_limits 기본 1024)
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'review', 'review', gen_random_uuid(), gen_random_uuid(), '{}')$$, '42501');
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'review', 'review', gen_random_uuid(), gen_random_uuid(), '{}')$$, '42501');
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'review', 'review', gen_random_uuid(), gen_random_uuid(), '{}')$$, '42501');
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'render', 'render_std', gen_random_uuid(), gen_random_uuid(),
  '{"inputs":{"depth_path":"00000000-0000-0000-0000-00000000000b/arch/render_input/00000000-0000-0000-0000-0000000005a1.png","edge_path":"00000000-0000-0000-0000-00000000000b/arch/render_input/00000000-0000-0000-0000-0000000005a2.png"}}')$$, '23514');
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'render', 'render_hq', gen_random_uuid(), gen_random_uuid(), '{}')$$, 'render_max_px');
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'layout', 'layout', gen_random_uuid(), gen_random_uuid(), '{}')$$, 'Phase 2');
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 97);
select zz_check.expect($$select count(*) from nomad_core.jobs j join nomad_arch.renders r on r.job_id = j.id and r.credit_ledger_id = j.credit_ledger_id where j.product_code = 'arch' and j.job_type = 'arch.render'$$, 1);
-- 멤버는 실행 기록을 읽는다(B 는 못 본다)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_arch.renders', 1);
select zz_check.denied($$update nomad_arch.renders set status = 'succeeded'$$);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_arch.renders', 0);
reset role;
-- 실패 → 환불, 결과 경로 검증. fail_ai_run 은 최종 실패에서만(잡이 queued·running 이면 거부)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_arch.finish_ai_run((select v::uuid from zz_check.vals where k = 'run1'), '{"output_path":"00000000-0000-0000-0000-00000000000b/arch/render/00000000-0000-0000-0000-0000000006a1.png","ai_label":true}')$$, '23514');
select zz_check.fails_with($$select nomad_arch.fail_ai_run((select v::uuid from zz_check.vals where k = 'run1'), 'too early')$$, '55000');
-- 재현 A: 잡이 최종 실패(core 가 환불)한 뒤 결과 저장 시도 → 거부(환불된 실행에 결과 없음)
select count(*) from nomad_core.claim_jobs('arch.render', 'w1', 1, null, 'arch');
select nomad_core.fail_job(r.job_id, 'w1', 1, 'provider error', false) from nomad_arch.renders r where r.id = (select v::uuid from zz_check.vals where k = 'run1');
select zz_check.fails_with($$select nomad_arch.finish_ai_run((select v::uuid from zz_check.vals where k = 'run1'), '{"output_path":"00000000-0000-0000-0000-00000000000a/arch/render/00000000-0000-0000-0000-0000000006a1.png","ai_label":true}')$$, '55000');
select zz_check.expect_text($$select nomad_arch.fail_ai_run((select v::uuid from zz_check.vals where k = 'run1'), 'provider error') ->> 'status'$$, 'refunded');
select zz_check.fails_with($$select nomad_arch.fail_ai_run((select v::uuid from zz_check.vals where k = 'run1'), 'again')$$, '22023');
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 100);
-- 재현 B: 결과 저장(succeeded) 뒤 잡이 최종 실패해도 환불되지 않는다(mark_job_delivered)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into zz_check.vals
select 'run2', r.run_id::text from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'render', 'render_std',
  '00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000004a1',
  '{"inputs":{"depth_path":"00000000-0000-0000-0000-00000000000a/arch/render_input/00000000-0000-0000-0000-0000000005a1.png","edge_path":"00000000-0000-0000-0000-00000000000a/arch/render_input/00000000-0000-0000-0000-0000000005a2.png"}}') r;
select count(*) from nomad_core.claim_jobs('arch.render', 'w1', 1, null, 'arch');
select nomad_arch.finish_ai_run((select v::uuid from zz_check.vals where k = 'run2'), '{"output_path":"00000000-0000-0000-0000-00000000000a/arch/render/00000000-0000-0000-0000-0000000006a2.png","ai_label":true,"width":1024,"height":1024}');
select nomad_core.fail_job(r.job_id, 'w1', 1, 'late error', false) from nomad_arch.renders r where r.id = (select v::uuid from zz_check.vals where k = 'run2');
select zz_check.fails_with($$select nomad_arch.fail_ai_run((select v::uuid from zz_check.vals where k = 'run2'), 'late')$$, '22023');
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 97);
select zz_check.expect_text($$select r.status || '/' || j.status || '/' || j.refund_on_failure::text from nomad_arch.renders r join nomad_core.jobs j on j.id = r.job_id where r.id = (select v::uuid from zz_check.vals where k = 'run2')$$, 'succeeded/failed/false');

-- ==== 6. 주문(D1) → 라이선스 발급 → 기기 → 연장 → 환불 (조직 B) ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into zz_check.vals
select 'order1', o.id::text from nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2',
  'license', 'perpetual_standard', 'zz-order-key-1') o;
select zz_check.expect($$select amount_krw from nomad_arch.license_orders where id = (select v::uuid from zz_check.vals where k = 'order1')$$, 890000);
-- 멱등: 같은 키 = 같은 주문, 다른 요청 = 거부
select zz_check.expect_text($$select o.id::text from nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'license', 'perpetual_standard', 'zz-order-key-1') o$$,
  (select v from zz_check.vals where k = 'order1'));
select zz_check.fails_with($$select nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'updates_extension', null, 'zz-order-key-1')$$, 'idempotency');
select zz_check.fails_with($$select nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'license', 'perpetual_old', 'zz-order-key-2')$$, 'unknown license sku');
select zz_check.fails_with($$select nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'license', 'perpetual_standard', 'zz-order-key-3')$$, '42501');
select zz_check.fails_with($$select nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'updates_extension', null, 'zz-order-key-4')$$, 'AR003');
-- 결제 전 발급 금지, 금액 불일치 거부
select zz_check.fails_with($$select * from nomad_arch.issue_license((select v::uuid from zz_check.vals where k = 'order1'))$$, 'paid license order required');
select zz_check.fails_with($$select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order1'), 'paid', 'pg-1', 1000)$$, 'matching amount');
select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order1'), 'paid', 'pg-1', 890000);
select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order1'), 'paid', 'pg-1', 890000);   -- 웹훅 재전송
select zz_check.fails_with($$select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order1'), 'canceled')$$, '22023');
insert into zz_check.vals select 'serial', l.serial from nomad_arch.issue_license((select v::uuid from zz_check.vals where k = 'order1')) l;
select zz_check.expect($$select count(*) from nomad_arch.issue_license((select v::uuid from zz_check.vals where k = 'order1')) l where l.serial is null$$, 1);
insert into zz_check.vals values ('serial_hash', (select encode(extensions.digest(replace(substr(v, 6), '-', ''), 'sha256'), 'hex') from zz_check.vals where k = 'serial'));
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 300);
select zz_check.expect($$select count(*) from nomad_arch.licenses where serial_hash = (select v from zz_check.vals where k = 'serial_hash')$$, 1);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
-- 기기: 비멤버 거부, 2대까지, 같은 기기 재활성은 갱신
select zz_check.fails_with($$select nomad_arch.activate_license((select v from zz_check.vals where k = 'serial_hash'), repeat('1', 64), '00000000-0000-0000-0000-0000000000a4')$$, 'AR006');
select zz_check.fails_with($$select nomad_arch.activate_license(repeat('f', 64), repeat('1', 64), '00000000-0000-0000-0000-0000000000a2')$$, 'AR002');
select nomad_arch.activate_license((select v from zz_check.vals where k = 'serial_hash'), repeat('1', 64), '00000000-0000-0000-0000-0000000000a2');
select nomad_arch.activate_license((select v from zz_check.vals where k = 'serial_hash'), repeat('1', 64), '00000000-0000-0000-0000-0000000000a2');
select nomad_arch.activate_license((select v from zz_check.vals where k = 'serial_hash'), repeat('2', 64), '00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$select nomad_arch.activate_license((select v from zz_check.vals where k = 'serial_hash'), repeat('3', 64), '00000000-0000-0000-0000-0000000000a2')$$, 'AR001');
-- 라이선스만 있는 조직은 플랜 기기 불가
select zz_check.fails_with($$select nomad_arch.activate_plan_device('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', repeat('4', 64))$$, 'AR003');
select nomad_arch.activate_plan_device('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', repeat('5', 64));
select zz_check.fails_with($$select nomad_arch.activate_plan_device('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', repeat('6', 64))$$, 'AR001');
reset role;

-- B owner: 라이선스로 접근이 열린다(licensed), 해시 컬럼은 못 본다, A 기록은 못 본다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000b') ->> 'state'$$, 'licensed');
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000b') ->> 'cloud_review'$$, 'true');
-- p_org null = 개인 조직(arch 접근 없음) → 거부
select zz_check.fails_with($$select nomad_arch.upsert_drafting_profile('{"office_name":"B 사무소"}')$$, 'no arch access');
select nomad_arch.upsert_drafting_profile('{"office_name":"B 사무소"}', '00000000-0000-0000-0000-00000000000b');
select zz_check.expect('select count(*) from nomad_arch.drafting_profiles', 1);
select zz_check.expect('select count(*) from nomad_arch.licenses', 1);
select zz_check.expect('select count(*) from nomad_arch.license_orders', 1);
select zz_check.denied('select serial_hash from nomad_arch.licenses');
select zz_check.denied('select device_hash from nomad_arch.license_activations');
select zz_check.denied('select external_payment_ref from nomad_arch.license_orders');
select zz_check.expect('select count(*) from nomad_arch.license_activations', 2);
select zz_check.expect('select count(*) from nomad_arch.rule_packs', 1);
-- 셀프 해제(owner): 1대
select nomad_arch.deactivate_activation((select a.id from nomad_arch.license_activations a where a.deactivated_at is null order by a.activated_at limit 1));
select zz_check.expect($$select count(*) from nomad_arch.license_activations where deactivation_kind = 'self'$$, 1);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_arch.licenses', 0);
select zz_check.expect('select count(*) from nomad_arch.license_orders', 0);
select zz_check.expect('select count(*) from nomad_arch.drafting_profiles', 1);          -- A 것만
reset role;
-- A owner 가 B 기기를 해제하려 하면 not found
select set_config('zz.b_activation', (select id::text from nomad_arch.license_activations where organization_id = '00000000-0000-0000-0000-00000000000b' and deactivated_at is null limit 1), true);
select set_config('zz.a_activation', (select id::text from nomad_arch.license_activations where organization_id = '00000000-0000-0000-0000-00000000000a' limit 1), true);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_arch.deactivate_activation(current_setting('zz.b_activation')::uuid)$$, 'P0002');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_arch.deactivate_activation(current_setting('zz.a_activation')::uuid)$$, '42501');
reset role;

-- 연장 주문(+1년, 멱등) → 환불(라이선스 refunded → 기기 해제 → 다시 잠김)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into zz_check.vals
select 'order2', o.id::text from nomad_arch.create_license_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2',
  'updates_extension', null, 'zz-order-key-5') o;
select zz_check.expect($$select amount_krw from nomad_arch.license_orders where id = (select v::uuid from zz_check.vals where k = 'order2')$$, 290000);
select zz_check.fails_with($$select * from nomad_arch.extend_updates((select v::uuid from zz_check.vals where k = 'order2'))$$, 'paid updates_extension');
select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order2'), 'paid', 'pg-2', 290000);
insert into zz_check.vals select 'until1', updates_until::text from nomad_arch.licenses;
select * from nomad_arch.extend_updates((select v::uuid from zz_check.vals where k = 'order2'));
select * from nomad_arch.extend_updates((select v::uuid from zz_check.vals where k = 'order2'));
select zz_check.expect_text($$select updates_until::text from nomad_arch.licenses$$, (select ((v::date) + interval '1 year')::date::text from zz_check.vals where k = 'until1'));
-- 연장 환불 → 연장 되돌림
select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order2'), 'refunded');
select zz_check.expect_text($$select updates_until::text || '/' || cardinality(extension_order_ids) from nomad_arch.licenses$$, (select v || '/0' from zz_check.vals where k = 'until1'));
-- 라이선스 환불 → 기기 해제 + 보너스 회수(잔액 한도, 멱등)
select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order1'), 'refunded');
select nomad_arch.mark_license_order((select v::uuid from zz_check.vals where k = 'order1'), 'refunded');
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.credit_ledger where idempotency_key like 'arch:bonus_clawback:%'$$, 1);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.expect($$select count(*) from nomad_arch.licenses where status = 'refunded'$$, 1);
select zz_check.expect($$select count(*) from nomad_arch.license_activations where license_id is not null and deactivated_at is null$$, 0);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000b') ->> 'state'$$, 'trial_expired');
select zz_check.expect('select count(*) from nomad_arch.drafting_profiles', 0);
select zz_check.expect('select count(*) from nomad_arch.license_orders', 2);              -- 구매 기록은 잠기지 않는다
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000b' and action like 'arch.%' and action <> 'arch.license.activate'$$, 10);

-- ==== 7. 잠김 회귀: A 구독이 끊기면 작업 공간·AI 가 잠긴다 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'arch';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect_text($$select nomad_arch.org_features('00000000-0000-0000-0000-00000000000a') ->> 'state'$$, 'subscription_expired');
select zz_check.expect('select count(*) from nomad_arch.cloud_projects', 0);
select zz_check.expect('select count(*) from nomad_arch.renders', 0);
select zz_check.expect('select count(*) from nomad_arch.rule_packs', 0);
select zz_check.expect($$select count(*) from nomad_arch.eligible_rule_packs('00000000-0000-0000-0000-00000000000a')$$, 0);
select zz_check.fails_with($$select nomad_arch.upsert_drafting_profile('{"office_name":"x"}', '00000000-0000-0000-0000-00000000000a')$$, '42501');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select * from nomad_arch.start_ai_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'review', 'review', gen_random_uuid(), gen_random_uuid(), '{}')$$, 'no active plan or license');
select zz_check.fails_with($$select nomad_arch.activate_plan_device('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', repeat('7', 64))$$, 'AR003');
reset role;
-- 체험(B, 만료일 있음)으로 다시 열린다 — 워터마크 있음
update nomad_core.subscriptions set status = 'active', plan_code = 'B', ends_at = now() + interval '14 days'
 where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'arch';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect_text($$select (nomad_arch.org_features('00000000-0000-0000-0000-00000000000a') ->> 'state') || '/' || (nomad_arch.org_features('00000000-0000-0000-0000-00000000000a') ->> 'drafting_watermark')$$, 'trial/true');
select zz_check.expect('select count(*) from nomad_arch.cloud_projects', 3);
reset role;

-- ==== 8. 0002: AI 라우팅 시드 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'arch'$$, 14);

-- ==== 9. 모든 표 RLS · anon 직접 grant 없음 ====
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_arch' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_arch' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_arch' and grantee = 'anon'$$, 0);
