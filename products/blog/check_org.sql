-- nomad-blog org안 검사: 조직 2곳 교차 거부 · 역할(owner/editor/viewer) · 보호 컬럼·서버 표 잠금 · 제휴 링크·지원서·자격 참조 조직 일치
-- · 발행 게이트(동의·컴플라이언스·대가성 문구) · 결과 저장(작업 실패·취소면 거부 + mark_job_delivered) · 사용자 RPC
-- · 플랜 기능 잠금(구독 끊김 = C, 기존 유료 행 경로 포함) · 조직 비활성 잠김 · 함수 권한 · 동기화 컬럼.
-- 합성 데이터만. 실행: bash products/blog/run_check.sh  (begin → org/0001·0002 → 이 파일 → rollback)

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
create function zz_check.id(k text) returns uuid language sql as $$ select v::uuid from t_ids where t_ids.k = id.k $$;
grant execute on function zz_check.id(text) to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(a1 owner · a3 editor · a4 viewer, 플랜 B 구독), 조직 B(a2 owner, 구독 없음 = C) ----
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
  ('00000000-0000-0000-0000-00000000000a', 'blog', 'B', 'active');
-- 작업(A 6개, B 1개) · 채널 자격 · 제휴 계정·링크·브랜드커넥트 지원서(합성)
insert into t_ids select 'job' || n, (select id from nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000000a',
  p_product => 'blog', p_job_type => 'blog.test', p_idempotency_key => 'zz-job-' || n)) from generate_series(1, 6) n;
insert into t_ids select 'jobB', id from nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000000b',
  p_product => 'blog', p_job_type => 'blog.test', p_idempotency_key => 'zz-job-b');
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4) values
  ('00000000-0000-0000-0000-0000000c0a01', '00000000-0000-0000-0000-00000000000a', 'naver_blog', 'naver', gen_random_uuid(), 'abcd'),
  ('00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-00000000000b', 'naver_blog', 'naver', gen_random_uuid(), 'abcd');
insert into nomad_core.affiliate_accounts (id, organization_id, provider, partner_id, risk_consented_at) values
  ('00000000-0000-0000-0000-0000000aac01', '00000000-0000-0000-0000-00000000000a', 'coupang', 'AF-A', null),
  ('00000000-0000-0000-0000-0000000aac02', '00000000-0000-0000-0000-00000000000a', 'naver_brandconnect', 'BC-A', now()),
  ('00000000-0000-0000-0000-0000000bac02', '00000000-0000-0000-0000-00000000000b', 'naver_brandconnect', 'BC-B', now());
insert into nomad_core.affiliate_links (id, organization_id, account_id, provider, product_code, original_url, affiliate_url, short_code) values
  ('00000000-0000-0000-0000-0000000a1101', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000aac01', 'coupang', 'blog', 'https://shop.test/1', 'https://link.test/1', 'zzlinka1'),
  ('00000000-0000-0000-0000-0000000a1102', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000aac01', 'coupang', 'contentflow', 'https://shop.test/2', 'https://link.test/2', 'zzlinka2'),
  ('00000000-0000-0000-0000-0000000a1103', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000aac01', 'coupang', 'blog', 'https://shop.test/3', 'https://link.test/3', 'zzlinka3'),
  ('00000000-0000-0000-0000-0000000b1101', '00000000-0000-0000-0000-00000000000b', null, 'coupang', 'blog', 'https://shop.test/b', 'https://link.test/b', 'zzlinkb1');
insert into nomad_core.brandconnect_applications (id, organization_id, account_id, product_code, campaign_id, target_url, target_kind) values
  ('00000000-0000-0000-0000-0000000abc01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000aac02', 'blog', 'camp-1', 'https://brand.test/a', 'blog'),
  ('00000000-0000-0000-0000-0000000abc02', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000aac02', 'blog', 'camp-2', 'https://brand.test/c', 'clip'),
  ('00000000-0000-0000-0000-0000000bbc01', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000bac02', 'blog', 'camp-1', 'https://brand.test/b', 'blog');

-- ==== 0. 시드·구조 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_blog'$$, 4);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_blog' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'blog'$$, 12);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_blog' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.routine_privileges where routine_schema = 'nomad_blog' and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from (values ('nomad_blog')) s(n) where has_schema_privilege('anon', n, 'usage')$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_blog' and p.prosecdef and not ('search_path=""' = any (coalesce(p.proconfig, '{}')))$$, 0);
-- 제품 함수 본문에 core 표 직접 쓰기 0건, core 표에 제품 트리거 0건
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_blog' and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+nomad_core\.'$$, 0);
select zz_check.expect($$select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace
  where n.nspname = 'nomad_core' and pn.nspname = 'nomad_blog'$$, 0);
select zz_check.expect($$select count(*) from storage.buckets where id = 'blog-files' and (public or 'image/svg+xml' = any (allowed_mime_types))$$, 0);

-- ==== 1. anon: 전부 거부 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_blog.posts');
select zz_check.denied($$select nomad_blog.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_blog.monthly_post_usage('00000000-0000-0000-0000-00000000000a')$$);
reset role;

-- ==== 2. 조직 A owner(a1, 플랜 B): 원고 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_blog.posts (id, organization_id, title, cover_image_path) values
  ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000a', '글 1', '00000000-0000-0000-0000-00000000000a/blog/covers/1.png'),
  ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-00000000000a', '글 2', null),
  ('00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-00000000000a', '글 3', null);
select zz_check.expect($$select count(*) from nomad_blog.posts where created_by = '00000000-0000-0000-0000-0000000000a1' and status = 'draft'$$, 3);
select zz_check.fails_with($$insert into nomad_blog.posts (organization_id, title, cover_image_path) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-00000000000b/blog/covers/x.png')$$, 'posts_cover_path_check');
select zz_check.fails_with($$insert into nomad_blog.posts (organization_id, title, template) values ('00000000-0000-0000-0000-00000000000a', 'x', 'experience')$$, 'posts_experience_check');
-- 보호 컬럼은 grant 없음
select zz_check.denied($$update nomad_blog.posts set status = 'published'$$);
select zz_check.denied($$update nomad_blog.posts set body_html = '<script>'$$);
select zz_check.denied($$update nomad_blog.posts set compliance_verdict = 'pass'$$);
-- 브랜드커넥트: 같은 조직 블로그형만(B 플랜 허용)
update nomad_blog.posts set brandconnect_application_id = '00000000-0000-0000-0000-0000000abc01' where id = '00000000-0000-0000-0000-0000000b0001';
select zz_check.fails_with($$update nomad_blog.posts set brandconnect_application_id = '00000000-0000-0000-0000-0000000bbc01' where id = '00000000-0000-0000-0000-0000000b0002'$$, 'another organization');
select zz_check.fails_with($$update nomad_blog.posts set brandconnect_application_id = '00000000-0000-0000-0000-0000000abc02' where id = '00000000-0000-0000-0000-0000000b0002'$$, 'not a blog campaign');
update nomad_blog.posts set title = '글 1 수정' where id = '00000000-0000-0000-0000-0000000b0001';
select zz_check.expect($$select version from nomad_blog.posts where id = '00000000-0000-0000-0000-0000000b0001'$$, 3);
-- 서버 표·서버 함수 거부
select zz_check.denied($$insert into nomad_blog.channel_accounts (organization_id, channel) values ('00000000-0000-0000-0000-00000000000a', 'wordpress')$$);
select zz_check.denied($$insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000a1101', 'coupang')$$);
select zz_check.denied($$select nomad_blog.acquire_channel_lock(gen_random_uuid(), gen_random_uuid())$$);
select zz_check.expect($$select nomad_blog.monthly_post_usage('00000000-0000-0000-0000-00000000000a')$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 3. editor(a3) 쓰기 · viewer(a4) 읽기만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
insert into nomad_blog.posts (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', '편집자 글');
delete from nomad_blog.posts;  -- editor 는 삭제 정책 밖(0건)
select zz_check.expect($$select count(*) from nomad_blog.posts$$, 4);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.expect($$select count(*) from nomad_blog.posts$$, 4);
select zz_check.denied($$insert into nomad_blog.posts (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'viewer')$$);
do $$ declare n int; begin
  update nomad_blog.posts set title = 'viewer';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'viewer updated posts'; end if;
end $$;
select zz_check.fails_with($$select nomad_blog.set_post_archived('00000000-0000-0000-0000-0000000b0003', true)$$, 'editor role required');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 4. 조직 B owner(a2, 구독 없음 = C): A 데이터 0건, A 로 쓰기 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select (select count(*) from nomad_blog.posts) + (select count(*) from nomad_blog.channel_accounts)
  + (select count(*) from nomad_blog.post_publications) + (select count(*) from nomad_blog.post_affiliate_links)$$, 0);
select zz_check.denied($$insert into nomad_blog.posts (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'B가 A에')$$);
select zz_check.fails_with($$select nomad_blog.acknowledge_compliance_warning('00000000-0000-0000-0000-0000000b0001')$$, 'not found');
select zz_check.fails_with($$select nomad_blog.monthly_post_usage('00000000-0000-0000-0000-00000000000a')$$, 'not a member');
do $$ declare n int; begin
  update nomad_blog.posts set title = 'hack' where organization_id = '00000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'B updated A post'; end if;
end $$;
-- 무료(C)도 작업 공간은 열려 있다. 브랜드커넥트는 C 에서 잠김
insert into nomad_blog.posts (id, organization_id, title) values ('00000000-0000-0000-0000-0000000b0b01', '00000000-0000-0000-0000-00000000000b', 'B 글');
select zz_check.fails_with($$update nomad_blog.posts set brandconnect_application_id = '00000000-0000-0000-0000-0000000bbc01'$$, '(brandconnect)');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 5. 서버(관리 세션 = 서버 호출): 채널·제휴·발행·생성 ====
-- 채널 계정: 자격은 같은 조직 것만, 인스타그램은 A 플랜만
insert into nomad_blog.channel_accounts (id, organization_id, channel, external_account_id, credential_id, status) values
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-00000000000a', 'naver', 'blog-a', '00000000-0000-0000-0000-0000000c0a01', 'active'),
  ('00000000-0000-0000-0000-0000000ca002', '00000000-0000-0000-0000-00000000000a', 'wordpress', 'wp-a', null, 'active');
select zz_check.denied($$insert into nomad_blog.channel_accounts (organization_id, channel, external_account_id, credential_id, status) values ('00000000-0000-0000-0000-00000000000a', 'naver', 'blog-x', '00000000-0000-0000-0000-0000000c0b01', 'active')$$);
select zz_check.fails_with($$insert into nomad_blog.channel_accounts (organization_id, channel, external_account_id, status) values ('00000000-0000-0000-0000-00000000000a', 'instagram', 'ig-a', 'active')$$, '(instagram_channel)');
-- 제휴 링크 매핑: 같은 조직(복합 FK)·blog 제품·같은 제공자, 자동 삽입은 B 허용
insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider, inserted_by) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000a1101', 'coupang', 'auto');
select zz_check.denied($$insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b1101', 'coupang')$$);
select zz_check.fails_with($$insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000a1102', 'coupang')$$, 'not a blog link');
select zz_check.fails_with($$insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000a1103', 'tenping')$$, 'not a blog link');
-- 발행 게이트: 자동화 동의 → 컴플라이언스 → 대가성 문구
select zz_check.fails_with($$insert into nomad_blog.post_publications (organization_id, post_id, channel_account_id, channel) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000ca001', 'naver')$$, 'automation risk consent');
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.fails_with($$select nomad_blog.consent_channel_automation_risk('00000000-0000-0000-0000-0000000ca001', 'risk-v1')$$, 'owner/admin only');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_blog.consent_channel_automation_risk('00000000-0000-0000-0000-0000000ca001', 'risk-v1');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.fails_with($$insert into nomad_blog.post_publications (organization_id, post_id, channel_account_id, channel) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000ca001', 'naver')$$, 'compliance gate');
update nomad_blog.posts set compliance_verdict = 'warn', compliance_issues = '[{"code":"x"}]' where id in ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000b0001');
update nomad_blog.posts set compliance_verdict = 'pass' where id = '00000000-0000-0000-0000-0000000b0003';
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select nomad_blog.acknowledge_compliance_warning('00000000-0000-0000-0000-0000000b0002');
select nomad_blog.acknowledge_compliance_warning('00000000-0000-0000-0000-0000000b0001');
reset role;
select set_config('request.jwt.claims', '', true);
-- 발행 1(글 2 → 네이버, 제휴 링크 있음): 대가성 문구 없이 발행 시작 거부 → 포함 후 발행 → 결과 전달
insert into nomad_blog.post_publications (id, organization_id, post_id, channel_account_id, channel, job_id) values
  ('00000000-0000-0000-0000-0000000d0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000ca001', 'naver', zz_check.id('job1'));
select zz_check.expect($$select count(*) from nomad_blog.post_publications where requires_disclosure and affiliate_link_count = 1$$, 1);
select zz_check.expect_text($$select status from nomad_blog.posts where id = '00000000-0000-0000-0000-0000000b0002'$$, 'publishing');
select zz_check.fails_with($$update nomad_blog.post_publications set status = 'publishing' where id = '00000000-0000-0000-0000-0000000d0001'$$, 'post_publications_disclosure_check');
update nomad_blog.post_publications set status = 'publishing', disclosure_included = true where id = '00000000-0000-0000-0000-0000000d0001';
update nomad_blog.post_publications set status = 'published', published_url = 'https://blog.test/1' where id = '00000000-0000-0000-0000-0000000d0001';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job1') and not refund_on_failure$$, 1);
select zz_check.expect_text($$select status from nomad_blog.posts where id = '00000000-0000-0000-0000-0000000b0002'$$, 'published');
-- 발행 2(글 3 → 워드프레스, 예약, B 허용) → 사용자 취소(작업 환불)
insert into nomad_blog.post_publications (id, organization_id, post_id, channel_account_id, channel, status, scheduled_at, job_id) values
  ('00000000-0000-0000-0000-0000000d0002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-0000000ca002', 'wordpress', 'scheduled', now() + interval '1 day', zz_check.id('job2'));
select zz_check.expect_text($$select status from nomad_blog.posts where id = '00000000-0000-0000-0000-0000000b0003'$$, 'scheduled');
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$select nomad_blog.cancel_publication('00000000-0000-0000-0000-0000000d0002')$$, 'not found');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_blog.cancel_publication('00000000-0000-0000-0000-0000000d0002');
select zz_check.fails_with($$select nomad_blog.cancel_publication('00000000-0000-0000-0000-0000000d0002')$$, 'cannot be canceled');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect_text($$select status from nomad_core.jobs where id = zz_check.id('job2')$$, 'canceled');
-- 발행 3: 작업이 취소(환불)됐으면 발행 결과 저장 거부
insert into nomad_blog.post_publications (id, organization_id, post_id, channel_account_id, channel, job_id) values
  ('00000000-0000-0000-0000-0000000d0003', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-0000000ca002', 'wordpress', zz_check.id('job3'));
select nomad_core.cancel_job(zz_check.id('job3'));
update nomad_blog.post_publications set status = 'publishing' where id = '00000000-0000-0000-0000-0000000d0003';
select zz_check.fails_with($$update nomad_blog.post_publications set status = 'published' where id = '00000000-0000-0000-0000-0000000d0003'$$, 'job is already finished');
-- 발행 결과 불확실 → 사용자 확인
update nomad_blog.post_publications set status = 'failed' where id = '00000000-0000-0000-0000-0000000d0003';
update nomad_blog.post_publications set status = 'queued', job_id = zz_check.id('job6') where id = '00000000-0000-0000-0000-0000000d0003';
update nomad_blog.post_publications set status = 'publishing' where id = '00000000-0000-0000-0000-0000000d0003';
update nomad_blog.post_publications set status = 'unconfirmed' where id = '00000000-0000-0000-0000-0000000d0003';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job6') and not refund_on_failure$$, 1);
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.fails_with($$select nomad_blog.resolve_unconfirmed_publication('00000000-0000-0000-0000-0000000d0003', 'http://x')$$, 'https url required');
select nomad_blog.resolve_unconfirmed_publication('00000000-0000-0000-0000-0000000d0003', 'https://wp.test/3');
reset role;
select set_config('request.jwt.claims', '', true);
-- 원고 생성 결과: 작업이 살아 있으면 저장 + 환불 해제, 취소된 작업이면 거부(본문 없이 draft 로 돌리는 실패 정리는 허용)
insert into nomad_blog.posts (id, organization_id, title) values
  ('00000000-0000-0000-0000-0000000b0004', '00000000-0000-0000-0000-00000000000a', '생성 1'),
  ('00000000-0000-0000-0000-0000000b0005', '00000000-0000-0000-0000-00000000000a', '생성 2');
update nomad_blog.posts set status = 'generating', ai_job_id = zz_check.id('job4') where id = '00000000-0000-0000-0000-0000000b0004';
update nomad_blog.posts set status = 'generating', ai_job_id = zz_check.id('job5') where id = '00000000-0000-0000-0000-0000000b0005';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
do $$ declare n int; begin
  update nomad_blog.posts set title = 'x' where id = '00000000-0000-0000-0000-0000000b0004';   -- 생성 중 편집은 정책 밖(0건)
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'edited generating post'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_blog.posts set status = 'draft', body_html = '<p>생성</p>' where id = '00000000-0000-0000-0000-0000000b0004';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job4') and not refund_on_failure$$, 1);
select nomad_core.cancel_job(zz_check.id('job5'));
select zz_check.fails_with($$update nomad_blog.posts set status = 'draft', body_html = '<p>늦은 결과</p>' where id = '00000000-0000-0000-0000-0000000b0005'$$, 'job is already finished');
update nomad_blog.posts set status = 'draft', last_error = 'job canceled' where id = '00000000-0000-0000-0000-0000000b0005';
select zz_check.denied($$update nomad_blog.posts set ai_job_id = zz_check.id('jobB') where id = '00000000-0000-0000-0000-0000000b0005'$$);
-- 워커 잠금
select zz_check.expect_text($$select nomad_blog.acquire_channel_lock('00000000-0000-0000-0000-0000000ca002', zz_check.id('job6'))::text$$, 'true');
select zz_check.expect_text($$select nomad_blog.acquire_channel_lock('00000000-0000-0000-0000-0000000ca002', zz_check.id('job4'))::text$$, 'false');
select nomad_blog.release_channel_lock('00000000-0000-0000-0000-0000000ca002', zz_check.id('job6'));
-- 보관·사용량
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select nomad_blog.set_post_archived('00000000-0000-0000-0000-0000000b0005', true);
select zz_check.expect($$select count(*) from nomad_blog.posts where status = 'archived' and archived_at is not null$$, 1);
select zz_check.expect($$select nomad_blog.monthly_post_usage('00000000-0000-0000-0000-00000000000a')$$, 2);
reset role;
select set_config('request.jwt.claims', '', true);
-- 연결 해제(owner·admin): 공유되지 않은 자격은 폐기
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.fails_with($$select nomad_blog.disconnect_channel_account('00000000-0000-0000-0000-0000000ca001')$$, 'owner/admin only');
reset role;
select set_config('request.jwt.claims', '', true);
-- (해제 전에) 예약 발행 1건을 남겨 둔다 — 6절 끊김 회귀용
insert into nomad_blog.post_publications (id, organization_id, post_id, channel_account_id, channel, status, scheduled_at) values
  ('00000000-0000-0000-0000-0000000d0004', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-0000000ca002', 'wordpress', 'scheduled', now() + interval '1 day'),
  ('00000000-0000-0000-0000-0000000d0005', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000ca001', 'naver', 'queued', null);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_blog.cancel_publication('00000000-0000-0000-0000-0000000d0005');
select nomad_blog.disconnect_channel_account('00000000-0000-0000-0000-0000000ca001');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.provider_credentials where id = '00000000-0000-0000-0000-0000000c0a01' and revoked_at is not null$$, 1);
select zz_check.expect($$select count(*) from nomad_blog.channel_accounts where status = 'revoked' and credential_id is null$$, 1);
-- consent 1 · warn_ack 2 · cancel 2 · resolve 1 · archive 1 · disconnect 1
select zz_check.expect($$select count(*) from nomad_core.audit_log where action like 'blog.%'$$, 8);

-- ==== 6. 잠김 회귀: 구독이 끊기면 C = 원본 free 기능만(기존 유료 행 경로 포함) ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'blog';
update nomad_blog.posts set compliance_verdict = 'pass' where id = '00000000-0000-0000-0000-0000000b0004';
-- 구독 중 예약한 발행도 발행 시작 거부, 새 예약 거부
select zz_check.fails_with($$update nomad_blog.post_publications set status = 'publishing' where id = '00000000-0000-0000-0000-0000000d0004'$$, '(schedule)');
select zz_check.fails_with($$insert into nomad_blog.post_publications (organization_id, post_id, channel_account_id, channel, status, scheduled_at) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0004', '00000000-0000-0000-0000-0000000ca002', 'wordpress', 'scheduled', now() + interval '1 day')$$, '(schedule)');
-- 브랜드커넥트 원고(글 1) 발행 거부 — 채널을 다시 연결해 둔다
insert into nomad_blog.channel_accounts (id, organization_id, channel, external_account_id, status) values
  ('00000000-0000-0000-0000-0000000ca003', '00000000-0000-0000-0000-00000000000a', 'wordpress', 'wp-a2', 'active');
select zz_check.fails_with($$insert into nomad_blog.post_publications (organization_id, post_id, channel_account_id, channel) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000ca003', 'wordpress')$$, '(brandconnect)');
-- 제휴 자동 삽입 거부(수동 삽입은 무료 기능)
select zz_check.fails_with($$insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider, inserted_by) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0004', '00000000-0000-0000-0000-0000000a1103', 'coupang', 'auto')$$, '(affiliate_auto_insert)');
insert into nomad_blog.post_affiliate_links (organization_id, post_id, link_id, provider) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0004', '00000000-0000-0000-0000-0000000a1103', 'coupang');
-- 즉시 발행(무료)은 된다
insert into nomad_blog.post_publications (organization_id, post_id, channel_account_id, channel) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0004', '00000000-0000-0000-0000-0000000ca003', 'wordpress');
-- 사용자: 브랜드커넥트 새 연결 거부, 원고 작성은 된다
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$update nomad_blog.posts set brandconnect_application_id = '00000000-0000-0000-0000-0000000abc01' where id = '00000000-0000-0000-0000-0000000b0003'$$, '(brandconnect)');
insert into nomad_blog.posts (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', '무료 글');
reset role;
select set_config('request.jwt.claims', '', true);
-- 조직 비활성 = 전부 잠김
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select (select count(*) from nomad_blog.posts) + (select count(*) from nomad_blog.post_publications) + (select count(*) from nomad_blog.channel_accounts)$$, 0);
select zz_check.fails_with($$select nomad_blog.set_post_archived('00000000-0000-0000-0000-0000000b0003', true)$$, 'not found');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000a';

-- ==== 7. 동기화 컬럼: 수정하면 updated_at 증가 ====
do $$
declare v_before timestamptz; v_after timestamptz;
begin
  alter table nomad_blog.posts disable trigger posts_touch_updated_at;
  update nomad_blog.posts set updated_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-0000000b0003';
  alter table nomad_blog.posts enable trigger posts_touch_updated_at;
  select updated_at into v_before from nomad_blog.posts where id = '00000000-0000-0000-0000-0000000b0003';
  update nomad_blog.posts set title = '글 3 수정' where id = '00000000-0000-0000-0000-0000000b0003';
  select updated_at into v_after from nomad_blog.posts where id = '00000000-0000-0000-0000-0000000b0003';
  if v_after <= v_before then raise exception 'touch_updated_at not applied'; end if;
end $$;

-- ==== 8. 보안 리뷰 반영: 예약 발행 시작의 컴플라이언스 · 결과 전달 잠금 · 보관 복원 범위 ====
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'blog';
-- 예약 뒤 컴플라이언스가 fail 로 바뀐 원고는 발행 시작 거부(BL003)
update nomad_blog.posts set compliance_verdict = 'fail' where id = '00000000-0000-0000-0000-0000000b0003';
select zz_check.fails_with($$update nomad_blog.post_publications set status = 'publishing' where id = '00000000-0000-0000-0000-0000000d0004'$$, 'compliance gate not passed');
-- 결과 전달 판정은 잡 행 잠금 뒤
select zz_check.expect($$select count(*) from pg_proc where oid = 'nomad_blog.deliver_job_result'::regproc and prosrc like '%for update%'$$, 1);
-- 복원(archived=false)은 보관된 원고만
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.fails_with($$select nomad_blog.set_post_archived('00000000-0000-0000-0000-0000000b0004', false)$$, 'post is not archived');
select zz_check.expect_text($$select (nomad_blog.set_post_archived('00000000-0000-0000-0000-0000000b0005', false)).status$$, 'draft');
reset role;
select set_config('request.jwt.claims', '', true);
