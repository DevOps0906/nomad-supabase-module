-- org안 검사: 조직 2곳(O1·O2) 교차 접근 거부 + 역할(owner·viewer) + 한도·동기화 컬럼·Worker 흐름. 마지막에 rollback.
-- run_check.sh가 begin·준비·이식 SQL 뒤에 이어 붙인다(단독 실행 금지).
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'a-org@example.invalid', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'b-org@example.invalid', 'authenticated', 'authenticated'),
  ('cccccccc-0000-0000-0000-00000000000c', 'c-org@example.invalid', 'authenticated', 'authenticated');
insert into nomad_core.organizations (id, name) values
  ('01010101-0000-0000-0000-000000000001', '조직 1'),
  ('02020202-0000-0000-0000-000000000002', '조직 2');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('01010101-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', 'owner'),
  ('01010101-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-00000000000c', 'viewer'),
  ('02020202-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-00000000000b', 'owner');

create temp table t_ids (k text primary key, v uuid);
create temp table t_job (j jsonb);
grant all on t_ids, t_job to public;

-- ===== 생성 권한·한도 =====
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'p1', id from nomad_knowflow.create_project('01010101-0000-0000-0000-000000000001', 'O1 프로젝트');
select public.t_expect($q$select nomad_knowflow.create_project('02020202-0000-0000-0000-000000000002', 'x')$q$, 'P0002');
select nomad_knowflow.create_project('01010101-0000-0000-0000-000000000001', 'O1 프로젝트 2');
select public.t_expect($q$select nomad_knowflow.create_project('01010101-0000-0000-0000-000000000001', 'O1 3')$q$, 'KF429');
select public.t_eq((select count(*) from nomad_knowflow.projects), 2, 'A는 조직 1 프로젝트 2개 조회');

select public.t_login('cccccccc-0000-0000-0000-00000000000c');
select public.t_eq((select count(*) from nomad_knowflow.projects), 2, 'viewer C는 조직 1 프로젝트 읽기');
select public.t_expect($q$select nomad_knowflow.create_project('01010101-0000-0000-0000-000000000001', 'viewer')$q$, 'P0002');
select public.t_expect(format($q$select nomad_knowflow.update_project(%L, '{"name":"x"}')$q$, (select v from t_ids where k = 'p1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_project(%L)$q$, (select v from t_ids where k = 'p1')), 'P0002');

-- ===== B(조직 2): 교차 접근 거부 =====
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
insert into t_ids select 'p2', id from nomad_knowflow.create_project('02020202-0000-0000-0000-000000000002', 'O2 프로젝트');
select public.t_eq((select count(*) from nomad_knowflow.projects), 1, 'B는 조직 2 프로젝트 1개만 조회');
select public.t_expect($q$select nomad_knowflow.create_project('01010101-0000-0000-0000-000000000001', 'x')$q$, 'P0002');
select public.t_expect(format($q$select nomad_knowflow.update_project(%L, '{"name":"x"}')$q$, (select v from t_ids where k = 'p1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_project(%L)$q$, (select v from t_ids where k = 'p1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.list_project_jobs(%L)$q$, (select v from t_ids where k = 'p1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', '01010101-0000-0000-0000-000000000001/x/y.pdf', null, 'k1', 'h1')$q$, (select v from t_ids where k = 'p1')), 'P0002');
select public.t_eq((select count(*) from nomad_knowflow.org_quotas), 1, 'B는 자기 조직 쿼터 행만');
select public.t_expect($q$insert into nomad_knowflow.projects (organization_id, name) values ('02020202-0000-0000-0000-000000000002', 'x')$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow.source_chunks$q$, '42501');
select public.t_expect($q$select * from nomad_knowflow_private.idempotency_keys$q$, '42501');
select public.t_expect($q$select nomad_knowflow.claim_job()$q$, '42501');

-- ===== A: PDF 등록 → Worker 처리 =====
reset role;
insert into storage.objects (bucket_id, name, metadata)
select 'knowflow-sources', '01010101-0000-0000-0000-000000000001/' || v || '/33333333-3333-3333-3333-333333333333.pdf',
       '{"size": 1000, "mimetype": "application/pdf"}'::jsonb from t_ids where k = 'p1';
select public.t_login('cccccccc-0000-0000-0000-00000000000c');
-- viewer는 등록 불가
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', '01010101-0000-0000-0000-000000000001/%s/33333333-3333-3333-3333-333333333333.pdf', null, 'kc', 'hc')$q$, (select v from t_ids where k = 'p1'), (select v from t_ids where k = 'p1')), 'P0002');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
-- 조직 2 폴더 경로로는 등록 불가
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', '02020202-0000-0000-0000-000000000002/%s/33333333-3333-3333-3333-333333333333.pdf', null, 'k0', 'h0')$q$, (select v from t_ids where k = 'p1'), (select v from t_ids where k = 'p1')), '22023');
insert into t_ids select 's1', (nomad_knowflow.register_pdf_source((select v from t_ids where k = 'p1'), '문서 O1',
  '01010101-0000-0000-0000-000000000001/' || (select v from t_ids where k = 'p1') || '/33333333-3333-3333-3333-333333333333.pdf',
  null, 'key-1', 'hash-1') ->> 'source_id')::uuid;
select public.t_eq((select (nomad_knowflow.register_pdf_source((select v from t_ids where k = 'p1'), '문서 O1',
  '01010101-0000-0000-0000-000000000001/' || (select v from t_ids where k = 'p1') || '/33333333-3333-3333-3333-333333333333.pdf',
  null, 'key-1', 'hash-1') ->> 'duplicate')::boolean::int), 1, '멱등 키 재요청 duplicate');
select public.t_eq((select used_source_jobs from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 1, '같은 멱등 키 재요청 시 차감 1회(PDF)');

select public.t_role('service_role');
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from t_job where j is not null), 1, 'claim_job 작업 획득');
select public.t_eq((select count(*) from nomad_knowflow.replace_source_chunks(
  ((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int,
  '[{"chunk_index":0,"content":"안녕 지식","locator":{"page":1}}]'::jsonb) r where r), 1, 'replace_source_chunks');
select public.t_eq((select count(*) from nomad_knowflow.complete_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int) c where c), 1, 'complete_job');
-- 유튜브(service_role): 조직 기준 등록
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('01010101-0000-0000-0000-000000000001', %L, 'abcdefghijk', 't', 'c', 601, 'ky1', 'hy1')$q$, (select v from t_ids where k = 'p1')), 'KF413');
select public.t_eq((select count(*) from nomad_knowflow.register_youtube_source('01010101-0000-0000-0000-000000000001', (select v from t_ids where k = 'p1'), 'abcdefghijk', '영상', '채널', 500, 'ky2', 'hy2')), 1, 'O1 유튜브 등록');
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('02020202-0000-0000-0000-000000000002', %L, 'zzzzzzzzzzz', '영상', '채널', 100, 'ky4', 'hy4')$q$, (select v from t_ids where k = 'p1')), 'P0002');
reset role;

-- ===== B: 조직 1 자료·청크·작업 접근 거부 =====
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_eq((select count(*) from nomad_knowflow.sources), 0, 'B는 조직 1 자료 안 보임');
select public.t_eq((select count(*) from nomad_knowflow.processing_jobs), 0, 'B는 조직 1 작업 안 보임');
select public.t_expect(format($q$select nomad_knowflow.get_source_chunks(%L)$q$, (select v from t_ids where k = 's1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk', 'rh')$q$, (select v from t_ids where k = 's1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_sources(%L, array[%L]::uuid[])$q$, (select v from t_ids where k = 'p1'), (select v from t_ids where k = 's1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_sources(%L, array[%L]::uuid[])$q$, (select v from t_ids where k = 'p2'), (select v from t_ids where k = 's1')), 'P0002');

-- ===== C(viewer): 읽기만 =====
select public.t_login('cccccccc-0000-0000-0000-00000000000c');
select public.t_eq((select count(*) from nomad_knowflow.sources), 2, 'viewer C는 조직 1 자료 읽기');
select public.t_eq((select jsonb_array_length(nomad_knowflow.get_source_chunks((select v from t_ids where k = 's1')) -> 'chunks')), 1, 'viewer C 청크 조회');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk', 'rh')$q$, (select v from t_ids where k = 's1')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.delete_sources(%L, array[%L]::uuid[])$q$, (select v from t_ids where k = 'p1'), (select v from t_ids where k = 's1')), 'P0002');

-- ===== A: 동기화 컬럼·소프트 삭제 =====
reset role;
set local session_replication_role = replica;
update nomad_knowflow.projects set updated_at = now() - interval '1 day' where id = (select v from t_ids where k = 'p1');
set local session_replication_role = origin;
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select count(*) from nomad_knowflow.list_project_jobs((select v from t_ids where k = 'p1'))), 2, 'A 작업 목록(PDF·유튜브)');
select nomad_knowflow.update_project((select v from t_ids where k = 'p1'), '{"name":"이름 변경"}');
select public.t_eq((select count(*) from nomad_knowflow.projects p where p.id = (select v from t_ids where k = 'p1') and p.updated_at > now() - interval '1 minute'), 1, 'update 시 updated_at 갱신(touch 트리거)');
select nomad_knowflow.delete_sources((select v from t_ids where k = 'p1'), array[(select v from t_ids where k = 's1')]);
select public.t_eq((select count(*) from nomad_knowflow.sources where id = (select v from t_ids where k = 's1')), 0, '삭제한 자료는 RLS로 숨김');
reset role;
select public.t_eq((select count(*) from nomad_knowflow.sources where id = (select v from t_ids where k = 's1') and deleted_at is not null), 1, 'deleted_at 소프트 삭제 행은 남음');

-- ===== anon / Storage =====
select public.t_role('anon');
select public.t_expect($q$select * from nomad_knowflow.projects$q$, '42501');
select public.t_eq((select count(*) from nomad_knowflow.consume_auth_rate_limit('login_ip', repeat('a', 64)) where allowed), 1, 'anon consume_auth_rate_limit 허용');
reset role;
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect($q$insert into storage.objects (bucket_id, name) values ('knowflow-sources', '01010101-0000-0000-0000-000000000001/x/y.pdf')$q$, '42501');
select public.t_eq((select count(*) from storage.objects where bucket_id = 'knowflow-sources'), 0, 'B는 조직 1 폴더 객체 안 보임');
select public.t_login('cccccccc-0000-0000-0000-00000000000c');
select public.t_expect($q$insert into storage.objects (bucket_id, name) values ('knowflow-sources', '01010101-0000-0000-0000-000000000001/x/z.pdf')$q$, '42501');
select public.t_eq((select count(*) from storage.objects where bucket_id = 'knowflow-sources'), 1, 'viewer C는 조직 1 폴더 읽기');
reset role;

-- ===== 기능 잠금(task-007): 재시도 멱등 차감 1회 · 구독 끊김 = 쓰기 잠금 · 읽기 유지 =====
insert into t_ids select 'yt', id from nomad_knowflow.sources
 where organization_id = '01010101-0000-0000-0000-000000000001' and source_type = 'youtube';
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'no_handler', false) f where f = 'failed'), 1, '유튜브 작업 실패(환불)');
reset role;
select public.t_eq((select used_source_jobs + used_video_seconds from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 1, '실패 잡 환불(source_jobs 1·video_seconds 0)');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select nomad_knowflow.retry_source((select v from t_ids where k = 'yt'), 'rk-1', 'rh-1');
select public.t_eq((select (nomad_knowflow.retry_source((select v from t_ids where k = 'yt'), 'rk-1', 'rh-1') ->> 'duplicate')::boolean::int), 1, '재시도 멱등 키 재요청 duplicate');
select public.t_eq((select used_source_jobs from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 2, '같은 멱등 키 재시도 차감 1회(source_jobs)');
select public.t_eq((select used_video_seconds from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 500, '같은 멱등 키 재시도 차감 1회(video_seconds)');

-- 보고서 잠금: C 플랜(구독 없음)에는 space_reports가 없다 → create_report 거부
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, 'r', 'rk-c0')$q$, (select v from t_ids where k = 'p1')), 'KF403');

-- 잠금 준비: C 플랜에서 knowflow 기능을 빼고(검사 트랜잭션 안에서만) O1에 B 구독
reset role;
delete from nomad_core.plan_features where product_code = 'knowflow' and plan_code = 'C';
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
values ('01010101-0000-0000-0000-000000000001', 'knowflow', 'B', 'active');
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('knowflow', 'B', 'monthly_questions', 5), ('knowflow', 'B', 'monthly_reports', 5)
on conflict (product_code, plan_code, limit_key) do update set limit_value = excluded.limit_value;
insert into storage.objects (bucket_id, name, metadata)
select 'knowflow-sources', '01010101-0000-0000-0000-000000000001/' || v || '/44444444-4444-4444-4444-444444444444.pdf',
       '{"size": 1000, "mimetype": "application/pdf"}'::jsonb from t_ids where k = 'p1';
select public.t_role('service_role');
with c as (insert into nomad_knowflow.conversations (project_id, organization_id, title)
  select v, '01010101-0000-0000-0000-000000000001', '대화' from t_ids where k = 'p1' returning id)
insert into t_ids select 'cv', id from c;
-- task-017: 질문·답변·보고서는 RPC만(서버 직접 insert·메시지 수정 거부)
select public.t_expect(format($q$insert into nomad_knowflow.messages (conversation_id, role, content) values (%L, 'user', '질문')$q$, (select v from t_ids where k = 'cv')), '42501');
select public.t_expect(format($q$insert into nomad_knowflow.messages (conversation_id, role, content) values (%L, 'assistant', '답변')$q$, (select v from t_ids where k = 'cv')), '42501');
select public.t_expect($q$update nomad_knowflow.messages set role = 'user'$q$, '42501');
select public.t_expect(format($q$insert into nomad_knowflow.reports (project_id, organization_id, title) values (%L, '01010101-0000-0000-0000-000000000001', '보고서')$q$, (select v from t_ids where k = 'p1')), '42501');
-- 질문: 멱등 키 재요청은 같은 메시지·차감 1회, 같은 키 다른 내용은 KF409, 남의 대화는 P0002
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'q1', (nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문', 'qk-1') ->> 'message_id')::uuid;
select public.t_eq((select ((r ->> 'duplicate')::boolean and (r ->> 'message_id')::uuid = (select v from t_ids where k = 'q1'))::int
  from nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문', 'qk-1') r), 1, '질문 멱등 키 재요청은 같은 메시지');
select public.t_eq((select used_questions from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 1, '같은 멱등 키 질문 차감 1회');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '다른 질문', 'qk-1')$q$, (select v from t_ids where k = 'cv')), 'KF409');
select public.t_eq((select count(*) from nomad_knowflow.messages), 1, '구독 중 질문 생성');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, 'x', 'qk-b')$q$, (select v from t_ids where k = 'cv')), 'P0002');
select public.t_expect($q$select nomad_knowflow.save_answer(gen_random_uuid(), 'x')$q$, '42501');
select public.t_login('cccccccc-0000-0000-0000-00000000000c');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, 'viewer', 'qk-c')$q$, (select v from t_ids where k = 'cv')), 'P0002');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, 'viewer', 'rk-c')$q$, (select v from t_ids where k = 'p1')), 'P0002');
-- 월 질문 한도(5): 4개 더 → 6번째 KF429(차감 없음)
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'q' || i, (nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문 ' || i, 'qk-' || i) ->> 'message_id')::uuid
  from generate_series(2, 5) i;
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '질문 6', 'qk-6')$q$, (select v from t_ids where k = 'cv')), 'KF429');
select public.t_eq((select used_questions from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 5, '질문 한도 초과는 차감 없음');
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
select public.t_eq((select used_questions from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 4, '질문 환불은 이번 달 사용량 -1');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q5')) ->> 'refunded')::boolean::int), 0, '재환불은 false(1회만)');
select public.t_eq((select used_questions from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 4, '재환불은 사용량 변화 없음');
select public.t_expect(format($q$select nomad_knowflow.save_answer(%L, 'x')$q$, (select v from t_ids where k = 'q5')), 'KF409');
reset role;
update nomad_knowflow.messages set quota_charged_period = (nomad_knowflow_private.current_period_start() - interval '1 month')::date where id = (select v from t_ids where k = 'q4');
update nomad_knowflow.messages set quota_charged_period = null where id = (select v from t_ids where k = 'q3');
select public.t_role('service_role');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q4')) ->> 'refunded')::boolean::int), 1, '지난달 차감분 환불은 표식만');
select public.t_eq((select used_questions from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 4, '지난달 차감분 환불은 사용량 그대로');
select public.t_eq((select (nomad_knowflow.refund_question_quota((select v from t_ids where k = 'q3')) ->> 'refunded')::boolean::int), 0, '이관 행(표식 null)은 환불 안 함');
select public.t_eq((select count(*) from nomad_knowflow.messages where id = (select v from t_ids where k = 'q3') and quota_refunded_at is null), 1, '이관 행은 환불 표시 없음');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_eq((select ((nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문', 'qk-1') ->> 'answer_id')::uuid
  = (select v from t_ids where k = 'an'))::int), 1, '질문 재요청은 답변 id도 반환');
-- 환불된 질문을 같은 멱등 키로 다시 불러도 재차감 없이 refunded=true, 사용자는 환불 RPC 실행 불가
select public.t_eq((select (nomad_knowflow.ask_question((select v from t_ids where k = 'cv'), '질문 5', 'qk-5') ->> 'refunded')::boolean::int), 1, '환불된 질문 재요청은 refunded');
select public.t_eq((select used_questions from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 4, '환불된 질문 재요청은 차감 없음');
select public.t_expect(format($q$select nomad_knowflow.refund_question_quota(%L)$q$, (select v from t_ids where k = 'q2')), '42501');
-- 보고서: 멱등 키 재요청 차감 1회 · 다른 내용 KF409 · 남의 프로젝트 P0002 · 생성 작업 실패 시 환불·failed
insert into t_ids select 'rp', (nomad_knowflow.create_report((select v from t_ids where k = 'p1'), '보고서', 'rk-r1') ->> 'report_id')::uuid;
select public.t_eq((select ((r ->> 'duplicate')::boolean and (r ->> 'report_id')::uuid = (select v from t_ids where k = 'rp'))::int
  from nomad_knowflow.create_report((select v from t_ids where k = 'p1'), '보고서', 'rk-r1') r), 1, '보고서 멱등 키 재요청은 같은 보고서');
select public.t_eq((select used_reports from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 1, '같은 멱등 키 보고서 차감 1회');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, '다른 보고서', 'rk-r1')$q$, (select v from t_ids where k = 'p1')), 'KF409');
select public.t_eq((select count(*) from nomad_knowflow.reports), 1, 'B 구독 중 보고서 생성');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, 'x', 'rk-b')$q$, (select v from t_ids where k = 'p1')), 'P0002');
reset role;
update nomad_knowflow.processing_jobs set status = 'cancelled' where status = 'queued' and job_type <> 'report_generate';
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from t_job where (j ->> 'report_id')::uuid = (select v from t_ids where k = 'rp')), 1, '보고서 생성 작업 획득');
select public.t_eq((select count(*) from nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'llm_error', false) f where f = 'failed'), 1, '보고서 작업 실패');
reset role;
select public.t_eq((select used_reports from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 0, '보고서 실패 환불');
select public.t_eq((select count(*) from nomad_knowflow.reports where id = (select v from t_ids where k = 'rp') and status = 'failed'), 1, '보고서 실패 상태');
-- 환불은 차감 1건에 묶인다(quota_charged_period 표식): 같은 보고서 잡 두 번 실패·ready 뒤 실패·지난달 표식은 환불 없음
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'rp2', (nomad_knowflow.create_report((select v from t_ids where k = 'p1'), '보고서 2', 'rk-r2') ->> 'report_id')::uuid;
select public.t_eq((select used_reports from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 1, '보고서 2 차감');
reset role;
select public.t_eq((select count(*) from nomad_knowflow.reports where id = (select v from t_ids where k = 'rp') and quota_charged_period is null), 1, '환불한 보고서는 표식 해제');
insert into nomad_knowflow.processing_jobs (organization_id, report_id, job_type) select '01010101-0000-0000-0000-000000000001'::uuid, v, 'report_generate' from t_ids where k = 'rp';
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
select public.t_eq((select used_reports from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 1, '같은 보고서 두 번째 실패·ready 뒤 실패는 환불 없음');
select public.t_eq((select count(*) from nomad_knowflow.reports where id = (select v from t_ids where k = 'rp2') and status = 'ready'), 1, 'ready 보고서 상태 유지');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ids select 'rp3', (nomad_knowflow.create_report((select v from t_ids where k = 'p1'), '보고서 3', 'rk-r3') ->> 'report_id')::uuid;
reset role;
update nomad_knowflow.reports set quota_charged_period = (quota_charged_period - interval '1 month')::date where id = (select v from t_ids where k = 'rp3');
select public.t_role('service_role');
delete from t_job;
insert into t_job select nomad_knowflow.claim_job(60);
select public.t_eq((select count(*) from t_job where (j ->> 'report_id')::uuid = (select v from t_ids where k = 'rp3')), 1, '보고서 3 작업 획득');
select nomad_knowflow.fail_job(((select j from t_job) ->> 'id')::uuid, ((select j from t_job) ->> 'attempt_count')::int, 'llm_error', false);
reset role;
select public.t_eq((select used_reports from nomad_knowflow.org_quotas where organization_id = '01010101-0000-0000-0000-000000000001'), 2, '지난달 표식 보고서 실패는 이번 달 사용량 불변');
reset role;
update nomad_core.subscriptions set status = 'inactive'
 where organization_id = '01010101-0000-0000-0000-000000000001' and product_code = 'knowflow';

-- 잠김: 대화·등록·재시도 거부
select public.t_role('service_role');
select public.t_expect(format($q$insert into nomad_knowflow.conversations (project_id, organization_id) values (%L, '01010101-0000-0000-0000-000000000001')$q$, (select v from t_ids where k = 'p1')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('01010101-0000-0000-0000-000000000001', %L, 'lmnopqrstuv', '영상', '채널', 10, 'ky9', 'hy9')$q$, (select v from t_ids where k = 'p1')), 'KF403');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '질문 9', 'qk-9')$q$, (select v from t_ids where k = 'cv')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.ask_question(%L, '질문', 'qk-1')$q$, (select v from t_ids where k = 'cv')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.create_report(%L, '보고서', 'rk-r1')$q$, (select v from t_ids where k = 'p1')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', '01010101-0000-0000-0000-000000000001/%s/44444444-4444-4444-4444-444444444444.pdf', null, 'key-9', 'hash-9')$q$, (select v from t_ids where k = 'p1'), (select v from t_ids where k = 'p1')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk-2', 'rh-2')$q$, (select v from t_ids where k = 'yt')), 'KF403');
-- 잠겨도 읽기는 유지
select public.t_eq((select count(*) from nomad_knowflow.sources), 1, '잠김: 자료 읽기 유지');
select public.t_eq((select count(*) from nomad_knowflow.messages), 6, '잠김: 메시지 읽기 유지');
select public.t_eq((select count(*) from nomad_knowflow.projects), 2, '잠김: 프로젝트 읽기 유지');
select public.t_eq((select (count(*) > 0)::int from nomad_knowflow.list_project_jobs((select v from t_ids where k = 'p1'))), 1, '잠김: 작업 목록 유지');
select public.t_login('cccccccc-0000-0000-0000-00000000000c');
select public.t_eq((select count(*) from nomad_knowflow.conversations), 1, '잠김: viewer 대화 읽기 유지');
-- 잠김: 잠기기 전 질문의 답변 저장은 허용
select public.t_role('service_role');
select nomad_knowflow.save_answer((select v from t_ids where k = 'q2'), '답변 q2');
select public.t_eq((select count(*) from nomad_knowflow.messages where role = 'assistant'), 2, '잠김: assistant 답변 허용');
-- 잠김에도 남의 프로젝트·자료는 P0002(존재 노출 없음)
select public.t_expect(format($q$select nomad_knowflow.register_youtube_source('01010101-0000-0000-0000-000000000001', %L, 'lmnopqrstuv', '영상', '채널', 10, 'ky8', 'hy8')$q$, (select v from t_ids where k = 'p2')), 'P0002');
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, 't', '02020202-0000-0000-0000-000000000002/%s/44444444-4444-4444-4444-444444444444.pdf', null, 'key-8', 'hash-8')$q$, (select v from t_ids where k = 'p2'), (select v from t_ids where k = 'p2')), 'P0002');
select public.t_expect($q$select nomad_knowflow.retry_source(gen_random_uuid(), 'rk-8', 'rh-8')$q$, 'P0002');
select public.t_login('bbbbbbbb-0000-0000-0000-00000000000b');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk-7', 'rh-7')$q$, (select v from t_ids where k = 'yt')), 'P0002');
-- 잠김: 같은 멱등 키 재요청도 KF403
select public.t_login('aaaaaaaa-0000-0000-0000-00000000000a');
select public.t_expect(format($q$select nomad_knowflow.register_pdf_source(%L, '문서 O1', '01010101-0000-0000-0000-000000000001/%s/33333333-3333-3333-3333-333333333333.pdf', null, 'key-1', 'hash-1')$q$, (select v from t_ids where k = 'p1'), (select v from t_ids where k = 'p1')), 'KF403');
select public.t_expect(format($q$select nomad_knowflow.retry_source(%L, 'rk-1', 'rh-1')$q$, (select v from t_ids where k = 'yt')), 'KF403');
-- ends_at 만료(status active)로도 잠김
reset role;
update nomad_core.subscriptions set status = 'active', starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
 where organization_id = '01010101-0000-0000-0000-000000000001' and product_code = 'knowflow';
select public.t_role('service_role');
select public.t_expect(format($q$insert into nomad_knowflow.conversations (project_id, organization_id) values (%L, '01010101-0000-0000-0000-000000000001')$q$, (select v from t_ids where k = 'p1')), 'KF403');
reset role;

select 'ORG CHECK PASSED' as result;
rollback;
