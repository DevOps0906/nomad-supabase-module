# platform-docs 통합 DB → nomad_core 이식 대응표 (task-009, 2026-11-13 초안)

- 원본(읽기 전용): `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\` 코어 `0000~0009`(파일 10개, 테이블 41개) + 제품 조각 17개(`1000~2600`). hms는 모듈러에 없고 `admin-suite/supabase/monolith/hms/`에만 있다.
- 사용자 결정(2026-11-13): **nomad_core가 정본**(저쪽 `core`는 설계 근거로만 씀) · 병원(hms)만 격리형 · 학교(sms)는 조직형 · 이미 있는 flora·sceneflow·commerce는 차이만 표시.
- 수치 근거: 테이블 수 = 조각 파일의 `create table` 문 수. 코어 의존 = 조각 SQL의 `core.*` 참조 유무(앱 코드 의존은 미확인).
- 이쪽 현행 정본: [core-schema](../01-architecture/core-schema.md) · [billing-credits](../01-architecture/billing-credits.md) · [feature-catalog](../01-architecture/feature-catalog.md) · `blueprints/registry.yaml`.

## 1. 코어 대조표 (저쪽 `core` 41개 → nomad_core)

판정: 대응(같은 역할, 이식 불필요) · 충돌(같은 역할, 모델이 다름 → 이쪽 유지·필요한 컬럼만 추가) · 없음(새로 이식할지 결정).

| 원본 파일 | 저쪽 테이블 | nomad_core | 판정 | 이식 |
|---|---|---|---|---|
| 0000 | (확장 pgcrypto·pg_cron, 스키마) | 확장은 `extensions` 사용 중 | 대응 | pg_cron은 수량 한도·월 지급 잡이 필요할 때 |
| 0001 | `profiles` | `profiles` | 충돌: 저쪽 `platform_role`·`status`(승인제) ↔ 이쪽 `platform_admins` 별도 | 안 함. 승인제(`status=pending`)는 결정 필요 |
| 0001 | `organizations` | `organizations` | 충돌: `is_personal`↔`kind`, `owner_id`↔owner 멤버십, 저쪽만 `slug`·`settings`·`deleted_at` | 필요 시 컬럼 추가(news 화이트라벨이 `slug`·`settings` 요구, 미확인) |
| 0001 | `org_members` | `memberships` | 충돌: 역할 `member`↔`editor`, 저쪽만 `status` | 안 함. 제품 이식 때 `member`→`editor`로 치환 |
| 0002 | `apps` | `products` | 대응(저쪽만 `signup_policy`·`status`) | `signup_policy='invite'`(stock 초대제)는 결정 필요 |
| 0002 | `plans` | `plans`·`features`·`plan_features` | 충돌: 저쪽 자유 code + `price_krw`·`monthly_credits`·`features jsonb` ↔ 이쪽 A/B/C 고정 + 정규화 기능 | 안 함. 수량 키는 3장(task-006) |
| 0002 | `credit_packs` | 없음(`addon_products`는 기능 이용권) | 없음 | 결정 필요(크레딧 구매를 addon으로 볼지) |
| 0002 | `billing_keys`·`payment_orders`·`payments`·`webhook_events` | 없음(`addon_purchases`=외부 영수증만) | 없음 | 결정 필요: 결제 서버를 이 저장소 범위에 넣을지. 계약은 [INTEGRATION](../../INTEGRATION.md#결제-연결-계약) |
| 0002 | `subscriptions` | `subscriptions` | 충돌: 상태 5종(trialing·past_due 등)·청구 주기 ↔ 이쪽 active·inactive | 상태 확장은 결제 범위 결정 후 |
| 0002 | `app_entitlements` | `subscriptions`+`feature_grants`+`has_feature()` | 대응 | 안 함 |
| 0003 | `wallets` | 없음(잔액 = `sum(delta)`) | 없음 | 안 함 권장(원장 합 + 같은 트랜잭션 잠금). 버킷 분리 시 재검토 |
| 0003 | `credit_ledger` | `credit_ledger` | 충돌: 저쪽 plan/pack 버킷·`entry_type`·`refund_of`·`ref_type/ref_id`·`balance_after` ↔ 이쪽 `delta`·`reason`·멱등 키 | **부분 이식**: `ref_type/ref_id`(작업 연결)·환불 연결. 버킷은 결정 필요 |
| 0003 | `ai_usage` | 없음 | 없음 | AI 계층과 함께(C5) |
| 0004 | `audit_log` | 없음 | 없음 | **이식**: erp·sms·docs 감사 요구 |
| 0004 | `oauth_states`·`encrypted_credentials` | 없음 | 없음 | **이식**: 외부 계정 연동 7개 제품(2장 표 "자격") |
| 0004 | `rate_limit_buckets` | 없음 | 없음 | **이식**: 3장 시간 창 한도 |
| 0005 | `jobs` | 없음(제품별 `edit_jobs`·`render_jobs`·`automation_jobs`·`pipeline_runs`) | 없음 | **이식**: 11개 제품이 참조, 실패 시 자동 환불 계약 |
| 0006 | `affiliate_accounts`·`_links`·`_clicks`·`_disclosures`·`brandconnect_applications` | 없음 | 없음 | 이식: blog(contentflow)·video만 사용 |
| 0007 | (함수 EXECUTE 회수, 테이블 없음) | AGENTS.md 4장 규칙과 같은 원칙 | 대응 | 안 함 |
| 0008 | `ai_*` 11개·`wiki_*` 3개 (pgvector, `ai_runtime` 스키마) | 없음(knowflow `chunks`는 제품 내) | 없음 | 결정 필요: 17개 조각 모두 AI 시드를 넣음. 코어 이식 or 제품 시드 분리 |
| 0009 | `voice_sessions`·`voice_jobs` | 없음 | 없음 | 이식 보류: SQL 참조는 microweb만 |

## 2. 제품 대응표 (16개, admin-suite는 3개로 분리 = 18행)

형태: org=조직 소유(`organization_id`) · user=1인 조직 구독 전제 + 소유자 컬럼 · isolated=별도 프로젝트. slug는 이쪽 스키마 `nomad_<slug>` 기준 **제안**.
코어 의존 약어: J=jobs · Cr=credits · Af=affiliate · AI=ai 시드 · V=voice · Cd=자격(oauth·encrypted_credentials) · anon=anon grant 수.

| 저쪽 제품 (스키마·번호) | slug 제안 | 형태 | 테이블 | 코어 의존(SQL) | 기존 대응 |
|---|---|---|---|---|---|
| flora-publishing (`publishing` 1000) | `flora` | org | 13 | J·Cr·AI·Cd | **flora**(6) — 2.1 |
| astro-ai (`astro` 1100) | `astro` (또는 `personal` 흡수) | user 제안 | 7 | J·Cr·AI | personal(사주·꿈해몽·여행) 부분 겹침 |
| sceneflow (`video` 1200) | `sceneflow` | org | 36 | J·Cr·Af·AI·Cd | **sceneflow**(7) — 2.1 |
| nomad-blog (`blog` 1300) | `contentflow` 흡수 또는 `blog` | org | 4 | J·Cr·Af·AI·Cd | contentflow(블로그 자동화) 겹침 |
| nomad-commerce (`commerce` 1400) | `commerce` | org | 13 | J·Cr·AI·Cd | **commerce**(6) — 2.1 |
| microweb-studio (`microweb` 1500) | `microweb` | org | 10 | J·Cr·AI·V·anon 12 | 없음 |
| admin-suite erp (`erp` 1600) | `erp` | org | 8 | AI | 없음 |
| admin-suite sms (`sms` 1700) | `school` | org (registry `isolated`→`org` 변경) | 5 | AI | school 청사진(isolated 초안) |
| admin-suite hms (모놀리스만) | `hospital` | isolated | 10 | 없음(nomad_core 연결 금지) | hospital 청사진 — task-008(보류) |
| live-poll (`poll` 1800) | `poll` | org | 9 | AI | 없음 |
| stock-dashboard (`stock` 1900) | `stock` | user 제안 | 19 | Cr·AI·Cd | 없음 |
| toon-factory (`toon` 2000) | `toon` | org | 11 | J·Cr·AI | 없음 |
| study-note (`notes` 2100) | `studynote` | user 제안 | 7 | J·Cr·AI | knowflow·classroom 부분 겹침(미확인) |
| website-floria (`site` 2200) | `floria` | org | 3 | AI | 없음 |
| nomad-docs (`docs` 2300) | `docs` | org | 31 | J·Cr·AI·Cd | 없음 |
| arch-studio (`arch` 2400) | `arch` | org | 15 | J·Cr·AI | 없음 (일회성 주문 C-1 필요) |
| local-news (`news` 2500) | `news` | org | 40 | Cr·AI·Cd·anon 46 | 없음 (코어 요청 R-1~R-10) |
| book-trailer (`trailer` 2600) | `trailer` | org | 17 | J·Cr·AI | 없음 |

- 제품 간 FK: 샘플 확인(blog·video·docs·trailer·news·arch) 0건. 나머지는 이식 작업에서 확인.
- 이식 공통 변환: `core.org_members`→`nomad_core.memberships`(`member`→`editor`), `org_id`→`organization_id`, `core.has_entitlement`→`nomad_core.has_feature`, 저쪽 `plans` 시드→A/B/C + `features`. 상세 규칙은 `tasks/task-002-blueprint-migrations.md#변환 규칙` 재사용.

### 2.1 이미 있는 3개 제품 — 저쪽 설계와 차이

| 제품 | 양쪽 대응 | 저쪽에만 있음 | 이쪽에만 있음 |
|---|---|---|---|
| flora | personas↔custom_personas · projects↔books · chapters↔chapters · assets↔cover_images·manuscript_uploads · pipeline_runs↔generation_runs·agent_tasks | sections · book_exports · member_settings · webhook_endpoints·deliveries · waitlist | audiobooks (저쪽은 낭독을 코어 voice·jobs로 처리, 미확인) |
| sceneflow | projects↔productions · scenes↔scenes · assets↔scene_assets · channels↔channels · uploads↔uploads · edit_jobs·render_jobs↔core.jobs+outputs | 트렌드(trend_videos·radar_reports) · 롱폼 3 · 음원·플리 4 · 랜딩·링크인바이오 3 · 대행(clients 외 3) · 스토리보드 5 · 편집(edit_presets·edit_plans·clip_transcripts·pronunciation_lexicon) · compliance·banned_words·analytics·workflows | 없음 |
| commerce | sourcing_items↔import_batches · products↔products · marketplace_accounts↔market_accounts(+Cd) · listings↔listing_drafts·market_uploads · automation_jobs↔core.jobs | detail_pages·slots · market_images · shipping_templates · export_files · banned_words · exchange_rates · market_categories | orders (저쪽 1400에 주문 테이블 없음) |

차이는 이쪽 기존 테이블을 유지하고 **새 테이블만 새 날짜 마이그레이션으로 추가**한다(적용된 파일 수정 금지). 저쪽만 있는 것 중 채택 범위는 결정 필요.

## 3. 수량 한도 — 저쪽 설계 요약 (task-006 입력)

| 요소 | 저쪽 방식 | 위치 |
|---|---|---|
| 한도 저장 | `core.plans.features jsonb`에 키·값. 서버만 읽음 | 0002 `plans.features` 주석, 각 조각 플랜 시드 |
| 키 종류 | 개수형 `max_*`(max_events·max_members·max_students·max_classes·max_channel_accounts·max_books·max_activations 등) · 기간형 `*_per_month`·`*_per_day`(posts_per_month·ai_chat_turns_per_day) · 크기형(storage_mb·max_input_chars·materials_max_mb) · 허용 목록(channel_types·ai_modes·allowed_tiers) | `seed.sql`, 1300·1600·1700·1800·2100·2400·2600 |
| 읽기 헬퍼 | 제품 스키마 함수 예: `poll.plan_feature_int(org, key, default)` — 키가 없으면 기본값 | 1800 718·759·767행 |
| 검사 지점 | 생성 RPC 안에서 현재 개수 count 후 초과 시 SQLSTATE 오류(예: 행사 생성·라이브 전환) | 1800 |
| 시간 창 한도 | `core.rate_limit_buckets` + `core.rate_limit_hit(key, limit, window_s)` 고정 윈도우, service_role 전용 | 0004 666~701행 |
| 무제한 표기 | `-1` 대신 큰 숫자로 통일(2026-10-14 결정) | 1800 1540행 |

- 기간형(`*_per_month`)을 무엇으로 세는지(테이블 count vs 원장)는 미확인 — 근거 필요.
- 이쪽 적용 시 선택지(결정 필요): (A) `plans`에 `limits jsonb` 컬럼 추가 · (B) `plan_features`처럼 정규화한 `plan_limits(product_code, plan_code, limit_key, value int)` + `nomad_core.plan_limit(org, product, key)` 헬퍼. 이쪽은 기능을 정규화 표로 두므로 B가 일관적이다(제안).
- 수치(저쪽 시드 값)는 그대로 가져오지 않는다. 수치는 [billing-credits](../01-architecture/billing-credits.md) 결정 후.

## 4. 병렬 이식 웨이브

| 웨이브 | 작업 | 병렬 | 선행 | 위험 |
|---|---|---|---|---|
| C1 | 크레딧 원장 보강(`ref_type/ref_id`·환불 연결) + 버킷 결정 반영 | 단독 | 결정 D2 | 높음 |
| C2 | `jobs`(클레임·하트비트·실패 시 환불) | 단독 | C1 | 높음 |
| C3 | 수량 한도(task-006) · `rate_limit_buckets` | C3·C4 병렬 | C1 | 높음 |
| C4 | `audit_log` · `oauth_states` · `encrypted_credentials` | C3·C4 병렬 | — | 높음 |
| C5 | AI 계층(pgvector·`ai_*`·`wiki_*`·`ai_usage`) | C5·C6·C7 병렬 | C2 | 높음 |
| C6 | affiliate 5개 | C5·C6·C7 병렬 | C4 | 보통 |
| C7 | voice 2개 | C5·C6·C7 병렬 | C2 | 보통 |
| P1 | erp · school(sms) · poll · floria(site) | 4개 병렬 | C3·C4 | 높음(RLS) |
| P2 | astro · studynote · toon · trailer · arch · microweb · docs · stock | 8개 병렬 | C2·C3 (+microweb C7, docs·stock C4) | 높음 |
| P3 | flora·sceneflow·commerce 차이 추가 · contentflow(blog) | 4개 병렬 | C2·C4 (+sceneflow·contentflow C6) | 높음 |
| P4 | news | 단독 | P1 이후 + 코어 요청 R-1~R-10 결정 | 높음(anon 46) |
| 별도 | hospital(hms) | — | task-008 결정 4건 | 높음 |

- 제품 조각의 AI 시드는 C5 전이면 제품 마이그레이션과 분리한 두 번째 파일로 둔다(결정 D6에 따름).
- 각 제품 작업 완료 조건: `tests/services_access.sql`·`feature_gating.sql`에 해당 제품 추가 후 통과, `sql2erd` 갱신, registry 갱신.

## 5. 사람 결정 필요

| ID | 질문 | 영향 |
|---|---|---|
| D1 | 결제 서버(`billing_keys`·`payment_orders`·`payments`·`webhook_events`, 구독 상태 5종)를 이 저장소에 넣는가, INTEGRATION 계약(외부 결제 서버)만 유지하는가 | 1장 0002 · arch 일회성 주문 C-1 |
| D2 | 크레딧 버킷(plan/pack 분리·월 지급 만료) 채택 여부, `credit_packs`를 addon으로 볼지 | C1 · task-007 |
| D3 | 수량 한도 저장 방식 A(jsonb) / B(정규화) | C3 · task-006 |
| D4 | 제품 slug·흡수: astro↔personal, nomad-blog↔contentflow, study-note↔knowflow/classroom | 2장 |
| D5 | 형태: astro·studynote·stock을 user로 둘지 org로 둘지 | 2장 |
| D6 | AI 계층을 코어로 이식(C5)할지, 제품 AI 시드를 빼고 이식할지 | P1~P4 일정 |
| D7 | 승인제·초대제 가입(`profiles.status`, `apps.signup_policy`) 도입 여부 | stock·admin-suite |
| D8 | anon 노출 제품(microweb·news·poll 참가자)의 공개 경로 허용 범위 | 보안 레벨, P2·P4 |
| D9 | flora·sceneflow·commerce의 저쪽 전용 테이블 채택 범위(특히 sceneflow 29개) | P3 규모 |
| D10 | local-news 코어 요청 R-1~R-10(독자 인증·테마) 수용 여부 | P4 |
| D11 | registry: school `isolated`→`org`, `db: supabase-b`→`supabase-a` 변경 승인 | P1 |

## 6. 미확인 (근거 필요)

- 앱 코드 쪽 코어 의존(특히 voice·AI)은 SQL 참조만 셌다 — 제품 `02_ARCHITECTURE.md` 확인 필요.
- 기간형 한도의 계수 방식, news의 `organizations.slug·settings` 요구, flora 낭독의 저쪽 처리 위치.
- 테이블 수는 `create table` 문 수라 파티션·조건부 생성이 섞였을 수 있다(docs 31·news 40).
