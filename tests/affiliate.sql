-- 제휴(affiliate) 검증: 조직 격리 · anon 접근 0 · 서버 전용 쓰기 · 대가성 문구 · 브랜드커넥트 위험 동의·상태 전이 (합성 데이터, 롤백)
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

-- 1. 권한 표 · RLS: 다섯 테이블 모두 RLS, 사용자 정책·직접 권한 0, 서버 함수는 service_role만
do $$
declare t text; f text;
begin
  foreach t in array array['affiliate_accounts', 'affiliate_links', 'affiliate_clicks', 'affiliate_disclosures', 'brandconnect_applications'] loop
    if not (select relrowsecurity from pg_class where oid = ('nomad_core.' || t)::regclass) then raise exception '% RLS off', t; end if;
    if exists (select 1 from pg_policies where schemaname = 'nomad_core' and tablename = t) then raise exception '% has policy', t; end if;
    if has_table_privilege('anon', 'nomad_core.' || t, 'select,insert,update,delete')
       or has_table_privilege('authenticated', 'nomad_core.' || t, 'select,insert,update,delete')
    then raise exception '% grants too wide', t; end if;
    if not has_table_privilege('service_role', 'nomad_core.' || t, 'select') then raise exception '% service select missing', t; end if;
  end loop;
  if has_table_privilege('service_role', 'nomad_core.affiliate_clicks', 'insert,update') then raise exception 'clicks writable directly'; end if;
  foreach f in array array['nomad_core.new_affiliate_short_code(integer)', 'nomad_core.record_affiliate_click(text,text,text,text,text)',
      'nomad_core.purge_affiliate_clicks(interval)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then raise exception '% too wide', f; end if;
    if not has_function_privilege('service_role', f, 'execute') then raise exception '% service missing', f; end if;
  end loop;
  foreach f in array array['public.nomad_affiliate_accounts(uuid)', 'public.nomad_affiliate_links(uuid,integer)',
      'public.nomad_affiliate_clicks(uuid,uuid,integer)', 'public.nomad_effective_disclosure(uuid,text,text)',
      'public.nomad_upsert_affiliate_disclosure(uuid,text,text,text)', 'public.nomad_consent_brandconnect_risk(uuid)',
      'public.nomad_create_brandconnect_application(uuid,text,text,text,text,text,text,text,text)',
      'public.nomad_brandconnect_applications(uuid,integer)'] loop
    if has_function_privilege('anon', f, 'execute') then raise exception '% anon execute', f; end if;
    if not has_function_privilege('authenticated', f, 'execute') then raise exception '% authenticated missing', f; end if;
  end loop;
  if has_function_privilege('authenticated', 'nomad_core.brandconnect_status_transition()', 'execute')
     or has_function_privilege('authenticated', 'nomad_core.brandconnect_insert_guard()', 'execute') then raise exception 'trigger fn exposed'; end if;
end $$;

-- a1 조직A owner · a2 조직A viewer · a3 조직A editor · b1 조직B owner
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000a1', 'aff-a-owner@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a2', 'aff-a-viewer@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a3', 'aff-a-editor@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000b1', 'aff-b-owner@example.test', now(), false, '{}');
insert into nomad_core.organizations (id, name, kind) values
 ('00000000-0000-4000-8000-00000000a0a0', '제휴 A팀', 'team'),
 ('00000000-0000-4000-8000-00000000b0b0', '제휴 B팀', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a1', 'owner'),
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a2', 'viewer'),
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a3', 'editor'),
 ('00000000-0000-4000-8000-00000000b0b0', '00000000-0000-4000-8000-0000000000b1', 'owner');
-- 합성 제품 aff_test: 'brandconnect' 기능은 B 플랜에만, 조직A만 구독(조직B는 잠김)
insert into nomad_core.products (code, name) values ('aff_test', '제휴 테스트 제품');
insert into nomad_core.plans (product_code, code, name) values ('aff_test', 'B', '중간');
insert into nomad_core.features (product_code, code, name) values ('aff_test', 'brandconnect', '브랜드커넥트 자동 지원');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values ('aff_test', 'B', 'brandconnect');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
 ('00000000-0000-4000-8000-00000000a0a0', 'aff_test', 'B', 'active');
-- 조직B 작업·조직A 자격(복합 FK 교차 검사용, 관리 세션)
insert into nomad_core.jobs (id, organization_id, product_code, job_type) values
 ('00000000-0000-4000-8000-0000000b0f01', '00000000-0000-4000-8000-00000000b0b0', 'aff_test', 'brandconnect.apply');
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4) values
 ('00000000-0000-4000-8000-0000000a0cc1', '00000000-0000-4000-8000-00000000a0a0', 'openai', 'aff', gen_random_uuid(), 'abcd');

-- 2. 서버 쓰기(service_role): 계정·링크·기본 문구
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_core.affiliate_accounts (id, organization_id, provider, partner_id) values
 ('00000000-0000-4000-8000-0000000a0c01', '00000000-0000-4000-8000-00000000a0a0', 'coupang', 'AF-TEST-A'),
 ('00000000-0000-4000-8000-0000000a0c02', '00000000-0000-4000-8000-00000000a0a0', 'naver_brandconnect', 'BC-TEST-A'),
 ('00000000-0000-4000-8000-0000000b0c01', '00000000-0000-4000-8000-00000000b0b0', 'naver_brandconnect', 'BC-TEST-B');
insert into nomad_core.affiliate_links (id, organization_id, account_id, provider, product_code, original_url, affiliate_url, short_code) values
 ('00000000-0000-4000-8000-0000000a1101', '00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000a0c01',
  'coupang', 'contentflow_example', 'https://shop.example.test/p/1', 'https://aff.example.test/a1', nomad_core.new_affiliate_short_code()),
 ('00000000-0000-4000-8000-0000000b1101', '00000000-0000-4000-8000-00000000b0b0', null,
  'coupang', 'contentflow_example', 'https://shop.example.test/p/2', 'https://aff.example.test/b1', 'testcodeb1');
insert into nomad_core.affiliate_disclosures (organization_id, provider, placement, body) values
 (null, 'coupang', 'blog_top', '[기본] 이 글은 제휴 활동으로 수수료를 받을 수 있습니다.');
do $$
declare v_code text; v_url text;
begin
  select short_code into v_code from nomad_core.affiliate_links where id = '00000000-0000-4000-8000-0000000a1101';
  if v_code !~ '^[a-z0-9]{8}$' then raise exception 'short code format %', v_code; end if;
  v_url := nomad_core.record_affiliate_click(v_code, 'https://ref.example.test', 'hash-1', 'ua', 'KR');
  if v_url <> 'https://aff.example.test/a1' then raise exception 'click url %', v_url; end if;
  perform nomad_core.record_affiliate_click(v_code);
  if nomad_core.record_affiliate_click('nosuchcode') is not null then raise exception 'unknown code not null'; end if;
  perform nomad_core.record_affiliate_click('testcodeb1');
  if (select click_count from nomad_core.affiliate_links where id = '00000000-0000-4000-8000-0000000a1101') <> 2 then raise exception 'click_count'; end if;
  if (select count(*) from nomad_core.affiliate_clicks where organization_id = '00000000-0000-4000-8000-00000000a0a0') <> 2 then raise exception 'click rows'; end if;
end $$;
-- 클릭 로그는 service_role도 직접 넣거나 고치지 못한다 · 잘못된 입력 거부
select pg_temp.expect_err($q$insert into nomad_core.affiliate_clicks (link_id, organization_id) values ('00000000-0000-4000-8000-0000000a1101', '00000000-0000-4000-8000-00000000a0a0')$q$, '%permission denied%');
select pg_temp.expect_err($q$update nomad_core.affiliate_clicks set country = 'US'$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.new_affiliate_short_code(3)$q$, '%6..32%');
select pg_temp.expect_err($q$insert into nomad_core.affiliate_links (organization_id, provider, product_code, original_url, affiliate_url, short_code) values ('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'contentflow_example', 'javascript:alert(1)', 'https://x.test', 'abcdefgh')$q$, '%affiliate_links_url_check%');
select pg_temp.expect_err($q$insert into nomad_core.affiliate_disclosures (organization_id, provider, placement, body) values (null, 'coupang', 'video_description', '  짧음  ')$q$, '%check%');
-- 조직 일치 복합 FK: 다른 조직 계정·자격을 걸 수 없다
select pg_temp.expect_err($q$insert into nomad_core.affiliate_links (organization_id, account_id, provider, product_code, original_url, affiliate_url, short_code) values ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000b0c01', 'coupang', 'contentflow_example', 'https://x.test', 'https://y.test', 'crossorg1')$q$, '%foreign key%');
select pg_temp.expect_err($q$update nomad_core.affiliate_accounts set credential_id = '00000000-0000-4000-8000-0000000a0cc1' where id = '00000000-0000-4000-8000-0000000b0c01'$q$, '%foreign key%');
update nomad_core.affiliate_accounts set credential_id = '00000000-0000-4000-8000-0000000a0cc1' where id = '00000000-0000-4000-8000-0000000a0c01';
-- 지원서는 draft로만 시작(service_role 직접 쓰기도)
select pg_temp.expect_err($q$insert into nomad_core.brandconnect_applications (organization_id, account_id, product_code, campaign_id, target_url, target_kind, status) values ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000a0c02', 'aff_test', 'camp-x', 'https://blog.example.test/x', 'blog', 'submitted')$q$, '%must start as draft%');
-- 보존 정리: 입력 검증
select pg_temp.expect_err($q$select nomad_core.purge_affiliate_clicks(null)$q$, '%must be >= 0%');
select pg_temp.expect_err($q$select nomad_core.purge_affiliate_clicks(interval '-1 day')$q$, '%must be >= 0%');
reset role;
-- 클릭 집계만 바뀐 갱신은 updated_at 유지, 다른 컬럼 갱신은 바뀜
select set_config('request.jwt.claims', '', true);
update nomad_core.affiliate_links set updated_at = '2000-01-01' where id = '00000000-0000-4000-8000-0000000a1101';
do $$
declare v_code text;
begin
  select short_code into v_code from nomad_core.affiliate_links where id = '00000000-0000-4000-8000-0000000a1101';
  if (select updated_at from nomad_core.affiliate_links where id = '00000000-0000-4000-8000-0000000a1101') <> '2000-01-01' then raise exception 'updated_at reset failed'; end if;
  perform nomad_core.record_affiliate_click(v_code);
  if (select updated_at from nomad_core.affiliate_links where id = '00000000-0000-4000-8000-0000000a1101') <> '2000-01-01' then raise exception 'click touched updated_at'; end if;
  update nomad_core.affiliate_links set product_name = '바뀐 상품' where id = '00000000-0000-4000-8000-0000000a1101';
  if (select updated_at from nomad_core.affiliate_links where id = '00000000-0000-4000-8000-0000000a1101') = '2000-01-01' then raise exception 'real update did not touch updated_at'; end if;
  -- 보존 정리: 40일 전 클릭 1건만 지운다
  update nomad_core.affiliate_clicks set clicked_at = now() - interval '40 days'
  where id = (select min(id) from nomad_core.affiliate_clicks where organization_id = '00000000-0000-4000-8000-00000000a0a0');
  if nomad_core.purge_affiliate_clicks(interval '30 days') <> 1 then raise exception 'purge count'; end if;
  if (select count(*) from nomad_core.affiliate_clicks where organization_id = '00000000-0000-4000-8000-00000000a0a0') <> 2 then raise exception 'purge left wrong rows'; end if;
end $$;

-- 3. authenticated: 테이블 직접 접근·서버 함수 거부
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err($q$select * from nomad_core.affiliate_links$q$, '%permission denied%');
select pg_temp.expect_err($q$select * from nomad_core.affiliate_accounts$q$, '%permission denied%');
select pg_temp.expect_err($q$insert into nomad_core.affiliate_disclosures (organization_id, provider, placement, body) values ('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top', '사용자가 직접 넣은 문구입니다')$q$, '%permission denied%');
select pg_temp.expect_err($q$update nomad_core.brandconnect_applications set status = 'accepted'$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.record_affiliate_click('testcodeb1')$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.new_affiliate_short_code()$q$, '%permission denied%');

-- 4. 조직 격리: A owner는 A만
do $$
declare n integer;
begin
  select count(*) into n from public.nomad_affiliate_accounts('00000000-0000-4000-8000-00000000a0a0');
  if n <> 2 then raise exception 'A accounts %', n; end if;
  select count(*) into n from public.nomad_affiliate_links('00000000-0000-4000-8000-00000000a0a0');
  if n <> 1 then raise exception 'A links %', n; end if;
  select count(*) into n from public.nomad_affiliate_clicks('00000000-0000-4000-8000-00000000a0a0');
  if n <> 2 then raise exception 'A clicks %', n; end if;
  select count(*) into n from public.nomad_affiliate_clicks('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000b1101');
  if n <> 0 then raise exception 'B link clicks leaked via A org %', n; end if;
  if public.nomad_effective_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top') not like '[기본]%' then raise exception 'default disclosure'; end if;
end $$;
select pg_temp.expect_err($q$select * from public.nomad_affiliate_accounts('00000000-0000-4000-8000-00000000b0b0')$q$, '%forbidden%');
select pg_temp.expect_err($q$select * from public.nomad_affiliate_links('00000000-0000-4000-8000-00000000b0b0')$q$, '%forbidden%');
select pg_temp.expect_err($q$select * from public.nomad_affiliate_clicks('00000000-0000-4000-8000-00000000b0b0')$q$, '%forbidden%');
select pg_temp.expect_err($q$select public.nomad_effective_disclosure('00000000-0000-4000-8000-00000000b0b0', 'coupang', 'blog_top')$q$, '%forbidden%');
select pg_temp.expect_err($q$select * from public.nomad_brandconnect_applications('00000000-0000-4000-8000-00000000b0b0')$q$, '%forbidden%');
select pg_temp.expect_err($q$select public.nomad_upsert_affiliate_disclosure('00000000-0000-4000-8000-00000000b0b0', 'coupang', 'blog_top', 'B 조직 문구를 A가 바꾸려 함')$q$, '%forbidden%');
select pg_temp.expect_err($q$select public.nomad_consent_brandconnect_risk('00000000-0000-4000-8000-0000000b0c01')$q$, '%forbidden%');
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000b0c01', 'camp-1', 'https://blog.example.test/a', 'blog', 'aff_test')$q$, '%forbidden%');

-- 5. 대가성 문구: owner 편집(조직 문구 우선, 다른 조직은 기본값 유지), 빈 문구 거부, 감사 기록
do $$
declare v1 uuid; v2 uuid;
begin
  v1 := public.nomad_upsert_affiliate_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top', '[A팀] 쿠팡 파트너스 활동으로 수수료를 받습니다.');
  v2 := public.nomad_upsert_affiliate_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top', '[A팀] 수정: 쿠팡 파트너스 수수료 고지입니다.');
  if v1 is distinct from v2 then raise exception 'upsert made a second row'; end if;
  if public.nomad_effective_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top') not like '[A팀] 수정%' then raise exception 'org disclosure not preferred'; end if;
end $$;
select pg_temp.expect_err($q$select public.nomad_upsert_affiliate_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top', '   ')$q$, '%check%');
select pg_temp.expect_err($q$select public.nomad_upsert_affiliate_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'off', '플랫폼에 없는 위치 문구입니다')$q$, '%check%');

-- 6. 브랜드커넥트: 위험 동의 전 거부 → owner 동의(멱등) → editor 생성(멱등)
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}', true);
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-1', 'https://blog.example.test/a', 'blog', 'aff_test')$q$, '%risk consent required%');
select pg_temp.expect_err($q$select public.nomad_consent_brandconnect_risk('00000000-0000-4000-8000-0000000a0c02')$q$, '%forbidden%');
select pg_temp.expect_err($q$select public.nomad_upsert_affiliate_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top', 'editor가 바꾸려는 문구입니다')$q$, '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err($q$select public.nomad_consent_brandconnect_risk('00000000-0000-4000-8000-0000000a0c01')$q$, '%not a brandconnect account%');
do $$
declare t1 timestamptz; t2 timestamptz;
begin
  t1 := public.nomad_consent_brandconnect_risk('00000000-0000-4000-8000-0000000a0c02');
  t2 := public.nomad_consent_brandconnect_risk('00000000-0000-4000-8000-0000000a0c02');
  if t1 is null or t1 is distinct from t2 then raise exception 'consent not idempotent'; end if;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}', true);
do $$
declare v1 uuid; v2 uuid; n integer;
begin
  v1 := public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-1', 'https://blog.example.test/a', 'blog', 'aff_test', '브랜드');
  v2 := public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-1', 'https://blog.example.test/a', 'blog', 'aff_test');
  if v1 is null or v1 is distinct from v2 then raise exception 'application not idempotent'; end if;
  select count(*) into n from public.nomad_brandconnect_applications('00000000-0000-4000-8000-00000000a0a0') where status = 'draft';
  if n <> 1 then raise exception 'A applications %', n; end if;
end $$;
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-2', 'http://blog.example.test/a', 'blog', 'aff_test')$q$, '%check%');
-- 멱등 재호출인데 본문이 다르면 거부
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-1', 'https://blog.example.test/other', 'blog', 'aff_test')$q$, '%different body%');
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-1', 'https://blog.example.test/a', 'clip', 'aff_test')$q$, '%different body%');
-- 기능 잠금: 'brandconnect' 기능이 없는 제품이면 거부
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-4', 'https://blog.example.test/a', 'blog', 'contentflow_example')$q$, '%feature locked%');
-- 길이 제한
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-5', 'https://blog.example.test/a', 'blog', 'aff_test', repeat('가', 201))$q$, '%check%');
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-6', 'https://blog.example.test/' || repeat('a', 2000), 'blog', 'aff_test')$q$, '%check%');
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-7', 'https://blog.example.test/a', 'blog', 'aff_test', null, null, repeat('c', 101))$q$, '%check%');
-- viewer는 읽기만
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}', true);
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000a0c02', 'camp-3', 'https://blog.example.test/a', 'blog', 'aff_test')$q$, '%forbidden%');
select pg_temp.expect_err($q$select * from public.nomad_affiliate_clicks('00000000-0000-4000-8000-00000000a0a0')$q$, '%forbidden%');
do $$ begin
  if (select count(*) from public.nomad_affiliate_links('00000000-0000-4000-8000-00000000a0a0')) <> 1 then raise exception 'viewer links'; end if;
end $$;
-- B owner에게 A 지원서·문구가 보이지 않는다
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000b1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
do $$ begin
  if (select count(*) from public.nomad_brandconnect_applications('00000000-0000-4000-8000-00000000b0b0')) <> 0 then raise exception 'B sees applications'; end if;
  if public.nomad_effective_disclosure('00000000-0000-4000-8000-00000000b0b0', 'coupang', 'blog_top') not like '[기본]%' then raise exception 'B got A disclosure'; end if;
  perform public.nomad_consent_brandconnect_risk('00000000-0000-4000-8000-0000000b0c01');
end $$;
-- 조직B는 aff_test를 구독하지 않아 동의했어도 기능 잠김
select pg_temp.expect_err($q$select public.nomad_create_brandconnect_application('00000000-0000-4000-8000-0000000b0c01', 'camp-b', 'https://blog.example.test/b', 'blog', 'aff_test')$q$, '%feature locked%');
reset role;

-- 7. 감사 기록(문구 2회·동의 1회) · 상태 전이(service_role 직접 쓰기에도 적용)
select set_config('request.jwt.claims', '', true);
do $$ begin
  if (select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-4000-8000-00000000a0a0'
        and action in ('affiliate.disclosure.upsert', 'affiliate.brandconnect.risk_consent')
        and actor_id = '00000000-0000-4000-8000-0000000000a1') <> 3 then raise exception 'audit rows'; end if;
  if (select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-4000-8000-00000000a0a0'
        and action = 'affiliate.brandconnect.application_create' and actor_id = '00000000-0000-4000-8000-0000000000a3') <> 1
  then raise exception 'application audit rows'; end if;
  -- 문구 감사: 첫 편집은 before 없음, 두 번째는 전후 본문
  if not exists (select 1 from nomad_core.audit_log where action = 'affiliate.disclosure.upsert' and before is null
                   and after ->> 'body' like '[A팀] 쿠팡%') then raise exception 'first disclosure audit'; end if;
  if not exists (select 1 from nomad_core.audit_log where action = 'affiliate.disclosure.upsert'
                   and before ->> 'body' like '[A팀] 쿠팡%' and after ->> 'body' like '[A팀] 수정%') then raise exception 'disclosure audit before/after'; end if;
end $$;
-- 작업은 같은 조직 것만 연결(조직B 작업을 A 지원서에 걸 수 없다)
select pg_temp.expect_err($q$update nomad_core.brandconnect_applications set job_id = '00000000-0000-4000-8000-0000000b0f01' where campaign_id = 'camp-1'$q$, '%foreign key%');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select pg_temp.expect_err($q$update nomad_core.brandconnect_applications set status = 'accepted' where campaign_id = 'camp-1'$q$, '%invalid status transition%');
update nomad_core.brandconnect_applications set status = 'submitting', attempts = attempts + 1 where campaign_id = 'camp-1';
update nomad_core.brandconnect_applications set status = 'failed' where campaign_id = 'camp-1';
update nomad_core.brandconnect_applications set status = 'submitting' where campaign_id = 'camp-1';
update nomad_core.brandconnect_applications set status = 'submitted', submitted_at = now() where campaign_id = 'camp-1';
update nomad_core.brandconnect_applications set status = 'accepted', decided_at = now() where campaign_id = 'camp-1';
select pg_temp.expect_err($q$update nomad_core.brandconnect_applications set status = 'draft' where campaign_id = 'camp-1'$q$, '%invalid status transition%');
reset role;

-- 8. anon: 테이블·사용자 RPC·서버 함수 모두 거부
set local role anon;
select set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.expect_err($q$select * from nomad_core.affiliate_links$q$, '%permission denied%');
select pg_temp.expect_err($q$select * from public.nomad_affiliate_links('00000000-0000-4000-8000-00000000a0a0')$q$, '%permission denied%');
select pg_temp.expect_err($q$select public.nomad_effective_disclosure('00000000-0000-4000-8000-00000000a0a0', 'coupang', 'blog_top')$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.record_affiliate_click('testcodeb1')$q$, '%permission denied%');

rollback;
\o
