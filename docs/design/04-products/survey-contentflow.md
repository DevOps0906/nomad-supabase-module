# ContentFlow-AI-V2.0 기존 DB 조사 (2026-11-13, scout)

| 앱 | 구성 | DB 접근 | 로컬 저장소 |
|---|---|---|---|
| apps/web | Next.js 16, API route 약 50개 | 계정 모드 Supabase(anon + RLS), 로컬 모드 localStorage | articles·keywords·revenue·settings 키 |
| apps/mobile | Capacitor + Vite(Android) | 직접 없음, web API 경유 | secureStore(토큰) |
| apps/desktop | Tauri + web sidecar | sidecar 경유 | 미확인 |
| packages/shell-bridge | 세션·저장 추상화 | — | 메모리 |

| 마이그레이션(public, 0001~0019) | 테이블 | 소유 | RLS |
|---|---|---|---|
| 0001 | workspaces(owner_id) · memberships · blogs · sources · articles · article_versions · approvals · audit_logs | workspace_id | 예(is_member) |
| 0003·0004·0005 | keywords · invitations · revenue_rows | workspace_id | 예 |
| 0006 | rate_limits | 미확인 | 예, 정책 없음(함수 전용) |
| 0007·0008 | agent_runs · article_state_events · delivery_attempts | workspace_id | 예 |
| 0011·0012 | site_checks · cost_entries · improvement_tasks | workspace_id | 예 |
| 0016·0017 | keyword_trends · blog_metric_snapshots | workspace_id | 예 |
| 0019 | workspace_entitlements · blog_usage_snapshots · plan_defaults() · enforce_plan_lock 트리거 | workspace_id | 예 |

- 인증: Supabase 이메일, 자체 `/api/auth/*`(login·signup·reset·token refresh/revoke)로 감쌈. persistSession=false.
- **조직형**: workspaces = nomad_core.organizations, memberships(+invitations, RPC invite_member 등) = nomad_core.memberships, workspaces.plan·workspace_entitlements = plans·subscriptions·plan_limits(included_blogs) 대응. 구독·결제·크레딧 없음.
- nomad_core 참조 없음. 이 저장소의 contentflow 스키마(supabase/migrations/*_contentflow.sql)는 별도 설계라 대조 필요.
- 미확인: 0002·0009·0010·0013·0014·0015·0018 정의, 0006 소유 컬럼, supabase/tests/rls.sql 결과.
