-- user안 검사: 합성 사용자 2명(A·B) 교차 접근 거부 + 한도·동기화 컬럼·Worker 흐름. 마지막에 rollback.
-- run_check.sh가 begin·준비·이식 SQL 뒤에 이어 붙인다(단독 실행 금지).
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a-user@example.invalid', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'b-user@example.invalid', 'authenticated', 'authenticated');

-- Storage 객체(합성): A 폴더 아래 PDF 메타데이터
insert into storage.objects (bucket_id, name, metadata)
values ('knowflow-sources', 'aaaaaaaa-0000-0000-0000-00000000000a/11111111-0000-0000-0000-000000000001/22222222-2222-2222-2222-222222222222.pdf',
        '{"size": 1000, "mimetype": "application/pdf"}'::jsonb);

create temp table t_ids (k text primary key, v uuid);
create temp table t_job (j jsonb);
create temp table t_before (u timestamptz);
grant all on t_ids, t_job, t_before to public;

-- ===== A: 프로젝트 생성·한도 =====
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'pa', id from nomad_knowflow.create_project('A 프로젝트');
select public.t_eq((select count(*) from nomad_knowflow.projects), 1, 'A는 자기 프로젝트 1개 조회');
select nomad_knowflow.create_project('A 프로젝트 2');
select public.t_expect($q$select nomad_knowflow.create_project('A 3')$q$, 'KF429');

-- ===== B: 교차 접근 거부 =====
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
insert into t_ids select 'pb', id from nomad_knowflow.create_project('B 프로젝트');
select public.t_eq((select count(*) from nomad_knowflow.projects), 1, 'B는 자기 프로젝트 1개만 조회');
select public.t_eq((select count(*) from nomad_knowflow.projects where id = (select v from t_ids where k = 'pa')), 0, 'B는 A 프로젝트 안 보임');
select public.t_expect(format($q$select nomad_knowflow.update_project(%L, '{"name":"x"}')$q$, (select v from t_ids where k = 'pa')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_project(%L)$q$, (select v from t_ids where k = 'pa')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.list_project_jobs(%L)$q$, (select v from t_ids where k = 'pa')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', 'aaaaaaaa-0000-0000-0000-00000000000a/x/y.pdf', null, 'k1', 'h1')$q$, (select v from t_ids where k = 'pa')), '22023');
select public.t_eq((select count(*) from nomad_knowflow.user_quotas), 1, 'B는 자기 쿼터 행만');
-- 테이블 직접 쓰기·청크 직접 읽기 거부
select public.t_expect($q$insert into nomad_knowflow.projects (user_id, name) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'x')$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow.source_chunks$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow_private.idempotency_keys$q$, '42501');
select public.t_expect($q$select nomad_knowflow.claim_job()$q$, '42501');
select public.t_expect($q$select nomad_knowflow.register_youtube_source('bbbbbbbb-0000-0000-0000-00000000000b', gen_random_uuid(), 'abcdefghijk', 't', 'c', 10, 'k', 'h')$q$, '42501');

-- ===== A: PDF 등록 → Worker 처리 =====
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
-- PDF 경로의 프로젝트 id를 실제 프로젝트로 맞추기 위해 객체를 다시 만든다(postgres)
reset role;
insert into storage.objects (bucket_id, name, metadata)
select 'knowflow-sources', 'aaaaaaaa-0000-0000-0000-00000000000a/' || v || '/33333333-3333-3333-3333-333333333333.pdf',
       '{"size": 1000, "mimetype": "application/pdf"}'::jsonb from t_ids where k = 'pa';
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
-- B 폴더 경로로는 등록 불가
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', 'bbbbbbbb-0000-0000-0000-00000000000b/%s/33333333-3333-3333-3333-333333333333.pdf', null, 'k0', 'h0')$q$, (select v from t_ids where k = 'pa'), (select v from t_ids where k = 'pa')), '22023');
insert into t_ids select 'sa', (nomad_knowflow.register_pdf_source((select v from t_ids where k = 'pa'), '문서 A',
  'aaaaaaaa-0000-0000-0000-00000000000a/' || (select v from t_ids where k = 'pa') || '/33333333-3333-3333-3333-333333333333.pdf',
  null, 'key-a-1', 'hash-a-1') ->> 'source_id')::uuid;
-- 같은 멱등 키 재요청은 같은 자료
select public.t_eq((select (nomad_knowflow.register_pdf_source((select v from t_ids where k = 'pa'), '문서 A',
  'aaaaaaaa-0000-0000-0000-00000000000a/' || (select v from t_ids where k = 'pa') || '/33333333-3333-3333-3333-333333333333.pdf',
  null, 'key-a-1', 'hash-a-1') ->> 'duplicate')::boolean::int), 1, '멱등 키 재요청 duplicate');
select public.t_eq((select count(*) from nomad_knowflow.sources), 1, 'A 자료 1개');

-- Worker(service_role)
select public.t_role('service_role');
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from t_job where j is not null), 1, 'claim_job 작업 획득');
select public.t_eq((select count(*) from nomad_knowflow.replace_source_chunks(
  ((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int,
  '[{"chunk_index":0,"content":"안녕 지식","locator":{"page":1}}]'::jsonb) r where r), 1, 'replace_source_chunks');
select public.t_eq((select count(*) from nomad_knowflow.complete_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int) c where c), 1, 'complete_job');

-- 유튜브(service_role): A 프로젝트에 등록, 길이 초과·쿼터
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('aaaaaaaa-0000-0000-0000-00000000000a', %L, 'abcdefghijk', 't', 'c', 601, 'ky1', 'hy1')$q$, (select v from t_ids where k = 'pa')), 'KF413');
select public.t_eq((select count(*) from nomad_knowflow.register_youtube_source('aaaaaaaa-0000-0000-0000-00000000000a', (select v from t_ids where k = 'pa'), 'abcdefghijk', '영상', '채널', 500, 'ky2', 'hy2')), 1, 'A 유튜브 등록');
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('aaaaaaaa-0000-0000-0000-00000000000a', %L, 'abcdefghijk', '영상', '채널', 100, 'ky3', 'hy3')$q$, (select v from t_ids where k = 'pa')), '23505');
-- 다른 사용자 프로젝트에는 등록 불가
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('bbbbbbbb-0000-0000-0000-00000000000b', %L, 'zzzzzzzzzzz', '영상', '채널', 100, 'ky4', 'hy4')$q$, (select v from t_ids where k = 'pa')), 'P0002');
reset role;

-- ===== B: A의 자료·청크·작업 접근 거부 =====
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_eq((select count(*) from nomad_knowflow.sources), 0, 'B는 A 자료 안 보임');
select public.t_eq((select count(*) from nomad_knowflow.processing_jobs), 0, 'B는 A 작업 안 보임');
select public.t_eq((select count(*) from nomad_knowflow.usage_events), 0, 'B는 사용 기록 안 보임');
select public.t_expect(format($q$select nomad_knowflow.get_source_chunks(%L)$q$, (select v from t_ids where k = 'sa')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk', 'rh')$q$, (select v from t_ids where k = 'sa')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_sources(%L, array[%L]::uuid[])$q$, (select v from t_ids where k = 'pb'), (select v from t_ids where k = 'sa')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_sources(%L, array[%L]::uuid[])$q$, (select v from t_ids where k = 'pa'), (select v from t_ids where k = 'sa')), 'P0002');

-- ===== A: 청크 읽기·동기화 컬럼 =====
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select jsonb_array_length(nomad_knowflow.get_source_chunks((select v from t_ids where k = 'sa')) -> 'chunks')), 1, 'A는 자기 자료 청크 조회');
select public.t_eq((select count(*) from nomad_knowflow.list_project_jobs((select v from t_ids where k = 'pa'))), 2, 'A 작업 목록(PDF·유튜브)');
-- touch 트리거: 과거 시각으로 되돌려 놓고(트리거 우회) 수정하면 현재 시각으로 갱신돼야 한다
reset role;
set local session_replication_role = replica;
update nomad_knowflow.projects set updated_at = now() - interval '1 day' where id = (select v from t_ids where k = 'pa');
set local session_replication_role = origin;
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select nomad_knowflow.update_project((select v from t_ids where k = 'pa'), '{"name":"A 이름 변경"}');
select public.t_eq((select count(*) from nomad_knowflow.projects p where p.id = (select v from t_ids where k = 'pa') and p.updated_at > now() - interval '1 minute'), 1, 'update 시 updated_at 갱신(touch 트리거)');
-- 소프트 삭제 자료는 숨김(동기화는 deleted_at으로 전파)
select nomad_knowflow.delete_sources((select v from t_ids where k = 'pa'), array[(select v from t_ids where k = 'sa')]);
select public.t_eq((select count(*) from nomad_knowflow.sources where id = (select v from t_ids where k = 'sa')), 0, '삭제한 자료는 RLS로 숨김');
reset role;
select public.t_eq((select count(*) from nomad_knowflow.sources where id = (select v from t_ids where k = 'sa') and deleted_at is not null), 1, 'deleted_at 소프트 삭제 행은 남음');

-- ===== anon: 공개 읽기 없음, 인증 한도만 호출 가능 =====
select public.t_role('anon');
select public.t_expect($q$select * from nomad_knowflow.projects$q$, '42501');
select public.t_expect($q$select nomad_knowflow.create_project('x')$q$, '42501');
select public.t_eq((select count(*) from nomad_knowflow.consume_auth_rate_limit('login_ip', repeat('a', 64)) where allowed), 1, 'anon consume_auth_rate_limit 허용');
reset role;

-- Storage 정책: B는 A 폴더에 업로드 불가
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect($q$insert into storage.objects (bucket_id, name) values ('knowflow-sources', 'aaaaaaaa-0000-0000-0000-00000000000a/x/y.pdf')$q$, '42501');
select public.t_eq((select count(*) from storage.objects where bucket_id = 'knowflow-sources'), 0, 'B는 A 폴더 객체 안 보임');
reset role;

select 'USER CHECK PASSED' as result;
rollback;
