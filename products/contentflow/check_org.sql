-- ContentFlow org안 검사: 조직 2곳 교차 접근 거부 · 역할별 권한 · 승인 흐름 · 한도 · 동기화 컬럼 · 발행 큐 · 분석 연결(0002). 합성 데이터만, 마지막에 rollback.
-- 실행(저장소 루트에서; org 파일의 begin/commit을 빼고 한 트랜잭션으로 합친다):
--   { sed '/^-- @@APPLY/,$d' products/contentflow/check_org.sql
--     sed '/^begin;$/d;/^commit;$/d' products/contentflow/org/0*.sql
--     sed -n '/^-- @@APPLY/,$p' products/contentflow/check_org.sql; } \
--   | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1
begin;
drop schema if exists nomad_contentflow cascade;
drop schema if exists nomad_contentflow_private cascade;

-- core 20261119000100 이 들어가기 전까지의 임시 정의(검사 트랜잭션 안에서만).
create or replace function nomad_core.touch_updated_at() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end $$;

-- ---- 검사 도우미 (authenticated가 쓸 수 있게 별도 스키마) ----
create schema zz_check;
grant usage on schema zz_check to anon, authenticated;
create function zz_check.denied(q text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin execute q; ok := true; exception when others then null; end;
  if ok then raise exception 'NOT DENIED: %', q; end if;
end $$;
create function zz_check.fails_with(q text, msg text) returns void language plpgsql as $$
declare got text;
begin
  begin execute q; got := null; exception when others then got := sqlerrm; end;
  if got is null then raise exception 'NOT DENIED: %', q; end if;
  if got not like '%' || msg || '%' then raise exception 'wrong error for %: got [%], want [%]', q, got, msg; end if;
end $$;
create function zz_check.n(q text) returns bigint language plpgsql as $$
declare r bigint; begin execute q into r; return r; end $$;
create function zz_check.expect(q text, want bigint) returns void language plpgsql as $$
declare r bigint; begin execute q into r;
  if r is distinct from want then raise exception 'EXPECT % got % for %', want, r, q; end if; end $$;
grant execute on all functions in schema zz_check to anon, authenticated;

-- @@APPLY
-- ---- 합성 데이터: 조직 A(u1 owner, u3 editor, u4 viewer+검수자, u5 viewer), 조직 B(u2 owner) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'u1@example.test'), ('00000000-0000-0000-0000-0000000000a2', 'u2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 'u3@example.test'), ('00000000-0000-0000-0000-0000000000a4', 'u4@example.test'),
  ('00000000-0000-0000-0000-0000000000a5', 'u5@example.test');
insert into nomad_core.organizations (id, name, kind) values
  ('00000000-0000-0000-0000-00000000000a', 'org A', 'team'), ('00000000-0000-0000-0000-00000000000b', 'org B', 'team');
insert into nomad_core.memberships (organization_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4', 'viewer'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5', 'viewer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'owner');
insert into nomad_core.plans (product_code, code, name) values ('contentflow', 'A', 'A'), ('contentflow', 'B', 'B'), ('contentflow', 'C', 'C') on conflict do nothing;
-- 검사용 임시 한도(제품 시드 아님, rollback됨): 기본 플랜 C
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('contentflow', 'C', 'included_blogs', 1), ('contentflow', 'C', 'max_blogs', 3), ('contentflow', 'C', 'overage_allowed', 1)
  on conflict (product_code, plan_code, limit_key) do update set limit_value = excluded.limit_value;

-- 서버(postgres)가 조직 A·B 기초 데이터 입력
insert into nomad_contentflow.blogs (id, organization_id, platform, domain) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000a', 'wordpress', 'a.example.test'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-00000000000b', 'naver', 'b.example.test');
insert into nomad_contentflow.reviewers (organization_id, user_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a4');
insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values
  ('00000000-0000-0000-0000-00000000000a', 'alpha', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000000b', 'beta', '00000000-0000-0000-0000-0000000000a2');
insert into nomad_contentflow.articles (id, organization_id, owner_id, title, state) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'A article', 'idea'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'B article', 'idea');
insert into nomad_contentflow.cost_entries (organization_id, category, amount, currency, occurred_on, created_by) values
  ('00000000-0000-0000-0000-00000000000a', 'hosting', 10, 'USD', '2026-01-01', '00000000-0000-0000-0000-0000000000a1');
insert into nomad_contentflow.revenue_rows (organization_id, row_key, source, status, currency, report_date, revenue, timezone, period_start, period_end, created_by) values
  ('00000000-0000-0000-0000-00000000000a', 'k1', 'adsense', 'estimated', 'USD', '2026-01-02', 1, 'UTC', '2026-01-01', '2026-01-31', '00000000-0000-0000-0000-0000000000a1');

-- ==== 1. 조직 B(u2) 시점: 조직 A 데이터 전부 안 보이고 쓰기 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_contentflow.blogs', 1);
select zz_check.expect('select count(*) from nomad_contentflow.blogs where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.articles where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.keywords where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.site_checks where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.cost_entries where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.revenue_rows where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.reviewers where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.workspace_members(''00000000-0000-0000-0000-00000000000a'')', 0);
select zz_check.denied($$insert into nomad_contentflow.blogs (organization_id, platform, domain) values ('00000000-0000-0000-0000-00000000000a', 'wordpress', 'x.example.test')$$);
select zz_check.denied($$insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values ('00000000-0000-0000-0000-00000000000a', 'zzz', '00000000-0000-0000-0000-0000000000a2')$$);
select zz_check.denied($$insert into nomad_contentflow.articles (organization_id, owner_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2')$$);
-- 조직 B 소속으로 위장해 조직 A의 블로그를 참조(복합 FK 거부)
select zz_check.denied($$insert into nomad_contentflow.articles (organization_id, owner_id, blog_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b1')$$);
select zz_check.denied($$insert into nomad_contentflow.reviewers (organization_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5')$$);
-- 수정·삭제는 0행(보이지 않음)
update nomad_contentflow.articles set title = 'hacked' where id = '00000000-0000-0000-0000-0000000000c1';
delete from nomad_contentflow.keywords where organization_id = '00000000-0000-0000-0000-00000000000a';
update nomad_contentflow.blogs set domain = 'hacked.example.test' where id = '00000000-0000-0000-0000-0000000000b1';
reset role;
select zz_check.expect($$select count(*) from nomad_contentflow.articles where title = 'hacked'$$, 0);
select zz_check.expect($$select count(*) from nomad_contentflow.keywords where organization_id = '00000000-0000-0000-0000-00000000000a'$$, 1);
select zz_check.expect($$select count(*) from nomad_contentflow.blogs where domain = 'hacked.example.test'$$, 0);

-- ==== 2. 조직 A 시점 반대 방향(u1) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_contentflow.articles', 1);
select zz_check.expect('select count(*) from nomad_contentflow.articles where organization_id = ''00000000-0000-0000-0000-00000000000b''', 0);
select zz_check.expect('select count(*) from nomad_contentflow.workspace_members(''00000000-0000-0000-0000-00000000000a'')', 4);
select zz_check.denied($$insert into nomad_contentflow.articles (organization_id, owner_id) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1')$$);
-- 블로그 한도: 포함 1개(이미 1개 있음) → 확인 없이 2번째 거부, 확인하면 허용, 3번째까지, 4번째는 상한
select zz_check.fails_with($$insert into nomad_contentflow.blogs (organization_id, platform, domain) values ('00000000-0000-0000-0000-00000000000a', 'naver', 'n2.example.test')$$, 'BLOG_LIMIT_CONFIRM_REQUIRED');
insert into nomad_contentflow.blogs (organization_id, platform, domain, overage_ack) values ('00000000-0000-0000-0000-00000000000a', 'naver', 'n2.example.test', true);
insert into nomad_contentflow.blogs (organization_id, platform, domain, overage_ack) values ('00000000-0000-0000-0000-00000000000a', 'naver', 'n3.example.test', true);
select zz_check.fails_with($$insert into nomad_contentflow.blogs (organization_id, platform, domain, overage_ack) values ('00000000-0000-0000-0000-00000000000a', 'naver', 'n4.example.test', true)$$, 'BLOG_LIMIT_REACHED');
select zz_check.expect($$select count(*) from nomad_contentflow.audit_logs where action = 'blog.overage_ack'$$, 2);
select zz_check.expect($$select count(*) from nomad_contentflow.blog_usage_snapshots where peak_active = 3$$, 1);
-- 확인 신호는 저장되지 않는다
select zz_check.expect($$select count(*) from nomad_contentflow.blogs where overage_ack$$, 0);
-- blog.* 감사 로그 위조 거부
select zz_check.denied($$insert into nomad_contentflow.audit_logs (organization_id, actor_id, action) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'blog.overage_ack')$$);
-- 검수자 지정은 owner가 가능
insert into nomad_contentflow.reviewers (organization_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5');
delete from nomad_contentflow.reviewers where user_id = '00000000-0000-0000-0000-0000000000a5';
-- site_checks: owner 가능
insert into nomad_contentflow.site_checks (organization_id, check_key, status, note) values ('00000000-0000-0000-0000-00000000000a', 'ad_status', 'unknown', null);
select zz_check.expect('select count(*) from nomad_contentflow.site_checks', 1);
reset role;

-- ==== 3. 역할별(조직 A): editor(u3) · viewer(u5) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values ('00000000-0000-0000-0000-00000000000a', 'Gamma', '00000000-0000-0000-0000-0000000000a3');
select zz_check.denied($$insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values ('00000000-0000-0000-0000-00000000000a', ' gamma ', '00000000-0000-0000-0000-0000000000a3')$$);
select zz_check.denied($$insert into nomad_contentflow.blogs (organization_id, platform, domain) values ('00000000-0000-0000-0000-00000000000a', 'naver', 'e.example.test')$$);
select zz_check.denied($$insert into nomad_contentflow.site_checks (organization_id, check_key, status, note) values ('00000000-0000-0000-0000-00000000000a', 'post_launch', 'pass', 'x')$$);
select zz_check.denied($$insert into nomad_contentflow.cost_entries (organization_id, category, amount, currency, occurred_on, created_by) values ('00000000-0000-0000-0000-00000000000a', 'other', 1, 'USD', '2026-01-01', '00000000-0000-0000-0000-0000000000a3')$$);
select zz_check.denied($$insert into nomad_contentflow.reviewers (organization_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a5')$$);
-- editor는 키워드의 블로그 지정 불가(owner/admin만)
select zz_check.fails_with($$update nomad_contentflow.keywords set blog_id = '00000000-0000-0000-0000-0000000000b1' where phrase = 'Gamma'$$, 'only owner or admin');
-- 소프트 삭제 후 같은 키 다시 등록 가능(부분 유니크), 되돌려 놓은 뒤 확인
update nomad_contentflow.keywords set deleted_at = now() where phrase = 'Gamma';
insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values ('00000000-0000-0000-0000-00000000000a', 'GAMMA', '00000000-0000-0000-0000-0000000000a3');
-- 글 만들기: 작성 단계에서 바로 입력 → 검수 요청
insert into nomad_contentflow.articles (id, organization_id, owner_id, state, title, body, source_url, brief_purpose, brief_audience)
  values ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a3', 'drafting',
    'Title', 'Body text', 'https://example.test/src', 'purpose', 'audience');
-- editor가 곧바로 승인 상태로 쓰기·승인 우회 거부
select zz_check.denied($$update nomad_contentflow.articles set state = 'approved' where id = '00000000-0000-0000-0000-0000000000c3'$$);
update nomad_contentflow.articles set state = 'approval_pending' where id = '00000000-0000-0000-0000-0000000000c3';
select zz_check.fails_with($$update nomad_contentflow.articles set evidence_status = 'ok', rights_status = 'ok' where id = '00000000-0000-0000-0000-0000000000c3'$$, 'only owner, admin or reviewer');
select zz_check.fails_with($$update nomad_contentflow.articles set state = 'approved' where id = '00000000-0000-0000-0000-0000000000c3'$$, 'only owner, admin or reviewer');
-- 승인 스냅샷·승인 행은 직접 위조 불가(editor는 approvals 권한 없음)
select zz_check.denied($$insert into nomad_contentflow.approvals (organization_id, article_version_id, reviewer_id, decision, snapshot_hash) values ('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), '00000000-0000-0000-0000-0000000000a3', 'approved', 'x')$$);
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_contentflow.articles', 2);
select zz_check.denied($$insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values ('00000000-0000-0000-0000-00000000000a', 'v', '00000000-0000-0000-0000-0000000000a5')$$);
select zz_check.denied($$insert into nomad_contentflow.agent_runs (organization_id, task, model, prompt_version, status, duration_ms, created_by) values ('00000000-0000-0000-0000-00000000000a', 'draft', 'm', 'v1', 'succeeded', 1, '00000000-0000-0000-0000-0000000000a5')$$);
update nomad_contentflow.articles set title = 'viewer edit' where organization_id = '00000000-0000-0000-0000-00000000000a';
select zz_check.expect($$select count(*) from nomad_contentflow.audit_logs$$, 0);
reset role;
select zz_check.expect($$select count(*) from nomad_contentflow.articles where title = 'viewer edit'$$, 0);

-- ==== 4. 검수자(u4, nomad_core 역할 viewer + reviewers 지정) ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a4","role":"authenticated"}', true);
insert into nomad_contentflow.agent_runs (organization_id, task, model, prompt_version, status, duration_ms, created_by)
  values ('00000000-0000-0000-0000-00000000000a', 'review', 'm', 'v1', 'succeeded', 1, '00000000-0000-0000-0000-0000000000a4');
-- 내용 수정 거부, 키워드 등 다른 쓰기 거부
select zz_check.fails_with($$update nomad_contentflow.articles set title = 'edit' where id = '00000000-0000-0000-0000-0000000000c3'$$, 'reviewers can only');
select zz_check.denied($$insert into nomad_contentflow.keywords (organization_id, phrase, created_by) values ('00000000-0000-0000-0000-00000000000a', 'rv', '00000000-0000-0000-0000-0000000000a4')$$);
-- 근거·권리 확인 후 승인 → 스냅샷+승인 생성
update nomad_contentflow.articles set evidence_status = 'ok', rights_status = 'ok' where id = '00000000-0000-0000-0000-0000000000c3';
update nomad_contentflow.articles set state = 'approved' where id = '00000000-0000-0000-0000-0000000000c3';
select zz_check.expect('select count(*) from nomad_contentflow.article_versions', 1);
select zz_check.expect('select count(*) from nomad_contentflow.approvals', 1);
select zz_check.expect('select count(*) from nomad_contentflow.article_state_events', 2);
select zz_check.denied($$update nomad_contentflow.article_versions set title = 'x'$$);
select zz_check.denied($$delete from nomad_contentflow.approvals$$);
reset role;
-- 서버 권한도 추가 전용 트리거는 우회 못 한다
select zz_check.denied($$update nomad_contentflow.approvals set snapshot_hash = 'x'$$);
select zz_check.denied($$delete from nomad_contentflow.audit_logs$$);

-- 조직 B는 A의 스냅샷·승인·이력·감사 로그를 못 본다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_contentflow.article_versions', 0);
select zz_check.expect('select count(*) from nomad_contentflow.approvals', 0);
select zz_check.expect('select count(*) from nomad_contentflow.article_state_events', 0);
select zz_check.expect('select count(*) from nomad_contentflow.agent_runs', 0);
select zz_check.expect('select count(*) from nomad_contentflow.audit_logs', 0);
select zz_check.expect('select count(*) from nomad_contentflow.blog_usage_snapshots where organization_id = ''00000000-0000-0000-0000-00000000000a''', 0);
reset role;

-- ==== 5. 동기화 컬럼 ====
select zz_check.expect($$select count(*) from pg_trigger where tgname in ('blogs_touch','keywords_touch','articles_touch') and not tgisinternal$$, 3);
insert into nomad_contentflow.keywords (organization_id, phrase, created_by, updated_at) values ('00000000-0000-0000-0000-00000000000a', 'sync', '00000000-0000-0000-0000-0000000000a1', '2000-01-01');
update nomad_contentflow.keywords set note = 'n' where phrase = 'sync';
select zz_check.expect($$select count(*) from nomad_contentflow.keywords where phrase = 'sync' and updated_at > '2001-01-01'$$, 1);
select zz_check.expect($$select count(*) from pg_indexes where schemaname = 'nomad_contentflow' and indexname in ('blogs_org_updated_idx','keywords_org_updated_idx','articles_org_updated_idx')$$, 3);

-- ==== 6. 익명·비노출 스키마 ====
set local role anon;
select zz_check.denied('select count(*) from nomad_contentflow.articles');
select zz_check.denied('select * from nomad_contentflow_private.rate_limits');
select zz_check.expect($$select (nomad_contentflow.rate_limit_hit('k1', 2, 60))::int + (nomad_contentflow.rate_limit_hit('k1', 2, 60))::int$$, 0);
select zz_check.expect($$select (nomad_contentflow.rate_limit_hit('k1', 2, 60))::int$$, 1);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.denied('select * from nomad_contentflow_private.rate_limits');
select zz_check.denied($$select nomad_core.org_plan_limit('00000000-0000-0000-0000-00000000000a', 'contentflow', 'max_blogs')$$);
reset role;

-- ==== 7. 발행 큐(0002): 조직 A editor만 큐에 넣고 가져가고 끝낸다, 조직 B는 아무것도 못 본다 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
update nomad_contentflow.articles set state = 'export_ready' where id = '00000000-0000-0000-0000-0000000000c3';
select zz_check.denied($$insert into nomad_contentflow.publish_jobs (organization_id, article_id, approved_version_id, remote_key, idempotency_key) select organization_id, article_id, id, 'site-a', 'x' from nomad_contentflow.article_versions$$);
select zz_check.expect($$select count(*) from nomad_contentflow.enqueue_publish_job('00000000-0000-0000-0000-0000000000c3', 'site-a') where not duplicate$$, 1);
select zz_check.expect($$select count(*) from nomad_contentflow.enqueue_publish_job('00000000-0000-0000-0000-0000000000c3', 'site-a') where duplicate$$, 1);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_contentflow.publish_jobs', 0);
select zz_check.fails_with($$select * from nomad_contentflow.enqueue_publish_job('00000000-0000-0000-0000-0000000000c3', 'site-a')$$, 'FORBIDDEN_ROLE');
select zz_check.expect($$select count(*) from nomad_contentflow.claim_publish_job('site-a')$$, 0);
select zz_check.fails_with($$select nomad_contentflow.cancel_publish_job((select id from nomad_contentflow.publish_jobs limit 1))$$, 'FORBIDDEN_ROLE');
reset role;
select zz_check.fails_with($$select nomad_contentflow.cancel_publish_job((select id from nomad_contentflow.publish_jobs limit 1))$$, 'FORBIDDEN_ROLE');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated"}', true);
select zz_check.fails_with($$select * from nomad_contentflow.enqueue_publish_job('00000000-0000-0000-0000-0000000000c3', 'site-a')$$, 'FORBIDDEN_ROLE');
-- u5는 개인 조직 owner라 호출은 되지만 조직 A 작업은 가져가지 못한다
select zz_check.expect($$select count(*) from nomad_contentflow.claim_publish_job('site-a')$$, 0);
select zz_check.expect('select count(*) from nomad_contentflow.publish_jobs', 1);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.expect($$select count(*) from nomad_contentflow.claim_publish_job('site-a')$$, 1);
select zz_check.expect($$select count(*) from nomad_contentflow.articles where id = '00000000-0000-0000-0000-0000000000c3' and state = 'publishing'$$, 1);
select zz_check.expect($$select count(*) from nomad_contentflow.claim_publish_job('site-a')$$, 0);
select zz_check.fails_with($$select nomad_contentflow.cancel_publish_job((select id from nomad_contentflow.publish_jobs limit 1))$$, 'JOB_RUNNING');
select zz_check.expect($$select count(*) from nomad_contentflow.publish_jobs j where nomad_contentflow.finish_publish_job(j.id, 'success') = 'draft_created'$$, 1);
select zz_check.expect($$select count(*) from nomad_contentflow.articles where id = '00000000-0000-0000-0000-0000000000c3' and state = 'draft_created'$$, 1);
reset role;

-- ==== 8. 분석 연결·자격·동기화(0002): owner/admin만, 조직 B 차단, 동기화 행 위조 거부 ====
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
select zz_check.expect($$select count(*) from nomad_contentflow.store_credential('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000d1', 'sub-1', 'client-1', 'cipher', 1) g where g = '00000000-0000-0000-0000-0000000000d1'$$, 1);
select zz_check.denied('select * from nomad_contentflow.analytics_credentials');
select zz_check.fails_with($$insert into nomad_contentflow.analytics_connections (organization_id, blog_id, grant_id, provider, external_ref, connected_by, status) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1', 'gsc', 'sc-domain:a', '00000000-0000-0000-0000-0000000000a1', 'active')$$, 'CONNECTION_STATE_FORBIDDEN');
insert into nomad_contentflow.analytics_connections (id, organization_id, blog_id, grant_id, provider, external_ref, connected_by)
  values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000d1', 'gsc', 'sc-domain:a', '00000000-0000-0000-0000-0000000000a1');
select zz_check.fails_with($$update nomad_contentflow.analytics_connections set status = 'active'$$, 'CONNECTION_STATE_FORBIDDEN');
select zz_check.expect($$select count(*) from nomad_contentflow.read_credential('00000000-0000-0000-0000-0000000000e1') where ciphertext = 'cipher'$$, 1);
select zz_check.expect($$select count(*) from nomad_contentflow.begin_sync_run('00000000-0000-0000-0000-0000000000e1', '2026-01-01', '2026-01-02')$$, 1);
select zz_check.fails_with($$select nomad_contentflow.begin_sync_run('00000000-0000-0000-0000-0000000000e1', '2026-01-01', '2026-01-02')$$, 'SYNC_RUNNING');
select zz_check.expect($$select nomad_contentflow.replace_synced_range('00000000-0000-0000-0000-0000000000e1', (select id from nomad_contentflow.analytics_sync_runs), '2026-01-01', '2026-01-02',
  '[{"metric":"clicks","scope":"site","dimension":"","value":3,"measured_on":"2026-01-01"},{"metric":"clicks","scope":"site","dimension":"","value":4,"measured_on":"2026-01-02"}]'::jsonb)$$, 2);
select zz_check.expect($$select count(*) from nomad_contentflow.blog_metric_snapshots where tool = 'gsc-api' and connection_id is not null$$, 2);
select zz_check.expect($$select count(*) from nomad_contentflow.analytics_connections where status = 'active'$$, 1);
select zz_check.fails_with($$insert into nomad_contentflow.blog_metric_snapshots (organization_id, blog_id, tool, metric, value, measured_on, created_by) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000b1', 'gsc-api', 'm', 1, '2026-01-03', '00000000-0000-0000-0000-0000000000a1')$$, 'SYNCED_ROW_FORBIDDEN');
select zz_check.fails_with($$insert into nomad_contentflow.revenue_rows (organization_id, row_key, source, status, currency, report_date, revenue, timezone, period_start, period_end, created_by) values ('00000000-0000-0000-0000-00000000000a', 'k9', 'adsense-api', 'estimated', 'USD', '2026-01-02', 1, 'UTC', '2026-01-01', '2026-01-31', '00000000-0000-0000-0000-0000000000a1')$$, 'SYNCED_ROW_FORBIDDEN');
select zz_check.fails_with($$select nomad_contentflow.delete_credential('00000000-0000-0000-0000-0000000000d1')$$, 'GRANT_IN_USE');
reset role;
-- editor·조직 B는 자격·연결 RPC 거부, B는 A의 연결·실행 기록을 못 본다
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a3","role":"authenticated"}', true);
select zz_check.fails_with($$select * from nomad_contentflow.read_credential('00000000-0000-0000-0000-0000000000e1')$$, 'ANALYTICS_FORBIDDEN');
select zz_check.denied($$insert into nomad_contentflow.analytics_connections (organization_id, grant_id, provider, external_ref, connected_by) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000d1', 'adsense', 'pub-1', '00000000-0000-0000-0000-0000000000a3')$$);
select zz_check.expect('select count(*) from nomad_contentflow.analytics_connections', 1);
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.expect('select count(*) from nomad_contentflow.analytics_connections', 0);
select zz_check.expect('select count(*) from nomad_contentflow.analytics_sync_runs', 0);
select zz_check.fails_with($$select * from nomad_contentflow.read_credential('00000000-0000-0000-0000-0000000000e1')$$, 'ANALYTICS_FORBIDDEN');
select zz_check.fails_with($$select * from nomad_contentflow.read_grant_credential('00000000-0000-0000-0000-0000000000d1')$$, 'ANALYTICS_FORBIDDEN');
select zz_check.fails_with($$select nomad_contentflow.disconnect_connection('00000000-0000-0000-0000-0000000000e1', true)$$, 'ANALYTICS_FORBIDDEN');
select zz_check.fails_with($$select nomad_contentflow.store_credential('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 's', 'c', 'x', 1)$$, 'ANALYTICS_FORBIDDEN');
-- B는 A의 연결을 자기 조직 행에 붙일 수 없다(복합 FK)
select zz_check.denied($$insert into nomad_contentflow.analytics_connections (organization_id, grant_id, provider, external_ref, connected_by) values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000d1', 'adsense', 'pub-2', '00000000-0000-0000-0000-0000000000a2')$$);
reset role;
-- 동의자(u1)가 owner를 잃으면 연결은 needs_reauth, 자격 읽기 거부
insert into nomad_core.memberships (organization_id, user_id, role) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'owner');
update nomad_core.memberships set role = 'editor' where organization_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';
select zz_check.expect($$select count(*) from nomad_contentflow.analytics_connections where status = 'needs_reauth'$$, 1);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
select zz_check.fails_with($$select * from nomad_contentflow.read_credential('00000000-0000-0000-0000-0000000000e1')$$, 'CONNECTION_NOT_ACTIVE');
select zz_check.fails_with($$select * from nomad_contentflow.read_grant_credential('00000000-0000-0000-0000-0000000000d1')$$, 'GRANT_OWNER_INACTIVE');
-- 끊기(삭제): 동기화 행과 연결이 사라지고, 남은 사용 연결 0
select zz_check.expect($$select nomad_contentflow.disconnect_connection('00000000-0000-0000-0000-0000000000e1', true)$$, 0);
select zz_check.expect($$select count(*) from nomad_contentflow.blog_metric_snapshots where tool = 'gsc-api'$$, 0);
reset role;
set local role anon;
select zz_check.denied($$select nomad_contentflow.claim_publish_job('site-a')$$);
select zz_check.denied('select count(*) from nomad_contentflow.analytics_connections');
reset role;

select 'check_org OK' as result;
rollback;
