-- analytics org안 검사: 조직 2곳 교차 접근 0 · anon 표 접근 0(공개 RPC 하나) · 역할별 쓰기 범위(grant 목록 고정) · 원본 불변·경로 접두
--   · 파일 한도 fail-closed · 참조 조직·프로젝트 일치 · 공유 링크·웹훅 토큰 RPC · 구독 끊김(쓰기 잠금·읽기·기존 공유 열람 유지) · 연쇄 삭제 · Storage.
-- 합성 데이터만, 마지막에 rollback. 실행: bash products/analytics/run_check.sh

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
create function zz_check.expect_text(q text, want text) returns void language plpgsql as $$
declare r text; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
create table zz_check.vals (k text primary key, v text);
create function zz_check.id(key text) returns uuid language sql stable as $$ select v::uuid from zz_check.vals where k = key $$;
-- 조직 org 의 행 수를 표 전체에 걸쳐 센다(호출자 권한·RLS 그대로). pipelines 는 허용 컬럼만 읽는다.
create function zz_check.org_rows(org uuid) returns bigint language plpgsql as $$
declare t text; n bigint; total bigint := 0;
begin
  for t in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'nomad_analytics' and c.relkind = 'r' loop
    execute format('select count(id) from nomad_analytics.%I where organization_id = $1', t) into n using org;
    total := total + n;
  end loop;
  return total;
end $$;
grant all on zz_check.vals to service_role, authenticated;
grant select on zz_check.vals to anon;
grant execute on all functions in schema zz_check to anon, authenticated, service_role;

-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u5 viewer, 플랜 A 구독), 조직 B(u2 owner, 구독 없음 = C), u4 = 어느 조직에도 없음 ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
  ('00000000-0000-0000-0000-00000000000a', 'analytics', 'A', 'active');
-- 한도는 저장소 시드가 아니라 검사용(rollback). C 는 아직 키 없음 → fail-closed 확인 뒤 넣는다.
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('analytics', 'A', 'max_files_per_project', 3);

-- ==== 0. 서버: 프로젝트·파일·실행·결과·파이프라인·알림 ====
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_analytics.projects (id, organization_id, name, status) values
  ('00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-00000000000a', 'A 프로젝트', 'completed'),
  ('00000000-0000-0000-0000-000000001b01', '00000000-0000-0000-0000-00000000000b', 'B 프로젝트', 'completed');
insert into nomad_analytics.datasets (id, organization_id, project_id, file_name, file_type, size_bytes) values
  ('00000000-0000-0000-0000-000000002a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', 'a.csv', 'csv', 100);
-- C 에 max_files_per_project 키가 없으면 0 = 거부(fail-closed)
select zz_check.fails_with($$insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000001b01', 'b.csv', 'csv', 100)$$, 'AN001');
reset role;
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values ('analytics', 'C', 'max_files_per_project', 1);
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_analytics.datasets (id, organization_id, project_id, file_name, file_type, size_bytes) values
  ('00000000-0000-0000-0000-000000002b01', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000001b01', 'b.csv', 'csv', 100);
select zz_check.fails_with($$insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000001b01', 'b2.csv', 'csv', 100)$$, 'AN001');
-- 참조 조직 일치: 다른 조직 프로젝트에 데이터셋(복합 FK)
select zz_check.fails_with($$insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001b01', 'x.csv', 'csv', 1)$$, '23503');
insert into nomad_analytics.dataset_versions (organization_id, dataset_id, version, kind, storage_path) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002a01', 1, 'raw', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a01/raw/source.csv'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002a01', 2, 'cleaned', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a01/v2.parquet');
-- 경로 첫 폴더 = 자기 조직, 상위 경로 금지
select zz_check.fails_with($$insert into nomad_analytics.dataset_versions (organization_id, dataset_id, version, kind, storage_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002a01', 3, 'cleaned', '00000000-0000-0000-0000-00000000000b/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a01/v3.parquet')$$, 'dataset_versions_path_check');
select zz_check.fails_with($$insert into nomad_analytics.dataset_versions (organization_id, dataset_id, version, kind, storage_path) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002a01', 3, 'cleaned', '00000000-0000-0000-0000-00000000000a/analytics/datasets/../v3.parquet')$$, 'dataset_versions_path_check');
insert into nomad_analytics.analysis_runs (id, organization_id, project_id, dataset_id, status) values
  ('00000000-0000-0000-0000-000000003a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-000000002a01', 'done'),
  ('00000000-0000-0000-0000-000000003b01', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000001b01', '00000000-0000-0000-0000-000000002b01', 'done');
-- 웹훅 실행: A(automation) 허용, B(C) AN002
insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id, trigger) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-000000002a01', 'webhook');
select zz_check.fails_with($$insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id, trigger) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000001b01', '00000000-0000-0000-0000-000000002b01', 'schedule')$$, 'AN002');
insert into nomad_analytics.run_steps (organization_id, run_id, step_no, status) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000003a01', 1, 'done');
insert into nomad_analytics.cleaning_proposals (id, organization_id, run_id, kind, title, plan) values
  ('00000000-0000-0000-0000-000000004a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000003a01', 'dedupe', '중복 제거', '{}');
insert into nomad_analytics.change_logs (organization_id, proposal_id, run_id, detail) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000004a01', '00000000-0000-0000-0000-000000003a01', '{}');
select zz_check.fails_with($$insert into nomad_analytics.change_logs (organization_id, proposal_id, run_id, detail) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000004a01', '00000000-0000-0000-0000-000000003b01', '{}')$$, '23503');
insert into nomad_analytics.dashboards (id, organization_id, run_id, project_id, spec) values
  ('00000000-0000-0000-0000-000000005a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000003a01', '00000000-0000-0000-0000-000000001a01', '{}');
insert into nomad_analytics.widgets (organization_id, dashboard_id, chart_type, config) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000005a01', 'bar', '{}');
insert into nomad_analytics.reports (id, organization_id, run_id, project_id, pdf_path) values
  ('00000000-0000-0000-0000-000000006a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000003a01', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-00000000000a/analytics/reports/00000000-0000-0000-0000-000000006a01/v1.pdf'),
  ('00000000-0000-0000-0000-000000006b01', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000003b01', '00000000-0000-0000-0000-000000001b01', null);
select zz_check.fails_with($$update nomad_analytics.reports set docx_path = '00000000-0000-0000-0000-00000000000b/analytics/reports/x.docx' where id = '00000000-0000-0000-0000-000000006a01'$$, 'reports_paths_check');
insert into nomad_analytics.report_sections (id, organization_id, report_id, kind, content) values
  ('00000000-0000-0000-0000-000000007a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000006a01', 'trend', '{"chart": "line", "value": 42, "text": "증가"}');
insert into nomad_analytics.pipelines (id, organization_id, project_id) values
  ('00000000-0000-0000-0000-000000008a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01');
insert into nomad_analytics.schedules (organization_id, pipeline_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000008a01');
insert into nomad_analytics.usage_events (organization_id, user_id, kind) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'ai_call');
insert into nomad_analytics.questions (id, organization_id, project_id, question, answer) values
  ('00000000-0000-0000-0000-000000009a01', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '매출 추이?', '{}');
insert into nomad_analytics.notifications (organization_id, user_id, project_id, kind, title) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000001a01', 'run_done', 'A 완료'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-000000001a01', 'run_done', 'A 완료');
-- 알림 받는 사람은 그 조직 멤버만(u4 는 비멤버, u2 는 B 멤버)
select zz_check.fails_with($$insert into nomad_analytics.notifications (organization_id, user_id, kind, title) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'x', 'x')$$, '23503');
select zz_check.fails_with($$insert into nomad_analytics.notifications (organization_id, user_id, kind, title) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'x', 'x')$$, '23503');
reset role;

-- ==== 1. anon: 모든 표 거부, 사용자 RPC 거부, 공개 RPC 는 형식 검사 ====
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'nomad_analytics' and c.relkind = 'r' loop
    perform zz_check.denied(format('select count(*) from nomad_analytics.%I', t));
    perform zz_check.denied(format('delete from nomad_analytics.%I', t));
  end loop;
end $$;
select zz_check.denied($$select nomad_analytics.has_access('00000000-0000-0000-0000-00000000000a')$$);
select zz_check.denied($$select * from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006a01')$$);
select zz_check.denied($$select nomad_analytics.pipeline_webhook_token('00000000-0000-0000-0000-000000001a01')$$);
select zz_check.expect_text($$select nomad_analytics.get_shared_report('../x')::text$$, null);
select zz_check.expect_text($$select nomad_analytics.get_shared_report('AAAAAAAAAAAAAAAAAAAAAAAA')::text$$, null);
reset role;

-- ==== 2. 조직 A owner: 공유 링크·웹훅 토큰(RPC), 서버 컬럼·다른 조직 쓰기 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
insert into zz_check.vals select 'share1', s.id::text from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006a01') s;
insert into zz_check.vals select 'token1', s.token from nomad_analytics.report_shares s where s.id = zz_check.id('share1');
select zz_check.expect('select count(*) from nomad_analytics.report_shares', 1);
select zz_check.fails_with($$select * from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006a01', now() - interval '1 day')$$, '22023');
select zz_check.expect($$select length(nomad_analytics.pipeline_webhook_token('00000000-0000-0000-0000-000000001a01'))$$, 24);
-- webhook_token 은 SELECT grant 제외(select * 도 거부), 나머지 컬럼은 읽힌다
select zz_check.denied('select webhook_token from nomad_analytics.pipelines');
select zz_check.denied('select * from nomad_analytics.pipelines');
select zz_check.expect('select count(id) from nomad_analytics.pipelines', 1);
-- 공유 표·서버 표 직접 쓰기 거부
select zz_check.denied($$insert into nomad_analytics.report_shares (organization_id, report_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000006a01')$$);
select zz_check.denied($$update nomad_analytics.report_shares set revoked = false$$);
select zz_check.denied($$update nomad_analytics.projects set status = 'draft' where id = '00000000-0000-0000-0000-000000001a01'$$);
select zz_check.denied($$insert into nomad_analytics.projects (id, organization_id, name) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 'x')$$);
select zz_check.denied($$update nomad_analytics.dashboards set spec = '{}'$$);
select zz_check.denied($$insert into nomad_analytics.questions (organization_id, project_id, question, answer) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', 'q', '{}')$$);
select zz_check.fails_with($$insert into nomad_analytics.projects (organization_id, name) values ('00000000-0000-0000-0000-00000000000b', 'x')$$, '42501');
-- 실행: 다른 조직 데이터셋을 목록에 섞으면 AN003, 사용자 경로는 수동·대기 상태로 고정
select zz_check.fails_with($$insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id, dataset_ids) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-000000002a01', array['00000000-0000-0000-0000-000000002a01', '00000000-0000-0000-0000-000000002b01']::uuid[])$$, 'AN003');
select zz_check.denied($$insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id, trigger) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-000000002a01', 'webhook')$$);
-- 알림: 본인 것만, read_at 은 서버 시각
select zz_check.expect('select count(*) from nomad_analytics.notifications', 1);
update nomad_analytics.notifications set read_at = '2000-01-01' where read_at is null;
select zz_check.expect($$select count(*) from nomad_analytics.notifications where read_at > now() - interval '1 minute'$$, 1);
select zz_check.denied($$update nomad_analytics.notifications set title = 'x'$$);
reset role;
-- anon 공개 열람: 공개 컬럼만
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_analytics.get_shared_report((select v from zz_check.vals where k = 'token1')) ->> 'project_name'$$, 'A 프로젝트');
select zz_check.expect($$select jsonb_array_length(nomad_analytics.get_shared_report((select v from zz_check.vals where k = 'token1')) -> 'sections')$$, 1);
select zz_check.expect($$select count(*) from jsonb_object_keys(nomad_analytics.get_shared_report((select v from zz_check.vals where k = 'token1')))$$, 4);
reset role;

-- ==== 3. editor: 만들기·올리기·실행·그래프 유형·고정·끄기. 삭제(프로젝트)·공유·토큰은 owner/admin ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
with i as (insert into nomad_analytics.projects (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', '편집자 프로젝트') returning id)
insert into zz_check.vals select 'p2', id::text from i;
select zz_check.expect_text($$select created_by::text || '/' || status from nomad_analytics.projects where id = zz_check.id('p2')$$, '00000000-0000-0000-0000-0000000000a3/draft');
with i as (insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000a', zz_check.id('p2'), '판매.xlsx', 'xlsx', 2048) returning id)
insert into zz_check.vals select 'd2', id::text from i;
-- 원본 raw v1 은 정해진 경로만, cleaned·다른 경로 거부
select zz_check.fails_with(format($$insert into nomad_analytics.dataset_versions (organization_id, dataset_id, version, kind, storage_path) values ('00000000-0000-0000-0000-00000000000a', %L, 1, 'raw', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/%s/raw/source.xlsx')$$, zz_check.id('d2'), zz_check.id('d2')), 'raw v1 upload path');
select zz_check.fails_with(format($$insert into nomad_analytics.dataset_versions (organization_id, dataset_id, version, kind, storage_path) values ('00000000-0000-0000-0000-00000000000a', %L, 2, 'cleaned', '00000000-0000-0000-0000-00000000000a/analytics/datasets/%s/%s/v2.parquet')$$, zz_check.id('d2'), zz_check.id('p2'), zz_check.id('d2')), '42501');
do $$ begin
  execute format($q$insert into nomad_analytics.dataset_versions (organization_id, dataset_id, version, kind, storage_path) values ('00000000-0000-0000-0000-00000000000a', %L, 1, 'raw', '00000000-0000-0000-0000-00000000000a/analytics/datasets/%s/%s/raw/source.xlsx')$q$, zz_check.id('d2'), zz_check.id('p2'), zz_check.id('d2'));
end $$;
select zz_check.denied($$update nomad_analytics.dataset_versions set storage_path = storage_path$$);
select zz_check.denied($$delete from nomad_analytics.dataset_versions$$);
select zz_check.expect('select count(*) from nomad_analytics.dataset_versions', 3);
-- 파일 한도(A=3): 프로젝트 p2 에 2개 더 → 3번째 추가 AN001. 옮기기도 한도
insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes)
select '00000000-0000-0000-0000-00000000000a', zz_check.id('p2'), 'f' || g || '.csv', 'csv', 10 from generate_series(1, 2) g;
select zz_check.fails_with(format($$insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000a', %L, 'f9.csv', 'csv', 10)$$, zz_check.id('p2')), 'AN001');
select zz_check.fails_with(format($$update nomad_analytics.datasets set project_id = %L where id = '00000000-0000-0000-0000-000000002a01'$$, zz_check.id('p2')), 'AN001');
select zz_check.fails_with(format($$update nomad_analytics.datasets set project_id = '00000000-0000-0000-0000-000000001b01' where id = %L$$, zz_check.id('d2')), '23503');
update nomad_analytics.datasets set sheet_name = '시트2' where id = zz_check.id('d2');
select zz_check.denied(format($$update nomad_analytics.datasets set row_count = 1 where id = %L$$, zz_check.id('d2')));
-- 실행(수동): 다른 프로젝트 데이터셋 섞으면 AN003
select zz_check.fails_with(format($$insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id, dataset_ids) values ('00000000-0000-0000-0000-00000000000a', %L, %L, array[%L, '00000000-0000-0000-0000-000000002a01']::uuid[])$$, zz_check.id('p2'), zz_check.id('d2'), zz_check.id('d2')), 'AN003');
with i as (insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id) values ('00000000-0000-0000-0000-00000000000a', zz_check.id('p2'), zz_check.id('d2')) returning id)
insert into zz_check.vals select 'r2', id::text from i;
select zz_check.expect_text($$select status || '/' || trigger || '/' || array_length(dataset_ids, 1) from nomad_analytics.analysis_runs where id = zz_check.id('r2')$$, 'pending/manual/1');
select zz_check.denied($$update nomad_analytics.analysis_runs set status = 'done'$$);
-- 보안 리뷰 1: 실행이 참조하는 데이터셋은 편집자가 지울 수 없다(실행·보고서·공유 연쇄 삭제 방지). 참조 없는 파일은 지운다.
select zz_check.fails_with(format($$delete from nomad_analytics.datasets where id = %L$$, zz_check.id('d2')), 'dataset has analysis runs');
select zz_check.fails_with($$delete from nomad_analytics.datasets where id = '00000000-0000-0000-0000-000000002a01'$$, 'dataset has analysis runs');
select zz_check.expect(format($$with d as (delete from nomad_analytics.datasets where project_id = %L and file_name = 'f1.csv' returning 1) select count(*) from d$$, zz_check.id('p2')), 1);
-- 보고서 섹션: chart 만
update nomad_analytics.report_sections set content = jsonb_set(content, '{chart}', '"bar"') where id = '00000000-0000-0000-0000-000000007a01';
select zz_check.fails_with($$update nomad_analytics.report_sections set content = jsonb_set(content, '{value}', '1') where id = '00000000-0000-0000-0000-000000007a01'$$, 'only content.chart');
select zz_check.denied($$update nomad_analytics.report_sections set kind = 'x' where id = '00000000-0000-0000-0000-000000007a01'$$);
-- 보안 리뷰 3: chart 는 짧은 식별자만(공개 RPC 로 anon 에 나감)
select zz_check.fails_with($$update nomad_analytics.report_sections set content = jsonb_set(content, '{chart}', to_jsonb(repeat('a', 33))) where id = '00000000-0000-0000-0000-000000007a01'$$, 'report_sections_chart_check');
select zz_check.fails_with($$update nomad_analytics.report_sections set content = jsonb_set(content, '{chart}', '"<script>"') where id = '00000000-0000-0000-0000-000000007a01'$$, 'report_sections_chart_check');
-- 질문 고정, 파이프라인 끄기
update nomad_analytics.questions set pinned = true where id = '00000000-0000-0000-0000-000000009a01';
update nomad_analytics.pipelines set enabled = false where id = '00000000-0000-0000-0000-000000008a01';
-- 프로젝트 삭제는 owner/admin: 편집자 삭제는 0행
delete from nomad_analytics.projects where id = zz_check.id('p2');
select zz_check.expect($$select count(*) from nomad_analytics.projects where id = zz_check.id('p2')$$, 1);
select zz_check.fails_with($$select * from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006a01')$$, '42501');
select zz_check.fails_with($$select nomad_analytics.revoke_report_share(zz_check.id('share1'))$$, '42501');
select zz_check.fails_with($$select nomad_analytics.pipeline_webhook_token('00000000-0000-0000-0000-000000001a01')$$, '42501');
select zz_check.expect('select count(*) from nomad_analytics.report_shares', 0);
select zz_check.expect('select count(*) from nomad_analytics.notifications', 1);
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into nomad_analytics.run_steps (organization_id, run_id, step_no) values ('00000000-0000-0000-0000-00000000000a', zz_check.id('r2'), 1);
reset role;

-- ==== 4. viewer: 읽기만 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_analytics.projects', 2);
select zz_check.expect('select count(*) from nomad_analytics.usage_events', 1);
select zz_check.fails_with($$insert into nomad_analytics.projects (organization_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$, '42501');
select zz_check.fails_with($$insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', 'v.csv', 'csv', 1)$$, '42501');
select zz_check.expect($$with u as (update nomad_analytics.questions set pinned = false returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with d as (delete from nomad_analytics.datasets returning 1) select count(*) from d$$, 0);
select zz_check.expect($$with u as (update nomad_analytics.pipelines set enabled = true returning 1) select count(*) from u$$, 0);
reset role;

-- ==== 5. 다른 조직·무소속: A 행 0, A 대상 RPC 는 존재 비노출(P0002), BEFORE 트리거 비멤버 선거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect($$select zz_check.org_rows('00000000-0000-0000-0000-00000000000a')$$, 0);
select zz_check.expect($$select count(*) from nomad_analytics.report_shares$$, 0);
select zz_check.fails_with($$insert into nomad_analytics.datasets (organization_id, project_id, file_name, file_type, size_bytes) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', 'x.csv', 'csv', 1)$$, 'not a member of this organization');
select zz_check.fails_with($$insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-000000002a01')$$, 'not a member of this organization');
select zz_check.fails_with($$select * from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006a01')$$, 'P0002');
select zz_check.fails_with($$select nomad_analytics.revoke_report_share(zz_check.id('share1'))$$, 'P0002');
select zz_check.fails_with($$select nomad_analytics.pipeline_webhook_token('00000000-0000-0000-0000-000000001a01')$$, 'P0002');
select zz_check.expect($$with u as (update nomad_analytics.projects set name = 'x' where organization_id = '00000000-0000-0000-0000-00000000000a' returning 1) select count(*) from u$$, 0);
select zz_check.expect($$with d as (delete from nomad_analytics.projects where organization_id = '00000000-0000-0000-0000-00000000000a' returning 1) select count(*) from d$$, 0);
-- B(C 무료): 작업 공간은 쓰고, 공유는 잠김(AN002)
select zz_check.expect($$select zz_check.org_rows('00000000-0000-0000-0000-00000000000b')$$, 4);
select zz_check.fails_with($$select * from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006b01')$$, 'AN002');
insert into nomad_analytics.projects (organization_id, name) values ('00000000-0000-0000-0000-00000000000b', 'B 새 프로젝트');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
select zz_check.expect($$select zz_check.org_rows('00000000-0000-0000-0000-00000000000a') + zz_check.org_rows('00000000-0000-0000-0000-00000000000b')$$, 0);
select zz_check.expect($$select count(*) from nomad_analytics.notifications$$, 0);
reset role;

-- ==== 6. 구독 끊김(A inactive = C): 유료 기능 쓰기 잠금, 읽기·기존 공유 열람·해제·끄기 유지 ====
update nomad_core.subscriptions set status = 'inactive' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'analytics';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.fails_with($$select * from nomad_analytics.create_report_share('00000000-0000-0000-0000-000000006a01')$$, 'AN002');
select zz_check.fails_with($$update nomad_analytics.pipelines set enabled = true where id = '00000000-0000-0000-0000-000000008a01'$$, '42501');
select zz_check.fails_with($$select nomad_analytics.pipeline_webhook_token('00000000-0000-0000-0000-000000001a01')$$, 'AN002');
update nomad_analytics.pipelines set enabled = false where id = '00000000-0000-0000-0000-000000008a01';
select zz_check.expect('select count(id) from nomad_analytics.pipelines', 1);
select zz_check.expect('select count(*) from nomad_analytics.schedules', 1);
select zz_check.expect('select count(*) from nomad_analytics.report_shares', 1);
select zz_check.expect('select count(*) from nomad_analytics.reports', 1);
select zz_check.expect('select count(*) from nomad_analytics.analysis_runs', 3);
-- 작업 공간(C 기능)은 그대로
update nomad_analytics.projects set name = 'A 프로젝트(이름 변경)' where id = '00000000-0000-0000-0000-000000001a01';
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select zz_check.fails_with($$insert into nomad_analytics.analysis_runs (organization_id, project_id, dataset_id, trigger) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000001a01', '00000000-0000-0000-0000-000000002a01', 'schedule')$$, 'AN002');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_analytics.get_shared_report((select v from zz_check.vals where k = 'token1')) ->> 'project_name'$$, 'A 프로젝트(이름 변경)');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select nomad_analytics.revoke_report_share(zz_check.id('share1'));
select nomad_analytics.revoke_report_share(zz_check.id('share1'));  -- 재해제는 그대로
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select zz_check.expect_text($$select nomad_analytics.get_shared_report((select v from zz_check.vals where k = 'token1'))::text$$, null);
reset role;
select zz_check.expect($$select count(*) from nomad_core.audit_log where organization_id = '00000000-0000-0000-0000-00000000000a' and action like 'analytics.report_share.%'$$, 2);
update nomad_core.subscriptions set status = 'active' where organization_id = '00000000-0000-0000-0000-00000000000a' and product_code = 'analytics';

-- ==== 7. owner 삭제: 프로젝트 연쇄 삭제(서버 표 가드가 연쇄를 막지 않음) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect($$with d as (delete from nomad_analytics.projects where id = zz_check.id('p2') returning 1) select count(*) from d$$, 1);
select zz_check.expect($$select count(*) from nomad_analytics.datasets where project_id = zz_check.id('p2')$$, 0);
reset role;
select zz_check.expect($$select count(*) from nomad_analytics.run_steps where run_id = zz_check.id('r2')$$, 0);

-- ==== 8. Storage: 경로 첫 폴더 = 조직, 다른 조직 파일 0, 원본 업로드는 편집자·정해진 경로만 ====
insert into storage.objects (bucket_id, name) values
  ('analytics-datasets', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a01/raw/source.csv'),
  ('analytics-reports', '00000000-0000-0000-0000-00000000000a/analytics/reports/00000000-0000-0000-0000-000000006a01/v1.pdf'),
  ('analytics-datasets', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a01/v2.parquet'),
  ('analytics-datasets', '00000000-0000-0000-0000-00000000000b/analytics/datasets/00000000-0000-0000-0000-000000001b01/00000000-0000-0000-0000-000000002b01/raw/source.csv');
select zz_check.expect($$select count(*) from storage.buckets where id like 'analytics-%' and public$$, 0);
-- Storage API 처럼 직접 삭제 보호를 풀고 정책만 본다(rollback)
select set_config('storage.allow_delete_query', 'true', true);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect($$select count(*) from storage.objects where bucket_id like 'analytics-%'$$, 1);
select zz_check.expect($$with d as (delete from storage.objects where bucket_id like 'analytics-%' and name like '00000000-0000-0000-0000-00000000000a/%' returning 1) select count(*) from d$$, 0);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect($$select count(*) from storage.objects where bucket_id like 'analytics-%'$$, 3);
select zz_check.fails_with($$insert into storage.objects (bucket_id, name) values ('analytics-datasets', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a02/raw/source.csv')$$, '42501');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
insert into storage.objects (bucket_id, name) values ('analytics-datasets', '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a03/raw/source.xlsx');
select zz_check.fails_with($$insert into storage.objects (bucket_id, name) values ('analytics-datasets', '00000000-0000-0000-0000-00000000000b/analytics/datasets/00000000-0000-0000-0000-000000001b01/00000000-0000-0000-0000-000000002b02/raw/source.csv')$$, '42501');
select zz_check.fails_with($$insert into storage.objects (bucket_id, name) values ('analytics-datasets', '00000000-0000-0000-0000-00000000000a/analytics/datasets/x/../v9.parquet')$$, '42501');
select zz_check.fails_with($$insert into storage.objects (bucket_id, name) values ('analytics-reports', '00000000-0000-0000-0000-00000000000a/analytics/reports/x.pdf')$$, '42501');
-- 보고서 파일 삭제는 owner/admin: 편집자는 0행
select zz_check.expect($$with d as (delete from storage.objects where bucket_id = 'analytics-reports' returning 1) select count(*) from d$$, 0);
-- 보안 리뷰 2: 기록된 원본(버전 행 있음)·정제본은 편집자가 못 지운다(지우고 같은 경로 재업로드 우회 차단). 기록 전 업로드만 지운다.
select zz_check.expect($$with d as (delete from storage.objects where name = '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a01/raw/source.csv' returning 1) select count(*) from d$$, 0);
select zz_check.expect($$with d as (delete from storage.objects where name like '%/v2.parquet' returning 1) select count(*) from d$$, 0);
select zz_check.expect($$with d as (delete from storage.objects where name = '00000000-0000-0000-0000-00000000000a/analytics/datasets/00000000-0000-0000-0000-000000001a01/00000000-0000-0000-0000-000000002a03/raw/source.xlsx' returning 1) select count(*) from d$$, 1);
reset role;

-- ==== 9. 카탈로그: 모든 표 RLS · 표 17개 · anon 표·컬럼 grant 0 · anon 실행 함수 1 · authenticated 쓰기 범위 고정 ====
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_analytics' and c.relkind = 'r' and not c.relrowsecurity$$, 0);
select zz_check.expect($$select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'nomad_analytics' and c.relkind = 'r'$$, 17);
select zz_check.expect($$select count(*) from information_schema.role_table_grants where table_schema = 'nomad_analytics' and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from information_schema.column_privileges where table_schema = 'nomad_analytics' and grantee in ('anon', 'PUBLIC')$$, 0);
select zz_check.expect($$select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'nomad_analytics' and has_function_privilege('anon', p.oid, 'execute')$$, 1);
-- 표 단위 쓰기 grant: delete 3개만(projects·datasets·questions). insert·update 는 아래 컬럼 목록만.
select zz_check.expect_text($$select string_agg(table_name || ':' || privilege_type, ',' order by table_name, privilege_type) from information_schema.role_table_grants where table_schema = 'nomad_analytics' and grantee = 'authenticated' and privilege_type <> 'SELECT'$$,
  'datasets:DELETE,projects:DELETE,questions:DELETE');
select zz_check.expect_text($$select string_agg(table_name || '.' || column_name || ':' || privilege_type, ',' order by table_name, privilege_type, column_name) from information_schema.column_privileges where table_schema = 'nomad_analytics' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE')$$,
  'analysis_runs.dataset_id:INSERT,analysis_runs.dataset_ids:INSERT,analysis_runs.organization_id:INSERT,analysis_runs.project_id:INSERT,'
  || 'dataset_versions.dataset_id:INSERT,dataset_versions.kind:INSERT,dataset_versions.organization_id:INSERT,dataset_versions.storage_path:INSERT,dataset_versions.version:INSERT,'
  || 'datasets.file_name:INSERT,datasets.file_type:INSERT,datasets.organization_id:INSERT,datasets.project_id:INSERT,datasets.sheet_name:INSERT,datasets.size_bytes:INSERT,'
  || 'datasets.project_id:UPDATE,datasets.sheet_name:UPDATE,notifications.read_at:UPDATE,pipelines.enabled:UPDATE,'
  || 'projects.name:INSERT,projects.organization_id:INSERT,projects.name:UPDATE,questions.pinned:UPDATE,report_sections.content:UPDATE');
