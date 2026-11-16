-- LOTTO-LAB org안 검사(합성 데이터). 실행: bash products/lottolab/run_check.sh org
-- (begin; → 청사진 스키마 drop → 임시 touch_updated_at → org/0001 + app/0001 적용 → 이 파일 → rollback;)

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
  ('00000000-0000-4000-8000-0000000000a1'), ('00000000-0000-4000-8000-0000000000a2'), ('00000000-0000-4000-8000-0000000000a3');
insert into nomad_core.organizations (id, name) values
  ('00000000-0000-4000-8000-0000000000aa', 'A 조직'), ('00000000-0000-4000-8000-0000000000bb', 'B 조직');
insert into nomad_core.memberships values
  ('00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000a1', 'owner'),
  ('00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000a3', 'viewer'),
  ('00000000-0000-4000-8000-0000000000bb', '00000000-0000-4000-8000-0000000000a2', 'owner');
-- 서버(postgres) 시드: 공개 데이터
insert into nomad_lottolab.ingestion_runs (id, game, draw_no, source_url, fetched_at, payload_sha256, raw_payload, status)
values ('00000000-0000-4000-8000-0000000000e1', 'lotto', 1, 'https://example.test', now(), 'x', '{}', 'verified');
insert into nomad_lottolab.draws_lotto (draw_no, draw_date, nums, bonus, prizes, source_url, ingestion_run_id, source_verified_at)
values (1, '2002-12-07', '{1,2,3,4,5,6}', 7, '[]', 'https://example.test', '00000000-0000-4000-8000-0000000000e1', now());
insert into nomad_lottolab.statistics_cache values ('lotto', 'all', 'freq', '{}', 1, 1, 1, 'test', now(), now());

-- 사용자 A로 본인 데이터 작성
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true);

insert into nomad_lottolab.generator_profiles (organization_id, game, name, config)
  values ('00000000-0000-4000-8000-0000000000aa', 'lotto', 'A 프리셋', '{}');
insert into nomad_lottolab.generated_batches (id, organization_id, game, strategy, engine_version)
  values ('00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000aa', 'lotto', 's', 'v1');
insert into nomad_lottolab.generated_numbers (id, batch_id, game, line_no, numbers)
  values ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000b1', 'lotto', 1, '{"nums":[1,2,3,4,5,6]}');
insert into nomad_lottolab.saved_tickets (id, organization_id, game, ticket_data, purchase_status, source_number_id, idempotency_key)
  values ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000aa', 'lotto', '{"nums":[1,2,3,4,5,6]}', 'favorite',
          '00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000f1');
insert into nomad_lottolab.fortune_profiles (organization_id, birth_date, calendar)
  values ('00000000-0000-4000-8000-0000000000aa', '1990-01-15', 'solar');
insert into nomad_lottolab.user_consents (organization_id, user_id, terms_version, privacy_version, adult_confirmed)
  values ('00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000a1', 't1', 'p1', true);
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

-- viewer(a3): A 조직 데이터 읽기 가능, 쓰기 거부
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true);
do $$
begin
  if (select count(*) from nomad_lottolab.generator_profiles) <> 1
     or (select count(*) from nomad_lottolab.saved_tickets) <> 1
     or (select count(*) from nomad_lottolab.generated_numbers) <> 1
  then raise exception 'viewer cannot read org data'; end if;
  -- 운세 프로필은 본인만: 같은 조직 viewer에게도 a1 행은 보이지 않는다
  if (select count(*) from nomad_lottolab.fortune_profiles) <> 0 then raise exception 'fortune_profiles visible to other member'; end if;
end;
$$;
-- viewer도 자기 운세 프로필은 만들 수 있고, 남의 행으로 위조할 수 없다
insert into nomad_lottolab.fortune_profiles (organization_id, birth_date, calendar)
  values ('00000000-0000-4000-8000-0000000000aa', '1985-03-03', 'solar');
select pg_temp.expect_fail($q$insert into nomad_lottolab.fortune_profiles (organization_id, user_id, birth_date, calendar) values ('00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000a2', '1985-03-03', 'solar')$q$, 'spoof user_id');
do $$
declare n int;
begin
  if (select count(*) from nomad_lottolab.fortune_profiles) <> 1 then raise exception 'viewer own fortune row missing'; end if;
  update nomad_lottolab.fortune_profiles set birth_date = '1985-04-04' where user_id = '00000000-0000-4000-8000-0000000000a1';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'viewer updated other fortune row'; end if;
  delete from nomad_lottolab.fortune_profiles where user_id = '00000000-0000-4000-8000-0000000000a1';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'viewer deleted other fortune row'; end if;
end;
$$;
-- 조직 owner(a1)도 viewer의 운세 프로필은 못 보고 자기 1행만 본다
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true);
do $$
begin
  if (select count(*) from nomad_lottolab.fortune_profiles) <> 1
     or (select user_id from nomad_lottolab.fortune_profiles) <> '00000000-0000-4000-8000-0000000000a1'
  then raise exception 'owner sees other member fortune row'; end if;
end;
$$;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true);
select pg_temp.expect_fail($q$insert into nomad_lottolab.generator_profiles (organization_id, game, name, config) values ('00000000-0000-4000-8000-0000000000aa', 'lotto', 'v', '{}')$q$, 'viewer insert');
do $$
declare n int;
begin
  update nomad_lottolab.saved_tickets set deleted_at = now();
  get diagnostics n = row_count;
  -- UPDATE 정책이 편집자 이상이므로 viewer는 0행
  if n <> 0 then raise exception 'viewer updated ticket'; end if;
  delete from nomad_lottolab.generator_profiles;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'viewer deleted'; end if;
end;
$$;

-- 조직 B 멤버(a2): A 조직 행이 전혀 안 보이고, 위조 쓰기 거부
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
  then raise exception 'org B sees org A rows'; end if;
  -- 공개 데이터는 보인다
  if (select count(*) from nomad_lottolab.draws_lotto) <> 1 then raise exception 'public draws hidden'; end if;
end;
$$;
select pg_temp.expect_fail($q$insert into nomad_lottolab.generator_profiles (organization_id, game, name, config) values ('00000000-0000-4000-8000-0000000000aa', 'lotto', 'x', '{}')$q$, 'org B insert into org A');
select pg_temp.expect_fail($q$insert into nomad_lottolab.generated_numbers (batch_id, game, line_no, numbers) values ('00000000-0000-4000-8000-0000000000b1', 'lotto', 2, '{"nums":[1,2,3,4,5,6]}')$q$, 'B insert numbers into A batch');
select pg_temp.expect_fail($q$insert into nomad_lottolab.saved_tickets (organization_id, game, ticket_data, purchase_status, source_number_id, idempotency_key) values ('00000000-0000-4000-8000-0000000000bb', 'lotto', '{"nums":[1,2,3,4,5,6]}', 'favorite', '00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000f2')$q$, 'B ticket from A number');
select pg_temp.expect_fail($q$insert into nomad_lottolab.user_consents (organization_id, user_id, terms_version, privacy_version, adult_confirmed) values ('00000000-0000-4000-8000-0000000000aa', '00000000-0000-4000-8000-0000000000a1', 't', 'p', true)$q$, 'B consent as A');
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

-- 운세 프로필 추가 검사: 다른 조직 위조, 앱 upsert, user_id·조직 이동 거부, 조직 탈퇴 후 본인 삭제
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true);
select pg_temp.expect_fail($q$insert into nomad_lottolab.fortune_profiles (organization_id, birth_date, calendar) values ('00000000-0000-4000-8000-0000000000aa', '1980-01-01', 'solar')$q$, 'B fortune into A org');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a1', true);
insert into nomad_lottolab.fortune_profiles (organization_id, birth_date, calendar)
  values ('00000000-0000-4000-8000-0000000000aa', '1991-02-02', 'solar')
  on conflict (organization_id, user_id) do update
  set organization_id = excluded.organization_id, birth_date = excluded.birth_date, calendar = excluded.calendar;
do $$
begin
  if (select birth_date from nomad_lottolab.fortune_profiles) <> '1991-02-02' then raise exception 'fortune upsert failed'; end if;
end;
$$;
select pg_temp.expect_fail($q$update nomad_lottolab.fortune_profiles set user_id = '00000000-0000-4000-8000-0000000000a3'$q$, 'fortune update user_id');
select pg_temp.expect_fail($q$update nomad_lottolab.fortune_profiles set organization_id = '00000000-0000-4000-8000-0000000000bb'$q$, 'fortune move to non-member org');
-- a3가 조직을 떠나도 자기 행은 보이고 지울 수 있다(다시 쓰기는 거부)
reset role;
delete from nomad_core.memberships where user_id = '00000000-0000-4000-8000-0000000000a3';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a3', true);
select pg_temp.expect_fail($q$insert into nomad_lottolab.fortune_profiles (organization_id, birth_date, calendar) values ('00000000-0000-4000-8000-0000000000bb', '1980-01-01', 'solar')$q$, 'non-member fortune insert');
do $$
declare n int;
begin
  if (select count(*) from nomad_lottolab.fortune_profiles) <> 1 then raise exception 'left member cannot see own fortune row'; end if;
  update nomad_lottolab.fortune_profiles set birth_date = '1970-01-01';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'left member updated fortune row'; end if;
  delete from nomad_lottolab.fortune_profiles;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'left member cannot delete own fortune row'; end if;
end;
$$;
reset role;

-- ── 결정 8: 계정 삭제 전 1인 개인 조직 정리(service_role) ──
-- p1 = a2만 멤버인 개인 조직(정리 대상, 가입 트리거가 만든 a2 개인 조직도 대상 = 2곳) · p2 = a2와 a3가 함께 있는 개인 조직(제외) · bb = a2 단독 팀 조직(kind team, 제외)
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-4000-8000-0000000000c7', 'a2 개인', 'personal'), ('00000000-0000-4000-8000-0000000000c8', '공유 개인', 'personal');
delete from nomad_core.memberships where organization_id in ('00000000-0000-4000-8000-0000000000c7', '00000000-0000-4000-8000-0000000000c8');
insert into nomad_core.memberships values
  ('00000000-0000-4000-8000-0000000000c7', '00000000-0000-4000-8000-0000000000a2', 'owner'),
  ('00000000-0000-4000-8000-0000000000c8', '00000000-0000-4000-8000-0000000000a2', 'owner'),
  ('00000000-0000-4000-8000-0000000000c8', '00000000-0000-4000-8000-0000000000a3', 'viewer');
insert into nomad_lottolab.generator_profiles (organization_id, game, name, config) values
  ('00000000-0000-4000-8000-0000000000c7', 'lotto', 'p1', '{}'), ('00000000-0000-4000-8000-0000000000c8', 'lotto', 'p2', '{}'),
  ('00000000-0000-4000-8000-0000000000bb', 'lotto', 'team', '{}');
insert into nomad_lottolab.generated_batches (id, organization_id, game, strategy, engine_version)
  values ('00000000-0000-4000-8000-0000000000b7', '00000000-0000-4000-8000-0000000000c7', 'lotto', 's', 'v1');
insert into nomad_lottolab.generated_numbers (id, batch_id, game, line_no, numbers)
  values ('00000000-0000-4000-8000-0000000000c9', '00000000-0000-4000-8000-0000000000b7', 'lotto', 1, '{"nums":[1,2,3,4,5,6]}');
insert into nomad_lottolab.saved_tickets (organization_id, game, ticket_data, purchase_status, source_number_id, idempotency_key)
  values ('00000000-0000-4000-8000-0000000000c7', 'lotto', '{"nums":[1,2,3,4,5,6]}', 'favorite',
          '00000000-0000-4000-8000-0000000000c9', '00000000-0000-4000-8000-0000000000f7');
insert into nomad_lottolab.fortune_profiles (organization_id, user_id, birth_date, calendar)
  values ('00000000-0000-4000-8000-0000000000c7', '00000000-0000-4000-8000-0000000000a2', '1985-05-05', 'solar');
insert into nomad_lottolab.user_consents (organization_id, user_id, terms_version, privacy_version, adult_confirmed)
  values ('00000000-0000-4000-8000-0000000000c7', '00000000-0000-4000-8000-0000000000a2', 't1', 'p1', true);
-- 사용자 롤은 실행 불가
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000a2', true);
select pg_temp.expect_fail($q$select nomad_lottolab.purge_personal_org_data('00000000-0000-4000-8000-0000000000a2')$q$, 'purge by authenticated');
reset role;
set local role service_role;
do $$
declare r jsonb := nomad_lottolab.purge_personal_org_data('00000000-0000-4000-8000-0000000000a2');
begin
  if r <> '{"organizations": 2, "saved_tickets": 1, "generated_batches": 1, "generator_profiles": 1, "fortune_profiles": 1, "user_consents": 1}'::jsonb then
    raise exception 'purge result %', r;
  end if;
end;
$$;
reset role;
do $$
begin
  if exists (select 1 from nomad_lottolab.generated_numbers where batch_id = '00000000-0000-4000-8000-0000000000b7') then raise exception 'numbers not cascaded'; end if;
  if (select count(*) from nomad_lottolab.generator_profiles where organization_id in ('00000000-0000-4000-8000-0000000000c8', '00000000-0000-4000-8000-0000000000bb')) <> 2 then
    raise exception 'shared personal org or team org was purged';
  end if;
  if not exists (select 1 from nomad_core.organizations where id = '00000000-0000-4000-8000-0000000000c7') then raise exception 'organization itself was deleted'; end if;
  if not exists (select 1 from nomad_core.memberships where organization_id = '00000000-0000-4000-8000-0000000000c7') then raise exception 'membership was deleted'; end if;
  -- 다른 멤버가 있는 개인 조직(c8)·팀 조직(bb)은 데이터·감사 기록 모두 없음
  if (select count(*) from nomad_lottolab.generator_profiles where organization_id = '00000000-0000-4000-8000-0000000000c8') <> 1 then raise exception 'shared personal org purged'; end if;
  if (select count(*) from nomad_lottolab.generator_profiles where organization_id = '00000000-0000-4000-8000-0000000000bb') <> 1 then raise exception 'team org purged'; end if;
  -- 감사: 정리한 조직마다 1건(조직 id·건수만, 사용자 id 없음)
  if (select count(*) from nomad_core.audit_log where action = 'lottolab.personal_org_purged') <> 2 then raise exception 'purge audit count'; end if;
  if exists (select 1 from nomad_core.audit_log where action = 'lottolab.personal_org_purged'
              and (organization_id in ('00000000-0000-4000-8000-0000000000c8', '00000000-0000-4000-8000-0000000000bb')
                   or target_id <> organization_id::text)) then raise exception 'purge audit wrong org'; end if;
  if exists (select 1 from nomad_core.audit_log where action = 'lottolab.personal_org_purged'
              and (metadata::text like '%00000000-0000-4000-8000-0000000000a2%' or before is not null or after is not null)) then
    raise exception 'purge audit contains personal data';
  end if;
  if (select metadata from nomad_core.audit_log where action = 'lottolab.personal_org_purged' and organization_id = '00000000-0000-4000-8000-0000000000c7')
     <> '{"saved_tickets": 1, "generated_batches": 1, "generator_profiles": 1, "fortune_profiles": 1, "user_consents": 1}'::jsonb then
    raise exception 'purge audit counts';
  end if;
end;
$$;
