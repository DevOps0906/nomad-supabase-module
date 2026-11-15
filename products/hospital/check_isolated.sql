-- hospital 격리형 검사: 권한 면(표 0·함수 service_role 만)·공용 스키마 참조 0 · 행위자 확인 · 역할별 범위
--   · restrict 삭제 · 감사 로그 append-only/TRUNCATE · 열람 감사 · HMAC(키 없음 오류·정규화) · bootstrap 1회 · 보존·파기.
--   합성 데이터만, 마지막에 rollback. 실행: bash products/hospital/run_check.sh

create schema zz_check;
grant usage on schema zz_check to anon, authenticated, service_role;
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
-- 오류가 나야 하고, 오류 문구에 평문 인자(forbidden)가 없어야 한다
create function zz_check.err_without(q text, forbidden text) returns void language plpgsql as $$
declare got text;
begin
  begin execute q; got := null; exception when others then got := sqlerrm; end;
  if got is null then raise exception 'NOT DENIED: %', q; end if;
  if position(forbidden in got) > 0 then raise exception 'plaintext leaked in error: %', got; end if;
end $$;
create table zz_check.vals (k text primary key, v text);
grant all on zz_check.vals to service_role;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ==== 1. 권한 면 (postgres 로 조회) ====
-- service_role: 표·시퀀스 직접 권한 0
select zz_check.expect($$select count(*) from pg_class c where c.relnamespace = 'nomad_hospital'::regnamespace and c.relkind in ('r','p','v','m')
  and has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')$$, 0);
select zz_check.expect($$select count(*) from pg_class c where c.relnamespace = 'nomad_hospital'::regnamespace and c.relkind = 'S'
  and case when c.relkind = 'S' then has_sequence_privilege('service_role', c.oid, 'USAGE,SELECT,UPDATE') end$$, 0);
-- anon·authenticated: 스키마·표·시퀀스·함수 권한 0
select zz_check.expect($$select count(*) from unnest(array['anon','authenticated']) r where has_schema_privilege(r, 'nomad_hospital', 'USAGE,CREATE')$$, 0);
select zz_check.expect($$select count(*) from pg_class c, unnest(array['anon','authenticated']) r
  where c.relnamespace = 'nomad_hospital'::regnamespace and c.relkind in ('r','p','v','m')
    and has_table_privilege(r, c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')$$, 0);
select zz_check.expect($$select count(*) from pg_class c, unnest(array['anon','authenticated']) r
  where c.relnamespace = 'nomad_hospital'::regnamespace and c.relkind = 'S' and case when c.relkind = 'S' then has_sequence_privilege(r, c.oid, 'USAGE,SELECT,UPDATE') end$$, 0);
select zz_check.expect($$select count(*) from pg_proc p, unnest(array['anon','authenticated']) r
  where p.pronamespace = 'nomad_hospital'::regnamespace and has_function_privilege(r, p.oid, 'EXECUTE')$$, 0);
-- service_role: 내부 도우미(_*)·트리거 함수 EXECUTE 0, API 19개만
select zz_check.expect($$select count(*) from pg_proc p where p.pronamespace = 'nomad_hospital'::regnamespace
  and (p.proname like '\_%' or p.proname like 'tg\_%') and has_function_privilege('service_role', p.oid, 'EXECUTE')$$, 0);
-- 스키마 전체 함수 순회: service_role 실행 가능 = API 19개와 정확히 일치(빠짐·초과 모두 실패)
select zz_check.expect($$select count(*) from (
  (select p.proname::text from pg_proc p where p.pronamespace = 'nomad_hospital'::regnamespace and has_function_privilege('service_role', p.oid, 'EXECUTE')
   except select unnest(array['bootstrap_admin','add_staff','deactivate_staff','list_staff','assign_care','end_care','register_patient',
     'search_patients','get_patient','create_appointment','set_appointment_status','list_appointments','add_contact_log','list_contact_logs',
     'add_consult_note','list_consult_notes','list_purge_candidates','purge_record','list_audit_logs']))
  union all
  (select unnest(array['bootstrap_admin','add_staff','deactivate_staff','list_staff','assign_care','end_care','register_patient',
     'search_patients','get_patient','create_appointment','set_appointment_status','list_appointments','add_contact_log','list_contact_logs',
     'add_consult_note','list_consult_notes','list_purge_candidates','purge_record','list_audit_logs'])
   except select p.proname::text from pg_proc p where p.pronamespace = 'nomad_hospital'::regnamespace and has_function_privilege('service_role', p.oid, 'EXECUTE'))
) d$$, 0);
select zz_check.expect($$select count(*) from pg_proc p where p.pronamespace = 'nomad_hospital'::regnamespace
  and has_function_privilege('service_role', p.oid, 'EXECUTE')$$, 19);
-- 검색 반환 컬럼에 암호문(*_enc) 없음
select zz_check.expect($$select count(*) from pg_proc p, unnest(p.proargnames) n
  where p.oid = 'nomad_hospital.search_patients(uuid,text,text,text)'::regprocedure and n like '%\_enc'$$, 0);
-- 모든 표 RLS
select zz_check.expect($$select count(*) from pg_class c where c.relnamespace = 'nomad_hospital'::regnamespace and c.relkind = 'r' and not c.relrowsecurity$$, 0);
-- definer 함수는 전부 search_path='' 고정
select zz_check.expect($$select count(*) from pg_proc p where p.pronamespace = 'nomad_hospital'::regnamespace and p.prosecdef
  and not coalesce(p.proconfig @> array['search_path=""'], false)$$, 0);
-- 공용 스키마 참조 0 (함수 본문·FK 대상. 파일 grep 은 run_check.sh)
select zz_check.expect($$select count(*) from pg_proc p where p.pronamespace = 'nomad_hospital'::regnamespace and p.prosrc ilike '%nomad\_core%'$$, 0);
select zz_check.expect($$select count(*) from pg_constraint k where k.connamespace = 'nomad_hospital'::regnamespace and k.contype = 'f'
  and k.confrelid::regclass::text not like 'nomad_hospital.%' and k.confrelid <> 'auth.users'::regclass$$, 0);
-- 모든 FK restrict
select zz_check.expect($$select count(*) from pg_constraint k where k.connamespace = 'nomad_hospital'::regnamespace and k.contype = 'f' and k.confdeltype <> 'r'$$, 0);

-- ==== 2. 합성 데이터: u1 관리자(bootstrap), u2 의사, u3 간호사, u4 접수, u5 의사(담당 없음), u6 퇴사 예정 간호사, u9 직원 아님 ====
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'zz-admin@example.test'),
  ('00000000-0000-0000-0000-0000000000c2', 'zz-doctor@example.test'),
  ('00000000-0000-0000-0000-0000000000c3', 'zz-nurse@example.test'),
  ('00000000-0000-0000-0000-0000000000c4', 'zz-reception@example.test'),
  ('00000000-0000-0000-0000-0000000000c5', 'zz-doctor2@example.test'),
  ('00000000-0000-0000-0000-0000000000c6', 'zz-nurse2@example.test'),
  ('00000000-0000-0000-0000-0000000000c7', 'zz-nurse3@example.test'),
  ('00000000-0000-0000-0000-0000000000c9', 'zz-outsider@example.test');

set local role service_role;
-- 직접 표 접근 거부(service_role 도)
select zz_check.fails_with($$select * from nomad_hospital.staff$$, '42501');
select zz_check.fails_with($$insert into nomad_hospital.audit_logs (action) values ('x')$$, '42501');
select zz_check.fails_with($$select nomad_hospital._hmac_key()$$, '42501');

-- bootstrap: 1회만
select nomad_hospital.bootstrap_admin('00000000-0000-0000-0000-0000000000c1', '관리자');
select zz_check.fails_with($$select nomad_hospital.bootstrap_admin('00000000-0000-0000-0000-0000000000c9', '두번째')$$, 'HP004');

select nomad_hospital.add_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2', '의사', 'doctor', '내과');
select nomad_hospital.add_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c3', '간호사', 'nurse', '내과');
select nomad_hospital.add_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c4', '접수', 'reception', null);
select nomad_hospital.add_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c5', '의사2', 'doctor', '외과');
select nomad_hospital.add_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c6', '간호사2', 'nurse', '외과');
select nomad_hospital.add_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c7', '간호사3', 'nurse', '외과');

-- ==== 3. HMAC: 키 없으면 오류(fail-closed) ====
select zz_check.fails_with($$select nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c4', '홍길동', '010-1234-5678', 'enc:n', 'enc:p', 'enc:b', now())$$, 'HP002');
select zz_check.fails_with($$select * from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', '홍길동', '010-1234-5678', 'reception')$$, 'HP002');
-- 오류 문구에 평문 이름·전화 없음(키 없음·행위자 거부·역할 거부)
select zz_check.err_without($$select nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c4', '홍길동', '010-1234-5678', 'enc', null, null, null)$$, '홍길동');
select zz_check.err_without($$select nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c4', '홍길동', '010-1234-5678', 'enc', null, null, null)$$, '1234');
select zz_check.err_without($$select * from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c9', '홍길동', '010-1234-5678', 'reception')$$, '홍길동');
select zz_check.err_without($$select nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c2', '홍길동', '010-1234-5678', 'enc', null, null, null)$$, '1234');
reset role;
select vault.create_secret('zz-synthetic-hmac-key-1', 'nomad_hospital_hmac_v1');
set local role service_role;

select zz_check.err_without($$select * from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', '  ', '+82', 'reception')$$, '+82');
insert into zz_check.vals values ('p1', nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c4', '홍길동', '010-1234-5678', 'enc:n1', 'enc:p1', 'enc:b1', now()));
insert into zz_check.vals values ('p2', nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c1', '김철수', '010-9999-0000', 'enc:n2', 'enc:p2', 'enc:b2', now()));

-- ==== 4. 행위자 확인: 없음·null·직원 아님·비활성 ====
select zz_check.fails_with($$select nomad_hospital.list_staff(null)$$, 'HP001');
select zz_check.fails_with($$select nomad_hospital.list_staff('00000000-0000-0000-0000-0000000000c9')$$, 'HP001');
select zz_check.fails_with($$select nomad_hospital.list_staff(gen_random_uuid())$$, 'HP001');
select nomad_hospital.deactivate_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c6');
select zz_check.fails_with($$select * from nomad_hospital.list_appointments('00000000-0000-0000-0000-0000000000c6', now() - interval '1 day', now() + interval '1 day', 'treatment')$$, 'HP001');
select zz_check.fails_with($$select nomad_hospital.deactivate_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c1')$$, '22023');

-- ==== 5. 역할별 범위 ====
-- 배정은 관리자만(의사 자가 배정 거부, 접수 거부)
select zz_check.fails_with(format($$select nomad_hospital.assign_care('00000000-0000-0000-0000-0000000000c2', %L, '00000000-0000-0000-0000-0000000000c2')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with(format($$select nomad_hospital.assign_care('00000000-0000-0000-0000-0000000000c4', %L, '00000000-0000-0000-0000-0000000000c2')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select nomad_hospital.assign_care('00000000-0000-0000-0000-0000000000c1', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c2');
select nomad_hospital.assign_care('00000000-0000-0000-0000-0000000000c1', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c3');
-- 퇴사(deactivate_staff) 시 담당 자동 종료
select nomad_hospital.assign_care('00000000-0000-0000-0000-0000000000c1', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c7');
select zz_check.expect(format($$select count(*) from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c7', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), 1);
select nomad_hospital.deactivate_staff('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c7');
reset role;
select zz_check.expect($$select count(*) from nomad_hospital.care_assignments where staff_id = '00000000-0000-0000-0000-0000000000c7' and ended_at is null$$, 0);
select zz_check.expect($$select count(*) from nomad_hospital.care_assignments where staff_id = '00000000-0000-0000-0000-0000000000c7' and ended_at is not null$$, 1);
set local role service_role;
-- end_care 뒤 접근 거부 (u5 를 잠시 배정 → 허용 → 종료 → 거부)
select nomad_hospital.assign_care('00000000-0000-0000-0000-0000000000c1', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c5');
select zz_check.expect(format($$select count(*) from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c5', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), 1);
select nomad_hospital.end_care('00000000-0000-0000-0000-0000000000c1', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c5');
select zz_check.fails_with(format($$select * from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c5', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with(format($$select * from nomad_hospital.list_contact_logs('00000000-0000-0000-0000-0000000000c5', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), '42501');
-- 의사·간호사는 예약·환자 등록 불가
select zz_check.fails_with(format($$select nomad_hospital.create_appointment('00000000-0000-0000-0000-0000000000c2', %L, '00000000-0000-0000-0000-0000000000c2', now())$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with($$select nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c2', '이영희', null, 'enc', null, null, null)$$, '42501');
insert into zz_check.vals values ('a1', nomad_hospital.create_appointment('00000000-0000-0000-0000-0000000000c4', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c2', now() + interval '1 hour'));
select nomad_hospital.create_appointment('00000000-0000-0000-0000-0000000000c4', (select v::uuid from zz_check.vals where k = 'p2'), '00000000-0000-0000-0000-0000000000c5', now() + interval '2 hour');
-- 예약 범위: 접수 2건, 담당 의사 1건(담당 환자만), 담당 없는 의사 0건
select zz_check.expect($$select count(*) from nomad_hospital.list_appointments('00000000-0000-0000-0000-0000000000c4', now(), now() + interval '1 day', 'reception')$$, 2);
select zz_check.expect($$select count(*) from nomad_hospital.list_appointments('00000000-0000-0000-0000-0000000000c2', now(), now() + interval '1 day', 'treatment')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.list_appointments('00000000-0000-0000-0000-0000000000c5', now(), now() + interval '1 day', 'treatment')$$, 0);
-- 환자 열람: 담당 외 의사 거부, 담당 간호사 허용, 접수 허용
select zz_check.fails_with(format($$select * from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c5', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.expect(format($$select count(*) from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c3', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), 1);
select zz_check.expect(format($$select count(*) from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c4', %L, 'reception')$$, (select v from zz_check.vals where k = 'p2')), 1);
-- 열람 사유 필수
select zz_check.fails_with(format($$select * from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c4', %L, 'curious')$$, (select v from zz_check.vals where k = 'p2')), '22023');
-- 상담 메모: 담당 의사 작성, 담당 간호사 열람, 접수·관리자·담당 외 의사 거부
insert into zz_check.vals values ('n1', nomad_hospital.add_consult_note('00000000-0000-0000-0000-0000000000c2', (select v::uuid from zz_check.vals where k = 'p1'), 'enc:note1'));
select zz_check.expect(format($$select count(*) from nomad_hospital.list_consult_notes('00000000-0000-0000-0000-0000000000c3', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), 1);
select zz_check.fails_with(format($$select * from nomad_hospital.list_consult_notes('00000000-0000-0000-0000-0000000000c4', %L, 'reception')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with(format($$select * from nomad_hospital.list_consult_notes('00000000-0000-0000-0000-0000000000c1', %L, 'admin_review')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with(format($$select * from nomad_hospital.list_consult_notes('00000000-0000-0000-0000-0000000000c5', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with(format($$select nomad_hospital.add_consult_note('00000000-0000-0000-0000-0000000000c5', %L, 'enc:x')$$, (select v from zz_check.vals where k = 'p1')), '42501');
-- 연락 기록: 접수 작성, 담당 외 의사 열람 거부
select nomad_hospital.add_contact_log('00000000-0000-0000-0000-0000000000c4', (select v::uuid from zz_check.vals where k = 'p1'), 'phone', 'enc:call');
select zz_check.fails_with(format($$select nomad_hospital.add_contact_log('00000000-0000-0000-0000-0000000000c5', %L, 'phone', 'enc:x')$$, (select v from zz_check.vals where k = 'p1')), '42501');
select zz_check.fails_with(format($$select * from nomad_hospital.list_contact_logs('00000000-0000-0000-0000-0000000000c5', %L, 'treatment')$$, (select v from zz_check.vals where k = 'p1')), '42501');
-- 감사 로그 열람은 관리자만
select zz_check.fails_with($$select * from nomad_hospital.list_audit_logs('00000000-0000-0000-0000-0000000000c2', now() - interval '1 day', now() + interval '1 day')$$, '42501');

-- ==== 6. HMAC 정규화 일치(+82·공백·하이픈, NFD 이름·공백) + 검색 범위 ====
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', null, '+82 10 1234 5678', 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', null, '+82 010 1234 5678', 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', null, '(+82)10-1234-5678', 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', null, '82-10-1234-5678', 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', null, '0082 10 1234 5678', 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', U&'\200B홍\200D길\FEFF동', null, 'reception')$$, 1);
select nomad_hospital.register_patient('00000000-0000-0000-0000-0000000000c4', 'John Kim', null, 'enc:n3', null, null, null);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', 'ＪＯＨＮ　ｋｉｍ', null, 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', ' 홍 길동 ', '01012345678', 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', normalize('홍길동', NFD), null, 'reception')$$, 1);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', '홍길', null, 'reception')$$, 0);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c5', '홍길동', null, 'treatment')$$, 0);
select zz_check.expect($$select count(*) from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c2', '홍길동', null, 'treatment')$$, 1);

reset role;
-- 해시는 저장, 평문 없음, key_version 1
select zz_check.expect($$select count(*) from nomad_hospital.patients where hash_key_version = 1 and name_hash ~ '^[0-9a-f]{64}$' and name_hash <> '홍길동'$$, 3);
select zz_check.expect($$select count(*) from nomad_hospital.patients where name_hash = nomad_hospital._hmac('name', normalize('홍 길동', NFD), 'zz-synthetic-hmac-key-1')$$, 1);

-- ==== 7. 열람마다 감사 행 ====
insert into zz_check.vals values ('audit0', (select count(*) from nomad_hospital.audit_logs));
set local role service_role;
select * from nomad_hospital.get_patient('00000000-0000-0000-0000-0000000000c2', (select v::uuid from zz_check.vals where k = 'p1'), 'treatment');
select * from nomad_hospital.list_consult_notes('00000000-0000-0000-0000-0000000000c2', (select v::uuid from zz_check.vals where k = 'p1'), 'treatment');
select * from nomad_hospital.list_consult_notes('00000000-0000-0000-0000-0000000000c3', (select v::uuid from zz_check.vals where k = 'p1'), 'treatment');
select * from nomad_hospital.list_contact_logs('00000000-0000-0000-0000-0000000000c4', (select v::uuid from zz_check.vals where k = 'p1'), 'reception');
select * from nomad_hospital.search_patients('00000000-0000-0000-0000-0000000000c4', '김철수', null, 'reception');
reset role;
select zz_check.expect($$select count(*) - (select v::bigint from zz_check.vals where k = 'audit0') from nomad_hospital.audit_logs$$, 5);
-- 검색 감사 detail 에 반환 id 배열
select zz_check.expect(format($$select count(*) from (select * from nomad_hospital.audit_logs where action = 'patient.search' order by id desc limit 1) l
  where l.detail -> 'patient_ids' = jsonb_build_array(%L::text) and l.row_count = 1$$, (select v from zz_check.vals where k = 'p2')), 1);
select zz_check.expect($$select count(*) from (select * from nomad_hospital.audit_logs order by id desc limit 5) l
  where l.actor_id is not null and l.actor_name is not null and l.purpose is not null$$, 5);
select zz_check.expect(format($$select count(*) from nomad_hospital.audit_logs where action = 'note.list' and patient_id = %L
  and actor_role in ('doctor','nurse')$$, (select v from zz_check.vals where k = 'p1')), 3);

-- ==== 8. restrict 삭제 ====
-- service_role 직접 삭제는 권한 없음
set local role service_role;
select zz_check.fails_with($$delete from nomad_hospital.consult_notes$$, '42501');
select zz_check.fails_with($$delete from nomad_hospital.staff where user_id = '00000000-0000-0000-0000-0000000000c2'$$, '42501');
reset role;
-- 소유자(postgres)로도: 진료 메모 삭제·수정은 append-only, 직원·auth 사용자·환자 삭제는 FK restrict
select zz_check.fails_with($$delete from nomad_hospital.consult_notes$$, 'append-only');
select zz_check.fails_with($$update nomad_hospital.consult_notes set note_enc = 'x'$$, 'append-only');
select zz_check.fails_with($$delete from nomad_hospital.contact_logs$$, 'append-only');
select zz_check.fails_with($$truncate nomad_hospital.consult_notes cascade$$, '42501');
select zz_check.fails_with($$truncate nomad_hospital.contact_logs$$, 'truncate is not allowed');
select zz_check.fails_with($$delete from nomad_hospital.staff where user_id = '00000000-0000-0000-0000-0000000000c2'$$, '23503');
select zz_check.fails_with($$delete from auth.users where id = '00000000-0000-0000-0000-0000000000c2'$$, '23503');
select zz_check.fails_with($$delete from auth.users where id = '00000000-0000-0000-0000-0000000000c6'$$, '23503');
select zz_check.fails_with(format($$delete from nomad_hospital.patients where id = %L$$, (select v from zz_check.vals where k = 'p1')), '23503');
-- 퇴사자(c6)는 비활성으로 남음
select zz_check.expect($$select count(*) from nomad_hospital.staff where user_id = '00000000-0000-0000-0000-0000000000c6' and not active$$, 1);

-- ==== 9. 감사 로그 update·delete·truncate 거부 (소유자로도) ====
select zz_check.fails_with($$update nomad_hospital.audit_logs set action = 'x'$$, 'append-only');
select zz_check.fails_with($$delete from nomad_hospital.audit_logs$$, 'append-only');
select zz_check.fails_with($$truncate nomad_hospital.audit_logs$$, 'truncate is not allowed');
-- 파기 스위치를 켜도 감사 로그 삭제는 불가
select set_config('nomad_hospital.allow_purge', 'on', true);
select zz_check.fails_with($$delete from nomad_hospital.audit_logs$$, 'append-only');
select set_config('nomad_hospital.allow_purge', 'off', true);

-- ==== 10. 보존·파기 ====
-- 오래된 합성 기록(소유자로 직접 넣음): 11년 전 메모 1, 6년 전 예약 1(5년), 2년 전 연락 1(3년 보존 → 아직)
insert into nomad_hospital.consult_notes (id, patient_id, author_id, note_enc, created_at)
  values ('00000000-0000-0000-0000-0000000000d1', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c2', 'enc:old', now() - interval '11 years');
insert into nomad_hospital.contact_logs (id, patient_id, channel, summary_enc, created_by, created_at)
  values ('00000000-0000-0000-0000-0000000000d2', (select v::uuid from zz_check.vals where k = 'p1'), 'sms', 'enc:sms', '00000000-0000-0000-0000-0000000000c4', now() - interval '2 years');
insert into nomad_hospital.appointments (id, patient_id, staff_id, scheduled_at, status, created_by, created_at)
  values ('00000000-0000-0000-0000-0000000000d3', (select v::uuid from zz_check.vals where k = 'p1'), '00000000-0000-0000-0000-0000000000c2',
          now() - interval '6 years', 'done', '00000000-0000-0000-0000-0000000000c4', now() - interval '6 years');
insert into zz_check.vals values ('n_old', '00000000-0000-0000-0000-0000000000d1'), ('c_recent', '00000000-0000-0000-0000-0000000000d2'),
  ('a_old', '00000000-0000-0000-0000-0000000000d3');
set local role service_role;
-- 후보: 11년 전 메모 + 6년 전 예약
select zz_check.expect($$select count(*) from nomad_hospital.list_purge_candidates('00000000-0000-0000-0000-0000000000c1')$$, 2);
select zz_check.fails_with($$select * from nomad_hospital.list_purge_candidates('00000000-0000-0000-0000-0000000000c2')$$, '42501');
-- 법무 확인 전(legal_review_pending=true, 기본값)이면 기간이 지나도 파기 거부(fail-closed)
select zz_check.fails_with(format($$select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'consult_note', %L, '보존 만료')$$, (select v from zz_check.vals where k = 'n_old')), 'HP005');
select zz_check.fails_with(format($$select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'appointment', %L, '보존 만료')$$, (select v from zz_check.vals where k = 'a_old')), 'HP005');
-- 법무 확인 완료를 가정(검사 트랜잭션 안에서만, rollback)
reset role;
update nomad_hospital.retention_policies set legal_review_pending = false;
set local role service_role;
-- 기간 전 파기 거부(오늘 메모·2년 전 연락)
select zz_check.fails_with(format($$select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'consult_note', %L, '보존 만료')$$, (select v from zz_check.vals where k = 'n1')), 'HP003');
select zz_check.fails_with(format($$select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'contact_log', %L, '보존 만료')$$, (select v from zz_check.vals where k = 'c_recent')), 'HP003');
-- 관리자 외 파기 거부, 사유 필수
select zz_check.fails_with(format($$select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c2', 'consult_note', %L, '보존 만료')$$, (select v from zz_check.vals where k = 'n_old')), '42501');
select zz_check.fails_with(format($$select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'consult_note', %L, '')$$, (select v from zz_check.vals where k = 'n_old')), '22023');
-- 기간 후 파기 + 감사 (메모·예약)
select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'consult_note', (select v::uuid from zz_check.vals where k = 'n_old'), '보존 기간 만료(검사)');
select nomad_hospital.purge_record('00000000-0000-0000-0000-0000000000c1', 'appointment', (select v::uuid from zz_check.vals where k = 'a_old'), '보존 기간 만료(검사)');
reset role;
select zz_check.expect(format($$select count(*) from nomad_hospital.consult_notes where id = %L$$, (select v from zz_check.vals where k = 'n_old')), 0);
select zz_check.expect(format($$select count(*) from nomad_hospital.appointments where id = %L$$, (select v from zz_check.vals where k = 'a_old')), 0);
select zz_check.expect($$select count(*) from nomad_hospital.audit_logs where action = 'purge.record'
  and target_id in ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d3')
  and detail ->> 'reason' = '보존 기간 만료(검사)' and actor_role = 'admin'$$, 2);
-- 파기 뒤 스위치는 꺼져 있어 직접 삭제 다시 거부
select zz_check.fails_with($$delete from nomad_hospital.consult_notes$$, 'append-only');
