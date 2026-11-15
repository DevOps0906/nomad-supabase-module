-- API 키(BYOK) · oauth_states 검증 (합성 데이터, 롤백)
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
grant all on t_ctx to authenticated, service_role;

-- c1 owner · c2 viewer · c3 admin · c4 비멤버
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000c1', 'owner@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000c2', 'viewer@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000c3', 'admin@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000c4', 'outsider@example.test', now(), false, '{}');
insert into nomad_core.organizations (id, name, kind) values ('00000000-0000-4000-8000-00000000c0a0', '키 테스트 팀', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
 ('00000000-0000-4000-8000-00000000c0a0', '00000000-0000-4000-8000-0000000000c1', 'owner'),
 ('00000000-0000-4000-8000-00000000c0a0', '00000000-0000-4000-8000-0000000000c2', 'viewer'),
 ('00000000-0000-4000-8000-00000000c0a0', '00000000-0000-4000-8000-0000000000c3', 'admin');
insert into t_ctx values ('org', '00000000-0000-4000-8000-00000000c0a0');

-- 1. 함수 권한: public 래퍼 grant
do $$
begin
  if not has_function_privilege('authenticated', 'public.nomad_set_provider_credential(uuid,text,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.nomad_list_provider_credentials(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.nomad_revoke_provider_credential(uuid)', 'execute')
  then raise exception 'authenticated wrapper grants missing'; end if;
  if has_function_privilege('authenticated', 'public.nomad_org_provider_secret(uuid,text,text)', 'execute')
     or has_function_privilege('anon', 'public.nomad_org_provider_secret(uuid,text,text)', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.org_provider_secret(uuid,text,text)', 'execute')
     or has_function_privilege('anon', 'public.nomad_set_provider_credential(uuid,text,text,text)', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.consume_oauth_state(text)', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.touch_updated_at()', 'execute')
  then raise exception 'secret/server-only function exposed'; end if;
  if not has_function_privilege('service_role', 'public.nomad_org_provider_secret(uuid,text,text)', 'execute')
     or not has_function_privilege('service_role', 'nomad_core.consume_oauth_state(text)', 'execute')
  then raise exception 'service_role grants missing'; end if;
end $$;

-- 2. 등록: owner 가능, viewer·비멤버 거부, 잘못된 입력 거부
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c2","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_set_provider_credential(%L, 'openai', 'default', 'sk-viewer-0000')$q$, (select v from t_ctx where k = 'org')), '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c4', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c4","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_set_provider_credential(%L, 'openai', 'default', 'sk-outsider-0000')$q$, (select v from t_ctx where k = 'org')), '%forbidden%');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_set_provider_credential(%L, 'nope', 'default', 'sk-test-1234567890abcdef')$q$, (select v from t_ctx where k = 'org')), '%unknown provider%');
select pg_temp.expect_err(format($q$select public.nomad_set_provider_credential(%L, 'openai', 'default', 'short')$q$, (select v from t_ctx where k = 'org')), '%invalid secret%');
select pg_temp.expect_err(format($q$select public.nomad_set_provider_credential(%L, 'openai', 'default', '1234567890123456789')$q$, (select v from t_ctx where k = 'org')), '%invalid secret%');
insert into t_ctx select 'cred1', public.nomad_set_provider_credential((select v::uuid from t_ctx where k = 'org'), 'openai', 'default', 'sk-first-AAAAAAAAAA1234')::text;

-- 3. authenticated: 원문 접근 불가(테이블·vault 직접), 목록은 last4만
do $$
begin
  perform pg_temp.expect_err('select * from nomad_core.provider_credentials', '%permission denied%');
  perform pg_temp.expect_err('select * from vault.decrypted_secrets', '%permission denied%');
  perform pg_temp.expect_err('select * from vault.secrets', '%permission denied%');
  perform pg_temp.expect_err(format('select nomad_core.org_provider_secret(%L, ''openai'', ''default'')', (select v from t_ctx where k = 'org')), '%permission denied%');
  perform pg_temp.expect_err(format('select public.nomad_org_provider_secret(%L, ''openai'', ''default'')', (select v from t_ctx where k = 'org')), '%permission denied%');
  if (select count(*) from public.nomad_list_provider_credentials((select v::uuid from t_ctx where k = 'org'))) <> 1
     or (select last4 from public.nomad_list_provider_credentials((select v::uuid from t_ctx where k = 'org'))) <> '1234'
  then raise exception 'list/last4 mismatch'; end if;
end $$;

-- viewer는 목록 가능, viewer 폐기 거부, 비멤버는 빈 목록
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c2","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from public.nomad_list_provider_credentials((select v::uuid from t_ctx where k = 'org'))) <> 1
  then raise exception 'viewer must list'; end if;
  perform pg_temp.expect_err(format('select public.nomad_revoke_provider_credential(%L)', (select v from t_ctx where k = 'cred1')), '%forbidden%');
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c4', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c4","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from public.nomad_list_provider_credentials((select v::uuid from t_ctx where k = 'org'))) <> 0
  then raise exception 'outsider must not list'; end if;
end $$;
reset role;

-- 4. service_role: 복호화, last_used_at 갱신, vault 이름 형식
set local role service_role;
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org');
begin
  if public.nomad_org_provider_secret(org, 'openai') is distinct from 'sk-first-AAAAAAAAAA1234'
  then raise exception 'service_role decrypt failed'; end if;
  if public.nomad_org_provider_secret(org, 'openai', 'other') is not null
     or public.nomad_org_provider_secret(org, 'anthropic') is not null
  then raise exception 'unknown label/provider must return null'; end if;
  -- 실측: service_role은 vault.decrypted_secrets를 직접 select할 수 있다 → 서버 전체(service_role 키) 신뢰 전제.
  if not exists (select 1 from vault.decrypted_secrets where decrypted_secret = 'sk-first-AAAAAAAAAA1234')
  then raise exception 'measured: service_role direct vault read expected to work'; end if;
end $$;
reset role;
do $$
declare cid uuid := (select v::uuid from t_ctx where k = 'cred1');
begin
  if (select last_used_at from nomad_core.provider_credentials where id = cid) is null
  then raise exception 'last_used_at not updated'; end if;
  if (select s.name from vault.secrets s join nomad_core.provider_credentials c on c.secret_id = s.id where c.id = cid)
     <> format('nomad:%s:openai:default:%s', (select v from t_ctx where k = 'org'), cid)
  then raise exception 'vault secret name format'; end if;
end $$;

-- 5. 교체(admin): 이전 vault 행 삭제, 새 값 복호화
insert into t_ctx select 'old_secret', secret_id::text from nomad_core.provider_credentials where id = (select v::uuid from t_ctx where k = 'cred1');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c3","role":"authenticated"}', true);
insert into t_ctx select 'cred2', public.nomad_set_provider_credential((select v::uuid from t_ctx where k = 'org'), 'openai', 'default', 'sk-second-BBBBBBBBB5678')::text;
reset role;
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org');
begin
  if exists (select 1 from vault.secrets where id = (select v::uuid from t_ctx where k = 'old_secret'))
  then raise exception 'old vault row must be deleted on replace'; end if;
  if (select count(*) from nomad_core.provider_credentials where organization_id = org and revoked_at is null) <> 1
  then raise exception 'exactly one active credential after replace'; end if;
  if nomad_core.org_provider_secret(org, 'openai', 'default') <> 'sk-second-BBBBBBBBB5678'
     or (select last4 from nomad_core.provider_credentials where id = (select v::uuid from t_ctx where k = 'cred2')) <> '5678'
  then raise exception 'replaced secret/last4 wrong'; end if;
end $$;

-- 6. 폐기(owner): vault 행 삭제, 복호화 null, 목록에서 제외, 재폐기 no-op
insert into t_ctx select 'new_secret', secret_id::text from nomad_core.provider_credentials where id = (select v::uuid from t_ctx where k = 'cred2');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}', true);
select public.nomad_revoke_provider_credential((select v::uuid from t_ctx where k = 'cred2'));
-- 재폐기는 no-op(오류 없음), 없는 키는 forbidden
select public.nomad_revoke_provider_credential((select v::uuid from t_ctx where k = 'cred2'));
select pg_temp.expect_err($q$select public.nomad_revoke_provider_credential('00000000-0000-4000-8000-00000000c0ff')$q$, '%forbidden%');
-- 폐기된 키여도 권한 없는 사용자(viewer·비멤버)는 forbidden
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c2","role":"authenticated"}', true);
select pg_temp.expect_err(format('select public.nomad_revoke_provider_credential(%L)', (select v from t_ctx where k = 'cred2')), '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c4', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c4","role":"authenticated"}', true);
select pg_temp.expect_err(format('select public.nomad_revoke_provider_credential(%L)', (select v from t_ctx where k = 'cred2')), '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c1","role":"authenticated"}', true);
do $$
begin
  if (select count(*) from public.nomad_list_provider_credentials((select v::uuid from t_ctx where k = 'org'))) <> 0
  then raise exception 'revoked credential still listed'; end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from vault.secrets where id = (select v::uuid from t_ctx where k = 'new_secret'))
  then raise exception 'vault row must be deleted on revoke'; end if;
  if nomad_core.org_provider_secret((select v::uuid from t_ctx where k = 'org'), 'openai', 'default') is not null
  then raise exception 'revoked credential must decrypt to null'; end if;
  if exists (select 1 from vault.secrets where name like 'nomad:' || (select v from t_ctx where k = 'org') || '%')
  then raise exception 'leftover vault rows'; end if;
end $$;

-- 6b. 비활성 조직: 활성 키가 있어도 복호화는 null
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4)
values ('00000000-0000-4000-8000-00000000c0c1', '00000000-0000-4000-8000-00000000c0a0', 'openai', 'inactive',
        vault.create_secret('sk-inactive-0000000000', 'nomad:test:inactive'), '0000');
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'org');
begin
  if nomad_core.org_provider_secret(org, 'openai', 'inactive') is distinct from 'sk-inactive-0000000000'
  then raise exception 'active org must decrypt'; end if;
  update nomad_core.organizations set active = false where id = org;
  if nomad_core.org_provider_secret(org, 'openai', 'inactive') is not null
  then raise exception 'inactive org must return null'; end if;
  update nomad_core.organizations set active = true where id = org;
end $$;

-- 6c. 서버(service_role) 폐기: 조직 역할 없이 가능 · vault 행 삭제 · 재폐기 no-op · 없는 키 forbidden
insert into t_ctx select 'inactive_secret', secret_id::text from nomad_core.provider_credentials where id = '00000000-0000-4000-8000-00000000c0c1';
set local role service_role;
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.nomad_revoke_provider_credential('00000000-0000-4000-8000-00000000c0c1');
select public.nomad_revoke_provider_credential('00000000-0000-4000-8000-00000000c0c1');
select pg_temp.expect_err($q$select public.nomad_revoke_provider_credential('00000000-0000-4000-8000-00000000c0ff')$q$, '%forbidden%');
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  if (select revoked_at from nomad_core.provider_credentials where id = '00000000-0000-4000-8000-00000000c0c1') is null
  then raise exception 'server revoke not applied'; end if;
  if exists (select 1 from vault.secrets where id = (select v::uuid from t_ctx where k = 'inactive_secret'))
  then raise exception 'vault row must be deleted on server revoke'; end if;
  if not has_function_privilege('service_role', 'nomad_core.revoke_provider_credential(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.nomad_revoke_provider_credential(uuid)', 'execute')
     or has_function_privilege('anon', 'public.nomad_revoke_provider_credential(uuid)', 'execute')
  then raise exception 'revoke grants wrong'; end if;
end $$;

-- 7. oauth_states: 1회 소비 · 만료 · 외부 redirect 거부 · authenticated 접근 불가
insert into nomad_core.oauth_states (state, provider, redirect_to, nonce, expires_at) values
 ('st-ok-0123456789012345678901234567890', 'naver', '/app/home', 'n1', now() + interval '10 minutes'),
 ('st-old-012345678901234567890123456789', 'naver', '/app', null, now() - interval '1 minute'),
 ('st-old2-01234567890123456789012345678', 'kakao', '/app', null, now() - interval '2 minutes');
select pg_temp.expect_err($q$insert into nomad_core.oauth_states (state, provider, redirect_to, expires_at) values ('bad1-0123456789012345678901234567890', 'naver', 'https://evil.example.test/', now() + interval '1 minute')$q$, '%oauth_states_redirect_to_check%');
select pg_temp.expect_err($q$insert into nomad_core.oauth_states (state, provider, redirect_to, expires_at) values ('bad2-0123456789012345678901234567890', 'naver', '//evil.example.test', now() + interval '1 minute')$q$, '%oauth_states_redirect_to_check%');
select pg_temp.expect_err($q$insert into nomad_core.oauth_states (state, provider, redirect_to, expires_at) values ('bad3-0123456789012345678901234567890', 'naver', '/\evil.example', now() + interval '1 minute')$q$, '%oauth_states_redirect_to_check%');
select pg_temp.expect_err($q$insert into nomad_core.oauth_states (state, provider, redirect_to, expires_at) values ('bad4-0123456789012345678901234567890', 'naver', E'/\t/evil.example', now() + interval '1 minute')$q$, '%oauth_states_redirect_to_check%');
select pg_temp.expect_err($q$insert into nomad_core.oauth_states (state, provider, redirect_to, expires_at) values ('bad5-0123456789012345678901234567890', 'naver', '/a b', now() + interval '1 minute')$q$, '%oauth_states_redirect_to_check%');
select pg_temp.expect_err($q$insert into nomad_core.oauth_states (state, provider, redirect_to, expires_at) values ('short', 'naver', '/ok', now() + interval '1 minute')$q$, '%oauth_states_state_check%');
do $$
begin
  if (select redirect_to from nomad_core.consume_oauth_state('st-ok-0123456789012345678901234567890')) is distinct from '/app/home' then raise exception 'consume failed'; end if;
  if exists (select 1 from nomad_core.consume_oauth_state('st-ok-0123456789012345678901234567890')) then raise exception 'state consumed twice'; end if;
  if exists (select 1 from nomad_core.consume_oauth_state('st-old-012345678901234567890123456789')) then raise exception 'expired state accepted'; end if;
  if exists (select 1 from nomad_core.consume_oauth_state('missing')) then raise exception 'unknown state accepted'; end if;
  if exists (select 1 from nomad_core.oauth_states) then raise exception 'expired rows not cleaned'; end if;
end $$;
set local role authenticated;
select pg_temp.expect_err($q$select * from nomad_core.oauth_states$q$, '%permission denied%');
select pg_temp.expect_err($q$select * from nomad_core.consume_oauth_state('x')$q$, '%permission denied%');

rollback;
