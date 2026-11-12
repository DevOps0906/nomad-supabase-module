-- task-004 기능 잠금 검증 (합성 데이터, 롤백)
-- 1 조직형(contentflow) 플랜별 쓰기 · 2 구독 기간 · 3 다운그레이드 · 4 manual 해제
-- 5 개인형(humscore·personal) · 6 dashboard_features
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

-- 문장 결과(첫 컬럼 정수)
create function pg_temp.n(stmt text) returns bigint
language plpgsql as $$
declare r bigint;
begin
  execute stmt into r;
  return r;
end;
$$;

-- 영향 행 수
create function pg_temp.rows(stmt text) returns bigint
language plpgsql as $$
declare r bigint;
begin
  execute stmt;
  get diagnostics r = row_count;
  return r;
end;
$$;

create function pg_temp.eq(actual bigint, expected bigint, label text) returns void
language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception '% : got %, want %', label, actual, expected;
  end if;
end;
$$;

create function pg_temp.as_user(u uuid) returns void
language sql as $$
  select set_config('request.jwt.claim.sub', u::text, true),
         set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
$$;

-- 합성 데이터 ---------------------------------------------------------------
-- 사용자: u1 구독 없는 조직 owner · u2 B 구독 owner · u3 A 구독 owner(조직형) / 팀 viewer(개인형)
--         u4 비활성 조직 owner · u5 멤버십 없음
insert into auth.users (id) values
 ('00000000-0000-4000-8000-0000000003a1'), ('00000000-0000-4000-8000-0000000003a2'),
 ('00000000-0000-4000-8000-0000000003a3'), ('00000000-0000-4000-8000-0000000003a4'),
 ('00000000-0000-4000-8000-0000000003a5');

-- 조직형 contentflow 업체: o1 구독 없음 · o2 B · o3 A · o4 만료 B · o5 미래 시작 B · o6 C로 다운그레이드 · o7 manual 해제
insert into nomad_core.organizations (id, name, active) values
 ('00000000-0000-4000-8000-0000000003b1', '기능잠금 o1', true),
 ('00000000-0000-4000-8000-0000000003b2', '기능잠금 o2', true),
 ('00000000-0000-4000-8000-0000000003b3', '기능잠금 o3', true),
 ('00000000-0000-4000-8000-0000000003b4', '기능잠금 o4', true),
 ('00000000-0000-4000-8000-0000000003b5', '기능잠금 o5', true),
 ('00000000-0000-4000-8000-0000000003b6', '기능잠금 o6', true),
 ('00000000-0000-4000-8000-0000000003b7', '기능잠금 o7', true),
 -- 개인형: p1 u1 개인 · p2 u2 개인(B) · p3 u3 개인(구독 없음) · pt 팀(B) · pi 비활성(B)
 ('00000000-0000-4000-8000-0000000003c1', '개인 p1', true),
 ('00000000-0000-4000-8000-0000000003c2', '개인 p2', true),
 ('00000000-0000-4000-8000-0000000003c3', '개인 p3', true),
 ('00000000-0000-4000-8000-0000000003c4', '팀 pt', true),
 ('00000000-0000-4000-8000-0000000003c5', '비활성 pi', false);

insert into nomad_core.memberships (organization_id, user_id, role)
select o, '00000000-0000-4000-8000-0000000003a1', 'owner'
  from unnest(array['00000000-0000-4000-8000-0000000003b1','00000000-0000-4000-8000-0000000003b2',
                    '00000000-0000-4000-8000-0000000003b3','00000000-0000-4000-8000-0000000003b4',
                    '00000000-0000-4000-8000-0000000003b5','00000000-0000-4000-8000-0000000003b6',
                    '00000000-0000-4000-8000-0000000003b7','00000000-0000-4000-8000-0000000003c1']::uuid[]) o;
insert into nomad_core.memberships (organization_id, user_id, role) values
 ('00000000-0000-4000-8000-0000000003c2', '00000000-0000-4000-8000-0000000003a2', 'owner'),
 ('00000000-0000-4000-8000-0000000003c3', '00000000-0000-4000-8000-0000000003a3', 'owner'),
 ('00000000-0000-4000-8000-0000000003c4', '00000000-0000-4000-8000-0000000003a3', 'viewer'),
 ('00000000-0000-4000-8000-0000000003c5', '00000000-0000-4000-8000-0000000003a4', 'owner');

insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status, starts_at, ends_at) values
 ('00000000-0000-4000-8000-0000000003b2', 'contentflow', 'B', 'active', now() - interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003b3', 'contentflow', 'A', 'active', now() - interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003b4', 'contentflow', 'B', 'active', now() - interval '10 days', now() - interval '1 day'),
 ('00000000-0000-4000-8000-0000000003b5', 'contentflow', 'B', 'active', now() + interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003b6', 'contentflow', 'C', 'active', now() - interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003c2', 'humscore', 'B', 'active', now() - interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003c2', 'personal', 'B', 'active', now() - interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003c4', 'humscore', 'B', 'active', now() - interval '1 day', null),
 ('00000000-0000-4000-8000-0000000003c5', 'humscore', 'B', 'active', now() - interval '1 day', null);

-- o7: 구독 없이 quality_review(A 전용)만 개별 해제
insert into nomad_core.feature_grants (organization_id, product_code, feature_code, source)
values ('00000000-0000-4000-8000-0000000003b7', 'contentflow', 'quality_review', 'manual');

-- o6(C로 내려간 조직)의 기존 B 기능 행, o2(B)의 기존 A 기능 행
insert into nomad_contentflow.publish_logs (id, organization_id, url) values
 ('00000000-0000-4000-8000-0000000003d1', '00000000-0000-4000-8000-0000000003b6', 'old');
insert into nomad_contentflow.reviews (id, organization_id, reviewer_id) values
 ('00000000-0000-4000-8000-0000000003d2', '00000000-0000-4000-8000-0000000003b2', '00000000-0000-4000-8000-0000000003a1');

-- 개인형 소유 악보
insert into nomad_humscore.scores (id, user_id, title)
select ('00000000-0000-4000-8000-0000000003e' || i)::uuid, ('00000000-0000-4000-8000-0000000003a' || i)::uuid, 's'
  from generate_series(1, 5) i;

-- 0. 카탈로그 시드 전제 -------------------------------------------------------
select pg_temp.eq((select count(*) from nomad_core.plans where product_code = 'contentflow'), 3, 'contentflow plans A/B/C');
select pg_temp.eq((select count(*) from nomad_core.plan_features where product_code = 'contentflow' and plan_code = 'C' and feature_code = 'publish_automation'), 0, 'C에 B 기능 없음');
select pg_temp.eq((select count(*) from nomad_core.plan_features where product_code = 'contentflow' and plan_code = 'B' and feature_code = 'publish_automation'), 1, 'B에 publish_automation');

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000003a1');

-- 1. 조직형 플랜별 쓰기 ------------------------------------------------------
-- 구독 없음(o1): C 기능(blogs) 가능, B(publish_logs)·A(reviews) 거부
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.blogs (organization_id, name) values ('00000000-0000-4000-8000-0000000003b1', 'c')$q$), 1, 'o1 C blogs insert');
select pg_temp.expect_err($q$insert into nomad_contentflow.publish_logs (organization_id, url) values ('00000000-0000-4000-8000-0000000003b1', 'x')$q$, '%row-level security%');
select pg_temp.expect_err($q$insert into nomad_contentflow.reviews (organization_id) values ('00000000-0000-4000-8000-0000000003b1')$q$, '%row-level security%');
-- B 구독(o2): publish_logs 가능, reviews(A) 거부
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.publish_logs (organization_id, url) values ('00000000-0000-4000-8000-0000000003b2', 'x')$q$), 1, 'o2 B publish_logs insert');
select pg_temp.expect_err($q$insert into nomad_contentflow.reviews (organization_id) values ('00000000-0000-4000-8000-0000000003b2')$q$, '%row-level security%');
-- A 구독(o3): 둘 다 가능
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.publish_logs (organization_id, url) values ('00000000-0000-4000-8000-0000000003b3', 'x')$q$), 1, 'o3 A publish_logs insert');
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.reviews (organization_id) values ('00000000-0000-4000-8000-0000000003b3')$q$), 1, 'o3 A reviews insert');

-- 2. 만료·미래 시작 구독은 C로 취급 ------------------------------------------
select pg_temp.expect_err($q$insert into nomad_contentflow.publish_logs (organization_id, url) values ('00000000-0000-4000-8000-0000000003b4', 'x')$q$, '%row-level security%');
select pg_temp.expect_err($q$insert into nomad_contentflow.publish_logs (organization_id, url) values ('00000000-0000-4000-8000-0000000003b5', 'x')$q$, '%row-level security%');
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.blogs (organization_id, name) values ('00000000-0000-4000-8000-0000000003b4', 'c')$q$), 1, 'o4 만료 구독도 C 쓰기');
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.blogs (organization_id, name) values ('00000000-0000-4000-8000-0000000003b5', 'c')$q$), 1, 'o5 미래 구독도 C 쓰기');

-- 3. 다운그레이드: 기존 B 행 select 가능, update 거부 / 정상 조직 update 가능
select pg_temp.eq((select count(*) from nomad_contentflow.publish_logs where id = '00000000-0000-4000-8000-0000000003d1'), 1, 'o6 기존 행 select');
select pg_temp.eq(pg_temp.rows($q$update nomad_contentflow.publish_logs set url = 'new' where id = '00000000-0000-4000-8000-0000000003d1'$q$), 0, 'o6 C 조직 update 거부');
select pg_temp.eq((select count(*) from nomad_contentflow.reviews where id = '00000000-0000-4000-8000-0000000003d2'), 1, 'o2 기존 A 행 select');
select pg_temp.eq(pg_temp.rows($q$update nomad_contentflow.reviews set verdict = 'reject' where id = '00000000-0000-4000-8000-0000000003d2'$q$), 0, 'o2 B 조직 A 기능 update 거부');
select pg_temp.eq(pg_temp.rows($q$update nomad_contentflow.publish_logs set url = 'new' where organization_id = '00000000-0000-4000-8000-0000000003b3'$q$), 1, 'o3 A update 가능');

-- 4. manual feature_grants 개별 해제(o7: 구독 없음)
select pg_temp.eq(pg_temp.rows($q$insert into nomad_contentflow.reviews (organization_id) values ('00000000-0000-4000-8000-0000000003b7')$q$), 1, 'o7 grant된 reviews 가능');
select pg_temp.expect_err($q$insert into nomad_contentflow.publish_logs (organization_id, url) values ('00000000-0000-4000-8000-0000000003b7', 'x')$q$, '%row-level security%');

-- 5. 개인형 ------------------------------------------------------------------
-- u1: 구독 없는 owner 조직만 → C 기능만(scores 가능, recordings·exports 거부)
select pg_temp.eq(pg_temp.rows($q$insert into nomad_humscore.scores (title) values ('c')$q$), 1, 'u1 C scores insert');
select pg_temp.expect_err($q$insert into nomad_humscore.recordings (score_id) values ('00000000-0000-4000-8000-0000000003e1')$q$, '%row-level security%');
select pg_temp.expect_err($q$insert into nomad_humscore.exports (score_id) values ('00000000-0000-4000-8000-0000000003e1')$q$, '%row-level security%');
select pg_temp.expect_err($q$insert into nomad_personal.saved_reports (reading_id) values (null)$q$, '%row-level security%');

-- u2: owner 조직 B 구독 → B 가능
select pg_temp.as_user('00000000-0000-4000-8000-0000000003a2');
select pg_temp.eq(pg_temp.rows($q$insert into nomad_humscore.recordings (score_id) values ('00000000-0000-4000-8000-0000000003e2')$q$), 1, 'u2 B recordings insert');
select pg_temp.eq(pg_temp.rows($q$insert into nomad_humscore.exports (score_id) values ('00000000-0000-4000-8000-0000000003e2')$q$), 1, 'u2 B exports insert');
select pg_temp.eq(pg_temp.rows($q$insert into nomad_personal.saved_reports (reading_id) values (null)$q$), 1, 'u2 B personal saved_reports insert');
select pg_temp.eq(pg_temp.rows($q$update nomad_humscore.recordings set duration = 1 where score_id = '00000000-0000-4000-8000-0000000003e2'$q$), 1, 'u2 B recordings update');

-- u3: 팀 viewer(B 구독 팀) + 자기 조직은 구독 없음 → 팀 구독은 공유되지 않음
select pg_temp.as_user('00000000-0000-4000-8000-0000000003a3');
select pg_temp.expect_err($q$insert into nomad_humscore.recordings (score_id) values ('00000000-0000-4000-8000-0000000003e3')$q$, '%row-level security%');
select pg_temp.eq((select nomad_core.user_has_feature('humscore', 'recording')::int), 0, 'u3 user_has_feature false');

-- u4: 비활성 조직 구독은 무효
select pg_temp.as_user('00000000-0000-4000-8000-0000000003a4');
select pg_temp.expect_err($q$insert into nomad_humscore.recordings (score_id) values ('00000000-0000-4000-8000-0000000003e4')$q$, '%row-level security%');

-- u5: 멤버십 없음
select pg_temp.as_user('00000000-0000-4000-8000-0000000003a5');
select pg_temp.expect_err($q$insert into nomad_humscore.recordings (score_id) values ('00000000-0000-4000-8000-0000000003e5')$q$, '%row-level security%');
select pg_temp.eq((select nomad_core.user_has_feature('humscore', 'recording')::int), 0, 'u5 user_has_feature false');

-- 6. dashboard_features --------------------------------------------------------
select pg_temp.as_user('00000000-0000-4000-8000-0000000003a1');
-- 구독 없는 o1: C 기능 unlocked·upgrade_to null, B 기능 locked·upgrade_to 'B'
select pg_temp.eq((select count(*) from nomad_core.dashboard_features('00000000-0000-4000-8000-0000000003b1', 'contentflow')
                    where feature_code = 'blog_core' and unlocked and upgrade_to is null), 1, 'o1 blog_core unlocked/null');
select pg_temp.eq((select count(*) from nomad_core.dashboard_features('00000000-0000-4000-8000-0000000003b1', 'contentflow')
                    where feature_code = 'publish_automation' and not unlocked and upgrade_to = 'B'), 1, 'o1 publish_automation locked/B');
select pg_temp.eq((select count(*) from nomad_core.dashboard_features('00000000-0000-4000-8000-0000000003b1', 'contentflow')
                    where feature_code = 'quality_review' and not unlocked and upgrade_to = 'A'), 1, 'o1 quality_review locked/A');
-- A 구독 o3: 전부 unlocked·upgrade_to null
select pg_temp.eq((select count(*) from nomad_core.dashboard_features('00000000-0000-4000-8000-0000000003b3', 'contentflow')
                    where not unlocked or upgrade_to is not null), 0, 'o3 모두 unlocked/null');

-- 서버 전용 org_has_feature: authenticated 실행 불가, service_role은 사용자 JWT 없이 업체 이용권 판정
do $$ begin
  perform nomad_core.org_has_feature('00000000-0000-4000-8000-0000000003b1', 'contentflow', 'blog_core');
  raise exception 'authenticated가 org_has_feature를 실행함';
exception when insufficient_privilege then null; end $$;
reset role;
set local role service_role;
select set_config('request.jwt.claims', '', true);
select pg_temp.eq(nomad_core.org_has_feature('00000000-0000-4000-8000-0000000003b1', 'contentflow', 'blog_core')::int, 1, 'service_role 구독 없음 C 열림');
select pg_temp.eq(nomad_core.org_has_feature('00000000-0000-4000-8000-0000000003b1', 'contentflow', 'publish_automation')::int, 0, 'service_role 구독 없음 B 잠김');
select pg_temp.eq(nomad_core.org_has_feature('00000000-0000-4000-8000-0000000003b3', 'contentflow', 'quality_review')::int, 1, 'service_role A 구독 A 열림');

reset role;
rollback;
\o
\echo feature_gating OK
