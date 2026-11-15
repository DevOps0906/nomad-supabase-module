-- book-trailer org안 검사: 조직 2곳 교차 거부 · 역할(owner/editor/viewer) · 서버 컬럼 잠금 · 엔드카드·대가성 문구 규칙
-- · 실행/렌더(크레딧 선차감·작업 등록·멱등·취소 환불) · 플랜 기능 잠금(구독 끊김 = C) · 조직 비활성 잠김 · 함수 권한 · 동기화 컬럼.
-- 합성 데이터만. 실행: bash products/trailer/run_check.sh  (begin → 청사진 drop → org/0001·0002 → 이 파일 → rollback)

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
  ('00000000-0000-0000-0000-00000000000a', 'trailer', 'B', 'active');
-- 수치 한도는 시드하지 않으므로 검사 안에서만 B 값을 넣는다(C는 없음 → 원본 free 값 1)
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('trailer', 'B', 'max_books', 10), ('trailer', 'B', 'max_trailers_per_book', 5), ('trailer', 'B', 'brand_kits_max', 5),
  ('trailer', 'B', 'max_duration_s', 90);
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test grant', 'zz-grant-a', 'trailer');

-- ==== 0. 시드·구조 ====
select zz_check.expect($$select count(*) from nomad_trailer.grammars where status = 'published'$$, 6);
select zz_check.expect($$select count(*) from nomad_trailer.templates$$, 6);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'trailer'$$, 16);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_trailer' and not rowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_tables where schemaname = 'nomad_trailer'$$, 17);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_trailer' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.routine_privileges where routine_schema in ('nomad_trailer', 'nomad_trailer_private') and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from (values ('nomad_trailer'), ('nomad_trailer_private')) s(n) where has_schema_privilege('anon', n, 'usage')$$, 0);
-- 제품 함수 본문에 core 작업·원장 직접 쓰기 0건(mark_job_delivered·consume/refund 함수만)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_trailer', 'nomad_trailer_private')
    and p.prosrc ~* '(insert\s+into|update|delete\s+from)\s+nomad_core\.(jobs|credit_ledger)'$$, 0);
select zz_check.expect($$select count(*) from storage.buckets where id = 'trailer-files' and 'image/svg+xml' = any (allowed_mime_types)$$, 0);

-- ==== 1. anon: 테이블·함수 모두 거부 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_trailer.books');
select zz_check.denied('select count(*) from nomad_trailer.grammars');
select zz_check.denied($$select nomad_trailer.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_trailer.record_link_click('abcdef1234')$$);
reset role;

-- ==== 2. 조직 A owner(a1): 책·트레일러·장면·링크·키트·메타데이터 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_trailer.grammars$$, 6);
select zz_check.expect($$select count(*) from nomad_trailer.music_tracks$$, 0);
insert into nomad_trailer.books (id, organization_id, title, genre, manuscript_path) values
  ('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000a', '책 1', 'novel',
   '00000000-0000-0000-0000-00000000000a/trailer/books/00000000-0000-0000-0000-0000000b0001/manuscript.pdf');
select zz_check.fails_with($$insert into nomad_trailer.books (organization_id, title, manuscript_path) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-00000000000b/trailer/books/00000000-0000-0000-0000-0000000b0009/manuscript.pdf')$$, 'books_manuscript_path_check');
select zz_check.denied($$insert into nomad_trailer.books (organization_id, title, source, flora_book_id) values ('00000000-0000-0000-0000-00000000000a', 'x', 'flora', gen_random_uuid())$$);
-- 서버 컬럼은 grant 없음, 트리거가 이중 잠금
select zz_check.denied($$update nomad_trailer.books set digest_status = 'ready'$$);
select zz_check.denied($$update nomad_trailer.books set rights_ack_at = now()$$);
select zz_check.fails_with($$select nomad_trailer.acknowledge_rights('00000000-0000-0000-0000-0000000b0001', 'bad')$$, 'invalid notice version');
select nomad_trailer.acknowledge_rights('00000000-0000-0000-0000-0000000b0001', 'rights-2026-11-v1');
select zz_check.expect($$select count(*) from nomad_trailer.books where rights_ack_at is not null and rights_ack_by = '00000000-0000-0000-0000-0000000000a1'$$, 1);
insert into nomad_trailer.trailers (id, organization_id, book_id, title, grammar_code, template_code, formats) values
  ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', '트레일러 1',
   'novel_cinematic', 'poetry_ink', array['vertical_9_16', 'landscape_16_9']);
select zz_check.denied($$insert into nomad_trailer.trailers (organization_id, book_id, title, grammar_code, template_code, voice) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 't', 'novel_cinematic', 'cinematic_basic', '{"provider":"x"}')$$);
select zz_check.expect($$select count(*) from nomad_trailer.scenes where kind = 'end_card'$$, 1);
select zz_check.denied($$insert into nomad_trailer.scenes (organization_id, trailer_id, position, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 5, 'end_card')$$);
delete from nomad_trailer.scenes where kind = 'end_card';  -- 정책이 엔드카드를 대상에서 뺀다(0건)
select zz_check.expect($$select count(*) from nomad_trailer.scenes where kind = 'end_card'$$, 1);
insert into nomad_trailer.purchase_links (id, organization_id, book_id, store, url, is_affiliate) values
  ('00000000-0000-0000-0000-0000000d0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000b0001', 'kyobo', 'https://example.test/b', true);
select zz_check.denied($$update nomad_trailer.purchase_links set click_count = 99$$);
insert into nomad_trailer.metadata_packs (organization_id, trailer_id, platform, title, description, link_ids) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'youtube', '제목', '본문', array['00000000-0000-0000-0000-0000000d0001']::uuid[]);
select zz_check.expect($$select count(*) from nomad_trailer.metadata_packs where has_affiliate and description like disclosure || '%'$$, 1);
insert into nomad_trailer.brand_kits (organization_id, name, palette) values
  ('00000000-0000-0000-0000-00000000000a', '기본', '[{"role":"background","hex":"#000000"},{"role":"text","hex":"#FFFFFF"},{"role":"accent","hex":"#FF0000"}]');
select zz_check.fails_with($$insert into nomad_trailer.brand_kits (organization_id, name, palette) values ('00000000-0000-0000-0000-00000000000a', 'x', '[]')$$, 'brand_kits_palette_check');
insert into nomad_trailer.briefs (organization_id, trailer_id, source, content) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'manual', '{"logline":"x"}');
-- 사용자가 ai로 넣어도 트리거가 manual로 바꾼다
insert into nomad_trailer.briefs (organization_id, trailer_id, source, content) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'ai', '{}');
select zz_check.expect($$select count(*) from nomad_trailer.briefs where source = 'ai'$$, 0);
select zz_check.denied($$update nomad_trailer.briefs set content = '{}'$$);
-- 서버 기록 표는 쓰기 거부
select zz_check.denied($$insert into nomad_trailer.generation_runs (organization_id, kind, book_id, idempotency_key) values ('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', 'x')$$);
select zz_check.denied($$insert into nomad_trailer.grammars (code, name, beats) values ('zz', 'zz', '[1,2,3]')$$);
-- 서버 전용 함수 거부
select zz_check.denied($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', null, null, 1, 'run:trailer:req-00000001', '00000000-0000-0000-0000-0000000000a1')$$);
select zz_check.denied($$select nomad_trailer.decide_review(repeat('a', 64), 'approved')$$);
-- 플랜 B 한도: 책 10권까지(검사 시드), 링크 고정 10
select zz_check.expect($$select count(*) from nomad_trailer.books$$, 1);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 3. editor(a3) 쓰기 · viewer(a4) 읽기만 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
insert into nomad_trailer.scenes (id, organization_id, trailer_id, position, kind, text) values
  ('00000000-0000-0000-0000-0000000e0001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 1, 'hook_text', '훅');
delete from nomad_trailer.books;  -- editor는 삭제 정책 밖(0건)
select zz_check.expect($$select count(*) from nomad_trailer.books$$, 1);
select nomad_trailer.save_scene('00000000-0000-0000-0000-0000000e0001', '{"text":"훅 2"}', 1);
select zz_check.fails_with($$select nomad_trailer.save_scene('00000000-0000-0000-0000-0000000e0001', '{"text":"x"}', 1)$$, 'revision conflict');
select zz_check.fails_with($$select nomad_trailer.reorder_scenes('00000000-0000-0000-0000-0000000c0001', array[(select id from nomad_trailer.scenes where kind = 'end_card'), '00000000-0000-0000-0000-0000000e0001'::uuid])$$, 'end card must be last');
select nomad_trailer.reorder_scenes('00000000-0000-0000-0000-0000000c0001', array['00000000-0000-0000-0000-0000000e0001'::uuid, (select id from nomad_trailer.scenes where kind = 'end_card')]);
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.login('00000000-0000-0000-0000-0000000000a4');
select zz_check.expect($$select count(*) from nomad_trailer.scenes$$, 2);
select zz_check.denied($$insert into nomad_trailer.scenes (organization_id, trailer_id, position, kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 9, 'hook_text')$$);
do $$ declare n int; begin
  update nomad_trailer.scenes set text = 'viewer';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'viewer updated scenes'; end if;
end $$;
select zz_check.fails_with($$select nomad_trailer.acknowledge_rights('00000000-0000-0000-0000-0000000b0001', 'rights-2026-11-v2')$$, 'not an editor');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 4. 조직 B owner(a2): A 데이터 0건, A 조직으로 쓰기 거부, C 한도(책 1권) ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select (select count(*) from nomad_trailer.books) + (select count(*) from nomad_trailer.trailers) + (select count(*) from nomad_trailer.scenes)
  + (select count(*) from nomad_trailer.purchase_links) + (select count(*) from nomad_trailer.brand_kits) + (select count(*) from nomad_trailer.metadata_packs)
  + (select count(*) from nomad_trailer.briefs)$$, 0);
select zz_check.denied($$insert into nomad_trailer.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', 'B가 A에')$$);
select zz_check.fails_with($$select nomad_trailer.acknowledge_rights('00000000-0000-0000-0000-0000000b0001', 'rights-2026-11-v1')$$, 'not found');
-- 구독 없음 = C: 작업 공간은 열려 있다(원본 free), 책 한도는 원본 free 값 1
select zz_check.expect($$select count(*) from nomad_trailer.grammars$$, 6);
insert into nomad_trailer.books (id, organization_id, title) values ('00000000-0000-0000-0000-0000000b0002', '00000000-0000-0000-0000-00000000000b', 'B 책');
select zz_check.fails_with($$insert into nomad_trailer.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000b', 'B 책 2')$$, 'plan limit reached');
-- 다른 조직 책을 가리키는 트레일러(복합 FK) 거부
select zz_check.denied($$insert into nomad_trailer.trailers (organization_id, book_id, title, grammar_code, template_code) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000b0001', 'x', 'novel_cinematic', 'cinematic_basic')$$);
do $$ declare n int; begin
  update nomad_trailer.books set title = 'hack' where organization_id = '00000000-0000-0000-0000-00000000000a';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'B updated A book'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 5. 서버(관리 세션 = 서버 호출): 실행·렌더·크레딧·작업 ====
-- 원고 파싱 결과는 서버가 쓴다
update nomad_trailer.books set manuscript_sha256 = repeat('a', 64), manuscript_chars = 1000 where id = '00000000-0000-0000-0000-0000000b0001';
select zz_check.fails_with($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', null, null, 5, 'run:trailer:req-00000001', '00000000-0000-0000-0000-0000000000a4')$$, 'not an editor');
select zz_check.fails_with($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', null, null, 5, 'bad', '00000000-0000-0000-0000-0000000000a1')$$, 'idempotency key');
select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', null, null, 5, 'run:trailer:req-00000001', '00000000-0000-0000-0000-0000000000a1');
select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', null, null, 5, 'run:trailer:req-00000001', '00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_trailer.generation_runs$$, 1);
select zz_check.expect($$select count(*) from nomad_core.jobs where product_code = 'trailer' and credit_ledger_id is not null$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 95);
select zz_check.expect_text($$select digest_status from nomad_trailer.books where id = '00000000-0000-0000-0000-0000000b0001'$$, 'queued');
select zz_check.fails_with($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'digest', '00000000-0000-0000-0000-0000000b0001', null, null, 5, 'run:trailer:req-00000002', '00000000-0000-0000-0000-0000000000a1')$$, 'already running');
-- 다른 조직이 같은 멱등 키를 쓰면 거부
select zz_check.fails_with($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000b', 'digest', '00000000-0000-0000-0000-0000000b0002', null, null, 0, 'run:trailer:req-00000001', '00000000-0000-0000-0000-0000000000a2')$$, 'another organization');
insert into t_ids select 'run1', id::text from nomad_trailer.generation_runs;
select nomad_trailer.finish_run((select v::uuid from t_ids where k = 'run1'), '{"chapters":[{"n":1,"title":"1장"}]}');
select zz_check.expect_text($$select digest_status from nomad_trailer.books where id = '00000000-0000-0000-0000-0000000b0001'$$, 'ready');
select zz_check.expect($$select count(*) from nomad_core.jobs where product_code = 'trailer' and not refund_on_failure$$, 1);
select zz_check.fails_with($$select nomad_trailer.finish_run((select v::uuid from t_ids where k = 'run1'), '{"chapters":[]}')$$, 'already succeeded');
-- brief → storyboard
select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'brief', null, '00000000-0000-0000-0000-0000000c0001', null, 2, 'run:trailer:req-00000003', '00000000-0000-0000-0000-0000000000a1');
select nomad_trailer.finish_run((select id from nomad_trailer.generation_runs where kind = 'brief'), '{"briefs":[{"logline":"A"},{"logline":"B"}]}');
select zz_check.expect($$select count(*) from nomad_trailer.briefs$$, 4);
select zz_check.expect($$select count(*) from nomad_trailer.trailers where current_brief_id is not null$$, 1);
select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'storyboard', null, '00000000-0000-0000-0000-0000000c0001', null, 2, 'run:trailer:req-00000004', '00000000-0000-0000-0000-0000000000a1');
select nomad_trailer.finish_run((select id from nomad_trailer.generation_runs where kind = 'storyboard'),
  '{"scenes":[{"kind":"hook_text","text":"훅","duration_ms":3000},{"kind":"title_card","text":"제목","duration_ms":3000}]}');
select zz_check.expect($$select count(*) from nomad_trailer.scenes$$, 3);
select zz_check.expect($$select position from nomad_trailer.scenes where kind = 'end_card'$$, 2);
-- 취소 → 작업만 끝난 실행 정리 + 환불
select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'meta', null, '00000000-0000-0000-0000-0000000c0001', null, 3, 'run:trailer:req-00000005', '00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 88);
select nomad_core.cancel_job((select job_id from nomad_trailer.generation_runs where kind = 'meta'));
-- 작업이 이미 취소(환불)됐으면 결과를 받지 않는다
select zz_check.fails_with($$select nomad_trailer.finish_run((select id from nomad_trailer.generation_runs where kind = 'meta'), '{"packs":[]}')$$, 'job is already finished');
select zz_check.expect($$select nomad_trailer.reconcile_runs('00000000-0000-0000-0000-00000000000a')$$, 1);
select zz_check.expect_text($$select status from nomad_trailer.generation_runs where kind = 'meta'$$, 'canceled');
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 91);
-- 크레딧 부족(조직 B 잔액 0)은 전체 롤백
select zz_check.denied($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000b', 'digest', '00000000-0000-0000-0000-0000000b0002', null, null, 5, 'run:trailer:req-00000006', '00000000-0000-0000-0000-0000000000a2')$$);
select zz_check.expect($$select count(*) from nomad_trailer.generation_runs where organization_id = '00000000-0000-0000-0000-00000000000b'$$, 0);

-- 렌더: 플랜 B(A 조직) — 1080p·가로·프리미엄 템플릿 허용, 워터마크 없음
select zz_check.fails_with($$select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'square_1_1', '720p', 0, gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1')$$, 'not selected');
select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'landscape_16_9', '1080p', 10,
  '00000000-0000-0000-0000-0000000f0001', '00000000-0000-0000-0000-0000000000a1');
select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'landscape_16_9', '1080p', 10,
  '00000000-0000-0000-0000-0000000f0001', '00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_trailer.renders where plan_code = 'B' and not watermark$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 81);
select zz_check.fails_with($$select nomad_trailer.finish_render((select id from nomad_trailer.renders), 'other/path.mp4', null, null, 1, 1)$$, 'output path');
select nomad_trailer.finish_render((select id from nomad_trailer.renders), '00000000-0000-0000-0000-00000000000a/trailer/renders/' || (select id from nomad_trailer.renders) || '/trailer.mp4', null, null, 1000, 30000);
select zz_check.expect($$select count(*) from nomad_trailer.renders where status = 'succeeded' and expires_at > now() + interval '80 days'$$, 1);
-- 승인 링크는 A 플랜만 → B에서 TR005
select zz_check.fails_with($$select nomad_trailer.open_review('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', array[(select id from nomad_trailer.renders)], repeat('b', 64), '저자', '00000000-0000-0000-0000-0000000000a1')$$, 'higher plan');
update nomad_core.subscriptions set plan_code = 'A' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'trailer';
select nomad_trailer.open_review('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', array[(select id from nomad_trailer.renders)], repeat('b', 64), '저자', '00000000-0000-0000-0000-0000000000a1');
select nomad_trailer.decide_review(repeat('b', 64), 'approved', '좋아요');
select zz_check.expect_text($$select status from nomad_trailer.trailers$$, 'approved');
select zz_check.expect($$select count(*) from nomad_trailer.renders where snapshot -> 'music' ? 'storage_path'$$, 0);
-- FLORA 가져오기(A): 한도 검사 + 같은 책 중복 금지
select zz_check.fails_with($$select nomad_trailer.import_flora_book('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000f1001', '00000000-0000-0000-0000-0000000000a1', '플로라 책')$$, 'plan limit reached');
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('trailer', 'A', 'max_books', 100);
select nomad_trailer.import_flora_book('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000f1001', '00000000-0000-0000-0000-0000000000a1', '플로라 책', null, null, 'novel');
select zz_check.fails_with($$select nomad_trailer.import_flora_book('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000f1001', '00000000-0000-0000-0000-0000000000a1', '플로라 책')$$, 'already imported');
delete from nomad_trailer.books where source = 'flora';
select zz_check.fails_with($$select nomad_trailer.decide_review(repeat('b', 64), 'approved')$$, 'not valid');
-- 구매 링크 클릭(서버)
select zz_check.expect_text($$select nomad_trailer.record_link_click((select short_code from nomad_trailer.purchase_links), 'https://ref.test', repeat('c', 64))$$, 'https://example.test/b');
select zz_check.expect($$select click_count from nomad_trailer.purchase_links$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action like 'trailer.%'$$, 4);  -- rights_ack·review.open·review.approved·import_flora

-- ==== 6. 잠김 회귀: 구독이 끊기면 C = 원본 free 기능만 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'trailer';
update nomad_trailer.trailers set status = 'active';
select zz_check.fails_with($$select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'vertical_9_16', '1080p', 0, gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1')$$, '1080p needs a higher plan');
select zz_check.fails_with($$select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'landscape_16_9', '720p', 0, gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1')$$, 'needs a higher plan');
select zz_check.fails_with($$select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'vertical_9_16', '720p', 0, gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1')$$, 'premium template');
select zz_check.fails_with($$select nomad_trailer.open_review('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', array[(select id from nomad_trailer.renders)], repeat('d', 64), '저자', '00000000-0000-0000-0000-0000000000a1')$$, 'higher plan');
select zz_check.fails_with($$select nomad_trailer.import_flora_book('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', '책')$$, 'higher plan');
-- 무료 템플릿·세로 720p는 C에서도 되고, 워터마크가 강제된다
update nomad_trailer.trailers set template_code = 'cinematic_basic';
select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'vertical_9_16', '720p', 0,
  '00000000-0000-0000-0000-0000000f0002', '00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_trailer.renders where request_id = '00000000-0000-0000-0000-0000000f0002' and watermark and plan_code = 'C'$$, 1);
-- 사용자 문맥: C에서 책 한도는 원본 free 값 1(이미 1권) → 추가 거부
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$insert into nomad_trailer.books (organization_id, title) values ('00000000-0000-0000-0000-00000000000a', '책 2')$$, 'plan limit reached');
-- 음악 업로드(music_upload)는 C에서 잠김: 트레일러 음악 경로 지정 거부
select zz_check.fails_with($$update nomad_trailer.trailers set music_path = '00000000-0000-0000-0000-00000000000a/trailer/music/00000000-0000-0000-0000-0000000a0001.mp3'$$, 'music upload needs a higher plan');
-- 소프트 삭제 시각은 클라이언트 값 대신 now()
update nomad_trailer.books set deleted_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000b0001';
select zz_check.expect($$select count(*) from nomad_trailer.books where deleted_at = now()$$, 1);
update nomad_trailer.books set deleted_at = null where id = '00000000-0000-0000-0000-0000000b0001';
reset role;
select set_config('request.jwt.claims', '', true);
-- 구독 중 올린 음악도 C에서는 렌더 거부(서버가 경로를 넣은 상태 가정)
update nomad_trailer.trailers set music_path = '00000000-0000-0000-0000-00000000000a/trailer/music/00000000-0000-0000-0000-0000000a0001.mp3';
select zz_check.fails_with($$select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'vertical_9_16', '720p', 0, gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1')$$, 'uploaded music needs a higher plan');
update nomad_trailer.trailers set music_path = null;
-- 소프트 삭제된 책은 렌더 거부
update nomad_trailer.books set deleted_at = now() where id = '00000000-0000-0000-0000-0000000b0001';
select zz_check.fails_with($$select nomad_trailer.start_render('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000c0001', 'vertical_9_16', '720p', 0, gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1')$$, 'book is deleted');
update nomad_trailer.books set deleted_at = null where id = '00000000-0000-0000-0000-0000000b0001';
-- 조직 비활성 = 전부 잠김(표 0건, 서버 RPC 거부)
update nomad_core.organizations set active = false where id = '00000000-0000-0000-0000-00000000000a';
select zz_check.fails_with($$select nomad_trailer.start_run('00000000-0000-0000-0000-00000000000a', 'meta', null, '00000000-0000-0000-0000-0000000c0001', null, 0, 'run:trailer:req-00000007', '00000000-0000-0000-0000-0000000000a1')$$, 'no entitlement');
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select (select count(*) from nomad_trailer.books) + (select count(*) from nomad_trailer.scenes) + (select count(*) from nomad_trailer.renders)$$, 0);
-- (카탈로그는 가입 시 자동 생성되는 개인 조직(C)으로 계속 보인다 — 조직 데이터만 잠긴다)
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_core.organizations set active = true where id = '00000000-0000-0000-0000-00000000000a';

-- ==== 7. 동기화 컬럼: 수정하면 updated_at 증가 ====
do $$
declare v_before timestamptz; v_after timestamptz;
begin
  -- 트랜잭션 안이라 now()가 고정이므로 과거 값으로 돌려 둔 뒤 수정한다
  alter table nomad_trailer.books disable trigger books_touch_updated_at;
  update nomad_trailer.books set updated_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-0000000b0001';
  alter table nomad_trailer.books enable trigger books_touch_updated_at;
  select updated_at into v_before from nomad_trailer.books where id = '00000000-0000-0000-0000-0000000b0001';
  update nomad_trailer.books set title = '책 1 수정' where id = '00000000-0000-0000-0000-0000000b0001';
  select updated_at into v_after from nomad_trailer.books where id = '00000000-0000-0000-0000-0000000b0001';
  if v_after <= v_before then raise exception 'touch_updated_at not applied'; end if;
end $$;
