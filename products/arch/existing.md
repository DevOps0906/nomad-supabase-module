# arch-studio 기존 DB → nomad_core 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2400_arch.sql`(스키마 `arch`, 15표) · 문서 `products/arch-studio/`(Tauri 데스크톱 + 로컬 SQLite, Next.js 웹 계정·API, 워커 `workers/arch-jobs`, FastAPI AI).
이식: `org/0001_arch.sql`(조직형만 — 원래 org 제품, 16표 = 원본 15 + D1 주문표 1) · `org/0002_ai.sql`(AI 라우팅 14행, 코어 C5 직접 참조). 스키마 `nomad_arch`(노출) · `nomad_arch_private`(내부, 노출 안 함).
검증: `bash products/arch/run_check.sh` (begin → 청사진 drop → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 데스크톱=Tauri 앱(supabase-js RLS 읽기·Route Handler 호출), 웹=Next.js 계정 화면(authenticated), 서버=Route Handler(service_role), 워커=arch-jobs(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('arch') | 대체: nomad_core.products | products('arch') | — |
| core.organizations · org_id · personal_org_id | 대체: nomad_core.organizations(kind personal) | organization_id | p_org null = 호출자 개인 조직(`caller_org`) |
| core.org_members(member) · is_org_member · has_org_role | 대체: nomad_core.memberships · organization_role | owner/admin/editor(원본 member) | 행위자 검사 `nomad_arch_private.actor_can_write` |
| core.app_entitlements · has_entitlement · has_arch_access | 대체: nomad_core.org_has_feature(org,'arch','workspace') 또는 활성 영구 라이선스 | `nomad_arch.has_access` · `has_arch_access` | 구독도 라이선스도 없으면 잠김 |
| core.plans(trial·sub_monthly·updates_yearly features jsonb) | 대체: A/B/C + features + plan_limits | 아래 표 | 수치 시드 안 함 |
| core.payment_orders · plans(updates_yearly price) | **D1: 이식 안 함** → 제품 표 `license_orders` | 아래 "결제 연동 계약" | 결제 수단·키·웹훅은 외부 결제 서버 |
| core.credit_packs(pack_100·550·1200) | 대체: core addon(운영자 설정) | — | 시드 안 함 |
| core.consume_credits · refund_credits · grant_credits · credit_ledger(bigint) | 대체: nomad_core.consume_credits · refund_credits · grant_credits · credit_ledger(uuid) | 멱등 키 `arch:consume:<request_id>` · `arch:refund:<run_id>` · `arch:license:<license_id>` | 서버 전용 |
| core.enqueue_job · jobs | 대체: nomad_core.enqueue_job · jobs | 키 `arch:job:<request_id>`, 큐 = job_type | 원본 finish_ai_run 의 `core.jobs.refund_on_failure` 직접 수정은 제거(아래 앱 변경) |
| core.write_audit | 대체: nomad_core.write_audit | 액션 `arch.*` | — |
| core.is_privileged_session · is_service_caller | 대체: nomad_core.is_service_caller | — | — |
| core.guard_privileged_write(이중 잠금) · set_updated_at | 삭제 · 대체 touch_updated_at | — | 사용자 쓰기 grant·정책이 하나도 없다 |
| core.storage_org_id | 대체: nomad_arch_private.storage_org_id | — | — |
| core.ai_routing_settings 시드 | 대체: nomad_core.ai_routing_settings | org/0002_ai.sql | 14행 + 체인 검사 |

## 테이블 (arch → nomad_arch, 16개)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| runtime_config | 이관(시드 제거) | nomad_arch.runtime_config | 서버 | 없음(플랫폼) |
| license_skus | 이관(시드 제거, anon grant 제거) | nomad_arch.license_skus | 웹 가격 화면 = `public_license_skus()` RPC | 없음 |
| builds | 이관 | nomad_arch.builds | 서버(업데이트 매니페스트) | 없음 |
| rule_packs | 이관(storage_path 숨김) | nomad_arch.rule_packs | 데스크톱 읽기 · eligible_rule_packs | 없음 |
| rule_pack_changes | 이관 | nomad_arch.rule_pack_changes | 데스크톱(폴백 배너) | 없음 |
| cost_catalogs | 이관 | nomad_arch.cost_catalogs | latest_cost_catalog | 없음 |
| (core.payment_orders) | **신규(D1)** | nomad_arch.license_orders | 서버 쓰기, 웹 읽기(멤버) | organization_id |
| licenses | 이관(order_id → license_orders) | nomad_arch.licenses | 웹 계정 화면 읽기 · 서버 | org_id → organization_id |
| license_activations | 이관(device_hash 숨김) | nomad_arch.license_activations | 웹 읽기 · deactivate_activation | 〃 |
| drafting_profiles | 이관 | nomad_arch.drafting_profiles | 데스크톱 읽기 · upsert_drafting_profile | org_id(PK) → organization_id |
| cloud_projects | 이관 | nomad_arch.cloud_projects | 데스크톱 · save_cloud_project | 〃 |
| renders · reviews · intake_runs · proposals | 이관(쓰기 서버) | nomad_arch.* | 서버·워커 쓰기, 데스크톱 읽기 | 〃 |
| site_lookups | 이관(사용자 접근 없음) | nomad_arch.site_lookups | record_site_lookup | 〃 |
| 버킷 arch-releases · arch-user | 이관(비공개, 정책 없음) | 같은 이름 | 서버 서명 URL | 경로 `<organization_id>/arch/<purpose>/…` |
| 코어 버킷 org-files(렌더) · exports(PDF) · voice-audio(상담 녹음) | **코어 계약** | — | 워커 | 이 저장소 core 에 아직 없음 — 팀장 확인 |
| 로컬 SQLite(B 분류: 프로젝트·판정·시트·license_store 등) | 범위 밖(데스크톱) | — | 데스크톱 | local-storage.md |
- 동기화 대상(클라우드 → 데스크톱 캐시): drafting_profiles · cloud_projects — `updated_at` + touch 트리거 + `(organization_id, updated_at)` 인덱스. 실행 기록·라이선스는 읽기 캐시(소프트 삭제 없음, 원본 그대로).

## 함수 (arch → nomad_arch, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| has_arch_access · feature_int · feature_bool · kst_today · valid_user_path | 이관 | nomad_arch.* | 정책·데스크톱 | — |
| config_int · caller_org · new_serial_body | 이관(내부) | nomad_arch_private.* | RPC 내부 | caller_org: 개인 조직 = organizations.kind 'personal' |
| org_features | 이관 | nomad_arch.org_features | 데스크톱·서버 | 같은 jsonb 모양. 상태 licensed / subscribed(A) / licensed_fallback / trial(B, trial_ends_at = 구독 ends_at) / *_expired |
| reconcile_runs | 이관(서버) | nomad_arch.reconcile_runs | 워커 크론 | — |
| enforce_* · after_license_status | 이관(트리거) | nomad_arch_private.* | 트리거 | + enforce_order_transition(신규) |
| (신규) create_license_order · mark_license_order | 신규(서버, D1) | nomad_arch.* | 서버(결제 전·후) | 아래 계약 |
| issue_license · extend_updates | 이관(서버) | nomad_arch.* | 서버 | 인자 = license_orders.id(원본 payment_orders.id). paid 주문만 |
| activate_license · activate_plan_device · eligible_build · record_site_lookup | 이관(서버) | nomad_arch.* | 서버 | — |
| start_ai_run · finish_ai_run · fail_ai_run · purge_expired | 이관(서버) | nomad_arch.* | 서버·워커 | 상태 *_expired 면 start 거부(42501). finish 는 core.jobs 를 건드리지 않는다 |
| deactivate_activation · eligible_rule_packs · latest_cost_catalog · upsert_drafting_profile · save_cloud_project | 이관(authenticated) | nomad_arch.* | 웹·데스크톱 | 원본 member → editor. 표제란 저장은 접근(has_access) 필요 |
| (신규) public_license_skus | 신규(anon·authenticated) | nomad_arch.public_license_skus | 웹 가격 화면 | D8: 표 직접 grant 대신 공개 definer RPC. 입력 없음(검증 불필요), 요청 제한은 앞단 CDN·Route Handler 캐시(예: 60초) |

## 플랜 대응 (수치 시드 안 함)
| 기능(nomad_core.features) | A(월 구독) | B(체험) | C | 원본 키 |
|---|---|---|---|---|
| workspace | ✓ | ✓ | — | (엔타이틀먼트) |
| cloud_review · rule_pack_updates · ai_render · ai_intake | ✓ | ✓ | — | 같은 이름(trial·sub_monthly true) |
| local_gpu_render · ai_layout · drafting_no_watermark | ✓ | — | — | 같은 이름 · drafting_watermark false |
- 영구 라이선스 + 업데이트 유효(licensed) = 플랜 A 의 기능·한도(원본 updates_yearly 와 같은 불리언). 폴백 = 상품 `fallback_features`(제품 표, 운영자 입력).
- B(체험)는 서버가 가입 때 `subscriptions(plan B, ends_at = now()+14일)`로 만든다(원본 trial_days). 만료 후 C = 잠김(원본 trial_expired "열람·내보내기만" = 로컬 앱).

| limit_key (product `arch`) | 원본 trial / sub_monthly / updates_yearly | 키가 없을 때 |
|---|---|---|
| render_max_px | 1024 / 4096 / 4096 | 1024 |
| site_lookups_per_day | 10 / 30 / 30 | 10 |
| ai_chat_turns_per_day | 20 / 200 / 200 | 20 |
| cloud_projects_max | 3 / 100 / 100 | 3 |
| max_activations(플랜 기기) | 1 / 1 / 2 | 1 |
- runtime_config 키(시드 없음, 운영자가 넣는다 — 없으면 start_ai_run 은 "no price"로 거부): `price.render_std` 3 · `price.render_hq` 5 · `price.upscale` 2 · `price.review` 15 · `price.intake_text` 2 · `price.intake_consult` 5 · `price.proposal` 10 · `price.doc_template` 1 · `price_krw.updates_yearly` 290000(**신규**, 원본 plans.price_krw) · `render_max_active_per_org` 3 · `render_retention_days` 90 · `self_deactivations_per_30d` 3 · `daily_credit_cap` 200000 · `site_lookup_retention_days` 90. (`trial_days` 는 구독 ends_at 으로 대체.)
- license_skus(시드 없음): perpetual_early 490,000원(보너스 300, 100개 한정) · perpetual_standard 890,000원(보너스 300).

## 결제 연동 계약 (D1 — 결제 테이블 없음)
1. 구매 시작(서버): `create_license_order(org, actor, 'license'|'updates_extension', sku|null, idempotency_key)` → 금액(정수 원)은 DB 가 정한다(상품 가격 / `price_krw.updates_yearly`). 같은 키 재호출 = 같은 주문, 다른 요청 = 거부. 행위자는 owner/admin.
2. 외부 결제 서버가 `license_orders.id`·`amount_krw` 로 결제창을 연다(주문 id = 결제 서버의 orderId). 이 저장소는 결제 키·카드 정보를 저장하지 않는다.
3. 결제 확정 웹훅 처리(서버, 서명 검증은 결제 서버 쪽): `mark_license_order(order, 'paid', <결제 서버 결제 id>, <확정 금액>)` — 금액 불일치면 거부, 같은 상태 재호출은 무해(웹훅 재전송). 이어서 `issue_license(order)`(시리얼 원문은 첫 반환만, 화면·메일로 한 번 전달) 또는 `extend_updates(order)`.
4. 취소(결제 전) `mark_license_order(order, 'canceled')`, 환불(결제 후) `mark_license_order(order, 'refunded')`:
   - license 주문 → 라이선스 refunded → 활성 기기 자동 해제 + 보너스 크레딧 회수(팀장 결정: 남은 잔액 한도 안에서 consume, 멱등 키 `arch:bonus_clawback:<order>`).
   - updates_extension 주문 → extend_updates 효과 되돌림(updates_until −1년, extension_order_ids 에서 제거).
5. 월 구독(A)·체험(B)은 코어 `subscriptions` 로만 관리(INTEGRATION 기능 이용권 계약).

## 앱 변경 (이식 후 웹·데스크톱·워커가 바꿀 것)
- `.schema('arch')` → `.schema('nomad_arch')`, `org_id` → `organization_id`, 역할 `member` → `editor`. 가격 화면은 `license_skus` 직접 조회 대신 `rpc('public_license_skus')`.
- 결제: core payment_orders·Toss 웹훅 코드 → 위 계약(create/mark_license_order). `issue_license`·`extend_updates` 인자는 license_orders.id.
- 워커 계약: 성공 = `finish_ai_run`(잡 행을 잠그고 failed·canceled 면 55000 거부, 저장 뒤 `nomad_core.mark_job_delivered`로 이후 잡 실패 환불 차단) → `nomad_core.complete_job`. 실패 = `nomad_core.fail_job` 이 **최종 실패**(재시도 없음)일 때만 `fail_ai_run`(잡이 queued·running 이면 55000 거부, 남은 금액만 환불 — 잡 환불이 끝났으면 0).
- 한도 수치가 시드되기 전에는 모든 상태가 "키가 없을 때" 값(1024px·3사본 등)으로 동작 → 운영자가 plan_limits A·B 값을 넣어야 한다. 무제한 = 2147483647.

## 팀장 확인 필요
1. D1 해석: 결제 테이블 대신 제품 표 `license_orders`(상태·금액 정수·멱등 키) 1개를 추가해 16표가 됐다. 주문 없이 계약만(issue_license 가 외부 주문 id·금액을 인자로 받는 방식)을 원하면 표를 뺄 수 있다.
2. 플랜 대응: A = 월 구독, B = 체험(14일 ends_at), C = 기능 없음(잠김). "원본 무료 플랜 기능만 C" 규칙에서 arch 원본에는 영구 무료 플랜이 없고 체험은 기간 한정이라 C 를 비웠다.
3. 코어 공용 버킷 org-files·exports·voice-audio 계약(렌더 결과·PDF·상담 녹음) 이 저장소에 없음.
4. (해결) 라이선스 환불 보너스 회수 = 잔액 한도 consume. 연장 환불의 −1년 되돌림은 만료 후 연장(오늘+1년)이었던 경우 근사값.
5. `drafting_profiles.default_text_height_mm numeric(3,1)`은 금액이 아니라 길이(mm)라 그대로 뒀다.
