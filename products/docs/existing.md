# nomad-docs 기존 DB → nomad_core 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2300_docs.sql`(스키마 `docs`, 3203줄, 표 31개) · 문서 `products/nomad-docs/`(Next.js 웹 = 로그인 후 워크스페이스, ai-service 워커, 앱 없음).
이식: `org/0001_docs.sql`(조직형만 — 원래 org 제품, 원본 0~25절) · `org/0002_ai.sql`(원본 26절 라우팅 시드 13행 + 체인 검사, core C5 표 사용). 스키마 `nomad_docs`(노출). 비노출 스키마 없음(core 공용 사용).
검증: `bash products/docs/run_check.sh` (begin → 청사진 drop → 임시 touch_updated_at → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js Server Action·Route Handler(authenticated 세션), 서버=Route Handler(service_role), 워커=ai-service·sweeper(service_role).
본문은 원본과 같다(기계 변환 + 아래 표의 차이만). 원본 원칙 유지: 숫자(금액·번호·합계)는 DB 계산, 문서 버전 append-only, 상태·번호 컬럼은 컬럼 GRANT + 2차 잠금 트리거 + RPC.

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('docs') | 대체: nomad_core.products | products('docs') | signup_policy open → 별도 없음 |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | p_org_id 인자도 p_organization_id |
| core.org_members(role member) · is_org_member · has_org_role | 대체: nomad_core.organization_role | `organization_role(x) is not null` / `coalesce(role,'') in (...)` | member → editor. viewer 는 읽기만 |
| core.current_org_ids() + has_entitlement (카탈로그 정책) | 대체 | nomad_docs.caller_has_docs() (definer, 불리언) | docs 기능이 있는 조직의 멤버면 카탈로그 읽기 |
| core.has_entitlement(org,'docs') | 대체 | 정책 nomad_core.has_feature(org,'docs','docs') · RPC org_has_feature | RPC 는 서버 호출도 받으므로 멤버십 없는 org_has_feature + 역할 검사 |
| core.is_privileged_session (2차 잠금 트리거) | 대체 | nomad_docs.is_privileged() | 원본은 current_user 기준(definer 안 = 통과). core 판정은 session_user 기준이라 사용자 definer RPC(finalize 등)가 막히므로 원본 의미로 보존 |
| core.is_privileged_session (서버 전용 RPC 진입) | 대체 | nomad_core.is_service_caller() | start/finish/fail_generation·apply_checklist_effects·report_progress·charge_daily_cap·reserve_credits·upsert_external_ref. next_doc_number 만 is_privileged(finalize 안에서 호출) |
| core.guard_privileged_write 트리거 | 삭제 | — | authenticated·anon 쓰기 GRANT 가 없어 서버·RPC 만 쓴다(floria 와 같음) |
| core.set_updated_at | 대체 | nomad_core.touch_updated_at | — |
| core.write_audit | 대체 | nomad_core.write_audit | 서명 같음 |
| core.jobs · enqueue_job · cancel_job | 대체 | nomad_core.jobs · enqueue_job(이름 인자) · cancel_job | queue 'docs.generate', 멱등 키 job:docs:<id> |
| core.consume_credits(org, n, app, reason, ref_type, ref_id, key, metadata, actor) | 대체 | nomad_core.consume_credits(org, n, reason, key, 'docs', ref_type, ref_id) | metadata·actor 인자 없음(ref 로 대체) |
| core.credit_ledger(id) bigint | 대체 | nomad_core.credit_ledger(id) uuid | generation_runs·doc_exports.credit_ledger_id, reserve_credits 반환형 bigint → **uuid** |
| core.ai_runs · ai_documents | 대체 | nomad_core.ai_runs · ai_documents | FK 유지 |
| core.encrypted_credentials · revoke_credential | 대체 | nomad_core.provider_credentials · revoke_provider_credential | 아래 "자격증명" 절 |
| core.personal_org_id() | 대체 | memberships ⨝ organizations(kind='personal') | ack_risk_notice 기본 조직 |
| core.allow_purge 설정 | 대체 | nomad_docs.allow_purge | document_versions 삭제 허용(조직 purge) |
| docs.org_features(plans.features jsonb) | 대체 | nomad_docs.plan_limit_int → nomad_core.org_plan_limit | 키 없으면 원본 Free 기본값 |
| core.plans 3행 · credit_packs 3행 | 대체: A/B/C + features + plan_limits 키 | 아래 표 | 가격·크레딧 수치 시드 안 함 |
| core.ai_routing_settings 13행 · 체인 검사 | 이관(0002) | nomad_core.ai_routing_settings(organization_id null, product_code 'docs') | scope_uniq 로 upsert |

## 플랜·기능 (원본 team→A, pro→B, free→C)
| 기능 code | A | B | C | 원본 근거 | DB 강제 위치 |
|---|---|---|---|---|---|
| docs | O | O | O | 모든 플랜(free 포함) | 모든 정책·RPC(has_feature/org_has_feature) |
| export_docx | O | O | — | formats docx·zip | enforce_plan_features(doc_exports format docx·zip·hwpx) |
| no_watermark | O | O | — | watermark false | 같음(watermark=false) |
| phase2_docs | O | — | — | doc_phase phase2 | start_generation(DC006). phase3 유형은 대응 플랜 없음 → 열지 않음 |
| webhooks | O | O | — | integrations webhook | webhook_endpoints insert |
| crm_integrations | O | — | — | integrations hubspot·admin_suite_erp·n8n | integration_connections insert(provider ≠ csv) |
| approvals | O | — | — | approvals | approval_steps insert |
| share_links | O | — | — | share_links | DB 표 없음(앱 몫) |
- 구독이 끊기면(구독 없음·만료·inactive = C 취급) 유료 기능만 잠기고 무료 `docs`는 남는다(원본에 free 플랜이 있으므로). 검증: `check_org.sql` 9절(3가지 끊김 각각, 재구독 시 풀림).
- 원본 enforcement 는 앱 몫이었으나 기능 잠금 검사를 위해 서버 쓰기 6개 표(doc_exports·webhook_endpoints·webhook_deliveries·integration_connections·sync_runs·approval_steps)에 `enforce_plan_features` 트리거를 **추가**했다(DC006).

## plan_limits 키 (수치 시드 안 함, 괄호 = 키가 없을 때 코드 기본값)
| 원본 features 키 | limit_key (product `docs`) | free / pro / team 원본 값 | DB 사용 |
|---|---|---|---|
| projects_max | projects_max | 2 / 50 / 300 | enforce_project_limit (2). 무제한 = 2147483647 |
| members_max | members_max | 1 / 1 / 5 | 없음(초대 경로는 core) |
| ai_chat_turns_per_day | ai_chat_turns_per_day | 30 / 200 / 500 | 없음(앱) |
| minutes_max_minutes | minutes_max_minutes | 30 / 120 / 180 | 없음(앱) |
| storage_mb | storage_mb | 200 / 5000 / 20000 | 없음(앱) |
| monthly_credits · signup_credits | (core 크레딧 지급 정책) | 30·50 / 400·0 / 1500·0 | core grant_plan_credits 몫 |
| 가격 price_krw · credit_packs | (INTEGRATION 결제 계약, addon) | 0 / 19900 / 59000, 팩 4900·12900·39000 | 이식 안 함 |

## 테이블 (docs → nomad_docs, 31개, 이름 유지)
| 원래 이름 | 분류 | 사용처 | 쓰기 경로 | 소유 컬럼 |
|---|---|---|---|---|
| doc_types · doc_type_versions · checklist_items · checklist_item_versions | 이관(플랫폼 카탈로그) | 웹 읽기 · 운영자 | service_role | 없음(공통) |
| clauses | 이관 | 웹 읽기(published) | service_role | organization_id(null = 플랫폼) |
| runtime_config · daily_credit_usage | 이관(사용자 접근 0, runtime_config 시드 없음) | 서버 | service_role · charge_daily_cap | 없음 |
| workspace_settings | 이관 | 웹 | owner/admin 컬럼 GRANT | organization_id(PK) |
| parties · projects · checklist_answers · requirements · artifacts · line_items | 이관(정본) | 웹 | owner/admin/editor 컬럼 GRANT + 2차 잠금 | organization_id |
| project_code_counters · doc_counters | 이관 | 트리거·finalize | next_project_code·next_doc_number | project_id / organization_id |
| uploads · documents · document_versions · trace_links · generation_runs · doc_exports | 이관 | 웹 읽기 · 서버·워커 | service_role · RPC (documents.title 만 editor) | organization_id |
| risk_acknowledgements · approval_steps · signature_requests | 이관 | 웹 | ack_risk_notice · decide_approval · service_role | organization_id |
| integration_connections · field_mappings · external_refs · sync_runs · webhook_endpoints · webhook_deliveries | 이관 | 웹(owner/admin) · 서버 | service_role · field_mappings 만 owner/admin | organization_id |
| 뷰 project_totals · project_pipeline · project_activity | 이관(security_invoker) | 웹 | — | — |
| Realtime | 이관 | 웹 진행률 | supabase_realtime 에 generation_runs·doc_exports·documents | — |
| Storage 버킷(exports·seal·uploads) | 없음 | — | 원본 2300 에 버킷 생성 없음(경로 규칙만 CHECK) | — |
- 동기화: 원본 updated_at + touch 트리거 유지. `deleted_at` 은 parties·projects 만(원본). 오프라인 캐시는 local-storage.md.
- anon(D8): 공개 경로 없음 — anon 은 nomad_docs 스키마 usage 없음·함수 실행 0·표 권한 0(check 10절). rate_limit_take 불필요.

## 함수 (이름 유지)
| 원래 이름 | 실행 | 사용처 | 변화 |
|---|---|---|---|
| finalize_document · archive_document · create_revision · set_project_status · ack_risk_notice · revoke_integration | authenticated(owner/admin)·service | 웹 | 역할 owner/admin, 기능 org_has_feature |
| confirm_checklist_suggestions · decide_approval · cancel_generation | authenticated(editor 이상·승인자·요청자)·service | 웹 | member → editor |
| next_project_code | authenticated(트리거 경유만) | 트리거 | — |
| start_generation · finish_generation · fail_generation · report_generation_progress · reconcile_generation_runs | service_role | 서버·워커 | consume/enqueue 서명 변환, doc_phase → phase2_docs, finish 는 core mark_job_delivered(잡 실패·취소면 저장 거부) |
| reserve_credits | service_role | 서버 | 반환 uuid, 멱등 비교는 core consume_credits |
| apply_checklist_effects · checklist_answers_hash · next_doc_number · upsert_external_ref · charge_daily_cap | service_role | 서버 | — |
| is_privileged · caller_has_docs · enforce_plan_features · plan_limit_int | 이식 추가 | 트리거·정책 | 위 표 |
| 트리거 함수(…_immutable·…_transition·…_before_write·guard_*·mark_documents_stale·validate_checklist_answer 등) | 트리거 | — | 같음 |

## 운영 수치 (시드 안 함 — 운영자가 runtime_config 에 넣는다)
| key | 원본 제안값 | 키가 없을 때(코드 상수) | 사용처 |
|---|---|---|---|
| max_active_generations_per_org | 3 | 3 (원본 coalesce 기본값) | start_generation, 조직당 동시 생성 DC006 |
| daily_credit_cap | 20000 | 상한 없음 (원본 코드 그대로) | charge_daily_cap, 플랫폼 일일 크레딧 DC006 |

## 생성 잡 환불 (원본과 다른 점)
- 원본 finish_generation 은 `core.jobs.refund_on_failure`를 직접 껐다(결과를 넘긴 뒤 잡이 실패해도 환불하지 않기, 교차검증 #4). 이식본은 core 전용 함수 `nomad_core.mark_job_delivered(job_id)`(core 20261120000800, API 역할 실행 권한 0 — definer 제품 함수만)를 부른다. 제품 함수 본문에 core jobs·credit_ledger 직접 쓰기 0(검사 10절).
- 잡이 이미 failed·canceled(= 환불됨)면 finish_generation 은 결과 저장을 거부한다(DC001, 검사 7절).

## 구독이 끊긴 뒤 기존 유료 행 (검사 9절)
| 동작 | 필요 기능 | 위치 |
|---|---|---|
| 웹훅 발송 기록(webhook_deliveries 삽입) | webhooks | enforce_plan_features 트리거 |
| 동기화 실행(sync_runs 삽입, csv 외 연결) | crm_integrations | 같음(연결 provider 조회) |
| 연결 재활성화(→ active, csv 외) | crm_integrations | 같음(integration_connections update of status) |
| upsert_external_ref(csv 외 연결) | crm_integrations | 함수 안 org_has_feature |
| decide_approval | approvals | 함수 안 org_has_feature |
| create_revision(phase2 유형) | phase2_docs | 함수 안(phase3 은 대응 플랜 없어 거부) |

## 자격증명 (core 요청 해소)
- 원본 `core.encrypted_credentials`(OAuth 토큰·웹훅 서명 비밀)는 `nomad_core.provider_credentials`(provider_code FK)로 연결한다. revoke_integration 은 사용자·서버 호출 모두 `nomad_core.revoke_provider_credential`로 회수한다(core 20261120000800: 서버 허용·재폐기 no-op, 검사 9-0절).
- 연동 제공자 코드 6개(hubspot·salesforce·ecount·douzone·n8n·admin_suite_erp)는 0001 에서 `nomad_core.api_providers`에 on conflict do nothing 으로 등록한다(표시 이름만, stock 과 같은 방식, 되돌릴 때 남겨도 무해). 검사 9-0절은 hubspot 자격증명을 실제 연결에 붙여 회수한다.

## 결정 기록 (2026-11-14 팀장 승인)
- 플랜 대응 team→A·pro→B·free→C, 기능 8개 이름, `enforce_plan_features` 트리거 추가(원본은 앱 강제).
- 2차 잠금 판정 `nomad_docs.is_privileged()`(current_user 기준) 유지.
- 원본 metadata(project_id 등)는 크레딧 원장에 남기지 않는다(core consume_credits 에 인자 없음) — ref_type/ref_id 만.
- 카탈로그(문서 종류·버전·체크리스트·조항 골격, 비수치 설정) 시드는 0001 에 유지. runtime_config 수치는 시드 안 함(위 표).

## 팀장 확인 필요
- 없음(2026-11-14 후속 지시 모두 반영).
