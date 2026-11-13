-- 가입 트리거 · 1인/팀 조직 · 초대 · 크레딧 검증 (합성 데이터, 롤백)
\o /dev/null
begin;

-- 실패 경로 확인 도우미: 문장이 반드시 실패하고 메시지가 패턴과 맞아야 한다.
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

create temp table t_ctx (k text primary key, v text);
grant all on t_ctx to authenticated;

-- 합성 사용자: a1 alice(owner) a2 bob a3 carol a4 dave(미인증) a5 익명 a6 erin a7 frank a8 이름·이메일 없음
insert into auth.users (id, email, email_confirmed_at, is_anonymous, raw_user_meta_data) values
 ('00000000-0000-4000-8000-0000000000a1', 'alice@example.test', now(), false, '{"name":"앨리스"}'),
 ('00000000-0000-4000-8000-0000000000a2', 'bob@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a3', 'carol@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a4', 'dave@example.test', null, false, '{}'),
 ('00000000-0000-4000-8000-0000000000a5', null, null, true, '{}'),
 ('00000000-0000-4000-8000-0000000000a6', 'erin@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a7', 'frank@example.test', now(), false, '{}'),
 ('00000000-0000-4000-8000-0000000000a8', null, null, false, '{}');

-- 1. 가입: 프로필 + personal 조직 + owner, 익명 제외
do $$
begin
  if (select display_name from nomad_core.profiles where user_id = '00000000-0000-4000-8000-0000000000a1') <> '앨리스'
     or (select display_name from nomad_core.profiles where user_id = '00000000-0000-4000-8000-0000000000a2') <> 'bob'
     or (select display_name from nomad_core.profiles where user_id = '00000000-0000-4000-8000-0000000000a8') <> '내 워크스페이스'
  then raise exception 'profile display_name fallback failed'; end if;
  if (select count(*) from nomad_core.memberships m join nomad_core.organizations o on o.id = m.organization_id
      where m.user_id = '00000000-0000-4000-8000-0000000000a1' and m.role = 'owner'
        and o.kind = 'personal' and o.seat_limit = 1 and o.created_by = m.user_id) <> 1
  then raise exception 'personal organization/owner not created'; end if;
  if exists (select 1 from nomad_core.profiles where user_id = '00000000-0000-4000-8000-0000000000a5')
     or exists (select 1 from nomad_core.memberships where user_id = '00000000-0000-4000-8000-0000000000a5')
     or exists (select 1 from nomad_core.organizations where created_by = '00000000-0000-4000-8000-0000000000a5')
  then raise exception 'anonymous user must not get profile/organization'; end if;
end;
$$;

-- 2. 팀 조직 생성
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);
select pg_temp.expect_err($q$select public.nomad_create_team_organization('무인증 팀')$q$, '%not authenticated%');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err($q$select public.nomad_create_team_organization('   ')$q$, '%organization name required%');
insert into t_ctx select 'team', public.nomad_create_team_organization('  앨리스 팀  ')::text;
insert into t_ctx select 'personal', id::text from public.nomad_my_organizations() where kind = 'personal';
do $$
begin
  if (select count(*) from public.nomad_my_organizations()) <> 2
     or not exists (select 1 from public.nomad_my_organizations()
                    where id = (select v::uuid from t_ctx where k = 'team') and name = '앨리스 팀' and kind = 'team' and role = 'owner')
  then raise exception 'team organization creation/listing failed'; end if;
end;
$$;

-- 테이블 직접 접근 불가 (초대·원장은 함수로만)
select pg_temp.expect_err($q$select * from nomad_core.invitations$q$, '%permission denied%');
select pg_temp.expect_err($q$select * from nomad_core.credit_ledger$q$, '%permission denied%');

-- 3. 초대 생성 권한·검증 (좌석 한도 2로 설정)
reset role;
update nomad_core.organizations set seat_limit = 2 where id = (select v::uuid from t_ctx where k = 'team');
set local role authenticated;

select pg_temp.expect_err(format($q$select public.nomad_create_invitation(%L, 'bob@example.test', 'editor')$q$, (select v from t_ctx where k = 'personal')), '%upgrade required%');
select pg_temp.expect_err(format($q$select public.nomad_create_invitation(%L, 'bob@example.test', 'owner')$q$, (select v from t_ctx where k = 'team')), '%invalid role%');
select pg_temp.expect_err(format($q$select public.nomad_create_invitation(%L, ' ALICE@example.test ', 'viewer')$q$, (select v from t_ctx where k = 'team')), '%already a member%');

insert into t_ctx select 'tokA', public.nomad_create_invitation((select v::uuid from t_ctx where k = 'team'), '  Bob@Example.TEST ', 'editor');
insert into t_ctx select 'tokC', public.nomad_create_invitation((select v::uuid from t_ctx where k = 'team'), 'carol@example.test', 'viewer');
insert into t_ctx select 'tokD', public.nomad_create_invitation((select v::uuid from t_ctx where k = 'team'), 'dave@example.test', 'viewer');
do $$ begin
  if length((select v from t_ctx where k = 'tokA')) <> 64 then raise exception 'token format'; end if;
end $$;

-- 좌석 한도: owner 1 + 대기 editor 1 = 2 → 추가 admin 초대 거부 (viewer는 위에서 허용됨)
select pg_temp.expect_err(format($q$select public.nomad_create_invitation(%L, 'erin@example.test', 'admin')$q$, (select v from t_ctx where k = 'team')), '%seat limit reached%');

-- 비회원(frank): 다른 조직 초대·초대 취소·차감 불가, 잔액 조회 null
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a7', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a7","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_create_invitation(%L, 'frank@example.test', 'viewer')$q$, (select v from t_ctx where k = 'team')), '%forbidden%');
select pg_temp.expect_err($q$select public.nomad_revoke_invitation(gen_random_uuid())$q$, '%forbidden%');
select pg_temp.expect_err(format($q$select public.nomad_spend_credits(%L, 1, 'x', 'k-frank')$q$, (select v from t_ctx where k = 'team')), '%forbidden%');
do $$ begin
  if public.nomad_credit_balance((select v::uuid from t_ctx where k = 'team')) is not null
  then raise exception 'non-member can read balance'; end if;
end $$;

-- 4. 초대 수락
-- carol이 bob 토큰 사용 → 이메일 불일치 / 없는 토큰
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_accept_invitation(%L)$q$, (select v from t_ctx where k = 'tokA')), '%email mismatch%');
select pg_temp.expect_err($q$select public.nomad_accept_invitation('no-such-token')$q$, '%invalid invitation%');
-- 비인증 호출
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);
select pg_temp.expect_err(format($q$select public.nomad_accept_invitation(%L)$q$, (select v from t_ctx where k = 'tokA')), '%not authenticated%');
-- dave: 이메일 미인증
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a4', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a4","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_accept_invitation(%L)$q$, (select v from t_ctx where k = 'tokD')), '%email not confirmed%');
-- bob 수락 성공, 재사용 거부
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}', true);
do $$ begin
  if public.nomad_accept_invitation((select v from t_ctx where k = 'tokA')) <> (select v::uuid from t_ctx where k = 'team')
  then raise exception 'accept returned wrong organization'; end if;
  if not exists (select 1 from public.nomad_my_organizations()
                 where id = (select v::uuid from t_ctx where k = 'team') and role = 'editor')
  then raise exception 'accept invitation failed'; end if;
end $$;
select pg_temp.expect_err(format($q$select public.nomad_accept_invitation(%L)$q$, (select v from t_ctx where k = 'tokA')), '%invalid invitation%');
-- editor는 초대 불가
select pg_temp.expect_err(format($q$select public.nomad_create_invitation(%L, 'erin@example.test', 'viewer')$q$, (select v from t_ctx where k = 'team')), '%forbidden%');

-- carol(viewer) 수락 성공
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}', true);
do $$ begin
  perform public.nomad_accept_invitation((select v from t_ctx where k = 'tokC'));
  if not exists (select 1 from public.nomad_my_organizations() where kind = 'team' and role = 'viewer')
  then raise exception 'viewer accept failed'; end if;
end $$;

-- 만료·수락 시 좌석 한도 (고정 초대를 서버 권한으로 삽입)
reset role;
insert into nomad_core.invitations (organization_id, email, role, token, expires_at) values
 ((select v::uuid from t_ctx where k = 'team'), 'erin@example.test', 'viewer', 'tok-expired', now() - interval '1 minute'),
 ((select v::uuid from t_ctx where k = 'team'), 'frank@example.test', 'editor', 'tok-seat', now() + interval '1 day');
insert into t_ctx select 'inv-seat', id::text from nomad_core.invitations where token = 'tok-seat';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a6', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a6","role":"authenticated"}', true);
select pg_temp.expect_err($q$select public.nomad_accept_invitation('tok-expired')$q$, '%invitation expired%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a7', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a7","role":"authenticated"}', true);
select pg_temp.expect_err($q$select public.nomad_accept_invitation('tok-seat')$q$, '%seat limit reached%');

-- 초대 취소: editor(bob) 거부, owner(alice) 성공
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_revoke_invitation(%L)$q$, (select v from t_ctx where k = 'inv-seat')), '%forbidden%');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select public.nomad_revoke_invitation((select v::uuid from t_ctx where k = 'inv-seat'));
reset role;
do $$ begin
  if exists (select 1 from nomad_core.invitations where token = 'tok-seat') then raise exception 'revoke failed'; end if;
end $$;

-- 5. 크레딧 (서버 권한으로 충전)
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'team');
begin
  if nomad_core.grant_credits(org, 100, 'seed', 'g1') <> 100 then raise exception 'grant failed'; end if;
  if nomad_core.grant_credits(org, 100, 'seed', 'g1') <> 100
     or (select count(*) from nomad_core.credit_ledger where organization_id = org) <> 1
  then raise exception 'grant idempotency failed'; end if;
  perform pg_temp.expect_err(format('select nomad_core.grant_credits(%L, 50, ''seed'', ''g1'')', org), '%idempotency key reused%');
  perform pg_temp.expect_err(format('select nomad_core.grant_credits(%L, 0, ''seed'', ''g0'')', org), '%amount must be positive%');
end $$;

-- 일반 사용자는 grant_credits 실행 불가
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select nomad_core.grant_credits(%L, 999, 'self', 'gx')$q$, (select v from t_ctx where k = 'team')), '%permission denied%');

-- bob(editor) 차감: 정상 · 멱등 재시도 · 키 재사용 불일치 · 잔액 부족 · 0 이하 · 잔액 전액
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a2","role":"authenticated"}', true);
do $$
declare org uuid := (select v::uuid from t_ctx where k = 'team');
begin
  if public.nomad_spend_credits(org, 30, 'use', 's1') <> 70 then raise exception 'spend failed'; end if;
  if public.nomad_spend_credits(org, 30, 'use', 's1') <> 70 or public.nomad_credit_balance(org) <> 70
  then raise exception 'spend idempotency failed (double charge)'; end if;
  perform pg_temp.expect_err(format('select public.nomad_spend_credits(%L, 31, ''use'', ''s1'')', org), '%idempotency key reused%');
  perform pg_temp.expect_err(format('select public.nomad_spend_credits(%L, 71, ''use'', ''s2'')', org), '%insufficient credits%');
  perform pg_temp.expect_err(format('select public.nomad_spend_credits(%L, 0, ''use'', ''s3'')', org), '%amount must be positive%');
  perform pg_temp.expect_err(format('select public.nomad_spend_credits(%L, -5, ''use'', ''s4'')', org), '%amount must be positive%');
  if public.nomad_spend_credits(org, 70, 'use', 's5') <> 0 then raise exception 'exact-balance spend failed'; end if;
end $$;

-- carol(viewer): 차감 불가, 잔액 조회 가능
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true),
       set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a3","role":"authenticated"}', true);
select pg_temp.expect_err(format($q$select public.nomad_spend_credits(%L, 1, 'use', 's6')$q$, (select v from t_ctx where k = 'team')), '%forbidden%');
do $$ begin
  if public.nomad_credit_balance((select v::uuid from t_ctx where k = 'team')) <> 0 then raise exception 'viewer balance'; end if;
end $$;

rollback;
