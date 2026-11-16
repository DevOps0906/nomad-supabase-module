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
select public.t_eq((select used_source_jobs from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 1, '같은 멱등 키 재요청 시 차감 1회(PDF)');
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

-- ===== 기능 잠금(task-007): 재시도 멱등 차감 1회 · 구독 끊김 = 쓰기 잠금 · 읽기 유지 =====
-- user안 이용권 = 사용자가 owner인 활성 조직(가입 시 개인 조직) 중 하나라도 기능이 열려 있으면 허용
insert into t_ids select 'oa', organization_id from nomad_core.memberships
 where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and role = 'owner' limit 1;
select public.t_eq((select count(*) from t_ids where k = 'oa'), 1, 'A 개인 조직(owner) 존재');
insert into t_ids select 'yt', id from nomad_knowflow.sources
 where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a' and source_type = 'youtube';
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'no_handler', false) f where f = 'failed'), 1, '유튜브 작업 실패(환불)');
reset role;
select public.t_eq((select used_source_jobs + used_video_seconds from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 1, '실패 잡 환불(source_jobs 1·video_seconds 0)');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select nomad_knowflow.retry_source((select v from t_ids where k = 'yt'), 'rk-1', 'rh-1');
select public.t_eq((select (nomad_knowflow.retry_source((select v from t_ids where k = 'yt'), 'rk-1', 'rh-1') ->> 'duplicate')::boolean::int), 1, '재시도 멱등 키 재요청 duplicate');
select public.t_eq((select used_source_jobs from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 2, '같은 멱등 키 재시도 차감 1회(source_jobs)');
select public.t_eq((select used_video_seconds from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 500, '같은 멱등 키 재시도 차감 1회(video_seconds)');

-- 보고서 잠금: C 플랜(구독 없음)에는 space_reports가 없다 → create_report 거부
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, 'r', 'rk-c')$q$, (select v from t_ids where k = 'pa')), 'KF403');

-- 잠금 준비: C 플랜에서 knowflow 기능을 빼고(검사 트랜잭션 안에서만) A 개인 조직에 B 구독
reset role;
delete from nomad_core.plan_features where product_code = 'knowflow' and plan_code = 'C';
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
select v, 'knowflow', 'B', 'active' from t_ids where k = 'oa';
insert into storage.objects (bucket_id, name, metadata)
select 'knowflow-sources', 'aaaaaaaa-0000-0000-0000-00000000000a/' || v || '/44444444-4444-4444-4444-444444444444.pdf',
       '{"size": 1000, "mimetype": "application/pdf"}'::jsonb from t_ids where k = 'pa';
select public.t_role('service_role');
with c as (insert into nomad_knowflow.conversations (project_id, user_id, title)
  select v, 'aaaaaaaa-0000-0000-0000-00000000000a', '대화' from t_ids where k = 'pa' returning id)
insert into t_ids select 'cv', id from c;
-- task-017: 질문·답변·보고서는 RPC만(서버 직접 insert·메시지 수정 거부)
select public.t_expect(format($q$insert into nomad_knowflow.messages (conversation_id, role, content) values (%L, 'user', '질문')$q$, (select v from t_ids where k = 'cv')), '42501');
select public.t_expect(format($q$insert into nomad_knowflow.messages (conversation_id, role, content) values (%L, 'assistant', '답변')$q$, (select v from t_ids where k = 'cv')), '42501');
select public.t_expect($q$update nomad_knowflow.messages set role = 'user'$q$, '42501');
select public.t_expect(format($q$insert into nomad_knowflow.reports (project_id, user_id, title) values (%L, 'aaaaaaaa-0000-0000-0000-00000000000a', '보고서')$q$, (select v from t_ids where k = 'pa')), '42501');
-- 질문: 멱등 키 재요청은 같은 메시지·차감 1회, 같은 키 다른 내용은 KF409, 남의 대화는 P0002
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'q1', (nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문', 'qk-1') ->> 'message_id')::uuid;
select public.t_eq((select ((r ->> 'duplicate')::boolean and (r ->> 'message_id')::uuid = (select v from t_ids where k = 'q1'))::int
  from nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문', 'qk-1') r), 1, '질문 멱등 키 재요청은 같은 메시지');
select public.t_eq((select used_questions from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 1, '같은 멱등 키 질문 차감 1회');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '다른 질문', 'qk-1')$q$, (select v from t_ids where k = 'cv')), 'KF409');
select public.t_eq((select count(*) from nomad_knowflow.messages), 1, '구독 중 질문 생성');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, 'x', 'qk-b')$q$, (select v from t_ids where k = 'cv')), 'P0002');
select public.t_expect($q$select nomad_knowflow.save_answer(gen_random_uuid(), 'x')$q$, '42501');
-- 월 질문 한도(5): 4개 더 → 6번째 KF429(차감 없음)
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'q' || i, (nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문 ' || i, 'qk-' || i) ->> 'message_id')::uuid
  from generate_series(2, 5) i;
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '질문 6', 'qk-6')$q$, (select v from t_ids where k = 'cv')), 'KF429');
select public.t_eq((select used_questions from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 5, '질문 한도 초과는 차감 없음');
-- 답변(service_role): 질문 1개당 1개, 재저장은 같은 답변, assistant·없는 메시지에는 P0002
select public.t_role('service_role');
insert into t_ids select 'an', (nomad_knowflow.save_answer((select v from t_ids where k = 'q1'), '답변', '{"chunks":[]}') ->> 'answer_id')::uuid;
select public.t_eq((select ((r ->> 'duplicate')::boolean and (r ->> 'answer_id')::uuid = (select v from t_ids where k = 'an'))::int
  from nomad_knowflow.save_answer((select v from t_ids where k = 'q1'), '답변 2') r), 1, '같은 질문 답변 재저장은 같은 답변');
select public.t_expect(format($q$select nomad_knowflow.save_answer(%L, 'x')$q$, (select v from t_ids where k = 'an')), 'P0002');
select public.t_expect($q$select nomad_knowflow.save_answer(gen_random_uuid(), 'x')$q$, 'P0002');
select public.t_eq((select count(*) from nomad_knowflow.messages m where m.reply_to = (select v from t_ids where k = 'q1')), 1, '답변은 질문 참조');
-- 질문 쿼터 환불(결정 2, service_role): 답변 있는 질문 KF409 · 1회만(이번 달 사용량 -1) · 환불된 질문 답변 저장 KF409
-- · 지난달 차감분은 표식만 지우고 사용량 그대로 · 이관 행(표식 null)은 환불 안 함 · 사용자 롤 실행 불가
select public.t_expect(format($q$select nomad_knowflow.refund_question_quota(%L)$q$, (select v from t_ids where k = 'q1')), 'KF409');
select public.t_expect(format($q$select nomad_knowflow.refund_question_quota(%L)$q$, (select v from t_ids where k = 'an')), 'P0002');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q5')) ->> 'refunded')::boolean::int), 1, '질문 환불 성공');
select public.t_eq((select used_questions from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 4, '질문 환불은 이번 달 사용량 -1');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q5')) ->> 'refunded')::boolean::int), 0, '재환불은 false(1회만)');
select public.t_eq((select used_questions from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 4, '재환불은 사용량 변화 없음');
select public.t_expect(format($q$select nomad_knowflow.save_answer(%L, 'x')$q$, (select v from t_ids where k = 'q5')), 'KF409');
reset role;
update nomad_knowflow.messages set quota_charged_period = (nomad_knowflow_private.current_period_start() - interval '1 month')::date where id = (select v from t_ids where k = 'q4');
update nomad_knowflow.messages set quota_charged_period = null where id = (select v from t_ids where k = 'q3');
select public.t_role('service_role');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q4')) ->> 'refunded')::boolean::int), 1, '지난달 차감분 환불은 표식만');
select public.t_eq((select used_questions from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 4, '지난달 차감분 환불은 사용량 그대로');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q3')) ->> 'refunded')::boolean::int), 0, '이관 행(표식 null)은 환불 안 함');
select public.t_eq((select count(*) from nomad_knowflow.messages where id = (select v from t_ids where k = 'q3') and quota_refunded_at is null), 1, '이관 행은 환불 표시 없음');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select ((nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문', 'qk-1') ->> 'answer_id')::uuid
  = (select v from t_ids where k = 'an'))::int), 1, '질문 재요청은 답변 id도 반환');
-- 환불된 질문을 같은 멱등 키로 다시 불러도 재차감 없이 refunded=true, 사용자는 환불 RPC 실행 불가
select public.t_eq((select (nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문 5', 'qk-5') ->> 'refunded')::boolean::int), 1, '환불된 질문 재요청은 refunded');
select public.t_eq((select used_questions from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 4, '환불된 질문 재요청은 차감 없음');
select public.t_expect(format($q$select nomad_knowflow.refund_question_quota(%L)$q$, (select v from t_ids where k = 'q2')), '42501');
-- 보고서: 멱등 키 재요청 차감 1회 · 다른 내용 KF409 · 남의 프로젝트 P0002 · 생성 작업 실패 시 환불·failed
insert into t_ids select 'rp', (nomad_knowflow.create_report((select v from t_ids where k = 'pa'), '보고서', 'rk-r1') ->> 'report_id')::uuid;
select public.t_eq((select ((r ->> 'duplicate')::boolean and (r ->> 'report_id')::uuid = (select v from t_ids where k = 'rp'))::int
  from nomad_knowflow.create_report((select v from t_ids where k = 'pa'), '보고서', 'rk-r1') r), 1, '보고서 멱등 키 재요청은 같은 보고서');
select public.t_eq((select used_reports from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 1, '같은 멱등 키 보고서 차감 1회');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, '다른 보고서', 'rk-r1')$q$, (select v from t_ids where k = 'pa')), 'KF409');
select public.t_eq((select count(*) from nomad_knowflow.reports), 1, 'B 구독 중 보고서 생성');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, 'x', 'rk-b')$q$, (select v from t_ids where k = 'pa')), 'P0002');
reset role;
update nomad_knowflow.processing_jobs set status = 'cancelled' where status = 'queued' and job_type <> 'report_generate';
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from t_job where (j ->> 'report_id')::uuid = (select v from t_ids where k = 'rp')), 1, '보고서 생성 작업 획득');
select public.t_eq((select count(*) from nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'llm_error', false) f where f = 'failed'), 1, '보고서 작업 실패');
reset role;
select public.t_eq((select used_reports from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 0, '보고서 실패 환불');
select public.t_eq((select count(*) from nomad_knowflow.reports where id = (select v from t_ids where k = 'rp') and status = 'failed'), 1, '보고서 실패 상태');
-- 환불은 차감 1건에 묶인다(quota_charged_period 표식): 같은 보고서 잡 두 번 실패·ready 뒤 실패·지난달 표식은 환불 없음
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'rp2', (nomad_knowflow.create_report((select v from t_ids where k = 'pa'), '보고서 2', 'rk-r2') ->> 'report_id')::uuid;
select public.t_eq((select used_reports from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 1, '보고서 2 차감');
reset role;
select public.t_eq((select count(*) from nomad_knowflow.reports where id = (select v from t_ids where k = 'rp') and quota_charged_period is null), 1, '환불한 보고서는 표식 해제');
insert into nomad_knowflow.processing_jobs (user_id, report_id, job_type) select 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid, v, 'report_generate' from t_ids where k = 'rp';
update nomad_knowflow.reports set status = 'ready' where id = (select v from t_ids where k = 'rp2');
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'llm_error', false);
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'llm_error', false);
reset role;
select public.t_eq((select count(*) from nomad_knowflow.processing_jobs where job_type = 'report_generate' and status = 'failed'), 3, '보고서 잡 3건 실패');
select public.t_eq((select used_reports from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 1, '같은 보고서 두 번째 실패·ready 뒤 실패는 환불 없음');
select public.t_eq((select count(*) from nomad_knowflow.reports where id = (select v from t_ids where k = 'rp2') and status = 'ready'), 1, 'ready 보고서 상태 유지');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'rp3', (nomad_knowflow.create_report((select v from t_ids where k = 'pa'), '보고서 3', 'rk-r3') ->> 'report_id')::uuid;
reset role;
update nomad_knowflow.reports set quota_charged_period = (quota_charged_period - interval '1 month')::date where id = (select v from t_ids where k = 'rp3');
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from t_job where (j ->> 'report_id')::uuid = (select v from t_ids where k = 'rp3')), 1, '보고서 3 작업 획득');
select nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'llm_error', false);
reset role;
select public.t_eq((select used_reports from nomad_knowflow.user_quotas where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 2, '지난달 표식 보고서 실패는 이번 달 사용량 불변');
update nomad_core.subscriptions set status = 'inactive'
 where organization_id = (select v from t_ids where k = 'oa') and product_code = 'knowflow';

-- 잠김: 대화·등록·재시도 거부
select public.t_role('service_role');
select public.t_expect(format($q$insert into nomad_knowflow.conversations (project_id, user_id) values (%L, 'aaaaaaaa-0000-0000-0000-00000000000a')$q$, (select v from t_ids where k = 'pa')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('aaaaaaaa-0000-0000-0000-00000000000a', %L, 'lmnopqrstuv', '영상', '채널', 10, 'ky9', 'hy9')$q$, (select v from t_ids where k = 'pa')), 'KF403');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '질문 9', 'qk-9')$q$, (select v from t_ids where k = 'cv')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '질문', 'qk-1')$q$, (select v from t_ids where k = 'cv')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, '보고서', 'rk-r1')$q$, (select v from t_ids where k = 'pa')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', 'aaaaaaaa-0000-0000-0000-00000000000a/%s/44444444-4444-4444-4444-444444444444.pdf', null, 'key-9', 'hash-9')$q$, (select v from t_ids where k = 'pa'), (select v from t_ids where k = 'pa')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk-2', 'rh-2')$q$, (select v from t_ids where k = 'yt')), 'KF403');
-- 잠겨도 읽기는 유지
select public.t_eq((select count(*) from nomad_knowflow.sources), 1, '잠김: 자료 읽기 유지');
select public.t_eq((select count(*) from nomad_knowflow.messages), 6, '잠김: 메시지 읽기 유지');
select public.t_eq((select count(*) from nomad_knowflow.projects), 2, '잠김: 프로젝트 읽기 유지');
select public.t_eq((select (count(*) > 0)::int from nomad_knowflow.list_project_jobs((select v from t_ids where k = 'pa'))), 1, '잠김: 작업 목록 유지');
-- 잠김: 잠기기 전 질문의 답변 저장은 허용
select public.t_role('service_role');
select nomad_knowflow.save_answer((select v from t_ids where k = 'q2'), '답변 q2');
select public.t_eq((select count(*) from nomad_knowflow.messages where role = 'assistant'), 2, '잠김: assistant 답변 허용');
-- 잠김에도 남의 프로젝트·자료는 P0002(존재 노출 없음)
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('aaaaaaaa-0000-0000-0000-00000000000a', %L, 'lmnopqrstuv', '영상', '채널', 10, 'ky8', 'hy8')$q$, (select v from t_ids where k = 'pb')), 'P0002');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', 'aaaaaaaa-0000-0000-0000-00000000000a/%s/44444444-4444-4444-4444-444444444444.pdf', null, 'key-8', 'hash-8')$q$, (select v from t_ids where k = 'pb'), (select v from t_ids where k = 'pb')), 'P0002');
select public.t_expect($q$select nomad_knowflow.retry_source(gen_random_uuid(), 'rk-8', 'rh-8')$q$, 'P0002');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk-7', 'rh-7')$q$, (select v from t_ids where k = 'yt')), 'P0002');
-- 잠김: 같은 멱등 키 재요청도 KF403
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, '문서 A', 'aaaaaaaa-0000-0000-0000-00000000000a/%s/33333333-3333-3333-3333-333333333333.pdf', null, 'key-a-1', 'hash-a-1')$q$, (select v from t_ids where k = 'pa'), (select v from t_ids where k = 'pa')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk-1', 'rh-1')$q$, (select v from t_ids where k = 'yt')), 'KF403');
-- ends_at 만료(status active)로도 잠김
reset role;
update nomad_core.subscriptions set status = 'active', starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
 where organization_id = (select v from t_ids where k = 'oa') and product_code = 'knowflow';
select public.t_role('service_role');
select public.t_expect(format($q$insert into nomad_knowflow.conversations (project_id, user_id) values (%L, 'aaaaaaaa-0000-0000-0000-00000000000a')$q$, (select v from t_ids where k = 'pa')), 'KF403');
-- 구독한 팀 조직: owner(A)만 열리고 admin(B)·editor(C)는 잠김
reset role;
insert into auth.users (id, email, aud, role) values
  ('cccccccc-0000-0000-0000-00000000000c', 'c-user@example.invalid', 'authenticated', 'authenticated');
select public.t_login('cccccccc-0000-0000-0000-00000000000c');
insert into t_ids select 'pc', id from nomad_knowflow.create_project('C 프로젝트');
reset role;
insert into nomad_core.organizations (id, name) values ('07070707-0000-0000-0000-000000000007', '팀');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('07070707-0000-0000-0000-000000000007', 'aaaaaaaa-0000-0000-0000-00000000000a', 'owner'),
  ('07070707-0000-0000-0000-000000000007', 'bbbbbbbb-0000-0000-0000-00000000000b', 'admin'),
  ('07070707-0000-0000-0000-000000000007', 'cccccccc-0000-0000-0000-00000000000c', 'editor');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
values ('07070707-0000-0000-0000-000000000007', 'knowflow', 'B', 'active');
select public.t_role('service_role');
select public.t_expect(format($q$insert into nomad_knowflow.conversations (project_id, user_id) values (%L, 'bbbbbbbb-0000-0000-0000-00000000000b')$q$, (select v from t_ids where k = 'pb')), 'KF403');
select public.t_expect(format($q$insert into nomad_knowflow.conversations (project_id, user_id) values (%L, 'cccccccc-0000-0000-0000-00000000000c')$q$, (select v from t_ids where k = 'pc')), 'KF403');
insert into nomad_knowflow.conversations (project_id, user_id) select v, 'aaaaaaaa-0000-0000-0000-00000000000a' from t_ids where k = 'pa';
select public.t_eq((select count(*) from nomad_knowflow.conversations where user_id = 'aaaaaaaa-0000-0000-0000-00000000000a'), 2, '구독 팀 조직 owner(A)는 열림');
reset role;

select 'USER CHECK PASSED' as result;
rollback;
