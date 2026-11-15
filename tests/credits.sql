-- 크레딧 원장 보강 검증: 버킷(plan 먼저→pack) · null=pack · 멱등(ref·버킷·환불 요청액) · 예약 키 선점 방지 · 환불 상한·no-op·만료 후 환불
--   · 월 지급분 만료(0원 완료 기록·기간 순서) · 서버 전용 (합성 데이터, 롤백)
\o /dev/null
begin;

create function pg_temp.expect_err(stmt text, pattern text) returns void
language plpgsql as $$
begin
  execute stmt;
  raise exception 'expected failure (%) but succeeded: %', pattern, stmt;
exception when others then
  if sqlerrm like 'expected failure%' or sqlerrm not like pattern then
    raise exception 'wrong error for [%]: got [%] want like [%]', stmt, sqlerrm, pattern;
  end if;
end;
$$;

create function pg_temp.buckets(org uuid, want_plan integer, want_pack integer, label text) returns void
language plpgsql as $$
declare b record;
begin
  select * into b from nomad_core.credit_bucket_balances(org);
  if b.plan_balance <> want_plan or b.pack_balance <> want_pack then
    raise exception '% buckets: got %/% want %/%', label, b.plan_balance, b.pack_balance, want_plan, want_pack;
  end if;
end;
$$;

create temp table t_ctx (k text primary key, v text);
grant all on t_ctx to authenticated;

-- 1. 권한 표: 새 함수는 service_role만, 내부 도우미는 아무에게도, 사용자 경로(spend)는 그대로
do $$
declare f text;
begin
  foreach f in array array[
    'nomad_core.credit_bucket_balances(uuid)',
    'nomad_core.grant_plan_credits(uuid,integer,text,text,text)',
    'nomad_core.consume_credits(uuid,integer,text,text,text,text,text)',
    'nomad_core.refund_credits(uuid,text,text,integer)',
    'nomad_core.expire_plan_credits(uuid,text)'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'grant too wide: %', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'grant missing: %', f; end if;
  end loop;
  foreach f in array array[
    'nomad_core.post_credit_entry(uuid,integer,text,text,text,text,text)',
    'nomad_core.open_plan_period(uuid)',
    'nomad_core.close_plan_period(uuid,text)'] loop
    if has_function_privilege('service_role', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute') then
      raise exception 'internal helper must not be granted: %', f;
    end if;
  end loop;
  if not has_function_privilege('authenticated', 'nomad_core.spend_credits(uuid,integer,text,text,text)', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.grant_credits(uuid,integer,text,text,text)', 'execute')
  then raise exception 'legacy credit grants changed'; end if;
end;
$$;

-- 합성 사용자 2명 → 각자 personal 조직(owner)
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000c1', 'credit-a@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000c2', 'credit-b@example.test', now(), false, '{}');
insert into t_ctx
select 'org' || right(m.user_id::text, 1), m.organization_id::text
from nomad_core.memberships m
where m.user_id in ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000c2') and m.role = 'owner';

-- 2. 지급: 기존 행(bucket null)=pack, grant_credits=pack, grant_plan_credits=plan(멱등 = 조직·기간)
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  insert into nomad_core.credit_ledger (organization_id, delta, reason, idempotency_key)
  values (org, 20, 'legacy', 'legacy-1');
  if nomad_core.grant_credits(org, 30, 'pack', 'g1') <> 50 then raise exception 'pack grant'; end if;
  if nomad_core.grant_plan_credits(org, 30, '2026-11', 'monthly') <> 80 then raise exception 'plan grant'; end if;
  if nomad_core.grant_plan_credits(org, 30, '2026-11', 'monthly') <> 80
     or (select count(*) from nomad_core.credit_ledger where organization_id = org and ref_type = 'plan_period') <> 1
  then raise exception 'plan grant not idempotent'; end if;
  perform pg_temp.expect_err(format('select nomad_core.grant_plan_credits(%L, 31, ''2026-11'', ''monthly'')', org), '%idempotency key reused%');
  perform pg_temp.buckets(org, 30, 50, 'after grants');
end;
$$;

-- 3. consume: plan 먼저→pack, 버킷별 2행, 멱등 비교에 ref 포함, 예약 키·ref_type 거부
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1'); r record; r2 record;
begin
  select * into r from nomad_core.consume_credits(org, 40, 'job', 'c1', null, 'job', 'j1');
  if r.balance <> 40 or r.plan_used <> 30 or r.pack_used <> 10 then
    raise exception 'consume split % % %', r.balance, r.plan_used, r.pack_used;
  end if;
  if (select bucket from nomad_core.credit_ledger where id = r.ledger_id) <> 'plan'
     or (select period_key from nomad_core.credit_ledger where id = r.ledger_id) <> '2026-11'
     or (select count(*) from nomad_core.credit_ledger where organization_id = org and idempotency_key = 'c1') <> 2
  then raise exception 'consume rows'; end if;
  perform pg_temp.buckets(org, 0, 40, 'after consume');

  select * into r2 from nomad_core.consume_credits(org, 40, 'job', 'c1', null, 'job', 'j1');
  if r2.ledger_id <> r.ledger_id or r2.plan_used <> 30 or r2.pack_used <> 10 or r2.balance <> 40
     or (select count(*) from nomad_core.credit_ledger where organization_id = org and idempotency_key = 'c1') <> 2
  then raise exception 'consume replay'; end if;
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 40, ''job'', ''c1'', null, ''job'', ''j2'')', org), '%idempotency key reused%');
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 41, ''job'', ''c1'', null, ''job'', ''j1'')', org), '%idempotency key reused%');
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 41, ''job'', ''c-big'')', org), '%insufficient credits%');
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 0, ''job'', ''c-zero'')', org), '%amount must be positive%');
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 1, ''job'', ''c-rs'', null, ''plan_expire'', ''x'')', org), '%reserved ref_type%');
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 1, ''job'', ''nomad:plan_expire:2026-11'')', org), '%reserved idempotency key%');
  perform pg_temp.expect_err(format('select nomad_core.grant_credits(%L, 1, ''x'', ''nomad:plan_period:2027-01'')', org), '%reserved idempotency key%');
  insert into t_ctx values ('c1', r.ledger_id::text),
    ('c1pack', (select id::text from nomad_core.credit_ledger where organization_id = org and idempotency_key = 'c1' and bucket = 'pack'));
end;
$$;

-- 4. 환불: 상한 = consume − 기존 환불, 원 버킷으로(plan 먼저), 남은 0이면 no-op, 재호출은 사유·요청액까지 비교
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1');
  c1 uuid := (select v::uuid from t_ctx where k = 'c1'); c1pack uuid := (select v::uuid from t_ctx where k = 'c1pack');
  r record;
begin
  select * into r from nomad_core.refund_credits(c1, 'job failed', 'r1', 15);
  if r.refunded <> 15 or r.balance <> 55 then raise exception 'refund r1 % %', r.refunded, r.balance; end if;
  perform pg_temp.buckets(org, 15, 40, 'after r1');

  select * into r from nomad_core.refund_credits(c1, 'job failed', 'r1', 15);
  if r.refunded <> 15 or (select count(*) from nomad_core.credit_ledger where organization_id = org and refund_of = c1) <> 1
  then raise exception 'refund replay'; end if;
  perform pg_temp.expect_err(format('select nomad_core.refund_credits(%L, ''other'', ''r1'', 15)', c1), '%idempotency key reused%');
  perform pg_temp.expect_err(format('select nomad_core.refund_credits(%L, ''job failed'', ''r1'', 16)', c1), '%idempotency key reused%');
  perform pg_temp.expect_err(format('select nomad_core.refund_credits(%L, ''job failed'', ''r1'')', c1), '%idempotency key reused%');

  -- pack 행 id로 불러도 같은 consume 묶음, 요청액이 상한보다 크면 상한까지
  select * into r from nomad_core.refund_credits(c1pack, 'job failed', 'r2', 999);
  if r.refunded <> 25 or r.balance <> 80 then raise exception 'refund r2 % %', r.refunded, r.balance; end if;
  perform pg_temp.buckets(org, 30, 50, 'after r2');
  if exists (select 1 from nomad_core.credit_ledger where organization_id = org and refund_of is not null and refund_of <> c1)
  then raise exception 'refund_of must point to primary row'; end if;
  select * into r from nomad_core.refund_credits(c1pack, 'job failed', 'r2', 999);
  if r.refunded <> 25 then raise exception 'clipped refund replay'; end if;

  select * into r from nomad_core.refund_credits(c1, 'job failed', 'r3');
  if r.ledger_id is not null or r.refunded <> 0 or r.balance <> 80
     or (select count(*) from nomad_core.credit_ledger where organization_id = org and refund_of = c1) <> 3
  then raise exception 'refund no-op'; end if;

  perform pg_temp.expect_err(format('select nomad_core.refund_credits(%L, ''x'', ''r4'')',
    (select id from nomad_core.credit_ledger where organization_id = org and idempotency_key = 'g1')), '%not a consume entry%');
  perform pg_temp.expect_err(format('select nomad_core.refund_credits(%L, ''x'', ''r5'', 0)', c1), '%amount must be positive%');
end;
$$;

-- 5. 만료 후 환불(plan 부분 0) · 0원 만료 완료 기록 · 지급 없는 기간
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1'); r record;
begin
  select * into r from nomad_core.consume_credits(org, 35, 'job', 'c3');   -- plan 30 + pack 5
  if r.plan_used <> 30 or r.pack_used <> 5 then raise exception 'c3 split'; end if;
  insert into t_ctx values ('c3', r.ledger_id::text);
  perform pg_temp.buckets(org, 0, 45, 'after c3');

  -- plan 전액 소진 후 만료 = 0이지만 완료 행을 남긴다
  if nomad_core.expire_plan_credits(org, '2026-11') <> 0 then raise exception 'zero expire'; end if;
  if (select count(*) from nomad_core.credit_ledger
      where organization_id = org and ref_type = 'plan_expire' and ref_id = '2026-11' and delta = 0) <> 1
  then raise exception 'zero expire must leave completion row'; end if;

  -- 만료 뒤 환불: plan 부분은 0, pack 부분만
  select * into r from nomad_core.refund_credits((select v::uuid from t_ctx where k = 'c3'), 'job failed', 'r7');
  if r.refunded <> 5 then raise exception 'refund after expire %', r.refunded; end if;
  perform pg_temp.buckets(org, 0, 50, 'after r7');

  -- 다음 기간 지급 뒤 이전 기간 만료 재호출은 기록된 0을 돌려주고 새 지급분을 지우지 않는다
  if nomad_core.grant_plan_credits(org, 4, '2026-12', 'monthly') <> 54 then raise exception 'dec grant'; end if;
  if nomad_core.expire_plan_credits(org, '2026-11') <> 0
     or (select count(*) from nomad_core.credit_ledger where organization_id = org and ref_type = 'plan_expire') <> 1
  then raise exception 'expire replay after next grant'; end if;
  perform pg_temp.buckets(org, 4, 50, 'after dec grant');
  -- 지연된 과거 기간 지급은 거부되고 12월 열린 기간은 그대로
  perform pg_temp.expect_err(format('select nomad_core.grant_plan_credits(%L, 9, ''2026-10'', ''monthly'')', org), '%stale period key%');
  perform pg_temp.buckets(org, 4, 50, 'after stale grant');

  if nomad_core.expire_plan_credits(org, '2026-10') <> 0
     or exists (select 1 from nomad_core.credit_ledger where organization_id = org and ref_id = '2026-10')
  then raise exception 'expire without grant'; end if;
  perform pg_temp.expect_err(format('select nomad_core.refund_credits(%L, ''x'', ''r6'')',
    (select id from nomad_core.credit_ledger where organization_id = org and ref_type = 'plan_expire')), '%not a consume entry%');
end;
$$;

-- 6. 기간 순서: 새 기간 지급이 열린 기간의 남은 plan을 먼저 만료, 이후 이전 기간 만료는 기록된 값
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  if nomad_core.grant_plan_credits(org, 7, '2027-01', 'monthly') <> 57 then raise exception 'jan grant'; end if;
  if (select delta from nomad_core.credit_ledger where organization_id = org and ref_type = 'plan_expire' and ref_id = '2026-12') <> -4
  then raise exception 'dec not auto-expired'; end if;
  perform pg_temp.buckets(org, 7, 50, 'after jan grant');
  if nomad_core.expire_plan_credits(org, '2026-12') <> 4
     or (select count(*) from nomad_core.credit_ledger where organization_id = org and ref_type = 'plan_expire') <> 2
  then raise exception 'dec expire replay'; end if;
  perform pg_temp.buckets(org, 7, 50, 'jan intact');
  if nomad_core.expire_plan_credits(org, '2027-01') <> 7 then raise exception 'jan expire'; end if;
  perform pg_temp.buckets(org, 0, 50, 'after jan expire');
  if nomad_core.grant_plan_credits(org, 10, '2027-02', 'monthly') <> 60 then raise exception 'feb grant'; end if;
end;
$$;

-- 7. 조직 격리: 다른 조직 잔액은 0이라 차감 불가, 같은 키도 조직별로 독립
do $$
declare org2 uuid := (select v::uuid from t_ctx where k = 'org2');
begin
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 1, ''job'', ''c1'')', org2), '%insufficient credits%');
  if nomad_core.grant_credits(org2, 3, 'pack', 'c1') <> 3 then raise exception 'per-org key'; end if;
end;
$$;

-- 8. 사용자 경로(spend): plan 먼저→pack, 예약 접두사 키 거부, 옛 형식 키를 써도 서버 만료는 영향 없음
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_spend_credits(%L, 1, 'x', 'nomad:plan_expire:2027-02')$q$,
  (select v from t_ctx where k = 'org1')), '%reserved idempotency key%');
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  if public.nomad_spend_credits(org, 1, 'x', 'plan_expire:2027-02') <> 59 then raise exception 'user spend old-style key'; end if;
  if public.nomad_spend_credits(org, 6, 'use', 's1') <> 53 then raise exception 'user spend'; end if;
  if public.nomad_credit_balance(org) <> 53 then raise exception 'user balance'; end if;
  if public.nomad_spend_credits(org, 6, 'use', 's1') <> 53 then raise exception 'user spend replay'; end if;
end;
$$;
-- 9. 사용자는 서버 함수 실행 불가
select pg_temp.expect_err(format($q$select nomad_core.consume_credits(%L, 1, 'x', 'u1')$q$, (select v from t_ctx where k = 'org1')), '%permission denied%');
select pg_temp.expect_err(format($q$select nomad_core.refund_credits(%L, 'x', 'u2')$q$, (select v from t_ctx where k = 'c1')), '%permission denied%');
select pg_temp.expect_err(format($q$select nomad_core.expire_plan_credits(%L, '2027-02')$q$, (select v from t_ctx where k = 'org1')), '%permission denied%');
select pg_temp.expect_err(format($q$select nomad_core.grant_plan_credits(%L, 9, '2027-03', 'x')$q$, (select v from t_ctx where k = 'org1')), '%permission denied%');
reset role;

-- 관리 세션이어도 사용자 JWT를 실은 경우 서버로 보지 않는다
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  perform pg_temp.expect_err(format('select nomad_core.consume_credits(%L, 1, ''x'', ''u4'')', org), '%server only%');
  perform pg_temp.expect_err(format('select nomad_core.expire_plan_credits(%L, ''2027-02'')', org), '%server only%');
end;
$$;
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);

do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org1');
begin
  perform pg_temp.buckets(org, 3, 50, 'before feb expire');
  if nomad_core.expire_plan_credits(org, '2027-02') <> 3 then raise exception 'feb expire after user key'; end if;
  perform pg_temp.buckets(org, 0, 50, 'final');
  if exists (select 1 from nomad_core.credit_ledger where idempotency_key in ('u1', 'u2', 'u3', 'u4')) then
    raise exception 'denied caller wrote a ledger row';
  end if;
end;
$$;

-- 0원 행은 plan_expire 외에는 직접 insert로도 금지(ref_type null이면 체크가 NULL로 통과하던 문제)
reset role;
select pg_temp.expect_err(
  $$insert into nomad_core.credit_ledger (organization_id, delta, reason, idempotency_key)
    select id, 0, 'x', 'zero-direct' from nomad_core.organizations limit 1$$, '%credit_ledger_delta_check%');

rollback;
\o
\echo 'credits: ok'
