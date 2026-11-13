-- LOTTO-LAB user안 검사(합성 데이터). 실행: bash products/lottolab/run_check.sh user
-- (begin; → 청사진 스키마 drop → 임시 touch_updated_at → user/0001 + app/0001 적용 → 이 파일 → rollback;)

create function pg_temp.expect_fail(p_sql text, p_label text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'denied[%]: %', p_label, sqlerrm;
    return;   -- 거부됨(권한 부족·RLS 위반·제약)
  end;
  raise exception 'EXPECTED FAILURE BUT PASSED: %', p_label;
end;
$$;

insert into auth.users (id) values
  ('00000000-0000-4000-8000-0000000000a1'), ('00000000-0000-4000-8000-0000000000a2');

-- 서버(postgres) 시드: 공개 데이터
insert into nomad_lottolab.ingestion_runs (id, game, draw_no, source_url, fetched_at, payload_sha256, raw_payload, status)
values ('00000000-0000-4000-8000-0000000000e1', 'lotto', 1, 'https://example.test', now(), 'x', '{}', 'verified');
insert into nomad_lottolab.draws_lotto (draw_no, draw_date, nums, bonus, prizes, source_url, ingestion_run_id, source_verified_at)
values (1, '2002-12-07', '{1,2,3,4,5,6}', 7, '[]', 'https://example.test', '00000000-0000-4000-8000-0000000000e1', now());
insert into nomad_lottolab.statistics_cache values ('lotto', 'all', 'freq', '{}', 1, 1, 1, 'test', now(), now());

-- 사용자 A로 본인 데이터 작성
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true);

insert into nomad_lottolab.generator_profiles (user_id, game, name, config)
  values ('00000000-0000-4000-8000-0000000000a1', 'lotto', 'A 프리셋', '{}');
insert into nomad_lottolab.generated_batches (id, user_id, game, strategy, engine_version)
  values ('00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a1', 'lotto', 's', 'v1');
insert into nomad_lottolab.generated_numbers (id, batch_id, game, line_no, numbers)
  values ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000b1', 'lotto', 1, '{"nums":[1,2,3,4,5,6]}');
insert into nomad_lottolab.saved_tickets (id, user_id, game, ticket_data, purchase_status, source_number_id, idempotency_key)
  values ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000a1', 'lotto', '{"nums":[1,2,3,4,5,6]}', 'favorite',
          '00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000f1');
insert into nomad_lottolab.fortune_profiles (user_id, birth_date, calendar)
  values ('00000000-0000-4000-8000-0000000000a1', '1990-01-15', 'solar');
insert into nomad_lottolab.user_consents (user_id, terms_version, privacy_version, adult_confirmed)
  values ('00000000-0000-4000-8000-0000000000a1', 't1', 'p1', true);
insert into nomad_lottolab.push_devices (user_id, platform, token)
  values ('00000000-0000-4000-8000-0000000000a1', 'android', 'tok-a');

-- 동기화 컬럼: 수정하면 updated_at 증가, 소프트 삭제 가능
do $$
declare v_before timestamptz; v_after timestamptz;
begin
  select updated_at into v_before from nomad_lottolab.saved_tickets;
  perform pg_sleep(0.01);
  update nomad_lottolab.saved_tickets set purchase_status = 'purchased', purchase_date = current_date;
  select updated_at into v_after from nomad_lottolab.saved_tickets;
  if v_after <= v_before then raise exception 'touch_updated_at not applied'; end if;
  update nomad_lottolab.generator_profiles set deleted_at = now();
  if (select deleted_at from nomad_lottolab.generator_profiles) is null then raise exception 'soft delete failed'; end if;
end;
$$;
select pg_temp.expect_fail($q$update nomad_lottolab.saved_tickets set purchase_status = 'favorite'$q$, 'purchased->favorite');

-- 사용자 B: A의 행이 전혀 안 보이고, 위조 쓰기 거부
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true);
do $$
begin
  if (select count(*) from nomad_lottolab.generator_profiles) <> 0
     or (select count(*) from nomad_lottolab.generated_batches) <> 0
     or (select count(*) from nomad_lottolab.generated_numbers) <> 0
     or (select count(*) from nomad_lottolab.saved_tickets) <> 0
     or (select count(*) from nomad_lottolab.draw_checks) <> 0
     or (select count(*) from nomad_lottolab.fortune_profiles) <> 0
     or (select count(*) from nomad_lottolab.user_consents) <> 0
     or (select count(*) from nomad_lottolab.push_devices) <> 0
  then raise exception 'B sees A rows'; end if;
  -- 공개 데이터는 보인다
  if (select count(*) from nomad_lottolab.draws_lotto) <> 1 then raise exception 'public draws hidden'; end if;
end;
$$;
select pg_temp.expect_fail($q$insert into nomad_lottolab.generator_profiles (user_id, game, name, config) values ('00000000-0000-4000-8000-0000000000a1', 'lotto', 'x', '{}')$q$, 'B insert as A');
select pg_temp.expect_fail($q$insert into nomad_lottolab.generated_numbers (batch_id, game, line_no, numbers) values ('00000000-0000-4000-8000-0000000000b1', 'lotto', 2, '{"nums":[1,2,3,4,5,6]}')$q$, 'B insert numbers into A batch');
select pg_temp.expect_fail($q$insert into nomad_lottolab.saved_tickets (user_id, game, ticket_data, purchase_status, source_number_id, idempotency_key) values ('00000000-0000-4000-8000-0000000000a2', 'lotto', '{"nums":[1,2,3,4,5,6]}', 'favorite', '00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000f2')$q$, 'B ticket from A number');
select pg_temp.expect_fail($q$insert into nomad_lottolab.user_consents (user_id, terms_version, privacy_version, adult_confirmed) values ('00000000-0000-4000-8000-0000000000a1', 't', 'p', true)$q$, 'B consent as A');
do $$
declare n int;
begin
  update nomad_lottolab.saved_tickets set purchase_status = 'purchased', purchase_date = current_date;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'B updated A ticket'; end if;
  delete from nomad_lottolab.generator_profiles;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'B deleted A profile'; end if;
end;
$$;
select pg_temp.expect_fail($q$insert into nomad_lottolab.draw_checks (ticket_id, game, draw_no, checked_at) values ('00000000-0000-4000-8000-0000000000d1', 'lotto', 1, now())$q$, 'user writes draw_checks');
select pg_temp.expect_fail($q$insert into nomad_lottolab.subscription_accounts (user_id, store, product_id, state) values ('00000000-0000-4000-8000-0000000000a2', 's', 'p', 'x')$q$, 'user writes subscription');

-- anon: 공개 읽기만, 쓰기·사용자 데이터 거부
reset role;
set local role anon;
do $$
begin
  if (select count(*) from nomad_lottolab.draws_lotto) <> 1
     or (select count(*) from nomad_lottolab.statistics_cache) <> 1
     or (select count(*) from nomad_lottolab.draws_pension) <> 0
  then raise exception 'anon public read failed'; end if;
end;
$$;
select pg_temp.expect_fail($q$insert into nomad_lottolab.draws_lotto (draw_no, draw_date, nums, bonus, prizes, source_url, ingestion_run_id, source_verified_at) values (2, '2002-12-14', '{1,2,3,4,5,6}', 7, '[]', 'u', '00000000-0000-4000-8000-0000000000e1', now())$q$, 'anon insert draws');
select pg_temp.expect_fail($q$update nomad_lottolab.draws_lotto set bonus = 8$q$, 'anon update draws');
select pg_temp.expect_fail($q$delete from nomad_lottolab.statistics_cache$q$, 'anon delete stats');
select pg_temp.expect_fail($q$select * from nomad_lottolab.saved_tickets$q$, 'anon read tickets');
select pg_temp.expect_fail($q$select * from nomad_lottolab.waitlist_signups$q$, 'anon read waitlist');
select pg_temp.expect_fail($q$select * from nomad_lottolab.ingestion_runs$q$, 'anon read ingestion_runs');
select pg_temp.expect_fail($q$select nomad_lottolab.waitlist_confirm(repeat('a', 64))$q$, 'anon rpc');

-- service_role: 사전알림 RPC 동작
reset role;
set local role service_role;
do $$
declare h text := repeat('a', 64);
begin
  if not nomad_lottolab.waitlist_rate_hit('k', 60, 2) then raise exception 'rate hit'; end if;
  if not nomad_lottolab.waitlist_request_confirm('x@example.test', h, 3600, 3, 3600) then raise exception 'request_confirm'; end if;
  if not nomad_lottolab.waitlist_confirm(h) then raise exception 'confirm'; end if;
end;
$$;
