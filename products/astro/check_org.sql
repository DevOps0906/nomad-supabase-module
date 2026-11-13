-- astro org안 검사: 조직 2곳 교차 접근 거부 · anon은 list_themes RPC만 · 암호문 컬럼 차단 · 역할별 쓰기 · 리딩 취소(core 작업 취소+크레딧 환불)
-- · 상태 전이 · 발송 outbox · 잠김 회귀(조직 비활성 = 잠김, 구독 끊김 = C도 리딩 열림) · AI 라우팅(0002). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/astro/run_check.sh org

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

-- ---- 합성 데이터: 조직 A(team: a1 owner · a3 editor · a5 viewer) 구독 없음(C), 조직 B(personal: a2 owner) 플랜 A ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'personal');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
update nomad_core.organizations set active = false
 where id not in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000b', 'astro', 'A', 'active');

-- ==== 0. 서버(service_role): 보관함·리딩(크레딧 차감 + 작업 등록)·렌더·발송 ====
select zz_check.as_role('service_role');
insert into nomad_astro.subjects (id, organization_id, alias, relation, gender, name_ciphertext, birth_ciphertext, key_version) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-00000000000a', '나', 'self', 'female', 'enc-name-a', 'enc-birth-a', 1),
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-00000000000b', '나', 'self', 'male', 'enc-name-b', 'enc-birth-b', 1);
-- 본인 외에는 제3자 동의 필수, 조직당 self 1개
select zz_check.fails_with($$insert into nomad_astro.subjects (organization_id, alias, relation, gender, name_ciphertext, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000a', '엄마', 'family', 'female', 'x', 'y', 1)$$, '23514');
select zz_check.fails_with($$insert into nomad_astro.subjects (organization_id, alias, relation, gender, name_ciphertext, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000a', '또나', 'self', 'female', 'x', 'y', 1)$$, '23505');
-- 남의 조직 보관함을 가리키는 리딩 거부(복합 FK)
select zz_check.fails_with($$insert into nomad_astro.readings (organization_id, subject_id, kind, theme_key, credits_charged, request_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005b1', 'saju', 'mystical-dark', 0, gen_random_uuid())$$, '23503');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test_grant', 'test:grant:a', 'astro');
create temp table zz_ids on commit drop as
  select (select ledger_id from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000a', 30, 'astro.reading',
          'consume:astro:00000000-0000-0000-0000-0000000007a1', 'astro', 'reading', '00000000-0000-0000-0000-0000000006a1')) as ledger_id;
grant select on zz_ids to service_role, authenticated;
insert into nomad_astro.readings (id, organization_id, subject_id, kind, theme_key, credits_charged, credit_ledger_id, job_id, request_id, created_by) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a1', 'saju', 'mystical-dark', 30,
   (select ledger_id from zz_ids),
   (nomad_core.enqueue_job('00000000-0000-0000-0000-00000000000a', 'astro', 'astro.reading', '{"reading_id":"00000000-0000-0000-0000-0000000006a1"}'::jsonb,
      p_credit_ledger_id => (select ledger_id from zz_ids), p_idempotency_key => 'job:astro:00000000-0000-0000-0000-0000000007a1',
      p_created_by => '00000000-0000-0000-0000-0000000000a3')).id,
   '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000006a2', '00000000-0000-0000-0000-00000000000a', null, 'tarot', 'oracle-gold', 0, null, null,
   '00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000005b1', 'saju', 'mystical-dark', 0, null, null,
   '00000000-0000-0000-0000-0000000007b1', '00000000-0000-0000-0000-0000000000a2');
-- 같은 request_id 재요청은 거부(멱등 키 unique)
select zz_check.fails_with($$insert into nomad_astro.readings (organization_id, kind, theme_key, credits_charged, request_id) values ('00000000-0000-0000-0000-00000000000a', 'tarot', 'oracle-gold', 0, '00000000-0000-0000-0000-0000000007a2')$$, '23505');
-- 상태 전이: B 리딩 완료까지, 잘못된 전이·불변 컬럼 거부
-- 원장·작업 조직 일치(AS005): 다른 조직의 차감 행·작업은 연결 불가
select zz_check.fails_with($$insert into nomad_astro.readings (organization_id, subject_id, kind, theme_key, credits_charged, credit_ledger_id, request_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000005b1', 'saju', 'mystical-dark', 30, (select ledger_id from zz_ids), gen_random_uuid())$$, 'AS005');
select zz_check.fails_with($$update nomad_astro.readings set job_id = (select job_id from nomad_astro.readings where id = '00000000-0000-0000-0000-0000000006a1') where id = '00000000-0000-0000-0000-0000000006b1'$$, 'AS005');
update nomad_astro.readings set job_id = (nomad_core.enqueue_job('00000000-0000-0000-0000-00000000000b', 'astro', 'astro.reading', '{}'::jsonb, p_idempotency_key => 'job:astro:b1')).id
 where id = '00000000-0000-0000-0000-0000000006b1';
-- 작업 없이 차감만 된 리딩(환불 경로)과 과금 근거 없는 리딩(거부 경로)
insert into nomad_astro.readings (id, organization_id, kind, theme_key, tarot_cards, credits_charged, credit_ledger_id, request_id, created_by) values
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-00000000000a', 'tarot', 'oracle-gold', '[1,2,3]', 20,
   (select ledger_id from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000a', 20, 'astro.reading', 'consume:astro:00000000-0000-0000-0000-0000000007a3', 'astro', 'reading', '00000000-0000-0000-0000-0000000006a3')),
   '00000000-0000-0000-0000-0000000007a3', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000006a4', '00000000-0000-0000-0000-00000000000a', 'tarot', 'oracle-gold', '[1,2,3]', 5, null, '00000000-0000-0000-0000-0000000007a4', '00000000-0000-0000-0000-0000000000a1');
update nomad_astro.readings set status = 'generating' where id = '00000000-0000-0000-0000-0000000006b1';
update nomad_astro.readings set status = 'rendering' where id = '00000000-0000-0000-0000-0000000006b1';
insert into nomad_astro.reading_renders (id, organization_id, reading_id, theme_key, is_initial, request_id) values
  ('00000000-0000-0000-0000-0000000008b1', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000006b1', 'mystical-dark', true, gen_random_uuid());
update nomad_astro.reading_renders set status = 'rendering' where id = '00000000-0000-0000-0000-0000000008b1';
select zz_check.fails_with($$update nomad_astro.reading_renders set status = 'succeeded' where id = '00000000-0000-0000-0000-0000000008b1'$$, 'AS001');
select zz_check.fails_with($$update nomad_astro.reading_renders set pdf_path = '00000000-0000-0000-0000-00000000000a/astro/pdf/x.pdf' where id = '00000000-0000-0000-0000-0000000008b1'$$, '23514');
update nomad_astro.reading_renders set status = 'succeeded', pdf_path = '00000000-0000-0000-0000-00000000000b/astro/pdf/r1.pdf' where id = '00000000-0000-0000-0000-0000000008b1';
update nomad_astro.readings set status = 'completed', current_render_id = '00000000-0000-0000-0000-0000000008b1' where id = '00000000-0000-0000-0000-0000000006b1';
select zz_check.fails_with($$update nomad_astro.readings set status = 'queued' where id = '00000000-0000-0000-0000-0000000006b1'$$, 'AS001');
select zz_check.fails_with($$update nomad_astro.readings set credits_charged = 1 where id = '00000000-0000-0000-0000-0000000006b1'$$, 'AS001');
-- 발송 outbox: 집기 → 실패(재시도) → 집기 불가(5분 뒤) → 강제 만기 후 성공
insert into nomad_astro.deliveries (organization_id, reading_id, render_id, recipient_masked, recipient_ciphertext, key_version) values
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000008b1', 'u2***@example.test', 'enc-email', 1);
select zz_check.expect($$select count(*) from nomad_astro.claim_due_deliveries('w1', 10)$$, 1);
select zz_check.expect($$select ((nomad_astro.finish_delivery((select id from nomad_astro.deliveries limit 1), false, 'smtp 451')).status = 'pending')::int$$, 1);
select zz_check.expect($$select count(*) from nomad_astro.claim_due_deliveries('w1', 10)$$, 0);
update nomad_astro.deliveries set next_attempt_at = now() - interval '1 second';
select zz_check.expect($$select count(*) from nomad_astro.claim_due_deliveries('w1', 10)$$, 1);
select zz_check.expect($$select ((nomad_astro.finish_delivery((select id from nomad_astro.deliveries limit 1), true, null, 'msg-1')).status = 'sent')::int$$, 1);
select zz_check.fails_with($$select nomad_astro.finish_delivery((select id from nomad_astro.deliveries limit 1), true)$$, 'AS003');
insert into nomad_astro.consents (organization_id, user_id, subject_id, kind, version, granted) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', null, 'privacy_required', 'v1', true),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', null, 'privacy_required', 'v1', true),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', null, 'marketing_email', 'v1', false);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 50);

select zz_check.expect($$select count(*) from nomad_core.jobs where idempotency_key = 'job:astro:b1' and not refund_on_failure$$, 1);
-- last_error는 200자로 자른다
select zz_check.expect($$select count(*) from nomad_astro.deliveries where last_error is null or length(last_error) <= 200$$, 1);

-- ==== 1. anon: 표 직접 접근 0, 공개 RPC list_themes만 ====
select zz_check.as_role('anon');
select zz_check.denied('select count(*) from nomad_astro.themes');
select zz_check.denied('select count(*) from nomad_astro.readings');
select zz_check.denied($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')$$);
select zz_check.denied($$select nomad_astro.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.expect('select count(*) from nomad_astro.list_themes()', 2);
reset role;

-- ==== 2. 조직 A owner(a1): 자기 조직만, 암호문 컬럼 차단, 서버 전용 쓰기 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_astro.themes', 2);
select zz_check.expect('select count(*) from nomad_astro.subjects', 1);
select zz_check.expect('select count(*) from nomad_astro.readings', 4);
select zz_check.expect('select count(*) from nomad_astro.reading_renders', 0);
select zz_check.expect('select count(*) from nomad_astro.deliveries', 0);
select zz_check.expect('select count(*) from nomad_astro.consents', 2);
select zz_check.denied('select name_ciphertext from nomad_astro.subjects');
select zz_check.denied('select question_ciphertext from nomad_astro.readings');
select zz_check.denied($$insert into nomad_astro.subjects (organization_id, alias, relation, gender, name_ciphertext, birth_ciphertext, key_version) values ('00000000-0000-0000-0000-00000000000a', 'x', 'self', 'male', 'x', 'y', 1)$$);
select zz_check.denied($$update nomad_astro.readings set progress = 50$$);
select zz_check.denied($$insert into nomad_astro.consents (organization_id, user_id, kind, version, granted) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'marketing_email', 'v1', true)$$);
select zz_check.denied($$select * from nomad_astro.claim_due_deliveries('evil', 10)$$);
-- 설정: 자기 조직 가능, 남의 조직 거부
insert into nomad_astro.preferences (organization_id, default_theme_key) values ('00000000-0000-0000-0000-00000000000a', 'oracle-gold');
select zz_check.denied($$insert into nomad_astro.preferences (organization_id) values ('00000000-0000-0000-0000-00000000000b')$$);
select zz_check.expect($$with u as (update nomad_astro.preferences set email_delivery_enabled = false returning 1) select count(*) from u$$, 1);
reset role;

-- ==== 3. 조직 B owner(a2): 남의 조직 리딩 취소 불가(존재도 숨김) ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_astro.readings', 1);
select zz_check.expect('select count(*) from nomad_astro.reading_renders', 1);
select zz_check.expect('select count(*) from nomad_astro.deliveries', 1);
select zz_check.expect('select count(*) from nomad_astro.preferences', 0);
select zz_check.denied('select recipient_ciphertext from nomad_astro.deliveries');
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')$$, 'P0002');
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006b1')$$, 'AS002');
reset role;

-- ==== 4. 조직 A viewer(a5)·editor(a3): viewer는 쓰기 불가, editor는 취소 → core 작업 취소 + 크레딧 환불 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect('select count(*) from nomad_astro.readings', 4);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')$$, '42501');
select zz_check.expect($$with u as (update nomad_astro.preferences set email_delivery_enabled = true returning 1) select count(*) from u$$, 0);
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect($$select ((nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')).status = 'canceled')::int$$, 1);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a1')$$, 'AS002');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.jobs where organization_id = '00000000-0000-0000-0000-00000000000a' and status = 'canceled'$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 80);
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000a' and action in ('reading.cancel', 'job.cancel')$$, 2);

-- ==== 4b. 보안 보강 회귀: 원장만 있는 리딩 환불 · 과금 근거 없으면 거부 · 동의 열람 범위 · updated_by 강제 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.expect('select count(*) from nomad_astro.consents', 1);
select zz_check.expect($$select count(*) from nomad_astro.consents where ip_hash is null$$, 1);
select zz_check.expect($$with u as (update nomad_astro.preferences set email_delivery_enabled = true returning 1) select count(*) from u$$, 1);
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect('select count(*) from nomad_astro.consents', 0);
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.denied($$update nomad_astro.preferences set updated_by = '00000000-0000-0000-0000-0000000000a2'$$);
select zz_check.expect($$select ((nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a3')).status = 'canceled')::int$$, 1);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a4')$$, 'AS004');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 100);
select zz_check.expect($$select (updated_by = '00000000-0000-0000-0000-0000000000a3')::int from nomad_astro.preferences$$, 1);

-- ==== 5. 잠김 회귀 ====
-- 5.1 구독 끊김(B: inactive → C 취급)이어도 원본 무료 기능(reading)이라 열려 있다
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000b' and product_code = 'astro';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect('select count(*) from nomad_astro.readings', 1);
reset role;
-- 5.2 조직 비활성 → 모든 표 0행·RPC 거부
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_astro.readings', 0);
select zz_check.expect('select count(*) from nomad_astro.subjects', 0);
select zz_check.expect('select count(*) from nomad_astro.preferences', 0);
select zz_check.fails_with($$select nomad_astro.cancel_reading('00000000-0000-0000-0000-0000000006a2')$$, 'P0002');
reset role;
-- 5.3 C 플랜에서 reading 기능을 빼면(정책 변경 회귀) 구독 없는 조직은 잠긴다
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000a';
delete from nomad_core.plan_features where product_code = 'astro' and plan_code = 'C' and feature_code = 'reading';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect('select count(*) from nomad_astro.readings', 0);
select zz_check.denied($$insert into nomad_astro.preferences (organization_id) values ('00000000-0000-0000-0000-00000000000a')$$);
reset role;

-- ==== 6. 0002 AI · 정적 검사 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'astro'$$, 10);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'astro' and feature_code in ('ai_chat', 'voice_chat', 'narration')$$, 9);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_astro' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_astro'$$, 7);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_astro' and grantee = 'anon'$$, 0);
