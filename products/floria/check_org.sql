-- Floria org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · 공개 RPC(D8) · 상태 전이 · 기능 잠금 · 동기화 컬럼 · AI 스위치(0002). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/floria/run_check.sh   (begin → 청사진 drop → 임시 touch_updated_at → org/0001·0002 → 이 파일 → rollback)

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

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer), 조직 B(u2 owner) ----
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

-- 구독이 끊기면 잠기므로(C에 site 없음) 두 조직 모두 B 구독
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'floria', 'B', 'active'), ('00000000-0000-0000-0000-00000000000b', 'floria', 'B', 'active');

-- ==== 0. 서버(service_role): 사이트 등록 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_floria.provision_site('00000000-0000-0000-0000-00000000000a', 'floria-a', 'Floria A', 'floria', array['https://a.example.test'], 'a@example.test');
select nomad_floria.provision_site('00000000-0000-0000-0000-00000000000b', 'floria-b', 'Floria B');
reset role;
select zz_check.expect($$select count(*) from nomad_floria.sites$$, 2);
-- 일반 사용자는 provision_site 불가
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.denied($$select nomad_floria.provision_site('00000000-0000-0000-0000-00000000000a', 'floria-x', 'X')$$);
reset role;

-- ==== 1. 방문자(anon): 공개 RPC만 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_floria.sites');
select zz_check.denied('select count(*) from nomad_floria.inquiries');
select zz_check.denied($$insert into nomad_floria.inquiries (organization_id, site_id, kind, name, email, message, consent_version) values ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 'other', 'x', 'x@example.test', 'xxxxxxxxxxxx', 'v1')$$);
select zz_check.denied('select * from nomad_core.rate_limit_buckets');
select zz_check.denied($$select nomad_core.rate_limit_take('k', 1, 60)$$);
select zz_check.denied('select * from nomad_core.audit_log');
select zz_check.denied($$select nomad_floria.subscribe_newsletter('floria-a', 'n@example.test', 'ko', 'v1')$$);
select zz_check.denied($$select nomad_floria.purge_expired()$$);
select zz_check.denied($$select nomad_floria.set_inquiry_status(gen_random_uuid(), 'read')$$);
-- 정상 접수 3건(같은 이메일 시간당 3) → 4번째 {ok:false, code:SI001} (raise 아님: 카운터가 롤백되지 않고 쌓인다)
select nomad_floria.submit_inquiry('Floria-A', 'wedding', 'Visitor', 'v1@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', '/contact', null, 8000);
select nomad_floria.submit_inquiry('floria-a', 'wedding', 'Visitor', 'v1@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', '/contact', null, 8000);
select nomad_floria.submit_inquiry('floria-a', 'wedding', 'Visitor', 'v1@example.test', '010-1234-5678', 'Hello, I want a wedding bouquet.', 'ko', 'v1', '/contact', null, 8000);
select zz_check.expect($$select (nomad_floria.submit_inquiry('floria-a', 'wedding', 'Visitor', 'v1@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', '/contact', null, 8000) = '{"ok":false,"code":"SI001"}')::int$$, 1);
select zz_check.expect($$select (nomad_floria.submit_inquiry('floria-a', 'wedding', 'Visitor', 'v1@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', '/contact', null, 8000) ->> 'code' = 'SI001')::int$$, 1);
-- 검증 실패들
select zz_check.fails_with($$select nomad_floria.submit_inquiry('floria-a', 'wedding', 'V', 'v2@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v0', null, null, 8000)$$, 'SI004');
select zz_check.fails_with($$select nomad_floria.submit_inquiry('nope', 'wedding', 'V', 'v2@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', null, null, 8000)$$, 'SI002');
select zz_check.fails_with($$select nomad_floria.submit_inquiry('floria-a', 'hack', 'V', 'v2@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', null, null, 8000)$$, 'SI003');
select zz_check.fails_with($$select nomad_floria.submit_inquiry('floria-a', 'other', 'V', 'not-an-email', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', null, null, 8000)$$, 'SI003');
select zz_check.fails_with($$select nomad_floria.submit_inquiry('floria-a', 'other', 'V', 'v2@example.test', null, 'short', 'ko', 'v1', null, null, 8000)$$, 'SI003');
-- 허니팟: 저장 안 함, 정상 응답처럼
select nomad_floria.submit_inquiry('floria-a', 'other', 'Bot', 'bot@example.test', null, 'Buy cheap stuff now please', 'ko', 'v1', null, 'filled', 8000);
-- 너무 빠른 제출 → spam 상태로 저장
select nomad_floria.submit_inquiry('floria-a', 'other', 'Fast', 'fast@example.test', null, 'Submitted way too fast here', 'ko', 'v1', null, null, 100);
reset role;
select zz_check.expect($$select count(*) from nomad_floria.inquiries where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 4);
select zz_check.expect($$select count(*) from nomad_floria.inquiries where email = 'bot@example.test'$$, 0);
select zz_check.expect($$select count(*) from nomad_floria.inquiries where status = 'spam' and email = 'fast@example.test'$$, 1);
-- 조직 B 사이트에도 1건(교차 검사용)
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select nomad_floria.submit_inquiry('floria-b', 'press', 'PressB', 'pb@example.test', null, 'Press question for org B site', 'en', 'v1', null, null, 9000);
reset role;

-- ==== 2. 서버: 뉴스레터 이중 동의 · 구독 해지 · 전이 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_floria.subscribe_newsletter('floria-a', 'sub1@example.test', 'ko', 'v1', '/', null, 5000);
select nomad_floria.subscribe_newsletter('floria-b', 'subb@example.test', 'en', 'v1', '/', null, 5000);
select zz_check.fails_with($$select nomad_floria.subscribe_newsletter('floria-a', 'sub2@example.test', 'ko', 'v0')$$, 'SI004');
reset role;
select zz_check.expect($$select count(*) from nomad_floria.newsletter_subscribers where status = 'pending'$$, 2);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_floria.confirm_newsletter((select id from nomad_floria.newsletter_subscribers where site_id = (select id from nomad_floria.sites where slug = 'floria-a')));
reset role;
select zz_check.expect($$select count(*) from nomad_floria.newsletter_subscribers where status = 'confirmed' and confirmed_at is not null$$, 1);
-- 직접 전이 위반(트리거): confirmed → pending 불가
select zz_check.fails_with($$update nomad_floria.newsletter_subscribers set status = 'pending' where status = 'confirmed'$$, 'invalid status transition');

-- 교차 검사용 조직 A id 보관(B 시점에서는 RLS로 안 보이므로)
create temp table t_ids as
select 'site_a'::text k, id from nomad_floria.sites where slug = 'floria-a'
union all select 'inq_a', (select id from nomad_floria.inquiries where email = 'v1@example.test' and phone is null order by created_at limit 1)
union all select 'sub_a', (select id from nomad_floria.newsletter_subscribers where email = 'sub1@example.test');
grant select on t_ids to public;

-- ==== 3. 조직 B(u2) 시점: 조직 A 전부 안 보이고 쓰기 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_floria.sites', 1);
select zz_check.expect('select count(*) from nomad_floria.inquiries', 1);
select zz_check.expect('select count(*) from nomad_floria.newsletter_subscribers', 1);
select zz_check.expect($$select count(*) from nomad_floria.inquiries where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.denied($$insert into nomad_floria.sites (organization_id, slug, name) values ('00000000-0000-0000-0000-00000000000a', 'evil-site', 'E')$$);
select zz_check.denied($$update nomad_floria.inquiries set staff_note = 'hacked'$$ || '');
select zz_check.denied($$delete from nomad_floria.inquiries$$);
select zz_check.fails_with($$select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_a'), 'read')$$, 'not a member');
select zz_check.fails_with($$select nomad_floria.delete_inquiry((select id from t_ids where k = 'inq_a'))$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_floria.erase_subscriber((select id from t_ids where k = 'sub_a'))$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_floria.update_site_settings((select id from t_ids where k = 'site_a'), 'Hacked')$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_floria.update_ai_settings((select id from t_ids where k = 'site_a'), true, true)$$, 'owner/admin only');
reset role;

-- ==== 4. 조직 A viewer(u5): 사이트만, 문의·구독자 안 보임, 운영 RPC 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_floria.sites', 1);
select zz_check.expect('select count(*) from nomad_floria.inquiries', 0);
select zz_check.expect('select count(*) from nomad_floria.newsletter_subscribers', 0);
select zz_check.fails_with($$select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_a'), 'read')$$, 'not a member');
reset role;

-- ==== 5. 조직 A editor(u3): 문의 상태 변경 가능, 삭제·설정 불가 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_floria.inquiries', 4);
select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_a'), 'read', '확인함');
select zz_check.expect($$select count(*) from nomad_floria.inquiries where status = 'read' and read_at is not null and staff_note = '확인함'$$, 1);
select zz_check.fails_with($$select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_a'), 'bogus')$$, 'invalid status');
select zz_check.fails_with($$select nomad_floria.delete_inquiry((select id from t_ids where k = 'inq_a'))$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_floria.update_site_settings((select id from t_ids where k = 'site_a'), 'E')$$, 'owner/admin only');
select zz_check.denied($$update nomad_floria.sites set name = 'direct'$$);
reset role;

-- ==== 6. 조직 A owner(u1): 상태 전이 · 설정 · AI 스위치(0002) · 삭제 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_a'), 'replied');
select zz_check.fails_with($$select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_a'), 'new')$$, 'invalid status transition');
select nomad_floria.update_site_settings((select id from t_ids where k = 'site_a'), 'Floria A2', null, false);
select zz_check.expect($$select count(*) from nomad_floria.sites where name = 'Floria A2' and not accepts_inquiries$$, 1);
-- 음성은 상담이 켜져야만 켜진다
select nomad_floria.update_ai_settings((select id from t_ids where k = 'site_a'), null, true);
select zz_check.expect($$select count(*) from nomad_floria.sites where slug = 'floria-a' and not accepts_voice$$, 1);
select nomad_floria.update_ai_settings((select id from t_ids where k = 'site_a'), true, true);
select zz_check.expect($$select count(*) from nomad_floria.sites where slug = 'floria-a' and accepts_ai_chat and accepts_voice$$, 1);
select nomad_floria.update_ai_settings((select id from t_ids where k = 'site_a'), false);
select zz_check.expect($$select count(*) from nomad_floria.sites where slug = 'floria-a' and not accepts_ai_chat and not accepts_voice$$, 1);
select nomad_floria.erase_subscriber((select id from t_ids where k = 'sub_a'));
select zz_check.expect($$select count(*) from nomad_floria.newsletter_subscribers where status = 'unsubscribed' and email is null$$, 1);
select nomad_floria.delete_inquiry((select id from t_ids where k = 'inq_a'));
select zz_check.expect('select count(*) from nomad_floria.inquiries', 3);
reset role;
-- 문의 접수를 끈 사이트는 SI002
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.fails_with($$select nomad_floria.submit_inquiry('floria-a', 'other', 'V', 'v9@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', null, null, 8000)$$, 'SI002');
reset role;

-- ==== 7. 기능 잠금: 구독이 끊기면(만료·inactive·구독 없음 = C 취급, C에는 site 없음) 공개 접수·조회·운영 RPC 잠김 ====
-- 단 개인정보 삭제(delete_inquiry·erase_subscriber)는 잠긴 조직에서도 owner/admin에게 허용(의도)
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'floria' and plan_code = 'C'$$, 0);
update nomad_floria.sites set accepts_inquiries = true where slug = 'floria-a';
insert into t_ids select 'inq_fast', id from nomad_floria.inquiries where email = 'fast@example.test';
create function pg_temp.floria_locked_checks() returns void language plpgsql as $f$
begin
  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform zz_check.fails_with($$select nomad_floria.submit_inquiry('floria-a', 'other', 'V', 'v8@example.test', null, 'Hello, I want a wedding bouquet.', 'ko', 'v1', null, null, 8000)$$, 'SI002');
  set local role service_role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform zz_check.fails_with($$select nomad_floria.subscribe_newsletter('floria-a', 'lock@example.test', 'ko', 'v1', '/', null, 5000)$$, 'SI002');
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
  perform zz_check.expect('select count(*) from nomad_floria.sites', 0);
  perform zz_check.expect('select count(*) from nomad_floria.inquiries', 0);
  perform zz_check.expect('select count(*) from nomad_floria.newsletter_subscribers', 0);
  perform zz_check.fails_with($$select nomad_floria.update_site_settings((select id from t_ids where k = 'site_a'), 'X')$$, 'no entitlement');
  perform zz_check.fails_with($$select nomad_floria.set_inquiry_status((select id from t_ids where k = 'inq_fast'), 'read')$$, 'no entitlement');
  perform zz_check.fails_with($$select nomad_floria.update_ai_settings((select id from t_ids where k = 'site_a'), true)$$, 'no entitlement');
  -- 조직 B(구독 유지)는 그대로
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
  perform zz_check.expect('select count(*) from nomad_floria.sites', 1);
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $f$;
-- 7-1 만료(ends_at 지남)
update nomad_core.subscriptions set starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
  where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'floria';
select pg_temp.floria_locked_checks();
-- 7-2 inactive
update nomad_core.subscriptions set status = 'inactive', ends_at = null
  where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'floria';
select pg_temp.floria_locked_checks();
-- 7-3 구독 행 없음 + 서버도 사이트 등록 불가
delete from nomad_core.subscriptions where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'floria';
select pg_temp.floria_locked_checks();
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_floria.provision_site('00000000-0000-0000-0000-00000000000a', 'floria-a2', 'A2')$$, 'no site entitlement');
-- 잠긴 상태에서도 개인정보 삭제는 허용(owner)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_floria.delete_inquiry((select id from t_ids where k = 'inq_fast'));
select nomad_floria.erase_subscriber((select id from t_ids where k = 'sub_a'));
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_floria.inquiries where email = 'fast@example.test'$$, 0);
-- 재구독(B)하면 풀림
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
  values ('00000000-0000-0000-0000-00000000000a', 'floria', 'B', 'active');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_floria.sites', 1);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 8. 함수 권한 · 동기화 컬럼 ====
-- anon 이 실행 가능한 함수는 공개 RPC submit_inquiry 하나뿐(D8)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_floria' and has_function_privilege('anon', p.oid, 'execute')
    and p.prorettype <> 'trigger'::regtype$$, 1);
-- touch 트리거: 같은 트랜잭션 안에서도 updated_at 이 created_at(now()) 보다 커진다(run_check.sh 임시 정의는 clock_timestamp)
update nomad_floria.sites set name = 'Floria B2' where slug = 'floria-b';
select zz_check.expect($$select count(*) from nomad_floria.sites where slug = 'floria-b' and updated_at > created_at$$, 1);
select zz_check.expect($$select count(*) from pg_trigger where tgname in ('sites_touch', 'inquiries_touch', 'newsletter_touch') and not tgisinternal$$, 3);

-- ==== 9. P1 보안 회귀 ====
-- 한도 초과 반환이 롤백되지 않아 이메일 카운터가 한도(3)를 넘어 쌓였다(정상 3 + 초과 2 = 5)
select zz_check.expect($$select count::bigint from nomad_core.rate_limit_buckets
  where key = 'floria:inq:email:' || (select id from nomad_floria.sites where slug = 'floria-a')::text || ':'
              || encode(extensions.digest(convert_to('v1@example.test', 'UTF8'), 'sha256'), 'hex')$$, 5);
-- core 교체(제품 사본 없음): 비노출 스키마 없음, 감사는 nomad_core.audit_log(provision 2 · 상태 변경 2 · 삭제 2(잠긴 조직 삭제 포함), 행위자 강제)
select zz_check.expect($$select count(*) from pg_namespace where nspname = 'nomad_floria_private'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'site.provision'$$, 2);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'inquiry.status' and organization_id = '00000000-0000-0000-0000-00000000000a' and actor_role = 'user' and actor_id is not null$$, 2);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'inquiry.delete' and organization_id = '00000000-0000-0000-0000-00000000000a'$$, 2);
-- 테이블 권한: anon 은 전무, authenticated 는 SELECT(공개 스키마 3개) 외 없음
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_floria' and c.relkind = 'r'
    and (has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')
         or has_table_privilege('authenticated', c.oid, 'insert,update,delete,truncate,references,trigger'))$$, 0);
