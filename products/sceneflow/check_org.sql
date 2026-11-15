-- sceneflow org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · 공개 RPC(D8)·anon · 기능 잠금(C) · 크레딧 선차감·환불·잡(결과 저장 거부·전달 표시)
--   · 구독 끊김 잠김 회귀(기존 행 경로 포함) · 반환 컬럼 회귀 · 소프트 삭제 · AI 시드(0002). 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/sceneflow/run_check.sh

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
create table zz_check.vals (k text primary key, v text);
grant all on zz_check.vals to service_role, authenticated;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer, 플랜 A 구독), 조직 B(u2 owner, 구독 없음 = C 무료), u4 = 어느 조직에도 없음 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'sceneflow', 'A', 'active');
-- 한도는 저장소 시드가 아니라 검사용(트랜잭션 rollback)
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('sceneflow', 'A', 'max_channels', 5), ('sceneflow', 'A', 'storyboard_max_minutes', 60), ('sceneflow', 'A', 'shorts_extract_max', 10),
  ('sceneflow', 'A', 'render_max_resolution', 2160), ('sceneflow', 'A', 'render_max_fps', 60), ('sceneflow', 'A', 'aspect_variants_max', 3),
  ('sceneflow', 'A', 'edit_presets_max', 20), ('sceneflow', 'C', 'max_channels', 1);

-- ==== 0. 서버: 채널·제휴 링크·랜딩·생산·출력물·크레딧 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_sceneflow.channels (id, organization_id, platform, external_channel_id, name) values
  ('00000000-0000-0000-0000-0000000010a1', '00000000-0000-0000-0000-00000000000a', 'youtube', 'yt-a', 'A 유튜브'),
  ('00000000-0000-0000-0000-0000000010a2', '00000000-0000-0000-0000-00000000000a', 'instagram', 'ig-a', 'A 인스타'),
  ('00000000-0000-0000-0000-0000000010b1', '00000000-0000-0000-0000-00000000000b', 'youtube', 'yt-b', 'B 유튜브');
-- C(무료): YouTube 외 플랫폼 VD004, YouTube 한도(C max_channels 1) VD003
select zz_check.fails_with($$insert into nomad_sceneflow.channels (organization_id, platform, external_channel_id) values ('00000000-0000-0000-0000-00000000000b', 'tiktok', 'tt-b')$$, 'VD004');
select zz_check.fails_with($$insert into nomad_sceneflow.channels (organization_id, platform, external_channel_id) values ('00000000-0000-0000-0000-00000000000b', 'youtube', 'yt-b2')$$, 'VD003');
insert into nomad_core.affiliate_links (id, organization_id, provider, product_code, original_url, affiliate_url, short_code) values
  ('00000000-0000-0000-0000-0000000020a1', '00000000-0000-0000-0000-00000000000a', 'coupang', 'sceneflow', 'https://example.test/p', 'https://link.example.test/a', 'zzcheckaa1'),
  ('00000000-0000-0000-0000-0000000020b1', '00000000-0000-0000-0000-00000000000b', 'coupang', 'sceneflow', 'https://example.test/q', 'https://link.example.test/b', 'zzcheckbb1');
insert into nomad_sceneflow.landing_pages (id, organization_id, slug, product_name, primary_link_id) values
  ('00000000-0000-0000-0000-0000000030a1', '00000000-0000-0000-0000-00000000000a', 'a-landing', '상품 A', '00000000-0000-0000-0000-0000000020a1'),
  ('00000000-0000-0000-0000-0000000030b1', '00000000-0000-0000-0000-00000000000b', 'b-landing', '상품 B', '00000000-0000-0000-0000-0000000020b1');
-- 조직 일치: 다른 조직 제휴 링크(복합 FK)·관련 링크 배열(트리거)
select zz_check.fails_with($$insert into nomad_sceneflow.landing_pages (organization_id, slug, product_name, primary_link_id) values ('00000000-0000-0000-0000-00000000000b', 'b-x', 'x', '00000000-0000-0000-0000-0000000020a1')$$, '23503');
select zz_check.fails_with($$update nomad_sceneflow.landing_pages set related_link_ids = array['00000000-0000-0000-0000-0000000020a1']::uuid[] where id = '00000000-0000-0000-0000-0000000030b1'$$, 'VD002');
insert into nomad_sceneflow.productions (id, organization_id, track, request_id) values
  ('00000000-0000-0000-0000-0000000040a1', '00000000-0000-0000-0000-00000000000a', 'A', gen_random_uuid());
insert into nomad_sceneflow.outputs (id, organization_id, kind, production_id, language, status) values
  ('00000000-0000-0000-0000-0000000050a1', '00000000-0000-0000-0000-00000000000a', 'short', '00000000-0000-0000-0000-0000000040a1', 'KO', 'ready');
-- 업로드(A, 인스타그램): 컴플라이언스 통과 → approved (구독 끊김 회귀용)
insert into nomad_sceneflow.uploads (id, organization_id, output_id, channel_id, platform, title) values
  ('00000000-0000-0000-0000-0000000060a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000050a1', '00000000-0000-0000-0000-0000000010a2', 'instagram', '업로드 A');
insert into nomad_sceneflow.compliance_checks (id, organization_id, upload_id, verdict) values
  ('00000000-0000-0000-0000-0000000061a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000060a1', 'pass');
update nomad_sceneflow.uploads set status = 'checking' where id = '00000000-0000-0000-0000-0000000060a1';
select zz_check.fails_with($$update nomad_sceneflow.uploads set status = 'approved' where id = '00000000-0000-0000-0000-0000000060a1'$$, 'VD011');
update nomad_sceneflow.uploads set status = 'approved', compliance_check_id = '00000000-0000-0000-0000-0000000061a1' where id = '00000000-0000-0000-0000-0000000060a1';
-- 다른 조직 출력물·채널로 업로드 거부(복합 FK)
select zz_check.fails_with($$insert into nomad_sceneflow.uploads (organization_id, output_id, channel_id, platform, title) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000050a1', '00000000-0000-0000-0000-0000000010b1', 'youtube', 'x')$$, '23503');
-- 크레딧 원장 조직 일치(트리거): A 원장을 B 행에 붙이면 VD002
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test', 'zz:grant:a', 'sceneflow');
select zz_check.fails_with($$insert into nomad_sceneflow.radar_reports (organization_id, kind, credit_ledger_id) values ('00000000-0000-0000-0000-00000000000b', 'topic_score', (select id from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a' limit 1))$$, 'VD002');
insert into nomad_sceneflow.linkinbio_profiles (organization_id, handle, is_published) values ('00000000-0000-0000-0000-00000000000b', 'b_handle', true);
insert into nomad_sceneflow.linkinbio_items (organization_id, profile_id, kind, title, url)
select '00000000-0000-0000-0000-00000000000b', p.id, 'link', '홈', 'https://example.test' from nomad_sceneflow.linkinbio_profiles p where p.handle = 'b_handle';
reset role;

-- ==== 1. anon: 공개 RPC 만, 표·사용자 RPC 거부 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_sceneflow.landing_pages');
select zz_check.denied('select count(*) from nomad_sceneflow.storyboards');
select zz_check.denied('select count(*) from nomad_sceneflow.storyboard_templates');
select zz_check.denied($$select nomad_sceneflow.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030a1', 'published')$$);
select zz_check.expect_text($$select nomad_sceneflow.get_public_landing('a-landing')::text$$, null);   -- 아직 draft
select zz_check.expect_text($$select nomad_sceneflow.get_public_linkinbio('b_handle') ->> 'handle'$$, 'b_handle');   -- 무료(C) 기능
select zz_check.expect_text($$select nomad_sceneflow.get_public_linkinbio('../x')::text$$, null);
reset role;

-- ==== 2. 조직 A owner: 랜딩 공개, 스토리보드 만들기 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect_text($$select (nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030a1', 'published')).status$$, 'published');
select zz_check.fails_with($$select nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030b1', 'published')$$, '42501');
select zz_check.expect('select count(*) from nomad_sceneflow.landing_pages', 1);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboard_templates', 5);
-- 사용자 insert 에는 id grant 가 없다 → id 없이 넣고, 검사용 고정 id 로 postgres 가 바꾼다
with i as (insert into nomad_sceneflow.storyboards (organization_id, title, format, aspect, target_seconds, template_code)
  values ('00000000-0000-0000-0000-00000000000a', '쇼츠 1', 'shorts', '9:16', 30, 'list_topn') returning id)
insert into zz_check.vals select 'sb1', id::text from i;
reset role;
update nomad_sceneflow.storyboards set id = '00000000-0000-0000-0000-0000000070a1' where id = (select v::uuid from zz_check.vals where k = 'sb1');
set local role authenticated;
select zz_check.fails_with($$insert into nomad_sceneflow.storyboards (organization_id, title, format, aspect, target_seconds, template_code) values ('00000000-0000-0000-0000-00000000000b', 'x', 'shorts', '9:16', 30, 'list_topn')$$, '42501');
-- 서버 컬럼(status·version)은 사용자 grant 없음
select zz_check.denied($$update nomad_sceneflow.storyboards set status = 'ready' where id = '00000000-0000-0000-0000-0000000070a1'$$);
-- 고객(agency, A 플랜만)
insert into nomad_sceneflow.clients (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', '고객 1');
reset role;

-- ==== 3. 역할: editor 는 쓰기(Track F), 링크인바이오·고객은 owner/admin. viewer 는 읽기만. 비멤버 0 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
with i as (insert into nomad_sceneflow.music_library (organization_id, title, license_type, license_proof_path, youtube_monetization_allowed, audio_path)
  values ('00000000-0000-0000-0000-00000000000a', '곡 1', 'purchased', '00000000-0000-0000-0000-00000000000a/sceneflow/music_library/00000000-0000-0000-0000-0000000081a1.pdf', true, '00000000-0000-0000-0000-00000000000a/sceneflow/music_library/00000000-0000-0000-0000-0000000081a2.mp3') returning id)
insert into zz_check.vals select 'ml1', id::text from i;
reset role;
update nomad_sceneflow.music_library set id = '00000000-0000-0000-0000-0000000080a1' where id = (select v::uuid from zz_check.vals where k = 'ml1');
set local role authenticated;
select zz_check.fails_with($$insert into nomad_sceneflow.linkinbio_profiles (organization_id, handle) values ('00000000-0000-0000-0000-00000000000a', 'a_handle')$$, '42501');
select zz_check.fails_with($$insert into nomad_sceneflow.clients (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', '고객 2')$$, '42501');
-- 소프트 삭제·복구는 owner/admin
select zz_check.fails_with($$update nomad_sceneflow.storyboards set deleted_at = now() where id = '00000000-0000-0000-0000-0000000070a1'$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboards', 1);
select zz_check.fails_with($$insert into nomad_sceneflow.workflows (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'w')$$, '42501');
select zz_check.expect($$with u as (update nomad_sceneflow.storyboards set title = 'viewer' returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$select nomad_sceneflow.update_channel_settings('00000000-0000-0000-0000-0000000010a1', 'trend')$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboards', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.channels', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboard_templates', 0);
reset role;

-- ==== 4. 조직 B(C 무료): A 행 0건·수정 0건, 유료 기능 잠김, 무료 기능 동작 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboards', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.music_library', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.uploads', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.channels', 1);
select zz_check.expect($$with u as (update nomad_sceneflow.music_library set title = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (delete from nomad_sceneflow.storyboards returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$select nomad_sceneflow.save_scene(gen_random_uuid(), 1, '{}')$$, 'P0002');
select zz_check.fails_with($$insert into nomad_sceneflow.storyboards (organization_id, title, format, aspect, target_seconds, template_code) values ('00000000-0000-0000-0000-00000000000b', 'x', 'shorts', '9:16', 30, 'list_topn')$$, 'VD009');   -- 멤버에게는 플랜 잠금으로 알린다
select zz_check.fails_with($$insert into nomad_sceneflow.playlists (organization_id, title, mood, target_duration_min) values ('00000000-0000-0000-0000-00000000000b', 'p', 'cafe', 30)$$, '42501');
select zz_check.fails_with($$select nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030b1', 'published')$$, 'VD009');
select zz_check.expect('select count(*) from nomad_sceneflow.storyboard_templates', 0);
-- 무료: 워크플로·금칙어
insert into nomad_sceneflow.workflows (organization_id, name) values ('00000000-0000-0000-0000-00000000000b', 'B 흐름');
insert into nomad_sceneflow.banned_words (organization_id, word) values ('00000000-0000-0000-0000-00000000000b', '금칙');
-- B 는 A 조직 행을 만들 수 없다
select zz_check.fails_with($$insert into nomad_sceneflow.workflows (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$, '42501');
reset role;

-- ==== 5. 서버: 렌더 — 선차감·잡·멱등·환불·결과 저장 거부·전달 표시 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_sceneflow.apply_storyboard_result('00000000-0000-0000-0000-0000000070a1',
  '[{"kind":"text_card","duration_ms":10000,"on_screen_text":"1"},{"kind":"text_card","duration_ms":10000,"on_screen_text":"2"},{"kind":"text_card","duration_ms":10000,"on_screen_text":"3"}]');
select zz_check.fails_with($$select * from nomad_sceneflow.start_cut_render('00000000-0000-0000-0000-0000000070a1', '00000000-0000-0000-0000-0000000000a2', gen_random_uuid(), 5)$$, '42501');
select zz_check.fails_with($$select * from nomad_sceneflow.start_cut_render('00000000-0000-0000-0000-0000000070a1', '00000000-0000-0000-0000-0000000000a5', gen_random_uuid(), 5)$$, '42501');
insert into zz_check.vals select 'cut1', r.cut_id::text from nomad_sceneflow.start_cut_render('00000000-0000-0000-0000-0000000070a1',
  '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000090a1', 5) r;
-- 같은 request_id = 같은 렌더(재차감 없음)
select zz_check.expect_text($$select r.cut_id::text || '/' || r.credits from nomad_sceneflow.start_cut_render('00000000-0000-0000-0000-0000000070a1', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000090a1', 5) r$$,
  (select v || '/5' from zz_check.vals where k = 'cut1'));
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 95);
select zz_check.expect_text($$select status from nomad_sceneflow.storyboards where id = '00000000-0000-0000-0000-0000000070a1'$$, 'rendering');
-- 렌더 중 사용자 편집 거부(VD020)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_sceneflow.save_scene((select id from nomad_sceneflow.scenes where ord = 1), 1, '{"on_screen_text":"x"}')$$, 'VD020');
select zz_check.fails_with($$update nomad_sceneflow.storyboards set title = 'x' where id = '00000000-0000-0000-0000-0000000070a1'$$, 'VD020');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_sceneflow.fail_cut_render((select v::uuid from zz_check.vals where k = 'cut1'), 'too early')$$, '55000');
-- 재현 A: 잡이 최종 실패(core 가 환불)한 뒤 결과 저장 시도 → 출력물 ready·완료 모두 거부
select count(*) from nomad_core.claim_jobs('sceneflow.orchestrate', 'w1', 1, null, 'sceneflow');
select nomad_core.fail_job(c.job_id, 'w1', 1, 'render error', false) from nomad_sceneflow.storyboard_cuts c where c.id = (select v::uuid from zz_check.vals where k = 'cut1');
select zz_check.fails_with($$insert into nomad_sceneflow.outputs (organization_id, kind, storyboard_cut_id, language, status) values ('00000000-0000-0000-0000-00000000000a', 'short', (select v::uuid from zz_check.vals where k = 'cut1'), 'KO', 'ready')$$, '55000');
select zz_check.fails_with($$select nomad_sceneflow.finish_cut_render((select v::uuid from zz_check.vals where k = 'cut1'))$$, '55000');
select zz_check.expect_text($$select (nomad_sceneflow.fail_cut_render((select v::uuid from zz_check.vals where k = 'cut1'), 'render error') ->> 'refunded')$$, '0');
select zz_check.fails_with($$select nomad_sceneflow.fail_cut_render((select v::uuid from zz_check.vals where k = 'cut1'), 'again')$$, '22023');
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 100);
select zz_check.expect_text($$select status from nomad_sceneflow.storyboards where id = '00000000-0000-0000-0000-0000000070a1'$$, 'ready');
-- 재현 B: 출력물 ready(전달 표시) → 완료 → 이후 잡이 실패해도 환불 없음
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select * from nomad_sceneflow.start_cut_render('00000000-0000-0000-0000-0000000070a1', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000090a2', 5);
select count(*) from nomad_core.claim_jobs('sceneflow.orchestrate', 'w1', 1, null, 'sceneflow');
insert into nomad_sceneflow.outputs (organization_id, kind, storyboard_cut_id, language, status, width, height, fps)
values ('00000000-0000-0000-0000-00000000000a', 'short', (select v::uuid from zz_check.vals where k = 'cut1'), 'KO', 'ready', 720, 1280, 30);
select nomad_sceneflow.finish_cut_render((select v::uuid from zz_check.vals where k = 'cut1'));
select nomad_core.fail_job(c.job_id, 'w1', 1, 'late error', false) from nomad_sceneflow.storyboard_cuts c where c.id = (select v::uuid from zz_check.vals where k = 'cut1');
select zz_check.fails_with($$select nomad_sceneflow.fail_cut_render((select v::uuid from zz_check.vals where k = 'cut1'), 'late')$$, '22023');
reset role;
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 95);
select zz_check.expect_text($$select c.status || '/' || j.status || '/' || j.refund_on_failure::text || '/' || b.status from nomad_sceneflow.storyboard_cuts c join nomad_core.jobs j on j.id = c.job_id join nomad_sceneflow.storyboards b on b.id = c.storyboard_id where c.id = (select v::uuid from zz_check.vals where k = 'cut1')$$,
  'ready/failed/false/rendered');
-- 멤버는 컷·출력물을 읽고(B 는 못 본다), 서버 컬럼은 못 바꾼다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboard_cuts', 1);
select zz_check.denied($$update nomad_sceneflow.storyboard_cuts set status = 'failed'$$);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboard_cuts', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboard_snapshots', 0);
select zz_check.expect('select count(*) from nomad_sceneflow.outputs', 0);
reset role;

-- ==== 6. 소프트 삭제 시각은 서버 now() (owner) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
update nomad_sceneflow.music_library set deleted_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000080a1';
select zz_check.expect($$select count(*) from nomad_sceneflow.music_library where deleted_at >= now() - interval '1 minute'$$, 1);
update nomad_sceneflow.music_library set deleted_at = null where id = '00000000-0000-0000-0000-0000000080a1';
reset role;

-- ==== 7. 잠김 회귀: A 구독이 끊기면(C) 유료 기능의 신규·기존 행 경로가 잠기고, 무료 기능·읽기는 남는다 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'sceneflow';
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_sceneflow.get_public_landing('a-landing')::text$$, null);   -- 게시된 랜딩도 not found
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_sceneflow.storyboards', 1);   -- 읽기는 남는다(무료 studio)
select zz_check.expect($$with u as (update nomad_sceneflow.storyboards set title = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (update nomad_sceneflow.music_library set title = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (update nomad_sceneflow.landing_pages set headline = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with u as (update nomad_sceneflow.clients set notes = 'x' returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$select nomad_sceneflow.save_scene((select id from nomad_sceneflow.scenes where ord = 1), 1, '{"on_screen_text":"x"}')$$, 'VD009');
select zz_check.fails_with($$select nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030a1', 'published')$$, 'VD009');
select zz_check.fails_with($$select nomad_sceneflow.set_client_status((select id from nomad_sceneflow.clients limit 1), 'paused')$$, 'VD009');
select zz_check.fails_with($$insert into nomad_sceneflow.storyboards (organization_id, title, format, aspect, target_seconds, template_code) values ('00000000-0000-0000-0000-00000000000a', 'x', 'shorts', '9:16', 30, 'list_topn')$$, 'VD009');   -- 구독 끊김: 멤버에게는 플랜 잠금
select zz_check.expect_text($$select (nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030a1', 'unpublished')).status$$, 'unpublished');   -- 내리기는 허용
insert into nomad_sceneflow.workflows (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'A 흐름');   -- 무료 기능
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
-- 기존 유료 플랫폼 업로드(approved)를 예약으로 넘기는 경로 차단(VD004), 렌더·결과 반영 차단(VD009), 유료 채널 재활성 차단
select zz_check.fails_with($$update nomad_sceneflow.uploads set status = 'scheduled' where id = '00000000-0000-0000-0000-0000000060a1'$$, 'VD004');
select zz_check.fails_with($$select * from nomad_sceneflow.start_cut_render('00000000-0000-0000-0000-0000000070a1', '00000000-0000-0000-0000-0000000000a3', gen_random_uuid(), 5)$$, 'VD009');
update nomad_sceneflow.channels set status = 'paused' where id = '00000000-0000-0000-0000-0000000010a2';
select zz_check.fails_with($$update nomad_sceneflow.channels set status = 'active' where id = '00000000-0000-0000-0000-0000000010a2'$$, 'VD004');
reset role;
-- 다시 구독하면 풀린다
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'sceneflow';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_sceneflow.set_landing_status('00000000-0000-0000-0000-0000000030a1', 'published');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_sceneflow.get_public_landing('a-landing') -> 'primary' ->> 'short_code'$$, 'zzcheckaa1');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
update nomad_sceneflow.uploads set status = 'scheduled' where id = '00000000-0000-0000-0000-0000000060a1';
reset role;

-- ==== 8. 반환 컬럼 회귀: authenticated 가 실행하는 DEFINER 함수가 표 행을 돌려주면, 그 표의 모든 컬럼을 authenticated 가 select 할 수 있어야 한다 ====
select zz_check.expect($$
  select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  join pg_type t on t.oid = p.prorettype join pg_class c on c.oid = t.typrelid
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = 'nomad_sceneflow' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute')
    and not has_column_privilege('authenticated', c.oid, a.attnum, 'select')$$, 0);
-- 반환 행이 있는 사용자 RPC 가 실제로 있는지(검사가 빈 집합이 아님)
select zz_check.expect($$
  select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_type t on t.oid = p.prorettype
  where n.nspname = 'nomad_sceneflow' and p.prosecdef and t.typrelid <> 0 and has_function_privilege('authenticated', p.oid, 'execute')$$, 16);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.denied('select token_hash from nomad_sceneflow.client_reviews');
reset role;

-- ==== 9. 모든 표 RLS · anon 표 grant 없음 · anon 실행 함수는 공개 RPC 2개 · 비노출 스키마는 API 역할에 usage 없음 ====
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname in ('nomad_sceneflow', 'nomad_sceneflow_private') and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_sceneflow' and c.relkind = 'r'$$, 36);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_sceneflow' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_sceneflow' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('nomad_sceneflow', 'nomad_sceneflow_private') and has_function_privilege('anon', p.oid, 'execute')$$, 2);
select zz_check.expect($$select count(*) from (values ('anon'), ('authenticated')) r(x) where has_schema_privilege(r.x, 'nomad_sceneflow_private', 'usage')$$, 0);

-- ==== 10. 0002: AI 라우팅 시드 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'sceneflow'$$, 17);

-- ==== 11. 보안 리뷰 반영: 비멤버에게 남의 조직 플랜·부모 상태 비노출 · 사용자 경로 컬럼 조직 접두 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.fails_with($$insert into nomad_sceneflow.edit_presets (organization_id, name, settings) values ('00000000-0000-0000-0000-00000000000a', 'x', '{}')$$, 'not a member of this organization');
select zz_check.fails_with($$insert into nomad_sceneflow.longform_sections (organization_id, longform_id, position, heading) values ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 1, 'x')$$, 'not a member of this organization');
select zz_check.fails_with($$insert into nomad_sceneflow.playlist_items (organization_id, playlist_id, position, library_track_id) values ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 1, '00000000-0000-0000-0000-0000000080a1')$$, 'not a member of this organization');
reset role;
-- 경로 첫 폴더 = 자기 조직, <조직>/sceneflow/<표>/<uuid>.<확장자> 형식만
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$update nomad_sceneflow.music_library set license_proof_path = '00000000-0000-0000-0000-00000000000b/sceneflow/music_library/00000000-0000-0000-0000-0000000081a1.pdf' where id = '00000000-0000-0000-0000-0000000080a1'$$, 'music_library_license_proof_path_check');
select zz_check.fails_with($$update nomad_sceneflow.music_library set audio_path = '00000000-0000-0000-0000-00000000000a/sceneflow/music_library/../x.mp3' where id = '00000000-0000-0000-0000-0000000080a1'$$, 'music_library_audio_path_check');
select zz_check.fails_with($$update nomad_sceneflow.linkinbio_profiles set avatar_path = '00000000-0000-0000-0000-00000000000a/sceneflow/linkinbio/00000000-0000-0000-0000-0000000081a3.png' where handle = 'b_handle'$$, 'linkinbio_avatar_path_check');
select zz_check.fails_with($$update nomad_sceneflow.clients set brand_guide_path = '00000000-0000-0000-0000-00000000000b/sceneflow/clients/00000000-0000-0000-0000-0000000081a4.pdf' where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 'clients_brand_guide_path_check');
select zz_check.expect($$with u as (update nomad_sceneflow.linkinbio_profiles set avatar_path = '00000000-0000-0000-0000-00000000000b/sceneflow/linkinbio/00000000-0000-0000-0000-0000000081a3.png' where handle = 'b_handle' returning 1) select count(*) from u$$, 1);
reset role;
