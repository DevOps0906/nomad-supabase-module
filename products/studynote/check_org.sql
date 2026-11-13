-- study-note org안 검사: 조직 2곳 교차 거부 · 역할(owner/editor/viewer) · 결과 컬럼 잠금 · 실행(선차감·작업·멱등·환불·재시도)
-- · 플랜 잠금(구독 끊김 = C: premium 모델·입력 한도) · 조직 비활성 잠김 · 취소 권한 · 보존 · 함수 권한.
-- 합성 데이터만. 실행: bash products/studynote/run_check.sh org  (begin → 청사진 drop → org/0001·0002 → 이 파일 → rollback)

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
grant execute on all functions in schema zz_check to anon, authenticated, service_role;
create function zz_check.login(u text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
grant execute on function zz_check.login(text) to authenticated;

-- ---- 합성 데이터: 조직 A(a1 owner · a3 editor · a4 viewer, 플랜 B), 조직 B(a2 owner, 구독 없음 = C) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'a2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'a4@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'studynote', 'B', 'active');
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('studynote', 'B', 'max_input_chars', 10000);
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test grant', 'zz-grant-a', 'studynote');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000b', 100, 'test grant', 'zz-grant-b', 'studynote');

-- ==== 0. 구조 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_studynote'$$, 7);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_studynote' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_studynote' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.routine_privileges where routine_schema in ('nomad_studynote', 'nomad_studynote_private') and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'studynote'$$, 13);
select zz_check.expect($$select count(*) from (values ('nomad_studynote'), ('nomad_studynote_private')) s(n) where has_schema_privilege('anon', n, 'usage')$$, 0);
-- 제품 함수 본문에 core 작업·원장 직접 쓰기 0건(mark_job_delivered·consume/refund 함수만)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_studynote', 'nomad_studynote_private')
    and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+nomad_core\.(jobs|credit_ledger)'$$, 0);
select zz_check.expect($$select count(*) from nomad_studynote.model_catalog$$, 13);

-- ==== 1. anon: 테이블·함수 거부 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_studynote.entries');
select zz_check.denied('select count(*) from nomad_studynote.model_catalog');
select zz_check.denied($$select nomad_studynote.request_run_cancel(gen_random_uuid())$$);
reset role;

-- ==== 2. 조직 A owner(a1) ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_studynote.entries (id, organization_id, entry_date, input_text) values
  ('00000000-0000-0000-0000-0000000e0001', '00000000-0000-0000-0000-00000000000a', '2026-11-14', '오늘 배운 것: SQL RLS');
select zz_check.denied($$insert into nomad_studynote.entries (organization_id, entry_date, input_text, status) values ('00000000-0000-0000-0000-00000000000a', '2026-11-14', 'x', 'organized')$$);
select zz_check.denied($$update nomad_studynote.entries set final_text = 'x'$$);
select zz_check.denied($$update nomad_studynote.entries set status = 'organized'$$);
select zz_check.denied($$insert into nomad_studynote.entries (organization_id, created_by, entry_date, input_text) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', '2026-11-14', 'x')$$);
insert into nomad_studynote.user_settings (organization_id, user_id, base_model_1, merge_model, theme) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6', 'dark');
select zz_check.denied($$insert into nomad_studynote.user_settings (organization_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3')$$);
select zz_check.denied($$insert into nomad_studynote.runs (organization_id, entry_id, request_id, idempotency_key, base_model_1, base_model_2, merge_model, credits_charged) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'x', 'a', 'b', 'c', 0)$$);
select zz_check.denied($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$);
select zz_check.denied($$select count(*) from nomad_studynote.runtime_config$$);
select zz_check.expect($$select count(*) from nomad_studynote.model_catalog$$, 13);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 3. editor(a3) 쓰기 · viewer(a4) 읽기만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
update nomad_studynote.entries set input_text = '오늘 배운 것: SQL RLS 정책' where id = '00000000-0000-0000-0000-0000000e0001';
delete from nomad_studynote.entries;  -- editor는 삭제 정책 밖(0건)
select zz_check.expect($$select count(*) from nomad_studynote.entries$$, 1);
select zz_check.expect($$select count(*) from nomad_studynote.user_settings$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.expect($$select count(*) from nomad_studynote.entries$$, 1);
select zz_check.denied($$insert into nomad_studynote.entries (organization_id, entry_date, input_text) values ('00000000-0000-0000-0000-00000000000a', '2026-11-14', 'viewer')$$);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 4. 조직 B owner(a2): A 데이터 0건, A 조직으로 쓰기 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select (select count(*) from nomad_studynote.entries) + (select count(*) from nomad_studynote.user_settings) + (select count(*) from nomad_studynote.runs)$$, 0);
select zz_check.denied($$insert into nomad_studynote.entries (organization_id, entry_date, input_text) values ('00000000-0000-0000-0000-00000000000a', '2026-11-14', 'B가 A에')$$);
select zz_check.denied($$insert into nomad_studynote.user_settings (organization_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2')$$);
-- 구독 없음(C)도 정리 기능은 열려 있다(원본 free)
insert into nomad_studynote.entries (id, organization_id, entry_date, input_text) values
  ('00000000-0000-0000-0000-0000000e00b1', '00000000-0000-0000-0000-00000000000b', '2026-11-14', repeat('가', 6000));
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 5. 서버: 실행 · 선차감 · 작업 · 멱등 · 환불 ====
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not an editor');
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e00b1', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'entry not found');
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'no/model', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not available');
-- 플랜 B: premium 허용. 비용 4 + 1 + 2 = 7
select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0001', 'anthropic/claude-opus-4.7', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6');
select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0001', 'anthropic/claude-opus-4.7', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6');
select zz_check.expect($$select count(*) from nomad_studynote.runs$$, 1);
select zz_check.expect($$select count(*) from nomad_studynote.run_steps$$, 3);
select zz_check.expect($$select count(*) from nomad_core.jobs where product_code = 'studynote' and credit_ledger_id is not null$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 93);
select zz_check.expect_text($$select status from nomad_studynote.entries where id = '00000000-0000-0000-0000-0000000e0001'$$, 'organizing');
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'already active');
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1', '00000000-0000-0000-0000-0000000f0001', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'another organization');
-- 사용자가 원문을 바꾸려 하면(정리 중) 거부
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$update nomad_studynote.entries set input_text = 'x' where id = '00000000-0000-0000-0000-0000000e0001'$$, 'locked while organizing');
reset role;
select set_config('request.jwt.claims', '', true);
-- 워커: base1 성공, base2 실패, merge 성공 → succeeded, base2 크레딧(1) 환불
create temp table t_ids (k text primary key, v text);
grant all on t_ids to public;
insert into t_ids select 'run1', id::text from nomad_studynote.runs;
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base1', 'running');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base1', 'succeeded', '요약 1');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base2', 'failed', null, null, null, null, null, 'timeout');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'merge', 'running');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'merge', 'succeeded', '통합본');
select zz_check.fails_with($$select nomad_studynote.finish_run((select v::uuid from t_ids where k = 'run1'), '최종', array['RLS'])$$, 'exactly 2 keywords');
select nomad_studynote.finish_run((select v::uuid from t_ids where k = 'run1'), '최종본', array['RLS', 'SQL']);
select zz_check.expect_text($$select status from nomad_studynote.runs where id = (select v::uuid from t_ids where k = 'run1')$$, 'succeeded');
select zz_check.expect($$select credits_refunded from nomad_studynote.runs where id = (select v::uuid from t_ids where k = 'run1')$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 94);
select zz_check.expect($$select count(*) from nomad_core.jobs where product_code = 'studynote' and not refund_on_failure$$, 1);
select zz_check.expect_text($$select status from nomad_studynote.entries where id = '00000000-0000-0000-0000-0000000e0001'$$, 'organized');
select zz_check.fails_with($$select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base2', 'running')$$, 'already succeeded');
-- 재시도: base2만 다시(base1 재사용 0크레딧) + merge. 비용 1 + 2 = 3
select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0002', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6',
  (select v::uuid from t_ids where k = 'run1'), array['base2']);
select zz_check.expect($$select count(*) from nomad_studynote.run_steps where status = 'reused' and credits = 0$$, 1);
select zz_check.expect($$select credits_charged from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0002'$$, 3);
-- 취소 권한: editor(a3)는 남의 실행 취소 불가, owner(a1)는 queued 취소 → 전액 환불
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.fails_with($$select nomad_studynote.request_run_cancel((select id from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0002'))$$, 'forbidden');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$select nomad_studynote.request_run_cancel('00000000-0000-0000-0000-000000000000'::uuid)$$, 'not found');
reset role;
select set_config('request.jwt.claims', '', true);
insert into t_ids select 'run2', id::text from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0002';
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$select nomad_studynote.request_run_cancel((select v::uuid from t_ids where k = 'run2'))$$, 'not found');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_studynote.request_run_cancel((select v::uuid from t_ids where k = 'run2'));
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect_text($$select status from nomad_studynote.runs where id = (select v::uuid from t_ids where k = 'run2')$$, 'canceled');
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 94);
select zz_check.expect_text($$select status from nomad_studynote.entries where id = '00000000-0000-0000-0000-0000000e0001'$$, 'organized');
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'studynote.run.cancel'$$, 1);
-- 전부 실패 → failed, 작업 키로 전액 환불(fail_job과 같은 요청이라 이중 환불 없음)
select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0003', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini');
select nomad_studynote.finish_run((select id from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0003'));
select zz_check.expect_text($$select status from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0003'$$, 'failed');
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 94);
select zz_check.expect($$select count(*) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a' and idempotency_key like 'nomad:refund:%:job:%'$$, 2);  -- 취소(run2)·실패(run3)

-- 워커 사망: 작업이 취소·실패로 끝났는데 실행이 남은 경우 → finish_run 거부, reconcile_runs로 정리
select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0004', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini');
select nomad_core.cancel_job((select job_id from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0004'));
select zz_check.fails_with($$select nomad_studynote.finish_run((select id from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0004'), '최종', array['a', 'b'])$$, 'job is already finished');
select zz_check.expect($$select nomad_studynote.reconcile_runs('00000000-0000-0000-0000-00000000000a')$$, 1);
select zz_check.expect_text($$select status from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0004'$$, 'canceled');
select zz_check.expect_text($$select status from nomad_studynote.entries where id = '00000000-0000-0000-0000-0000000e0001'$$, 'organized');
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 94);
-- 🔴 회귀: 한 사용자가 실행·취소를 반복해도 전체 일일 예산(cost_guard)이 쌓이지 않는다(이전: NT005로 전체 서비스 정지)
update nomad_studynote.runtime_config set value_int = (select used_credits from nomad_studynote.cost_guard) + 5 where key = 'daily_credit_cap';
do $$
declare i integer; v_run nomad_studynote.runs;
begin
  for i in 1..5 loop
    v_run := nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1',
      '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini');
    perform nomad_studynote.request_run_cancel(v_run.id);
  end loop;
end $$;
select zz_check.expect($$select used_credits from nomad_studynote.cost_guard$$, 6);
-- 조직별 일일 상한(plan_limits daily_credit_cap): 오늘 순사용 6 + 3 > 7 → 거부
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('studynote', 'B', 'daily_credit_cap', 7);
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'organization daily budget');
delete from nomad_core.plan_limits where product_code = 'studynote' and limit_key = 'daily_credit_cap';
update nomad_studynote.runtime_config set value_int = 5000 where key = 'daily_credit_cap';
-- 소프트 삭제 시각은 클라이언트 값 대신 now()
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
update nomad_studynote.entries set deleted_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000e0001';
select zz_check.expect($$select count(*) from nomad_studynote.entries where id = '00000000-0000-0000-0000-0000000e0001' and deleted_at = now()$$, 1);
update nomad_studynote.entries set deleted_at = null where id = '00000000-0000-0000-0000-0000000e0001';
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 6. 잠김 회귀: 구독 없음(C) · 구독 끊김 = 원본 free(premium 금지, 입력 5000자) ====
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'input exceeds plan limit');
update nomad_studynote.entries set input_text = '짧은 원문' where id = '00000000-0000-0000-0000-0000000e00b1';
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1', gen_random_uuid(), 'openai/gpt-5.5', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not allowed by the plan');
select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1',
  gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6');
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'studynote';
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'anthropic/claude-opus-4.7', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not allowed by the plan');
-- 조직 비활성 = 전부 잠김
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
select zz_check.fails_with($$select nomad_studynote.start_run('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'no entitlement');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select (select count(*) from nomad_studynote.entries) + (select count(*) from nomad_studynote.runs) + (select count(*) from nomad_studynote.run_steps) + (select count(*) from nomad_studynote.user_settings)$$, 0);
select zz_check.denied($$insert into nomad_studynote.entries (organization_id, entry_date, input_text) values ('00000000-0000-0000-0000-00000000000a', '2026-11-14', 'x')$$);
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000a';

-- ==== 7. 보존: history_max_entries 초과분 soft delete(최신 1건 유지) ====
insert into nomad_studynote.entries (organization_id, created_by, entry_date, input_text)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '2026-11-01', '원문 ' || g from generate_series(1, 3) g;
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('studynote', 'C', 'history_max_entries', 2);
select zz_check.expect($$select nomad_studynote.enforce_retention('00000000-0000-0000-0000-00000000000a')$$, 2);
select zz_check.expect($$select count(*) from nomad_studynote.entries where organization_id = '00000000-0000-0000-0000-00000000000a' and deleted_at is null$$, 2);
select zz_check.expect($$select nomad_studynote.purge_deleted(interval '0 seconds')$$, 0);
