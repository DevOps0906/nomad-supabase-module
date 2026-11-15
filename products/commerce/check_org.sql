-- Commerce org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · 상품 한도·소프트 삭제 · 마켓 계정 자격(조직·제공자·폐기, 사용 시점 재확인)
-- · 상세페이지 잡 전달(실패·취소 잡 거부 + mark_job_delivered) · 업로드 게이트 · 구독 끊김 잠김(기존 행 재시도 포함) · 회귀(anon 0·core 직접 쓰기 0·라우팅 시드).
-- 합성 데이터만, 마지막에 rollback. 실행: bash products/commerce/run_check.sh

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
create table zz_check.vals (k text primary key, v text);
grant all on zz_check.vals to service_role, authenticated;
create function zz_check.v(p text) returns uuid language sql stable as $$ select v::uuid from zz_check.vals where k = p $$;
create function zz_check.s15() returns text[] language sql immutable as $$ select array['T-1','T-2','T-3','T-4','T-5','D-1','D-2','D-3','D-4','D-5','D-6','D-7','D-8','L-1','L-3'] $$;
create function zz_check.s18() returns text[] language sql immutable as $$ select array['T-1','T-2','T-3','T-4','T-5','D-1','D-2','D-3','D-4','D-5','D-6','D-7','D-8','D-9','D-10','L-1','L-2','L-3'] $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer, 플랜 B 구독), 조직 B(u2 owner, 구독 없음 = C), u4 = 어느 조직에도 없음 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'c1@example.test'), ('00000000-0000-0000-0000-0000000000c2', 'c2@example.test'),
  ('00000000-0000-0000-0000-0000000000c3', 'c3@example.test'), ('00000000-0000-0000-0000-0000000000c4', 'c4@example.test'),
  ('00000000-0000-0000-0000-0000000000c5', 'c5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000c00a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000c00b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000c00a', '00000000-0000-0000-0000-0000000000c1', 'owner'),
  ('00000000-0000-0000-0000-00000000c00a', '00000000-0000-0000-0000-0000000000c3', 'editor'),
  ('00000000-0000-0000-0000-00000000c00a', '00000000-0000-0000-0000-0000000000c5', 'viewer'),
  ('00000000-0000-0000-0000-00000000c00b', '00000000-0000-0000-0000-0000000000c2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000c00a', 'commerce', 'B', 'active');
-- 검사용 자격(vault 원문 없이 메타만, secret_id 는 임의값)
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4) values
  ('00000000-0000-0000-0000-00000000cc01', '00000000-0000-0000-0000-00000000c00a', 'coupang', 'A 쿠팡', gen_random_uuid(), '1111'),
  ('00000000-0000-0000-0000-00000000cc02', '00000000-0000-0000-0000-00000000c00a', 'smartstore', 'A 스마트', gen_random_uuid(), '2222'),
  ('00000000-0000-0000-0000-00000000cc03', '00000000-0000-0000-0000-00000000c00b', 'coupang', 'B 쿠팡', gen_random_uuid(), '3333'),
  ('00000000-0000-0000-0000-00000000cc04', '00000000-0000-0000-0000-00000000c00a', 'gmarket', 'A 지마켓', gen_random_uuid(), '4444'),
  ('00000000-0000-0000-0000-00000000cc05', '00000000-0000-0000-0000-00000000c00a', 'coupang', 'A 쿠팡 폐기', gen_random_uuid(), '5555');
update nomad_core.provider_credentials set revoked_at = now() where id = '00000000-0000-0000-0000-00000000cc05';

-- ==== 1. anon: 스키마 usage 없음(공개 RPC 없음, D8) ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_commerce.products');
select zz_check.denied('select count(*) from nomad_commerce.banned_words');
select zz_check.denied('select count(*) from nomad_commerce.exchange_rates');
select zz_check.denied($$select nomad_commerce.acknowledge_compliance_warning(gen_random_uuid())$$);
reset role;

-- ==== 2. 상품 한도: plan_limits 시드 없음 → 상수 기본 30(원본 free). 30개 성공·31번째 CM002 후 삭제. 이후 검사용 한도 C 2 · B 5 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated"}', true);
insert into nomad_commerce.products (organization_id, title) select '00000000-0000-0000-0000-00000000c00b', 'd' || g from generate_series(1, 30) g;
select zz_check.fails_with($$insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00b', 'x')$$, 'CM002');
delete from nomad_commerce.products where organization_id = '00000000-0000-0000-0000-00000000c00b';
reset role;
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('commerce', 'C', 'products', 2), ('commerce', 'B', 'products', 5);

-- ==== 3. 조직 A owner·editor·viewer: 사용자 콘텐츠 쓰기 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated"}', true);
with r as (
  insert into nomad_commerce.products (organization_id, title, sell_price_krw) values ('00000000-0000-0000-0000-00000000c00a', 'A 상품1', 19900) returning id) insert into zz_check.vals select 'pA1', id::text from r;
with r as (
  insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00a', 'A 상품2') returning id) insert into zz_check.vals select 'pA2', id::text from r;
select zz_check.expect($$select count(*) from nomad_commerce.products where created_by = '00000000-0000-0000-0000-0000000000c3'$$, 2);
with r as (
  insert into nomad_commerce.shipping_templates (organization_id, name) values ('00000000-0000-0000-0000-00000000c00a', '기본') returning id) insert into zz_check.vals select 'stA', id::text from r;
select zz_check.fails_with($$insert into nomad_commerce.shipping_templates (organization_id, name, return_window_days) values ('00000000-0000-0000-0000-00000000c00a', 'x', 5)$$, '23514');
with r as (
  insert into nomad_commerce.listing_drafts (organization_id, product_id, market, shipping_template_id)
  values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'coupang', zz_check.v('stA')) returning id) insert into zz_check.vals select 'ldA', id::text from r;
-- 서버 컬럼·조직 이동·삭제(editor) 불가
select zz_check.denied($$update nomad_commerce.products set banned_words_found = '{x}'$$);
select zz_check.denied($$update nomad_commerce.products set organization_id = '00000000-0000-0000-0000-00000000c00b'$$);
select zz_check.denied($$update nomad_commerce.listing_drafts set status = 'ready'$$);
select zz_check.denied($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots) values ('00000000-0000-0000-0000-00000000c00a', gen_random_uuid(), 'persuasive', array['T-1','D-1','L-3'])$$);
select zz_check.denied($$insert into nomad_commerce.banned_words (organization_id, word) values ('00000000-0000-0000-0000-00000000c00a', '편집자')$$);
delete from nomad_commerce.products where id = zz_check.v('pA2');
select zz_check.expect('select count(*) from nomad_commerce.products', 2);
-- 소프트 삭제 시각은 now() 강제(과거 값 무시)
update nomad_commerce.products set deleted_at = '2000-01-01' where id = zz_check.v('pA2');
select zz_check.expect($$select count(*) from nomad_commerce.products where id = zz_check.v('pA2') and deleted_at = now()$$, 1);
update nomad_commerce.products set deleted_at = '2001-01-01' where id = zz_check.v('pA2');
select zz_check.expect($$select count(*) from nomad_commerce.products where id = zz_check.v('pA2') and deleted_at = now()$$, 1);
update nomad_commerce.products set deleted_at = null where id = zz_check.v('pA2');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_commerce.products', 2);
select zz_check.denied($$insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00a', 'viewer')$$);
select zz_check.expect($$with u as (update nomad_commerce.products set title = 'v' returning 1) select count(*) from u$$, 0);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
insert into nomad_commerce.banned_words (organization_id, word, category) values ('00000000-0000-0000-0000-00000000c00a', '기적의', 'general');
-- 기본 사전 FAIL 단어는 조직 행으로 낮출 수 없다(일반 조직 단어는 낮출 수 있다)
insert into nomad_commerce.banned_words (organization_id, word, category, severity, is_active) values ('00000000-0000-0000-0000-00000000c00a', '치료', 'general', 'warn', false);
select zz_check.expect($$select count(*) from nomad_commerce.banned_words where organization_id is not null and word = '치료' and severity = 'fail' and is_active$$, 1);
update nomad_commerce.banned_words set severity = 'warn', is_active = false where organization_id is not null and word = '치료';
select zz_check.expect($$select count(*) from nomad_commerce.banned_words where organization_id is not null and word = '치료' and severity = 'fail' and is_active$$, 1);
update nomad_commerce.banned_words set severity = 'warn' where organization_id is not null and word = '기적의';
select zz_check.expect($$select count(*) from nomad_commerce.banned_words where organization_id is not null and word = '기적의' and severity = 'warn'$$, 1);
select zz_check.denied($$insert into nomad_commerce.banned_words (organization_id, word) values (null, '전역')$$);
select zz_check.expect($$with u as (update nomad_commerce.banned_words set note = 'x' where organization_id is null returning 1) select count(*) from u$$, 0);
reset role;

-- ==== 4. 조직 B owner(C) · 비멤버: 교차 접근 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_commerce.products', 0);
select zz_check.expect('select count(*) from nomad_commerce.listing_drafts', 0);
select zz_check.expect('select count(*) from nomad_commerce.shipping_templates', 0);
select zz_check.expect('select count(*) from nomad_commerce.banned_words where organization_id is not null', 0);
select zz_check.expect('select count(*) from nomad_commerce.banned_words where organization_id is null', 21);
select zz_check.denied($$insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00a', 'x')$$);
select zz_check.expect($$with u as (update nomad_commerce.products set title = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (delete from nomad_commerce.products returning 1) select count(*) from u$$, 0);
with r as (
  insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00b', 'B 상품') returning id) insert into zz_check.vals select 'pB1', id::text from r;
-- 다른 조직 상품 참조 23503
select zz_check.fails_with($$insert into nomad_commerce.listing_drafts (organization_id, product_id, market) values ('00000000-0000-0000-0000-00000000c00b', zz_check.v('pA1'), 'coupang')$$, '23503');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c4","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_commerce.products', 0);
select zz_check.expect('select count(*) from nomad_commerce.detail_pages', 0);
reset role;

-- ==== 5. 상품 한도(C 2) · 복원 시 재검사 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated"}', true);
with r as (
  insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00b', 'B 상품2') returning id) insert into zz_check.vals select 'pB2', id::text from r;
select zz_check.fails_with($$insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00b', 'B 3')$$, 'CM002');
update nomad_commerce.products set deleted_at = now() where id = zz_check.v('pB2');
insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00b', 'B 3');
select zz_check.fails_with($$update nomad_commerce.products set deleted_at = null where id = zz_check.v('pB2')$$, 'CM002');
reset role;

-- ==== 6. 서버: 마켓 계정 자격(조직·제공자·폐기) · 슬롯 한도(키 없음 = 1) ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$insert into nomad_commerce.market_accounts (organization_id, market, slot_no, label, credential_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', 1, 'x', '00000000-0000-0000-0000-00000000cc03')$$, 'CM006');
select zz_check.fails_with($$insert into nomad_commerce.market_accounts (organization_id, market, slot_no, label, credential_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', 1, 'x', '00000000-0000-0000-0000-00000000cc02')$$, 'CM006');
select zz_check.fails_with($$insert into nomad_commerce.market_accounts (organization_id, market, slot_no, label, credential_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', 1, 'x', '00000000-0000-0000-0000-00000000cc05')$$, 'CM006');
with r as (
  insert into nomad_commerce.market_accounts (organization_id, market, slot_no, label, credential_id)
  values ('00000000-0000-0000-0000-00000000c00a', 'coupang', 1, 'A 쿠팡', '00000000-0000-0000-0000-00000000cc01') returning id) insert into zz_check.vals select 'maA', id::text from r;
select zz_check.fails_with($$insert into nomad_commerce.market_accounts (organization_id, market, slot_no, label, credential_id) values ('00000000-0000-0000-0000-00000000c00a', 'smartstore', 1, 'y', '00000000-0000-0000-0000-00000000cc02')$$, 'CM003');
with r as (
  insert into nomad_commerce.market_accounts (organization_id, market, slot_no, label, credential_id, status)
  values ('00000000-0000-0000-0000-00000000c00a', 'gmarket', 1, 'A 지마켓', '00000000-0000-0000-0000-00000000cc04', 'disabled') returning id) insert into zz_check.vals select 'maG', id::text from r;
-- 재활성화도 슬롯 한도
select zz_check.fails_with($$update nomad_commerce.market_accounts set status = 'active' where id = zz_check.v('maG')$$, 'CM003');
reset role;
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('commerce', 'B', 'market_slots', 3);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
update nomad_commerce.market_accounts set status = 'active' where id = zz_check.v('maG');

-- ==== 7. 서버: 상세페이지 · 크레딧·잡 참조 · 결과 전달 ====
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000c00a', 100, 'test', 'zz:grant:a', 'commerce');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000c00b', 100, 'test', 'zz:grant:b', 'commerce');
insert into zz_check.vals select 'lgA1', ledger_id::text from nomad_core.consume_credits('00000000-0000-0000-0000-00000000c00a', 9, 'detail', 'consume:commerce:r1', 'commerce');
insert into zz_check.vals select 'lgA2', ledger_id::text from nomad_core.consume_credits('00000000-0000-0000-0000-00000000c00a', 9, 'detail', 'consume:commerce:r2', 'commerce');
insert into zz_check.vals select 'lgB1', ledger_id::text from nomad_core.consume_credits('00000000-0000-0000-0000-00000000c00b', 9, 'detail', 'consume:commerce:rb', 'commerce');
insert into zz_check.vals select 'jA1', (nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000c00a', p_product => 'commerce',
  p_job_type => 'detail.generate', p_queue => 'commerce.detail', p_credit_ledger_id => zz_check.v('lgA1'), p_idempotency_key => 'job:commerce:r1')).id::text;
insert into zz_check.vals select 'jA2', (nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000c00a', p_product => 'commerce',
  p_job_type => 'detail.generate', p_queue => 'commerce.detail', p_credit_ledger_id => zz_check.v('lgA2'), p_idempotency_key => 'job:commerce:r2')).id::text;
insert into zz_check.vals select 'jB1', (nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000c00b', p_product => 'commerce',
  p_job_type => 'detail.generate', p_queue => 'commerce.detail', p_credit_ledger_id => zz_check.v('lgB1'), p_idempotency_key => 'job:commerce:rb')).id::text;
-- 다른 조직의 잡·원장 참조 CM010, 필수 슬롯 23514, 잘못된 초기 상태 CM001
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, job_id) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3'], zz_check.v('jB1'))$$, 'CM010');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, credit_ledger_id) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3'], zz_check.v('lgB1'))$$, 'CM010');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1'])$$, '23514');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, status) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3'], 'ready')$$, 'CM001');
-- B(C 플랜)는 15슬롯·확장 유형 불가
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slot_set, slots) values ('00000000-0000-0000-0000-00000000c00b', zz_check.v('pB1'), 'persuasive', 15, zz_check.s15())$$, 'CM007');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots) values ('00000000-0000-0000-0000-00000000c00b', zz_check.v('pB1'), 'informative', array['T-1','D-1','L-3'])$$, 'CM007');
-- A(B 플랜): 15슬롯 정보형 생성 → ready(잡 전달 표시)
with r as (
  insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slot_set, slots, credits_charged, credit_ledger_id, job_id)
  values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'informative', 15, zz_check.s15(), 9, zz_check.v('lgA1'), zz_check.v('jA1')) returning id) insert into zz_check.vals select 'dA1', id::text from r;
update nomad_commerce.detail_pages set status = 'queued' where id = zz_check.v('dA1');
update nomad_commerce.detail_pages set status = 'generating' where id = zz_check.v('dA1');
select zz_check.fails_with($$update nomad_commerce.detail_pages set status = 'waiting' where id = zz_check.v('dA1')$$, 'CM001');
update nomad_commerce.detail_pages set status = 'ready', compliance_verdict = 'warn' where id = zz_check.v('dA1');
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.v('jA1') and not refund_on_failure$$, 1);
-- 잡이 취소(= 환불)된 페이지는 결과 저장 거부 55000
with r as (
  insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, credits_charged, credit_ledger_id, job_id)
  values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3'], 9, zz_check.v('lgA2'), zz_check.v('jA2')) returning id) insert into zz_check.vals select 'dA2', id::text from r;
update nomad_commerce.detail_pages set status = 'queued' where id = zz_check.v('dA2');
update nomad_commerce.detail_pages set status = 'generating' where id = zz_check.v('dA2');
select nomad_core.cancel_job(zz_check.v('jA2'));
select zz_check.fails_with($$update nomad_commerce.detail_pages set status = 'ready' where id = zz_check.v('dA2')$$, '55000');
update nomad_commerce.detail_pages set status = 'failed' where id = zz_check.v('dA2');
-- 내보내기: 다른 조직 대상 CM010
select zz_check.fails_with($$insert into nomad_commerce.export_files (organization_id, kind, product_ids) values ('00000000-0000-0000-0000-00000000c00a', 'zip_images', array[zz_check.v('pB1')])$$, 'CM010');
insert into nomad_commerce.export_files (organization_id, kind, product_ids) values ('00000000-0000-0000-0000-00000000c00a', 'excel_playauto', array[zz_check.v('pA1')]);
select zz_check.fails_with($$insert into nomad_commerce.export_files (organization_id, kind) values ('00000000-0000-0000-0000-00000000c00b', 'excel_playauto')$$, 'CM007');
insert into nomad_commerce.export_files (organization_id, kind) values ('00000000-0000-0000-0000-00000000c00b', 'zip_images');
reset role;

-- ==== 8. 업로드 게이트: WARN 미확인 CM005 → 확인 RPC(editor) → 업로드 · FAIL CM004 · 플랜 미허용 마켓 CM007 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'), zz_check.v('dA1'))$$, 'CM005');
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'), zz_check.v('dA2'))$$, 'CM008');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c2","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_commerce.acknowledge_compliance_warning(zz_check.v('dA1'))$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c5","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_commerce.acknowledge_compliance_warning(zz_check.v('dA1'))$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c3","role":"authenticated"}', true);
select zz_check.expect($$select count(*) from nomad_commerce.acknowledge_compliance_warning(zz_check.v('dA1'), '확인') where warn_acknowledged_by = '00000000-0000-0000-0000-0000000000c3'$$, 1);
select zz_check.fails_with($$select nomad_commerce.acknowledge_compliance_warning(zz_check.v('dA2'))$$, 'CM008');
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'commerce.detail_page.compliance_warn_ack'$$, 1);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
with r as (
  insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id, idempotency_key)
  values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'), zz_check.v('dA1'), 'upload:r1') returning id) insert into zz_check.vals select 'upA', id::text from r;
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id, idempotency_key) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'), zz_check.v('dA1'), 'upload:r1')$$, '23505');
-- 상세페이지 없는 업로드 CM008(compliance 생략 금지)
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'))$$, 'CM008');
-- 이슈가 바뀌면 WARN 확인 초기화 → 업로드 CM005
update nomad_commerce.detail_pages set compliance_issues = '[{"code":"new"}]' where id = zz_check.v('dA1');
select zz_check.expect($$select count(*) from nomad_commerce.detail_pages where id = zz_check.v('dA1') and warn_acknowledged_at is null and warn_acknowledged_by is null$$, 1);
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'), zz_check.v('dA1'))$$, 'CM005');
-- 업로드 대상(계정·마켓·상세페이지)은 바꿀 수 없다 CM011
select zz_check.fails_with($$update nomad_commerce.market_uploads set market_account_id = zz_check.v('maG') where id = zz_check.v('upA')$$, 'CM011');
select zz_check.fails_with($$update nomad_commerce.market_uploads set market = 'gmarket' where id = zz_check.v('upA')$$, 'CM011');
select zz_check.fails_with($$update nomad_commerce.market_uploads set detail_page_id = zz_check.v('dA2') where id = zz_check.v('upA')$$, 'CM011');
update nomad_commerce.detail_pages set compliance_verdict = 'fail' where id = zz_check.v('dA1');
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id) values ('00000000-0000-0000-0000-00000000c00a', 'coupang', zz_check.v('maA'), zz_check.v('dA1'))$$, 'CM004');
update nomad_commerce.detail_pages set compliance_verdict = 'pass' where id = zz_check.v('dA1');
select zz_check.fails_with($$select nomad_commerce.acknowledge_compliance_warning(zz_check.v('dA1'))$$, 'CM009');
-- gmarket 은 어느 플랜에도 없음 → CM007. 수동 이용권으로 열고 등록 → 실패 → 이용권 회수 뒤 재시도(기존 행) CM007
select zz_check.fails_with($$insert into nomad_commerce.market_uploads (organization_id, market, market_account_id) values ('00000000-0000-0000-0000-00000000c00a', 'gmarket', zz_check.v('maG'))$$, 'CM007');
reset role;
insert into nomad_core.features (product_code, code, name) values ('commerce', 'market_api_gmarket', 'zz 검사용') on conflict do nothing;
insert into nomad_core.feature_grants (organization_id, product_code, feature_code, source) values
  ('00000000-0000-0000-0000-00000000c00a', 'commerce', 'market_api_gmarket', 'manual');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
with r as (
  insert into nomad_commerce.market_uploads (organization_id, market, market_account_id, detail_page_id) values ('00000000-0000-0000-0000-00000000c00a', 'gmarket', zz_check.v('maG'), zz_check.v('dA1')) returning id) insert into zz_check.vals select 'upG', id::text from r;
update nomad_commerce.market_uploads set status = 'failed' where id = zz_check.v('upG');
reset role;
update nomad_core.feature_grants set revoked_at = now() where feature_code = 'market_api_gmarket';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$update nomad_commerce.market_uploads set status = 'queued' where id = zz_check.v('upG')$$, 'CM007');
-- 쿠팡 업로드 실패 → 자격 폐기 → 재시도 CM006(사용 시점 재확인)
update nomad_commerce.market_uploads set status = 'failed' where id = zz_check.v('upA');
update nomad_commerce.market_uploads set status = 'queued' where id = zz_check.v('upA');
update nomad_commerce.market_uploads set status = 'failed' where id = zz_check.v('upA');
select nomad_core.revoke_provider_credential('00000000-0000-0000-0000-00000000cc01');
select zz_check.fails_with($$update nomad_commerce.market_uploads set status = 'queued' where id = zz_check.v('upA')$$, 'CM006');
reset role;

-- ==== 9. 구독 끊김(만료·inactive) = C: 유료 기능 잠김(기존 실패 행 재시도 포함), 무료 기능·읽기는 유지, 재구독 시 풀림 ====
update nomad_core.subscriptions set ends_at = now() - interval '1 second', starts_at = now() - interval '1 day'
 where organization_id = '00000000-0000-0000-0000-00000000c00a' and product_code = 'commerce';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$insert into nomad_commerce.export_files (organization_id, kind) values ('00000000-0000-0000-0000-00000000c00a', 'excel_playauto')$$, 'CM007');
insert into nomad_commerce.export_files (organization_id, kind) values ('00000000-0000-0000-0000-00000000c00a', 'zip_images');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slot_set, slots) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', 15, array['T-1','D-1','L-3'])$$, 'CM007');
with r as (
  insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3']) returning id) insert into zz_check.vals select 'dA3', id::text from r;
reset role;
-- 기존 실패 행(dA2: 설득형 10슬롯)은 C 에서도 재시도 가능, 15슬롯 실패 행은 거부
update nomad_core.subscriptions set ends_at = null, status = 'active' where organization_id = '00000000-0000-0000-0000-00000000c00a' and product_code = 'commerce';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
with r as (
  insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slot_set, slots) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'emotional', 15, zz_check.s15()) returning id) insert into zz_check.vals select 'dA4', id::text from r;
update nomad_commerce.detail_pages set status = 'queued' where id = zz_check.v('dA4');
update nomad_commerce.detail_pages set status = 'failed' where id = zz_check.v('dA4');
reset role;
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000c00a' and product_code = 'commerce';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$update nomad_commerce.detail_pages set status = 'waiting' where id = zz_check.v('dA4')$$, 'CM007');
-- 상태와 무관하게 세트·유형 변경도 재검사(dA3: C 에서 만든 10슬롯 설득형)
select zz_check.fails_with($$update nomad_commerce.detail_pages set slot_set = 15 where id = zz_check.v('dA3')$$, 'CM007');
select zz_check.fails_with($$update nomad_commerce.detail_pages set page_type = 'informative' where id = zz_check.v('dA3')$$, 'CM007');
update nomad_commerce.detail_pages set status = 'waiting' where id = zz_check.v('dA2');
select zz_check.fails_with($$insert into nomad_commerce.export_files (organization_id, kind) values ('00000000-0000-0000-0000-00000000c00a', 'excel_playauto')$$, 'CM007');
reset role;
-- 읽기·무료 기능(상품 편집)은 유지. 한도는 C 값(상품 2)으로 내려간다 → 새 상품 CM002
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_commerce.products', 2);
update nomad_commerce.products set title = 'C 에서도 편집' where id = zz_check.v('pA1');
select zz_check.fails_with($$insert into nomad_commerce.products (organization_id, title) values ('00000000-0000-0000-0000-00000000c00a', 'x')$$, 'CM002');
reset role;
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000c00a' and product_code = 'commerce';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
update nomad_commerce.detail_pages set status = 'waiting' where id = zz_check.v('dA4');
insert into nomad_commerce.export_files (organization_id, kind) values ('00000000-0000-0000-0000-00000000c00a', 'excel_playauto');
reset role;

-- ==== 11. 보안 리뷰 반영: 슬롯 수 ≤ 세트 · 멱등 키 조직 범위 · 전달된 잡의 archived→ready 복원 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slot_set, slots) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', 10, zz_check.s15())$$, '23514');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slot_set, slots) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', 15, zz_check.s18())$$, '23514');
select zz_check.fails_with($$update nomad_commerce.detail_pages set slots = zz_check.s15() where id = zz_check.v('dA3')$$, '23514');
insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, request_id) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3'], '00000000-0000-0000-0000-0000000000f1');
select zz_check.fails_with($$insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, request_id) values ('00000000-0000-0000-0000-00000000c00a', zz_check.v('pA1'), 'persuasive', array['T-1','D-1','L-3'], '00000000-0000-0000-0000-0000000000f1')$$, '23505');
insert into nomad_commerce.detail_pages (organization_id, product_id, page_type, slots, request_id) values ('00000000-0000-0000-0000-00000000c00b', zz_check.v('pB1'), 'persuasive', array['T-1','D-1','L-3'], '00000000-0000-0000-0000-0000000000f1');
select zz_check.expect($$select count(*) from pg_indexes where schemaname = 'nomad_commerce' and indexdef ~ 'UNIQUE.*\(organization_id, (idempotency_key|request_id)\)'$$, 2);
select zz_check.expect($$select count(*) from pg_indexes where schemaname = 'nomad_commerce' and indexdef ~ 'UNIQUE.*\((idempotency_key|request_id)\)'$$, 0);
reset role;
-- dA1 의 잡은 전달 후(refund_on_failure false) 실패 = 환불 없음 → archived→ready 복원 허용(환불된 잡 jA2 는 7절에서 55000)
update nomad_core.jobs set status = 'failed', finished_at = now() where id = zz_check.v('jA1');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
update nomad_commerce.detail_pages set status = 'archived' where id = zz_check.v('dA1');
update nomad_commerce.detail_pages set status = 'ready' where id = zz_check.v('dA1');
select zz_check.expect($$select count(*) from nomad_commerce.detail_pages where id = zz_check.v('dA1') and status = 'ready'$$, 1);
reset role;

-- ==== 10. 회귀: 권한·RLS·core 직접 쓰기 0·core 표 트리거 0·라우팅 시드(0002) ====
select zz_check.expect($$select has_schema_privilege('anon', 'nomad_commerce', 'usage')::int$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_commerce' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_commerce' and c.relkind = 'r'$$, 13);
select zz_check.expect($$select count(*) from information_schema.role_table_grants
  where table_schema = 'nomad_commerce' and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from information_schema.role_table_grants
  where table_schema = 'nomad_commerce' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
    and table_name not in ('products', 'shipping_templates', 'listing_drafts', 'banned_words')$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges
  where table_schema = 'nomad_commerce' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE')
    and table_name not in ('products', 'shipping_templates', 'listing_drafts', 'banned_words')$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_commerce', 'nomad_commerce_private')
    and p.prosrc ~* '(update|insert into|delete from)\s+nomad_core\.'$$, 0);
select zz_check.expect($$select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace
  where n.nspname = 'nomad_core' and pn.nspname in ('nomad_commerce', 'nomad_commerce_private')$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_commerce', 'nomad_commerce_private') and p.prosecdef
    and not coalesce(array_to_string(p.proconfig, ',') like '%search_path=""%', false)$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_commerce', 'nomad_commerce_private') and has_function_privilege('authenticated', p.oid, 'execute')$$, 1);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'commerce'$$, 14);
