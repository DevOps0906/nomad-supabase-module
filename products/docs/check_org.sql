-- NOMAD Docs org안 검사: 조직 2곳 교차 거부 · 역할(owner/editor/viewer) · 생성 파이프라인(크레딧·잡·확정·취소 환불) ·
-- 구독 끊김 잠김(유료 기능만, 무료 docs는 C로 유지) · anon 0 회귀. 합성 데이터만, 마지막에 rollback.
-- 실행: bash products/docs/run_check.sh   (begin → 청사진 drop → 임시 touch_updated_at → org/0001·0002 → 이 파일 → rollback)

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
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer), 조직 B(u2 owner). 둘 다 B 플랜 구독 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'docs', 'B', 'active'), ('00000000-0000-0000-0000-00000000000b', 'docs', 'B', 'active');
select nomad_core.grant_credits('00000000-0000-0000-0000-00000000000a', 100, 'test grant', 'test:grant:a', 'docs');
-- 판매용 문서 유형(quote)은 이미 활성. sow 도 활성(취소 시나리오용)

-- ==== 1. 방문자(anon): 공개 경로 없음 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.denied('select count(*) from nomad_docs.projects');
select zz_check.denied('select count(*) from nomad_docs.doc_types');
select zz_check.denied('select count(*) from nomad_docs.project_totals');
select zz_check.denied($$insert into nomad_docs.parties (organization_id, kind, name) values ('00000000-0000-0000-0000-00000000000a', 'client', 'x')$$);
select zz_check.denied($$select nomad_docs.finalize_document(gen_random_uuid(), 1)$$);
select zz_check.denied($$select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), null, 'quote', null, null, null, 'gen:docs:anon00001', null)$$);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 2. 조직 A editor(u3): 정본 데이터 직접 쓰기, 번호는 서버가 부여, 한도 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_docs.doc_types where is_active', 8);
insert into nomad_docs.parties (organization_id, kind, name, biz_reg_no) values ('00000000-0000-0000-0000-00000000000a', 'client', '거래처 A', '123-45-67890');
select zz_check.fails_with($$insert into nomad_docs.parties (organization_id, kind, name, biz_reg_no) values ('00000000-0000-0000-0000-00000000000a', 'client', 'RRN', '900101-1234567')$$, 'parties_biz_reg_no_check');
insert into nomad_docs.projects (organization_id, name, project_type) values ('00000000-0000-0000-0000-00000000000a', 'Project A1', 'web');
insert into nomad_docs.projects (organization_id, name, project_type) values ('00000000-0000-0000-0000-00000000000a', 'Project A2', 'web');
-- projects_max 키가 없으면 원본 Free 기본값 2 → 세 번째는 DC006
select zz_check.fails_with($$insert into nomad_docs.projects (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'Project A3')$$, 'plan limit reached');
-- status 는 컬럼 GRANT 밖(set_project_status RPC 전용)
select zz_check.denied($$update nomad_docs.projects set status = 'active' where name = 'Project A1'$$);
select zz_check.fails_with($$select nomad_docs.set_project_status((select id from nomad_docs.projects where name = 'Project A1'), 'active')$$, 'owner/admin only');
insert into nomad_docs.checklist_answers (project_id, organization_id, item_key, value)
  select id, organization_id, 'profile.service_summary', '"업무 자동화 웹"' from nomad_docs.projects where name = 'Project A1';
select zz_check.fails_with($$insert into nomad_docs.checklist_answers (project_id, organization_id, item_key, value)
  select id, organization_id, 'nfr.security_level', '"ultra"' from nomad_docs.projects where name = 'Project A1'$$, 'value does not match');
insert into nomad_docs.requirements (organization_id, project_id, kind, title)
  select organization_id, id, 'functional', '로그인' from nomad_docs.projects where name = 'Project A1';
insert into nomad_docs.requirements (organization_id, project_id, kind, title)
  select organization_id, id, 'nonfunctional', '응답 2초' from nomad_docs.projects where name = 'Project A1';
insert into nomad_docs.artifacts (organization_id, project_id, kind, name)
  select organization_id, id, 'screen', '로그인 화면' from nomad_docs.projects where name = 'Project A1';
insert into nomad_docs.line_items (organization_id, project_id, name, quantity, unit_price_krw)
  select organization_id, id, '개발', 3, 500000 from nomad_docs.projects where name = 'Project A1';
select zz_check.expect($$select count(*) from nomad_docs.requirements where req_code in ('FR-001', 'NFR-001') and source = 'manual'$$, 2);
select zz_check.expect($$select count(*) from nomad_docs.artifacts where code = 'SCR-001'$$, 1);
select zz_check.expect($$select total_krw from nomad_docs.project_totals t join nomad_docs.projects p on p.id = t.project_id where p.name = 'Project A1'$$, 1650000);
-- 번호 함수 직접 호출 금지(트리거 전용)
select zz_check.fails_with($$select nomad_docs.next_project_code((select id from nomad_docs.projects where name = 'Project A1'), 'requirements', 'FR')$$, 'trigger use only');
-- 서버 관리 컬럼(source)·코드 변경 거부
select zz_check.denied($$update nomad_docs.requirements set source = 'checklist' where req_code = 'FR-001'$$);
reset role;
select set_config('request.jwt.claims', '', true);

create temp table t_ids as
select 'proj_a1'::text k, id from nomad_docs.projects where name = 'Project A1'
union all select 'proj_a2', id from nomad_docs.projects where name = 'Project A2'
union all select 'req_a', id from nomad_docs.requirements where req_code = 'FR-001';
grant select on t_ids to public;

-- ==== 3. 조직 A viewer(u5): 읽기만 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_docs.projects', 2);
select zz_check.denied($$insert into nomad_docs.parties (organization_id, kind, name) values ('00000000-0000-0000-0000-00000000000a', 'vendor', 'V')$$);
select zz_check.expect($$with u as (update nomad_docs.requirements set title = 'viewer' returning 1) select count(*) from u$$, 0);
reset role;

-- ==== 4. 서버(service_role): 생성 시작(크레딧 선차감 + 잡) → 결과 저장 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), null, 'quote', null, null, null,
                                   'gen:docs:req0000001', '00000000-0000-0000-0000-0000000000a3');
-- 같은 멱등 키 = 같은 실행(이중 차감 없음)
select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), null, 'quote', null, null, null,
                                   'gen:docs:req0000001', '00000000-0000-0000-0000-0000000000a3');
-- 비멤버 행위자 거부
select zz_check.fails_with($$select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a2'), null, 'quote', null, null, null,
                                   'gen:docs:req0000009', '00000000-0000-0000-0000-0000000000a2')$$, 'not a member');
-- 비활성(법무 검토 전) 고위험 유형 거부
select zz_check.fails_with($$select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a2'), null, 'dev_contract', null, null, null,
                                   'gen:docs:req0000008', '00000000-0000-0000-0000-0000000000a3')$$, 'not available');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect('select count(*) from nomad_docs.generation_runs', 1);
select zz_check.expect($$select count(*) from nomad_docs.documents where status = 'generating'$$, 1);
select zz_check.expect($$select count(*) from nomad_core.jobs j join nomad_docs.generation_runs g on g.job_id = j.id
  where j.product_code = 'docs' and j.status = 'queued' and j.credit_ledger_id = g.credit_ledger_id$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 98);
insert into t_ids select 'doc_q', id from nomad_docs.documents where doc_type_code = 'quote';
insert into t_ids select 'run_q', id from nomad_docs.generation_runs;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_docs.report_generation_progress((select id from t_ids where k = 'run_q'), 'drafting', 'items', 1, 4);
select nomad_docs.finish_generation((select id from t_ids where k = 'run_q'), '[{"key":"header"}]', '<p>견적</p>',
  '{"client_party":"거래처 A","self_party":"우리","line_items":"3","quote":{"valid_until":"2026-12-31"}}',
  nomad_docs.checklist_answers_hash((select id from t_ids where k = 'proj_a1')),
  '{"errors":[],"warnings":[],"ran_at":"2026-11-14T00:00:00Z","rules":["L-RRN"]}', 'pass');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_docs.documents where status = 'review' and current_version = 1$$, 1);
-- 결과 저장 = mark_job_delivered(이후 잡이 실패해도 환불 안 함)
select zz_check.expect($$select count(*) from nomad_core.jobs where product_code = 'docs' and not refund_on_failure$$, 1);
-- 버전은 append-only
select zz_check.fails_with($$update nomad_docs.document_versions set body_html = 'x'$$, 'append-only');

-- ==== 5. 조직 B owner(u2): 조직 A 전부 안 보이고 쓰기·RPC 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_docs.projects', 0);
select zz_check.expect('select count(*) from nomad_docs.documents', 0);
select zz_check.expect('select count(*) from nomad_docs.generation_runs', 0);
select zz_check.expect('select count(*) from nomad_docs.project_totals', 0);
select zz_check.denied($$insert into nomad_docs.projects (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'evil')$$);
-- 자기 조직 id 로 남의 프로젝트에 매달기 = 복합 FK 거부
select zz_check.fails_with($$insert into nomad_docs.requirements (organization_id, project_id, kind, title)
  values ('00000000-0000-0000-0000-00000000000b', (select id from t_ids where k = 'proj_a1'), 'functional', 'x')$$, 'not a member');
select zz_check.expect($$with u as (update nomad_docs.requirements set title = 'hacked' returning 1) select count(*) from u$$, 0);
select zz_check.fails_with($$select nomad_docs.finalize_document((select id from t_ids where k = 'doc_q'), 1)$$, 'owner/admin only');
select zz_check.fails_with($$select nomad_docs.cancel_generation((select id from t_ids where k = 'run_q'))$$, 'owner/admin or the requester only');
select zz_check.fails_with($$select nomad_docs.set_project_status((select id from t_ids where k = 'proj_a1'), 'archived')$$, 'owner/admin only');
reset role;

-- ==== 6. 조직 A: editor 는 확정 불가, owner 확정 → 문서번호 · 확정 불변 · 개정본 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_docs.finalize_document((select id from t_ids where k = 'doc_q'), 1)$$, 'owner/admin only');
update nomad_docs.documents set title = '견적서 v1' where id = (select id from t_ids where k = 'doc_q');
select zz_check.fails_with($$update nomad_docs.documents set needs_regeneration = true where id = (select id from t_ids where k = 'doc_q')$$, 'permission denied');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_docs.finalize_document((select id from t_ids where k = 'doc_q'), 2)$$, 'version conflict');
select nomad_docs.finalize_document((select id from t_ids where k = 'doc_q'), 1);
select zz_check.expect($$select count(*) from nomad_docs.documents where status = 'final' and doc_number like 'QT-____-0001'$$, 1);
select zz_check.fails_with($$update nomad_docs.documents set title = 'changed' where id = (select id from t_ids where k = 'doc_q')$$, 'immutable');
select nomad_docs.create_revision((select id from t_ids where k = 'doc_q'));
select zz_check.expect($$select count(*) from nomad_docs.documents where supersedes_document_id is not null and status = 'draft' and current_version = 1$$, 1);
select nomad_docs.set_project_status((select id from t_ids where k = 'proj_a1'), 'active');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.audit_log where action = 'docs_document.finalize' and organization_id = '00000000-0000-0000-0000-00000000000a' and actor_role = 'user'$$, 1);

-- ==== 7. 대기 중 생성 취소(요청한 editor) → 잡 취소 + 크레딧 환불 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a2'), null, 'sow', null, null, null,
                                   'gen:docs:req0000002', '00000000-0000-0000-0000-0000000000a3');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 92);
insert into t_ids select 'run_s', id from nomad_docs.generation_runs where doc_type_code = 'sow';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_docs.cancel_generation((select id from t_ids where k = 'run_s'))$$, 'owner/admin or the requester only');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select nomad_docs.cancel_generation((select id from t_ids where k = 'run_s'));
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_docs.generation_runs where doc_type_code = 'sow' and status = 'canceled'$$, 1);
select zz_check.expect($$select count(*) from nomad_docs.documents where doc_type_code = 'sow' and status = 'draft'$$, 1);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 98);

-- 잡이 먼저 취소(환불)된 실행에는 결과를 저장하지 않는다(환불 뒤 결과 전달 방지)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_docs.start_generation('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a2'), null, 'wbs', null, null, null,
                                   'gen:docs:req0000003', '00000000-0000-0000-0000-0000000000a3');
select nomad_core.cancel_job((select job_id from nomad_docs.generation_runs where doc_type_code = 'wbs'));
select zz_check.fails_with($$select nomad_docs.finish_generation((select id from nomad_docs.generation_runs where doc_type_code = 'wbs'), '[]', null, '{}', null, '{}', 'pass')$$,
                           'job already failed or canceled');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 8. reserve_credits: 멱등(이중 차감·상한 이중 가산 없음) · 키 형식 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select nomad_docs.reserve_credits('00000000-0000-0000-0000-00000000000a', null, 3, 'docs.extract', 'docs_upload', 'u1', 'consume:docs:extract:req1234567');
select nomad_docs.reserve_credits('00000000-0000-0000-0000-00000000000a', null, 3, 'docs.extract', 'docs_upload', 'u1', 'consume:docs:extract:req1234567');
select zz_check.fails_with($$select nomad_docs.reserve_credits('00000000-0000-0000-0000-00000000000a', null, 5, 'docs.extract', 'docs_upload', 'u1', 'consume:docs:extract:req1234567')$$, 'idempotency');
select zz_check.fails_with($$select nomad_docs.reserve_credits('00000000-0000-0000-0000-00000000000a', null, 3, 'docs.extract', null, null, 'consume:docs:gen:req1234567')$$, 'invalid idempotency key');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select sum(delta) from nomad_core.credit_ledger where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 95);
-- 일일 사용량: quote 2 + sow 6 + wbs 2(취소 환불은 빼지 않음, 원본 규칙) + extract 3
select zz_check.expect('select sum(credits) from nomad_docs.daily_credit_usage', 13);
-- 일반 사용자는 서버 함수 실행 불가
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.denied($$select nomad_docs.reserve_credits('00000000-0000-0000-0000-00000000000a', null, 1, 'docs.extract', null, null, 'consume:docs:extract:req7654321')$$);
select zz_check.denied($$select nomad_docs.apply_checklist_effects((select id from t_ids where k = 'proj_a1'), '{}', 'x')$$);
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 9. 기능 잠금: B 플랜(유료) 기능 · 구독이 끊기면 유료 기능만 잠기고 무료 docs(C)는 남는다 ====
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'docs' and plan_code = 'C'$$, 1);
select zz_check.expect($$select count(*) from nomad_core.plan_features where product_code = 'docs' and plan_code = 'C' and feature_code = 'docs'$$, 1);
insert into t_ids select 'ver_q', id from nomad_docs.document_versions where document_id = (select id from t_ids where k = 'doc_q');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
-- B 플랜: DOCX·워터마크 없음·웹훅 허용, CRM 연동·승인은 A 전용
insert into nomad_docs.doc_exports (organization_id, project_id, document_version_id, format, watermark)
  values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), (select id from t_ids where k = 'ver_q'), 'docx', false);
insert into nomad_docs.webhook_endpoints (organization_id, url, events)
  values ('00000000-0000-0000-0000-00000000000a', 'https://hooks.example.test/a', '{document.finalized}');
insert into nomad_docs.integration_connections (organization_id, provider, kind) values ('00000000-0000-0000-0000-00000000000a', 'csv', 'file');
select zz_check.fails_with($$insert into nomad_docs.integration_connections (organization_id, provider, kind) values ('00000000-0000-0000-0000-00000000000a', 'hubspot', 'crm')$$, 'crm_integrations');
select zz_check.fails_with($$insert into nomad_docs.approval_steps (organization_id, document_id, version, step_no, approver_user_id)
  values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'doc_q'), 1, 1, '00000000-0000-0000-0000-0000000000a1')$$, 'approvals');
reset role;
select set_config('request.jwt.claims', '', true);
-- 9-0 phase2 개정본: B 플랜(phase2_docs 없음) owner 는 확장 유형 문서를 개정할 수 없다
insert into nomad_docs.documents (organization_id, project_id, doc_type_code, title, status, current_version, doc_number, finalized_at)
  values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), 'change_request', '변경요청', 'final', 1, 'CR-2026-0001', now());
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select nomad_docs.create_revision((select id from nomad_docs.documents where doc_type_code = 'change_request'))$$, 'phase2_docs required');
reset role;
select set_config('request.jwt.claims', '', true);
-- 9-0 A 플랜 동안 만든 유료 행(hubspot 연결 active · n8n 연결 error · 승인 단계)은 구독이 끊기면 쓰지 못한다
update nomad_core.subscriptions set plan_code = 'A' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'docs';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_docs.integration_connections (organization_id, provider, kind, status) values ('00000000-0000-0000-0000-00000000000a', 'hubspot', 'crm', 'pending');
update nomad_docs.integration_connections set status = 'active' where provider = 'hubspot' and status <> 'revoked';
insert into nomad_docs.integration_connections (organization_id, provider, kind) values ('00000000-0000-0000-0000-00000000000a', 'n8n', 'automation');
update nomad_docs.integration_connections set status = 'error' where provider = 'n8n';
insert into nomad_docs.approval_steps (organization_id, document_id, version, step_no, approver_user_id)
  values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'doc_q'), 1, 1, '00000000-0000-0000-0000-0000000000a1');
select nomad_docs.upsert_external_ref((select id from nomad_docs.integration_connections where provider = 'hubspot' and status <> 'revoked'), 'project',
                                      (select id from t_ids where k = 'proj_a1'), 'deal', 'hs-1');
reset role;
select set_config('request.jwt.claims', '', true);
-- 9-0 연동 자격증명(실제 hubspot 코드): 서버가 부른 revoke_integration 도 core revoke_provider_credential 로 회수(core 20261120000800)
select zz_check.expect($$select count(*) from nomad_core.api_providers where code in ('hubspot', 'salesforce', 'ecount', 'douzone', 'n8n', 'admin_suite_erp')$$, 6);
insert into nomad_core.provider_credentials (id, organization_id, provider_code, label, secret_id, last4)
  values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', 'hubspot', 'old-portal', gen_random_uuid(), 'abcd');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_docs.integration_connections (organization_id, provider, kind, status, credential_id, external_account_id)
  values ('00000000-0000-0000-0000-00000000000a', 'hubspot', 'crm', 'pending', '00000000-0000-0000-0000-0000000000c1', 'portal-old');
select nomad_docs.revoke_integration((select id from nomad_docs.integration_connections where external_account_id = 'portal-old'));
-- 이미 회수된 키를 다시 회수해도 no-op(연결은 already revoked 로 거부)
select zz_check.fails_with($$select nomad_docs.revoke_integration((select id from nomad_docs.integration_connections where external_account_id = 'portal-old'))$$, 'already revoked');
reset role;
select set_config('request.jwt.claims', '', true);
select zz_check.expect($$select count(*) from nomad_core.provider_credentials where id = '00000000-0000-0000-0000-0000000000c1' and revoked_at is not null$$, 1);
select zz_check.expect($$select count(*) from nomad_docs.integration_connections where external_account_id = 'portal-old' and status = 'revoked' and credential_id is not null$$, 1);
update nomad_core.subscriptions set plan_code = 'B' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'docs';
create function pg_temp.docs_locked_checks() returns void language plpgsql as $f$
begin
  set local role service_role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform zz_check.fails_with($$insert into nomad_docs.doc_exports (organization_id, project_id, document_version_id, format, watermark)
    values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), (select id from t_ids where k = 'ver_q'), 'docx', true)$$, 'export_docx');
  perform zz_check.fails_with($$insert into nomad_docs.doc_exports (organization_id, project_id, document_version_id, format, watermark)
    values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), (select id from t_ids where k = 'ver_q'), 'pdf', false)$$, 'no_watermark');
  perform zz_check.fails_with($$insert into nomad_docs.webhook_endpoints (organization_id, url, events)
    values ('00000000-0000-0000-0000-00000000000a', 'https://hooks.example.test/b', '{document.finalized}')$$, 'webhooks');
  -- 기존 유료 행: 웹훅 발송·동기화·외부 매핑·연결 재활성화 거부
  perform zz_check.fails_with($$insert into nomad_docs.webhook_deliveries (organization_id, endpoint_id, event_type, event_id, payload_hash)
    values ('00000000-0000-0000-0000-00000000000a', (select id from nomad_docs.webhook_endpoints where url = 'https://hooks.example.test/a'),
            'document.finalized', gen_random_uuid(), repeat('a', 64))$$, 'webhooks');
  perform zz_check.fails_with($$insert into nomad_docs.sync_runs (organization_id, connection_id, entity, direction)
    values ('00000000-0000-0000-0000-00000000000a', (select id from nomad_docs.integration_connections where provider = 'hubspot' and status <> 'revoked'), 'project', 'pull')$$, 'crm_integrations');
  perform zz_check.fails_with($$select nomad_docs.upsert_external_ref((select id from nomad_docs.integration_connections where provider = 'hubspot' and status <> 'revoked'), 'project',
    (select id from t_ids where k = 'proj_a1'), 'deal', 'hs-2')$$, 'crm_integrations');
  perform zz_check.fails_with($$update nomad_docs.integration_connections set status = 'active' where provider = 'n8n'$$, 'crm_integrations');
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
  perform zz_check.fails_with($$select nomad_docs.decide_approval((select id from nomad_docs.approval_steps limit 1), 'approved')$$, 'approvals required');
  set local role service_role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  -- 무료 기능은 남는다: PDF(워터마크) 내보내기
  insert into nomad_docs.doc_exports (organization_id, project_id, document_version_id, format, watermark)
    values ('00000000-0000-0000-0000-00000000000a', (select id from t_ids where k = 'proj_a1'), (select id from t_ids where k = 'ver_q'), 'pdf', true);
  -- 무료 기능 docs 로 읽기·쓰기 유지(owner)
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
  perform zz_check.expect('select count(*) from nomad_docs.projects', 2);
  perform zz_check.expect('select count(*) from nomad_docs.doc_types where is_active', 8);
  -- 조직 B(구독 유지)는 영향 없음
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
  perform zz_check.expect('select count(*) from nomad_docs.projects', 0);
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $f$;
-- 9-1 만료
update nomad_core.subscriptions set starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
  where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'docs';
select pg_temp.docs_locked_checks();
-- 9-2 inactive
update nomad_core.subscriptions set status = 'inactive', ends_at = null
  where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'docs';
select pg_temp.docs_locked_checks();
-- 9-3 구독 행 없음
delete from nomad_core.subscriptions where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'docs';
select pg_temp.docs_locked_checks();
-- 재구독(B)하면 유료 기능이 다시 열린다
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status)
  values ('00000000-0000-0000-0000-00000000000a', 'docs', 'B', 'active');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_docs.webhook_endpoints (organization_id, url, events)
  values ('00000000-0000-0000-0000-00000000000a', 'https://hooks.example.test/c', '{document.finalized}');
reset role;
select set_config('request.jwt.claims', '', true);

-- ==== 10. 회귀: anon 0 · 권한 · 라우팅 시드(0002) ====
-- anon 이 실행 가능한 nomad_docs 함수 0(D8: 공개 경로 없음)
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_docs' and has_function_privilege('anon', p.oid, 'execute')$$, 0);
-- anon 은 테이블·뷰 권한 전무
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_docs' and c.relkind in ('r', 'v')
    and has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')$$, 0);
-- 서버 전용 표: authenticated 쓰기 권한 없음
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_docs' and c.relkind = 'r'
    and c.relname in ('documents', 'document_versions', 'generation_runs', 'doc_exports', 'doc_counters', 'uploads', 'trace_links',
                      'integration_connections', 'webhook_endpoints', 'webhook_deliveries', 'sync_runs', 'runtime_config', 'daily_credit_usage')
    and has_table_privilege('authenticated', c.oid, 'insert,delete,truncate')$$, 0);
-- 모든 표 RLS
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_docs' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'nomad_docs' and c.relkind = 'r'$$, 31);
select zz_check.expect($$select count(*) from pg_namespace where nspname = 'nomad_docs_private'$$, 0);
select zz_check.expect($$select count(*) from nomad_core.ai_routing_settings where organization_id is null and product_code = 'docs'$$, 13);
-- 운영 수치 시드 없음(runtime_config 비어 있음, 함수는 코드 기본값) · 제품 함수가 core 표(jobs·credit_ledger)를 직접 고치지 않음
select zz_check.expect('select count(*) from nomad_docs.runtime_config', 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'nomad_docs' and p.prosrc ~* '(update|insert into|delete from)\s+nomad_core\.(jobs|credit_ledger)'$$, 0);
-- anon 은 nomad_docs 스키마 usage 도 없다
select zz_check.expect($$select has_schema_privilege('anon', 'nomad_docs', 'usage')::int$$, 0);
