# admin-suite ERP 기존 DB → nomad_core 이식 대응표 (task-015 P1)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1600_erp.sql`(스키마 `erp`) · 문서 `products/admin-suite/`(Next.js 16 웹, 워커 없음, AI는 Dify·FastAPI).
이식: `org/0001_erp.sql`(조직형만 — 원래 org 제품) · `org/0002_ai.sql`(**core 웨이브 후 적용**). 스키마 `nomad_erp`(노출) · `nomad_erp_private`(내부, 노출 안 함).
검증: `bash products/erp/run_check.sh` (begin → 청사진 drop → 임시 touch_updated_at → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler·Server Action(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('erp', signup_policy approval) | 대체: nomad_core.products | products('erp') | 승인제 가입은 제품 표 join_requests + join_codes로 유지 |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members(role member) | 대체: nomad_core.memberships | owner/admin = master_admin(파생) · 나머지 editor/viewer | ERP 역할은 employees.erp_role |
| core.has_org_role | 대체: nomad_core.organization_role | nomad_erp.has_access / has_role / my_role | 정책 도우미(definer) |
| core.invite_member | 대체: nomad_core.create_invitation | decide_join_request 안에서 호출 | staff→viewer, 관리자급→editor |
| core.write_audit · audit_log | 이관(제품 표) | nomad_erp.audit_logs + nomad_erp_private.write_audit | core audit 웨이브 후 교체 검토 |
| core.plans(default/standard features) | 대체: A/B/C + plan_limits 키 | 아래 표 | 수치 시드 안 함 |
| core.ai_routing_settings 시드 · ai-docs 버킷 | **core 웨이브 후 적용** | org/0002_ai.sql | AI 표가 없으면 notice만 |

## 테이블 (erp → nomad_erp)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| workspaces | 이관 | nomad_erp.workspaces | 웹 읽기 · 서버 register_workspace | org_id → organization_id(PK) |
| join_codes | 이관(사용자 접근 없음) | nomad_erp.join_codes | get/rotate_join_code RPC | org_id → organization_id |
| departments | 이관 | nomad_erp.departments | 웹 CRUD(master_admin) | org_id → organization_id |
| employees | 이관(쓰기 RPC만) | nomad_erp.employees | 웹 읽기·RPC | (org_id,user_id) → (organization_id,user_id) |
| join_requests | 이관 | nomad_erp.join_requests | 웹(신청자·master_admin) | org_id → organization_id |
| products | 이관(+deleted_at 소프트 삭제) | nomad_erp.products | 웹 CRUD(quantity는 RPC만) | org_id → organization_id |
| inventory_moves | 이관(append-only) | nomad_erp.inventory_moves | 웹 읽기·RPC | org_id → organization_id |
| sales | 이관 | nomad_erp.sales | 웹 읽기·RPC | org_id → organization_id |
| (core audit_log) | 신규(제품 표) | nomad_erp.audit_logs | 웹 읽기(master_admin) | organization_id |
| 버킷 product-images | 이관 | `erp-product-images`(비공개) | 웹 업로드·조회 | 경로 `<organization_id>/erp/product/<uuid>` |
| 버킷 ai-docs | 이관(**core 웨이브 후**) | `ai-docs`(0002, service_role만) | 서버·FastAPI | — |
- 동기화 대상: workspaces·departments·employees·join_requests·products·sales — `updated_at` + `nomad_core.touch_updated_at()` 트리거 + `(organization_id, updated_at)` 인덱스(products·departments). 소프트 삭제는 products만(`deleted_at`), 나머지는 상태 컬럼(status)으로 비활성.

## 함수 (erp → nomad_erp, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| has_access · has_role · my_role | 이관 | nomad_erp.* | 정책·웹 | 코어 역할 기반으로 재작성 |
| new_join_code | 이관(내부) | nomad_erp_private.new_join_code | RPC 내부 | — |
| register_workspace | 이관(service_role) | nomad_erp.register_workspace | 서버 | 인자 org_id → p_organization_id |
| get_join_code · rotate_join_code · update_workspace_settings | 이관 | nomad_erp.* | 웹(master_admin) | — |
| request_join · cancel_join_request · decide_join_request | 이관 | nomad_erp.* | 웹 | 승인 시 nomad_core.create_invitation, max_members 한도 ER004 |
| set_employee_role · set_employee_status · update_employee_profile · update_my_contact | 이관 | nomad_erp.* | 웹 | 자기 자신 변경 금지 |
| record_inventory_move · record_sale · complete_sale · cancel_sale | 이관(멱등 request_id) | nomad_erp.* | 웹 | 금액은 원본대로 numeric(12,2) — 아래 확인 필요 |
| dashboard_metrics · sales_trend | 이관 | nomad_erp.* | 웹 | sales_trend 기간 상한 = plan_limits |
| inventory_moves_immutable · guard_product_columns · sales_guard_transition · join_requests_guard_transition | 이관(트리거) | nomad_erp.* | 트리거 | — |
| (신규) caller_is_client · write_audit | 신규(내부) | nomad_erp_private.* | RPC 내부 | — |

## plan_limits 키 (수치 시드 안 함 — 원본 값은 참고)
| 원본 features 키 | limit_key (product `erp`) | 원본 default / standard |
|---|---|---|
| max_members | max_members | 5 / 50 |
| storage_mb | storage_mb | 500 / 10240 (DB에서 강제하지 않음, 서버 검사) |
| sales_trend_days | sales_trend_days | 31 / 366 (없으면 366) |
| export_xlsx(불리언) | — (features로 옮기지 않음, 앱 기능 플래그) | false / true |

## 팀장 확인 필요
1. 금액이 원본대로 `numeric(12,2)`(원 단위, 소수 2자리) — 절대 규칙 "금액은 정수(원)"과 다름. bigint 변경 여부.
2. `export_xlsx`를 nomad_core.features로 둘지(현재 미시드). 3. 0002의 공용 `ai-docs` 버킷 이름(school은 `school-ai-docs`) 통일.
