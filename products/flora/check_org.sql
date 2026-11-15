-- FLORA Publishing org안 검사: 조직 2곳 교차 거부 · 역할(owner/editor/viewer) · 서버 컬럼·서버 표 잠금 · 수량 한도(plan_limits, 없으면 free 값)
-- · 결과 저장(작업 실패·취소면 거부 + mark_job_delivered) · 참조 조직 일치(작업·원장·자격·표지) · 공개 RPC(anon) · trailer 계약(book_for_trailer)
-- · 플랜 기능 잠금(구독 끊김 = C, 기존 유료 행 경로 포함) · 조직 비활성 잠김 · 함수 권한 · 동기화 컬럼.
-- 합성 데이터만. 실행: bash products/flora/run_check.sh  (begin → 청사진 drop → org/0001·0002 → 이 파일 → rollback)

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
  ('00000000-0000-0000-0000-00000000000a', 'flora', 'B', 'active');
-- 수치 한도는 시드하지 않으므로 검사 안에서만 B 값을 넣는다(C는 없음 → 원본 free 값 3·3·6·3)
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('flora', 'B', 'max_books', 100), ('flora', 'B', 'max_chapters', 20), ('flora', 'B', 'max_sections', 200), ('flora', 'B', 'max_paragraphs', 5);
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test grant', 'zz-grant-a', 'flora');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000b', 10, 'test grant', 'zz-grant-b', 'flora');
-- 작업 7개(A) + 1개(B)
insert into t_ids select 'job' || n, (select id from nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000000a',
  p_product => 'flora', p_job_type => 'flora.test', p_idempotency_key => 'zz-job-' || n)) from generate_series(1, 7) n;
insert into t_ids select 'jobB', id from nomad_core.enqueue_job(p_organization => '00000000-0000-0000-0000-00000000000b',
  p_product => 'flora', p_job_type => 'flora.test', p_idempotency_key => 'zz-job-b');
-- 웹훅 서명 자격(합성, 원문 없음)
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4) values
  ('00000000-0000-0000-0000-0000000c0a01', '00000000-0000-0000-0000-00000000000a', 'outbound_webhook', 'hook', gen_random_uuid(), 'abcd'),
  ('00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-00000000000b', 'outbound_webhook', 'hook', gen_random_uuid(), 'abcd');

-- ==== 0. 시드·구조 ====
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_flora'$$, 13);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_flora' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'flora'$$, 12);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_flora' and grantee = 'anon'$$, 0);
-- anon 실행 권한은 공개 RPC 하나만, PUBLIC 0
select zz_check.expect($$select count(*) from information_schema.routine_privileges where routine_schema = 'nomad_flora' and grantee = 'PUBLIC'$$, 0);
select zz_check.expect_text($$select string_agg(routine_name, ',') from information_schema.routine_privileges where routine_schema = 'nomad_flora' and grantee = 'anon'$$, 'get_public_book');
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_flora' and p.prosecdef and not ('search_path=""' = any (coalesce(p.proconfig, '{}')))$$, 0);
-- 제품 함수 본문에 core 작업·원장 직접 쓰기 0건, core 표에 제품 트리거 0건
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_flora' and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+nomad_core\.'$$, 0);
select zz_check.expect($$select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid join pg_namespace pn on pn.oid = p.pronamespace
  where n.nspname = 'nomad_core' and pn.nspname = 'nomad_flora'$$, 0);
select zz_check.expect($$select count(*) from storage.buckets where id like 'flora-%' and (public or 'image/svg+xml' = any (allowed_mime_types))$$, 0);

-- ==== 1. anon: 표·사용자 함수 거부, 공개 RPC 만 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_flora.books');
select zz_check.denied('select count(*) from nomad_flora.waitlist');
select zz_check.denied($$select nomad_flora.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', true, 'x-book')$$);
select zz_check.expect_text($$select nomad_flora.get_public_book('no-such-book') ->> 'code'$$, 'not_found');
select zz_check.expect_text($$select nomad_flora.get_public_book('../../x') ->> 'code'$$, 'not_found');
reset role;

-- ==== 2. 조직 A owner(a1, 플랜 B): 책·목차·원고·설정 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into nomad_flora.books (id, organization_id, title, genre) values
  ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000a', '책 1', 'novel');
select zz_check.expect($$select count(*) from nomad_flora.books where created_by = '00000000-0000-0000-0000-0000000000a1' and status = 'draft'$$, 1);
-- 서버 컬럼은 grant 없음
select zz_check.denied($$update nomad_flora.books set is_public = true$$);
select zz_check.denied($$update nomad_flora.books set word_count = 9$$);
select zz_check.denied($$insert into nomad_flora.books (organization_id, title, slug) values ('00000000-0000-0000-0000-00000000000a', 'x', 'evil-slug')$$);
insert into nomad_flora.chapters (id, organization_id, book_id, position, title) values
  ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 1, '1장');
insert into nomad_flora.sections (id, organization_id, book_id, chapter_id, position, title, paragraph_target, body_html) values
  ('00000000-0000-0000-0000-0000000d0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001',
   '00000000-0000-0000-0000-0000000c0001', 1, '1절', 5, '<p>안녕</p>');
select zz_check.expect_text($$select gen_status || ':' || char_count || ':' || revision from nomad_flora.sections$$, 'edited:2:0');
update nomad_flora.sections set body_html = '<p>안녕하세요</p>';
select zz_check.expect($$select revision from nomad_flora.sections$$, 1);
select zz_check.denied($$update nomad_flora.sections set gen_status = 'generated'$$);
-- 서버 표·서버 함수 거부
select zz_check.denied($$insert into nomad_flora.cover_images (organization_id, book_id, style) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'minimal')$$);
select zz_check.denied($$insert into nomad_flora.generation_runs (organization_id, book_id, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'write_all')$$);
select zz_check.denied($$insert into nomad_flora.custom_personas (organization_id, name, taste_config) values ('00000000-0000-0000-0000-00000000000a', 'p', '{}')$$);
select zz_check.denied($$select nomad_flora.limit_of('00000000-0000-0000-0000-00000000000a', 'max_books', 3)$$);
select zz_check.denied($$select * from nomad_flora.book_for_trailer('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000000a1')$$);
-- 설정: 본인 행만, B 플랜이라 프로 테마·quality 허용
insert into nomad_flora.member_settings (organization_id, user_id, theme_key, llm_mode) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'lunaris-dark', 'quality');
select zz_check.denied($$insert into nomad_flora.member_settings (organization_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3')$$);
-- 상태 전이 + 공개 페이지
select zz_check.fails_with($$select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', true, 'my-book-1')$$, 'must be completed');
select zz_check.fails_with($$update nomad_flora.books set status = 'completed'$$, 'invalid status transition');
update nomad_flora.books set status = 'writing';
update nomad_flora.books set status = 'ready';
update nomad_flora.books set status = 'completed';
select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', true, 'my-book-1');
select zz_check.expect($$select count(*) from nomad_flora.books where is_public and published_at is not null$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 3. editor(a3) 쓰기 · viewer(a4) 읽기만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
insert into nomad_flora.chapters (organization_id, book_id, position, title) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 2, '2장');
delete from nomad_flora.books;  -- editor는 삭제 정책 밖(0건)
select zz_check.expect($$select count(*) from nomad_flora.books$$, 1);
select zz_check.fails_with($$select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', false)$$, 'owner/admin only');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.expect($$select count(*) from nomad_flora.chapters$$, 2);
select zz_check.denied($$insert into nomad_flora.chapters (organization_id, book_id, position, title) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 3, 'x')$$);
do $$ declare n int; begin
  update nomad_flora.sections set title = 'viewer';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'viewer updated sections'; end if;
end $$;
select zz_check.expect($$select count(*) from nomad_flora.webhook_endpoints$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 4. 조직 B owner(a2, 구독 없음 = C): A 데이터 0건, A 로 쓰기 거부, free 한도 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select (select count(*) from nomad_flora.books) + (select count(*) from nomad_flora.chapters) + (select count(*) from nomad_flora.sections)
  + (select count(*) from nomad_flora.member_settings)$$, 0);
select zz_check.denied($$insert into nomad_flora.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'B가 A에')$$);
select zz_check.fails_with($$select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', false)$$, 'not found');
do $$ declare n int; begin
  update nomad_flora.books set title = 'hack' where organization_id = '00000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'B updated A book'; end if;
end $$;
-- 무료(C)도 작업 공간은 열려 있다. 책 한도 3(원본 free)
insert into nomad_flora.books (id, organization_id, title) values
  ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-00000000000b', 'B 책 1'),
  ('00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-00000000000b', 'B 책 2'),
  ('00000000-0000-0000-0000-0000000b0004', '00000000-0000-0000-0000-00000000000b', 'B 책 3');
select zz_check.fails_with($$insert into nomad_flora.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000b', 'B 책 4')$$, 'plan limit reached');
-- 소프트 삭제: 시각은 now() 강제, 복원은 서버만, 삭제된 책은 한도에서 빠진다
update nomad_flora.books set deleted_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000b0004';
select zz_check.expect($$select count(*) from nomad_flora.books where deleted_at = now()$$, 1);
select zz_check.fails_with($$update nomad_flora.books set deleted_at = null where id = '00000000-0000-0000-0000-0000000b0004'$$, 'restore is server-only');
insert into nomad_flora.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000b', 'B 책 4');
-- 챕터 3·소제목 6·단락 3(free)
insert into nomad_flora.chapters (id, organization_id, book_id, position, title)
select ('00000000-0000-0000-0000-0000000c010' || n)::uuid, '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0002', n, n || '장'
from generate_series(1, 3) n;
select zz_check.fails_with($$insert into nomad_flora.chapters (organization_id, book_id, position, title) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0002', 4, '4장')$$, 'plan limit reached');
select zz_check.fails_with($$insert into nomad_flora.sections (organization_id, book_id, chapter_id, position, title, paragraph_target) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-0000000c0101', 1, 'x', 4)$$, 'exceeds plan limit');
-- 다른 조직 책을 가리키는 챕터(복합 FK) 거부
select zz_check.denied($$insert into nomad_flora.chapters (organization_id, book_id, position, title) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0001', 9, 'x')$$);
-- 프로 테마·quality 는 C 에서 잠김
select zz_check.fails_with($$insert into nomad_flora.member_settings (organization_id, user_id, theme_key) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'halo-dev')$$, 'not in the current plan');
select zz_check.fails_with($$insert into nomad_flora.member_settings (organization_id, user_id, llm_mode) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'quality')$$, 'quality mode needs a higher plan');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 5. 서버(관리 세션 = 서버 호출): 결과 저장·참조 조직·기능 ====
-- 표지: 작업이 살아 있으면 성공 저장 + 환불 해제, 다른 조직 작업은 FK 거부
insert into nomad_flora.cover_images (id, organization_id, book_id, style, job_id) values
  ('00000000-0000-0000-0000-0000000e0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'minimal', zz_check.id('job1')),
  ('00000000-0000-0000-0000-0000000e0002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'photo', zz_check.id('job2'));
select zz_check.denied($$insert into nomad_flora.cover_images (organization_id, book_id, style, job_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'photo', zz_check.id('jobB'))$$);
select zz_check.fails_with($$insert into nomad_flora.cover_images (organization_id, book_id, style, storage_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'photo', '00000000-0000-0000-0000-00000000000b/flora/covers/x.png')$$, 'cover_images_path_check');
update nomad_flora.cover_images set status = 'running' where id in ('00000000-0000-0000-0000-0000000e0001', '00000000-0000-0000-0000-0000000e0002');
update nomad_flora.cover_images set status = 'succeeded', storage_path = '00000000-0000-0000-0000-00000000000a/flora/covers/1.png'
 where id = '00000000-0000-0000-0000-0000000e0001';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job1') and not refund_on_failure$$, 1);
select nomad_core.cancel_job(zz_check.id('job2'));
select zz_check.fails_with($$update nomad_flora.cover_images set status = 'succeeded' where id = '00000000-0000-0000-0000-0000000e0002'$$, 'job is already finished');
-- 원고 생성 결과: 생성 중 사용자 편집 거부 → 서버 결과 저장 + 환불 해제
update nomad_flora.sections set gen_status = 'queued', last_job_id = zz_check.id('job3') where id = '00000000-0000-0000-0000-0000000d0001';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$update nomad_flora.sections set body_html = 'x'$$, 'being generated');
-- 표지 선택: 성공한 이 책 표지만
update nomad_flora.books set cover_image_id = '00000000-0000-0000-0000-0000000e0001' where id = '00000000-0000-0000-0000-0000000b0001';
select zz_check.fails_with($$update nomad_flora.books set cover_image_id = '00000000-0000-0000-0000-0000000e0002' where id = '00000000-0000-0000-0000-0000000b0001'$$, 'not ready');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_flora.sections set gen_status = 'generated', body_html = '<p>생성된 원고</p>' where id = '00000000-0000-0000-0000-0000000d0001';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job3') and not refund_on_failure$$, 1);
-- 전체 생성: B 플랜 write_all·quality 허용, 책당 진행 중 1개, 취소 요청(editor 가능, viewer·타 조직 거부)
insert into nomad_flora.generation_runs (id, organization_id, book_id, kind, mode, parent_job_id) values
  ('00000000-0000-0000-0000-0000000f0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'write_all', 'quality', zz_check.id('job4'));
select zz_check.denied($$insert into nomad_flora.generation_runs (organization_id, book_id, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'refine_all')$$);
select zz_check.fails_with($$insert into nomad_flora.generation_runs (organization_id, book_id, kind) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0002', 'write_all')$$, 'needs a higher plan');
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.fails_with($$select nomad_flora.request_generation_cancel('00000000-0000-0000-0000-0000000f0001')$$, 'editor role required');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$select nomad_flora.request_generation_cancel('00000000-0000-0000-0000-0000000f0001')$$, 'not found');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select nomad_flora.request_generation_cancel('00000000-0000-0000-0000-0000000f0001');
select zz_check.expect($$select count(*) from nomad_flora.generation_runs where cancel_requested_by = '00000000-0000-0000-0000-0000000000a3'$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);
-- 실행 결과: 부모 작업이 실패·취소면 succeeded/partial 저장 거부
update nomad_flora.generation_runs set status = 'running' where id = '00000000-0000-0000-0000-0000000f0001';
select nomad_core.cancel_job(zz_check.id('job4'));
select zz_check.fails_with($$update nomad_flora.generation_runs set status = 'partial' where id = '00000000-0000-0000-0000-0000000f0001'$$, 'job is already finished');
update nomad_flora.generation_runs set status = 'failed' where id = '00000000-0000-0000-0000-0000000f0001';
-- 내보내기: 원장은 같은 조직 것만, 워터마크 없음은 B 허용·C 거부
insert into t_ids select 'ledA', ledger_id::text from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000a', 2, 'flora.export', 'consume:flora:export:zz1', 'flora', 'book_export', 'zz1');
insert into t_ids select 'ledB', ledger_id::text from nomad_core.consume_credits('00000000-0000-0000-0000-00000000000b', 2, 'flora.export', 'consume:flora:export:zz2', 'flora', 'book_export', 'zz2');
insert into nomad_flora.book_exports (id, organization_id, book_id, format, job_id, credit_ledger_id, content_hash, watermark, preset) values
  ('00000000-0000-0000-0000-0000000a0e01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'pdf', zz_check.id('job5'), zz_check.id('ledA'), 'h1', false, '{}');
select zz_check.fails_with($$insert into nomad_flora.book_exports (organization_id, book_id, format, credit_ledger_id, content_hash, watermark, preset) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'pdf', zz_check.id('ledB'), 'h2', false, '{}')$$, 'another organization');
select zz_check.fails_with($$insert into nomad_flora.book_exports (organization_id, book_id, format, content_hash, watermark, preset) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0002', 'pdf', 'h3', false, '{}')$$, 'needs a higher plan');
insert into nomad_flora.book_exports (organization_id, book_id, format, credit_ledger_id, content_hash, watermark, preset) values
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0002', 'epub', zz_check.id('ledB'), 'h4', true, '{}');
update nomad_flora.book_exports set status = 'running' where id = '00000000-0000-0000-0000-0000000a0e01';
update nomad_flora.book_exports set status = 'succeeded', storage_path = '00000000-0000-0000-0000-00000000000a/flora/exports/1.pdf' where id = '00000000-0000-0000-0000-0000000a0e01';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job5') and not refund_on_failure$$, 1);
-- 웹훅: 서명 자격은 같은 조직 것만
insert into nomad_flora.webhook_endpoints (id, organization_id, url, events, secret_credential_id) values
  ('00000000-0000-0000-0000-0000000a0f01', '00000000-0000-0000-0000-00000000000a', 'https://hook.example.test/a', array['book.completed'], '00000000-0000-0000-0000-0000000c0a01');
select zz_check.denied($$insert into nomad_flora.webhook_endpoints (organization_id, url, events, secret_credential_id) values ('00000000-0000-0000-0000-00000000000a', 'https://hook.example.test/b', array['book.completed'], '00000000-0000-0000-0000-0000000c0b01')$$);
select zz_check.fails_with($$insert into nomad_flora.webhook_endpoints (organization_id, url, events, secret_credential_id) values ('00000000-0000-0000-0000-00000000000b', 'https://hook.example.test/c', array['book.completed'], '00000000-0000-0000-0000-0000000c0b01')$$, 'needs a higher plan');
insert into nomad_flora.webhook_deliveries (organization_id, endpoint_id, event_type, event_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000a0f01', 'book.completed', gen_random_uuid());
-- 원고 업로드: 경로는 같은 조직 flora 폴더, C 는 잠김
insert into nomad_flora.manuscript_uploads (id, organization_id, storage_path, ext) values
  ('00000000-0000-0000-0000-0000000a0d01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a/flora/manuscripts/1.pdf', 'pdf');
select zz_check.fails_with($$insert into nomad_flora.manuscript_uploads (organization_id, storage_path, ext) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b/flora/manuscripts/2.pdf', 'pdf')$$, 'manuscript_uploads_path_check');
select zz_check.fails_with($$insert into nomad_flora.manuscript_uploads (organization_id, storage_path, ext) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b/flora/manuscripts/3.pdf', 'pdf')$$, 'needs a higher plan');
update nomad_flora.manuscript_uploads set status = 'uploaded';
-- 나만의 페르소나: B 허용, C 거부
insert into nomad_flora.custom_personas (id, organization_id, name, taste_config) values
  ('00000000-0000-0000-0000-0000000a0c01', '00000000-0000-0000-0000-00000000000a', '내 문체', '{}');
select zz_check.fails_with($$insert into nomad_flora.custom_personas (organization_id, name, taste_config) values ('00000000-0000-0000-0000-00000000000b', 'x', '{}')$$, 'needs a higher plan');
-- 에이전트 작업: 결과 → 검수 → 결정, 재시도 규칙
insert into nomad_flora.agent_tasks (id, organization_id, book_id, agent_key, action, request_id, job_id) values
  ('00000000-0000-0000-0000-0000000a0a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'writing', 'draft_section', 'req-00000001', zz_check.id('job6')),
  ('00000000-0000-0000-0000-0000000a0a02', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'editing', 'refine', 'req-00000002', null);
select zz_check.denied($$insert into nomad_flora.agent_tasks (organization_id, agent_key, action, request_id) values ('00000000-0000-0000-0000-00000000000a', 'writing', 'x_y', 'req-00000001')$$);
update nomad_flora.agent_tasks set status = 'running' where id = '00000000-0000-0000-0000-0000000a0a01';
update nomad_flora.agent_tasks set status = 'succeeded', approval_status = 'pending' where id = '00000000-0000-0000-0000-0000000a0a01';
select zz_check.expect($$select count(*) from nomad_core.jobs where id = zz_check.id('job6') and not refund_on_failure$$, 1);
select zz_check.fails_with($$insert into nomad_flora.agent_tasks (organization_id, book_id, agent_key, action, request_id, retry_of, attempt) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'writing', 'draft_section', 'req-00000003', '00000000-0000-0000-0000-0000000a0a01', 2)$$, 'only failed/partial/canceled');
update nomad_flora.agent_tasks set status = 'failed' where id = '00000000-0000-0000-0000-0000000a0a02';
insert into nomad_flora.agent_tasks (organization_id, book_id, agent_key, action, request_id, retry_of, attempt) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'editing', 'refine', 'req-00000004', '00000000-0000-0000-0000-0000000a0a02', 2);
select zz_check.denied($$insert into nomad_flora.agent_tasks (organization_id, book_id, agent_key, action, request_id, retry_of, attempt) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'editing', 'refine', 'req-00000005', '00000000-0000-0000-0000-0000000a0a02', 2)$$);
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select nomad_flora.decide_agent_task('00000000-0000-0000-0000-0000000a0a01', 'approved', '좋아요');
select zz_check.fails_with($$select nomad_flora.decide_agent_task('00000000-0000-0000-0000-0000000a0a01', 'rejected')$$, 'not awaiting review');
reset role;
select set_config('request.jwt.claims', '', true);
-- trailer 계약: 멤버·이용권·같은 조직 책만 책 정보를 준다
select zz_check.expect_text($$select title || '/' || genre from nomad_flora.book_for_trailer('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000000a3')$$, '책 1/novel');
select zz_check.fails_with($$select * from nomad_flora.book_for_trailer('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000000a2')$$, 'not a member');
select zz_check.fails_with($$select * from nomad_flora.book_for_trailer('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000000a2')$$, 'not found');
-- 공개 페이지(anon): 공개 컬럼만
set local role anon;
select zz_check.expect_text($$select nomad_flora.get_public_book('my-book-1') -> 'book' ->> 'title'$$, '책 1');
select zz_check.expect_text($$select ((nomad_flora.get_public_book('my-book-1') -> 'book') ? 'organization_id')::text$$, 'false');
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where action like 'flora.%'$$, 3);  -- publish_page·cancel_request·decide

-- ==== 6. 잠김 회귀: 구독이 끊기면 C = 원본 free 기능만(기존 유료 행 경로 포함) ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'flora';
select zz_check.fails_with($$insert into nomad_flora.generation_runs (organization_id, book_id, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'write_all')$$, '(write_all)');
select zz_check.fails_with($$update nomad_flora.manuscript_uploads set status = 'parsing' where id = '00000000-0000-0000-0000-0000000a0d01'$$, '(upload)');
select zz_check.fails_with($$insert into nomad_flora.webhook_deliveries (organization_id, endpoint_id, event_type, event_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000a0f01', 'book.completed', gen_random_uuid())$$, '(webhooks)');
update nomad_flora.webhook_endpoints set status = 'disabled';
select zz_check.fails_with($$update nomad_flora.webhook_endpoints set status = 'active'$$, '(webhooks)');
select zz_check.fails_with($$insert into nomad_flora.book_exports (organization_id, book_id, format, content_hash, watermark, preset) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'pdf', 'h5', false, '{}')$$, '(no_watermark)');
insert into nomad_flora.book_exports (organization_id, book_id, format, content_hash, watermark, preset) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'pdf', 'h6', true, '{}');
select zz_check.fails_with($$insert into nomad_flora.custom_personas (organization_id, name, taste_config) values ('00000000-0000-0000-0000-00000000000a', 'x', '{}')$$, '(persona_blend)');
-- 이미 공개한 책의 독자 열람은 유지(microweb 과 같은 원칙). 새 공개는 아래에서 거부
set local role anon;
select zz_check.expect_text($$select nomad_flora.get_public_book('my-book-1') -> 'book' ->> 'title'$$, '책 1');
reset role;
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', true, 'my-book-1')$$, 'public_page needs a higher plan');
reset role;
select set_config('request.jwt.claims', '', true);
-- 조직 비활성이면 공개 책도 not_found
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
set local role anon;
select zz_check.expect_text($$select nomad_flora.get_public_book('my-book-1') ->> 'code'$$, 'not_found');
reset role;
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000a';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
-- 끄기는 기능 없이도 된다(끈 뒤에는 not_found)
select nomad_flora.set_book_visibility('00000000-0000-0000-0000-0000000b0001', false);
select zz_check.expect_text($$select nomad_flora.get_public_book('my-book-1') ->> 'code'$$, 'not_found');
-- 기존 프로 테마·quality 설정은 다음 저장 때 기본값으로 내린다
update nomad_flora.member_settings set favorite_persona_ids = array['p1'];
select zz_check.expect_text($$select theme_key || ':' || llm_mode from nomad_flora.member_settings$$, 'flora-dark:fast');
select zz_check.fails_with($$update nomad_flora.member_settings set theme_key = 'halo-dev'$$, 'not in the current plan');
-- 구독 중 만든 나만의 페르소나를 새 책에 붙이지 못한다
insert into nomad_flora.books (id, organization_id, title) values ('00000000-0000-0000-0000-0000000b0005', '00000000-0000-0000-0000-00000000000a', '책 2');
select zz_check.fails_with($$update nomad_flora.books set custom_persona_id = '00000000-0000-0000-0000-0000000a0c01' where id = '00000000-0000-0000-0000-0000000b0005'$$, '(persona_blend)');
-- 무료 범위(작업 공간·챕터)는 계속 된다. C 책 한도 3(원본 free)
insert into nomad_flora.chapters (organization_id, book_id, position, title) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0005', 1, '1장');
insert into nomad_flora.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', '책 3');
select zz_check.fails_with($$insert into nomad_flora.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', '책 4')$$, 'plan limit reached');
reset role;
select set_config('request.jwt.claims', '', true);
-- 조직 비활성 = 전부 잠김(표 0건, 서버 RPC 거부)
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
select zz_check.fails_with($$select * from nomad_flora.book_for_trailer('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-0000000000a1')$$, 'no entitlement');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select (select count(*) from nomad_flora.books) + (select count(*) from nomad_flora.sections) + (select count(*) from nomad_flora.member_settings)
  + (select count(*) from nomad_flora.agent_tasks)$$, 0);
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000a';

-- ==== 7. 동기화 컬럼: 수정하면 updated_at 증가 ====
do $$
declare v_before timestamptz; v_after timestamptz;
begin
  alter table nomad_flora.books disable trigger books_touch_updated_at;
  update nomad_flora.books set updated_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-0000000b0001';
  alter table nomad_flora.books enable trigger books_touch_updated_at;
  select updated_at into v_before from nomad_flora.books where id = '00000000-0000-0000-0000-0000000b0001';
  update nomad_flora.books set title = '책 1 수정' where id = '00000000-0000-0000-0000-0000000b0001';
  select updated_at into v_after from nomad_flora.books where id = '00000000-0000-0000-0000-0000000b0001';
  if v_after <= v_before then raise exception 'touch_updated_at not applied'; end if;
end $$;

-- ==== 8. 보안 리뷰 반영: 비멤버 플랜 노출 · 결과 전달 INSERT·잠금 · editor 소프트 삭제 ====
-- 비멤버(B owner a2)가 A 조직으로 쓰면 BEFORE 트리거가 플랜·한도를 판정하기 전에 42501
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.fails_with($$insert into nomad_flora.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'B가 A에')$$, 'not a member of this organization');
select zz_check.fails_with($$insert into nomad_flora.member_settings (organization_id, user_id, theme_key) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'halo-dev')$$, 'not a member of this organization');
reset role;
select set_config('request.jwt.claims', '', true);
-- 결과 상태로 바로 INSERT 해도 취소된 작업이면 거부(PB015), 판정은 잡 행 잠금 뒤
select zz_check.fails_with($$insert into nomad_flora.cover_images (organization_id, book_id, style, job_id, status, storage_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'photo', zz_check.id('job2'), 'succeeded', '00000000-0000-0000-0000-00000000000a/flora/covers/9.png')$$, 'job is already finished');
select zz_check.expect($$select count(*) from pg_proc where oid = 'nomad_flora.deliver_job_result'::regproc and prosrc like '%for update%'$$, 1);
-- editor(a3)는 소프트 삭제 불가(owner·admin 만), owner 는 가능
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select zz_check.fails_with($$update nomad_flora.books set deleted_at = now() where id = '00000000-0000-0000-0000-0000000b0001'$$, 'only owner/admin may delete');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$with u as (update nomad_flora.books set deleted_at = now() where id = '00000000-0000-0000-0000-0000000b0001' returning 1) select count(*) from u$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);
