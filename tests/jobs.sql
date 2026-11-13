-- 작업 큐 검증: 권한 표 · enqueue 멱등·크레딧 연결 검증 · 클레임(SKIP LOCKED)·하트비트·완료 · 재시도 백오프·최종 실패 환불
--   · 환불 no-op · reap 반복 안전 · 결과 전달 표시(mark_job_delivered) · 사용자 목록(본문 제외)·취소(생성자/owner·admin, 조직 격리) (합성 데이터, 롤백)
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

create temp table t_ctx (k text primary key, v text);
grant all on t_ctx to authenticated, anon;
create function pg_temp.ctx(key text) returns uuid language sql as $$ select v::uuid from t_ctx where k = key $$;
grant execute on function pg_temp.ctx(text) to authenticated, anon;

-- 1. 권한 표: 워커 함수는 service_role만, 내부 도우미는 아무에게도, 사용자 RPC는 authenticated만, 테이블은 service_role 읽기만
do $$
declare f text;
begin
  foreach f in array array[
    'nomad_core.enqueue_job(uuid,text,text,jsonb,text,integer,timestamptz,integer,uuid,text,uuid,uuid,boolean)',
    'nomad_core.claim_jobs(text,text,integer,text[],text)',
    'nomad_core.heartbeat_job(uuid,text,integer,integer,text)',
    'nomad_core.complete_job(uuid,text,integer,jsonb)',
    'nomad_core.fail_job(uuid,text,integer,text,boolean,integer)',
    'nomad_core.reap_stale_jobs(integer,integer)',
    'nomad_core.cancel_job(uuid)'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'grant too wide: %', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'grant missing: %', f; end if;
  end loop;
  -- 내부 도우미·환불 본문(서버 판별 없음)은 어떤 API 역할도 직접 실행 불가
  foreach f in array array['nomad_core.refund_job_credits(nomad_core.jobs,text)',
                           'nomad_core.refund_credits_internal(uuid,text,text,integer)',
                           'nomad_core.mark_job_delivered(uuid)'] loop
    if has_function_privilege('service_role', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute') or has_function_privilege('public', f, 'execute') then
      raise exception 'internal helper granted: %', f;
    end if;
  end loop;
  -- refund_credits 래퍼는 기존 권한 그대로(service_role만)
  if not has_function_privilege('service_role', 'nomad_core.refund_credits(uuid,text,text,integer)', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.refund_credits(uuid,text,text,integer)', 'execute')
     or has_function_privilege('anon', 'nomad_core.refund_credits(uuid,text,text,integer)', 'execute') then
    raise exception 'refund_credits grants changed';
  end if;
  foreach f in array array['public.nomad_my_jobs(uuid,integer,timestamptz,uuid)', 'public.nomad_cancel_job(uuid)'] loop
    if not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'user rpc grant wrong: %', f;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'nomad_core.jobs', 'select') or has_table_privilege('anon', 'nomad_core.jobs', 'select')
     or not has_table_privilege('service_role', 'nomad_core.jobs', 'select')
     or has_table_privilege('service_role', 'nomad_core.jobs', 'insert')
     or has_table_privilege('service_role', 'nomad_core.jobs', 'update')
     or has_table_privilege('service_role', 'nomad_core.jobs', 'delete') then
    raise exception 'table grants wrong';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'nomad_core.jobs'::regclass) then raise exception 'rls off'; end if;
  -- 사용자 목록은 본문·오류·워커·크레딧 연결을 주지 않는다
  if exists (select 1 from pg_proc p, unnest(p.proargnames) a
             where p.oid = 'public.nomad_my_jobs(uuid,integer,timestamptz,uuid)'::regprocedure
               and a in ('payload', 'result', 'last_error', 'locked_by', 'credit_ledger_id', 'idempotency_key')) then
    raise exception 'nomad_my_jobs exposes body columns';
  end if;
end;
$$;

-- 합성 사용자: a(조직1 owner) · b(조직2 owner) · c(조직1 editor)
insert into nomad_core.products (code, name) values ('jobs_test', '작업 큐 테스트');
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000a1', 'jobs-a@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a2', 'jobs-b@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a3', 'jobs-c@example.test', now(), false, '{}');
insert into t_ctx
select 'org' || right(m.user_id::text, 1), m.organization_id::text
from nomad_core.memberships m
where m.user_id in ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a2') and m.role = 'owner';
insert into nomad_core.memberships (organization_id, user_id, role)
values (pg_temp.ctx('org1'), '00000000-0000-4000-8000-0000000000a3', 'editor');

-- 2. enqueue: 크레딧 연결 검증 · 멱등
do $$
declare
  org uuid := pg_temp.ctx('org1'); org2 uuid := pg_temp.ctx('org2');
  l1 uuid; l2 uuid; lp uuid; lpack uuid; j nomad_core.jobs; j2 nomad_core.jobs;
begin
  perform nomad_core.grant_credits(org, 100, 'pack', 'jg1');
  perform nomad_core.grant_credits(org2, 100, 'pack', 'jg2');
  select ledger_id into l1 from nomad_core.consume_credits(org, 10, 'job', 'jc1', 'jobs_test', 'job', 'render');
  select ledger_id into l2 from nomad_core.consume_credits(org2, 10, 'job', 'jc2');
  insert into t_ctx values ('l1', l1);

  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{"in":1}', 'jq', 100, null, 3, l1, 'k1');
  insert into t_ctx values ('j1', j.id);
  if j.status <> 'queued' or j.attempts <> 0 then raise exception 'enqueue state'; end if;
  j2 := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{"in":1}', 'jq', 100, null, 3, l1, 'k1');
  if j2.id <> j.id or (select count(*) from nomad_core.jobs where organization_id = org) <> 1 then raise exception 'enqueue replay'; end if;
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{"in":2}', 'jq', 100, null, 3, %L, 'k1')$q$, org, l1),
    '%idempotency key reused%');
  -- 환불 여부·생성자·최대 시도·부모가 달라도 다른 요청
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{"in":1}', 'jq', 100, null, 3, %L, 'k1',
    p_refund_on_failure => false)$q$, org, l1), '%idempotency key reused%');
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{"in":1}', 'jq', 100, null, 3, %L, 'k1',
    p_created_by => '00000000-0000-4000-8000-0000000000a1')$q$, org, l1), '%idempotency key reused%');
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{"in":1}', 'jq', 100, null, 5, %L, 'k1')$q$,
    org, l1), '%idempotency key reused%');
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{"in":1}', 'jq', 100, null, 3, %L, 'k1',
    p_parent_job_id => %L)$q$, org, l1, j.id), '%idempotency key reused%');
  -- 같은 consume을 두 작업에 연결 금지
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{}', 'jq', 100, null, 3, %L, 'k2')$q$, org, l1),
    '%already linked%');
  -- 다른 조직의 consume · 지급 행 · 다른 제품으로 기록된 consume 거부
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{}', 'jq', 100, null, 3, %L)$q$, org, l2),
    '%not a consume of this organization%');
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{}', 'jq', 100, null, 3, %L)$q$, org,
    (select id from nomad_core.credit_ledger where organization_id = org and idempotency_key = 'jg1')), '%not a consume of this organization%');
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'contentflow_example', 'render', '{}', 'jq', 100, null, 3, %L)$q$,
    org, l1), '%not a consume of this organization%');
  -- plan·pack 두 행에 걸친 consume은 대표(plan) 행만
  perform nomad_core.grant_plan_credits(org, 5, '2026-11', 'monthly');
  select ledger_id into lp from nomad_core.consume_credits(org, 8, 'job', 'jc-split');
  select id into lpack from nomad_core.credit_ledger where organization_id = org and idempotency_key = 'jc-split' and bucket = 'pack';
  if (select bucket from nomad_core.credit_ledger where id = lp) <> 'plan' then raise exception 'primary not plan'; end if;
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'render', '{}', 'jq', 100, null, 3, %L)$q$, org, lpack),
    '%primary consume entry%');
  -- 부모는 같은 조직, 생성자는 조직 멤버
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'x', p_parent_job_id => %L)$q$, org2, j.id),
    '%parent job not in organization%');
  perform pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'x', p_created_by => %L)$q$, org2,
    '00000000-0000-4000-8000-0000000000a3'), '%creator is not a member%');
  -- 분할 consume 작업(최대 시도 1) — 4장에서 최종 실패 환불이 plan·pack 모두 되돌리는지 본다
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq', 200, null, 1, lp, 'k-split');
  insert into t_ctx values ('jsplit', j.id), ('lp', lp);
end;
$$;

-- 3. 클레임·하트비트·재시도 백오프·최종 실패 환불
do $$
declare
  org uuid := pg_temp.ctx('org1'); j1 uuid := pg_temp.ctx('j1'); l1 uuid := pg_temp.ctx('l1');
  j nomad_core.jobs; n integer; bal integer;
begin
  -- 우선순위 순(100인 j1이 200인 분할 작업보다 먼저), 한 번 잡힌 작업은 다시 안 잡힌다
  select * into j from nomad_core.claim_jobs('jq', 'w1', 1);
  if j.id <> j1 or j.status <> 'running' or j.attempts <> 1 or j.locked_by <> 'w1' then raise exception 'claim'; end if;
  if (select count(*) from nomad_core.claim_jobs('jq', 'w2', 10, array['nope'])) <> 0 then raise exception 'job type filter'; end if;
  if (select count(*) from nomad_core.claim_jobs('jq', 'w2', 10, null, 'contentflow_example')) <> 0 then raise exception 'product filter'; end if;

  if nomad_core.heartbeat_job(j1, 'w2', 1, 10) then raise exception 'foreign heartbeat'; end if;
  if nomad_core.heartbeat_job(j1, 'w1', 0, 10) then raise exception 'wrong attempt heartbeat'; end if;
  if not nomad_core.heartbeat_job(j1, 'w1', 1, 50, 'half') then raise exception 'heartbeat'; end if;
  if (select progress from nomad_core.jobs where id = j1) <> 50 then raise exception 'progress'; end if;
  perform pg_temp.expect_err(format('select nomad_core.complete_job(%L, ''w2'', 1)', j1), '%not running under worker%');
  perform pg_temp.expect_err(format('select nomad_core.complete_job(%L, ''w1'', 2)', j1), '%not running under worker%');

  -- 재시도: queued로 돌아가고 run_after가 미래라 바로 다시 잡히지 않는다
  j := nomad_core.fail_job(j1, 'w1', 1, 'boom', true, 60);
  if j.status <> 'queued' or j.locked_by is not null or j.last_error <> 'boom' then raise exception 'retry'; end if;
  if j.run_after <> now() + interval '60 seconds' then raise exception 'backoff 1: %', j.run_after - now(); end if;
  if exists (select 1 from nomad_core.claim_jobs('jq', 'w1', 1, array['render'], 'jobs_test') c where c.id = j1) then
    raise exception 'claimed before backoff';
  end if;
  -- (위 클레임이 분할 작업을 잡았을 수 있으므로 그대로 둔다 — 4장에서 처리)
  update nomad_core.jobs set run_after = now() where id = j1;
  select * into j from nomad_core.claim_jobs('jq', 'w1', 1) c where c.id = j1;
  if j.attempts <> 2 then raise exception 'second claim attempts %', j.attempts; end if;
  -- 멈췄던 이전 시도(같은 워커 id, attempts 1)는 새 시도를 덮지 못한다
  if nomad_core.heartbeat_job(j1, 'w1', 1, 99) then raise exception 'stale attempt heartbeat'; end if;
  perform pg_temp.expect_err(format('select nomad_core.complete_job(%L, ''w1'', 1, ''{"old":1}'')', j1), '%not running under worker%');
  perform pg_temp.expect_err(format('select nomad_core.fail_job(%L, ''w1'', 1, ''old'')', j1), '%not running under worker%');
  if (select status <> 'running' or progress = 99 or result is not null from nomad_core.jobs where id = j1) then
    raise exception 'stale attempt overwrote';
  end if;
  -- 백오프 지수 증가: 두 번째 실패는 60 × 2
  j := nomad_core.fail_job(j1, 'w1', 2, 'boom2', true, 60);
  if j.status <> 'queued' or j.run_after <> now() + interval '120 seconds' then raise exception 'backoff 2: %', j.run_after - now(); end if;
  update nomad_core.jobs set run_after = now() where id = j1;
  select * into j from nomad_core.claim_jobs('jq', 'w1', 1) c where c.id = j1;
  if j.attempts <> 3 then raise exception 'third claim attempts %', j.attempts; end if;

  -- 재시도 불가 실패 = 최종 실패 + 환불(10 전부)
  bal := nomad_core.credit_balance(org);
  j := nomad_core.fail_job(j1, 'w1', 3, 'fatal', false);
  if j.status <> 'failed' or j.finished_at is null then raise exception 'final fail'; end if;
  if (select sum(delta) from nomad_core.credit_ledger where refund_of = l1) <> 10
     or (select count(*) from nomad_core.credit_ledger where refund_of = l1 and reason = 'job_failed') <> 1 then
    raise exception 'refund on fail';
  end if;
  if nomad_core.credit_balance(org) <> bal + 10 then raise exception 'balance after refund'; end if;
  perform pg_temp.expect_err(format('select nomad_core.fail_job(%L, ''w1'', 3, ''again'')', j1), '%not running under worker%');

  -- 백오프 상한 86400초: 1회차 86400, 2회차 86400 × 2 → 86400
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jqcap', 100, null, 20);
  perform 1 from nomad_core.claim_jobs('jqcap', 'w1');
  j := nomad_core.fail_job(j.id, 'w1', 1, 'x', true, 86400);
  if j.run_after <> now() + interval '86400 seconds' then raise exception 'cap 1: %', j.run_after - now(); end if;
  update nomad_core.jobs set run_after = now() where id = j.id;
  perform 1 from nomad_core.claim_jobs('jqcap', 'w1');
  j := nomad_core.fail_job(j.id, 'w1', 2, 'x', true, 86400);
  if j.run_after <> now() + interval '86400 seconds' then raise exception 'cap 2: %', j.run_after - now(); end if;
  perform pg_temp.expect_err(format('select nomad_core.fail_job(%L, ''w1'', 2, ''x'', true, 86401)', j.id), '%retry delay%');
end;
$$;

-- 4. 최대 시도 도달 = 재시도 요청이어도 최종 실패 · 분할 consume은 plan·pack 모두 환불
do $$
declare js uuid := pg_temp.ctx('jsplit'); lp uuid := pg_temp.ctx('lp'); j nomad_core.jobs;
begin
  if (select status from nomad_core.jobs where id = js) = 'queued' then
    perform 1 from nomad_core.claim_jobs('jq', 'w3', 1) c where c.id = js;
  end if;
  j := nomad_core.fail_job(js, (select locked_by from nomad_core.jobs where id = js), 1, 'boom', true);
  if j.status <> 'failed' or j.attempts <> 1 then raise exception 'max attempts'; end if;
  if (select sum(delta) from nomad_core.credit_ledger where refund_of = lp) <> 8
     or (select count(distinct bucket) from nomad_core.credit_ledger where refund_of = lp) <> 2 then
    raise exception 'split refund';
  end if;
end;
$$;

-- 5. 환불 no-op: consume이 이미 다 환불됐으면 최종 실패는 오류 없이 행을 더 쓰지 않는다
do $$
declare org uuid := pg_temp.ctx('org1'); l3 uuid; j nomad_core.jobs;
begin
  select ledger_id into l3 from nomad_core.consume_credits(org, 4, 'job', 'jc3');
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq3', 100, null, 1, l3);
  perform nomad_core.refund_credits(l3, 'manual', 'm1');
  perform 1 from nomad_core.claim_jobs('jq3', 'w1');
  j := nomad_core.fail_job(j.id, 'w1', 1, 'x', false);
  if j.status <> 'failed' or (select count(*) from nomad_core.credit_ledger where refund_of = l3) <> 1 then
    raise exception 'refund no-op';
  end if;
  -- refund_on_failure = false면 환불하지 않는다
  select ledger_id into l3 from nomad_core.consume_credits(org, 2, 'job', 'jc4');
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq3', 100, null, 1, l3, p_refund_on_failure => false);
  perform 1 from nomad_core.claim_jobs('jq3', 'w1');
  perform nomad_core.fail_job(j.id, 'w1', 1, 'x', false);
  if exists (select 1 from nomad_core.credit_ledger where refund_of = l3) then raise exception 'refund despite flag'; end if;
end;
$$;

-- 6. reap: 끊긴 작업 재대기 → 반복 호출 0 → 마지막 시도에서 최종 실패 + 환불 1회
do $$
declare org uuid := pg_temp.ctx('org1'); l4 uuid; j nomad_core.jobs; n integer;
begin
  select ledger_id into l4 from nomad_core.consume_credits(org, 3, 'job', 'jc5');
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq4', 100, null, 2, l4);
  perform 1 from nomad_core.claim_jobs('jq4', 'w1');
  if nomad_core.reap_stale_jobs(600) <> 0 then raise exception 'reaped fresh job'; end if;
  update nomad_core.jobs set heartbeat_at = now() - interval '1 hour' where id = j.id;
  -- 같은 문장 안의 부분 조회는 호출 전 스냅숏을 보므로 결과를 먼저 변수로 받는다
  n := nomad_core.reap_stale_jobs(600);
  if n <> 1 or (select status from nomad_core.jobs where id = j.id) <> 'queued' then
    raise exception 'reap retry';
  end if;
  if nomad_core.reap_stale_jobs(600) <> 0 then raise exception 'reap repeat'; end if;
  update nomad_core.jobs set run_after = now() where id = j.id;
  perform 1 from nomad_core.claim_jobs('jq4', 'w2');
  update nomad_core.jobs set heartbeat_at = now() - interval '1 hour' where id = j.id;
  n := nomad_core.reap_stale_jobs(600);
  if n <> 1 or (select status from nomad_core.jobs where id = j.id) <> 'failed' then
    raise exception 'reap final';
  end if;
  n := nomad_core.reap_stale_jobs(600);
  if n <> 0 or (select sum(delta) from nomad_core.credit_ledger where refund_of = l4) <> 3
     or (select count(*) from nomad_core.credit_ledger where refund_of = l4) <> 1 then
    raise exception 'reap refund once';
  end if;
  perform pg_temp.expect_err('select nomad_core.reap_stale_jobs(0)', '%stale seconds%');
  perform pg_temp.expect_err('select nomad_core.reap_stale_jobs(600, 0)', '%limit must be%');
  -- 처리 상한: 끊긴 작업 2건을 p_limit 1로 한 건씩
  perform nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq8');
  perform nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq8');
  perform 1 from nomad_core.claim_jobs('jq8', 'w1', 2);
  update nomad_core.jobs set heartbeat_at = now() - interval '1 hour' where queue = 'jq8';
  n := nomad_core.reap_stale_jobs(600, 1);
  if n <> 1 then raise exception 'reap limit 1st %', n; end if;
  n := nomad_core.reap_stale_jobs(600, 1);
  if n <> 1 then raise exception 'reap limit 2nd %', n; end if;
  n := nomad_core.reap_stale_jobs(600, 1);
  if n <> 0 or exists (select 1 from nomad_core.jobs where queue = 'jq8' and status = 'running') then raise exception 'reap limit end'; end if;
end;
$$;

-- 7. 완료
do $$
declare org uuid := pg_temp.ctx('org1'); j nomad_core.jobs;
begin
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{"secret":"in"}', 'jq5');
  perform 1 from nomad_core.claim_jobs('jq5', 'w1');
  j := nomad_core.complete_job(j.id, 'w1', 1, '{"out":1}');
  if j.status <> 'succeeded' or j.progress <> 100 or j.locked_by is not null then raise exception 'complete'; end if;
  perform pg_temp.expect_err(format('select nomad_core.complete_job(%L, ''w1'', 1)', j.id), '%not running under worker%');
  -- 사용자 취소 시험용 작업: c 생성(크레딧 연결) · a 생성 · 조직2 · running
  insert into t_ctx values
    ('jc', (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq6', p_created_by => '00000000-0000-4000-8000-0000000000a3',
            p_credit_ledger_id => (select ledger_id from nomad_core.consume_credits(org, 5, 'job', 'jc6')))).id),
    ('ja', (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq6', p_created_by => '00000000-0000-4000-8000-0000000000a1')).id),
    ('jo2', (nomad_core.enqueue_job(pg_temp.ctx('org2'), 'jobs_test', 'render', '{}', 'jq6')).id),
    ('jr', (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq7', p_created_by => '00000000-0000-4000-8000-0000000000a3')).id);
  perform 1 from nomad_core.claim_jobs('jq7', 'w1');
  insert into t_ctx values
    ('jnr', (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq6', p_created_by => '00000000-0000-4000-8000-0000000000a3',
             p_refund_on_failure => false,
             p_credit_ledger_id => (select ledger_id from nomad_core.consume_credits(org, 7, 'job', 'jc7')))).id),
    ('jsv', (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq6')).id);
end;
$$;

-- 7b. 결과 전달 표시(mark_job_delivered): queued·running만 환불 끔 · 반복 안전 · 끝난 작업은 그대로 · 이후 최종 실패는 환불 없음
do $$
declare org uuid := pg_temp.ctx('org1'); l5 uuid; j nomad_core.jobs; jd uuid;
begin
  select ledger_id into l5 from nomad_core.consume_credits(org, 6, 'job', 'jc8');
  j := nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq9', 100, null, 1, l5);
  perform 1 from nomad_core.claim_jobs('jq9', 'w1');
  perform nomad_core.mark_job_delivered(j.id);
  perform nomad_core.mark_job_delivered(j.id);
  if (select refund_on_failure from nomad_core.jobs where id = j.id) then raise exception 'mark delivered running'; end if;
  perform nomad_core.fail_job(j.id, 'w1', 1, 'after delivery', false);
  if exists (select 1 from nomad_core.credit_ledger where refund_of = l5) then raise exception 'refund after delivery'; end if;
  -- queued도 표시된다
  jd := (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq9')).id;
  perform nomad_core.mark_job_delivered(jd);
  if (select refund_on_failure from nomad_core.jobs where id = jd) then raise exception 'mark delivered queued'; end if;
  -- 끝난 작업(succeeded)과 없는 작업은 그대로(오류 없음)
  jd := (nomad_core.enqueue_job(org, 'jobs_test', 'render', '{}', 'jq10')).id;
  perform 1 from nomad_core.claim_jobs('jq10', 'w1');
  perform nomad_core.complete_job(jd, 'w1', 1);
  perform nomad_core.mark_job_delivered(jd);
  perform nomad_core.mark_job_delivered(gen_random_uuid());
  if not (select refund_on_failure from nomad_core.jobs where id = jd) then raise exception 'mark delivered finished'; end if;
end;
$$;
-- API 역할은 직접 호출 불가
set local role service_role;
select pg_temp.expect_err('select nomad_core.mark_job_delivered(gen_random_uuid())', '%permission denied%');
reset role;

-- 서버(service_role JWT) 취소: 감사 actor_role = service, actor_id 없음
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_core.cancel_job(pg_temp.ctx('jsv'));
select set_config('request.jwt.claims', '', true);
do $$
begin
  if (select count(*) from nomad_core.audit_log where action = 'job.cancel' and target_id = pg_temp.ctx('jsv')::text
      and actor_role = 'service' and actor_id is null) <> 1 then
    raise exception 'server cancel audit actor_role';
  end if;
end;
$$;
insert into t_ctx select 'cnt', count(*)::text from nomad_core.jobs where organization_id = pg_temp.ctx('org1');

-- 8. 관리 세션이어도 사용자 JWT를 실은 경우 서버로 보지 않는다
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select nomad_core.enqueue_job(%L, 'jobs_test', 'x')$q$, pg_temp.ctx('org1')), '%server only%');
select pg_temp.expect_err($q$select nomad_core.claim_jobs('jq6', 'evil')$q$, '%server only%');
select pg_temp.expect_err('select nomad_core.reap_stale_jobs()', '%server only%');

-- 9. 사용자(editor c): 목록·취소
set local role authenticated;
select pg_temp.expect_err('select * from nomad_core.jobs', '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.claim_jobs('jq6', 'evil')$q$, '%permission denied%');
select pg_temp.expect_err(format('select nomad_core.cancel_job(%L)', pg_temp.ctx('ja')), '%permission denied%');
select pg_temp.expect_err(format($q$select nomad_core.refund_credits_internal(%L, 'x', 'evil')$q$, pg_temp.ctx('l1')), '%permission denied%');
select pg_temp.expect_err(format($q$select nomad_core.refund_credits(%L, 'x', 'evil')$q$, pg_temp.ctx('l1')), '%permission denied%');
select pg_temp.expect_err(format('select * from public.nomad_my_jobs(%L)', pg_temp.ctx('org2')), '%forbidden%');
do $$
declare org uuid := pg_temp.ctx('org1'); n integer; bal integer;
  g_role text := current_setting('request.jwt.claim.role', true); g_claims text := current_setting('request.jwt.claims', true);
begin
  select count(*) into n from public.nomad_my_jobs(org, 200);
  if n <> (select v::integer from t_ctx where k = 'cnt') then raise exception 'my_jobs count %', n; end if;
  if (select count(*) from public.nomad_my_jobs(org, 2)) <> 2 then raise exception 'page size'; end if;
  -- 커서: 3건씩 넘기면 겹치거나 빠짐 없이 전체를 돈다(같은 트랜잭션이라 created_at이 같아 id 순 동점 처리도 검증)
  declare c_at timestamptz; c_id uuid; seen uuid[] := '{}'; r record; got integer;
  begin
    loop
      got := 0;
      for r in select * from public.nomad_my_jobs(org, 3, c_at, c_id) loop
        if r.id = any (seen) then raise exception 'cursor overlap'; end if;
        seen := seen || r.id; c_at := r.created_at; c_id := r.id; got := got + 1;
      end loop;
      exit when got < 3;
    end loop;
    if cardinality(seen) <> n then raise exception 'cursor walk % of %', cardinality(seen), n; end if;
  end;

  bal := public.nomad_credit_balance(org);
  if public.nomad_cancel_job(pg_temp.ctx('jc')) <> 'canceled' then raise exception 'creator cancel'; end if;
  if public.nomad_credit_balance(org) <> bal + 5 then raise exception 'cancel refund'; end if;
  -- refund_on_failure = false여도 실행 전 취소는 환불
  if public.nomad_cancel_job(pg_temp.ctx('jnr')) <> 'canceled' then raise exception 'cancel jnr'; end if;
  if public.nomad_credit_balance(org) <> bal + 12 then
    raise exception 'cancel refund despite flag';
  end if;
  -- 취소·환불 경로는 role GUC를 바꾸지 않는다(서버 판별 우회 없음)
  if current_setting('request.jwt.claim.role', true) is distinct from g_role
     or current_setting('request.jwt.claims', true) is distinct from g_claims
     or nomad_core.jwt_role() <> 'authenticated' or nomad_core.is_service_caller() then
    raise exception 'role GUC changed by cancel';
  end if;
end;
$$;
select pg_temp.expect_err(format('select public.nomad_cancel_job(%L)', pg_temp.ctx('jc')), '%only queued%');
select pg_temp.expect_err(format('select public.nomad_cancel_job(%L)', pg_temp.ctx('ja')), '%forbidden%');
select pg_temp.expect_err(format('select public.nomad_cancel_job(%L)', pg_temp.ctx('jo2')), '%not found%');
select pg_temp.expect_err(format('select public.nomad_cancel_job(%L)', pg_temp.ctx('jr')), '%only queued%');
select pg_temp.expect_err(format('select public.nomad_cancel_job(%L)', gen_random_uuid()), '%not found%');

-- owner a는 남이 만든 작업도 취소
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select public.nomad_cancel_job(pg_temp.ctx('ja'));
-- 다른 조직 owner b는 조직1 작업을 볼 수도 취소할 수도 없다
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}', true);
select pg_temp.expect_err(format('select * from public.nomad_my_jobs(%L)', pg_temp.ctx('org1')), '%forbidden%');
select pg_temp.expect_err(format('select public.nomad_cancel_job(%L)', pg_temp.ctx('jr')), '%not found%');
do $$
begin
  if (select count(*) from public.nomad_my_jobs(pg_temp.ctx('org2'))) <> 1 then raise exception 'org2 sees own'; end if;
end;
$$;
reset role;

-- anon은 사용자 RPC도 실행 불가
set local role anon;
select pg_temp.expect_err(format('select * from public.nomad_my_jobs(%L)', pg_temp.ctx('org1')), '%permission denied%');
reset role;
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);

-- 10. 취소 결과: 상태·환불 행(사용자 = 취소자)·감사 기록
do $$
begin
  if (select status from nomad_core.jobs where id = pg_temp.ctx('ja')) <> 'canceled' then raise exception 'owner cancel'; end if;
  if (select status from nomad_core.jobs where id = pg_temp.ctx('jo2')) <> 'queued'
     or (select status from nomad_core.jobs where id = pg_temp.ctx('jr')) <> 'running' then raise exception 'denied cancel changed'; end if;
  -- consume이 plan·pack에 걸쳤을 수 있으므로 합계와 행 속성으로 본다
  if (select sum(l.delta) filter (where l.reason = 'job_canceled' and l.created_by = '00000000-0000-4000-8000-0000000000a3')
             is distinct from sum(l.delta) or sum(l.delta) <> 5
      from nomad_core.credit_ledger l join nomad_core.jobs j on l.refund_of = j.credit_ledger_id
      where j.id = pg_temp.ctx('jc')) then
    raise exception 'cancel refund row';
  end if;
  if (select count(*) from nomad_core.audit_log where action = 'job.cancel'
      and target_id in (pg_temp.ctx('jc')::text, pg_temp.ctx('ja')::text)) <> 2 then
    raise exception 'cancel audit';
  end if;
  if exists (select 1 from nomad_core.jobs where locked_by = 'evil') then raise exception 'denied claim wrote'; end if;
end;
$$;

-- 직접 쓰기는 소유자 외에 불가(service_role 포함)
set local role service_role;
select pg_temp.expect_err($q$update nomad_core.jobs set status = 'succeeded'$q$, '%permission denied%');
reset role;

rollback;
\o
\echo 'jobs: ok'
