-- 서비스 11개 마이그레이션(nomad_<slug>) 격리·권한 검증 (합성 데이터, 롤백)
-- 1 카탈로그 · 2 조직형 7개 대표 테이블 · 3 jangter 두 당사자 · 4 baedal 두 당사자 · 5 classroom 학생 기록
\o /dev/null
begin;

-- 실패 경로 도우미: 문장이 반드시 실패하고 메시지가 패턴과 맞아야 한다.
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

-- 문장 결과(첫 컬럼 정수) 반환
create function pg_temp.n(stmt text) returns bigint
language plpgsql as $$
declare r bigint;
begin
  execute stmt into r;
  return r;
end;
$$;

-- 현재 사용자 전환(authenticated 역할 상태에서 호출)
create function pg_temp.as_user(u uuid) returns void
language sql as $$
  select set_config('request.jwt.claim.sub', u::text, true),
         set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
$$;

-- 1. 카탈로그 ---------------------------------------------------------------
do $$
declare
  slugs text[] := array['contentflow','flora','knowflow','classroom','analytics','sceneflow','commerce','humscore','jangter','baedal','personal'];
  orgs  text[] := array['contentflow','flora','knowflow','classroom','analytics','sceneflow','commerce'];
  s text; bad text;
begin
  foreach s in array slugs loop
    if not exists (select 1 from information_schema.schemata where schema_name = 'nomad_' || s)
    then raise exception 'schema nomad_% missing', s; end if;
    if not exists (select 1 from nomad_core.products where code = s)
    then raise exception 'product % not registered', s; end if;

    -- RLS 활성
    select string_agg(c.relname, ',') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'nomad_' || s and c.relkind in ('r','p') and not c.relrowsecurity;
    if bad is not null then raise exception 'RLS disabled in nomad_%: %', s, bad; end if;

    -- 정책 대상 역할은 authenticated뿐
    select string_agg(tablename || '.' || policyname, ',') into bad from pg_policies
     where schemaname = 'nomad_' || s and roles <> array['authenticated']::name[];
    if bad is not null then raise exception 'policy roles not {authenticated} in nomad_%: %', s, bad; end if;

    -- 쓰기 정책에 true 금지
    select string_agg(tablename || '.' || policyname, ',') into bad from pg_policies
     where schemaname = 'nomad_' || s and cmd in ('INSERT','UPDATE','DELETE','ALL')
       and (coalesce(qual,'') ~* '\mtrue\M' or coalesce(with_check,'') ~* '\mtrue\M');
    if bad is not null then raise exception 'write policy opens with true in nomad_%: %', s, bad; end if;

    -- anon: 스키마·테이블·컬럼 권한 없음 / authenticated: truncate·references·trigger 없음
    if has_schema_privilege('anon', 'nomad_' || s, 'usage')
    then raise exception 'anon has schema usage on nomad_%', s; end if;
    if not has_schema_privilege('authenticated', 'nomad_' || s, 'usage')
    then raise exception 'authenticated lacks schema usage on nomad_%', s; end if;
    select string_agg(c.relname, ',') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'nomad_' || s and c.relkind in ('r','p')
       and (has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')
            or has_any_column_privilege('anon', c.oid, 'select,insert,update,references'));
    if bad is not null then raise exception 'anon has privileges in nomad_%: %', s, bad; end if;
    select string_agg(c.relname, ',') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'nomad_' || s and c.relkind in ('r','p')
       and has_table_privilege('authenticated', c.oid, 'truncate,references,trigger');
    if bad is not null then raise exception 'authenticated has truncate/references/trigger in nomad_%: %', s, bad; end if;
  end loop;

  -- 조직형: 삭제 정책은 owner/admin만 (예외: knowflow 개인 대화 chats·messages는 본인 기준)
  foreach s in array orgs loop
    select string_agg(tablename || '.' || policyname, ',') into bad from pg_policies
     where schemaname = 'nomad_' || s and cmd = 'DELETE'
       and not (s = 'knowflow' and tablename in ('chats','messages'))
       and not (qual ~ 'owner' and qual ~ 'admin' and qual !~ 'editor' and qual !~ 'viewer');
    if bad is not null then raise exception 'org delete policy not owner/admin only in nomad_%: %', s, bad; end if;
    -- 서버 전용 테이블(quiz_attempts, commerce.orders)을 뺀 모든 테이블에 삭제 정책
    select string_agg(c.relname, ',') into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'nomad_' || s and c.relkind = 'r'
       and (s, c.relname) not in (('classroom','quiz_attempts'), ('commerce','orders'))
       and not exists (select 1 from pg_policies p where p.schemaname = n.nspname and p.tablename = c.relname and p.cmd = 'DELETE');
    if bad is not null then raise exception 'org table without delete policy in nomad_%: %', s, bad; end if;
  end loop;
  -- knowflow 개인 대화: 삭제는 본인(대화 소유자) 기준
  if exists (select 1 from pg_policies where schemaname = 'nomad_knowflow' and cmd = 'DELETE' and tablename = 'chats' and qual !~ 'auth.uid')
     or exists (select 1 from pg_policies where schemaname = 'nomad_knowflow' and cmd = 'DELETE' and tablename = 'messages' and qual !~ 'chats')
  then raise exception 'knowflow chats/messages delete policy not owner-based'; end if;

  -- 서버 전용 값: authenticated 쓰기 불가
  if exists (select 1 from (values ('nomad_classroom.quiz_attempts'),('nomad_commerce.orders')) v(t)
             where has_table_privilege('authenticated', v.t, 'insert,update,delete')
                or has_any_column_privilege('authenticated', v.t::regclass, 'insert,update')
                or not has_table_privilege('authenticated', v.t, 'select'))
     or exists (select 1 from pg_policies where (schemaname, tablename) in (('nomad_classroom','quiz_attempts'),('nomad_commerce','orders')) and cmd <> 'SELECT')
  then raise exception 'quiz_attempts/commerce.orders must be server-only'; end if;
  if has_column_privilege('authenticated', 'nomad_commerce.automation_jobs', 'credits_used', 'insert,update')
  then raise exception 'authenticated can write credits_used'; end if;
  if has_column_privilege('authenticated', 'nomad_commerce.marketplace_accounts', 'token_ref', 'select,insert,update')
  then raise exception 'authenticated can access token_ref'; end if;
  if has_column_privilege('authenticated', 'nomad_analytics.share_links', 'token', 'insert,update')
     or not has_column_privilege('authenticated', 'nomad_analytics.share_links', 'token', 'select')
  then raise exception 'share_links.token must be server-issued (select only)'; end if;

  -- 멤버·역할 테이블: 쓰기는 owner/admin만 (editor 불가)
  select string_agg(schemaname || '.' || tablename || '.' || policyname, ',') into bad from pg_policies
   where (schemaname, tablename) in (('nomad_contentflow','blog_members'), ('nomad_classroom','enrollments'))
     and cmd in ('INSERT','UPDATE','DELETE')
     and (coalesce(qual,'') || coalesce(with_check,'') ~ 'editor' or coalesce(qual,'') || coalesce(with_check,'') !~ 'admin');
  if bad is not null then raise exception 'member table write not owner/admin only: %', bad; end if;

  -- 서버 전용(baedal 주문류) · 수정 불가(jangter 방·메시지)
  if exists (select 1 from (values ('nomad_baedal.orders'),('nomad_baedal.order_items'),('nomad_baedal.deliveries')) v(t)
             where has_table_privilege('authenticated', v.t, 'insert,update,delete')
                or has_any_column_privilege('authenticated', v.t::regclass, 'insert,update')
                or not has_table_privilege('authenticated', v.t, 'select'))
  then raise exception 'baedal server-only tables grant mismatch'; end if;
  if exists (select 1 from (values ('nomad_jangter.chat_rooms'),('nomad_jangter.messages')) v(t)
             where has_table_privilege('authenticated', v.t, 'delete')
                or has_any_column_privilege('authenticated', v.t::regclass, 'update')
                or not has_table_privilege('authenticated', v.t, 'select,insert'))
  then raise exception 'jangter rooms/messages grant mismatch'; end if;
  if exists (select 1 from pg_policies where schemaname = 'nomad_jangter' and tablename in ('chat_rooms','messages') and cmd in ('UPDATE','DELETE','ALL'))
     or exists (select 1 from pg_policies where schemaname = 'nomad_baedal' and tablename in ('orders','order_items','deliveries') and cmd <> 'SELECT')
  then raise exception 'unexpected write policy on restricted tables'; end if;
end;
$$;

-- 합성 사용자·업체 ---------------------------------------------------------
-- 조직형: a1 alice(A·C owner) a2 bob(B owner) a3 carol(A viewer) a4 dave(A editor) a5 erin(A admin) a6 frank(A viewer)
-- 개인형: b1 판매자 b2 구매자 b3 제3자 / c1 가게주인 c2 구매자 c3 제3자 c4 라이더
insert into auth.users (id) values
 ('00000000-0000-4000-8000-0000000002a1'), ('00000000-0000-4000-8000-0000000002a2'),
 ('00000000-0000-4000-8000-0000000002a3'), ('00000000-0000-4000-8000-0000000002a4'),
 ('00000000-0000-4000-8000-0000000002a5'), ('00000000-0000-4000-8000-0000000002a6'),
 ('00000000-0000-4000-8000-0000000002b1'), ('00000000-0000-4000-8000-0000000002b2'), ('00000000-0000-4000-8000-0000000002b3'),
 ('00000000-0000-4000-8000-0000000002c1'), ('00000000-0000-4000-8000-0000000002c2'),
 ('00000000-0000-4000-8000-0000000002c3'), ('00000000-0000-4000-8000-0000000002c4');
insert into nomad_core.organizations (id, name) values
 ('00000000-0000-4000-8000-00000000020a', '서비스 A 실습 업체'),
 ('00000000-0000-4000-8000-00000000020b', '서비스 B 실습 업체'),
 ('00000000-0000-4000-8000-00000000020c', '서비스 C 실습 업체');
insert into nomad_core.memberships values
 ('00000000-0000-4000-8000-00000000020a', '00000000-0000-4000-8000-0000000002a1', 'owner'),
 ('00000000-0000-4000-8000-00000000020c', '00000000-0000-4000-8000-0000000002a1', 'owner'),
 ('00000000-0000-4000-8000-00000000020b', '00000000-0000-4000-8000-0000000002a2', 'owner'),
 ('00000000-0000-4000-8000-00000000020a', '00000000-0000-4000-8000-0000000002a3', 'viewer'),
 ('00000000-0000-4000-8000-00000000020a', '00000000-0000-4000-8000-0000000002a4', 'editor'),
 ('00000000-0000-4000-8000-00000000020a', '00000000-0000-4000-8000-0000000002a5', 'admin'),
 ('00000000-0000-4000-8000-00000000020a', '00000000-0000-4000-8000-0000000002a6', 'viewer');

-- 격리 검증용: 기능 잠금(구독 없음=C)을 배제하도록 모든 조직×제품에 A 플랜 활성 구독
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
select o.id, p.code, 'A', 'active'
  from nomad_core.organizations o cross join nomad_core.products p
 where o.id in ('00000000-0000-4000-8000-00000000020a', '00000000-0000-4000-8000-00000000020b', '00000000-0000-4000-8000-00000000020c')
   and exists (select 1 from nomad_core.plans pl where pl.product_code = p.code and pl.code = 'A');

create temp table t_ids(slug text, org uuid, parent_id uuid, child_id uuid);
grant all on t_ids to authenticated;

-- 2. 조직형 7개: 서비스별 대표 부모→자식 ------------------------------------
do $$
declare
  a uuid := '00000000-0000-4000-8000-00000000020a';
  b uuid := '00000000-0000-4000-8000-00000000020b';
  c uuid := '00000000-0000-4000-8000-00000000020c';
  alice uuid := '00000000-0000-4000-8000-0000000002a1';
  bob   uuid := '00000000-0000-4000-8000-0000000002a2';
  carol uuid := '00000000-0000-4000-8000-0000000002a3';
  dave  uuid := '00000000-0000-4000-8000-0000000002a4';
  erin  uuid := '00000000-0000-4000-8000-0000000002a5';
  v record; o uuid; pid uuid; cid uuid; newid uuid; tp text; tc text; pa uuid;
begin
  for v in select * from (values
    ('contentflow','blogs','name','''b''','topics','blog_id'),
    ('flora','projects','title','''p''','chapters','project_id'),
    ('knowflow','spaces','name','''s''','sources','space_id'),
    ('classroom','courses','title','''c''','sessions','course_id'),
    ('analytics','projects','name','''p''','datasets','project_id'),
    ('sceneflow','projects','title','''p''','scenes','project_id'),
    ('commerce','products','title, price','''p'', 100','listings','product_id')
  ) t(slug, parent, pcols, pvals, child, fk)
  loop
    tp := format('nomad_%s.%s', v.slug, v.parent);
    tc := format('nomad_%s.%s', v.slug, v.child);

    -- 서버 권한으로 A·B 각각 부모+자식 한 쌍
    reset role;
    foreach o in array array[a, b] loop
      execute format('insert into %s (organization_id, %s) values (%L, %s) returning id', tp, v.pcols, o, v.pvals) into pid;
      execute format('insert into %s (organization_id, %s) values (%L, %L) returning id', tc, v.fk, o, pid) into cid;
      insert into t_ids values (v.slug, o, pid, cid);
    end loop;
    select parent_id into pa from t_ids where slug = v.slug and org = a;
    set local role authenticated;

    -- 타 업체(bob=B): A 조회 0행, 자기 업체 1행, insert·delete 거부
    perform pg_temp.as_user(bob);
    if pg_temp.n(format('select count(*) from %s where organization_id = %L', tc, a)) <> 0
       or pg_temp.n(format('select count(*) from %s where organization_id = %L', tp, a)) <> 0
       or pg_temp.n(format('select count(*) from %s', tc)) <> 1
    then raise exception '[%] cross-tenant read leak', v.slug; end if;
    perform pg_temp.expect_err(format('insert into %s (organization_id, %s) values (%L, %L)', tc, v.fk, a, pa), '%row-level security%');
    if pg_temp.n(format('with d as (delete from %s where organization_id = %L returning 1) select count(*) from d', tc, a)) <> 0
    then raise exception '[%] cross-tenant delete worked', v.slug; end if;

    -- viewer(carol): 조회 가능, insert 거부, 삭제·수정 0행
    perform pg_temp.as_user(carol);
    if pg_temp.n(format('select count(*) from %s where organization_id = %L', tc, a)) <> 1
    then raise exception '[%] viewer cannot read own org', v.slug; end if;
    perform pg_temp.expect_err(format('insert into %s (organization_id, %s) values (%L, %L)', tc, v.fk, a, pa), '%row-level security%');
    if pg_temp.n(format('with d as (delete from %s where organization_id = %L returning 1) select count(*) from d', tc, a)) <> 0
       or pg_temp.n(format('with u as (update %s set %s = %s where organization_id = %L returning 1) select count(*) from u', tc, v.fk, v.fk, a)) <> 0
    then raise exception '[%] viewer write affected rows', v.slug; end if;

    -- editor(dave): insert 성공, delete 0행
    perform pg_temp.as_user(dave);
    execute format('insert into %s (organization_id, %s) values (%L, %L) returning id', tc, v.fk, a, pa) into newid;
    if pg_temp.n(format('with d as (delete from %s where organization_id = %L returning 1) select count(*) from d', tc, a)) <> 0
    then raise exception '[%] editor delete worked', v.slug; end if;

    -- admin(erin): delete 성공(방금 만든 행)
    perform pg_temp.as_user(erin);
    if pg_temp.n(format('with d as (delete from %s where id = %L returning 1) select count(*) from d', tc, newid)) <> 1
    then raise exception '[%] admin delete failed', v.slug; end if;

    -- owner(alice: A·C): 교차 업체 부모 FK 거부, organization_id update 거부, 정상 insert
    perform pg_temp.as_user(alice);
    perform pg_temp.expect_err(format('insert into %s (organization_id, %s) values (%L, %L)', tc, v.fk, c, pa), '%foreign key%');
    perform pg_temp.expect_err(format('update %s set organization_id = %L where id = %L', tc, c, (select child_id from t_ids where slug = v.slug and org = a)), '%permission denied%');
    perform pg_temp.expect_err(format('update %s set organization_id = %L where id = %L', tp, c, pa), '%permission denied%');
    execute format('insert into %s (organization_id, %s) values (%L, %L)', tc, v.fk, a, pa);
    if pg_temp.n(format('select count(*) from %s where organization_id = %L', tc, b)) <> 0
    then raise exception '[%] owner sees other tenant', v.slug; end if;
  end loop;
end;
$$;

-- 3. jangter 두 당사자 -------------------------------------------------------
reset role;
do $$
declare
  j1 uuid := '00000000-0000-4000-8000-0000000002b1';
  j2 uuid := '00000000-0000-4000-8000-0000000002b2';
  j3 uuid := '00000000-0000-4000-8000-0000000002b3';
  lst uuid; hid uuid; room uuid;
begin
  set local role authenticated;
  perform pg_temp.as_user(j1);
  insert into nomad_jangter.listings (title, price) values ('자전거', 50000) returning id into lst;
  insert into nomad_jangter.listings (title, price, status) values ('숨김', 1000, 'hidden') returning id into hid;
  perform pg_temp.expect_err('insert into nomad_jangter.listings (title, price, seller_id) values (''명의도용'', 1, ''00000000-0000-4000-8000-0000000002b2'')', '%row-level security%');
  perform pg_temp.expect_err('insert into nomad_jangter.listings (title, price) values (''음수'', -1)', '%check constraint%');
  insert into nomad_jangter.listing_photos (listing_id, storage_path, "position") values (lst, 'p/1.jpg', 1);

  -- 구매자: 판매중만 보이고 hidden은 안 보임, 남의 글 수정 0행
  perform pg_temp.as_user(j2);
  if pg_temp.n(format('select count(*) from nomad_jangter.listings where id = %L', lst)) <> 1
     or pg_temp.n(format('select count(*) from nomad_jangter.listings where id = %L', hid)) <> 0
     or pg_temp.n(format('select count(*) from nomad_jangter.listing_photos where listing_id = %L', lst)) <> 1
  then raise exception 'jangter listing visibility failed'; end if;
  if pg_temp.n(format('with u as (update nomad_jangter.listings set title = ''x'' where id = %L returning 1) select count(*) from u', lst)) <> 0
  then raise exception 'buyer updated seller listing'; end if;
  perform pg_temp.expect_err(format('insert into nomad_jangter.listing_photos (listing_id, storage_path) values (%L, ''x'')', lst), '%row-level security%');

  -- 채팅방: 타인 명의 · 잘못된 판매자 · 자기 자신 · hidden 글 거부
  perform pg_temp.expect_err(format('insert into nomad_jangter.chat_rooms (listing_id, buyer_id, seller_id) values (%L, %L, %L)', lst, j3, j1), '%row-level security%');
  perform pg_temp.expect_err(format('insert into nomad_jangter.chat_rooms (listing_id, buyer_id, seller_id) values (%L, %L, %L)', lst, j2, j3), '%row-level security%');
  perform pg_temp.expect_err(format('insert into nomad_jangter.chat_rooms (listing_id, buyer_id, seller_id) values (%L, %L, %L)', hid, j2, j1), '%row-level security%');
  perform pg_temp.as_user(j1);
  perform pg_temp.expect_err(format('insert into nomad_jangter.chat_rooms (listing_id, buyer_id, seller_id) values (%L, %L, %L)', lst, j1, j1), '%row-level security%');
  perform pg_temp.as_user(j2);
  insert into nomad_jangter.chat_rooms (listing_id, seller_id) select lst, seller_id from nomad_jangter.listings where id = lst returning id into room;

  -- 메시지: 방 참여자 본인 명의만
  insert into nomad_jangter.messages (room_id, body) values (room, '안녕하세요');
  perform pg_temp.expect_err(format('insert into nomad_jangter.messages (room_id, sender_id, body) values (%L, %L, ''사칭'')', room, j1), '%row-level security%');
  perform pg_temp.as_user(j1);
  insert into nomad_jangter.messages (room_id, body) values (room, '네');
  perform pg_temp.expect_err(format('insert into nomad_jangter.messages (room_id, sender_id, body) values (%L, %L, ''사칭'')', room, j2), '%row-level security%');
  perform pg_temp.as_user(j3);
  perform pg_temp.expect_err(format('insert into nomad_jangter.messages (room_id, body) values (%L, ''끼어들기'')', room), '%row-level security%');
  perform pg_temp.expect_err(format('insert into nomad_jangter.reviews (room_id, score) values (%L, 5)', room), '%row-level security%');

  -- 조회: 판매자·구매자 가능, 제3자 0건
  if pg_temp.n('select count(*) from nomad_jangter.chat_rooms') <> 0
     or pg_temp.n('select count(*) from nomad_jangter.messages') <> 0
  then raise exception 'third party reads room/messages'; end if;
  perform pg_temp.as_user(j1);
  if pg_temp.n('select count(*) from nomad_jangter.chat_rooms') <> 1
     or pg_temp.n('select count(*) from nomad_jangter.messages') <> 2
  then raise exception 'seller cannot read room/messages'; end if;
  perform pg_temp.as_user(j2);
  if pg_temp.n('select count(*) from nomad_jangter.messages') <> 2
  then raise exception 'buyer cannot read messages'; end if;

  -- 방·메시지는 수정·삭제 불가
  perform pg_temp.expect_err('update nomad_jangter.chat_rooms set seller_id = null', '%permission denied%');
  perform pg_temp.expect_err('delete from nomad_jangter.chat_rooms', '%permission denied%');
  perform pg_temp.expect_err('update nomad_jangter.messages set body = ''x''', '%permission denied%');
  perform pg_temp.expect_err('delete from nomad_jangter.messages', '%permission denied%');

  -- 방 (listing_id, buyer_id) 중복 거부
  perform pg_temp.expect_err(format('insert into nomad_jangter.chat_rooms (listing_id, seller_id) values (%L, %L)', lst, j1), '%duplicate key%');

  -- 후기: sold 거래의 참여자만, 방당 1건, 전체 공개 조회
  perform pg_temp.expect_err(format('insert into nomad_jangter.reviews (room_id, score) values (%L, 5)', room), '%row-level security%');
  perform pg_temp.as_user(j1);
  update nomad_jangter.listings set status = 'sold' where id = lst;
  perform pg_temp.as_user(j2);
  insert into nomad_jangter.reviews (room_id, score) values (room, 5);
  perform pg_temp.expect_err(format('insert into nomad_jangter.reviews (room_id, score) values (%L, 4)', room), '%duplicate key%');
  perform pg_temp.as_user(j3);
  perform pg_temp.expect_err(format('insert into nomad_jangter.reviews (room_id, score) values (%L, 5)', room), '%row-level security%');
  if pg_temp.n('select count(*) from nomad_jangter.reviews') <> 1 then raise exception 'reviews not readable'; end if;
  if pg_temp.n('with d as (delete from nomad_jangter.reviews returning 1) select count(*) from d') <> 0
  then raise exception 'third party deleted review'; end if;

  -- 찜: 본인 것만
  perform pg_temp.as_user(j2);
  insert into nomad_jangter.favorites (listing_id) values (lst);
  perform pg_temp.expect_err(format('insert into nomad_jangter.favorites (user_id, listing_id) values (%L, %L)', j3, lst), '%row-level security%');
  perform pg_temp.as_user(j3);
  if pg_temp.n('select count(*) from nomad_jangter.favorites') <> 0 then raise exception 'favorites leak'; end if;
end;
$$;

-- 4. baedal 두 당사자 --------------------------------------------------------
reset role;
do $$
declare
  b1 uuid := '00000000-0000-4000-8000-0000000002c1';
  b2 uuid := '00000000-0000-4000-8000-0000000002c2';
  b3 uuid := '00000000-0000-4000-8000-0000000002c3';
  b4 uuid := '00000000-0000-4000-8000-0000000002c4';
  st uuid; mn uuid; od uuid;
begin
  set local role authenticated;
  perform pg_temp.as_user(b1);
  insert into nomad_baedal.stores (name) values ('실습 분식') returning id into st;
  insert into nomad_baedal.menus (store_id, name, price) values (st, '떡볶이', 4500) returning id into mn;
  perform pg_temp.expect_err('insert into nomad_baedal.stores (name, owner_id) values (''사칭'', ''00000000-0000-4000-8000-0000000002c2'')', '%row-level security%');
  perform pg_temp.as_user(b3);
  perform pg_temp.expect_err(format('insert into nomad_baedal.menus (store_id, name, price) values (%L, ''남의 메뉴'', 1)', st), '%row-level security%');
  if pg_temp.n(format('select count(*) from nomad_baedal.menus where store_id = %L', st)) <> 1
  then raise exception 'menus not public to authenticated'; end if;
  if pg_temp.n(format('with u as (update nomad_baedal.stores set name = ''x'' where id = %L returning 1) select count(*) from u', st)) <> 0
  then raise exception 'third party updated store'; end if;

  -- 서버 권한으로 주문·항목·배달 생성, 멱등 키 유일·필수
  reset role;
  insert into nomad_baedal.orders (buyer_id, store_id, total, idempotency_key) values (b2, st, 4500, 'k-1') returning id into od;
  insert into nomad_baedal.order_items (order_id, menu_id, qty) values (od, mn, 1);
  insert into nomad_baedal.deliveries (order_id, rider_id) values (od, b4);
  perform pg_temp.expect_err(format('insert into nomad_baedal.orders (buyer_id, store_id, total, idempotency_key) values (%L, %L, 1, ''k-1'')', b2, st), '%duplicate key%');
  perform pg_temp.expect_err(format('insert into nomad_baedal.orders (buyer_id, store_id, total) values (%L, %L, 1)', b2, st), '%null value%');
  perform pg_temp.expect_err(format('insert into nomad_baedal.orders (buyer_id, store_id, total, idempotency_key) values (%L, %L, -1, ''k-2'')', b2, st), '%check constraint%');
  set local role authenticated;

  -- 조회: 구매자·가게주인 가능, 제3자 0행, 라이더는 배달만
  perform pg_temp.as_user(b2);
  if pg_temp.n('select count(*) from nomad_baedal.orders') <> 1 or pg_temp.n('select count(*) from nomad_baedal.order_items') <> 1
     or pg_temp.n('select count(*) from nomad_baedal.deliveries') <> 1
  then raise exception 'buyer cannot read own order'; end if;
  perform pg_temp.as_user(b1);
  if pg_temp.n('select count(*) from nomad_baedal.orders') <> 1 or pg_temp.n('select count(*) from nomad_baedal.order_items') <> 1
     or pg_temp.n('select count(*) from nomad_baedal.deliveries') <> 1
  then raise exception 'store owner cannot read order'; end if;
  perform pg_temp.as_user(b3);
  if pg_temp.n('select count(*) from nomad_baedal.orders') <> 0 or pg_temp.n('select count(*) from nomad_baedal.order_items') <> 0
     or pg_temp.n('select count(*) from nomad_baedal.deliveries') <> 0
  then raise exception 'third party reads order data'; end if;
  perform pg_temp.as_user(b4);
  if pg_temp.n('select count(*) from nomad_baedal.deliveries') <> 1 or pg_temp.n('select count(*) from nomad_baedal.orders') <> 0
  then raise exception 'rider visibility wrong'; end if;

  -- authenticated 쓰기 거부(서버 전용)
  perform pg_temp.as_user(b2);
  perform pg_temp.expect_err(format('insert into nomad_baedal.orders (store_id, total, idempotency_key) values (%L, 1, ''k-x'')', st), '%permission denied%');
  perform pg_temp.expect_err('update nomad_baedal.orders set total = 0', '%permission denied%');
  perform pg_temp.expect_err('update nomad_baedal.orders set status = ''delivered''', '%permission denied%');
  perform pg_temp.expect_err('delete from nomad_baedal.orders', '%permission denied%');
  perform pg_temp.expect_err(format('insert into nomad_baedal.order_items (order_id, qty) values (%L, 1)', od), '%permission denied%');
  perform pg_temp.expect_err('update nomad_baedal.deliveries set status = ''delivered''', '%permission denied%');

  -- 후기: 배달완료 주문의 구매자만, 주문당 1건
  perform pg_temp.as_user(b2);
  perform pg_temp.expect_err(format('insert into nomad_baedal.reviews (order_id, rating) values (%L, 5)', od), '%row-level security%');
  reset role;
  update nomad_baedal.orders set status = 'delivered' where id = od;
  set local role authenticated;
  perform pg_temp.as_user(b3);
  perform pg_temp.expect_err(format('insert into nomad_baedal.reviews (order_id, rating) values (%L, 5)', od), '%row-level security%');
  perform pg_temp.as_user(b1);
  perform pg_temp.expect_err(format('insert into nomad_baedal.reviews (order_id, rating) values (%L, 5)', od), '%row-level security%');
  perform pg_temp.as_user(b2);
  perform pg_temp.expect_err(format('insert into nomad_baedal.reviews (order_id, writer_id, rating) values (%L, %L, 5)', od, b3), '%row-level security%');
  perform pg_temp.expect_err(format('insert into nomad_baedal.reviews (order_id, rating) values (%L, 6)', od), '%check constraint%');
  insert into nomad_baedal.reviews (order_id, rating) values (od, 5);
  perform pg_temp.expect_err(format('insert into nomad_baedal.reviews (order_id, rating) values (%L, 4)', od), '%duplicate key%');
  -- 조회: 작성자·가게주인만
  if pg_temp.n('select count(*) from nomad_baedal.reviews') <> 1 then raise exception 'writer cannot read review'; end if;
  perform pg_temp.as_user(b1);
  if pg_temp.n('select count(*) from nomad_baedal.reviews') <> 1 then raise exception 'store owner cannot read review'; end if;
  perform pg_temp.as_user(b4);
  if pg_temp.n('select count(*) from nomad_baedal.reviews') <> 0 then raise exception 'rider reads baedal review'; end if;
  perform pg_temp.as_user(b3);
  if pg_temp.n('select count(*) from nomad_baedal.reviews') <> 0 then raise exception 'third party reads baedal review'; end if;
  if pg_temp.n('with d as (delete from nomad_baedal.reviews returning 1) select count(*) from d') <> 0
  then raise exception 'third party deleted baedal review'; end if;
end;
$$;

-- 5. classroom: viewer 학생의 자기 기록 -------------------------------------
reset role;
do $$
declare
  a uuid := '00000000-0000-4000-8000-00000000020a';
  b uuid := '00000000-0000-4000-8000-00000000020b';
  carol uuid := '00000000-0000-4000-8000-0000000002a3';
  frank uuid := '00000000-0000-4000-8000-0000000002a6';
  dave  uuid := '00000000-0000-4000-8000-0000000002a4';
  bob   uuid := '00000000-0000-4000-8000-0000000002a2';
  course uuid; s_open uuid; s_closed uuid;
begin
  -- 점수는 서버 전용: 서버가 기록, authenticated는 쓰기 거부
  reset role;
  insert into nomad_classroom.quiz_attempts (organization_id, student_id, level, score) values (a, carol, 1, 80), (a, frank, 2, 70);
  set local role authenticated;
  perform pg_temp.as_user(carol);
  perform pg_temp.expect_err(format('insert into nomad_classroom.quiz_attempts (organization_id, student_id, score) values (%L, %L, 100)', a, carol), '%permission denied%');
  perform pg_temp.expect_err('update nomad_classroom.quiz_attempts set score = 100', '%permission denied%');
  perform pg_temp.expect_err('delete from nomad_classroom.quiz_attempts', '%permission denied%');

  -- 학생은 자기 기록만, 편집자는 전체, 타 업체는 0
  perform pg_temp.as_user(carol);
  if pg_temp.n('select count(*) from nomad_classroom.quiz_attempts') <> 1
     or pg_temp.n(format('select count(*) from nomad_classroom.quiz_attempts where student_id = %L', frank)) <> 0
     or pg_temp.n(format('select count(*) from nomad_classroom.quiz_attempts where student_id = %L', carol)) <> 1
  then raise exception 'student sees others attempts'; end if;
  perform pg_temp.as_user(frank);
  if pg_temp.n('select count(*) from nomad_classroom.quiz_attempts') <> 1 then raise exception 'frank own attempts wrong'; end if;
  perform pg_temp.as_user(dave);
  if pg_temp.n('select count(*) from nomad_classroom.quiz_attempts') <> 2 then raise exception 'editor cannot see all attempts'; end if;
  perform pg_temp.as_user(bob);
  if pg_temp.n('select count(*) from nomad_classroom.quiz_attempts') <> 0 then raise exception 'other tenant sees attempts'; end if;

  -- 미공개 자료·숨김 문제: viewer 0행, editor 가시
  reset role;
  select parent_id into course from t_ids where slug = 'classroom' and org = a;
  insert into nomad_classroom.sessions (organization_id, course_id, open_at) values (a, course, now() + interval '1 day') returning id into s_closed;
  insert into nomad_classroom.sessions (organization_id, course_id, open_at) values (a, course, now() - interval '1 day') returning id into s_open;
  insert into nomad_classroom.materials (organization_id, session_id, file_path) values (a, s_closed, 'closed.pdf'), (a, s_open, 'open.pdf');
  insert into nomad_classroom.quiz_items (organization_id, is_hidden) values (a, true), (a, false);
  set local role authenticated;
  perform pg_temp.as_user(carol);
  if pg_temp.n(format('select count(*) from nomad_classroom.materials where session_id = %L', s_closed)) <> 0
     or pg_temp.n(format('select count(*) from nomad_classroom.materials where session_id = %L', s_open)) <> 1
     or pg_temp.n('select count(*) from nomad_classroom.quiz_items where is_hidden') <> 0
     or pg_temp.n('select count(*) from nomad_classroom.quiz_items') <> 1
  then raise exception 'viewer sees unpublished material/hidden quiz'; end if;
  perform pg_temp.as_user(dave);
  if pg_temp.n(format('select count(*) from nomad_classroom.materials where session_id = %L', s_closed)) <> 1
     or pg_temp.n('select count(*) from nomad_classroom.quiz_items') <> 2
  then raise exception 'editor cannot see unpublished material/hidden quiz'; end if;

  -- 수강 등록: 조직 멤버만
  perform pg_temp.as_user('00000000-0000-4000-8000-0000000002a1');
  perform pg_temp.expect_err(format('insert into nomad_classroom.enrollments (organization_id, course_id, student_id) values (%L, %L, %L)', a, course, '00000000-0000-4000-8000-0000000002b1'), '%foreign key%');
  execute format('insert into nomad_classroom.enrollments (organization_id, course_id, student_id) values (%L, %L, %L)', a, course, carol);
end;
$$;

-- 6. 리뷰 반영 항목: contentflow·knowflow·commerce·analytics ----------------
reset role;
do $$
declare
  a uuid := '00000000-0000-4000-8000-00000000020a';
  alice uuid := '00000000-0000-4000-8000-0000000002a1';
  carol uuid := '00000000-0000-4000-8000-0000000002a3';
  erin  uuid := '00000000-0000-4000-8000-0000000002a5';
  frank uuid := '00000000-0000-4000-8000-0000000002a6';
  blog uuid; prv uuid; chat uuid; dash uuid; proj uuid; tok text; u uuid;
begin
  select parent_id into blog from t_ids where slug = 'contentflow' and org = a;
  select parent_id into proj from t_ids where slug = 'analytics' and org = a;
  set local role authenticated;

  -- blog_members: 비멤버 등록 FK 거부, 멤버는 가능
  perform pg_temp.as_user(alice);
  perform pg_temp.expect_err(format('insert into nomad_contentflow.blog_members (organization_id, blog_id, user_id) values (%L, %L, %L)', a, blog, '00000000-0000-4000-8000-0000000002b1'), '%foreign key%');
  execute format('insert into nomad_contentflow.blog_members (organization_id, blog_id, user_id) values (%L, %L, %L)', a, blog, carol);

  -- knowflow: 비공개 space는 owner/admin만, 개인 대화는 본인만, messages insert는 role=user만
  insert into nomad_knowflow.spaces (organization_id, name, visibility) values (a, '비공개', 'private') returning id into prv;
  insert into nomad_knowflow.sources (organization_id, space_id) values (a, prv);
  perform pg_temp.as_user(carol);
  if pg_temp.n(format('select count(*) from nomad_knowflow.spaces where id = %L', prv)) <> 0
     or pg_temp.n(format('select count(*) from nomad_knowflow.sources where space_id = %L', prv)) <> 0
     or pg_temp.n('select count(*) from nomad_knowflow.spaces') <> 1
  then raise exception 'viewer sees private space'; end if;
  perform pg_temp.as_user(erin);
  if pg_temp.n(format('select count(*) from nomad_knowflow.spaces where id = %L', prv)) <> 1
  then raise exception 'admin cannot see private space'; end if;

  perform pg_temp.as_user(carol);
  insert into nomad_knowflow.chats (organization_id, title) values (a, 'carol 대화') returning id into chat;
  insert into nomad_knowflow.messages (organization_id, chat_id, role) values (a, chat, 'user');
  perform pg_temp.expect_err(format('insert into nomad_knowflow.messages (organization_id, chat_id, role) values (%L, %L, ''assistant'')', a, chat), '%row-level security%');
  perform pg_temp.expect_err(format('insert into nomad_knowflow.messages (organization_id, chat_id) values (%L, %L)', a, chat), '%row-level security%');
  foreach u in array array[frank, alice, erin] loop
    perform pg_temp.as_user(u);
    if pg_temp.n('select count(*) from nomad_knowflow.chats') <> 0 or pg_temp.n('select count(*) from nomad_knowflow.messages') <> 0
    then raise exception 'others see personal chat'; end if;
    if pg_temp.n('with d as (delete from nomad_knowflow.chats returning 1) select count(*) from d') <> 0
    then raise exception 'others deleted personal chat'; end if;
    perform pg_temp.expect_err(format('insert into nomad_knowflow.messages (organization_id, chat_id, role) values (%L, %L, ''user'')', a, chat), '%row-level security%');
  end loop;

  -- commerce: 주문 쓰기·크레딧 컬럼·토큰 컬럼
  perform pg_temp.as_user(alice);
  perform pg_temp.expect_err(format('insert into nomad_commerce.orders (organization_id, total) values (%L, 1)', a), '%permission denied%');
  perform pg_temp.expect_err('update nomad_commerce.orders set total = 0', '%permission denied%');
  perform pg_temp.expect_err('delete from nomad_commerce.orders', '%permission denied%');
  perform pg_temp.expect_err(format('insert into nomad_commerce.automation_jobs (organization_id, credits_used) values (%L, 0)', a), '%permission denied%');
  execute format('insert into nomad_commerce.automation_jobs (organization_id, kind) values (%L, ''image'')', a);
  perform pg_temp.expect_err('update nomad_commerce.automation_jobs set credits_used = 0', '%permission denied%');
  execute format('insert into nomad_commerce.marketplace_accounts (organization_id, marketplace) values (%L, ''x'')', a);
  perform pg_temp.expect_err('select token_ref from nomad_commerce.marketplace_accounts', '%permission denied%');
  perform pg_temp.expect_err('select * from nomad_commerce.marketplace_accounts', '%permission denied%');
  perform pg_temp.expect_err(format('insert into nomad_commerce.marketplace_accounts (organization_id, marketplace, token_ref) values (%L, ''y'', ''t'')', a), '%permission denied%');
  if pg_temp.n('select count(id) from nomad_commerce.marketplace_accounts') <> 1 then raise exception 'marketplace_accounts id not readable'; end if;

  -- analytics share_links: 토큰은 서버 발급(default)
  insert into nomad_analytics.dashboards (organization_id, project_id, name) values (a, proj, 'd') returning id into dash;
  insert into nomad_analytics.share_links (organization_id, dashboard_id) values (a, dash) returning token into tok;
  if tok is null or length(tok) <> 48 then raise exception 'share token not issued by default'; end if;
  perform pg_temp.expect_err(format('insert into nomad_analytics.share_links (organization_id, dashboard_id, token) values (%L, %L, ''mine'')', a, dash), '%permission denied%');
  perform pg_temp.expect_err('update nomad_analytics.share_links set token = ''mine''', '%permission denied%');
end;
$$;

rollback;
