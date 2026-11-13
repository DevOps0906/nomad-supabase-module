-- AI 계층 검증: 서버 전용 권한표(사용자 접근 0 · 사용자 래퍼 0개) · 라우팅 해석 · 국외 동의 · 강제 오픈소스
--   · 벡터 검색 조직 격리 · 위키 이력 불변·개인정보 삭제 · 비용 원 정수 (합성 데이터, 롤백)
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

-- 첫 성분만 v인 1024차원 단위 벡터(합성)
create function pg_temp.vec(i integer) returns extensions.vector
language sql as $$
  select (select array_agg(case when g = i then 1 else 0 end order by g) from generate_series(1, 1024) g)::real[]::extensions.vector
$$;

insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000a1', 'ai-owner@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a2', 'ai-viewer@example.test', now(), false, '{}');
insert into nomad_core.products (code, name) values ('aitest', 'AI 테스트 제품'), ('aitest2', 'AI 테스트 제품 2');
insert into nomad_core.organizations (id, name, kind) values
 ('00000000-0000-4000-8000-00000000a0a0', 'AI A팀', 'team'),
 ('00000000-0000-4000-8000-00000000b0b0', 'AI B팀', 'team'),
 ('00000000-0000-4000-8000-00000000c0c0', 'AI C팀(삭제용)', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a1', 'owner'),
 ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000000a2', 'viewer');

-- 1. 권한표: AI 표 15개 · 함수 7개 모두 authenticated·anon 접근 0, 사용자 정책 0, public 래퍼 0개
do $$
declare
  t text;
  f regprocedure;
  v_tables text[] := array['ai_providers', 'ai_model_prices', 'ai_routing_settings', 'ai_org_settings', 'ai_collections',
                           'ai_documents', 'ai_chunks', 'wiki_pages', 'wiki_links', 'wiki_revisions', 'ai_conversations',
                           'ai_messages', 'ai_runs', 'ai_run_steps', 'ai_usage'];
begin
  foreach t in array v_tables loop
    if has_table_privilege('authenticated', 'nomad_core.' || t, 'select,insert,update,delete,truncate,references,trigger')
       or has_table_privilege('anon', 'nomad_core.' || t, 'select,insert,update,delete,truncate,references,trigger')
    then raise exception '% grants too wide', t; end if;
    if not has_table_privilege('service_role', 'nomad_core.' || t, 'select')
       or not has_table_privilege('service_role', 'nomad_core.' || t, 'insert')
    then raise exception '% service_role grant missing', t; end if;
    if not (select relrowsecurity from pg_class where oid = ('nomad_core.' || t)::regclass)
    then raise exception '% RLS off', t; end if;
  end loop;
  -- 표 목록 고정: 이 목록 밖의 ai_*·wiki_* 표가 생기면 이 검사도 함께 고친다
  if (select count(*) from pg_tables where schemaname = 'nomad_core' and (tablename like 'ai\_%' or tablename like 'wiki\_%'))
     <> cardinality(v_tables) then raise exception 'unexpected ai/wiki table set'; end if;
  -- 위키 실삭제는 purge_wiki_page·조직 삭제 연쇄로만, 이력은 추가 전용
  if has_table_privilege('service_role', 'nomad_core.wiki_pages', 'delete')
     or has_table_privilege('service_role', 'nomad_core.wiki_revisions', 'update,delete')
  then raise exception 'service_role can delete wiki directly'; end if;
  if exists (select 1 from pg_policies where schemaname = 'nomad_core' and tablename = any (v_tables))
  then raise exception 'user policies on ai tables'; end if;
  for f in select p.oid::regprocedure from pg_proc p
           where p.pronamespace = 'nomad_core'::regnamespace
             and p.proname in ('ai_filter_chain', 'match_ai_chunks', 'resolve_ai_route', 'set_ai_routing',
                               'set_ai_cross_border_ack', 'purge_wiki_page', 'wiki_revisions_immutable') loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
    then raise exception '% executable by user', f; end if;
  end loop;
  if (select count(*) from pg_proc p where p.pronamespace = 'nomad_core'::regnamespace
      and p.proname in ('ai_filter_chain', 'match_ai_chunks', 'resolve_ai_route', 'set_ai_routing',
                        'set_ai_cross_border_ack', 'purge_wiki_page', 'wiki_revisions_immutable')) <> 7
  then raise exception 'ai function set changed'; end if;
  -- 사용자 래퍼 0개: public(및 다른 노출 스키마)에 AI·위키 함수·뷰가 없다
  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
             and (p.proname ~ '(^|_)(ai|wiki)(_|$)' or p.prosrc ~ 'nomad_core\.(ai_|wiki_|match_ai|resolve_ai|set_ai|purge_wiki)'))
  then raise exception 'user wrapper for ai exists'; end if;
  if exists (select 1 from pg_views where schemaname = 'public' and definition ~ 'nomad_core\.(ai_|wiki_)')
  then raise exception 'public view over ai tables exists'; end if;
  if to_regnamespace('ai_runtime') is not null then raise exception 'ai_runtime schema must not exist'; end if;
  -- 임베딩 1024차원 · 비용 원 정수
  if (select atttypid = 'extensions.vector'::regtype and atttypmod = 1024 from pg_attribute
      where attrelid = 'nomad_core.ai_chunks'::regclass and attname = 'embedding') is not true
  then raise exception 'embedding is not vector(1024)'; end if;
  if (select atttypid::regtype::text from pg_attribute
      where attrelid = 'nomad_core.ai_usage'::regclass and attname = 'cost_krw') <> 'integer'
  then raise exception 'cost_krw is not integer'; end if;
end $$;

-- 2. 로그인 사용자(조직 owner)도 표·함수 모두 거부
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1"}', true);
select pg_temp.expect_err($q$select count(*) from nomad_core.ai_providers$q$, '%permission denied%');
select pg_temp.expect_err($q$select count(*) from nomad_core.ai_usage$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'chat', 'llm')$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.set_ai_cross_border_ack('00000000-0000-4000-8000-00000000a0a0', true, 'v1')$q$, '%permission denied%');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.expect_err($q$select count(*) from nomad_core.wiki_pages$q$, '%permission denied%');
reset role;

-- 3. 서버: 제품 라우팅 시드 형식(organization_id null) 재실행 멱등 — nulls not distinct
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'aitest', 'chat', 'llm', 'auto', '[{"provider":"anthropic","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'aitest', 'moderate', 'llm', 'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'aitest', 'sensitive', 'llm', 'open_source', '[{"provider":"anthropic","model":"*"},{"provider":"oss-llm","model":"*"}]', true)
on conflict do nothing;
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'aitest', 'chat', 'llm', 'auto', '[{"provider":"openai","model":"*"}]', false)
on conflict do nothing;
do $$
declare r jsonb;
begin
  if (select count(*) from nomad_core.ai_routing_settings where product_code = 'aitest') <> 3 then raise exception 'seed not idempotent'; end if;
  -- 국외 동의 없음: 상용(국외) 제공자 제외
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'CHAT ', 'llm');
  if r -> 'chain' <> '[{"provider":"oss-llm","model":"*"}]'::jsonb or (r ->> 'cross_border_ack')::boolean
  then raise exception 'no-ack chain wrong: %', r; end if;
  -- 동의 후: 원래 순서 그대로
  perform nomad_core.set_ai_cross_border_ack('00000000-0000-4000-8000-00000000a0a0', true, 'v1', '00000000-0000-4000-8000-0000000000a1');
  if (select ack_by from nomad_core.ai_org_settings where organization_id = '00000000-0000-4000-8000-00000000a0a0')
     is distinct from '00000000-0000-4000-8000-0000000000a1' then raise exception 'ack_by not actor'; end if;
  if not exists (select 1 from nomad_core.audit_log where action = 'ai.cross_border.ack'
                 and metadata ->> 'actor_id' = '00000000-0000-4000-8000-0000000000a1') then raise exception 'ack audit actor missing'; end if;
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'chat', 'llm');
  if r -> 'chain' <> '[{"provider":"anthropic","model":"*"},{"provider":"oss-llm","model":"*"}]'::jsonb or r ->> 'mode' <> 'auto'
  then raise exception 'ack chain wrong: %', r; end if;
  -- 다른 조직(B)은 동의가 없으므로 여전히 제외
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'chat', 'llm');
  if r -> 'chain' <> '[{"provider":"oss-llm","model":"*"}]'::jsonb then raise exception 'ack leaked to B: %', r; end if;
  -- 강제 오픈소스 범위
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'moderate', 'llm');
  if r ->> 'mode' <> 'open_source' or not (r ->> 'force_open_source')::boolean then raise exception 'force wrong: %', r; end if;
  -- 상용이 섞인 체인 + 강제 오픈소스: 국외 동의가 있어도 상용 제거
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'sensitive', 'llm');
  if r -> 'chain' <> '[{"provider":"oss-llm","model":"*"}]'::jsonb or r ->> 'mode' <> 'open_source'
  then raise exception 'forced mixed chain wrong: %', r; end if;
  -- 설정 없는 종류: 활성 오픈소스 제공자로 대체
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'x', 'embedding');
  if r -> 'chain' <> '[{"provider":"oss-embed","model":"*"}]'::jsonb then raise exception 'fallback wrong: %', r; end if;
  -- 조직 설정이 플랫폼보다 우선, 같은 범위 재설정은 갱신(행 1개)
  perform nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'chat', 'llm', 'commercial',
                                    '[{"provider":"openai","model":"*"}]');
  perform nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'chat', 'llm', 'commercial',
                                    '[{"provider":"google","model":"*"}]', false, '00000000-0000-4000-8000-0000000000a1');
  if (select updated_by from nomad_core.ai_routing_settings where organization_id = '00000000-0000-4000-8000-00000000a0a0')
     is distinct from '00000000-0000-4000-8000-0000000000a1' then raise exception 'updated_by not actor'; end if;
  if (select count(*) from nomad_core.ai_routing_settings where organization_id = '00000000-0000-4000-8000-00000000a0a0') <> 1
  then raise exception 'set_ai_routing not upsert'; end if;
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'chat', 'llm');
  if r -> 'chain' <> '[{"provider":"google","model":"*"}]'::jsonb or r ->> 'mode' <> 'commercial' then raise exception 'org override wrong: %', r; end if;
  -- 철회하면 즉시 국외 제외 → 플랫폼 기본도 없으니 오픈소스 대체
  perform nomad_core.set_ai_cross_border_ack('00000000-0000-4000-8000-00000000a0a0', false);
  r := nomad_core.resolve_ai_route('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'chat', 'llm');
  if r -> 'chain' <> '[{"provider":"oss-llm","model":"*"}]'::jsonb or r ->> 'mode' <> 'open_source'
  then raise exception 'revoke not applied (chain/mode): %', r; end if;
  if (select count(*) from nomad_core.audit_log where action in ('ai.routing.set', 'ai.cross_border.ack', 'ai.cross_border.revoke')
      and organization_id = '00000000-0000-4000-8000-00000000a0a0') <> 4 then raise exception 'audit rows missing'; end if;
end $$;

-- set_ai_routing 검증: 국외 동의 필요(AI002) · 플랫폼 강제 해제 불가(AI001) · 알 수 없는/종류 다른 제공자 · 입력
select pg_temp.expect_err($q$select nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'chat', 'llm', 'auto', '[{"provider":"anthropic","model":"*"}]')$q$, '%cross-border consent required%');
select pg_temp.expect_err($q$select nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'moderate', 'llm', 'auto', '[{"provider":"oss-llm","model":"*"}]')$q$, '%platform requires open_source%');
select pg_temp.expect_err($q$select nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'chat', 'llm', 'auto', '[{"provider":"nope","model":"*"}]')$q$, '%unknown, inactive%');
select pg_temp.expect_err($q$select nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'chat', 'llm', 'open_source', '[{"provider":"oss-embed","model":"*"}]')$q$, '%unknown, inactive%');
select pg_temp.expect_err($q$select nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'chat', 'llm', 'bogus')$q$, '%invalid mode%');
select pg_temp.expect_err($q$select nomad_core.set_ai_cross_border_ack('00000000-0000-4000-8000-00000000b0b0', true, ' ')$q$, '%notice version required%');
-- actor는 그 조직 owner·admin만(viewer·다른 조직 사용자 거부)
select pg_temp.expect_err($q$select nomad_core.set_ai_cross_border_ack('00000000-0000-4000-8000-00000000a0a0', true, 'v2', '00000000-0000-4000-8000-0000000000a2')$q$, '%actor must be owner/admin%');
select pg_temp.expect_err($q$select nomad_core.set_ai_routing('00000000-0000-4000-8000-00000000b0b0', 'aitest', 'chat', 'llm', 'auto', '[{"provider":"oss-llm","model":"*"}]', false, '00000000-0000-4000-8000-0000000000a1')$q$, '%actor must be owner/admin%');

-- 4. 벡터 검색: 조직·제품 격리, 준비 안 된 문서 제외, 다른 조직 컬렉션 지정 거부
insert into nomad_core.ai_collections (id, organization_id, product_code, kind, name, embedding_provider, embedding_model) values
  ('00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 'rag', 'docs', 'oss-embed', 'bge-m3'),
  ('00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-00000000b0b0', 'aitest', 'rag', 'docs', 'oss-embed', 'bge-m3'),
  ('00000000-0000-4000-8000-0000000c0a02', '00000000-0000-4000-8000-00000000a0a0', 'aitest2', 'rag', 'docs', 'oss-embed', 'bge-m3');
insert into nomad_core.ai_documents (id, collection_id, organization_id, product_code, source_type, content_hash, status) values
  ('00000000-0000-4000-8000-0000000d0a01', '00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 'text', 'h1', 'ready'),
  ('00000000-0000-4000-8000-0000000d0a02', '00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 'text', 'h2', 'pending'),
  ('00000000-0000-4000-8000-0000000d0b01', '00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-00000000b0b0', 'aitest', 'text', 'h1', 'ready'),
  ('00000000-0000-4000-8000-0000000d0a03', '00000000-0000-4000-8000-0000000c0a02', '00000000-0000-4000-8000-00000000a0a0', 'aitest2', 'text', 'h1', 'ready');
insert into nomad_core.ai_chunks (document_id, collection_id, organization_id, product_code, chunk_index, content, embedding) values
  ('00000000-0000-4000-8000-0000000d0a01', '00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 0, 'A 준비됨', pg_temp.vec(1)),
  ('00000000-0000-4000-8000-0000000d0a02', '00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 0, 'A 대기', pg_temp.vec(1)),
  ('00000000-0000-4000-8000-0000000d0b01', '00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-00000000b0b0', 'aitest', 0, 'B 비밀', pg_temp.vec(1)),
  ('00000000-0000-4000-8000-0000000d0a03', '00000000-0000-4000-8000-0000000c0a02', '00000000-0000-4000-8000-00000000a0a0', 'aitest2', 0, 'A 다른 제품', pg_temp.vec(1));
do $$
declare v text[];
begin
  select array_agg(content) into v from nomad_core.match_ai_chunks('00000000-0000-4000-8000-00000000a0a0', 'aitest', pg_temp.vec(1), 5);
  if v is distinct from array['A 준비됨'] then raise exception 'match isolation wrong: %', v; end if;
end $$;
-- 조직 불일치 문서를 다른 조직 이름으로 넣을 수 없다(복합 외래키)
select pg_temp.expect_err($q$insert into nomad_core.ai_chunks (document_id, collection_id, organization_id, product_code, chunk_index, content, embedding) values ('00000000-0000-4000-8000-0000000d0b01', '00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 1, 'x', pg_temp.vec(2))$q$, '%foreign key%');
select pg_temp.expect_err($q$select * from nomad_core.match_ai_chunks('00000000-0000-4000-8000-00000000a0a0', 'aitest', pg_temp.vec(1), 5, '00000000-0000-4000-8000-0000000c0b01')$q$, '%collection not in organization/product%');
select pg_temp.expect_err($q$select * from nomad_core.match_ai_chunks('00000000-0000-4000-8000-00000000a0a0', 'aitest', pg_temp.vec(1), 0)$q$, '%k must be 1..50%');
select pg_temp.expect_err($q$select * from nomad_core.match_ai_chunks('00000000-0000-4000-8000-00000000a0a0', 'aitest', pg_temp.vec(1), 5, null, null)$q$, '%min_similarity are required%');
select pg_temp.expect_err($q$select * from nomad_core.match_ai_chunks('00000000-0000-4000-8000-00000000a0a0', 'aitest', pg_temp.vec(1), 5, '00000000-0000-4000-8000-0000000c0a02')$q$, '%collection not in organization/product%');
select pg_temp.expect_err($q$insert into nomad_core.ai_collections (organization_id, product_code, kind, name, embedding_provider, embedding_model, embedding_dim) values ('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'rag', 'd2', 'oss-embed', 'm', 768)$q$, '%ai_collections_embedding_dim_check%');

-- 5. 위키: 이력 추가 전용, purge_wiki_page만 실제 삭제
-- 페이지의 컬렉션은 같은 조직·제품만(복합 외래키)
select pg_temp.expect_err($q$insert into nomad_core.wiki_pages (organization_id, product_code, collection_id, slug, title) values ('00000000-0000-4000-8000-00000000a0a0', 'aitest', '00000000-0000-4000-8000-0000000c0b01', 'x', 'x')$q$, '%foreign key%');
insert into nomad_core.wiki_pages (id, organization_id, product_code, collection_id, slug, title) values
  ('00000000-0000-4000-8000-0000000e0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', '00000000-0000-4000-8000-0000000c0a01', 'guide', '안내'),
  ('00000000-0000-4000-8000-0000000e0a02', '00000000-0000-4000-8000-00000000a0a0', 'aitest', null, 'guide/faq', '자주 묻는 질문');
-- 위키 페이지에서 만든 문서·청크(wiki_page_id 연결). source_type='wiki'면 연결 필수
insert into nomad_core.ai_documents (id, collection_id, organization_id, product_code, source_type, content_hash, status, wiki_page_id) values
  ('00000000-0000-4000-8000-0000000d0a09', '00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 'wiki', 'w1', 'ready', '00000000-0000-4000-8000-0000000e0a01');
insert into nomad_core.ai_chunks (document_id, collection_id, organization_id, product_code, chunk_index, content, embedding) values
  ('00000000-0000-4000-8000-0000000d0a09', '00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 0, '위키 본문', pg_temp.vec(3));
select pg_temp.expect_err($q$insert into nomad_core.ai_documents (collection_id, organization_id, product_code, source_type, content_hash) values ('00000000-0000-4000-8000-0000000c0a01', '00000000-0000-4000-8000-00000000a0a0', 'aitest', 'wiki', 'w2')$q$, '%ai_documents_wiki_page_check%');
insert into nomad_core.wiki_links (organization_id, from_page_id, to_page_id) values
  ('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000e0a01', '00000000-0000-4000-8000-0000000e0a02');
insert into nomad_core.wiki_revisions (page_id, organization_id, version, body_md, editor_kind) values
  ('00000000-0000-4000-8000-0000000e0a01', '00000000-0000-4000-8000-00000000a0a0', 1, '본문', 'agent');
select pg_temp.expect_err($q$update nomad_core.wiki_revisions set body_md = 'x'$q$, '%permission denied%');
select pg_temp.expect_err($q$delete from nomad_core.wiki_revisions$q$, '%permission denied%');
select pg_temp.expect_err($q$delete from nomad_core.wiki_pages where id = '00000000-0000-4000-8000-0000000e0a01'$q$, '%permission denied%');
select pg_temp.expect_err($q$select nomad_core.purge_wiki_page('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000e0a01', '')$q$, '%reason required%');
select pg_temp.expect_err($q$select nomad_core.purge_wiki_page('00000000-0000-4000-8000-00000000b0b0', '00000000-0000-4000-8000-0000000e0a01', '합성')$q$, '%page not in organization%');
select nomad_core.purge_wiki_page('00000000-0000-4000-8000-00000000a0a0', '00000000-0000-4000-8000-0000000e0a01', '개인정보 삭제 요청(합성)');
do $$
begin
  if exists (select 1 from nomad_core.wiki_pages where id = '00000000-0000-4000-8000-0000000e0a01')
     or exists (select 1 from nomad_core.wiki_revisions where page_id = '00000000-0000-4000-8000-0000000e0a01')
     or exists (select 1 from nomad_core.wiki_links where from_page_id = '00000000-0000-4000-8000-0000000e0a01')
     or exists (select 1 from nomad_core.ai_documents where wiki_page_id = '00000000-0000-4000-8000-0000000e0a01')
     or exists (select 1 from nomad_core.ai_chunks where document_id = '00000000-0000-4000-8000-0000000d0a09')
  then raise exception 'purge incomplete'; end if;
  if not exists (select 1 from nomad_core.wiki_pages where id = '00000000-0000-4000-8000-0000000e0a02') then raise exception 'purge too wide'; end if;
  if not exists (select 1 from nomad_core.audit_log where action = 'ai.wiki.purge') then raise exception 'purge audit missing'; end if;
end $$;

-- 6. 사용량: 원 단위 정수, 음수 거부
insert into nomad_core.ai_usage (organization_id, product_code, provider, model, kind, input_tokens, output_tokens, cost_usd_micros, cost_krw)
values ('00000000-0000-4000-8000-00000000a0a0', 'aitest', 'oss-llm', 'm', 'llm', 10, 20, 1500, 2);
select pg_temp.expect_err($q$insert into nomad_core.ai_usage (organization_id, provider, model, cost_krw) values ('00000000-0000-4000-8000-00000000a0a0', 'p', 'm', -1)$q$, '%ai_usage_cost_krw_check%');
-- 같은 조직 같은 request_id 중복 거부(다른 조직·request_id null은 허용)
insert into nomad_core.ai_usage (organization_id, provider, model, request_id) values
  ('00000000-0000-4000-8000-00000000a0a0', 'p', 'm', 'req-1'), ('00000000-0000-4000-8000-00000000b0b0', 'p', 'm', 'req-1'), ('00000000-0000-4000-8000-00000000a0a0', 'p', 'm', null), ('00000000-0000-4000-8000-00000000a0a0', 'p', 'm', null);
select pg_temp.expect_err($q$insert into nomad_core.ai_usage (organization_id, provider, model, request_id) values ('00000000-0000-4000-8000-00000000a0a0', 'p', 'm', 'req-1')$q$, '%ai_usage_request_uniq%');
reset role;

-- 7. 조직 삭제 연쇄: 이력 있는 조직도 지워진다(불변 트리거는 직접 수정·삭제만 막는다). 관리 세션
select set_config('request.jwt.claims', '', true);
insert into nomad_core.wiki_pages (id, organization_id, product_code, slug, title) values
  ('00000000-0000-4000-8000-0000000e0c01', '00000000-0000-4000-8000-00000000c0c0', 'aitest', 'p', '삭제될 페이지');
insert into nomad_core.wiki_revisions (page_id, organization_id, version, body_md, editor_kind) values
  ('00000000-0000-4000-8000-0000000e0c01', '00000000-0000-4000-8000-00000000c0c0', 1, '본문', 'user');
select pg_temp.expect_err($q$delete from nomad_core.wiki_revisions where organization_id = '00000000-0000-4000-8000-00000000c0c0'$q$, '%append-only%');
select pg_temp.expect_err($q$update nomad_core.wiki_revisions set body_md = 'x' where organization_id = '00000000-0000-4000-8000-00000000c0c0'$q$, '%append-only%');
delete from nomad_core.organizations where id = '00000000-0000-4000-8000-00000000c0c0';
do $$
begin
  if exists (select 1 from nomad_core.wiki_revisions where organization_id = '00000000-0000-4000-8000-00000000c0c0')
  then raise exception 'org cascade left revisions'; end if;
end $$;

rollback;
\o
\echo ai.sql OK
