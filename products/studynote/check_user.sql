-- study-note user안 검사: 사용자 2명 교차 거부 · 결과 컬럼 잠금 · 실행(과금 조직 = 본인 1인 조직, 선차감·작업·멱등·환불)
-- · 플랜 잠금(구독 끊김 = C: premium 모델·입력 한도) · 1인 조직 비활성 잠김 · 취소 권한 · 보존 · 함수 권한.
-- 합성 데이터만. 실행: bash products/studynote/run_check.sh user  (begin → 청사진 drop → user/0001·0002 → 이 파일 → rollback)
-- 가입하면 nomad_core가 1인 조직(kind personal, owner)을 자동으로 만든다 — 과금 조직은 그 조직이다.

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
create temp table t_ids (k text primary key, v text);
grant all on t_ids to public;

-- ---- 합성 데이터: u1(1인 조직 플랜 B), u2(구독 없음 = C) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'a2@example.test');
insert into t_ids select 'org1', m.organization_id::text from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
  where m.user_id = '00000000-0000-0000-0000-0000000000a1' and o.kind = 'personal';
insert into t_ids select 'org2', m.organization_id::text from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
  where m.user_id = '00000000-0000-0000-0000-0000000000a2' and o.kind = 'personal';
select zz_check.expect($$select count(*) from t_ids$$, 2);
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
  select v::uuid, 'studynote', 'B', 'active' from t_ids where k = 'org1';
select nomad_core.grant_credits((select v::uuid from t_ids where k = 'org1'), 100, 'test grant', 'zz-grant-1', 'studynote');
select nomad_core.grant_credits((select v::uuid from t_ids where k = 'org2'), 100, 'test grant', 'zz-grant-2', 'studynote');

-- ==== 0. 구조 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_studynote'$$, 7);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_studynote' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from information_schema.columns where table_schema = 'nomad_studynote' and column_name = 'user_id'$$, 4);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_studynote' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.routine_privileges where routine_schema in ('nomad_studynote', 'nomad_studynote_private') and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'studynote'$$, 13);
select zz_check.expect($$select count(*) from (values ('nomad_studynote'), ('nomad_studynote_private')) s(n) where has_schema_privilege('anon', n, 'usage')$$, 0);
-- 제품 함수 본문에 core 작업·원장 직접 쓰기 0건(mark_job_delivered·consume/refund 함수만)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_studynote', 'nomad_studynote_private')
    and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+nomad_core\.(jobs|credit_ledger)'$$, 0);

-- ==== 1. anon ====
set local role anon;
select zz_check.denied('select count(*) from nomad_studynote.entries');
select zz_check.denied($$select nomad_studynote.has_access()$$);
reset role;

-- ==== 2. u1: 본인 데이터 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_studynote.entries (id, entry_date, input_text) values ('00000000-0000-0000-0000-0000000e0001', '2026-11-14', '오늘 배운 것: RLS');
select zz_check.expect($$select count(*) from nomad_studynote.entries where user_id = '00000000-0000-0000-0000-0000000000a1'$$, 1);
select zz_check.denied($$insert into nomad_studynote.entries (user_id, entry_date, input_text) values ('00000000-0000-0000-0000-0000000000a2', '2026-11-14', 'x')$$);
select zz_check.denied($$update nomad_studynote.entries set user_id = '00000000-0000-0000-0000-0000000000a2'$$);
select zz_check.denied($$update nomad_studynote.entries set final_text = 'x'$$);
insert into nomad_studynote.user_settings (user_id, base_model_1, theme) values ('00000000-0000-0000-0000-0000000000a1', 'openai/gpt-5-mini', 'light');
select zz_check.denied($$insert into nomad_studynote.user_settings (user_id) values ('00000000-0000-0000-0000-0000000000a2')$$);
select zz_check.denied($$select nomad_studynote.start_run(gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 3. u2: u1 데이터 0건, 위조 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select (select count(*) from nomad_studynote.entries) + (select count(*) from nomad_studynote.user_settings)$$, 0);
do $$ declare n int; begin
  update nomad_studynote.entries set input_text = 'hack';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'u2 updated u1 entry'; end if;
  delete from nomad_studynote.entries;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'u2 deleted u1 entry'; end if;
end $$;
-- 구독 없음(C)도 정리 기능은 열려 있다(원본 free)
insert into nomad_studynote.entries (id, entry_date, input_text) values ('00000000-0000-0000-0000-0000000e00b1', '2026-11-14', repeat('가', 6000));
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 4. 서버: 과금 조직 검증 · 실행 · 환불 ====
-- 남의 1인 조직으로 과금 거부, 남의 일지 거부
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org2'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not the owner');
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org2'), '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'entry not found');
select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0001', 'anthropic/claude-opus-4.7', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6');
select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0001', 'anthropic/claude-opus-4.7', 'openai/gpt-5-mini', 'anthropic/claude-sonnet-4.6');
select zz_check.expect($$select count(*) from nomad_studynote.runs$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = (select v::uuid from t_ids where k = 'org1')$$, 93);
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org2'), '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1', '00000000-0000-0000-0000-0000000f0001', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'another user');
insert into t_ids select 'run1', id::text from nomad_studynote.runs;
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base1', 'running');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base1', 'succeeded', '요약 1');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'base2', 'failed', null, null, null, null, null, 'timeout');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'merge', 'running');
select nomad_studynote.record_step((select v::uuid from t_ids where k = 'run1'), 'merge', 'succeeded', '통합본');
select nomad_studynote.finish_run((select v::uuid from t_ids where k = 'run1'), '최종본', array['RLS', 'SQL']);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = (select v::uuid from t_ids where k = 'org1')$$, 94);
select zz_check.expect_text($$select status from nomad_studynote.entries where id = '00000000-0000-0000-0000-0000000e0001'$$, 'organized');
-- 본인만 결과를 본다
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select (select count(*) from nomad_studynote.runs) + (select count(*) from nomad_studynote.run_steps)$$, 4);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select (select count(*) from nomad_studynote.runs) + (select count(*) from nomad_studynote.run_steps)$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);
-- 취소: u2는 u1 실행을 못 찾고, u1은 queued 실행을 취소(전액 환불)
select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0002', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini');
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
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = (select v::uuid from t_ids where k = 'org1')$$, 94);

-- 워커 사망: 작업 취소 후 남은 실행 → finish_run 거부, reconcile_runs로 정리
select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001',
  '00000000-0000-0000-0000-0000000f0004', 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini');
select nomad_core.cancel_job((select job_id from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0004'));
select zz_check.fails_with($$select nomad_studynote.finish_run((select id from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0004'), '최종', array['a', 'b'])$$, 'job is already finished');
select zz_check.expect($$select nomad_studynote.reconcile_runs()$$, 1);
select zz_check.expect_text($$select status from nomad_studynote.runs where request_id = '00000000-0000-0000-0000-0000000f0004'$$, 'canceled');
-- 🔴 회귀: 반복 실행·취소가 전체 일일 예산을 쌓지 않는다 + 과금 조직별 상한
update nomad_studynote.runtime_config set value_int = (select used_credits from nomad_studynote.cost_guard) + 5 where key = 'daily_credit_cap';
do $$
declare i integer; v_run nomad_studynote.runs;
begin
  for i in 1..5 loop
    v_run := nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1',
      '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini');
    perform nomad_studynote.request_run_cancel(v_run.id);
  end loop;
end $$;
select zz_check.expect($$select used_credits from nomad_studynote.cost_guard$$, 6);
update nomad_studynote.runtime_config set value_int = 7 where key = 'daily_credit_cap_per_org';
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'organization daily budget');
update nomad_studynote.runtime_config set value_int = 300 where key = 'daily_credit_cap_per_org';
update nomad_studynote.runtime_config set value_int = 5000 where key = 'daily_credit_cap';
-- 소프트 삭제 시각은 클라이언트 값 대신 now()
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
update nomad_studynote.entries set deleted_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000e0001';
select zz_check.expect($$select count(*) from nomad_studynote.entries where deleted_at = now()$$, 1);
update nomad_studynote.entries set deleted_at = null where id = '00000000-0000-0000-0000-0000000e0001';
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 5. 잠김 회귀: C(구독 없음)·구독 끊김 = 원본 free ====
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org2'), '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'input exceeds plan limit');
update nomad_studynote.entries set input_text = '짧은 원문' where id = '00000000-0000-0000-0000-0000000e00b1';
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org2'), '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000e00b1', gen_random_uuid(), 'openai/gpt-5.5', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not allowed by the plan');
update nomad_core.subscriptions set status = 'inactive' where organization_id = (select v::uuid from t_ids where k = 'org1') and product_code = 'studynote';
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'anthropic/claude-opus-4.7', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'not allowed by the plan');
-- 1인 조직 비활성 = 전부 잠김(표 0건, 쓰기 거부, 서버 거부)
update nomad_core.organizations set active = false where id = (select v::uuid from t_ids where k = 'org1');
select zz_check.fails_with($$select nomad_studynote.start_run((select v::uuid from t_ids where k = 'org1'), '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000e0001', gen_random_uuid(), 'openai/gpt-5-mini', 'openai/gpt-5-mini', 'openai/gpt-5-mini')$$, 'no entitlement');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select (select count(*) from nomad_studynote.entries) + (select count(*) from nomad_studynote.runs) + (select count(*) from nomad_studynote.user_settings)$$, 0);
select zz_check.denied($$insert into nomad_studynote.entries (entry_date, input_text) values ('2026-11-14', 'x')$$);
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = true where id = (select v::uuid from t_ids where k = 'org1');

-- ==== 6. 보존: 사용자 일지 기준, 과금 조직(C) 한도 ====
insert into nomad_studynote.entries (user_id, entry_date, input_text)
select '00000000-0000-0000-0000-0000000000a1', '2026-11-01', '원문 ' || g from generate_series(1, 3) g;
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('studynote', 'C', 'history_max_entries', 2);
select zz_check.expect($$select nomad_studynote.enforce_retention('00000000-0000-0000-0000-0000000000a1', (select v::uuid from t_ids where k = 'org1'))$$, 2);
select zz_check.expect($$select count(*) from nomad_studynote.entries where user_id = '00000000-0000-0000-0000-0000000000a2' and deleted_at is null$$, 1);
