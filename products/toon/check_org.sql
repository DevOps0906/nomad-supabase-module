-- Toon org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · 카탈로그 컬럼 숨김 · 플랜 한도 · 기능 잠금(구독 끊김 회귀) · 내보내기 보정 · 협찬 · AI 시드(0002).
-- 합성 데이터만, 마지막에 rollback. 실행: bash products/toon/run_check.sh

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

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer, 플랜 A 구독), 조직 B(u2 owner, 구독 없음 = C) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'toon', 'A', 'active');
-- 수치 시드는 저장소에 없다. 검사용으로만 A 의 작품 한도를 넓힌다(rollback 으로 사라짐). B(C)는 기본값 1.
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('toon', 'A', 'max_series', 20);

-- ==== 0. 서버: 카탈로그 등록 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_toon.asset_packs (id, code, name, license_source, license_ref, status, license_verified_at, license_verified_by)
values ('00000000-0000-0000-0000-0000000000f1', 'basic', 'Basic', 'in_house', 'IN-001', 'published', now(), '00000000-0000-0000-0000-0000000000a1');
insert into nomad_toon.characters (id, pack_id, code, name, status)
values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1', 'hero', 'Hero', 'published');
insert into nomad_toon.assets (id, pack_id, kind, code, name, tier, storage_path, preview_path, mime, status) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000f1', 'background', 'room', 'Room', 'free', 'orig/room.png', 'prev/room.webp', 'image/png', 'published'),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000f1', 'background', 'castle', 'Castle', 'premium', 'orig/castle.png', 'prev/castle.webp', 'image/png', 'published'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000f1', 'prop', 'draft1', 'Draft', 'free', 'orig/d.png', 'prev/d.webp', 'image/png', 'draft');
-- 라이선스 검증 없는 공개 금지
select zz_check.denied($$insert into nomad_toon.asset_packs (code, name, license_source, license_ref, status) values ('bad', 'Bad', 'in_house', 'IN-002', 'published')$$);
reset role;

-- ==== 1. anon: 어떤 표·함수도 안 된다(공개 RPC 없음) ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_toon.series');
select zz_check.expect($$select count(*) where has_schema_privilege('anon', 'nomad_toon', 'usage')$$, 0);
select zz_check.denied('select count(*) from nomad_toon.asset_packs');
select zz_check.denied('select count(*) from nomad_toon.catalog_assets');
select zz_check.denied($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$insert into nomad_toon.series (organization_id, title, format, canvas_width, canvas_height) values ('00000000-0000-0000-0000-00000000000a', 'x', 'webtoon', 800, 1280)$$);
reset role;

-- ==== 2. 카탈로그 읽기: 공개 행만, 원본 경로 컬럼 숨김 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_toon.assets', 2);
select zz_check.expect('select count(*) from nomad_toon.catalog_assets', 2);
select zz_check.denied('select storage_path from nomad_toon.assets');
select zz_check.denied('select editor_path from nomad_toon.assets');
select zz_check.denied($$insert into nomad_toon.characters (pack_id, code, name) values ('00000000-0000-0000-0000-0000000000f1', 'x', 'X')$$);

-- ==== 3. 조직 A owner: 작품 만들기, B 에는 못 쓴다 ====
insert into nomad_toon.series (id, organization_id, title, format, canvas_width, canvas_height)
values ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-00000000000a', 'A 작품', 'webtoon', 800, 1280);
insert into nomad_toon.series (id, organization_id, title, format, canvas_width, canvas_height)
values ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-00000000000a', 'A 인스타툰', 'instatoon', 1080, 1350);
select zz_check.denied($$insert into nomad_toon.series (organization_id, title, format, canvas_width, canvas_height) values ('00000000-0000-0000-0000-00000000000b', 'x', 'webtoon', 800, 1280)$$);
select zz_check.expect_text($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000a') ->> 'plan_code'$$, 'A');
select zz_check.expect_text($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000a') ->> 'watermark'$$, 'false');
select zz_check.denied($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000b')$$);
reset role;

-- ==== 4. 조직 B owner(구독 없음 = C 무료 기능) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_toon.series', 0);               -- A 작품 안 보임
insert into nomad_toon.series (id, organization_id, title, format, canvas_width, canvas_height)
values ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-00000000000b', 'B 작품', 'webtoon', 800, 1280);
select zz_check.fails_with($$insert into nomad_toon.series (organization_id, title, format, canvas_width, canvas_height) values ('00000000-0000-0000-0000-00000000000b', 'B2', 'webtoon', 800, 1280)$$, 'TN001');
-- 다른 조직 작품에 회차 붙이기(복합 FK) 거부
select zz_check.denied($$insert into nomad_toon.episodes (organization_id, series_id, number) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000005a1', 1)$$);
select zz_check.expect($$with u as (update nomad_toon.series set title = 'hack' where id = '00000000-0000-0000-0000-0000000005a1' returning 1) select count(*) from u$$, 0);
-- 협찬은 pro 기능(C 잠김)
select zz_check.fails_with($$insert into nomad_toon.sponsorships (organization_id, series_id, advertiser_name, compensation_kind) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000005b1', '광고주', 'paid')$$, 'TN002');
select zz_check.expect_text($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000b') ->> 'watermark'$$, 'true');
select zz_check.expect_text($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000b') ->> 'export'$$, '["png"]');
-- 에셋 등급: B 는 free 만, A 조직 조회는 거부
select zz_check.expect($$select count(*) from nomad_toon.org_asset_access('00000000-0000-0000-0000-00000000000b', array['00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000e2']::uuid[]) where allowed$$, 1);
select zz_check.denied($$select * from nomad_toon.org_asset_access('00000000-0000-0000-0000-00000000000a', array['00000000-0000-0000-0000-0000000000e2']::uuid[])$$);
select zz_check.denied($$select nomad_toon.monthly_export_count('00000000-0000-0000-0000-00000000000a')$$);
reset role;

-- ==== 5. 조직 A editor: 회차·컷·문서 저장·순서 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
insert into nomad_toon.episodes (id, organization_id, series_id, number, title)
values ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a1', 1, '1화');
insert into nomad_toon.cuts (id, organization_id, episode_id, position, width, height, revision) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', 0, 800, 1280, 99),
  ('00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', 1, 800, 1280, 1);
select zz_check.expect($$select revision from nomad_toon.cuts where id = '00000000-0000-0000-0000-0000000007a1'$$, 1);  -- 사용자 값 무시
select zz_check.expect($$select nomad_toon.save_cut_doc('00000000-0000-0000-0000-0000000007a1', '{"v":1,"layers":[]}'::jsonb || '{"background":{}}', 1)$$, 2);
select zz_check.fails_with($$select nomad_toon.save_cut_doc('00000000-0000-0000-0000-0000000007a1', '{"v":1,"layers":[]}', 1)$$, 'TN409');
select nomad_toon.reorder_cuts('00000000-0000-0000-0000-0000000006a1', array['00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-0000000007a1']::uuid[]);
select zz_check.expect($$select position from nomad_toon.cuts where id = '00000000-0000-0000-0000-0000000007a1'$$, 1);
select zz_check.fails_with($$select nomad_toon.reorder_cuts('00000000-0000-0000-0000-0000000006a1', array['00000000-0000-0000-0000-0000000007a2']::uuid[])$$, '22023');
-- editor 는 삭제 불가(owner/admin), 행이 남는다
select zz_check.expect($$with d as (delete from nomad_toon.cuts where id = '00000000-0000-0000-0000-0000000007a2' returning 1) select count(*) from d$$, 0);
-- 협찬(A 플랜): 만들기 → 검토 요청, editor 결정 불가
insert into nomad_toon.sponsorships (id, organization_id, series_id, advertiser_name, compensation_kind, status, decided_at, decided_by)
values ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a1', '광고주', 'paid', 'draft', now(), '00000000-0000-0000-0000-0000000000a3');
select zz_check.expect($$select count(*) from nomad_toon.sponsorships where decided_at is null$$, 1);
select zz_check.fails_with($$update nomad_toon.sponsorships set status = 'approved' where id = '00000000-0000-0000-0000-0000000008a1'$$, '42501');
update nomad_toon.sponsorships set status = 'in_review' where id = '00000000-0000-0000-0000-0000000008a1';
select zz_check.fails_with($$select nomad_toon.decide_sponsorship('00000000-0000-0000-0000-0000000008a1', 'approved')$$, '42501');
-- 협찬 연결은 owner/admin 만
select zz_check.fails_with($$update nomad_toon.episodes set sponsorship_id = '00000000-0000-0000-0000-0000000008a1' where id = '00000000-0000-0000-0000-0000000006a1'$$, '42501');
-- 다른 작품으로 옮기기도 한도를 센다(기본 회차 3)
insert into nomad_toon.episodes (organization_id, series_id, number) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a2', 11),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a2', 12),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a2', 13);
select zz_check.fails_with($$update nomad_toon.episodes set series_id = '00000000-0000-0000-0000-0000000005a2' where id = '00000000-0000-0000-0000-0000000006a1'$$, 'TN001');
select zz_check.fails_with($$insert into nomad_toon.episodes (organization_id, series_id, number) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a2', 14)$$, 'TN001');
-- 컷을 다른 회차로 옮기기(인스타툰 회차 11 에 컷 10개 채운 뒤) 거부
insert into nomad_toon.cuts (organization_id, episode_id, position, width, height)
select '00000000-0000-0000-0000-00000000000a', e.id, g, 1080, 1350 from nomad_toon.episodes e, generate_series(0, 9) g where e.number = 11;
select zz_check.fails_with($$update nomad_toon.cuts set episode_id = (select id from nomad_toon.episodes where number = 11), position = 50 where id = '00000000-0000-0000-0000-0000000007a2'$$, 'TN001');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
update nomad_toon.episodes set sponsorship_id = '00000000-0000-0000-0000-0000000008a1' where id = '00000000-0000-0000-0000-0000000006a1';
reset role;

-- ==== 6. 조직 A viewer: 읽기만 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_toon.cuts', 12);
select zz_check.denied($$insert into nomad_toon.episodes (organization_id, series_id, number) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a1', 2)$$);
select zz_check.expect($$with u as (update nomad_toon.cuts set duration_ms = 3000 returning 1) select count(*) from u$$, 0);
select zz_check.denied($$insert into nomad_toon.exports (organization_id, kind, request_id) values ('00000000-0000-0000-0000-00000000000a', 'png', gen_random_uuid())$$);
reset role;

-- ==== 7. 서버: 내보내기 보정 · 협찬 승인 전 금지 · 종류 잠금 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
-- 협찬 회차: 승인 전 최종 내보내기 금지, 검토 시안은 워터마크 강제
select zz_check.fails_with($$insert into nomad_toon.exports (organization_id, episode_id, kind, request_id, watermark) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', 'png', gen_random_uuid(), false)$$, 'TN008');
insert into nomad_toon.exports (id, organization_id, episode_id, kind, request_id, watermark, options)
values ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', 'png', gen_random_uuid(), false, '{"purpose":"review"}');
select zz_check.expect_text($$select watermark::text || '/' || disclosure_text from nomad_toon.exports where id = '00000000-0000-0000-0000-0000000009a1'$$, 'true/광고');
-- A 는 mp4 가능·워터마크 끔 가능
insert into nomad_toon.exports (id, organization_id, kind, request_id, watermark)
values ('00000000-0000-0000-0000-0000000009a2', '00000000-0000-0000-0000-00000000000a', 'mp4', gen_random_uuid(), false);
select zz_check.expect_text($$select plan_code || '/' || watermark::text from nomad_toon.exports where id = '00000000-0000-0000-0000-0000000009a2'$$, 'A/false');
-- B(C): mp4 잠김, png 는 워터마크 강제
select zz_check.fails_with($$insert into nomad_toon.exports (organization_id, kind, request_id) values ('00000000-0000-0000-0000-00000000000b', 'mp4', gen_random_uuid())$$, 'TN004');
insert into nomad_toon.exports (id, organization_id, kind, request_id, watermark)
values ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-00000000000b', 'png', gen_random_uuid(), false);
select zz_check.expect_text($$select plan_code || '/' || watermark::text from nomad_toon.exports where id = '00000000-0000-0000-0000-0000000009b1'$$, 'C/true');
-- 판정 값 불변(서버 포함): 워터마크·종류·플랜·대가성 문구
select zz_check.fails_with($$update nomad_toon.exports set watermark = false where id = '00000000-0000-0000-0000-0000000009b1'$$, 'immutable');
select zz_check.fails_with($$update nomad_toon.exports set kind = 'mp4' where id = '00000000-0000-0000-0000-0000000009b1'$$, 'immutable');
select zz_check.fails_with($$update nomad_toon.exports set plan_code = 'A' where id = '00000000-0000-0000-0000-0000000009b1'$$, 'immutable');
select zz_check.fails_with($$update nomad_toon.exports set disclosure_text = null, sponsorship_id = null where id = '00000000-0000-0000-0000-0000000009a1'$$, 'immutable');
update nomad_toon.exports set status = 'running' where id = '00000000-0000-0000-0000-0000000009a2';   -- 진행 상태는 갱신 가능
-- 다른 조직 회차로 내보내기 거부
select zz_check.fails_with($$insert into nomad_toon.exports (organization_id, episode_id, kind, request_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000006a1', 'png', gen_random_uuid())$$, '22023');
-- 상태 전이
select zz_check.fails_with($$update nomad_toon.exports set status = 'succeeded' where id = '00000000-0000-0000-0000-0000000009b1'$$, '22023');
-- 생성물 기록(서버)
insert into nomad_toon.user_assets (id, organization_id, kind, source, ai_generated, model, storage_path, preview_path, width, height)
values ('00000000-0000-0000-0000-00000000aaa1', '00000000-0000-0000-0000-00000000000a', 'background', 'ai_generated', true, 'flux', '00000000-0000-0000-0000-00000000000a/toon/user_assets/x.png', 'p.webp', 1024, 1024);
select zz_check.denied($$insert into nomad_toon.user_assets (organization_id, kind, source, ai_generated, storage_path, preview_path, width, height) values ('00000000-0000-0000-0000-00000000000a', 'background', 'upload', true, 'x', 'p', 1, 1)$$);
reset role;

-- ==== 8. owner: 협찬 승인 → 최종 내보내기 가능 · 감사 기록 · 에셋 보관 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_toon.decide_sponsorship('00000000-0000-0000-0000-0000000008a1', 'approved', 'ok');
select zz_check.expect($$select count(*) from nomad_toon.sponsorships where status = 'approved' and decided_by = '00000000-0000-0000-0000-0000000000a1'$$, 1);
select zz_check.expect($$select nomad_toon.monthly_export_count('00000000-0000-0000-0000-00000000000a')$$, 1);
select zz_check.expect($$select count(*) from nomad_toon.org_asset_access('00000000-0000-0000-0000-00000000000a', array['00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000e2','00000000-0000-0000-0000-0000000000e3']::uuid[]) where allowed$$, 2);
select zz_check.expect('select count(*) from nomad_toon.user_assets', 1);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_toon.archive_user_asset('00000000-0000-0000-0000-00000000aaa1')$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_toon.archive_user_asset('00000000-0000-0000-0000-00000000aaa1')$$, 'P0002');
select zz_check.fails_with($$select nomad_toon.decide_sponsorship('00000000-0000-0000-0000-0000000008a1', 'approved')$$, 'P0002');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select nomad_toon.archive_user_asset('00000000-0000-0000-0000-00000000aaa1');
select zz_check.expect('select count(*) from nomad_toon.user_assets', 0);
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000a' and action in ('toon.sponsorship.approved', 'toon.user_asset.archive')$$, 2);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_toon.exports (organization_id, episode_id, kind, request_id)
values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', 'png', gen_random_uuid());
reset role;

-- ==== 9. 잠김 회귀: A 구독이 끊기면 C(무료 기능)만 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'toon';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_toon.series', 2);                -- 무료 기능(작품 열람)은 남는다
select zz_check.fails_with($$insert into nomad_toon.sponsorships (organization_id, series_id, advertiser_name, compensation_kind) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000005a1', '광고주2', 'paid')$$, 'TN002');
select zz_check.fails_with($$insert into nomad_toon.series (organization_id, title, format, canvas_width, canvas_height) values ('00000000-0000-0000-0000-00000000000a', 'A3', 'webtoon', 800, 1280)$$, 'TN001');
select zz_check.expect_text($$select nomad_toon.plan_features('00000000-0000-0000-0000-00000000000a') ->> 'plan_code'$$, 'C');
select zz_check.expect($$select count(*) from nomad_toon.org_asset_access('00000000-0000-0000-0000-00000000000a', array['00000000-0000-0000-0000-0000000000e2']::uuid[]) where allowed$$, 0);
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$insert into nomad_toon.exports (organization_id, kind, request_id) values ('00000000-0000-0000-0000-00000000000a', 'mp4', gen_random_uuid())$$, 'TN004');
reset role;

-- ==== 10. 0002: AI 기능·라우팅 시드 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'toon'$$, 14);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'toon' and plan_code = 'C' and feature_code = 'video_voice'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'toon' and plan_code = 'C' and feature_code = 'ai_chat'$$, 1);

-- ==== 11. 모든 표 RLS · anon 직접 grant 없음 ====
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_toon' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_toon' and grantee = 'anon'$$, 0);
