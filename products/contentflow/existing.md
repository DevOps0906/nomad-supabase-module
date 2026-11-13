# ContentFlow-AI-V2.0 기존 DB → nomad_core 기반 org안 대응표

원본: `ContentFlow-AI-V2.0/supabase/migrations/0001~0019`(public, 전부 읽음) · 앱 코드의 `.from()`/`.rpc()` 전수 grep(apps/web/src). 변환본: `org/0001_contentflow.sql`(스키마 `nomad_contentflow` 노출, `nomad_contentflow_private` 비노출). 조직형 전용이라 user안은 없다.
소유 컬럼 공통 변화: `workspace_id` → `organization_id`(→ `nomad_core.organizations`). 복합 FK `(organization_id, id)` 유지.

## 테이블
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org 변화 |
|---|---|---|---|---|
| workspaces | 대체: nomad_core.organizations | — (owner_id→organizations.created_by, plan→subscriptions/plan_limits) | web `/api/workspaces`, lib/supabase.ts | 자체 테이블 삭제. 생성은 `nomad_core.create_team_organization` |
| memberships | 대체: nomad_core.memberships | — | web `/api/workspaces`·`/active`, lib/supabase.ts | role은 owner/admin/editor/viewer만. reviewer는 아래 reviewers |
| (신규) | 이관(보강) | reviewers | web 승인·검수 화면 | 조직 멤버 중 검수자 지정(owner/admin만) |
| invitations | 대체: nomad_core.invitations | — | web `/api/team`(select) | token 방식, role은 admin/editor/viewer |
| blogs | 이관 | blogs (+updated_at·deleted_at) | web `/api/blogs`, lib/blogs-db.ts | workspace_id→organization_id |
| sources | 이관 | sources | 서버(승인 스냅샷 source_id) | 동일 |
| articles | 이관 | articles (+deleted_at, 0002~0014 컬럼 최종형) | web `/api/articles*`·`/ai/review`·`/wordpress/draft` | workspace_id→organization_id. owner_id(작성 user)는 유지 |
| article_versions | 이관 | article_versions | web(승인), article_delivery_check | 동일 |
| approvals | 이관 | approvals | 서버(트리거) | 동일 |
| audit_logs | 이관 | audit_logs | 트리거 | 동일. member.* 이벤트는 core RPC가 기록하지 않음 |
| keywords | 이관 | keywords (+updated_at·deleted_at) | web `/api/keywords*` | 동일. 중복 키는 소프트 삭제 제외 부분 유니크 |
| revenue_rows | 이관 | revenue_rows | web `/api/revenue` | 동일. 통화별 소수 금액이라 정수(원) 규칙 예외 |
| rate_limits | 이관(비노출) | nomad_contentflow_private.rate_limits | RPC rate_limit_hit만 | 소유 없음(전역 키) |
| agent_runs | 이관(크레딧 아님) | agent_runs | web `/api/costs`, lib/agent-runs.ts | 동일 |
| article_state_events | 이관 | article_state_events | web `/api/articles/[id]/history` | 동일 |
| delivery_attempts | 이관 | delivery_attempts | web `/api/articles/[id]/history`, lib/delivery.ts | 동일 |
| site_checks | 이관 | site_checks | web `/api/site-checks` | 동일 |
| cost_entries | 이관 | cost_entries | web `/api/costs` | 동일 |
| improvement_tasks | 이관 | improvement_tasks | web `/api/improvements` | assignee FK → nomad_core.memberships |
| keyword_trends | 이관 | keyword_trends | web `/api/trends` | 동일 |
| blog_metric_snapshots | 이관 | blog_metric_snapshots | web `/api/blog-metrics` | 동일 |
| workspace_entitlements | 대체: nomad_core.plan_limits | — | web `/api/blogs/usage` | 키 `included_blogs`·`max_blogs`·`overage_allowed`(0/1), product `contentflow`. 수치 시드 없음. grace_until·grace_active_cap은 삭제(이전 시 운영자 판단) |
| blog_usage_snapshots | 이관(사용량) | blog_usage_snapshots | web `/api/blogs/usage` | 동일. 트리거만 기록 |
| (함수) plan_defaults() | 삭제 | — | — | plan_limits로 대체 |

## 함수 · 트리거 · RPC
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| is_member(ws, roles) | 대체 | nomad_core.organization_role · nomad_contentflow.has_role(+include_reviewer) | RLS 전반 | 역할은 텍스트 배열 |
| my_role(ws) | 대체 | nomad_core.organization_role | 서버 내부 | — |
| add_owner_membership 트리거 | 삭제 | create_team_organization이 owner 멤버십 생성 | — | — |
| invite_member | 대체 | nomad_core.create_invitation | web `/api/team/invite` | (target_organization, invitee_email, invitee_role) → token |
| accept_invitation(inv) | 대체 | nomad_core.accept_invitation(invite_token) | web `/api/team/invitations/[id]/accept` | id 대신 token |
| delete_invitation | 대체(일부) | nomad_core.revoke_invitation(owner/admin만) | web `/api/team/invitations/[id]` | 초대받은 사람의 거절은 core에 없음 |
| my_invitations · decline_invitation | 대체:nomad_core | public.nomad_my_invitations · nomad_decline_invitation | web `/api/invitations` | core 20261119000300 추가 |
| change_member_role · remove_member | 대체:nomad_core | public.nomad_change_member_role · nomad_remove_member | web `/api/team/members/[userId]` | core 20261119000300 추가(마지막 owner 보호) |
| workspace_members(ws) | 이관 | nomad_contentflow.workspace_members(ws) | web `/api/team`·`/improvements`·`/site-checks` | 반환 user_id,email,role,is_reviewer (created_at 제거) |
| rate_limit_hit | 이관 | nomad_contentflow.rate_limit_hit | web lib/server.ts | anon 실행 허용, private 표 사용 |
| article_delivery_check | 이관 | nomad_contentflow.article_delivery_check | web lib/delivery.ts | invoker 유지(RLS가 글 범위 결정) |
| enforce_article_rules 외 글 규칙·해시 함수 | 이관 | 같은 이름, nomad_contentflow | 트리거 | reviewer = has_role(include_reviewer) |
| enforce_blog_limits · meter_blog_* · assert_blog_active | 이관 | 같은 이름 | 트리거 | 한도는 org_plan_limit(contentflow, 키). 정의 없으면 클라이언트 생성 거부 |
| enforce_plan_lock · sync_workspace_entitlements | 삭제 | — | — | 플랜은 core subscriptions가 관리 |
| cf_norm_key · cf_caller_is_client | 이관 | cf_norm_key · nomad_contentflow_private.caller_is_client | 트리거·생성 컬럼 | — |
| stamp_* · enforce_*_cap · record_article_transition 등 | 이관 | 같은 이름 | 트리거 | 상한 5000/20000/20000/30000은 상수 유지(plan_limits 아님) |

## 버킷 · 기타
- Storage 버킷 없음(config.toml은 주석 예시뿐) → `0002_storage.sql`·`app/*.sql` 없음.
- 레포 `supabase/tests/rls.sql`은 원본 public 스키마 기준이라 손대지 않음. 새 검사는 `check_org.sql`.
- 앱 변경 필요(레포 미수정, 참고): `nomad_contentflow` 스키마 노출·`db.schema` 지정, `workspaces`/`memberships` 조회를 `nomad_core.my_organizations()`로, 키워드 upsert 충돌 대상이 부분 유니크(`deleted_at is null`)라 PostgREST on_conflict 대신 조회 후 insert/update.

## 팀장 확인 필요
1. reviewer 역할이 nomad_core에 없음 → 제품 표 reviewers로 보강함(core에 역할 추가 vs 현행 유지).
2. (해결) core 20261119000300에 my_invitations·decline_invitation·change_member_role·remove_member 추가.
3. plan_limits 키 3종과 플랜 A/B/C 수치 매핑은 운영자가 정함.
