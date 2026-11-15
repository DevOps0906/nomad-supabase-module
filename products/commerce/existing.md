# nomad-commerce 기존 DB → nomad_core 이식 대응표 (task-015 P3)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1400_commerce.sql`(스키마 `commerce`, 13표) · 문서 `products/nomad-commerce/`(Next.js 웹, 워커 `services/commerce-worker`, FastAPI AI, Capacitor 는 Phase 2).
이식: `org/0001_commerce.sql`(조직형만 — 원래 org 제품, 13표 = 원본 그대로, 주문 표 없음) · `org/0002_ai.sql`(AI·음성 라우팅 14행, core C5 직접 참조). 스키마 `nomad_commerce`(노출) · `nomad_commerce_private`(트리거 함수, 노출 안 함).
D9: platform-docs 기준으로 새로 작성. 청사진 `supabase/migrations/2026111{5,6,7}000107_commerce.sql`(sourcing_items·marketplace_accounts·listings·automation_jobs·orders)은 참고만 했고 **같은 스키마 이름이라 둘 중 하나만 적용**한다(대응: sourcing_items↔import_batches · marketplace_accounts↔market_accounts · listings↔listing_drafts·market_uploads · automation_jobs↔nomad_core.jobs · orders 는 원본에 없어 채택 안 함).
검증: `bash products/commerce/run_check.sh` (begin → 청사진 nomad_commerce drop → 0001·0002 → `check_org.sql` → rollback, 통과). 주요 게이트 3개를 일부러 빼면 검사가 실패하는 것도 확인했다(업로드 재시도 게이트·mark_job_delivered·소프트 삭제 now()).
사용처 약어: 웹=Next.js Route Handler·RSC(authenticated 세션), 서버=Route Handler(service_role), 워커=commerce-worker(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('commerce') | 대체: nomad_core.products | products('commerce') | 청사진이 이미 넣었으면 on conflict 무시 |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | — |
| core.is_org_member · has_org_role(member) | 대체: nomad_core.organization_role | 읽기 = 멤버, 쓰기 = owner/admin/editor(원본 member), 삭제·금지어 = owner/admin | viewer 는 읽기만 |
| core.has_entitlement(org,'commerce') | 대체 | 정책 nomad_core.has_feature(org,'commerce','commerce') · 트리거 org_has_feature | 기능 commerce 는 A·B·C 모두 → 구독이 없어도(C) 열림(원본 free) |
| commerce.commerce_features · commerce_limit | 대체 | org_has_feature(기능) · org_plan_limit(한도) | 삭제(서버는 core 함수 직접 호출) |
| core.is_privileged_session · is_service_caller | 대체: nomad_core.is_service_caller | stamp_creator · acknowledge RPC | — |
| core.guard_privileged_write(이중 잠금) | 삭제 | — | 서버 표에 authenticated 쓰기 grant·정책 0(검사 10절) |
| core.set_updated_at | 대체: nomad_core.touch_updated_at | — | — |
| core.jobs · credit_ledger(bigint) | 대체: nomad_core.jobs · credit_ledger(uuid) | job_id · credit_ledger_id(uuid) | 같은 조직·commerce 제품만(`check_core_refs`, CM010) |
| core.consume_credits · refund_credits · enqueue_job | 대체: nomad_core 서버 함수 | 키 `consume:commerce:<request_id>` · `job:commerce:<request_id>`(원본 04_API 1절) | DB 함수 없음, Route Handler·워커가 직접 호출(원본 그대로) |
| core.encrypted_credentials(app_id 'commerce') | 대체: nomad_core.provider_credentials | market_accounts.credential_id | 같은 조직·provider_code = market·미폐기(등록·재활성화·업로드 때마다 재확인, CM006) |
| core.revoke_credential | 대체: nomad_core.revoke_provider_credential | DELETE /api/market-accounts | 서버 호출 허용·재폐기 no-op(core 20261120000800) |
| core.write_audit | 대체: nomad_core.write_audit | 액션 `commerce.detail_page.compliance_warn_ack` | — |
| core.plans 4행 features · credit_packs 3행 | 대체: A/B/C + features + plan_limits 키 | 아래 표 | 가격·크레딧 수치 시드 안 함 |
| core.ai_routing_settings 14행 · 체인 검사 | 이관(0002) | nomad_core.ai_routing_settings(organization_id null, product_code 'commerce') | 20.2절 plans 병합 UPDATE 는 기능·plan_limits 로 대체 |
| (마켓 자격 제공자) | 신규 등록 | nomad_core.api_providers 8행(coupang·smartstore·gmarket·auction·street11·lotteon·cafe24·imweb) | 표시 이름만, on conflict 무시, 되돌릴 때 남겨도 무해 |

## 플랜·기능 (원본 pro→A, starter→B, free→C · enterprise 는 미판매)
| 기능 code | A | B | C | 원본 키 | DB 강제 위치 |
|---|---|---|---|---|---|
| commerce | O | O | O | (엔타이틀먼트) | 모든 정책·트리거 |
| zip_export | O | O | O | zip_export | export_files_gate |
| ai_chat | O | O | O | ai_chat | 없음(Route Handler) |
| market_api_coupang · market_api_smartstore | O | O | O | market_api 배열(모든 플랜 같은 2개) | market_uploads_gate(등록·재시도) |
| excel_export | O | O | — | excel_export | export_files_gate |
| slot_set_15 · extra_detail_types | O | O | — | slot_sets [10,15] · detail_types 3종 | detail_pages_gate(생성·failed→waiting 재시도) — **원본은 Route Handler, DB 강제 추가** |
| url_benchmark · voice_input · voice_chat · shorts_narration | O | O | — | 같은 이름 | 없음(Route Handler) |
- 다른 마켓(gmarket 등)은 원본 market_api 에 없어 기능 코드도 만들지 않았다 → 업로드 CM007. 열 때는 기능 `market_api_<market>` 을 추가한다(게이트는 이름 규칙으로 찾는다).
- 구독이 끊기면(구독 없음·만료·inactive = C) 원본 free 기능만 남는다: 읽기·상품 편집·ZIP·쿠팡/스마트스토어 업로드는 유지, 엑셀·15슬롯·확장 유형 잠김. 재구독 시 풀림(검사 9절).

## 구독이 끊긴 뒤 기존 행 경로 (검사 8·9절)
| 동작 | 필요 | 위치 |
|---|---|---|
| 실패한 15슬롯·확장 유형 상세페이지 재시도(failed→waiting) | slot_set_15 · extra_detail_types | detail_pages_gate |
| 실패·반려 업로드 재시도(failed/rejected→queued) | market_api_<market> + 계정 active + 자격 미폐기 | market_uploads_gate |
| 비활성 마켓 계정 재활성화 | market_slots 한도 | market_accounts_enforce |
| 삭제 상품 복원 | products 한도 | products_enforce_quota |
| 엑셀 내보내기(새 행만, 재시도 전이 없음) | excel_export | export_files_gate |
- 한도는 내려간 플랜(C) 값으로 계산한다. 이미 넘친 상품·계정은 그대로 두고 새로 늘리는 것만 막는다(원본 그대로).

## plan_limits 키 (수치 시드 안 함, 괄호 = 키가 없을 때 코드 기본값 = 원본 4.4절 "없을 때", products 만 원본 free 값)
| limit_key (product `commerce`) | 원본 free / starter / pro / enterprise | DB 사용 |
|---|---|---|
| products | 30 / 300 / 2000 / 10000 | products_enforce_quota (30 = 원본 free 값, 팀장 결정 — 원본 코드 기본값은 0) |
| market_slots | 1 / 3 / 10 / 30 | market_accounts_enforce (1) |
| concurrency | 1 / 1 / 2 / 5 | 없음(디스패처, 1) |
| ai_chat_turns_per_day | 20 / 200 / 200 / 500 | 없음(Route Handler, 20) |
| image_quality_level | draft / standard / pro / ultra → 0 / 1 / 2 / 3 | 없음(워커 모델 선택, 0) |
| monthly·signup credits | 15·30 / 150 / 350 / 900 | core 크레딧 지급 정책 |
| 가격 · credit_packs(pack_50·120·200) | 0 / 29000 / 69000 / 149000, 팩 10000·23900·39900 | INTEGRATION 결제 계약(subscriptions · addon), 이식 안 함 |
- 무제한 = 2147483647(원본 -1 은 쓰지 않는다 — plan_limits 는 0 이상만).

## 테이블 (commerce → nomad_commerce, 13개, 이름 유지)
| 원래 이름 | 분류 | 사용처 | 쓰기 경로 | 소유 컬럼 |
|---|---|---|---|---|
| import_batches | 이관 | 웹 읽기 · 워커 | service_role (completed 때 잡 전달 검사) | org_id → organization_id |
| products | 이관 | 웹 | owner/admin/editor 컬럼 GRANT + 한도·소프트 삭제 트리거 | 〃 |
| detail_pages · detail_page_slots · market_images | 이관 | 웹 읽기(Realtime) · 워커 | service_role · acknowledge_compliance_warning | 〃 |
| market_accounts | 이관(credential_id → provider_credentials) | 웹 읽기 · 서버 | service_role | 〃 |
| shipping_templates · listing_drafts | 이관 | 웹 | owner/admin/editor 컬럼 GRANT | 〃 |
| market_uploads · export_files | 이관 | 웹 읽기(Realtime) · 워커 | service_role + 게이트(업로드는 상세페이지 필수·대상 고정, 멱등 키 조직 범위) | 〃 |
| banned_words | 이관(기본 사전 21행 시드 유지 — 문자열) | 웹 · compliance 모듈 | 조직 행 owner/admin | organization_id(null = 제품 기본) |
| exchange_rates · market_categories | 이관(전역 캐시) | 웹 읽기 · 워커 | service_role | 없음 |
| (청사진 orders) | 채택 안 함(D9) | — | — | — |
| Storage | 없음 | — | 원본 1400 에 버킷 생성 없음(이미지·엑셀은 코어 공용 버킷 계약 — 이 저장소에 아직 없음) | — |
- 동기화: 모든 사용자 표에 updated_at + touch 트리거. deleted_at 은 products 만(원본). 오프라인 캐시는 local-storage.md.
- anon(D8): 공개 경로 없음 → 스키마 usage·함수 실행·표 권한 0(검사 1·10절). rate limit 은 원본대로 Route Handler 의 `nomad_core.rate_limit_hit('commerce:<route>:<org>', …)`.

## 함수 (이름 유지)
| 원래 이름 | 실행 | 사용처 | 변화 |
|---|---|---|---|
| acknowledge_compliance_warning | authenticated(owner/admin/editor)·service | 웹 | member → editor, 반환 = detail_pages 행(전 컬럼 SELECT 허용 표) |
| commerce_transition_allowed · commerce_status_guard · commerce_stamp_creator | 트리거(private) | — | 이름 transition_allowed·status_guard·stamp_creator |
| products_enforce_quota · market_accounts_enforce · market_uploads_gate · export_files_gate | 트리거(private) | — | 한도 = org_plan_limit, 기능 = org_has_feature. 업로드 게이트는 재시도(→queued)에도, 자격 미폐기 재확인. 내보내기는 대상 상품·페이지 같은 조직(CM010) |
| (신규) detail_pages_gate | 트리거 | — | 위 "플랜·기능" |
| (신규) check_core_refs | 트리거 | — | 잡·원장 같은 조직·제품(CM010) |
| (신규) guard_job_delivery | 트리거 | — | 아래 "잡 결과 전달" |
| (신규) force_deleted_at | 트리거 | — | 소프트 삭제 시각 now() 강제(과거·미래 값 무시, 재삭제는 처음 시각 유지) |
| (신규) market_uploads_target_immutable · reset_warn_ack · banned_words_floor | 트리거 | — | 아래 "보안 리뷰 반영" |
| commerce_features · commerce_limit | 삭제 | — | 서버는 nomad_core.org_has_feature · org_plan_limit |

## 잡 결과 전달 (원본과 다른 점)
- 원본은 워커가 service_role 로 상태만 바꿨다. 이식본은 `detail_pages → ready`·`import_batches → completed` 때 트리거가 잡 행을 잠그고, 잡이 failed·canceled(= core 가 이미 환불)면 **55000 으로 저장을 거부**하고, 아니면 `nomad_core.mark_job_delivered(job_id)`를 불러 이후 잡 실패 환불을 막는다(검사 7절). 제품 함수의 core 표 직접 쓰기 0, core 표에 트리거 0(검사 10절).
- 일부 슬롯 실패 부분 환불(원본 02_ARCHITECTURE 4장)은 워커가 `nomad_core.refund_credits(원장, 사유, 키, 금액)`로 명시 호출(원본 그대로).
- 상세페이지 취소: waiting = 서버 refund_credits, queued = nomad_core.cancel_job(자동 환불). 취소·환불된 페이지는 상태 전이상 ready 로 갈 수 없다.

## 결제 연동 계약 (D1 — 결제 테이블 없음)
- commerce 의 결제는 월 구독(starter·pro → B·A)과 크레딧팩뿐이라 제품 주문 표가 필요 없다. 원본 `/api/billing/*`(payment_orders·billing_keys·webhook_events·confirm_payment_order)는 INTEGRATION 계약으로 대체: 구독 = 외부 결제 서버가 `nomad_core.subscriptions`(plan A/B, status·ends_at)를, 팩 = addon 구매(`addon_purchases` paid → 크레딧 지급, 멱등 키)를 쓴다.
- 환불: 구독 환불 → 구독 inactive(= C, 유료 기능 즉시 잠김). 팩 환불 → 크레딧 회수는 core addon·INTEGRATION 계약 몫(이 저장소 제품 쪽 처리 없음, 미검증). 제품 쪽에 되돌릴 혜택 행이 없다.

## 앱 변경 (이식 후 웹·워커가 바꿀 것)
- `.schema('commerce')` → `.schema('nomad_commerce')`, `org_id` → `organization_id`, 역할 `member` → `editor`, `core.entitled_plan_code`+features → `nomad_core.dashboard_features`·`org_has_feature`·`org_plan_limit`.
- 마켓 계정 등록: `encrypted_credentials` vault put → core 자격 set 함수(provider_code = market) 후 market_accounts.credential_id. 삭제는 `revoke_provider_credential` + status disabled.
- 워커: ready·completed 로 바꾸는 update 가 55000 이면 결과를 버리고 실패 처리(이미 환불됨). 상세페이지 credit_ledger_id 는 uuid.
- 한도 수치를 운영자가 plan_limits 에 넣기 전에는 모든 플랜이 상품 30개·계정 1개(코드 기본값) — 배포 전 A·B products·market_slots 값을 넣는다.

## 설치 경로
- 청사진(`supabase/migrations/*_commerce.sql`)은 이 저장소 로컬 실습용이다. 다른 저장소 설치(번들)는 core(`nomad_core*`)만 supabase/migrations 에서, 제품은 **`products/commerce`** 에서 가져오므로 같은 스키마 이름이 실제로 충돌하지 않는다. 이 저장소 로컬 DB 에서만 run_check 가 청사진 스키마를 트랜잭션 안에서 지우고 검사한다.

## 보안 리뷰 반영 (2026-11-14, ACCEPT 🟡·❓ — 검사 3·8·9·11절, 각 항목은 해당 코드를 빼면 검사가 실패함을 확인)
| 항목 | 위치 | 동작 |
|---|---|---|
| 슬롯 수 ≤ 세트 | detail_pages CHECK `detail_pages_slots_within_set` | 10세트에 15·18슬롯, 15세트에 18슬롯 = 23514 |
| 세트·유형·슬롯 변경 재검사 | detail_pages_gate(트리거 컬럼 status·slot_set·page_type·slots) | 상태와 무관하게 바뀌면 플랜 재검사(CM007) |
| 업로드 대상 고정 | market_uploads_target_immutable | 등록 뒤 market·market_account_id·detail_page_id 변경 CM011(FK set null 만 허용 → 재시도 게이트가 거부) |
| 상세페이지 없는 업로드 거부 | market_uploads_gate | detail_page_id null = CM008(compliance 생략 금지, 팀장 결정). 원본은 null 이면 판정을 건너뛰었다 |
| 전달 가드 판정 | guard_job_delivery | "환불됨" = 잡 failed·canceled **이고** refund_on_failure. 전달 뒤 실패한 잡은 archived→ready 복원 허용 |
| 멱등 키 조직 범위 | 유니크 인덱스 (organization_id, request_id) · (organization_id, idempotency_key) | 원본 전역 unique 대체. 다른 조직의 같은 키는 허용 |
| 기본 FAIL 단어 낮추기 금지 | banned_words_floor | 조직 행 단어가 활성 기본 FAIL 단어와 같으면 severity fail·is_active true 강제(카테고리 무관) |
| WARN 확인 초기화 | reset_warn_ack | compliance_verdict·compliance_issues 가 바뀌면 warn_acknowledged_at·by = null |

## 결정 기록 (2026-11-14 팀장)
- 승인: 플랜 대응 pro→A·starter→B·free→C(enterprise·api_access 없음) · detail_pages_gate DB 강제 추가 · source_price numeric(외화) 유지.
- products 한도 키가 없을 때 상수 기본 30(원본 free 값, docs 방식, 시드 없음). 검사 2절: 30개 성공·31번째 CM002.
- 청사진과 스키마 이름 공유는 위 "설치 경로"로 해소.

## 팀장 확인 필요
1. (기록만) 상품 이미지·엑셀·ZIP 저장 위치(코어 공용 버킷 계약)가 이 저장소에 없다(arch 3번과 같은 요청).
2. 청사진이 이 저장소 로컬 DB 에 넣은 nomad_core 행(features sourcing·marketplace_listing·commerce_automation, 플랜 이름 무료·프로·비즈니스)은 남는다 — 로컬 실습용이라 무해.
