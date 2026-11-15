# admin-suite SMS(학교) 기존 DB → nomad_core 이식 대응표 (task-015 P1)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1700_sms.sql`(스키마 `sms`) · 문서 `products/admin-suite/`(Next.js 16 웹, 워커 없음, AI는 Dify·FastAPI).
결정 D11: registry `isolated`→`org`(학교 = 조직). slug `school`. 이식: `org/0001_school.sql` · `org/0002_ai.sql`(**core 웨이브 후 적용**, AI 표 없으면 라우팅 시드 건너뜀).
스키마 `nomad_school`(노출) · `nomad_school_private`(내부, 노출 안 함). 검증: `bash products/school/run_check.sh`(통과, rollback).
사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('sms', signup_policy invite) | 대체: nomad_core.products | products('school') | 초대제는 nomad_core 초대 + invite_school_member |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members | 대체: nomad_core.memberships | admin = owner/admin(파생) · teacher/student = members.school_role(코어 역할 viewer) | — |
| core.has_entitlement | 대체: nomad_core.has_feature('school', 'school') | nomad_school.has_access | 기능 school(A·B·C) · export_xlsx(A·B) |
| core.is_service_caller | 대체 | nomad_school_private.caller_is_client | — |
| core.plans(default/standard features) | 대체: A/B/C + plan_limits 키 | 아래 표 | 수치 시드 안 함, 정의 없으면 클라이언트 거부(fail-closed) |
| core.ai_routing_settings 시드 · ai-docs 버킷 · AI 기능 | **core 웨이브 후 적용** | org/0002_ai.sql | 기능 ai_assistant(A·B·C)·ai_voice·ai_wiki(A·B), 버킷 `school-ai-docs` |

## 테이블 (sms → nomad_school)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| workspaces | 이관 | nomad_school.workspaces | 웹 읽기 · 서버 register_workspace | org_id → organization_id(PK) |
| classes | 이관(+deleted_at) | nomad_school.classes | 웹 CRUD(admin) | org_id → organization_id |
| subjects | 이관(+deleted_at) | nomad_school.subjects | 웹 CRUD(admin) | org_id → organization_id |
| members(sms_role) | 이관(school_role, 쓰기 RPC만) | nomad_school.members | 웹 읽기·RPC | (org_id,user_id) → (organization_id,user_id) |
| attendance | 이관(쓰기 RPC만, Realtime) | nomad_school.attendance | 웹 | org_id → organization_id |
- 동기화 대상: classes·subjects·members·attendance·workspaces — `updated_at` + touch 트리거 + `(organization_id, updated_at)` 인덱스. 소프트 삭제는 classes·subjects(`deleted_at`, 이름 유니크는 삭제 안 된 행만). RLS는 삭제 행도 보여 준다(동기화 삭제 전파용) — 화면은 `deleted_at is null`로 거른다.

## 함수 (sms → nomad_school, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| has_access · is_admin · is_staff · my_role | 이관 | nomad_school.* | 정책·웹 | 코어 역할 + workspaces.status 기반 |
| register_workspace | 이관(service_role) | nomad_school.register_workspace | 서버 | — |
| update_workspace_settings | 이관 | nomad_school.* | 웹(admin) | — |
| invite_school_member | 이관 | nomad_school.invite_school_member | 웹(admin) | 대상이 nomad_core 초대를 **먼저 수락**한 멤버여야 함 |
| accept_school_invite | 대체: nomad_core.accept_invitation | (만들지 않음) | 웹 | 수락 후 관리자가 invite_school_member로 학교 역할 부여 |
| set_member_role · assign_class · set_member_status | 이관 | nomad_school.* | 웹(admin) | 자기 자신 변경 금지 |
| mark_attendance · mark_attendance_bulk | 이관 | nomad_school.* | 웹(admin·teacher) | teacher 소급 = workspaces.teacher_backfill_days |
| dashboard_stats · attendance_trend · student_summary | 이관 | nomad_school.* | 웹 | trend 기간 = plan_limits |
| members_guard_transition | 삭제(쓰기 grant 없음 + RPC로 대체) | — | — | — |
| (신규) enforce_class_limit · enforce_student_limit | 신규(트리거) | nomad_school_private.* | 트리거 | plan_limits 한도 |

## plan_limits 키 (수치 시드 안 함 — 원본 값은 참고)
| 원본 features 키 | limit_key (product `school`) | 원본 default / standard |
|---|---|---|
| max_students | max_students | 100 / 1500 |
| max_classes | max_classes | 5 / 60 |
| attendance_trend_days | attendance_trend_days | 31 / 366 |
| export_xlsx(불리언) | 기능 `export_xlsx`(A·B) | false / true |
| (0002) AI 한도 | ai_turns_per_day · ai_turns_per_month · ai_commercial_turns_per_month · ai_docs_max | 원본 AI 값 참고 |

## 팀장 확인 필요
1. max_students·max_classes 정의가 없으면 클라이언트 생성이 막힌다(fail-closed) — 코어 시드가 먼저 필요.
2. 학생 데이터(미성년자) AI 접근은 MVP 제외 유지. 3. 0002 라우팅 열 이름은 task-014 결과에 맞춰 수정 필요.
