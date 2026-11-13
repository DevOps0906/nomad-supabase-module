-- 감사 로그 검증: 추가 전용 · 서버만 쓰기 · owner/admin만 자기 조직 읽기 (합성 데이터, 롤백)
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

-- a1 조직A owner · a2 조직A viewer · b1 조직B owner
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000a1', 'a-owner@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a2', 'a-viewer@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000b1', 'b-owner@example.test', now(), false, '{}');
insert into nomad_core.organizations (id, name, kind) values
 ('00000000-0000-4000-8000-00000000a0a0', '감사 A팀', 'team'),
 ('00000000-0000-4000-8000-00000000b0b0', '감사 B팀', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a1', 'owner'),
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a2', 'viewer'),
 ('00000000-0000-4000-8000-00000000b0b0', '00000000-0000-4000-8000-0000000000b1', 'owner');

-- 사용자 RPC 흉내: postgres 소유 SECURITY DEFINER 함수(롤백으로 사라짐)
create function public.audit_test_rpc() returns bigint
language sql security definer set search_path = ''
as $$ select nomad_core.write_audit(null, 'test.user_rpc') $$;
create function public.audit_test_priv() returns boolean
language sql security definer set search_path = ''
as $$ select nomad_core.is_privileged_session() or nomad_core.is_service_caller() $$;
grant execute on function public.audit_test_rpc(), public.audit_test_priv() to authenticated;

-- 1. 권한 표
do $$
begin
  if has_function_privilege('authenticated', 'nomad_core.write_audit(uuid,text,text,text,jsonb,jsonb,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.nomad_audit_log(uuid,integer,bigint)', 'execute')
     or has_table_privilege('authenticated', 'nomad_core.audit_log', 'select')
     or has_table_privilege('authenticated', 'nomad_core.audit_log', 'insert')
     or has_table_privilege('service_role', 'nomad_core.audit_log', 'update')
     or has_table_privilege('service_role', 'nomad_core.audit_log', 'delete')
  then raise exception 'audit grants too wide'; end if;
  if not has_function_privilege('service_role', 'nomad_core.write_audit(uuid,text,text,text,jsonb,jsonb,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.nomad_audit_log(uuid,integer,bigint)', 'execute')
  then raise exception 'audit grants missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'nomad_core.audit_log'::regclass)
  then raise exception 'audit_log RLS off'; end if;
end $$;

-- 2. 서버 쓰기: service_role만, actor_role은 service
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_core.write_audit('00000000-0000-4000-8000-00000000a0a0', 'test.a1', 'thing', '1', null, '{"k":1}'::jsonb);
select nomad_core.write_audit('00000000-0000-4000-8000-00000000a0a0', 'test.a2');
select nomad_core.write_audit('00000000-0000-4000-8000-00000000b0b0', 'test.b1');
do $$
begin
  if (select count(*) from nomad_core.audit_log) <> 3 then raise exception 'service write count'; end if;
  if exists (select 1 from nomad_core.audit_log where actor_role <> 'service') then raise exception 'actor_role not service'; end if;
end $$;

-- 3. 추가 전용: service_role도 update·delete·truncate 거부(권한 또는 트리거)
select pg_temp.expect_err($q$update nomad_core.audit_log set action = 'x'$q$, '%permission denied%');
select pg_temp.expect_err($q$delete from nomad_core.audit_log$q$, '%permission denied%');
select pg_temp.expect_err($q$truncate nomad_core.audit_log$q$, '%permission denied%');
reset role;
-- 관리 세션(postgres)도 트리거가 막는다
select set_config('request.jwt.claims', '', true);
select pg_temp.expect_err($q$update nomad_core.audit_log set action = 'x'$q$, '%append-only%');
select pg_temp.expect_err($q$delete from nomad_core.audit_log$q$, '%append-only%');
select pg_temp.expect_err($q$truncate nomad_core.audit_log$q$, '%append-only%');
-- JWT 없는 postgres 세션 = 서버, actor_role은 system
do $$
declare v_id bigint;
begin
  if not nomad_core.is_service_caller() or not nomad_core.is_privileged_session() then raise exception 'admin session not server'; end if;
  v_id := nomad_core.write_audit(null, 'test.system');
  if (select actor_role from nomad_core.audit_log where id = v_id) <> 'system' then raise exception 'actor_role not system'; end if;
end $$;

-- 4. authenticated: 직접 읽기·쓰기·write_audit 거부
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err($q$select * from nomad_core.audit_log$q$, '%permission denied%');
select pg_temp.expect_err($q$insert into nomad_core.audit_log (action) values ('forged')$q$, '%permission denied%');
select pg_temp.expect_err($q$update nomad_core.audit_log set action = 'x'$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.write_audit(null, 'forged')$q$, '%permission denied%');
-- 사용자 RPC(definer) 안에서 write_audit 성공, actor는 호출 사용자 · definer 안 헬퍼는 false
do $$
declare v_id bigint;
begin
  v_id := public.audit_test_rpc();
  if v_id is null then raise exception 'user rpc write failed'; end if;
  if public.audit_test_priv() then raise exception 'definer helper treats user as privileged'; end if;
end $$;
reset role;
do $$ begin
  if not exists (select 1 from nomad_core.audit_log where action = 'test.user_rpc' and actor_role = 'user'
                   and actor_id = '00000000-0000-4000-8000-0000000000a1') then
    raise exception 'user rpc audit row wrong';
  end if;
end $$;
set local role authenticated;

-- 5. RPC: A owner는 A 기록만, B 조직·viewer는 거부
do $$
declare n integer;
begin
  select count(*) into n from public.nomad_audit_log('00000000-0000-4000-8000-00000000a0a0');
  if n <> 2 then raise exception 'owner A should see 2 rows, got %', n; end if;
  select count(*) into n from public.nomad_audit_log('00000000-0000-4000-8000-00000000a0a0', 1);
  if n <> 1 then raise exception 'page_size 1 got %', n; end if;
end $$;
select pg_temp.expect_err($q$select * from public.nomad_audit_log('00000000-0000-4000-8000-00000000b0b0')$q$, '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}', true);
select pg_temp.expect_err($q$select * from public.nomad_audit_log('00000000-0000-4000-8000-00000000a0a0')$q$, '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000b1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
select pg_temp.expect_err($q$select * from public.nomad_audit_log('00000000-0000-4000-8000-00000000a0a0')$q$, '%forbidden%');

-- 6. 헬퍼는 authenticated에서 false, anon은 RPC 거부
do $$ begin
  if nomad_core.is_service_caller() or nomad_core.is_privileged_session() then raise exception 'authenticated treated as server'; end if;
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.expect_err($q$select * from public.nomad_audit_log('00000000-0000-4000-8000-00000000a0a0')$q$, '%permission denied%');

rollback;
\o
\echo audit.sql OK
