-- astro user안 검사: 사용자 2명 교차 접근 거부 · anon은 list_themes RPC만 · 암호문 컬럼 차단 · 리딩 취소(개인 조직 작업 취소+크레딧 환불)
-- · 상태 전이 · 발송 outbox · 잠김 회귀(활성 개인 조직 없음 = 잠김, 구독 끊김 = C도 리딩 열림) · AI 라우팅(0002). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/astro/run_check.sh user

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
create function zz_check.porg(u text) returns uuid language sql as $$
  select m.organization_id from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
   where m.user_id = u::uuid and m.role = 'owner' and o.kind = 'personal' limit 1 $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: u1(개인 조직 구독 없음 = C), u2(개인 조직 플랜 A). 개인 조직은 가입 트리거가 만든다 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  (zz_check.porg('00000000-0000-0000-0000-0000000000a2'), 'astro', 'A', 'active');

-- ==== 0. 서버(service_role) ====
select zz_check.as_role('service_role');
insert into nomad_astro.subjects (id, user_id, alias, relation, gender, name_ciphertext, birth_ciphertext, key_version) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a1', '나', 'self', 'female', 'enc-name-a', 'enc-birth-a', 1),
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000000a2', '나', 'self', 'male', 'enc-name-b', 'enc-birth-b', 1);
select zz_check.fails_with($$insert into nomad_astro.subjects (user_id, alias, relation, gender, name_ciphertext, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-0000000000a1', '또나', 'self', 'female', 'x', 'y', 1)$$, '23505');
select zz_check.fails_with($$insert into nomad_astro.readings (user_id, subject_id, kind, theme_key, credits_charged, request_id) values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000005b1', 'saju', 'mystical-dark', 0, gen_random_uuid())$$, '23503');
select nomad_core.grant_credits(zz_check.porg('00000000-0000-0000-0000-0000000000a1'), 100, 'test_grant', 'test:grant:u1', 'astro');
create temp table zz_ids on commit drop as
  select (select ledger_id from nomad_core.consume_credits(zz_check.porg('00000000-0000-0000-0000-0000000000a1'), 30, 'astro.reading',
          'consume:astro:00000000-0000-0000-0000-0000000007a1', 'astro', 'reading', '00000000-0000-0000-0000-0000000006a1')) as ledger_id;
grant select on zz_ids to service_role, authenticated;
insert into nomad_astro.readings (id, user_id, subject_id, kind, theme_key, credits_charged, credit_ledger_id, job_id, request_id, created_by) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000005a1', 'saju', 'mystical-dark', 30,
   (select ledger_id from zz_ids),
   (nomad_core.enqueue_job(zz_check.porg('00000000-0000-0000-0000-0000000000a1'), 'astro', 'astro.reading', '{"reading_id":"00000000-0000-0000-0000-0000000006a1"}'::jsonb,
      p_credit_ledger_id => (select ledger_id from zz_ids), p_idempotency_key => 'job:astro:00000000-0000-0000-0000-0000000007a1',
      p_created_by => '00000000-0000-0000-0000-0000000000a1')).id,
   '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000005b1', 'saju', 'mystical-dark', 0, null, null,
   '00000000-0000-0000-0000-0000000007b1', '00000000-0000-0000-0000-0000000000a2');
-- 원장·작업 조직 일치(AS005): 다른 조직의 차감 행·작업은 연결 불가
select zz_check.fails_with($$insert into nomad_astro.readings (user_id, subject_id, kind, theme_key, credits_charged, credit_ledger_id, request_id) values ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000005b1', 'saju', 'mystical-dark', 30, (select ledger_id from zz_ids), gen_random_uuid())$$, 'AS005');
select zz_check.fails_with($$update nomad_astro.readings set job_id = (select job_id from nomad_astro.readings where id = '00000000-0000-0000-0000-0000000006a1') where id = '00000000-0000-0000-0000-0000000006b1'$$, 'AS005');
update nomad_astro.readings set job_id = (nomad_core.enqueue_job(zz_check.porg('00000000-0000-0000-0000-0000000000a2'), 'astro', 'astro.reading', '{}'::jsonb, p_idempotency_key => 'job:astro:b1')).id
 where id = '00000000-0000-0000-0000-0000000006b1';
-- 작업 없이 차감만 된 리딩(환불 경로)과 과금 근거 없는 리딩(거부 경로)
insert into nomad_astro.readings (id, user_id, kind, theme_key, tarot_cards, credits_charged, credit_ledger_id, request_id, created_by) values
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-0000000000a1', 'tarot', 'oracle-gold', '[1,2,3]', 20,
   (select ledger_id from nomad_core.consume_credits(zz_check.porg('00000000-0000-0000-0000-0000000000a1'), 20, 'astro.reading', 'consume:astro:00000000-0000-0000-0000-0000000007a3', 'astro', 'reading', '00000000-0000-0000-0000-0000000006a3')),
   '00000000-0000-0000-0000-0000000007a3', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000006a4', '00000000-0000-0000-0000-0000000000a1', 'tarot', 'oracle-gold', '[1,2,3]', 5, null, '00000000-0000-0000-0000-0000000007a4', '00000000-0000-0000-0000-0000000000a1');
update nomad_astro.readings set status = 'generating' where id = '00000000-0000-0000-0000-0000000006b1';
update nomad_astro.readings set status = 'rendering' where id = '00000000-0000-0000-0000-0000000006b1';
insert into nomad_astro.reading_renders (id, user_id, reading_id, theme_key, is_initial, request_id) values
  ('00000000-0000-0000-0000-0000000008b1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000006b1', 'mystical-dark', true, gen_random_uuid());
update nomad_astro.reading_renders set status = 'rendering' where id = '00000000-0000-0000-0000-0000000008b1';
-- PDF 경로는 소유자 폴더만
select zz_check.fails_with($$update nomad_astro.reading_renders set status = 'succeeded', pdf_path = '00000000-0000-0000-0000-0000000000a1/astro/pdf/x.pdf' where id = '00000000-0000-0000-0000-0000000008b1'$$, '23514');
update nomad_astro.reading_renders set status = 'succeeded', pdf_path = '00000000-0000-0000-0000-0000000000a2/astro/pdf/r1.pdf' where id = '00000000-0000-0000-0000-0000000008b1';
update nomad_astro.readings set status = 'completed', current_render_id = '00000000-0000-0000-0000-0000000008b1' where id = '00000000-0000-0000-0000-0000000006b1';
select zz_check.fails_with($$update nomad_astro.readings set status = 'generating' where id = '00000000-0000-0000-0000-0000000006b1'$$, 'AS001');
insert into nomad_astro.deliveries (user_id, reading_id, render_id, recipient_masked, recipient_ciphertext, key_version) values
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000008b1', 'u2***@example.test', 'enc-email', 1);
select zz_check.expect($$select count(*) from nomad_astro.claim_due_deliveries('w1', 10)$$, 1);
select zz_check.expect($$select ((nomad_astro.finish_delivery((select id from nomad_astro.deliveries limit 1), true, null, 'msg-1')).status = 'sent')::int$$, 1);
insert into nomad_astro.consents (user_id, kind, version, granted) values
  ('00000000-0000-0000-0000-0000000000a1', 'privacy_required', 'v1', true), ('00000000-0000-0000-0000-0000000000a2', 'privacy_required', 'v1', true);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a1')$$, 50);

select zz_check.expect($$select count(*) from nomad_core.jobs where idempotency_key = 'job:astro:b1' and not refund_on_failure$$, 1);
-- last_error는 200자로 자른다
select zz_check.expect($$select count(*) from nomad_astro.deliveries where last_error is null or length(last_error) <= 200$$, 1);

-- ==== 1. anon ====
select zz_check.as_role('anon');
select zz_check.denied('select count(*) from nomad_astro.themes');
select zz_check.denied('select count(*) from nomad_astro.subjects');
select zz_check.denied($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')$$);
select zz_check.expect('select count(*) from nomad_astro.list_themes()', 2);
reset role;

-- ==== 2. u1: 본인 행만, 암호문 차단, 서버 전용 쓰기 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_astro.themes', 2);
select zz_check.expect('select count(*) from nomad_astro.subjects', 1);
select zz_check.expect('select count(*) from nomad_astro.readings', 3);
select zz_check.expect('select count(*) from nomad_astro.reading_renders', 0);
select zz_check.expect('select count(*) from nomad_astro.deliveries', 0);
select zz_check.expect('select count(*) from nomad_astro.consents', 1);
select zz_check.expect($$select nomad_astro.has_access('00000000-0000-0000-0000-0000000000a2')::int$$, 0);
select zz_check.denied('select name_ciphertext from nomad_astro.subjects');
select zz_check.denied('select question_ciphertext from nomad_astro.readings');
select zz_check.denied($$update nomad_astro.readings set progress = 50$$);
select zz_check.denied($$select nomad_astro.personal_organization('00000000-0000-0000-0000-0000000000a1')$$);
insert into nomad_astro.preferences (user_id, default_theme_key) values ('00000000-0000-0000-0000-0000000000a1', 'oracle-gold');
select zz_check.denied($$insert into nomad_astro.preferences (user_id) values ('00000000-0000-0000-0000-0000000000a2')$$);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006b1')$$, 'P0002');
-- 본인 취소 → 개인 조직 작업 취소 + 크레딧 환불
select zz_check.expect($$select ((nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')).status = 'canceled')::int$$, 1);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')$$, 'AS002');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.jobs where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a1') and status = 'canceled'$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a1')$$, 80);
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a1') and action = 'reading.cancel'$$, 1);

-- ==== 3. u2: 본인 행만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_astro.readings', 1);
select zz_check.expect('select count(*) from nomad_astro.reading_renders', 1);
select zz_check.expect('select count(*) from nomad_astro.deliveries', 1);
select zz_check.expect('select count(*) from nomad_astro.preferences', 0);
select zz_check.expect($$with u as (update nomad_astro.preferences set email_delivery_enabled = false returning 1) select count(*) from u$$, 0);
select zz_check.denied('select recipient_ciphertext from nomad_astro.deliveries');
reset role;

-- ==== 3b. 보안 보강 회귀: 원장만 있는 리딩 환불 · 과금 근거 없으면 거부 · updated_by 강제 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.denied($$update nomad_astro.preferences set updated_by = '00000000-0000-0000-0000-0000000000a2'$$);
select zz_check.expect($$select ((nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a3')).status = 'canceled')::int$$, 1);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a4')$$, 'AS004');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a1')$$, 100);
select zz_check.expect($$select (updated_by = '00000000-0000-0000-0000-0000000000a1')::int from nomad_astro.preferences$$, 1);

-- ==== 4. 잠김 회귀 ====
-- 4.1 구독 끊김(u2: inactive → C 취급)이어도 원본 무료 기능(reading)이라 열려 있다
update nomad_core.subscriptions set status = 'inactive' where organization_id = zz_check.porg('00000000-0000-0000-0000-0000000000a2') and product_code = 'astro';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_astro.readings', 1);
reset role;
-- 4.2 개인 조직 비활성 → 0행·쓰기 거부
update nomad_core.organizations set active = false where id = zz_check.porg('00000000-0000-0000-0000-0000000000a1');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_astro.readings', 0);
select zz_check.expect('select count(*) from nomad_astro.preferences', 0);
select zz_check.expect($$with u as (update nomad_astro.preferences set email_delivery_enabled = false returning 1) select count(*) from u$$, 0);
reset role;
-- 4.3 C 플랜에서 reading을 빼면(정책 변경 회귀) 구독 없는 사용자는 잠긴다
delete from nomad_core.plan_features where product_code = 'astro' and plan_code = 'C' and feature_code = 'reading';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_astro.readings', 0);
select zz_check.denied($$insert into nomad_astro.preferences (user_id) values ('00000000-0000-0000-0000-0000000000a2')$$);
reset role;
-- 4.4 기능 판정은 과금 조직(개인 조직)만: owner인 팀 조직에 플랜 A가 있어도 개인 조직이 C면 잠김
insert into nomad_core.organizations (id, name, kind) values ('00000000-0000-0000-0000-00000000000e', 'team E', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values ('00000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values ('00000000-0000-0000-0000-00000000000e', 'astro', 'A', 'active');
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_astro.readings', 0);
reset role;

-- ==== 5. 0002 AI · 정적 검사 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'astro'$$, 10);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_astro' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_astro'$$, 7);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_astro' and grantee = 'anon'$$, 0);
