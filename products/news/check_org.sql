-- news org안 검사(메모 news-port-notes.md 4장 필수 검사 전부 + 흐름 회귀). 합성 데이터만, 마지막에 rollback.
--   1 다른 조직 독자·편집국 접근 0 · 2 anon 표 접근 0(모든 표) · 3 사용자 표 쓰기 grant 0 · 4 구독 끊김 후 공개분 열람 유지·새 발행 잠금
--   · 5 가맹 키 설정 owner·admin 만(editor 거부) · 6 공개 RPC 가 비공개 컬럼(잠긴 본문 등)을 내지 않음
-- 실행: bash products/news/run_check.sh

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
grant select on zz_check.vals to anon;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터 ----
-- 조직 A(u1 owner·발행인, 플랜 B 구독), 조직 B(u2 owner·발행인, 플랜 A 구독). u3·u5 는 A 편집국으로 초대(기자·편집인),
-- u4 는 A 독자(조직 멤버 아님), u6 는 어디에도 없는 사용자(새 독자 가입 잠금 확인용)
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test', now()), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test', now()), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test', now()),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test', now()), ('00000000-0000-0000-0000-0000000000a6', 'u6@example.test', now());
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', '알파신문', 'team'), ('00000000-0000-0000-0000-00000000000b', '베타신문', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'news', 'B', 'active'), ('00000000-0000-0000-0000-00000000000b', 'news', 'A', 'active');
-- 한도는 저장소 시드가 아니라 검사용(rollback). B 조직(플랜 A)은 키가 없어 0 = 초대 불가(fail-closed)
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('news', 'B', 'news_staff_max', 5);

-- ==== 0. 개설(N2): owner 가 신청 → 서버 승인. 남의 조직·개인 조직으로 신청 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'appA', (nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000a', 'alpha-news', '알파신문', 'internet', '서울 아00001',
  date '2020-01-01', '발행인A', 'a@example.test', '02-000-0000', '00000000-0000-0000-0000-00000000000a/news/applications/cert.pdf')).id::text;
select zz_check.fails_with($$select nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000b', 'gamma-news', 'x', 'internet', 'r1', date '2020-01-01', 'p', 'a@example.test', '02-000-0000', '00000000-0000-0000-0000-00000000000b/news/applications/c.pdf')$$, '42501');
select zz_check.fails_with($$select nomad_news.request_newspaper((select organization_id from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id where m.user_id = '00000000-0000-0000-0000-0000000000a1' and o.kind = 'personal' limit 1), 'delta-news', 'x', 'internet', 'r1', date '2020-01-01', 'p', 'a@example.test', '02-000-0000', 'x')$$, '42501');
-- 신청자는 자기 신청만 본다
select zz_check.expect('select count(*) from nomad_news.newspaper_applications', 1);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000b', 'alpha-news', '베타', 'internet', 'r1', date '2020-01-01', 'p', 'b@example.test', '02-000-0000', '00000000-0000-0000-0000-00000000000b/news/applications/c.pdf')$$, 'NW001');
insert into zz_check.vals select 'appB', (nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000b', 'beta-news', '베타신문', 'weekly', '서울 다00002',
  date '2021-01-01', '발행인B', 'b@example.test', '02-111-1111', '00000000-0000-0000-0000-00000000000b/news/applications/cert.pdf')).id::text;
select zz_check.expect('select count(*) from nomad_news.newspaper_applications', 1);
select zz_check.denied($$select nomad_news.approve_newspaper((select v::uuid from zz_check.vals where k = 'appB'))$$);
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_news.approve_newspaper((select v::uuid from zz_check.vals where k = 'appA'));
select nomad_news.approve_newspaper((select v::uuid from zz_check.vals where k = 'appB'));
reset role;
-- core 표는 이식 함수가 쓰지 않는다: 조직·멤버십·구독 수 그대로
select zz_check.expect($$select count(*) from nomad_core.memberships where organization_id in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b')$$, 2);
select zz_check.expect($$select count(*) from nomad_news.staff where role = 'publisher' and status = 'active'$$, 2);

-- ==== 1. 매체정보 완성(발행인) · 편집국 초대(core 초대 + staff_invitations) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_news.set_newspaper_profile('00000000-0000-0000-0000-00000000000a', '{"legal_name":"(주)알파","editor_name":"편집인A","youth_officer_name":"청소년A",
  "publish_address":"서울시 중구 1","phone":"02-000-0000","first_published_on":"2020-02-01","comments_enabled":true,"banned_words":["금칙"]}');
insert into zz_check.vals select 'tok3', nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u3@example.test', 'reporter', '기자3') ->> 'token';
insert into zz_check.vals select 'tok5', nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u5@example.test', 'editor', '편집인5') ->> 'token';
select zz_check.fails_with($$select nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'x@example.test', 'publisher', 'x')$$, 'NW015');
select zz_check.expect('select count(*) from nomad_news.staff_invitations', 2);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select nomad_news.set_newspaper_profile('00000000-0000-0000-0000-00000000000b', '{"legal_name":"(주)베타","editor_name":"편집인B","youth_officer_name":"청소년B",
  "publish_address":"부산시 중구 2","phone":"051-000-0000","first_published_on":"2021-02-01"}');
-- 수치 한도 시드 없음 → 키 없음 = 0 → 초대 불가(fail-closed)
select zz_check.fails_with($$select nomad_news.invite_staff('00000000-0000-0000-0000-00000000000b', 'u6@example.test', 'reporter', 'x')$$, 'NW014');
-- 남의 조직 초대 목록·초대 거부
select zz_check.expect('select count(*) from nomad_news.staff_invitations', 0);
select zz_check.fails_with($$select nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u6@example.test', 'reporter', 'x')$$, '42501');
-- 수락: 이메일이 다른 토큰 거부(core accept_invitation), 자기 토큰은 staff 행
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok5'))$$, 'email mismatch');
select zz_check.expect_text($$select (nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok3'))).role$$, 'reporter');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect_text($$select (nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok5'))).role$$, 'editor');
-- N3: 도메인 역할은 core editor(admin 아님). 편집인(core editor)은 초대 불가(발행인만)
select zz_check.expect_text($$select nomad_core.organization_role('00000000-0000-0000-0000-00000000000a')$$, 'editor');
select zz_check.fails_with($$select nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u6@example.test', 'reporter', 'x')$$, '42501');
reset role;

-- ==== 2. 기사 워크플로: 기자 작성·제출 → 편집인 승인·게시(일반·프리미엄·예약용) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
insert into zz_check.vals select 'art1', (nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null,
  '{"slug":"open-1","title":"공개 기사","summary":"요약","body":[{"t":"p","v":"공개 본문"}],"body_text":"공개 본문"}')).id::text;
insert into zz_check.vals select 'art2', (nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null,
  '{"slug":"premium-1","title":"프리미엄 기사","body":[{"t":"p","v":"유료 본문"}],"body_text":"유료 본문","is_premium":true}')).id::text;
insert into zz_check.vals select 'art3', (nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null,
  '{"slug":"later-1","title":"나중 기사","body":[]}')).id::text;
insert into zz_check.vals select 'art4', (nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null,
  '{"slug":"sched-1","title":"예약 기사","body":[]}')).id::text;
select nomad_news.submit_article(v::uuid) from zz_check.vals where k in ('art1', 'art2', 'art3', 'art4');
-- 기자는 승인 불가
select zz_check.fails_with($$select nomad_news.review_article((select v::uuid from zz_check.vals where k = 'art1'), 'approve')$$, '42501');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select nomad_news.review_article(v::uuid, 'approve') from zz_check.vals where k in ('art1', 'art2', 'art3', 'art4');
select nomad_news.publish_article(v::uuid) from zz_check.vals where k in ('art1', 'art2');
select nomad_news.schedule_article((select v::uuid from zz_check.vals where k = 'art4'), now() + interval '1 hour');
select nomad_news.save_public_notice('00000000-0000-0000-0000-00000000000a', null,
  '{"issuer_name":"알파시청","title":"공고 1","body":"공고 본문","government_ad_ref":"GA-1","status":"published"}');
reset role;
-- 지면 PDF 는 A 플랜 기능(print_pdf): 조직 A(플랜 B) 발행인 거부
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.save_print_edition('00000000-0000-0000-0000-00000000000a', null, '{"edition_date":"2026-11-15","pdf_path":"00000000-0000-0000-0000-00000000000a/news/print/p1.pdf"}')$$, 'NW014');
reset role;
-- 조직 B: 기사 1건 게시(서버 경로는 예약만이라 발행인이 직접)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
insert into zz_check.vals select 'artB', (nomad_news.save_article('00000000-0000-0000-0000-00000000000b', null, '{"slug":"beta-1","title":"베타 기사","body":[]}')).id::text;
select nomad_news.submit_article((select v::uuid from zz_check.vals where k = 'artB'));
select nomad_news.review_article((select v::uuid from zz_check.vals where k = 'artB'), 'approve');
select nomad_news.publish_article((select v::uuid from zz_check.vals where k = 'artB'));
reset role;

-- ==== 3. 독자(u4): 가입·댓글. 프리미엄 본문은 잠김 → 멤버십 기록 후 열림 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect_text($$select (nomad_news.ensure_reader('00000000-0000-0000-0000-00000000000a', '독자넷', 'v1', 'v1', true)).email$$, 'u4@example.test');
select nomad_news.post_comment((select v::uuid from zz_check.vals where k = 'art1'), '좋은 기사');
select zz_check.fails_with($$select nomad_news.post_comment((select v::uuid from zz_check.vals where k = 'art1'), '금칙 포함')$$, 'NW010');
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') ->> 'locked'$$, 'true');
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') ->> 'body'$$, null);
-- 독자는 조직 멤버가 아니다: 편집국 표 0, 자기 독자 행 1
select zz_check.expect('select count(*) from nomad_news.articles', 0);
select zz_check.expect('select count(*) from nomad_news.readers', 1);
select zz_check.expect('select count(*) from nomad_news.staff', 0);
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_news.membership_tiers (id, organization_id, code, name, price_krw) values
  ('00000000-0000-0000-0000-0000000090a1', '00000000-0000-0000-0000-00000000000a', 'basic', '기본', 5000);
select nomad_news.record_membership('00000000-0000-0000-0000-00000000000a', (select id from nomad_news.readers where user_id = '00000000-0000-0000-0000-0000000000a4'),
  '00000000-0000-0000-0000-0000000090a1', 'active', now(), now() + interval '30 days', 'ord-1', 'evt-1');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') -> 'body' -> 0 ->> 'v'$$, '유료 본문');
reset role;

insert into zz_check.vals select 'rdr4', id::text from nomad_news.readers where user_id = '00000000-0000-0000-0000-0000000000a4';
insert into zz_check.vals select 'cmt1', id::text from nomad_news.comments limit 1;

-- ==== 4. [필수 1] 다른 조직 독자·편집국 접근 0 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect($$select count(*) from nomad_news.articles where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_news.readers where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_news.staff where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_news.memberships where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_news.comments where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_news.newspapers where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect($$select count(*) from nomad_news.public_notices where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 0);
select zz_check.expect('select count(*) from nomad_news.articles', 1);
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"title":"x"}')$$, '42501');
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'art1'), '{"title":"x"}')$$, '42501');
-- W7: 남의 조직 행 id 로 부르면 존재를 드러내지 않게 P0002(권한 없음과 없음 구분 불가)
select zz_check.fails_with($$select nomad_news.unpublish_article((select v::uuid from zz_check.vals where k = 'art1'), 'x')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.set_reader_status((select v::uuid from zz_check.vals where k = 'rdr4'), 'blocked')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.moderate_comment((select v::uuid from zz_check.vals where k = 'cmt1'), 'hide')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.record_article_correction((select v::uuid from zz_check.vals where k = 'art1'), 'correction', '남의 기사 정정 시도')$$, 'P0002');
reset role;
-- 같은 조직 안에서도 독자 email 은 발행인·편집인만(기자 0)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_news.readers', 0);
select zz_check.expect('select count(*) from nomad_news.staff_invitations', 0);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect_text('select email from nomad_news.readers', 'u4@example.test');
-- 토큰 해시 컬럼은 발행인에게도 없다
select zz_check.denied('select unsubscribe_token_hash from nomad_news.newsletter_subscriptions');
reset role;

-- ==== 5. [필수 2·6] anon: 표 접근 0, 공개 RPC 는 공개 컬럼만 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_news.articles');
select zz_check.denied('select count(*) from nomad_news.newspapers');
select zz_check.denied('select id from nomad_news.sections');
select zz_check.denied($$select nomad_news.is_public_newspaper('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select nomad_news.ensure_reader('00000000-0000-0000-0000-00000000000a', 'x', 'v1', 'v1', true)$$);
select zz_check.expect_text($$select nomad_news.get_public_newspaper('alpha-news') ->> 'title'$$, '알파신문');
select zz_check.expect_text($$select nomad_news.get_public_newspaper('no-such')::text$$, null);
select zz_check.expect($$select count(*) from jsonb_object_keys(nomad_news.get_public_newspaper('alpha-news')) k where k in ('banned_words', 'status_reason', 'created_by', 'application_id', 'profile_completed_at')$$, 0);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_articles('00000000-0000-0000-0000-00000000000a'))$$, 2);
select zz_check.expect($$select count(*) from jsonb_array_elements(nomad_news.list_public_articles('00000000-0000-0000-0000-00000000000a')) e, jsonb_object_keys(e) k
  where k in ('body', 'body_text', 'search_tsv', 'review_note', 'created_by', 'approved_by', 'legacy_id', 'unpublish_reason', 'embargo_until')$$, 0);
-- 잠긴 프리미엄 본문은 anon 에게 null, 비공개(승인만 된) 기사는 null
select zz_check.expect_text($$select coalesce(nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') ->> 'body', 'NULL')$$, 'NULL');
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') -> 'media' ->> 0$$, null);
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'open-1') -> 'body' -> 0 ->> 'v'$$, '공개 본문');
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'later-1')::text$$, null);
select zz_check.expect($$select count(*) from jsonb_array_elements(nomad_news.list_public_items('00000000-0000-0000-0000-00000000000a', 'notices')) e, jsonb_object_keys(e) k
  where k in ('government_ad_ref', 'created_by')$$, 0);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_items('00000000-0000-0000-0000-00000000000a', 'notices'))$$, 1);
select zz_check.expect($$select count(*) from nomad_news.list_comments((select v::uuid from zz_check.vals where k = 'art1'))$$, 1);
select zz_check.fails_with($$select nomad_news.list_public_items('00000000-0000-0000-0000-00000000000a', 'readers')$$, 'NW015');
reset role;
-- 모든 표: anon 표·컬럼 grant 0, 정책 0 · RLS 전부 · anon 실행 함수는 공개 RPC 10개뿐
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_news' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_news' and grantee = 'anon'$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_news' and c.relkind in ('r', 'v') and has_table_privilege('anon', c.oid, 'select')$$, 0);
select zz_check.expect($$select count(*) from pg_policies where schemaname = 'nomad_news' and 'anon' = any (roles)$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_news' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_news' and c.relkind = 'r'$$, 42);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'nomad_news' and has_function_privilege('anon', p.oid, 'execute')$$, 10);

-- ==== 6. [필수 3] 사용자 표 쓰기 grant 0 ====
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_news' and grantee in ('authenticated', 'anon', 'PUBLIC') and privilege_type <> 'SELECT'$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_news' and grantee in ('authenticated', 'anon', 'PUBLIC') and privilege_type <> 'SELECT'$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_news' and c.relkind = 'r'
  and (has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update') or has_table_privilege('authenticated', c.oid, 'delete'))$$, 0);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$insert into nomad_news.articles (organization_id, title, byline, slug) values ('00000000-0000-0000-0000-00000000000a', 'x', 'x', 'x')$$, '42501');
select zz_check.fails_with($$update nomad_news.articles set title = 'x' where organization_id = '00000000-0000-0000-0000-00000000000a'$$, '42501');
select zz_check.fails_with($$delete from nomad_news.readers$$, '42501');
reset role;

-- ==== 7. [필수 5] 가맹 키(toss_merchant) 설정은 core owner·admin 만 — 편집국 도메인 편집인(core editor)·독자 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_core.set_provider_credential('00000000-0000-0000-0000-00000000000a', 'toss_merchant', 'default', 'test_sk_000000000000000000000000')$$, '42501');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_core.set_provider_credential('00000000-0000-0000-0000-00000000000a', 'toss_merchant', 'default', 'test_sk_000000000000000000000000')$$, '42501');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'credA', nomad_core.set_provider_credential('00000000-0000-0000-0000-00000000000a', 'toss_merchant', 'default', 'test_sk_000000000000000000000000')::text;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
insert into zz_check.vals select 'credB', nomad_core.set_provider_credential('00000000-0000-0000-0000-00000000000b', 'toss_merchant', 'default', 'test_sk_111111111111111111111111')::text;
reset role;
-- 멤버십에 붙이는 가맹 키는 같은 신문사 것만(복합 FK + 함수 검사)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_news.record_membership('00000000-0000-0000-0000-00000000000a', (select id from nomad_news.readers where user_id = '00000000-0000-0000-0000-0000000000a4'), null, null, null, null, null, 'evt-2', (select v::uuid from zz_check.vals where k = 'credB'))$$, '23503');
select nomad_news.record_membership('00000000-0000-0000-0000-00000000000a', (select id from nomad_news.readers where user_id = '00000000-0000-0000-0000-0000000000a4'),
  null, null, null, null, null, 'evt-3', (select v::uuid from zz_check.vals where k = 'credA'));
reset role;

-- ==== 8. [필수 4] 구독 끊김(N1): 공개분·기존 유료 독자 열람·편집국 읽기 유지, 새 발행·편집·새 결제·새 독자 잠금 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'news';
-- 예약 기사의 시각이 지나도 서버 예약 게시는 잠김 → approved 로 되돌림
update nomad_news.articles set scheduled_for = now() - interval '1 minute' where id = (select v::uuid from zz_check.vals where k = 'art4');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.expect_text($$select nomad_news.run_scheduled_publishing() ->> 'failed'$$, '1');
select zz_check.expect_text($$select status from nomad_news.articles where id = (select v::uuid from zz_check.vals where k = 'art4')$$, 'approved');
-- 새 결제(새 후원 주문·기간 연장) 잠금, 해지 기록은 허용
select zz_check.fails_with($$select nomad_news.record_donation('00000000-0000-0000-0000-00000000000a', 'order-zz-1', 'pending', 10000)$$, 'NW014');
select zz_check.fails_with($$select nomad_news.record_membership('00000000-0000-0000-0000-00000000000a', (select id from nomad_news.readers where user_id = '00000000-0000-0000-0000-0000000000a4'), null, 'active', null, now() + interval '60 days', null, 'evt-4')$$, 'NW014');
select zz_check.fails_with($$select nomad_news.subscribe_newsletter('00000000-0000-0000-0000-00000000000a', 'x', 'a@example.test', 'v1')$$, 'NW014');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_articles('00000000-0000-0000-0000-00000000000a'))$$, 2);
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'open-1') -> 'body' -> 0 ->> 'v'$$, '공개 본문');
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_items('00000000-0000-0000-0000-00000000000a', 'notices'))$$, 1);
select zz_check.expect_text($$select nomad_news.get_public_newspaper('alpha-news') ->> 'reader_signup_open'$$, 'false');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
-- 기존 유료 독자는 프리미엄 본문 유지, 새 댓글은 잠금
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') -> 'body' -> 0 ->> 'v'$$, '유료 본문');
select zz_check.fails_with($$select nomad_news.post_comment((select v::uuid from zz_check.vals where k = 'art1'), '새 댓글')$$, 'NW014');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a6","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.ensure_reader('00000000-0000-0000-0000-00000000000a', '새독자', 'v1', 'v1', true)$$, 'NW014');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
-- 편집국 읽기 유지, 새 발행·편집 잠금
select zz_check.expect('select count(*) from nomad_news.articles', 4);
select zz_check.fails_with($$select nomad_news.publish_article((select v::uuid from zz_check.vals where k = 'art3'))$$, 'NW014');
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'art1'), '{"seo":{}}')$$, 'NW014');
-- 법정 의무 경로는 열림: 정정문 기록
select zz_check.expect_text($$select (nomad_news.record_article_correction((select v::uuid from zz_check.vals where k = 'art1'), 'correction', '제목 오기를 바로잡습니다')).kind$$, 'correction');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"title":"새 기사"}')$$, 'NW014');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u6@example.test', 'reporter', 'x')$$, 'NW014');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect($$select jsonb_array_length(nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'open-1') -> 'corrections')$$, 1);
reset role;
-- 조직 B 는 영향 없음
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect_text($$select (nomad_news.save_article('00000000-0000-0000-0000-00000000000b', (select v::uuid from zz_check.vals where k = 'artB'), '{"seo":{"k":"v"}}')).status$$, 'published');
reset role;

-- ==== 9. 편집국 제거(본인 탈퇴·발행인) → core 멤버십도 core 함수로 제거 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.remove_staff('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3')$$, '42501');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_news.remove_staff('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3');
reset role;
select zz_check.expect($$select count(*) from nomad_core.memberships where organization_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a3'$$, 0);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_news.articles', 0);
reset role;

-- ==== 10. 0002: AI 라우팅 시드 · toss_merchant 1행 ====
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'news'$$, 14);
select zz_check.expect($$select count(*) from nomad_core.api_providers where code = 'toss_merchant'$$, 1);

-- ==== 11. 스모크: 손댄 경로·공개 RPC 실행 회귀(조직 B 는 구독 활성, 조직 C 는 개설 반려·철회) ====
insert into nomad_core.organizations (id, name, kind) values ('00000000-0000-0000-0000-00000000000c', '감마신문', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000a6', 'owner');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000b', 'beta-two', 'x', 'internet', 'r1', date '2020-01-01', 'p', 'b@example.test', '02-000-0000', '00000000-0000-0000-0000-00000000000b/news/applications/c.pdf')$$, 'NW001');
select zz_check.fails_with($$select nomad_news.set_staff_role('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a6', 'desk')$$, 'P0002');
select nomad_news.set_paywall_rule('00000000-0000-0000-0000-00000000000b', '{"mode":"meter","free_articles_per_month":5}');
select nomad_news.upsert_taxonomy('00000000-0000-0000-0000-00000000000b', 'section', null, '{"slug":"local","name":"지역"}');
select nomad_news.upsert_newsletter_list('00000000-0000-0000-0000-00000000000b', null, '{"slug":"morning","name":"아침 브리핑"}');
select nomad_news.save_event('00000000-0000-0000-0000-00000000000b', null, '{"title":"축제","starts_at":"2030-01-01T10:00:00+09:00","status":"published"}');
select zz_check.expect_text($$select nomad_news.compliance_weekly_stats('00000000-0000-0000-0000-00000000000b', date '2026-11-09') ->> 'week_start'$$, '2026-11-09');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a6","role":"authenticated"}', true);
select nomad_news.ensure_reader('00000000-0000-0000-0000-00000000000b', '감마독자', 'v1', 'v1', true);
select nomad_news.submit_life_event('00000000-0000-0000-0000-00000000000b', '{"kind":"obituary","title":"부고","body":"부고 본문","applicant_name":"신청인","consent_version":"v1"}');
select nomad_news.submit_listing('00000000-0000-0000-0000-00000000000b', '{"business_name":"가게","category":"cafe"}');
insert into zz_check.vals select 'appC', (nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000c', 'gamma-news', '감마신문', 'internet', '서울 아00003',
  date '2022-01-01', '발행인C', 'c@example.test', '02-222-2222', '00000000-0000-0000-0000-00000000000c/news/applications/cert.pdf')).id::text;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.submit_life_event('00000000-0000-0000-0000-00000000000a', '{"kind":"obituary","title":"부고","body":"본문","applicant_name":"x","consent_version":"v1"}')$$, 'NW014');
select zz_check.fails_with($$select nomad_news.submit_listing('00000000-0000-0000-0000-00000000000a', '{"business_name":"가게","category":"cafe"}')$$, 'NW014');
select zz_check.fails_with($$select nomad_news.withdraw_newspaper_request((select v::uuid from zz_check.vals where k = 'appC'))$$, 'P0002');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_news.reject_newspaper((select v::uuid from zz_check.vals where k = 'appC'), '서류 미비');
select zz_check.expect_text($$select nomad_news.submit_tip('00000000-0000-0000-0000-00000000000b', '{"title":"제보","body":"제보 내용 열 글자 이상","consent_version":"v1"}') ->> 'ok'$$, 'true');
select zz_check.fails_with($$select nomad_news.submit_tip('00000000-0000-0000-0000-00000000000a', '{"title":"제보","body":"제보 내용 열 글자 이상","consent_version":"v1"}')$$, 'NW014');
select nomad_news.register_push_subscription('00000000-0000-0000-0000-00000000000b', 'https://push.example.test/abc123', repeat('k', 60), repeat('a', 20));
insert into zz_check.vals select 'nltok', nomad_news.subscribe_newsletter('00000000-0000-0000-0000-00000000000b', 'morning', 'n@example.test', 'v1') ->> 'confirm_token';
select nomad_news.review_listing((select id from nomad_news.local_listings where organization_id = '00000000-0000-0000-0000-00000000000b'), 'approve');
select nomad_news.activate_listing((select id from nomad_news.local_listings where organization_id = '00000000-0000-0000-0000-00000000000b'), now() - interval '1 day', now() + interval '1 day');
reset role;
-- 반려 뒤 같은 슬러그로 재신청 → 철회
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a6","role":"authenticated"}', true);
insert into zz_check.vals select 'appC2', (nomad_news.request_newspaper('00000000-0000-0000-0000-00000000000c', 'gamma-news', '감마신문', 'internet', '서울 아00003',
  date '2022-01-01', '발행인C', 'c@example.test', '02-222-2222', '00000000-0000-0000-0000-00000000000c/news/applications/cert.pdf')).id::text;
select zz_check.expect_text($$select (nomad_news.withdraw_newspaper_request((select v::uuid from zz_check.vals where k = 'appC2'))).status$$, 'withdrawn');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_news.confirm_newsletter((select v from zz_check.vals where k = 'nltok')) ->> 'status'$$, 'confirmed');
select zz_check.expect($$select count(*) from unnest(array['notices', 'life_events', 'events', 'listings', 'print_editions']) k
  cross join lateral (select nomad_news.list_public_items('00000000-0000-0000-0000-00000000000b', k) as j) x where jsonb_typeof(x.j) = 'array'$$, 5);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_items('00000000-0000-0000-0000-00000000000b', 'events'))$$, 1);
select zz_check.expect($$select count(*) from jsonb_array_elements(nomad_news.list_public_items('00000000-0000-0000-0000-00000000000b', 'listings')) e, jsonb_object_keys(e) k
  where k in ('contact_email', 'payment_order_id', 'applicant_user_id', 'reader_id')$$, 0);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_items('00000000-0000-0000-0000-00000000000b', 'listings'))$$, 1);
select zz_check.expect($$select count(*) from nomad_news.search_articles('00000000-0000-0000-0000-00000000000b', '베타')$$, 1);
select zz_check.expect($$select count(*) from nomad_news.most_read('00000000-0000-0000-0000-00000000000b')$$, 0);
select zz_check.expect($$select count(*) from nomad_news.serve_ads('00000000-0000-0000-0000-00000000000b', 'home')$$, 0);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_articles('00000000-0000-0000-0000-00000000000b', 'local'))$$, 0);
select zz_check.expect($$select jsonb_array_length(nomad_news.get_public_newspaper('beta-news') -> 'newsletter_lists')$$, 1);
reset role;

-- ==== 12. 리뷰 반영 회귀(R1 · S1~S8 · W1~W9). 조직 A 구독을 되살리고 데스크 u7 · 기자 u8 · 기고자 u9 를 들인다 ====
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'news';
update nomad_core.plan_limits set limit_value = 10 where product_code = 'news' and plan_code = 'B' and limit_key = 'news_staff_max';
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a7', 'u7@example.test', now()), ('00000000-0000-0000-0000-0000000000a8', 'u8@example.test', now()),
  ('00000000-0000-0000-0000-0000000000a9', 'u9@example.test', now());
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'tok7', nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u7@example.test', 'desk', '데스크7') ->> 'token';
insert into zz_check.vals select 'tok8', nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u8@example.test', 'reporter', '기자8') ->> 'token';
insert into zz_check.vals select 'tok9', nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u9@example.test', 'contributor', '기고9') ->> 'token';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
select nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok7'));
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
select nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok8'));
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a9","role":"authenticated"}', true);
select nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok9'));
reset role;

-- R1 미디어: 기자·기고자는 자기 것 + 미게시만. 게시된 자산은 데스크 이상 + 감사 로그
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
insert into zz_check.vals select 'medD', (nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', null,
  '{"storage_path":"00000000-0000-0000-0000-00000000000a/news/media/d1.jpg","mime":"image/jpeg","alt_text":"대체","credit":"데스크"}')).id::text;
insert into zz_check.vals select 'medH', (nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', null,
  '{"storage_path":"00000000-0000-0000-0000-00000000000a/news/media/h1.jpg","mime":"image/jpeg","alt_text":"대표","credit":"데스크"}')).id::text;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
insert into zz_check.vals select 'medR', (nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', null,
  '{"storage_path":"00000000-0000-0000-0000-00000000000a/news/media/r1.jpg","mime":"image/jpeg","alt_text":"대체","credit":"기자"}')).id::text;
select zz_check.fails_with($$select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medD'), '{"caption":"남의 것"}')$$, '42501');
select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medR'), '{"caption":"내 것"}');
reset role;
update nomad_news.media_assets set published_at = now() where id = (select v::uuid from zz_check.vals where k = 'medR');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medR'), '{"caption":"게시 뒤"}')$$, '42501');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medR'), '{"caption":"데스크 수정"}');
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000a' and action = 'media_asset.update'
  and target_id = (select v from zz_check.vals where k = 'medR')$$, 1);

-- R1-b 승인~게시 사이 창: draft 가 아닌 기사가 싣고 있는 자기 미게시 자산도 기자는 못 고친다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
insert into zz_check.vals select 'medR2', (nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', null,
  '{"storage_path":"00000000-0000-0000-0000-00000000000a/news/media/r2.jpg","mime":"image/jpeg","alt_text":"대체","credit":"기자"}')).id::text;
select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medR2'), '{"caption":"싣기 전"}');
reset role;
select set_config('request.jwt.claims', '', true);
update nomad_news.articles set media_ids = media_ids || (select v::uuid from zz_check.vals where k = 'medR2')
 where id = (select id from nomad_news.articles where organization_id = '00000000-0000-0000-0000-00000000000a' and status <> 'draft' order by created_at limit 1);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medR2'), '{"credit":"승인 뒤"}')$$, '42501');
reset role;
select set_config('request.jwt.claims', '', true);
-- 결제 반영은 멱등 키(이벤트 id) 필수
select zz_check.fails_with($$select nomad_news.record_membership('00000000-0000-0000-0000-00000000000a', (select id from nomad_news.readers where user_id = '00000000-0000-0000-0000-0000000000a4'), null, 'active')$$, 'NW015');

-- S1 도메인 역할: core 멤버십이 staff 합류 뒤 다른 초대로 다시 생기면 예전 역할이 살아나지 않는다. 발행인은 core owner 일 때만
update nomad_news.staff set joined_at = now() - interval '1 hour' where organization_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a5';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select nomad_core.remove_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'core5', nomad_core.create_invitation('00000000-0000-0000-0000-00000000000a', 'u5@example.test', 'editor');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select nomad_core.accept_invitation((select v from zz_check.vals where k = 'core5'));
select zz_check.expect_text($$select coalesce(nomad_news.staff_role('00000000-0000-0000-0000-00000000000a'), 'NONE')$$, 'NONE');
select zz_check.expect('select count(*) from nomad_news.articles', 0);
-- 다시 들어오려면 편집국 초대(invite_staff)를 거친다
select nomad_core.remove_member('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'tok5b', nomad_news.invite_staff('00000000-0000-0000-0000-00000000000a', 'u5@example.test', 'editor', '편집인5') ->> 'token';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect_text($$select (nomad_news.accept_staff_invitation((select v from zz_check.vals where k = 'tok5b'))).role$$, 'editor');
select zz_check.expect_text($$select nomad_news.staff_role('00000000-0000-0000-0000-00000000000a')$$, 'editor');
reset role;
update nomad_core.memberships set role = 'editor' where organization_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect_text($$select coalesce(nomad_news.staff_role('00000000-0000-0000-0000-00000000000a'), 'NONE')$$, 'NONE');
reset role;
update nomad_core.memberships set role = 'owner' where organization_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';

-- W4 데스크 미만: 저자는 본인 고정, sponsored·wire 유형과 속보 표시 지정 불가
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"title":"x","author_id":"00000000-0000-0000-0000-0000000000a1"}')$$, '42501');
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"title":"x","type":"sponsored","sponsor_label":"광고"}')$$, '42501');
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"title":"x","type":"wire"}')$$, '42501');
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"title":"x","is_breaking":true}')$$, '42501');
insert into zz_check.vals select 'art7', (nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null, '{"slug":"reporter-1","title":"기자 기사"}')).id::text;
-- W8 감사: 보관
select nomad_news.archive_article((select v::uuid from zz_check.vals where k = 'art7'));
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'article.archive' and target_id = (select v from zz_check.vals where k = 'art7')$$, 1);

-- W3 서버(service)는 draft 만 고친다(승인 뒤 내용 변경 불가)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'art3'), '{"title":"서버가 바꾼 제목"}')$$, 'NW004');
reset role;

-- S5 대표 사진은 활성 자산만 · S3 잠긴 프리미엄의 라이브 업데이트 비공개 · W2 기자는 숨김 방향만
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'art1'),
  jsonb_build_object('hero_media_id', (select v from zz_check.vals where k = 'medH'), 'change_note', '대표 사진 추가'));
select nomad_news.save_media_asset('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'medH'), '{"status":"archived"}');
select nomad_news.save_article('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'art2'), '{"is_live":true}');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
insert into zz_check.vals select 'lu1', (nomad_news.add_live_update((select v::uuid from zz_check.vals where k = 'art2'), '기자 업데이트')).id::text;
select nomad_news.set_live_update_status((select v::uuid from zz_check.vals where k = 'lu1'), 'hidden');
select zz_check.fails_with($$select nomad_news.set_live_update_status((select v::uuid from zz_check.vals where k = 'lu1'), 'visible')$$, '42501');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
select nomad_news.set_live_update_status((select v::uuid from zz_check.vals where k = 'lu1'), 'visible');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'open-1') ->> 'hero'$$, null);
select zz_check.expect($$select jsonb_array_length(nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') -> 'live_updates')$$, 0);
-- S4 프리미엄 본문은 검색 색인에 없다(제목·요약만) · S8 offset 상한
select zz_check.expect($$select count(*) from nomad_news.search_articles('00000000-0000-0000-0000-00000000000a', '유료')$$, 0);
select zz_check.expect($$select count(*) from nomad_news.search_articles('00000000-0000-0000-0000-00000000000a', '공개')$$, 1);
select zz_check.fails_with($$select * from nomad_news.search_articles('00000000-0000-0000-0000-00000000000a', '기사', 20, 5000)$$, 'NW015');
select zz_check.fails_with($$select * from nomad_news.search_articles('00000000-0000-0000-0000-00000000000a', '기사', 20, -1)$$, 'NW015');
reset role;
-- 유효 멤버(u4)에게는 라이브 업데이트가 보인다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect($$select jsonb_array_length(nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'premium-1') -> 'live_updates')$$, 1);
-- S7 독자는 멤버십의 결제 키·수수료·이벤트 id·외부 참조 컬럼을 못 읽는다
select zz_check.expect('select count(*) from nomad_news.memberships', 1);
select zz_check.denied('select billing_credential_id from nomad_news.memberships');
select zz_check.denied('select platform_fee_bps from nomad_news.memberships');
select zz_check.denied('select last_event_id from nomad_news.memberships');
select zz_check.denied('select external_ref from nomad_news.memberships');
reset role;

-- S6 멱등: 이미 처리한 이벤트(evt-1)를 다시 보내면(그 뒤 evt-3 가 처리됐어도) 아무것도 바꾸지 않는다
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_news.record_membership('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'rdr4'), null, 'canceled', null, null, null, 'evt-1');
reset role;
select zz_check.expect_text($$select status from nomad_news.memberships where reader_id = (select v::uuid from zz_check.vals where k = 'rdr4')$$, 'active');

-- W1 정정 청구에 기사가 정해져 있으면 그 기사에만 정정문을 붙인다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'req1', nomad_news.submit_correction_request('00000000-0000-0000-0000-00000000000a',
  jsonb_build_object('article_id', (select v from zz_check.vals where k = 'art1'), 'kind', 'correction', 'requester_name', '청구인',
                     'requester_email', 'r@example.test', 'claim_text', '사실과 다른 내용이 있습니다')) ->> 'id';
select nomad_news.respond_correction_request((select v::uuid from zz_check.vals where k = 'req1'), 'accept');
select zz_check.fails_with($$select nomad_news.record_article_correction((select v::uuid from zz_check.vals where k = 'art2'), 'correction', '다른 기사에 붙인 정정',
  (select v::uuid from zz_check.vals where k = 'req1'))$$, 'NW015');
select nomad_news.record_article_correction((select v::uuid from zz_check.vals where k = 'art1'), 'correction', '청구에 따른 정정입니다', (select v::uuid from zz_check.vals where k = 'req1'));
-- W8 감사: 선거 기간 저장
select nomad_news.upsert_election_period('00000000-0000-0000-0000-00000000000a', null, '{"name":"지방선거","election_day":"2030-06-03",
  "poll_blackout_from":"2030-05-28T00:00:00+09:00","poll_blackout_until":"2030-06-03T18:00:00+09:00"}');
-- W9 활성 유료 캠페인이 있는 광고주를 정부·지자체로 바꿀 수 없다
insert into zz_check.vals select 'adv1', (nomad_news.upsert_advertiser('00000000-0000-0000-0000-00000000000a', null, '{"name":"동네가게"}')).id::text;
select nomad_news.save_ad_campaign('00000000-0000-0000-0000-00000000000a', null, jsonb_build_object('advertiser_id', (select v from zz_check.vals where k = 'adv1'),
  'name', '유료 캠페인', 'price_krw', 10000, 'starts_at', now() - interval '1 day', 'ends_at', now() + interval '1 day', 'status', 'active'));
select zz_check.fails_with($$select nomad_news.upsert_advertiser('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'adv1'), '{"is_government":true}')$$, 'NW013');
-- W6 뉴스레터 기사는 같은 조직의 게시 기사만
insert into zz_check.vals select 'nl1', (nomad_news.upsert_newsletter_list('00000000-0000-0000-0000-00000000000a', null, '{"slug":"daily","name":"데일리"}')).id::text;
select zz_check.fails_with($$select nomad_news.save_newsletter_issue('00000000-0000-0000-0000-00000000000a', null, jsonb_build_object('list_id', (select v from zz_check.vals where k = 'nl1'),
  'subject', '오늘', 'article_ids', jsonb_build_array((select v from zz_check.vals where k = 'artB'))))$$, '23503');
select zz_check.fails_with($$select nomad_news.save_newsletter_issue('00000000-0000-0000-0000-00000000000a', null, jsonb_build_object('list_id', (select v from zz_check.vals where k = 'nl1'),
  'subject', '오늘', 'article_ids', jsonb_build_array((select v from zz_check.vals where k = 'art3'))))$$, '23503');
select nomad_news.save_newsletter_issue('00000000-0000-0000-0000-00000000000a', null, jsonb_build_object('list_id', (select v from zz_check.vals where k = 'nl1'),
  'subject', '오늘', 'article_ids', jsonb_build_array((select v from zz_check.vals where k = 'art1'))));
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000a' and action = 'election_period.save'$$, 1);

-- W5 행사: 기자는 자기 행사만, 게시는 데스크 이상
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
insert into zz_check.vals select 'evD', (nomad_news.save_event('00000000-0000-0000-0000-00000000000a', null, '{"title":"데스크 행사","starts_at":"2030-01-01T10:00:00+09:00"}')).id::text;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a8","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_news.save_event('00000000-0000-0000-0000-00000000000a', null, '{"title":"행사","starts_at":"2030-01-01T10:00:00+09:00","status":"published"}')$$, '42501');
select zz_check.fails_with($$select nomad_news.save_event('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'evD'), '{"title":"남의 행사"}')$$, '42501');
insert into zz_check.vals select 'evR', (nomad_news.save_event('00000000-0000-0000-0000-00000000000a', null, '{"title":"기자 행사","starts_at":"2030-01-01T10:00:00+09:00"}')).id::text;
select nomad_news.save_event('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'evR'), '{"venue":"시청"}');
select zz_check.fails_with($$select nomad_news.save_event('00000000-0000-0000-0000-00000000000a', (select v::uuid from zz_check.vals where k = 'evR'), '{"status":"published"}')$$, '42501');
reset role;

-- W8 감사: 홈 편집 예약 · 업소 검토 · 경조사 검토 · 지면 게시(조직 B, 플랜 A)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
insert into zz_check.vals select 'lstA', (nomad_news.submit_listing('00000000-0000-0000-0000-00000000000a', '{"business_name":"알파가게","category":"cafe"}')).id::text;
insert into zz_check.vals select 'leA', (nomad_news.submit_life_event('00000000-0000-0000-0000-00000000000a', '{"kind":"obituary","title":"부고","body":"본문","applicant_name":"신청인","consent_version":"v1"}')).id::text;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
insert into zz_check.vals select 'home1', (nomad_news.save_home_layout('00000000-0000-0000-0000-00000000000a', null, '{"name":"주말 홈"}')).id::text;
select nomad_news.publish_home_layout((select v::uuid from zz_check.vals where k = 'home1'), now() + interval '1 day');
select nomad_news.review_life_event((select v::uuid from zz_check.vals where k = 'leA'), 'approve');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_news.review_listing((select v::uuid from zz_check.vals where k = 'lstA'), 'approve');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
insert into zz_check.vals select 'pe1', (nomad_news.save_print_edition('00000000-0000-0000-0000-00000000000b', null,
  '{"edition_date":"2026-11-15","pdf_path":"00000000-0000-0000-0000-00000000000b/news/print/p1.pdf"}')).id::text;
select nomad_news.save_print_edition('00000000-0000-0000-0000-00000000000b', (select v::uuid from zz_check.vals where k = 'pe1'), '{"status":"published"}');
-- W7 남의 조직 행 id: 존재를 드러내지 않게 P0002
select zz_check.fails_with($$select nomad_news.submit_article((select v::uuid from zz_check.vals where k = 'art3'))$$, 'P0002');
select zz_check.fails_with($$select nomad_news.review_article((select v::uuid from zz_check.vals where k = 'art3'), 'approve')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.publish_article((select v::uuid from zz_check.vals where k = 'art3'))$$, 'P0002');
select zz_check.fails_with($$select nomad_news.archive_article((select v::uuid from zz_check.vals where k = 'art1'))$$, 'P0002');
select zz_check.fails_with($$select nomad_news.schedule_article((select v::uuid from zz_check.vals where k = 'art3'), now() + interval '1 hour')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.add_live_update((select v::uuid from zz_check.vals where k = 'art2'), 'x')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.set_live_update_status((select v::uuid from zz_check.vals where k = 'lu1'), 'hidden')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.publish_home_layout((select v::uuid from zz_check.vals where k = 'home1'))$$, 'P0002');
select zz_check.fails_with($$select nomad_news.review_listing((select v::uuid from zz_check.vals where k = 'lstA'), 'reject')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.review_life_event((select v::uuid from zz_check.vals where k = 'leA'), 'reject')$$, 'P0002');
select zz_check.fails_with($$select nomad_news.respond_correction_request((select v::uuid from zz_check.vals where k = 'req1'), 'withdrawn')$$, 'P0002');
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'home_layout.schedule' and target_id = (select v from zz_check.vals where k = 'home1')$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'life_event.approve' and target_id = (select v from zz_check.vals where k = 'leA')$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'listing.approve' and target_id = (select v from zz_check.vals where k = 'lstA')$$, 1);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'print_edition.publish' and target_id = (select v from zz_check.vals where k = 'pe1')$$, 1);

-- S2 엠바고: 구독이 끊긴 동안 풀린 엠바고 기사는 공개되지 않는다(끊기기 전에 풀린 것은 유지). 끊긴 시각은 예약 실행이 기록한다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
insert into zz_check.vals select 'art5', (nomad_news.save_article('00000000-0000-0000-0000-00000000000a', null,
  jsonb_build_object('slug', 'embargo-1', 'title', '엠바고 기사', 'body', '[]'::jsonb, 'embargo_until', now() + interval '1 hour'))).id::text;
select nomad_news.submit_article((select v::uuid from zz_check.vals where k = 'art5'));
select nomad_news.review_article((select v::uuid from zz_check.vals where k = 'art5'), 'approve');
select nomad_news.publish_article((select v::uuid from zz_check.vals where k = 'art5'));
reset role;
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'news';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_news.run_scheduled_publishing();
reset role;
select zz_check.expect($$select count(*) from nomad_news.newspapers where organization_id = '00000000-0000-0000-0000-00000000000a' and plan_lapsed_at = now()$$, 1);
update nomad_news.newspapers set plan_lapsed_at = now() - interval '10 minutes' where organization_id = '00000000-0000-0000-0000-00000000000a';
update nomad_news.articles set embargo_until = now() - interval '1 minute' where id = (select v::uuid from zz_check.vals where k = 'art5');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'embargo-1')::text$$, null);
select zz_check.expect($$select jsonb_array_length(nomad_news.list_public_articles('00000000-0000-0000-0000-00000000000a'))$$, 2);
reset role;
update nomad_news.articles set embargo_until = now() - interval '20 minutes' where id = (select v::uuid from zz_check.vals where k = 'art5');
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_news.read_article('00000000-0000-0000-0000-00000000000a', 'embargo-1') ->> 'slug'$$, 'embargo-1');
reset role;
-- W2 구독 끊김 중에는 숨긴 라이브 업데이트를 다시 보이게 할 수 없다(숨김은 열림)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a7","role":"authenticated"}', true);
select nomad_news.set_live_update_status((select v::uuid from zz_check.vals where k = 'lu1'), 'hidden');
select zz_check.fails_with($$select nomad_news.set_live_update_status((select v::uuid from zz_check.vals where k = 'lu1'), 'visible')$$, 'NW014');
reset role;
-- 구독이 돌아오면 끊긴 시각을 지운다
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'news';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_news.run_scheduled_publishing();
reset role;
select zz_check.expect($$select count(*) from nomad_news.newspapers where organization_id = '00000000-0000-0000-0000-00000000000a' and plan_lapsed_at is null$$, 1);
