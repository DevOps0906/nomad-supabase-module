-- live-poll org안 검사: 조직 2곳 교차 접근 거부 · 역할(owner/editor/viewer) · 청중 공개 RPC(D8, anon) · 투표·Q&A·차단 · 플랜 한도·기능 잠금 · 함수 권한 · 동기화 컬럼.
-- 합성 데이터만. 실행: bash products/poll/run_check.sh  (begin → 청사진 drop → 임시 touch_updated_at → org/0001·0002 → 이 파일 → rollback)

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
-- 청중 RPC 의 {ok, code} 결과 확인
create function zz_check.ok_code(q text, want text) returns void language plpgsql as $$
declare r jsonb; begin execute q into r;
  if coalesce(r ->> 'code', 'OK') is distinct from want then raise exception 'EXPECT code % got % for %', want, r, q; end if; end $$;
create function zz_check.login(u text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

create temp table t_ids (k text primary key, v text);
grant all on t_ids to public;

-- ---- 합성 데이터: 조직 A(a1 owner · a3 editor · a5 viewer), 조직 B(a2 owner) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'a2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@example.test'), ('00000000-0000-0000-0000-0000000000a5', 'a5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');

-- ==== 1. 조직 A owner(a1): 행사·문항·선택지 만들고 진행 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
insert into t_ids select 'e1', id::text from nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', '  A 행사  ', '설명');
select zz_check.expect($$select count(*) from nomad_poll.events where title = 'A 행사' and status = 'draft'$$, 1);
insert into nomad_poll.polls (organization_id, event_id, title) values ('00000000-0000-0000-0000-00000000000a', (select v::uuid from t_ids where k = 'e1'), '좋아하는 색');
insert into t_ids select 'p1', id::text from nomad_poll.polls where title = '좋아하는 색';
select zz_check.fails_with($$select nomad_poll.transition_poll((select v::uuid from t_ids where k = 'p1'), 'open')$$, 'PL002');
insert into nomad_poll.poll_options (organization_id, poll_id, position, label) values
  ('00000000-0000-0000-0000-00000000000a', (select v::uuid from t_ids where k = 'p1'), 1, '빨강'),
  ('00000000-0000-0000-0000-00000000000a', (select v::uuid from t_ids where k = 'p1'), 2, '파랑');
insert into t_ids select 'o1', id::text from nomad_poll.poll_options where label = '빨강';
select nomad_poll.transition_event((select v::uuid from t_ids where k = 'e1'), 'live');
select nomad_poll.transition_poll((select v::uuid from t_ids where k = 'p1'), 'open');
-- 열린 문항은 RLS(draft 만 수정)로 0행 갱신
update nomad_poll.polls set title = '바뀐 제목';
select zz_check.expect($$select count(*) from nomad_poll.polls where title = '좋아하는 색'$$, 1);
-- 플랜 한도: 기본 max_live_events 1 → 두 번째 행사 live 거부
insert into t_ids select 'e2', id::text from nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', 'A 행사 2');
select zz_check.fails_with($$select nomad_poll.transition_event((select v::uuid from t_ids where k = 'e2'), 'live')$$, 'PL012');
select zz_check.fails_with($$select nomad_poll.transition_event((select v::uuid from t_ids where k = 'e2'), 'ended')$$, 'PL011');
insert into nomad_poll.banned_words (organization_id, word) values ('00000000-0000-0000-0000-00000000000a', '금지어');
reset role;
insert into t_ids select 'code1', code from nomad_poll.events where id = (select v::uuid from t_ids where k = 'e1');

-- ==== 2. 청중(anon): 테이블 접근 없음, 공개 RPC 만 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_poll.events');
select zz_check.denied('select count(*) from nomad_poll.participants');
select zz_check.denied('select count(*) from nomad_poll.votes');
select zz_check.denied('select count(*) from nomad_poll_private.rate_limits');
select zz_check.denied($$select nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', 'x')$$);
select zz_check.denied($$select nomad_poll.collect_broadcasts()$$);
select zz_check.denied($$select nomad_poll.purge_expired_events()$$);
select zz_check.denied($$select nomad_poll.resolve_participant(repeat('a', 40))$$);
select zz_check.fails_with($$select nomad_poll.join_event('000000', 'short')$$, 'bad token');
select zz_check.ok_code($$select nomad_poll.join_event('12ab56', repeat('t', 40))$$, 'PL007');
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code1'), repeat('t', 40), '나쁜금지어')$$, 'PL008');
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code1'), repeat('t', 40), '청중1')$$, 'OK');
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code1'), repeat('u', 40), '청중2')$$, 'OK');
select zz_check.ok_code($$select nomad_poll.cast_vote(repeat('t', 40), (select v::uuid from t_ids where k = 'p1'), array[(select v::uuid from t_ids where k = 'o1')])$$, 'OK');
select zz_check.ok_code($$select nomad_poll.cast_vote(repeat('t', 40), (select v::uuid from t_ids where k = 'p1'), array[(select v::uuid from t_ids where k = 'o1')])$$, 'PL005');
select zz_check.ok_code($$select nomad_poll.cast_vote(repeat('u', 40), (select v::uuid from t_ids where k = 'p1'), array[gen_random_uuid()])$$, 'PL007');
select zz_check.ok_code($$select nomad_poll.cast_vote(repeat('z', 40), (select v::uuid from t_ids where k = 'p1'), array[(select v::uuid from t_ids where k = 'o1')])$$, 'PL009');
select zz_check.ok_code($$select nomad_poll.ask_question(repeat('t', 40), '좋은 질문입니다')$$, 'OK');
-- 금칙어 질문은 숨김 저장되지만 작성자에게는 pending 으로 보인다
select zz_check.expect($$select (nomad_poll.ask_question(repeat('t', 40), '이건 금지어 포함') ->> 'status' = 'pending')::int$$, 1);
select zz_check.expect($$select (nomad_poll.participant_snapshot(repeat('t', 40)) is not null)::int$$, 1);
reset role;
insert into t_ids select 'q1', id::text from nomad_poll.qna_questions where status = 'visible';
insert into t_ids select 'pa1', id::text from nomad_poll.participants where nickname = '청중1';
set local role anon;
select zz_check.ok_code($$select nomad_poll.upvote_question(repeat('u', 40), (select v::uuid from t_ids where k = 'q1'))$$, 'OK');
reset role;
select zz_check.expect($$select count(*) from nomad_poll.qna_questions where status = 'hidden' and hidden_reason = 'banned_word'$$, 1);
select zz_check.expect($$select count(*) from nomad_poll.participants where token_hash = repeat('t', 40)$$, 0);

-- ==== 3. 조직 B owner(a2): 조직 A 전부 안 보이고 쓰기·RPC 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a2');
select zz_check.expect($$select count(*) from nomad_poll.events$$, 0);
select zz_check.expect($$select count(*) from nomad_poll.polls$$, 0);
select zz_check.expect($$select count(*) from nomad_poll.participants$$, 0);
select zz_check.expect($$select count(*) from nomad_poll.votes$$, 0);
select zz_check.expect($$select count(*) from nomad_poll.qna_questions$$, 0);
select zz_check.expect($$select count(*) from nomad_poll.banned_words$$, 0);
select zz_check.denied($$insert into nomad_poll.polls (organization_id, event_id, title) values ('00000000-0000-0000-0000-00000000000a', (select v::uuid from t_ids where k = 'e1'), 'evil')$$);
select zz_check.denied($$insert into nomad_poll.banned_words (organization_id, word) values ('00000000-0000-0000-0000-00000000000a', 'evil')$$);
update nomad_poll.events set title = 'hacked';
select zz_check.fails_with($$select nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', 'evil')$$, 'not a member');
select zz_check.fails_with($$select nomad_poll.transition_event((select v::uuid from t_ids where k = 'e1'), 'ended')$$, 'not a member');
select zz_check.fails_with($$select nomad_poll.transition_poll((select v::uuid from t_ids where k = 'p1'), 'closed')$$, 'not a member');
select zz_check.fails_with($$select nomad_poll.moderate_question((select v::uuid from t_ids where k = 'q1'), 'hidden')$$, 'not a member');
select zz_check.fails_with($$select nomad_poll.block_participant((select v::uuid from t_ids where k = 'pa1'))$$, 'not a member');
select zz_check.fails_with($$select nomad_poll.rotate_overlay_key((select v::uuid from t_ids where k = 'e1'))$$, 'not a member');
select zz_check.fails_with($$select nomad_poll.set_event_passcode((select v::uuid from t_ids where k = 'e1'), '1234')$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_poll.delete_event((select v::uuid from t_ids where k = 'e1'))$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_poll.host_poll_results((select v::uuid from t_ids where k = 'p1'))$$, 'not a member');
-- B 자기 조직 행사는 만들 수 있다
select nomad_poll.create_event('00000000-0000-0000-0000-00000000000b', 'B 행사');
select zz_check.expect($$select count(*) from nomad_poll.events$$, 1);
reset role;
select zz_check.expect($$select count(*) from nomad_poll.events where title = 'hacked'$$, 0);

-- ==== 4. 조직 A viewer(a5): 읽기만 / editor(a3): 진행 가능, owner 전용 거부 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a5');
select zz_check.expect($$select count(*) from nomad_poll.events$$, 2);
select zz_check.expect($$select count(*) from nomad_poll.votes$$, 1);
select zz_check.denied($$select token_hash from nomad_poll.participants$$);
select zz_check.fails_with($$select nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', 'viewer')$$, 'not a member');
select zz_check.denied($$insert into nomad_poll.polls (organization_id, event_id, title) values ('00000000-0000-0000-0000-00000000000a', (select v::uuid from t_ids where k = 'e1'), 'viewer')$$);
select zz_check.fails_with($$select nomad_poll.moderate_question((select v::uuid from t_ids where k = 'q1'), 'answered')$$, 'not a member');
select zz_check.login('00000000-0000-0000-0000-0000000000a3');
select nomad_poll.moderate_question((select v::uuid from t_ids where k = 'q1'), 'answered');
select zz_check.fails_with($$select nomad_poll.set_event_passcode((select v::uuid from t_ids where k = 'e1'), '1234')$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_poll.delete_event((select v::uuid from t_ids where k = 'e2'))$$, 'owner/admin only');
select zz_check.expect($$select count(*) from nomad_poll.audit_logs$$, 0);
reset role;

-- ==== 5. owner(a1): 차단 → 청중 거부, 문항 종료 → 확정 집계, 비밀번호 입장 ====
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select nomad_poll.block_participant((select v::uuid from t_ids where k = 'pa1'));
select zz_check.expect($$select count(*) from nomad_poll.qna_questions where hidden_reason = 'blocked_participant'$$, 1);
select zz_check.expect($$select (nomad_poll.host_poll_results((select v::uuid from t_ids where k = 'p1')) is not null)::int$$, 1);
select nomad_poll.transition_poll((select v::uuid from t_ids where k = 'p1'), 'closed');
select zz_check.expect($$select count(*) from nomad_poll.poll_results$$, 1);
select nomad_poll.set_event_passcode((select v::uuid from t_ids where k = 'e1'), '4321');
-- 감사 8건: 행사 생성 2 · live · 문항 open·closed · 답변 처리(a3) · 차단 · 비밀번호
select zz_check.expect($$select count(*) from nomad_poll.audit_logs where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 8);
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.ok_code($$select nomad_poll.ask_question(repeat('t', 40), '차단 후 질문')$$, 'PL009');
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code1'), repeat('v', 40), '청중3', null, '0000')$$, 'PL013');
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code1'), repeat('v', 40), '청중3', null, '4321')$$, 'OK');
reset role;

-- ==== 6. 기능 잠금: 플랜 C 에서 host 를 빼면 조회·진행 모두 막힌다 ====
delete from nomad_core.plan_features where product_code = 'poll' and plan_code = 'C' and feature_code = 'host';
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.expect($$select count(*) from nomad_poll.events$$, 0);
select zz_check.fails_with($$select nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', 'locked')$$, 'no entitlement');
-- P1 회귀: 진행자 RPC 6개도 기능 잠금(org_has_feature 'poll' 'host')을 따른다
select zz_check.fails_with($$select nomad_poll.set_current_poll((select v::uuid from t_ids where k = 'e1'), null)$$, 'no entitlement');
select zz_check.fails_with($$select nomad_poll.moderate_question((select v::uuid from t_ids where k = 'q1'), 'visible')$$, 'no entitlement');
select zz_check.fails_with($$select nomad_poll.block_participant((select v::uuid from t_ids where k = 'pa1'), false)$$, 'no entitlement');
select zz_check.fails_with($$select nomad_poll.rotate_overlay_key((select v::uuid from t_ids where k = 'e1'))$$, 'no entitlement');
select zz_check.fails_with($$select nomad_poll.set_event_passcode((select v::uuid from t_ids where k = 'e1'), null)$$, 'no entitlement');
select zz_check.fails_with($$select nomad_poll.delete_event((select v::uuid from t_ids where k = 'e2'))$$, 'no entitlement');
reset role;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values ('poll', 'C', 'host');

-- ==== 7. 함수 권한 · 0002 이용권 · 동기화 컬럼 ====
-- anon 실행 가능 = 청중 공개 RPC 6개(join_event·participant_snapshot·cast_vote·ask_question·upvote_question·overlay_snapshot)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('nomad_poll', 'nomad_poll_private') and has_function_privilege('anon', p.oid, 'execute')
    and p.prorettype <> 'trigger'::regtype$$, 6);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'poll' and plan_code = 'C'$$, 6);
select zz_check.expect($$select count(*) from pg_trigger where tgname in ('events_touch','polls_touch','poll_options_touch','poll_results_touch','qna_questions_touch') and not tgisinternal$$, 5);
update nomad_poll.events set description = '수정' where id = (select v::uuid from t_ids where k = 'e2');
select zz_check.expect($$select count(*) from nomad_poll.events where id = (select v::uuid from t_ids where k = 'e2') and updated_at > created_at$$, 1);

-- ==== 8. P1 보안 회귀 ====
-- settings: 키별 boolean 타입 제약(문자열 등 거부), 읽기는 jsonb_typeof 확인 후 변환(이상 값은 기본값)
select zz_check.login('00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$update nomad_poll.events set settings = '{"qna_enabled":"yes"}' where id = (select v::uuid from t_ids where k = 'e2')$$, 'events_settings_check');
select zz_check.fails_with($$select nomad_poll.create_event('00000000-0000-0000-0000-00000000000a', 'bad', '', '{"allow_anonymous":1}')$$, 'events_settings_check');
update nomad_poll.events set settings = '{"qna_enabled":false}' where id = (select v::uuid from t_ids where k = 'e2');
select zz_check.expect($$select count(*) from nomad_poll.events where settings = '{"qna_enabled":false}'$$, 1);
select nomad_poll.set_event_passcode((select v::uuid from t_ids where k = 'e2'), '5678');
reset role;
select zz_check.expect($$select nomad_poll_private.setting_bool('{"x":"yes"}', 'x', true)::int$$, 1);
select zz_check.expect($$select nomad_poll_private.setting_bool('{"x":false}', 'x', true)::int$$, 0);
insert into t_ids select 'code2', code from nomad_poll.events where id = (select v::uuid from t_ids where k = 'e2');
-- join_event: 전역 잠금 키 없음(코드 단위), 클라이언트가 넘긴 p_ip_hash 는 무시(토큰 단위)
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.ok_code($$select nomad_poll.join_event('999999', repeat('w', 40), null, repeat('a', 64))$$, 'PL001');
-- 비live 행사: 비밀번호 검사가 먼저(틀리면 PL013, 상태 숨김), 맞으면 PL002 이지만 제목은 없다
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code2'), repeat('w', 40), null, null, '0000')$$, 'PL013');
select zz_check.ok_code($$select nomad_poll.join_event((select v from t_ids where k = 'code2'), repeat('w', 40), null, null, '5678')$$, 'PL002');
select zz_check.expect($$select (nomad_poll.join_event((select v from t_ids where k = 'code2'), repeat('w', 40), null, null, '5678') ? 'title')::int$$, 0);
reset role;
select zz_check.expect($$select count(*) from nomad_poll_private.rate_limits where key = 'poll:join_fail:all'$$, 0);
select zz_check.expect($$select count(*) from nomad_poll_private.rate_limits where key = 'poll:join_fail:code:999999'$$, 1);
select zz_check.expect($$select count(*) from nomad_poll_private.rate_limits where key = 'poll:join_fail:' || repeat('a', 64)$$, 0);
select zz_check.expect($$select count(*) from nomad_poll_private.rate_limits where key = 'poll:join_fail:tok:' || nomad_poll.token_hash(repeat('w', 40))$$, 1);
-- 서버(service_role) 호출일 때만 p_ip_hash 를 키로 쓴다
set local role service_role;
select zz_check.ok_code($$select nomad_poll.join_event('999998', repeat('w', 40), null, repeat('b', 64))$$, 'PL001');
reset role;
select zz_check.expect($$select count(*) from nomad_poll_private.rate_limits where key = 'poll:join_fail:' || repeat('b', 64)$$, 1);
-- collect_broadcasts: 한 행사의 오류는 그 행사만 건너뛰고 나머지는 보낸다(행사 e1 에서만 실패하도록 임시 교체, rollback 으로 복원)
create or replace function nomad_poll.build_public_state(p_event_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $f$
begin
  if p_event_id = (select v::uuid from t_ids where k = 'e1') then raise exception 'boom'; end if;
  return '{}'::jsonb;
end $f$;
update nomad_poll.events set title = '방송 갱신' where id = (select v::uuid from t_ids where k = 'e1');
create temp table t_bc as select * from nomad_poll.collect_broadcasts();
select zz_check.expect($$select count(*) from t_bc where event_id = (select v::uuid from t_ids where k = 'e1')$$, 0);
select zz_check.expect($$select (count(*) > 0)::int from t_bc$$, 1);
select zz_check.expect($$select broadcast_seq from nomad_poll.events where id = (select v::uuid from t_ids where k = 'e1')$$, 0);
