-- stock org안 검사: 조직 2곳 교차 접근 거부 · anon 0 · 역할별 쓰기 · 베타 게이트 · 구독 잠김 회귀 · 모의주문(멱등·확인·킬 스위치)
-- · append-only · 크레딧(core consume_credits) 연결 · AI 라우팅(0002). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/stock/run_check.sh org

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

-- ---- 합성 데이터: 조직 A(team: a1 owner · a3 editor · a5 viewer) 플랜 B, 조직 B(personal: a2 owner) 플랜 A, 조직 C(team: a7 owner) 구독 없음 ----
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test', now()), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test', now()), ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test', now()),
  ('00000000-0000-0000-0000-0000000000a7', 'u7@example.test', now()), ('00000000-0000-0000-0000-0000000000a8', 'u8@example.test', null);
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'personal'),
  ('00000000-0000-0000-0000-00000000000c', 'org C', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner'),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000a7', 'owner');
-- 가입 트리거가 만든 개인 조직은 비활성화(검사 대상 조직만 남긴다)
update nomad_core.organizations set active = false
 where id not in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000c');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'stock', 'B', 'active'), ('00000000-0000-0000-0000-00000000000b', 'stock', 'A', 'active');

-- ==== 0. 서버(service_role): 베타 초대·수락, 연결·동기화 결과 ====
select zz_check.as_role('service_role');
insert into nomad_stock.beta_invites (email_normalized, token_hash) values
  ('u2@example.test', repeat('b', 64)), ('u9@example.test', repeat('9', 64)), ('u8@example.test', repeat('8', 64));
-- 이메일 미인증 사용자는 수락 불가(ST032)
select zz_check.fails_with($$select nomad_stock.redeem_beta_invite(repeat('8', 64), '00000000-0000-0000-0000-0000000000a8')$$, 'ST032');
-- 이메일 불일치 ST031, 없는 토큰 ST030
select zz_check.fails_with($$select nomad_stock.redeem_beta_invite(repeat('9', 64), '00000000-0000-0000-0000-0000000000a2')$$, 'ST031');
select zz_check.fails_with($$select nomad_stock.redeem_beta_invite(repeat('0', 64), '00000000-0000-0000-0000-0000000000a2')$$, 'ST030');
select nomad_stock.redeem_beta_invite(repeat('b', 64), '00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$select nomad_stock.redeem_beta_invite(repeat('b', 64), '00000000-0000-0000-0000-0000000000a2')$$, 'ST030');
-- 팀 조직 A·C는 운영자 경로(직접 부여)
insert into nomad_stock.beta_access (organization_id) values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000c');
insert into nomad_stock.instruments (symbol, name, market) values ('005930', '삼성전자', 'KOSPI'), ('000660', 'SK하이닉스', 'KOSPI');
insert into nomad_stock.daily_prices (symbol, trade_date, close, source) values ('005930', current_date, 70000, 'mock');
insert into nomad_stock.broker_connections (id, organization_id, broker, env, account_masked, account_ref_hash, status, orders_enabled) values
  ('00000000-0000-0000-0000-0000000c0a01', '00000000-0000-0000-0000-00000000000a', 'mock', 'paper', '1234-****', repeat('a', 64), 'active', true),
  ('00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-00000000000b', 'mock', 'paper', '5678-****', repeat('c', 64), 'active', true),
  ('00000000-0000-0000-0000-0000000c0c01', '00000000-0000-0000-0000-00000000000c', 'mock', 'paper', '9999-****', repeat('d', 64), 'active', false);
insert into nomad_stock.holdings (organization_id, connection_id, symbol, name, quantity, avg_price, purchase_krw) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0a01', '005930', '삼성전자', 10, 70000, 700000),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '000660', 'SK하이닉스', 5, 150000, 750000),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000c0c01', '005930', '삼성전자', 1, 70000, 70000);
insert into nomad_stock.balance_snapshots (organization_id, connection_id, cash_krw, purchase_krw, eval_krw) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0a01', 100000, 700000, 720000),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', 10000000, 750000, 700000);
insert into nomad_stock.trades (id, organization_id, connection_id, broker_exec_id, symbol, name, side, quantity, price, amount_krw, executed_at) values
  ('00000000-0000-0000-0000-0000000d0a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0a01', 'x1', '005930', '삼성전자', 'buy', 10, 70000, 700000, now()),
  ('00000000-0000-0000-0000-0000000d0b01', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', 'y1', '000660', 'SK하이닉스', 'buy', 5, 150000, 750000, now());
-- 자격 증명: 같은 조직·같은 증권사·폐기 안 된 키만(ST050), 폐기되면 연결 revoked
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4) values
  ('00000000-0000-0000-0000-0000000ccaa1', '00000000-0000-0000-0000-00000000000a', 'kis', 'default', gen_random_uuid(), 'abcd'),
  ('00000000-0000-0000-0000-0000000ccbb1', '00000000-0000-0000-0000-00000000000b', 'kis', 'default', gen_random_uuid(), 'efgh');
select zz_check.fails_with($$insert into nomad_stock.broker_connections (organization_id, broker, env, account_masked, account_ref_hash, status, credential_id) values ('00000000-0000-0000-0000-00000000000a', 'kis', 'paper', '1111-****', repeat('1', 64), 'active', '00000000-0000-0000-0000-0000000ccbb1')$$, 'ST050');
select zz_check.fails_with($$insert into nomad_stock.broker_connections (organization_id, broker, env, account_masked, account_ref_hash, status, credential_id) values ('00000000-0000-0000-0000-00000000000a', 'kiwoom', 'paper', '1111-****', repeat('1', 64), 'active', '00000000-0000-0000-0000-0000000ccaa1')$$, 'ST050');
insert into nomad_stock.broker_connections (id, organization_id, broker, env, account_masked, account_ref_hash, status, orders_enabled, credential_id) values
  ('00000000-0000-0000-0000-0000000c0a02', '00000000-0000-0000-0000-00000000000a', 'kis', 'paper', '1111-****', repeat('1', 64), 'active', true, '00000000-0000-0000-0000-0000000ccaa1');
-- 크레딧: 조직 B에 100 지급 → 진단 10 차감(멱등 키) → 리포트에 원장 연결
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000b', 100, 'test_grant', 'test:grant:b', 'stock');
insert into nomad_stock.ai_reports (id, organization_id, prompt_version, input_hash, disclaimer_version, request_id, credits_charged, credit_ledger_id) values
  ('00000000-0000-0000-0000-0000000e0b01', '00000000-0000-0000-0000-00000000000b', 'v1', repeat('e', 64), '2026-10-01', '00000000-0000-0000-0000-0000000f0b01', 10,
   (select ledger_id from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000b', 10, 'stock.diagnosis',
      'consume:stock:00000000-0000-0000-0000-0000000f0b01', 'stock', 'ai_report', '00000000-0000-0000-0000-0000000e0b01'))),
  ('00000000-0000-0000-0000-0000000e0a01', '00000000-0000-0000-0000-00000000000a', 'v1', repeat('f', 64), '2026-10-01', '00000000-0000-0000-0000-0000000f0a01', 0, null);
-- 다른 조직의 차감 행은 연결 불가(ST051)
select zz_check.fails_with($$update nomad_stock.ai_reports set credit_ledger_id = (select credit_ledger_id from nomad_stock.ai_reports where id = '00000000-0000-0000-0000-0000000e0b01') where id = '00000000-0000-0000-0000-0000000e0a01'$$, 'ST051');
-- 같은 멱등 키 재요청은 추가 차감 없음
select nomad_core.consume_credits('00000000-0000-0000-0000-00000000000b', 10, 'stock.diagnosis',
  'consume:stock:00000000-0000-0000-0000-0000000f0b01', 'stock', 'ai_report', '00000000-0000-0000-0000-0000000e0b01');
update nomad_stock.ai_reports set status = 'running' where id in ('00000000-0000-0000-0000-0000000e0b01', '00000000-0000-0000-0000-0000000e0a01');
-- 투자 권유 검사 기록 없는 성공은 거부(23514), 목표가 키도 거부
select zz_check.fails_with($$update nomad_stock.ai_reports set status = 'succeeded', output = '{"summary":"x"}' where id = '00000000-0000-0000-0000-0000000e0b01'$$, '23514');
select zz_check.fails_with($$update nomad_stock.ai_reports set status = 'succeeded', output = '{"advice_check":{"passed":true},"target_price":1}' where id = '00000000-0000-0000-0000-0000000e0b01'$$, '23514');
update nomad_stock.ai_reports set status = 'succeeded', output = '{"advice_check":{"passed":true},"summary":"ok"}'
 where id in ('00000000-0000-0000-0000-0000000e0b01', '00000000-0000-0000-0000-0000000e0a01');
select zz_check.fails_with($$update nomad_stock.ai_reports set status = 'queued' where id = '00000000-0000-0000-0000-0000000e0b01'$$, '22023');
insert into nomad_stock.ai_report_items (id, organization_id, report_id, symbol, risk_level) values
  ('00000000-0000-0000-0000-0000000e1a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000e0a01', '005930', 'low'),
  ('00000000-0000-0000-0000-0000000e1b01', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000e0b01', '000660', 'high');
insert into nomad_stock.idea_evaluations (organization_id, item_id, horizon_days, entry_date, entry_price, eval_date, eval_price, return_pct, benchmark_return_pct, rule_version) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000e1a01', 5, current_date - 7, 70000, current_date, 71000, 1.4, 0.5, 'r1'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000e1b01', 5, current_date - 7, 150000, current_date, 140000, -6.6, 0.5, 'r1');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.provider_credentials set revoked_at = now() where id = '00000000-0000-0000-0000-0000000ccaa1';
-- 코어 표에는 제품 트리거가 없다: 키 폐기만으로는 연결이 바뀌지 않는다(사용 시점에 판정)
select zz_check.expect($$select count(*) from nomad_stock.broker_connections where id = '00000000-0000-0000-0000-0000000c0a02' and status = 'active'$$, 1);
select zz_check.expect($$select count(*) from pg_trigger where tgrelid = 'nomad_core.provider_credentials'::regclass and not tgisinternal and tgname like 'nomad_stock%'$$, 0);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 90);
select zz_check.expect($$select count(*) from nomad_stock.beta_access where organization_id = '00000000-0000-0000-0000-00000000000b' and status = 'active'$$, 1);

-- ==== 1. anon: 표 직접 접근 0, 사용자 RPC 실행 불가 ====
select zz_check.as_role('anon');
select zz_check.denied('select count(*) from nomad_stock.instruments');
select zz_check.denied('select count(*) from nomad_stock.holdings');
select zz_check.denied('select count(*) from nomad_stock.beta_invites');
select zz_check.denied($$select nomad_stock.has_stock_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_stock.engage_kill_switch('00000000-0000-0000-0000-00000000000a')$$);
reset role;

-- ==== 2. 조직 A owner(a1): 자기 조직만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_stock.instruments', 2);
select zz_check.expect('select count(id) from nomad_stock.broker_connections', 2);
select zz_check.denied('select account_ref_hash from nomad_stock.broker_connections');
select zz_check.denied('select credential_id from nomad_stock.broker_connections');
select zz_check.denied('select * from nomad_stock.broker_connections');
select zz_check.expect('select count(*) from nomad_stock.holdings', 1);
select zz_check.expect('select count(*) from nomad_stock.balance_snapshots', 1);
select zz_check.expect('select count(*) from nomad_stock.trades', 1);
select zz_check.expect('select count(*) from nomad_stock.ai_reports', 1);
select zz_check.expect('select count(*) from nomad_stock.ai_report_items', 1);
select zz_check.expect($$select count(*) from nomad_stock.holdings where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 0);
-- 리더보드는 A 플랜(조직 B)만: 조직 A(플랜 B)는 0
select zz_check.expect('select count(*) from nomad_stock.idea_evaluations', 0);
select zz_check.expect('select count(*) from nomad_stock.beta_access', 1);
select zz_check.denied('select count(*) from nomad_stock.daily_prices');
select zz_check.denied('select count(*) from nomad_stock.beta_invites');
-- 서버 전용 쓰기 거부
select zz_check.denied($$insert into nomad_stock.broker_connections (organization_id, broker, account_masked, account_ref_hash) values ('00000000-0000-0000-0000-00000000000a', 'mock', '1111-****', repeat('1', 64))$$);
select zz_check.denied($$update nomad_stock.holdings set quantity = 0$$);
select zz_check.denied($$insert into nomad_stock.beta_access (organization_id) values ('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_stock.redeem_beta_invite(repeat('9', 64), '00000000-0000-0000-0000-0000000000a1')$$);
select zz_check.denied($$select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0a01', gen_random_uuid(), '005930', 'buy', 1, 70000, 70000, now(), '00000000-0000-0000-0000-0000000000a1')$$);
-- 남의 조직 체결에 메모 불가, 자기 조직은 가능
select zz_check.denied($$insert into nomad_stock.trade_notes (organization_id, trade_id, body) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000d0b01', 'x')$$);
select zz_check.denied($$insert into nomad_stock.trade_notes (organization_id, trade_id, body) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000d0b01', 'x')$$);
insert into nomad_stock.trade_notes (organization_id, trade_id, body) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000d0a01', 'owner note');
-- 동의: 자기 조직 OK, 남의 조직 42501
select nomad_stock.record_consent('00000000-0000-0000-0000-00000000000a', 'investment_disclaimer', '2026-10-01');
select nomad_stock.record_consent('00000000-0000-0000-0000-00000000000a', 'investment_disclaimer', '2026-10-01');
select zz_check.expect('select count(*) from nomad_stock.consents', 1);
select zz_check.fails_with($$select nomad_stock.record_consent('00000000-0000-0000-0000-00000000000b', 'investment_disclaimer', '2026-10-01')$$, '42501');
-- 한도: owner OK, 남의 조직 거부
select nomad_stock.set_order_limits('00000000-0000-0000-0000-00000000000a', 500000, 2000000, 10, 30, 5);
select zz_check.fails_with($$select nomad_stock.set_order_limits('00000000-0000-0000-0000-00000000000b', 500000, 2000000, 10, 30, 5)$$, '42501');
select zz_check.fails_with($$select nomad_stock.engage_kill_switch('00000000-0000-0000-0000-00000000000b')$$, '42501');
select zz_check.fails_with($$select nomad_stock.engage_kill_switch('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0b01')$$, '42501');
reset role;

-- ==== 3. 조직 A editor(a3)·viewer(a5) ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
insert into nomad_stock.trade_notes (organization_id, trade_id, body) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000d0a01', 'editor note');
select zz_check.expect('select count(*) from nomad_stock.trade_notes', 2);
-- 남의 메모 수정 0행, 자기 메모 소프트 삭제
select zz_check.expect($$with u as (update nomad_stock.trade_notes set body = 'hijack' where body = 'owner note' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (update nomad_stock.trade_notes set deleted_at = now() where body = 'editor note' returning 1) select count(*) from u$$, 1);
select zz_check.fails_with($$select nomad_stock.set_order_limits('00000000-0000-0000-0000-00000000000a', 500000, 2000000, 10, 30, 5)$$, '42501');
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect('select count(*) from nomad_stock.holdings', 1);
select zz_check.denied($$insert into nomad_stock.trade_notes (organization_id, trade_id, body) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000d0a01', 'viewer note')$$);
reset role;
-- owner는 editor 메모 삭제 가능
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$with d as (delete from nomad_stock.trade_notes where body = 'editor note' returning 1) select count(*) from d$$, 1);
reset role;

-- ==== 4. 조직 B owner(a2): 자기 조직만 + 리더보드(플랜 A) ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_stock.holdings', 1);
select zz_check.expect('select count(*) from nomad_stock.trade_notes', 0);
select zz_check.expect('select count(*) from nomad_stock.consents', 0);
select zz_check.expect('select count(*) from nomad_stock.idea_evaluations', 1);
select zz_check.expect($$select count(*) from nomad_stock.ai_reports where credit_ledger_id is not null$$, 1);
reset role;

-- ==== 5. 모의주문: 플랜 B(조직 A)는 ST040, 플랜 A(조직 B)는 생성·멱등·비중·본인 확인·킬 스위치·적격 재확인 ====
select zz_check.as_role('service_role');
select zz_check.fails_with($$select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0a01', '00000000-0000-0000-0000-000000000a01', '005930', 'buy', 1, 70000, 70000, now(), '00000000-0000-0000-0000-0000000000a1')$$, 'ST040');
-- 행위자가 그 조직 멤버가 아니면 42501
select zz_check.fails_with($$select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b09', '000660', 'buy', 1, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a1')$$, '42501');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b01', '000660', 'buy', 2, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b01', '000660', 'buy', 2, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
-- 한도 초과(기본 1회 100만 원) → 예외 대신 blocked 행
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b02', '000660', 'buy', 10, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b03', '000660', 'sell', 1, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
reset role;
select set_config('request.jwt.claims', '', true);
-- 종목 비중 한도 10%: (75만 + 90만) / 1,070만 = 15.4% → blocked
update nomad_stock.order_limits set max_position_weight_pct = 10 where organization_id = '00000000-0000-0000-0000-00000000000b';
select zz_check.as_role('service_role');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b04', '000660', 'buy', 6, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
-- 서버는 사람 확인을 대신할 수 없다
select zz_check.denied($$select nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b01'))$$);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.fails_with($$select nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b01'))$$, '42501');
select zz_check.expect($$select count(*) from nomad_stock.order_requests where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 4);
select zz_check.expect($$select count(*) from nomad_stock.order_requests where block_reason = 'max_order_krw'$$, 1);
select zz_check.expect($$select count(*) from nomad_stock.order_requests where block_reason = 'max_position_weight'$$, 1);
select zz_check.expect($$select est_amount_krw from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b01'$$, 300000);
-- 다른 조직 사용자는 보지도 확인하지도 못한다
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_stock.order_requests', 0);
select zz_check.fails_with($$select nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests limit 1))$$, 'P0002');
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select ((nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b01'))).confirmed_by = '00000000-0000-0000-0000-0000000000a2')::int$$, 1);
-- 킬 스위치: 확인된 b01·대기 b03 즉시 blocked
select nomad_stock.engage_kill_switch('00000000-0000-0000-0000-00000000000b', null, 'panic');
select zz_check.expect($$select count(*) from nomad_stock.order_requests where status = 'blocked'$$, 4);
select zz_check.expect('select count(*) from nomad_stock.kill_switches', 1);
select zz_check.expect('select count(*) from nomad_stock.order_events', 7);
select nomad_stock.release_kill_switch((select id from nomad_stock.kill_switches limit 1));
select zz_check.expect('select count(*) from nomad_stock.kill_switches where is_active', 0);
reset role;
-- 적격 재확인: b05 확인 → orders_enabled 끔 → 제출 시 blocked(not_eligible), b06 확인 시 blocked(not_eligible)
select zz_check.as_role('service_role');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b05', '000660', 'sell', 1, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-000000000b06', '000660', 'sell', 1, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b05'));
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_stock.broker_connections set orders_enabled = false where id = '00000000-0000-0000-0000-0000000c0b01';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select ((nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b06'))).block_reason = 'not_eligible')::int$$, 1);
reset role;
select zz_check.as_role('service_role');
select zz_check.expect($$select ((nomad_stock.apply_order_update((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b05'), 'submitted')).block_reason = 'not_eligible')::int$$, 1);
reset role;
-- 폐기된 키: 확인 시 blocked(not_eligible) + 연결 revoked, 생성 시에도 blocked 행 + 연결 revoked(제품 표만 갱신)
select set_config('request.jwt.claims', '', true);
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4) values
  ('00000000-0000-0000-0000-0000000ccbb2', '00000000-0000-0000-0000-00000000000b', 'kis', 'k2', gen_random_uuid(), 'k2k2'),
  ('00000000-0000-0000-0000-0000000ccbb3', '00000000-0000-0000-0000-00000000000b', 'kis', 'k3', gen_random_uuid(), 'k3k3');
insert into nomad_stock.broker_connections (id, organization_id, broker, env, account_masked, account_ref_hash, status, orders_enabled, credential_id) values
  ('00000000-0000-0000-0000-0000000c0b02', '00000000-0000-0000-0000-00000000000b', 'kis', 'paper', '2222-****', repeat('2', 64), 'active', true, '00000000-0000-0000-0000-0000000ccbb2'),
  ('00000000-0000-0000-0000-0000000c0b03', '00000000-0000-0000-0000-00000000000b', 'kis', 'paper', '3333-****', repeat('3', 64), 'active', true, '00000000-0000-0000-0000-0000000ccbb3');
select zz_check.as_role('service_role');
select nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b02', '00000000-0000-0000-0000-000000000b07', '000660', 'sell', 1, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.provider_credentials set revoked_at = now() where id in ('00000000-0000-0000-0000-0000000ccbb2', '00000000-0000-0000-0000-0000000ccbb3');
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select ((nomad_stock.confirm_paper_order((select id from nomad_stock.order_requests where client_order_id = '00000000-0000-0000-0000-000000000b07'))).block_reason = 'not_eligible')::int$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_stock.broker_connections where id = '00000000-0000-0000-0000-0000000c0b02' and status = 'revoked' and not orders_enabled$$, 1);
select zz_check.as_role('service_role');
select zz_check.expect($$select ((nomad_stock.create_paper_order('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000c0b03', '00000000-0000-0000-0000-000000000b08', '000660', 'sell', 1, 150000, 150000, now(), '00000000-0000-0000-0000-0000000000a2')).block_reason = 'not_eligible')::int$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_stock.broker_connections where id = '00000000-0000-0000-0000-0000000c0b03' and status = 'revoked' and not orders_enabled$$, 1);
select set_config('request.jwt.claims', '', true);
-- order_events·consents append-only(관리자 세션에서도)
select zz_check.fails_with($$update nomad_stock.order_events set detail = '{}'$$, 'ST000');
select zz_check.fails_with($$delete from nomad_stock.consents$$, 'ST000');

-- ==== 6. 잠김 회귀: 구독 없음(조직 C) · 구독 끊김 · 베타 회수 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a7');
select zz_check.expect('select count(*) from nomad_stock.holdings', 0);
select zz_check.expect('select count(id) from nomad_stock.broker_connections', 0);
select zz_check.expect('select count(*) from nomad_stock.instruments', 0);
select zz_check.expect('select count(*) from nomad_stock.fundamentals', 0);
-- 멈추는 쪽은 구독·베타와 무관: 켜기 가능, 읽기는 안 됨
select nomad_stock.engage_kill_switch('00000000-0000-0000-0000-00000000000c', null, 'stop');
select zz_check.expect('select count(*) from nomad_stock.kill_switches', 0);
select zz_check.fails_with($$select nomad_stock.engage_kill_switch('00000000-0000-0000-0000-00000000000a')$$, '42501');
select zz_check.fails_with($$select nomad_stock.record_consent('00000000-0000-0000-0000-00000000000c', 'investment_disclaimer', '2026-10-01')$$, '42501');
reset role;
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'stock';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_stock.holdings', 0);
select zz_check.expect('select count(*) from nomad_stock.instruments', 0);
select zz_check.expect('select count(*) from nomad_stock.trade_notes', 0);
select zz_check.denied($$insert into nomad_stock.trade_notes (organization_id, trade_id, body) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000d0a01', 'locked')$$);
reset role;
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'stock';
select zz_check.as_role('service_role');
select nomad_stock.revoke_beta_access('00000000-0000-0000-0000-00000000000a', 'test');
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_stock.holdings', 0);
select zz_check.expect('select count(*) from nomad_stock.beta_access', 1);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action in ('stock.beta.accept', 'stock.beta.revoke', 'stock.kill_switch.engage', 'stock.order.confirm')$$, 6);

-- ==== 7. 0002 AI: 기능·라우팅 시드 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'stock'$$, 12);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'stock' and plan_code = 'C'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'stock' and feature_code = 'ai_chat'$$, 2);

-- ==== 8. 정적 검사: 모든 표 RLS, anon 표 권한 0 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_stock' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_stock'$$, 19);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_stock' and grantee = 'anon'$$, 0);
select zz_check.expect($$select has_schema_privilege('anon', 'nomad_stock', 'usage')::int$$, 0);
