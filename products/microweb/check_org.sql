-- Microweb org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · anon 테이블 접근 0 · 공개 RPC(D8)·한도 · 게시 흐름(대행·셀프 크레딧) ·
-- 하객 쓰기(service_role) · 음성 연결 · 구독 끊김 잠김 · 만료 · 함수/테이블 권한. 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/microweb/run_check.sh   (begin → 청사진 drop → 임시 touch_updated_at → org/0001·0002 → 이 파일 → rollback)

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
create function zz_check.eq(q text, want text) returns void language plpgsql as $$
declare r text; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT [%] got [%] for %', want, r, q; end if; end $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer, 대행 모드), 조직 B(u2 owner, 셀프 모드, 활성 사이트 1) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
-- 구독이 끊기면 잠기므로(C에 studio 없음) 두 조직 모두 B 구독
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'microweb', 'B', 'active'), ('00000000-0000-0000-0000-00000000000b', 'microweb', 'B', 'active');
insert into nomad_microweb.studio_access (organization_id, mode, max_active_sites) values
  ('00000000-0000-0000-0000-00000000000a', 'agency', 3), ('00000000-0000-0000-0000-00000000000b', 'self_service', 1);

create temp table t_ids (k text primary key, id uuid);
create temp table t_tok (token text);
grant all on t_ids, t_tok to public;

-- ==== 0. 방문자(anon): 테이블 직접 접근 0, 서버 함수 거부 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_microweb.templates');
select zz_check.denied('select count(*) from nomad_microweb.portfolio_items');
select zz_check.denied('select count(*) from nomad_microweb.studio_access');
select zz_check.denied('select count(*) from nomad_microweb.sites');
select zz_check.denied('select count(*) from nomad_microweb.site_publications');
select zz_check.denied('select count(*) from nomad_microweb.site_assets');
select zz_check.denied('select count(*) from nomad_microweb.guestbook_entries');
select zz_check.denied('select count(*) from nomad_microweb.rsvp_responses');
select zz_check.denied('select count(*) from nomad_microweb.leads');
select zz_check.denied('select count(*) from nomad_microweb.production_orders');
select zz_check.denied($$insert into nomad_microweb.guestbook_entries (organization_id, site_id, author_name, body, ip_hash) values ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 'x', 'x', repeat('x', 32))$$);
select zz_check.denied($$select * from nomad_microweb.submit_guestbook_entry('minsu-jieun', 'x', 'x', null, false, repeat('x', 32))$$);
select zz_check.denied($$select * from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000a', 'contact_form', 'x', '010-1234-5678', null, null, null, null, null, null, null, null, true, repeat('x', 32))$$);
select zz_check.denied($$select nomad_microweb.is_site_live(gen_random_uuid())$$);
select zz_check.denied($$select nomad_microweb.has_studio_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_microweb.expire_sites()$$);
select zz_check.denied($$select nomad_core.rate_limit_take('microweb:x', 1, 60)$$);
select zz_check.denied('select * from nomad_core.rate_limit_buckets');
reset role;

-- ==== 1. 사이트 생성: 역할·템플릿·활성 상한 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'wedding_classic', '민수 지은 결혼합니다', 'Minsu-Jieun', now() + interval '30 days');
select zz_check.fails_with($$select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'dol_basic', 'X', 'dol-x')$$, 'MW004');
select zz_check.fails_with($$select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'wedding_classic', 'X', 'admin')$$, 'sites_slug_reserved_check');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'wedding_classic', '두 번째', 'a-second', now() + interval '60 days');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'wedding_classic', 'V', 'viewer-site')$$, 'role');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'wedding_classic', 'E', 'evil-site')$$, 'role');
select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000b', 'wedding_classic', 'B 청첩장', 'b-site', now() + interval '20 days');
select zz_check.fails_with($$select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000b', 'wedding_classic', 'B2', 'b-site-two')$$, 'MW005');
reset role;
select set_config('request.jwt.claims', '', true);
insert into t_ids select 'site_a', id from nomad_microweb.sites where slug = 'minsu-jieun';
insert into t_ids select 'site_a2', id from nomad_microweb.sites where slug = 'a-second';
insert into t_ids select 'site_b', id from nomad_microweb.sites where slug = 'b-site';
select zz_check.expect($$select count(*) from nomad_microweb.sites where status = 'draft' and expires_at is not null$$, 3);

-- ==== 2. 조직 B(u2) 시점: 조직 A 전부 안 보이고 쓰기 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_microweb.sites', 1);
select zz_check.expect($$select count(*) from nomad_microweb.sites where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
update nomad_microweb.sites set title = 'hacked' where id = (select id from t_ids where k = 'site_a');
select zz_check.fails_with($$select nomad_microweb.transition_site((select id from t_ids where k = 'site_a'), 'review')$$, 'role');
select zz_check.fails_with($$select nomad_microweb.confirm_disclosure_consent((select id from t_ids where k = 'site_a'), 'self')$$, 'role');
select zz_check.fails_with($$select nomad_microweb.issue_preview_token((select id from t_ids where k = 'site_a'))$$, 'role');
select zz_check.fails_with($$select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', 'X', 1000, 'evil')$$, 'role');
select zz_check.denied($$insert into nomad_microweb.sites (organization_id, template_id, kind, slug, title) select '00000000-0000-0000-0000-00000000000b', id, kind, 'direct-ins', 'D' from nomad_microweb.templates limit 1$$);
select zz_check.denied($$update nomad_microweb.sites set status = 'published'$$);
select zz_check.denied($$update nomad_microweb.sites set organization_id = '00000000-0000-0000-0000-00000000000a'$$);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_microweb.sites where title = 'hacked'$$, 0);

-- ==== 3. 대행 게시 흐름(조직 A): 동의 → 시안 토큰 → 결제 주문(멱등) → 고객 승인 → 게시 요청 → 완료 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_microweb.confirm_disclosure_consent((select id from t_ids where k = 'site_a'), 'self');
insert into t_tok select nomad_microweb.issue_preview_token((select id from t_ids where k = 'site_a'), 48);
select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', '김민수', 150000, 'ord-1', 'wedding_classic', 'pro', null, (select id from t_ids where k = 'site_a'));
-- 같은 키 재호출 = 같은 행, 다른 금액 = 거부
select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', '김민수', 150000, 'ord-1', 'wedding_classic', 'pro', null, (select id from t_ids where k = 'site_a'));
select zz_check.fails_with($$select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', '김민수', 1, 'ord-1', 'wedding_classic', 'pro', null, (select id from t_ids where k = 'site_a'))$$, 'idempotency key reused');
select zz_check.fails_with($$select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', '김민수', 1000, null)$$, 'idempotency key required');
select zz_check.fails_with($$select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', '김민수', 1000, 'ord-x', null, null, null, (select id from t_ids where k = 'site_b'))$$, 'site not in organization');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect('select count(*) from nomad_microweb.production_orders', 1);
insert into t_ids select 'order_a', id from nomad_microweb.production_orders where idempotency_key = 'ord-1';
-- 서버: 결제 주문 없음 → MW008
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_a'), '00000000-0000-0000-0000-0000000000a1')$$, 'MW008');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_microweb.transition_order((select id from t_ids where k = 'order_a'), 'paid', 'bank_transfer')$$, 'role');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_microweb.transition_order((select id from t_ids where k = 'order_a'), 'paid')$$, 'payment_method required');
select zz_check.fails_with($$select nomad_microweb.transition_order((select id from t_ids where k = 'order_a'), 'paid', 'bank_transfer', '1234567890123456')$$, 'production_orders_reference_check');
select nomad_microweb.transition_order((select id from t_ids where k = 'order_a'), 'paid', 'bank_transfer', 'REF-1');
create temp table t_paid as select paid_at from nomad_microweb.production_orders where id = (select id from t_ids where k = 'order_a');
select nomad_microweb.transition_order((select id from t_ids where k = 'order_a'), 'paid', 'other', 'REF-2');
select zz_check.expect($$select count(*) from nomad_microweb.production_orders o, t_paid p where o.paid_at = p.paid_at and o.payment_reference = 'REF-1'$$, 1);
select zz_check.fails_with($$select nomad_microweb.transition_order((select id from t_ids where k = 'order_a'), 'closed')$$, 'MW001');
-- 주문 1건당 사이트 1개: 같은 사이트 재호출은 통과, 다른 사이트로 바꾸기는 거부
select nomad_microweb.attach_order_site((select id from t_ids where k = 'order_a'), (select id from t_ids where k = 'site_a'));
select zz_check.fails_with($$select nomad_microweb.attach_order_site((select id from t_ids where k = 'order_a'), (select id from t_ids where k = 'site_a2'))$$, 'order already has a site');
select zz_check.eq($$select nomad_microweb.studio_access_detail('00000000-0000-0000-0000-00000000000a') ->> 'mode'$$, 'agency');
select zz_check.denied('select note from nomad_microweb.studio_access');
reset role;
-- 고객 승인 전 MW009 → 승인 → editor 행위자 거부 → owner 게시 요청
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_a'), '00000000-0000-0000-0000-0000000000a1')$$, 'MW009');
select zz_check.fails_with($$select nomad_microweb.record_customer_approval('deadbeef', '김민수')$$, 'MW013');
select nomad_microweb.record_customer_approval((select encode(extensions.digest(token, 'sha256'), 'hex') from t_tok), '김민수');
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_a'), '00000000-0000-0000-0000-0000000000a3')$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_a'), '00000000-0000-0000-0000-0000000000a2')$$, 'owner/admin only');
select nomad_microweb.request_publish((select id from t_ids where k = 'site_a'), '00000000-0000-0000-0000-0000000000a1');
reset role;
-- publishing 중에는 사용자 편집 잠금(MW003)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$update nomad_microweb.sites set title = 'during publish' where id = (select id from t_ids where k = 'site_a')$$, 'MW003');
select zz_check.fails_with($$select nomad_microweb.transition_site((select id from t_ids where k = 'site_a'), 'draft')$$, 'MW003');
reset role;
select set_config('request.jwt.claims', '', true);
insert into t_ids select 'job_a', (nomad_core.enqueue_job('00000000-0000-0000-0000-00000000000a', 'microweb', 'site.publish')).id;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_microweb.finalize_publish((select id from t_ids where k = 'site_a'), (select id from t_ids where k = 'job_a'),
  '{"blocks":[{"type":"hero"}]}', '민수 지은 결혼합니다', null, 'https://cdn.example.test/og.webp');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_microweb.sites where slug = 'minsu-jieun' and status = 'published' and first_published_at is not null and publish_job_id is not null$$, 1);
select zz_check.expect($$select count(*) from nomad_microweb.site_publications where slug = 'minsu-jieun' and is_live and version = 1$$, 1);
-- 첫 게시 뒤 슬러그 잠금(MW002, 서버도)
select zz_check.fails_with($$update nomad_microweb.sites set slug = 'new-slug' where slug = 'minsu-jieun'$$, 'MW002');
-- 서버도 상태 전이 규칙을 따른다(published → archived 불가)
select zz_check.fails_with($$update nomad_microweb.sites set status = 'archived' where slug = 'minsu-jieun'$$, 'MW001');

-- ==== 4. 셀프 게시(조직 B): 이 사이트용 microweb consume 원장이 있어야 한다 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select nomad_microweb.confirm_disclosure_consent((select id from t_ids where k = 'site_b'), 'written');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_b'), '00000000-0000-0000-0000-0000000000a2')$$, 'MW008');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000b', 100, 'test pack', 'grant-b-1', 'microweb');
insert into t_ids select 'ledger_wrong', ledger_id from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000b', 20, 'publish', 'pub-wrong', 'microweb', 'other_use', null);
insert into t_ids select 'ledger_b', ledger_id from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000b', 20, 'publish', 'pub-b-1', 'microweb', 'microweb_publish', (select id::text from t_ids where k = 'site_b'));
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_b'), '00000000-0000-0000-0000-0000000000a2', (select id from t_ids where k = 'ledger_wrong'))$$, 'MW008');
-- 템플릿 셀프 발행 단가 미정(null) → 거부
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_b'), '00000000-0000-0000-0000-0000000000a2', (select id from t_ids where k = 'ledger_b'))$$, 'below template price');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_microweb.templates set self_publish_credits = 20 where code = 'wedding_classic';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
-- 단가보다 적게 차감한 원장 → 거부
insert into t_ids select 'ledger_low', ledger_id from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000b', 5, 'publish', 'pub-b-low', 'microweb', 'microweb_publish', (select id::text from t_ids where k = 'site_b'));
select zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_b'), '00000000-0000-0000-0000-0000000000a2', (select id from t_ids where k = 'ledger_low'))$$, 'below template price');
select nomad_microweb.request_publish((select id from t_ids where k = 'site_b'), '00000000-0000-0000-0000-0000000000a2', (select id from t_ids where k = 'ledger_b'));
select nomad_microweb.finalize_publish((select id from t_ids where k = 'site_b'), null, '{"blocks":[]}');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_microweb.sites where slug = 'b-site' and status = 'published' and publish_charged_at is not null and publish_ledger_id = (select id from t_ids where k = 'ledger_b')$$, 1);

-- ==== 5. 공개 RPC(anon): 게시 중 스냅샷·카탈로그·방명록만, 입력 검증 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.eq($$select nomad_microweb.get_public_site(' MINSU-JIEUN ') -> 'site' ->> 'slug'$$, 'minsu-jieun');
select zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'rsvp_open'$$, 'false');
select zz_check.expect($$select (nomad_microweb.get_public_site('minsu-jieun') -> 'site' ? 'organization_id')::int$$, 0);
select zz_check.eq($$select nomad_microweb.get_public_site('a-second') ->> 'code'$$, 'not_found');
select zz_check.eq($$select nomad_microweb.get_public_site('no-such-site') ->> 'code'$$, 'not_found');
select zz_check.eq($$select nomad_microweb.get_public_site('x') ->> 'code'$$, 'invalid');
select zz_check.eq($$select nomad_microweb.get_public_site(null) ->> 'code'$$, 'invalid');
select zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_templates() -> 'templates')$$, 12);
select zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_portfolio() -> 'items')$$, 0);
select zz_check.eq($$select nomad_microweb.list_public_portfolio('bogus') ->> 'code'$$, 'invalid');
select zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_guestbook('minsu-jieun') -> 'entries')$$, 0);
reset role;

-- ==== 6. 하객 쓰기(service_role, Route Handler 가 IP 해시 계산): 방명록·RSVP·견적 문의 + 한도 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '친구1', '축하해 첫 번째', 'friend', false, repeat('a', 32))$$, 'ok');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '친구2', '축하해 두 번째', 'friend', true, repeat('a', 32))$$, 'ok');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '친구3', '축하해 세 번째', null, false, repeat('a', 32))$$, 'ok');
-- 같은 IP 해시 10분 3건 초과 → rate_limited (raise 아님: 카운터가 쌓인다)
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '친구4', '축하해 네 번째', null, false, repeat('a', 32))$$, 'rate_limited');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '스팸', 'visit https://spam.example.test', null, false, repeat('b', 32))$$, 'spam');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', repeat('긴', 21), '이름이 너무 길다', null, false, repeat('c', 32))$$, 'invalid');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '짧은해시', '본문', null, false, 'short')$$, 'invalid');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('a-second', '미게시', '본문', null, false, repeat('d', 32))$$, 'closed');
select zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('b-site', 'B하객', 'B 축하', null, false, repeat('e', 32))$$, 'ok');
-- RSVP 는 사이트 스위치가 꺼져 있으면 closed
select zz_check.eq($$select result from nomad_microweb.submit_rsvp('minsu-jieun', '하객', 'side_a', 'yes', 2, 'yes', null, repeat('f', 32))$$, 'closed');
-- 견적 문의: 대행 모드 조직만, 동의 필수
select zz_check.eq($$select result from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000a', 'contact_form', '문의자', '010-1234-5678', null, 'wedding', 'wedding_classic', 'pro', null, null, null, '견적 부탁드립니다', true, repeat('g', 32))$$, 'ok');
select zz_check.eq($$select result from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000a', 'contact_form', '문의자2', null, 'Q@Example.test', null, null, null, null, null, null, null, false, repeat('h', 32))$$, 'invalid');
select zz_check.eq($$select result from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000a', 'contact_form', '형식오류', '010-1234-5678', null, null, 'Bad Code!', null, null, null, null, null, true, repeat('m', 32))$$, 'invalid');
select zz_check.eq($$select result from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000a', 'contact_form', '연락처없음', null, null, null, null, null, null, null, null, null, true, repeat('i', 32))$$, 'invalid');
select zz_check.eq($$select result from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000b', 'contact_form', 'B문의', '010-1234-5678', null, null, null, null, null, null, null, null, true, repeat('j', 32))$$, 'closed');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count::bigint from nomad_core.rate_limit_buckets where key = 'microweb:gb:ip:' || repeat('a', 32) || ':' || (select id from t_ids where k = 'site_a')::text$$, 4);
select zz_check.expect($$select count(*) from nomad_microweb.guestbook_entries where site_id = (select id from t_ids where k = 'site_a')$$, 3);
insert into t_ids select 'gb1', id from nomad_microweb.guestbook_entries where body = '축하해 첫 번째';
insert into t_ids select 'gb2', id from nomad_microweb.guestbook_entries where body = '축하해 두 번째';
insert into t_ids select 'lead_a', id from nomad_microweb.leads where name = '문의자';
-- owner 가 RSVP 를 켜면(컬럼 GRANT 직접 수정) 접수 → 공개 스냅샷의 rsvp_open 도 true
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
update nomad_microweb.sites set rsvp_enabled = true where id = (select id from t_ids where k = 'site_a');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.eq($$select result from nomad_microweb.submit_rsvp('minsu-jieun', '하객', 'side_a', 'yes', 2, 'yes', '꼭 갈게요', repeat('f', 32))$$, 'ok');
select zz_check.eq($$select result from nomad_microweb.submit_rsvp('minsu-jieun', '하객', 'side_a', 'maybe', 2, null, null, repeat('k', 32))$$, 'invalid');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'rsvp_open'$$, 'true');
select zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_guestbook('minsu-jieun') -> 'entries')$$, 3);
select zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_guestbook('minsu-jieun', null, 2) -> 'entries')$$, 2);
select zz_check.expect($$select (nomad_microweb.list_public_guestbook('minsu-jieun') -> 'entries' -> 0 ? 'ip_hash')::int$$, 0);
reset role;

-- ==== 7. 공개 읽기 RPC 는 DB 요청 제한을 하지 않는다(사이트·slug 키 = anon 한 명이 남의 청첩장을 닫는 수단). 과부하는 CDN·WAF 몫 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$ begin
  for i in 1..50 loop
    perform nomad_microweb.get_public_site('minsu-jieun');
    perform nomad_microweb.get_public_site('missing-' || i);
    perform nomad_microweb.list_public_guestbook('minsu-jieun');
    perform nomad_microweb.list_public_templates();
    perform nomad_microweb.list_public_portfolio();
  end loop;
end $$;
select zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'slug'$$, 'minsu-jieun');
select zz_check.eq($$select nomad_microweb.list_public_guestbook('minsu-jieun') ->> 'ok'$$, 'true');
reset role;
select set_config('request.jwt.claims', '', true);
-- 읽기 키가 하나도 없다(없는 slug 50개도 행을 만들지 않는다). 쓰기 키(gb·rsvp·lead)는 그대로 있다
select zz_check.expect($$select count(*) from nomad_core.rate_limit_buckets where key like 'microweb:pub:%'$$, 0);
select zz_check.expect($$select (count(*) > 0)::int from nomad_core.rate_limit_buckets where key like 'microweb:gb:%'$$, 1);
select zz_check.expect($$select (count(*) > 0)::int from nomad_core.rate_limit_buckets where key like 'microweb:rsvp:%'$$, 1);
select zz_check.expect($$select (count(*) > 0)::int from nomad_core.rate_limit_buckets where key like 'microweb:lead:%'$$, 1);

-- ==== 8. 역할: viewer 는 개인정보 표 0건·수정 불가, editor 는 콘텐츠·문의 상태, owner 만 삭제 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_microweb.sites', 2);
select zz_check.expect('select count(*) from nomad_microweb.guestbook_entries', 3);
select zz_check.expect('select count(*) from nomad_microweb.leads', 0);
select zz_check.expect('select count(*) from nomad_microweb.rsvp_responses', 0);
select zz_check.expect('select count(*) from nomad_microweb.production_orders', 0);
update nomad_microweb.sites set title = 'viewer edit' where id = (select id from t_ids where k = 'site_a2');
select zz_check.denied('select ip_hash from nomad_microweb.guestbook_entries');
select zz_check.denied('select voice_job_id from nomad_microweb.guestbook_entries');
select zz_check.fails_with($$select nomad_microweb.moderate_guestbook_entry((select id from t_ids where k = 'gb2'), 'hidden')$$, 'role');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_microweb.leads', 1);
select zz_check.expect('select count(*) from nomad_microweb.rsvp_responses', 1);
select zz_check.denied('select ip_hash from nomad_microweb.leads');
select zz_check.denied('select ip_hash from nomad_microweb.rsvp_responses');
update nomad_microweb.sites set title = '두 번째 수정', content = '{"blocks":[]}' where id = (select id from t_ids where k = 'site_a2');
select zz_check.denied($$update nomad_microweb.sites set status = 'review' where id = (select id from t_ids where k = 'site_a2')$$);
select zz_check.denied($$update nomad_microweb.sites set publish_charged_at = now() where id = (select id from t_ids where k = 'site_a2')$$);
select zz_check.fails_with($$update nomad_microweb.sites set expires_at = now() - interval '1 day' where id = (select id from t_ids where k = 'site_a2')$$, 'expires_at must be in the future');
select nomad_microweb.transition_site((select id from t_ids where k = 'site_a2'), 'review');
select zz_check.fails_with($$select nomad_microweb.transition_site((select id from t_ids where k = 'site_a2'), 'archived')$$, 'role');
select zz_check.fails_with($$select nomad_microweb.transition_site((select id from t_ids where k = 'site_a2'), 'published')$$, 'MW001');
-- definer 반환값에 숨김 컬럼(ip_hash·voice_job_id·moderated_by) 없음
select zz_check.expect($$select (nomad_microweb.moderate_guestbook_entry((select id from t_ids where k = 'gb2'), 'hidden') ?| array['ip_hash', 'voice_job_id', 'moderated_by'])::int$$, 0);
select zz_check.expect($$select (nomad_microweb.set_lead_status((select id from t_ids where k = 'lead_a'), 'contacted', '전화함') ?| array['ip_hash'])::int$$, 0);
select zz_check.eq($$select nomad_microweb.moderate_guestbook_entry((select id from t_ids where k = 'gb2'), 'hidden') ->> 'status'$$, 'hidden');
-- 허용 목록 note·granted_by 는 owner/admin RPC 만
select zz_check.denied('select note from nomad_microweb.studio_access');
select zz_check.denied('select granted_by from nomad_microweb.studio_access');
select zz_check.fails_with($$select nomad_microweb.studio_access_detail('00000000-0000-0000-0000-00000000000a')$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_microweb.set_lead_status((select id from t_ids where k = 'lead_a'), 'new')$$, 'MW001');
select zz_check.fails_with($$select nomad_microweb.delete_lead((select id from t_ids where k = 'lead_a'))$$, 'owner/admin only');
delete from nomad_microweb.guestbook_entries where id = (select id from t_ids where k = 'gb1');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_microweb.leads', 0);
select zz_check.expect('select count(*) from nomad_microweb.site_publications', 1);
select zz_check.fails_with($$select nomad_microweb.set_lead_status((select id from t_ids where k = 'lead_a'), 'quoted')$$, 'role');
select zz_check.fails_with($$select nomad_microweb.delete_lead((select id from t_ids where k = 'lead_a'))$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_microweb.moderate_guestbook_entry((select id from t_ids where k = 'gb1'), 'spam')$$, 'role');
delete from nomad_microweb.guestbook_entries where id = (select id from t_ids where k = 'gb1');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_microweb.sites where title = 'viewer edit'$$, 0);
select zz_check.expect($$select count(*) from nomad_microweb.sites where title = '두 번째 수정' and status = 'review'$$, 1);
-- editor 의 직접 삭제는 정책상 0건(owner/admin 만)
select zz_check.expect($$select count(*) from nomad_microweb.guestbook_entries where id = (select id from t_ids where k = 'gb1')$$, 1);
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_guestbook('minsu-jieun') -> 'entries')$$, 2);
reset role;

-- ==== 9. 하객 음성 연결(core voice_jobs) ====
select set_config('request.jwt.claims', '', true);
insert into nomad_core.voice_jobs (id, organization_id, product_code, feature, kind, provider, status, store_audio, consent_at, consent_kind,
                                   notice_version, storage_path, expires_at)
values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 'microweb', 'microweb_guestbook_voice', 'stt', 'oss-voice',
        'succeeded', true, now(), 'third_party_notice', 'v1', '00000000-0000-0000-0000-00000000000a/microweb/gb-voice/1.webm', now() + interval '1 hour'),
       ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000a', 'microweb', 'voice', 'stt', 'oss-voice',
        'succeeded', false, null, null, null, null, null),
       ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000000b', 'microweb', 'microweb_guestbook_voice', 'stt', 'oss-voice',
        'succeeded', true, now(), 'third_party_notice', 'v1', '00000000-0000-0000-0000-00000000000b/microweb/gb-voice/1.webm', now() + interval '1 hour');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb1'), '00000000-0000-0000-0000-0000000000f1')$$, 'ok');
select zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb1'), '00000000-0000-0000-0000-0000000000f1')$$, 'already');
select zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb2'), '00000000-0000-0000-0000-0000000000f1')$$, 'already');
select zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb2'), '00000000-0000-0000-0000-0000000000f2')$$, 'invalid');
select zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb2'), '00000000-0000-0000-0000-0000000000f3')$$, 'invalid');
select zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb2'), gen_random_uuid())$$, 'not_found');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect($$select count(*) from jsonb_array_elements(nomad_microweb.list_public_guestbook('minsu-jieun') -> 'entries') e where (e ->> 'has_voice')::boolean$$, 1);
reset role;

-- ==== 10. 기능 잠금: 구독이 끊기면(만료·inactive·구독 없음 = C 취급, C에는 studio 없음) 스튜디오·공개·하객 경로 잠김 ====
-- 예외: 이미 게시된 청첩장 공개 열람(get_public_site·list_public_guestbook)은 유지(사용자 결정), 개인정보 삭제(delete_lead)는 owner/admin 허용.
-- 만료·정리 작업은 플랜과 무관.
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'microweb' and plan_code = 'C' and feature_code = 'studio'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'microweb' and plan_code = 'C'$$, 10);
create function pg_temp.microweb_locked_checks() returns void language plpgsql as $f$
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
  perform zz_check.expect('select count(*) from nomad_microweb.sites', 0);
  perform zz_check.expect('select count(*) from nomad_microweb.site_publications', 0);
  perform zz_check.expect('select count(*) from nomad_microweb.guestbook_entries', 0);
  perform zz_check.expect('select count(*) from nomad_microweb.leads', 0);
  perform zz_check.expect('select count(*) from nomad_microweb.production_orders', 0);
  perform zz_check.expect('select count(*) from nomad_microweb.studio_access', 1);
  perform zz_check.fails_with($$select nomad_microweb.create_site('00000000-0000-0000-0000-00000000000a', 'wedding_classic', 'L', 'locked-site')$$, 'no studio access');
  perform zz_check.fails_with($$select nomad_microweb.transition_site((select id from t_ids where k = 'site_a2'), 'draft')$$, 'no studio access');
  perform zz_check.fails_with($$select nomad_microweb.set_lead_status((select id from t_ids where k = 'lead_a'), 'quoted')$$, 'no studio access');
  perform zz_check.fails_with($$select nomad_microweb.create_order('00000000-0000-0000-0000-00000000000a', 'L', 1000, 'ord-locked')$$, 'no studio access');
  perform zz_check.fails_with($$select nomad_microweb.issue_preview_token((select id from t_ids where k = 'site_a2'))$$, 'no studio access');
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  -- 이미 게시된 청첩장의 하객 열람은 유지(사용자 결정), 쓰기 표시는 닫힘
  perform zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'slug'$$, 'minsu-jieun');
  perform zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'guestbook_open'$$, 'false');
  perform zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'rsvp_open'$$, 'false');
  perform zz_check.expect($$select jsonb_array_length(nomad_microweb.list_public_guestbook('minsu-jieun') -> 'entries')$$, 2);
  -- 게시되지 않은 사이트는 여전히 not_found
  perform zz_check.eq($$select nomad_microweb.get_public_site('a-second') ->> 'code'$$, 'not_found');
  perform zz_check.eq($$select nomad_microweb.get_public_site('b-site') -> 'site' ->> 'slug'$$, 'b-site');
  set local role service_role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform zz_check.eq($$select result from nomad_microweb.submit_guestbook_entry('minsu-jieun', '잠김', '잠긴 사이트', null, false, repeat('l', 32))$$, 'closed');
  perform zz_check.eq($$select result from nomad_microweb.submit_rsvp('minsu-jieun', '잠김', 'none', 'yes', 1, null, null, repeat('l', 32))$$, 'closed');
  perform zz_check.eq($$select result from nomad_microweb.create_lead('00000000-0000-0000-0000-00000000000a', 'contact_form', '잠김', '010-1234-5678', null, null, null, null, null, null, null, null, true, repeat('l', 32))$$, 'closed');
  perform zz_check.eq($$select nomad_microweb.attach_guestbook_voice((select id from t_ids where k = 'gb2'), '00000000-0000-0000-0000-0000000000f1')$$, 'closed');
  perform zz_check.fails_with($$select nomad_microweb.request_publish((select id from t_ids where k = 'site_a2'), '00000000-0000-0000-0000-0000000000a1')$$, 'no studio access');
  -- 조직 B(구독 유지)는 그대로
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
  perform zz_check.expect('select count(*) from nomad_microweb.sites', 1);
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $f$;
-- 10-1 만료(ends_at 지남)
update nomad_core.subscriptions set starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
 where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'microweb';
select pg_temp.microweb_locked_checks();
-- 10-2 inactive
update nomad_core.subscriptions set status = 'inactive', ends_at = null
 where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'microweb';
select pg_temp.microweb_locked_checks();
-- 10-3 구독 행 없음
delete from nomad_core.subscriptions where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'microweb';
select pg_temp.microweb_locked_checks();
-- 잠긴 상태에서도 견적 문의 개인정보 삭제는 허용(owner)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_microweb.delete_lead((select id from t_ids where k = 'lead_a'));
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect('select count(*) from nomad_microweb.leads', 0);
-- 허용 목록 회수도 잠금(구독 유지 조직 B)
update nomad_microweb.studio_access set revoked_at = now() where organization_id = '00000000-0000-0000-0000-00000000000b';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_microweb.sites', 0);
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.eq($$select nomad_microweb.get_public_site('b-site') -> 'site' ->> 'slug'$$, 'b-site');
select zz_check.eq($$select nomad_microweb.get_public_site('b-site') -> 'site' ->> 'guestbook_open'$$, 'false');
reset role;
select set_config('request.jwt.claims', '', true);
-- 조직 비활성은 게시 중이어도 not_found
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000b';
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.eq($$select nomad_microweb.get_public_site('b-site') ->> 'code'$$, 'not_found');
select zz_check.eq($$select nomad_microweb.list_public_guestbook('b-site') ->> 'code'$$, 'not_found');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000b';
update nomad_microweb.studio_access set revoked_at = null where organization_id = '00000000-0000-0000-0000-00000000000b';
-- 재구독(B)하면 풀림
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
  values ('00000000-0000-0000-0000-00000000000a', 'microweb', 'B', 'active');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_microweb.sites', 2);
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') -> 'site' ->> 'slug'$$, 'minsu-jieun');
reset role;

-- ==== 11. 게시 중지·만료(service, 플랜 무관) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_microweb.transition_site((select id from t_ids where k = 'site_a'), 'unpublished', '고객 요청');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_microweb.site_publications where slug = 'minsu-jieun' and not is_live and unpublished_at is not null$$, 1);
update nomad_microweb.sites set expires_at = now() - interval '1 minute' where slug = 'b-site';
select zz_check.expect($$select count(*) from nomad_microweb.site_publications where slug = 'b-site' and expires_at < now()$$, 1);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.expect($$select count(*) from nomad_microweb.expire_sites()$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_microweb.sites where slug = 'b-site' and status = 'expired' and expired_at is not null$$, 1);
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.eq($$select nomad_microweb.get_public_site('b-site') ->> 'code'$$, 'not_found');
select zz_check.eq($$select nomad_microweb.get_public_site('minsu-jieun') ->> 'code'$$, 'not_found');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 12. 함수 권한 · 테이블 권한 · 동기화 컬럼 · 감사 · AI 라우팅 ====
-- anon 이 실행 가능한 함수는 공개 읽기 RPC 4개뿐(D8)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_microweb' and has_function_privilege('anon', p.oid, 'execute')
    and p.prorettype <> 'trigger'::regtype$$, 4);
-- 숨김 컬럼이 있는 표(guestbook_entries·rsvp_responses·leads·studio_access)의 행 타입을 돌려주는 함수가 authenticated 에 없다
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_microweb' and has_function_privilege('authenticated', p.oid, 'execute')
    and p.prorettype in ('nomad_microweb.guestbook_entries'::regtype, 'nomad_microweb.rsvp_responses'::regtype,
                         'nomad_microweb.leads'::regtype, 'nomad_microweb.studio_access'::regtype)$$, 0);
-- 테이블 권한: anon 은 전무(10개 표 전부), authenticated 는 insert·truncate·references·trigger 없음
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_microweb' and c.relkind = 'r'$$, 10);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_microweb' and c.relkind = 'r'
    and (has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')
         or has_any_column_privilege('anon', c.oid, 'select,insert,update,references')
         or has_table_privilege('authenticated', c.oid, 'insert,truncate,references,trigger'))$$, 0);
-- 모든 표 RLS
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_microweb' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
-- touch 트리거(run_check.sh 임시 정의는 clock_timestamp)
select zz_check.expect($$select count(*) from nomad_microweb.sites where slug = 'a-second' and updated_at > created_at$$, 1);
select zz_check.expect($$select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_microweb' and t.tgname like '%\_touch' and not t.tgisinternal$$, 9);
-- 감사: 행위자 강제(사용자 RPC 는 actor_role user), 개인정보 없음
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'site.create'$$, 3);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'order.create' and actor_role = 'user' and actor_id = '00000000-0000-0000-0000-0000000000a1'$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'lead.delete' and organization_id = '00000000-0000-0000-0000-00000000000a'$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'guestbook.voice_attach'$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action like 'lead.%' and (after::text like '%문의자%' or before::text like '%010-%')$$, 0);
-- 비노출 스키마 없음, AI 라우팅 12행(하객 음성은 오픈소스 강제)
select zz_check.expect($$select count(*) from pg_namespace where nspname = 'nomad_microweb_private'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'microweb'$$, 12);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where product_code = 'microweb' and feature = 'microweb_guestbook_voice' and force_open_source$$, 1);
