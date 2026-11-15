-- 레이트 리밋 검증: 고정 윈도우 한도·리셋 · upsert 원자성 · 서버 전용 · RLS (합성 데이터, 롤백)
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

-- 1. 권한 표 · RLS
do $$
begin
  if has_function_privilege('authenticated', 'nomad_core.rate_limit_hit(text,integer,integer)', 'execute')
     or has_function_privilege('anon', 'nomad_core.rate_limit_hit(text,integer,integer)', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.purge_rate_limit_buckets(interval)', 'execute')
     or has_function_privilege('anon', 'nomad_core.purge_rate_limit_buckets(interval)', 'execute')
     or has_table_privilege('authenticated', 'nomad_core.rate_limit_buckets', 'select,insert,update,delete')
     or has_table_privilege('anon', 'nomad_core.rate_limit_buckets', 'select,insert,update,delete')
  then raise exception 'rate limit grants too wide'; end if;
  if not has_function_privilege('service_role', 'nomad_core.rate_limit_hit(text,integer,integer)', 'execute')
     or not has_function_privilege('service_role', 'nomad_core.purge_rate_limit_buckets(interval)', 'execute')
  then raise exception 'rate limit grants missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'nomad_core.rate_limit_buckets'::regclass)
  then raise exception 'rate_limit_buckets RLS off'; end if;
  -- 원자성: 조회 후 쓰기 두 문장이 아니라 한 문장 upsert(행 잠금으로 동시 호출 직렬화)
  if (select prosrc from pg_proc where oid = 'nomad_core.rate_limit_hit(text,integer,integer)'::regprocedure)
     not like '%on conflict (key) do update%'
  then raise exception 'rate_limit_hit is not a single upsert'; end if;
end $$;

-- 2. 서버 호출: 한도 3, 윈도우 60초
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare r record; i integer;
begin
  for i in 1..3 loop
    select * into r from nomad_core.rate_limit_hit('test:ip:1', 3, 60);
    if not r.allowed or r.remaining <> 3 - i then raise exception 'hit % should pass, got % %', i, r.allowed, r.remaining; end if;
  end loop;
  if r.reset_at < now() + interval '60 seconds' or r.reset_at > clock_timestamp() + interval '60 seconds' then raise exception 'reset_at wrong %', r.reset_at; end if;
  -- 윈도우 내 한도 초과 거부
  select * into r from nomad_core.rate_limit_hit('test:ip:1', 3, 60);
  if r.allowed or r.remaining <> 0 then raise exception 'hit 4 should be denied'; end if;
  -- 다른 키는 독립
  select * into r from nomad_core.rate_limit_hit('test:ip:2', 3, 60);
  if not r.allowed or r.remaining <> 2 then raise exception 'other key not independent'; end if;
end $$;

-- 입력 검증
select pg_temp.expect_err($$select nomad_core.rate_limit_hit('', 3, 60)$$, '%invalid key%');
select pg_temp.expect_err($$select nomad_core.rate_limit_hit('k', 0, 60)$$, '%must be >= 1%');
select pg_temp.expect_err($$select nomad_core.rate_limit_hit('k', 3, 0)$$, '%must be >= 1%');

-- 3. 윈도우 경과 후 리셋: 관리 세션에서 윈도우 시작을 61초 전으로 돌린다
reset role;
select set_config('request.jwt.claims', '', true);
-- 테이블은 service_role도 직접 못 읽으므로 관리 세션에서 확인. 같은 키 반복 호출도 행은 1개(upsert)
do $$
begin
  if (select count(*) from nomad_core.rate_limit_buckets where key = 'test:ip:1') <> 1 then raise exception 'duplicate bucket rows'; end if;
  if (select count from nomad_core.rate_limit_buckets where key = 'test:ip:1') <> 4 then raise exception 'count not 4'; end if;
end $$;
update nomad_core.rate_limit_buckets set window_start = now() - interval '61 seconds' where key = 'test:ip:1';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare r record;
begin
  select * into r from nomad_core.rate_limit_hit('test:ip:1', 3, 60);
  if not r.allowed or r.remaining <> 2 then raise exception 'window not reset (% %)', r.allowed, r.remaining; end if;
  if r.reset_at < now() + interval '60 seconds' or r.reset_at > clock_timestamp() + interval '60 seconds' then raise exception 'window_start not moved'; end if;
end $$;
-- 경계: 정확히 윈도우 길이만큼 지난 경우도 리셋
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.rate_limit_buckets set window_start = now() - interval '60 seconds', count = 99 where key = 'test:ip:2';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare r record;
begin
  select * into r from nomad_core.rate_limit_hit('test:ip:2', 3, 60);
  if not r.allowed or r.remaining <> 2 then raise exception 'boundary window not reset'; end if;
end $$;

-- 4. 정리 함수: 윈도우 끝 기준. 긴 윈도우(7일, 한도 1)는 마지막 히트가 2일 전이어도 남아 한도가 유지된다
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare r record;
begin
  select * into r from nomad_core.rate_limit_hit('test:long', 1, 604800);
  if not r.allowed then raise exception 'long window first hit denied'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.rate_limit_buckets set window_end = now() - interval '2 days' where key = 'test:ip:2';
update nomad_core.rate_limit_buckets
   set window_start = now() - interval '2 days', window_end = now() + interval '5 days', updated_at = now() - interval '2 days'
 where key = 'test:long';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select pg_temp.expect_err($$select nomad_core.purge_rate_limit_buckets(interval '-1 day')$$, '%must be >= 0%');
select pg_temp.expect_err($$select nomad_core.purge_rate_limit_buckets(null)$$, '%must be >= 0%');
do $$
declare r record;
begin
  if nomad_core.purge_rate_limit_buckets() <> 1 then raise exception 'purge count wrong'; end if;
  select * into r from nomad_core.rate_limit_hit('test:long', 1, 604800);
  if r.allowed then raise exception 'long window reset by purge'; end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from nomad_core.rate_limit_buckets where key = 'test:ip:2') then raise exception 'purge missed'; end if;
  if not exists (select 1 from nomad_core.rate_limit_buckets where key = 'test:ip:1') then raise exception 'purge removed fresh key'; end if;
end $$;
-- service_role도 테이블 직접 접근은 없다(함수로만)
set local role service_role;
select pg_temp.expect_err($$select count(*) from nomad_core.rate_limit_buckets$$, '%permission denied%');

-- 5. authenticated 거부: 직접 실행·테이블 접근, 그리고 definer 래퍼 경유(서버 판별)도 거부
reset role;
create function public.rate_limit_test_rpc() returns boolean
language sql security definer set search_path = ''
as $$ select allowed from nomad_core.rate_limit_hit('test:user', 3, 60) $$;
grant execute on function public.rate_limit_test_rpc() to authenticated, anon;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err($$select nomad_core.rate_limit_hit('test:user', 3, 60)$$, '%permission denied%');
select pg_temp.expect_err($$select nomad_core.purge_rate_limit_buckets()$$, '%permission denied%');
select pg_temp.expect_err($$select count(*) from nomad_core.rate_limit_buckets$$, '%permission denied%');
select pg_temp.expect_err($$insert into nomad_core.rate_limit_buckets (key, window_start, window_end) values ('x', now(), now())$$, '%permission denied%');
select pg_temp.expect_err($$select public.rate_limit_test_rpc()$$, '%server only%');

-- 6. anon 거부
set local role anon;
select set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.expect_err($$select nomad_core.rate_limit_hit('test:anon', 3, 60)$$, '%permission denied%');
select pg_temp.expect_err($$select count(*) from nomad_core.rate_limit_buckets$$, '%permission denied%');
select pg_temp.expect_err($$select public.rate_limit_test_rpc()$$, '%server only%');

reset role;
do $$
begin
  if exists (select 1 from nomad_core.rate_limit_buckets where key in ('test:user', 'test:anon')) then
    raise exception 'denied caller wrote a bucket';
  end if;
end $$;

-- 7. rate_limit_take(제품 definer RPC 내부용): execute grant 없음, 소유자 definer 래퍼 경유만 동작
do $$
begin
  if has_function_privilege('authenticated', 'nomad_core.rate_limit_take(text,integer,integer)', 'execute')
     or has_function_privilege('anon', 'nomad_core.rate_limit_take(text,integer,integer)', 'execute')
     or has_function_privilege('service_role', 'nomad_core.rate_limit_take(text,integer,integer)', 'execute')
  then raise exception 'rate_limit_take grants too wide'; end if;
  if (select prosrc from pg_proc where oid = 'nomad_core.rate_limit_take(text,integer,integer)'::regprocedure)
     not like '%on conflict (key) do update%'
  then raise exception 'rate_limit_take is not a single upsert'; end if;
end $$;
create function public.rate_limit_take_test_rpc() returns boolean
language sql security definer set search_path = ''
as $$ select allowed from nomad_core.rate_limit_take('test:take:' || coalesce(auth.uid()::text, 'anon'), 2, 60) $$;
grant execute on function public.rate_limit_take_test_rpc() to authenticated, anon;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err($$select nomad_core.rate_limit_take('test:direct', 3, 60)$$, '%permission denied%');
do $$
begin
  if not public.rate_limit_take_test_rpc() or not public.rate_limit_take_test_rpc() then raise exception 'take within limit denied'; end if;
  if public.rate_limit_take_test_rpc() then raise exception 'take over limit allowed'; end if;
end $$;
set local role anon;
select set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.expect_err($$select nomad_core.rate_limit_take('test:direct', 3, 60)$$, '%permission denied%');
do $$
begin
  if not public.rate_limit_take_test_rpc() then raise exception 'anon key not independent'; end if;
end $$;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select pg_temp.expect_err($$select nomad_core.rate_limit_take('test:direct', 3, 60)$$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.expect_err($$select nomad_core.rate_limit_take('', 3, 60)$$, '%invalid key%');
select pg_temp.expect_err($$select nomad_core.rate_limit_take('k:x', 3, 0)$$, '%must be >= 1%');
-- 키 형식: '<제품>:' 접두사(소문자·숫자·_) 필수
select pg_temp.expect_err($$select nomad_core.rate_limit_take('nokey', 3, 60)$$, '%invalid key%');
select pg_temp.expect_err($$select nomad_core.rate_limit_take('Erp:join:x', 3, 60)$$, '%invalid key%');
select pg_temp.expect_err($$select nomad_core.rate_limit_take(':join:x', 3, 60)$$, '%invalid key%');
select pg_temp.expect_err($$select nomad_core.rate_limit_take('erp-x:join', 3, 60)$$, '%invalid key%');
do $$
begin
  if (select count from nomad_core.rate_limit_buckets where key = 'test:take:00000000-0000-4000-8000-0000000000a1') <> 3
  then raise exception 'take count wrong'; end if;
  if exists (select 1 from nomad_core.rate_limit_buckets where key = 'test:direct') then raise exception 'direct take wrote a bucket'; end if;
end $$;

rollback;
\o
\echo 'rate_limit: ok'
