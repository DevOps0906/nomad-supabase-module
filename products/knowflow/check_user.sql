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

-- ===== 0003: 영상 요약 격리·권한 + 권리자 삭제(takedown) 뒤 재저장 거부 =====
-- 자료 3개: ta(A, 영상 tkdnvideo01) · tb(B, 같은 영상) · tc(A, 다른 영상 othervideo1). 자료마다 running 작업 jr_* · succeeded 작업 jd_*
reset role;
insert into t_ids (k, v) select k, gen_random_uuid() from unnest(array['ta', 'tb', 'tc', 'jr_ta', 'jr_tb', 'jr_tc', 'jd_ta', 'jd_tb', 'jd_tc']) k;
insert into nomad_knowflow.sources (id, project_id, user_id, source_type, title, original_url, video_id, duration_seconds, status)
select (select v from t_ids where k = x.k), (select v from t_ids where k = x.pk), x.o::uuid, 'youtube', '영상 ' || x.k,
       'https://www.youtube.com/watch?v=' || x.vid, x.vid, 100, 'processing'
  from (values ('ta', 'pa', 'aaaaaaaa-0000-0000-0000-00000000000a', 'tkdnvideo01'), ('tb', 'pb', 'bbbbbbbb-0000-0000-0000-00000000000b', 'tkdnvideo01'), ('tc', 'pa', 'aaaaaaaa-0000-0000-0000-00000000000a', 'othervideo1')) x(k, pk, o, vid);
insert into nomad_knowflow.processing_jobs (id, user_id, source_id, job_type, status, attempt_count, started_at)
select (select v from t_ids where k = 'jr_' || s.title_k), s.user_id, s.id, 'source_ingest', 'running', 1, now()
  from (select substr(title, 4) as title_k, * from nomad_knowflow.sources where id in (select v from t_ids where k in ('ta', 'tb', 'tc'))) s;
insert into nomad_knowflow.processing_jobs (id, user_id, source_id, job_type, status, progress, attempt_count, started_at, finished_at)
select (select v from t_ids where k = 'jd_' || s.title_k), s.user_id, s.id, 'source_ingest', 'succeeded', 100, 1, now(), now()
  from (select substr(title, 4) as title_k, * from nomad_knowflow.sources where id in (select v from t_ids where k in ('ta', 'tb', 'tc'))) s;
create temp table t_kf3 (k text primary key, ok boolean);
grant all on t_kf3 to public;
select public.t_role('service_role');
insert into t_kf3 select 'chunks_' || x.k, nomad_knowflow.replace_source_chunks((select v from t_ids where k = 'jr_' || x.k), 1,
  '[{"chunk_index":0,"content":"청크 0","locator":{"t_start":0}},{"chunk_index":1,"content":"청크 1","locator":{"t_start":10}}]'::jsonb)
  from (values ('ta'), ('tb'), ('tc')) x(k);
insert into t_kf3 select 'moments_' || x.k, nomad_knowflow.replace_source_moments((select v from t_ids where k = 'jr_' || x.k), 1,
  '[{"moment_index":0,"locator":{"t_start":0,"t_end":10},"title":"장면","description":"설명"}]'::jsonb)
  from (values ('ta'), ('tb'), ('tc')) x(k);
insert into t_kf3 select 'summary_' || x.k, nomad_knowflow.save_source_summary((select v from t_ids where k = 'jd_' || x.k),
  jsonb_build_array(jsonb_build_object('text', '요약 문장', 'chunk_ids',
    (select jsonb_agg(c.id::text) from nomad_knowflow.source_chunks c where c.source_id = (select v from t_ids where k = x.k)))), 'test-model')
  from (values ('ta'), ('tb'), ('tc')) x(k);
select public.t_eq((select count(*) from t_kf3 where ok), 9, '0003 준비: 청크·장면·요약 저장 9건');
reset role;

-- 요약 격리: 자기 요약만
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select count(*) from nomad_knowflow.source_summaries), 2, 'A는 자기 요약 2건만');
select public.t_eq((select count(*) from nomad_knowflow.source_summaries where source_id = (select v from t_ids where k = 'tb')), 0, 'A는 B 요약 안 보임');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_eq((select count(*) from nomad_knowflow.source_summaries), 1, 'B는 자기 요약 1건만');
-- service_role 외 실행·직접 쓰기 거부
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.save_source_summary(%L, '[{"text":"x","chunk_ids":[]}]', 'm')$q$, (select v from t_ids where k = 'jd_ta')), '42501');
select public.t_expect($q$select nomad_knowflow.takedown_video('tkdnvideo01', '사유')$q$, '42501');
select public.t_expect(format($q$select nomad_knowflow.replace_source_moments(%L, 1, '[]')$q$, (select v from t_ids where k = 'jr_ta')), '42501');
select public.t_expect(format($q$update nomad_knowflow.source_summaries set model = 'x' where source_id = %L$q$, (select v from t_ids where k = 'ta')), '42501');
select public.t_expect(format($q$delete from nomad_knowflow.source_summaries where source_id = %L$q$, (select v from t_ids where k = 'ta')), '42501');
select public.t_role('anon');
select public.t_expect($q$select nomad_knowflow.takedown_video('tkdnvideo01', '사유')$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow.source_summaries$q$, '42501');

-- takedown: 같은 영상의 모든 자료 비활성 + 청크·장면·요약 삭제, 진행 중 작업 수 반환
select public.t_role('service_role');
select public.t_expect($q$select nomad_knowflow.takedown_video('bad', '사유')$q$, '22023');
select public.t_expect($q$select nomad_knowflow.takedown_video('tkdnvideo01', '  ')$q$, '22023');
delete from t_job;
insert into t_job select nomad_knowflow.takedown_video('tkdnvideo01', '권리자 요청(합성)');
select public.t_eq((select (j ->> 'sources')::int from t_job), 2, 'takedown 자료 2건(A·B)');
select public.t_eq((select (j ->> 'chunks_deleted')::int from t_job), 4, 'takedown 청크 4건 삭제');
select public.t_eq((select (j ->> 'moments_deleted')::int from t_job), 2, 'takedown 장면 2건 삭제');
select public.t_eq((select (j ->> 'summaries_deleted')::int from t_job), 2, 'takedown 요약 2건 삭제');
select public.t_eq((select (j ->> 'active_jobs')::int from t_job), 2, 'takedown 진행 중 작업 2건');
-- takedown 뒤 진행 중 작업의 재저장 거부(false, 아무것도 안 바뀜)
select public.t_eq((select count(*) from nomad_knowflow.replace_source_chunks((select v from t_ids where k = 'jr_ta'), 1,
  '[{"chunk_index":0,"content":"되살림","locator":{}}]'::jsonb) r where not r), 1, 'takedown 뒤 replace_source_chunks 거부');
select public.t_eq((select count(*) from nomad_knowflow.replace_source_moments((select v from t_ids where k = 'jr_ta'), 1,
  '[{"moment_index":0,"locator":{"t_start":0,"t_end":10},"title":"장면","description":"설명"}]'::jsonb) r where not r), 1, 'takedown 뒤 replace_source_moments 거부');
select public.t_eq((select count(*) from nomad_knowflow.save_source_summary((select v from t_ids where k = 'jd_tb'),
  '[{"text":"되살림","chunk_ids":["00000000-0000-0000-0000-000000000000"]}]'::jsonb, 'm') r where not r), 1, 'takedown 뒤 save_source_summary 거부');
reset role;
select public.t_eq((select count(*) from nomad_knowflow.source_chunks where source_id in (select v from t_ids where k in ('ta', 'tb'))), 0, 'takedown 자료 청크 0');
select public.t_eq((select count(*) from nomad_knowflow.source_moments where source_id in (select v from t_ids where k in ('ta', 'tb'))), 0, 'takedown 자료 장면 0');
select public.t_eq((select count(*) from nomad_knowflow.source_summaries where source_id in (select v from t_ids where k in ('ta', 'tb'))), 0, 'takedown 자료 요약 0');
-- 다른 영상(tc)은 영향 없음
select public.t_eq((select count(*) from nomad_knowflow.sources where id = (select v from t_ids where k = 'tc') and unavailable_at is null), 1, '다른 영상 자료 활성 유지');
select public.t_eq((select count(*) from nomad_knowflow.source_chunks where source_id = (select v from t_ids where k = 'tc')), 2, '다른 영상 청크 유지');
select public.t_eq((select count(*) from nomad_knowflow.source_moments where source_id = (select v from t_ids where k = 'tc')), 1, '다른 영상 장면 유지');
select public.t_eq((select count(*) from nomad_knowflow.source_summaries where source_id = (select v from t_ids where k = 'tc')), 1, '다른 영상 요약 유지');
select public.t_eq((select count(*) from nomad_core.audit_log where action = 'knowflow.rights_takedown' and target_id = 'tkdnvideo01'), 1, 'takedown 감사 기록 1건');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select count(*) from nomad_knowflow.source_summaries), 1, 'takedown 뒤 A 요약은 다른 영상 1건');
reset role;

-- ===== 0004: L1 캡처 소유자 격리·영상당 20장·영상 삭제/비활성 시 제거·Storage 정책 (org안 블록의 user안 대응) =====
-- 준비(postgres): A 프로젝트, 유튜브 자료 2개(y1·y2)·PDF 자료 1개, 장면 카드. 경로 첫 폴더 = user_id
reset role;
insert into nomad_knowflow.projects (id, user_id, name) values
  ('10000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', 'A 캡처 프로젝트');
insert into nomad_knowflow.sources (id, project_id, user_id, source_type, title, original_url, video_id, status) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a',
   'youtube', '영상 1', 'https://www.youtube.com/watch?v=capvideo001', 'capvideo001', 'completed'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a',
   'youtube', '영상 2', 'https://www.youtube.com/watch?v=capvideo002', 'capvideo002', 'completed');
insert into nomad_knowflow.sources (id, project_id, user_id, source_type, title, storage_path, status) values
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a',
   'pdf', '문서', 'aaaaaaaa-0000-0000-0000-00000000000a/10000000-0000-0000-0000-000000000001/x.pdf', 'completed');
insert into nomad_knowflow.source_moments (id, source_id, project_id, user_id, moment_index, locator, title, description) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-00000000000a', 0, '{"t_start": 12.5, "t_end": 30}', '장면 1', '설명'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-00000000000a', 0, '{"t_start": 5, "t_end": 9}', '장면 2', '설명');

create temp table t_cap (k text primary key, j jsonb);
grant all on t_cap to public;

-- 입력 검증
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'image/jpeg', 100)$q$, '22023');
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'image/png', 2097153)$q$, '22023');
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000001', 'image/png', 100)$q$, '22023');
-- 다른 자료의 장면 카드
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 'image/png', 100)$q$, 'P0002');

-- 영상당 20장, 21장째 거절
insert into t_cap select 'first', nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'image/webp', 1000);
select public.t_eq((select count(*) from t_cap where j ->> 'storage_path' like
  'aaaaaaaa-0000-0000-0000-00000000000a/10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/%.webp'), 1, '캡처 경로 = 사용자/프로젝트/자료/캡처.webp');
select public.t_eq((select ((j ->> 't_seconds')::numeric * 10)::bigint from t_cap where k = 'first'), 125, '캡처 시각 = 장면 카드 t_start');
select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'image/png', 1000)
  from generate_series(2, 20);
select public.t_eq((select count(*) from nomad_knowflow.source_captures), 20, 'A는 캡처 20장 조회');
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'image/png', 1000)$q$, 'KF429');
select public.t_eq((select count(*) from nomad_knowflow.source_captures), 20, '21장째 거절 후에도 20장');
-- 다른 영상은 따로 센다
insert into t_cap select 'y2', nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 'image/png', 1000);

-- Storage: 행 경로에는 업로드 가능, 행 없는 경로는 불가
insert into storage.objects (bucket_id, name, metadata)
select 'knowflow-captures', j ->> 'storage_path', '{"size": 1000, "mimetype": "image/webp"}'::jsonb from t_cap where k = 'first';
select public.t_expect($q$insert into storage.objects (bucket_id, name) values ('knowflow-captures', 'aaaaaaaa-0000-0000-0000-00000000000a/10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/99999999-9999-9999-9999-999999999999.png')$q$, '42501');
select public.t_eq((select count(*) from storage.objects where bucket_id = 'knowflow-captures'), 1, 'A는 자기 캡처 객체 조회');

-- B: 타인 캡처 접근 불가
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_eq((select count(*) from nomad_knowflow.source_captures), 0, 'B는 A 캡처를 볼 수 없음');
select public.t_eq((select count(*) from storage.objects where bucket_id = 'knowflow-captures'), 0, 'B는 A 캡처 객체를 볼 수 없음');
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 'image/png', 1000)$q$, 'P0002');
select public.t_eq((select nomad_knowflow.discard_source_capture((select (j ->> 'capture_id')::uuid from t_cap where k = 'y2'))::int), 0, 'B는 A 캡처 삭제 불가');
select public.t_expect(format($q$insert into storage.objects (bucket_id, name) values ('knowflow-captures', %L)$q$,
  (select j ->> 'storage_path' from t_cap where k = 'y2')), '42501');
select public.t_expect(format($q$insert into storage.objects (bucket_id, name) values ('knowflow-captures', %L)$q$,
  'bbbbbbbb-0000-0000-0000-00000000000b/' || (select j ->> 'storage_path' from t_cap where k = 'y2')), '42501');
select public.t_expect($q$insert into nomad_knowflow.source_captures (source_id, project_id, user_id, t_seconds, mime_type, byte_size, storage_path, created_by) values ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', 0, 'image/png', 1, 'x', 'bbbbbbbb-0000-0000-0000-00000000000b')$q$, '42501');
select public.t_expect($q$select nomad_knowflow.claim_capture_object_trash(10)$q$, '42501');
select public.t_expect($q$select nomad_knowflow.ack_capture_object_trash(array['x'])$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow_private.capture_object_trash$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow.list_stalled_capture_object_trash(10)$q$, '42501');

-- 업로드 실패 정리: discard → 정리 대기열
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select nomad_knowflow.discard_source_capture((select (j ->> 'capture_id')::uuid from t_cap where k = 'y2'))::int), 1, 'A는 방금 만든 캡처 삭제');

-- 영상 삭제 시 캡처 제거
select nomad_knowflow.delete_sources('10000000-0000-0000-0000-000000000001', array['20000000-0000-0000-0000-000000000001'::uuid]);
reset role;
select public.t_eq((select count(*) from nomad_knowflow.source_captures where source_id = '20000000-0000-0000-0000-000000000001'), 0, '자료 삭제 시 캡처 행 제거');
select public.t_eq((select count(*) from nomad_knowflow_private.capture_object_trash), 21, '지운 캡처 경로 21개 정리 대기(삭제 20 + discard 1)');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select count(*) from storage.objects where bucket_id = 'knowflow-captures'), 0, '행이 지워진 객체는 읽기 불가');

-- 비활성(권리자 요청) 시 캡처 제거
select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 'image/png', 1000);
select public.t_role('service_role');
select nomad_knowflow.takedown_video('capvideo002', '권리자 요청(검사)');
reset role;
select public.t_eq((select count(*) from nomad_knowflow.source_captures), 0, '비활성 시 캡처 행 제거');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect($q$select nomad_knowflow.create_source_capture('20000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 'image/png', 1000)$q$, 'KF410');

-- 정리 대기열: service_role만 꺼낸다
select public.t_role('service_role');
create temp table t_claim (k text primary key, paths text[]);
grant all on t_claim to public;
insert into t_claim select 'c1', nomad_knowflow.claim_capture_object_trash(1000);
select public.t_eq((select cardinality(paths) from t_claim where k = 'c1'), 22, 'service_role이 정리 대기 경로 22개를 맡음');
select public.t_eq((select cardinality(nomad_knowflow.claim_capture_object_trash(1000))), 0, '맡은 경로는 15분 안에 다시 나오지 않음');
select public.t_expect($q$select nomad_knowflow.claim_capture_object_trash(0)$q$, '22023');
select public.t_expect($q$select nomad_knowflow.ack_capture_object_trash(null)$q$, '22023');
-- Storage 삭제 성공분(10개)만 ack, 나머지 12개는 실패로 보고 ack하지 않는다
select public.t_eq((select nomad_knowflow.ack_capture_object_trash((select paths[1:10] from t_claim where k = 'c1'))), 10, 'ack한 10개만 대기열에서 빠짐');
select public.t_eq((select nomad_knowflow.ack_capture_object_trash((select paths[1:10] from t_claim where k = 'c1'))), 0, '같은 ack 재전송은 0(멱등)');
reset role;
select public.t_eq((select count(*) from nomad_knowflow_private.capture_object_trash), 12, 'ack 안 한 12개는 대기열에 남음(경로 유실 없음)');
-- 오래된 claim(15분 초과)은 다시 배정된다
update nomad_knowflow_private.capture_object_trash set claimed_at = now() - interval '16 minutes';
select public.t_role('service_role');
insert into t_claim select 'c2', nomad_knowflow.claim_capture_object_trash(1000);
select public.t_eq((select cardinality(paths) from t_claim where k = 'c2'), 12, '오래된 claim 12개 재배정');
reset role;
select public.t_eq((select count(*) from nomad_knowflow_private.capture_object_trash where attempts = 2), 12, '재배정 시 시도 횟수 2');
select public.t_role('service_role');
select public.t_eq((select nomad_knowflow.ack_capture_object_trash((select paths from t_claim where k = 'c2'))), 12, '재시도 성공분 ack');
reset role;
-- 시도 상한: attempts 10 이상은 배정하지 않고 행은 남긴다(운영자 확인용)
insert into nomad_knowflow_private.capture_object_trash (storage_path, claimed_at, attempts) values
  ('stall/a.png', now() - interval '1 hour', 10), ('stall/b.png', now() - interval '1 hour', 12),
  ('stall/c.png', now() - interval '1 hour', 9), ('stall/d.png', null, 10);
select public.t_role('service_role');
insert into t_claim select 'c3', nomad_knowflow.claim_capture_object_trash(1000);
select public.t_eq((select cardinality(paths) from t_claim where k = 'c3'), 1, '시도 상한(10) 미만 1개만 배정');
select public.t_eq((select (paths[1] = 'stall/c.png')::int from t_claim where k = 'c3'), 1, '9회 경로는 마지막 시도로 배정');
select public.t_eq((select count(*) from nomad_knowflow.list_stalled_capture_object_trash(1000)), 4, '상한 걸린 경로 4개(9→10 포함) 조회');
select public.t_eq((select max(stalled_total) from nomad_knowflow.list_stalled_capture_object_trash(1)), 4, 'limit 1이어도 전체 수 4');
select public.t_expect($q$select * from nomad_knowflow.list_stalled_capture_object_trash(0)$q$, '22023');
reset role;
update nomad_knowflow_private.capture_object_trash set claimed_at = now() - interval '16 minutes';
select public.t_role('service_role');
select public.t_eq((select cardinality(nomad_knowflow.claim_capture_object_trash(1000))), 0, '상한 넘은 행은 15분 지나도 미배정');
reset role;
select public.t_eq((select count(*) from nomad_knowflow_private.capture_object_trash where storage_path like 'stall/%'), 4, '상한 넘은 행은 대기열에 남음');

select 'USER CHECK PASSED' as result;
rollback;
