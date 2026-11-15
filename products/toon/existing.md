# toon-factory 기존 DB → nomad_core 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2000_toon.sql`(스키마 `toon`, 11표) · 플랜 시드 `_supabase-modular/seed.sql`(toon free·pro) · 문서 `products/toon-factory/`(Next.js 웹 에디터, TS 워커 `services/toon-worker`, FastAPI AI).
이식: `org/0001_toon.sql`(조직형만 — 원래 org 제품) · `org/0002_ai.sql`(AI 기능·라우팅, 코어 C5 직접 참조). 스키마 `nomad_toon`(노출) · `nomad_toon_private`(내부, 노출 안 함).
검증: `bash products/toon/run_check.sh` (begin → 청사진 drop → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler(service_role), 워커=toon-worker(service_role), API=FastAPI.

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('toon') | 대체: nomad_core.products | products('toon') | — |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members(member) · is_org_member · has_org_role | 대체: nomad_core.memberships · organization_role | owner/admin/editor(원본 member) 쓰기, viewer 읽기 | 정책 도우미 `nomad_toon.has_access`·`can_edit`·`is_manager` |
| core.app_entitlements · has_entitlement | 대체: nomad_core.has_feature(org, 'toon', 'studio') | — | studio 는 A·B·C 전부 = 구독이 끊겨도 무료 기능은 남는다 |
| core.plans(free·pro features jsonb) | 대체: A/B/C + features + plan_limits 키 | 아래 표 | free→C, pro→A·B. 수치 시드 안 함 |
| core.jobs · credit_ledger(bigint) | 대체: nomad_core.jobs · credit_ledger(uuid) | generations·exports 의 job_id·credit_ledger_id | 선차감 `nomad_core.consume_credits`, 잡 `enqueue_job`(서버) |
| core.write_audit | 대체: nomad_core.write_audit | 액션 `toon.*` | 콘솔 조회 `public.nomad_audit_log` |
| core.guard_privileged_write(이중 잠금) | 삭제 | — | 서버 기록·카탈로그는 사용자 쓰기 grant·정책 자체가 없다 |
| core.set_updated_at | 대체: nomad_core.touch_updated_at | — | — |
| core.storage_org_id · is_platform_admin | 삭제 | 경로 첫 폴더 정규식 · 운영자는 service_role | 카탈로그 draft 열람은 관리 화면(service_role) |
| core.ai_routing_settings 시드 · plans AI 키 | 대체: nomad_core.ai_routing_settings · features | org/0002_ai.sql | 14행, 체인 검사 포함 |

## 테이블 (toon → nomad_toon, 11개 + 뷰 1)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| asset_packs | 이관(플랫폼 소유) | nomad_toon.asset_packs | 웹 읽기 · 관리(service_role) | 없음(카탈로그) |
| characters | 이관 | nomad_toon.characters | 웹 읽기 · 관리 | 없음 |
| assets | 이관(storage_path·editor_path 컬럼 숨김) | nomad_toon.assets | 웹 읽기 · 워커 원본 | 없음 |
| (뷰) catalog_assets | 이관(security_invoker) | nomad_toon.catalog_assets | 웹 | — |
| series | 이관 | nomad_toon.series | 웹 CRUD | org_id → organization_id |
| series_characters | 이관 | nomad_toon.series_characters | 웹 CRUD | 〃 |
| episodes | 이관(+sponsorship_id) | nomad_toon.episodes | 웹 CRUD · 워커(script) | 〃 |
| cuts | 이관 | nomad_toon.cuts | 웹(에디터 자동 저장) | 〃 |
| sponsorships | 이관(원본 11-2) | nomad_toon.sponsorships | 웹 CRUD · decide_sponsorship | 〃 |
| generations | 이관(쓰기 서버) | nomad_toon.generations | 서버·워커 쓰기, 웹 읽기 | 〃 |
| user_assets | 이관(+updated_at, 소프트 삭제) | nomad_toon.user_assets | 워커 쓰기, 웹 읽기·archive | 〃 |
| exports | 이관(+preset·협찬 컬럼, 원본 11-1·11-2) | nomad_toon.exports | 서버·워커 쓰기, 웹 읽기 | 〃 |
| 버킷 toon-catalog | 이관(비공개, 정책 없음) | toon-catalog | 워커·서명 URL | — |
| 버킷 toon-previews | 이관(공개 버킷) | toon-previews | 웹 public URL | 플랫폼 카탈로그 썸네일(assets.preview_path)만. **조직 창작물(user_assets.preview_path·cuts.thumbnail_path)은 넣지 않고 비공개 toon-user-assets 에 둔다**. anon storage.objects 정책 없음(D8) |
| 버킷 toon-user-assets | 이관 | toon-user-assets | 웹 읽기(자기 조직 폴더) | 경로 `<organization_id>/toon/user_assets/<uuid>.png` |
| 코어 버킷 exports(`<org>/toon/exports/…`, 음성 클립) | **코어 계약** | — | 워커 | 이 저장소에 코어 exports 버킷 없음 — 팀장 확인 |
- 동기화 대상: series·series_characters·episodes·cuts·sponsorships·user_assets — `updated_at` + `touch_updated_at` + `(organization_id, updated_at)` 인덱스. 소프트 삭제는 user_assets 만(`deleted_at`), 나머지는 하드 삭제(원본 그대로) → local-storage.md 의 전체 재조회 규칙.

## 함수 (toon → nomad_toon, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| has_toon_access | 이관 | nomad_toon.has_toon_access | 정책 | studio 이용권 기준 |
| plan_features | 이관 | nomad_toon.plan_features | 웹·서버 | 원본과 같은 jsonb 모양(watermark·export·asset_tiers·한도 키 + plan_code)을 코어 이용권·plan_limits 로 만든다 |
| feature_int | 이관 | nomad_toon.feature_int | 웹·서버 | 무제한 -1 → 2147483647 |
| enforce_plan_limits | 이관(트리거, definer) | nomad_toon_private.enforce_plan_limits | 트리거 | 한도 = `org_plan_limit` ?? 원본 free 값, TN001. insert + 소유 키 update(작품·회차 옮기기)에도 적용 |
| bump_cut_revision · enforce_run_status_transition | 이관(트리거) | nomad_toon_private.* | 트리거 | insert 때도 revision=1 강제 |
| save_cut_doc · reorder_cuts | 이관(invoker) | nomad_toon.* | 웹 | TN409 충돌 |
| org_asset_access | 이관 | nomad_toon.org_asset_access | 서버·워커 | premium = 기능 `premium_assets` |
| monthly_export_count | 이관 | nomad_toon.monthly_export_count | 서버 | 한도 키 exports_per_month |
| archive_user_asset | 이관 | nomad_toon.archive_user_asset | 웹 | 원본 member → editor 이상, 감사 nomad_core |
| enforce_sponsorship_status · decide_sponsorship | 이관 | nomad_toon_private.* · nomad_toon.decide_sponsorship | 트리거 · 웹(owner/admin) | 플랜 게이트 = 기능 `sponsorship`(TN002), GUC 이름 `nomad_toon.sponsorship_decision` |
| (신규) guard_episode_sponsorship · exports_immutable | 신규(트리거) | nomad_toon_private.* | 트리거 | 회차 협찬 연결은 owner/admin 만 · 내보내기 판정 값(kind·preset·plan_code·watermark·협찬 문구·크레딧) 불변(service_role 포함) |
| apply_export_sponsorship | 이관+보강 | nomad_toon_private.apply_export_sponsorship | 트리거 | **신규**: plan_code 기록·워터마크 강제(no_watermark 없으면 true)·종류 잠금(TN004)·다른 조직 회차 거부. 원본 협찬 복사·TN008 유지 |

## 플랜 대응 (수치 시드 안 함)
| 기능(nomad_core.features) | A | B | C | 원본 키 |
|---|---|---|---|---|
| studio · export_png | ✓ | ✓ | ✓ | (엔타이틀먼트) · export ["png"] |
| export_zip · export_strip · export_mp4 | ✓ | ✓ | — | export 배열(pro) |
| no_watermark · premium_assets · commercial_use · sponsorship | ✓ | ✓ | — | watermark false · asset_tiers premium · commercial_use · sponsorship |
| ai_chat · voice_chat · dialogue_voice (0002) | ✓ | ✓ | ✓ | 원본 free·pro 모두 true |
| video_voice (0002) | ✓ | ✓ | — | pro 만 |

| limit_key (product `toon`) | 원본 free / pro | 키가 없을 때 |
|---|---|---|
| max_series | 1 / 20 | 1 |
| max_episodes_per_series | 3 / 500 | 3 |
| max_cuts_per_episode | 10 / 60 (instatoon 은 항상 ≤10) | 10 |
| exports_per_month | 20 / 300 | 20 (서버가 monthly_export_count 로 판정) |
| mp4_max_seconds | 0 / 60 | 0 (워커 판정) |
| user_asset_storage_mb | 100 / 2048 | 100 (서버 판정) |
| ai_chat_turns_per_day (0002) | 20 / 200 | 서버 판정 |
- 크레딧(원본 monthly_credits free 10 / pro 300, 충전팩 pack_100·pack_300)은 core credits(plan 지급·addon)로 운영자가 설정 — 여기서 넣지 않는다.

## 앱 변경 (이식 후 웹·워커가 바꿀 것)
- `.schema('toon')` → `.schema('nomad_toon')`, `org_id` → `organization_id`, 역할 `member` → `editor`.
- 플랜 판정은 `plan_features(org)`(모양 동일) 또는 `nomad_core.has_feature(org, 'toon', <기능>)`. **무제한 표기는 -1 이 아니라 2147483647**.
- 수치 한도가 시드되기 전에는 A·B 조직도 free 한도(작품 1개 등)로 막힌다 → 운영자가 `nomad_core.plan_limits` 에 A·B 값을 넣어야 한다.
- 내보내기 행의 watermark·plan_code 는 트리거가 덮어쓴다(서버가 계산해 넣던 코드는 남겨도 무해). 잠긴 종류는 TN004.
- 워커: `core.jobs` 상태 미러링은 `nomad_core.claim_jobs/complete_job/fail_job` 사용, 이미지 2장 중 1장 실패 부분 환불은 `nomad_core.refund_credits(ledger, reason, key, 4)`.

## 팀장 확인 필요
1. 플랜 대응 free→C, pro→A·B(B=A 동일 기능). 별도 중간 플랜이 생기면 B 기능을 줄인다.
2. 코어 공용 버킷 `exports`(내보내기 결과·음성 클립)가 이 저장소에 없다 — 코어에 둘지, `toon-exports` 제품 버킷으로 둘지.
3. toon-previews 공개 버킷은 원본처럼 public=true(카탈로그 썸네일만, 조직 창작물 금지). D8 은 "표 직접 접근 금지"라 storage public URL 은 허용으로 봤다. nomad_toon 스키마 anon usage 는 제거(공개 RPC 없음).
