# NOMAD Commerce 로컬 저장소 설계 (원본: 웹 MVP, 서버가 정본 — 브라우저에는 캐시·UI 상태만)

키 규칙: `nomad.commerce.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
원본 원칙 유지(03_SCREENS_UX GNB · 07_SOURCE_MIGRATION #5): 역할·플랜·마켓 API 키를 브라우저에 쓰지 않는다. 플랜 판정은 서버(`dashboard_features`)만 믿는다.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·마켓 API 키) |
|---|---|---|---|
| 웹(Next.js, 주 환경) | IndexedDB `nomad-commerce`(아래 캐시) | localStorage `nomad.theme` · `nomad.commerce.ui.v1`(GNB 접기 등) | localStorage·IndexedDB 금지. 세션은 쿠키(@supabase/ssr, httpOnly). 마켓 키는 서버 vault 만(브라우저 미전달) |
| 앱(Capacitor, Phase 2 원격 셸) | 웹과 같음(원격 셸이 같은 웹을 띄운다) | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | 해당 없음 | — | — |

## 오프라인 캐시 대상 (서버 → 브라우저, 동기화 컬럼 updated_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.commerce.products.v1` | products | `deleted_at` 이 있는 행은 캐시에서 지운다(소프트 삭제) |
| `nomad.commerce.listing_drafts.v1` | listing_drafts | status `archived` 는 목록에서 숨김 |
| `nomad.commerce.shipping_templates.v1` | shipping_templates | 하드 삭제라 증분으로 삭제를 알 수 없음 → 열 때 전체 재조회(조직당 수십 행) |
| `nomad.commerce.banned_words.v1` | banned_words(기본 + 조직) | compliance 미리보기용. 판정 정본은 서버 |
| `nomad.commerce.market_categories.v1` | market_categories(마켓별) | synced_at 기준 하루 1회 |
| `nomad.commerce.syncstate.v1` | — | 표별 마지막 동기 시각 |
캐시하지 않음: detail_pages·slots·market_images·market_uploads·export_files·import_batches(진행 상태는 Realtime, 이미지·파일은 서명 URL), market_accounts(자격 상태는 매번 서버), exchange_rates(서버 계산).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`products_org_updated_idx` · `listing_drafts_org_updated_idx` · `shipping_templates_org_updated_idx`).
2. 올리기: 상품·등록 폼·배송 템플릿 편집만 오프라인 큐 `nomad.commerce.outbox.v1`에 두고 온라인이 되면 순서대로 반영. 서버 `updated_at`이 더 최신이면 서버 값을 쓰고 사용자에게 알린다.
3. 큐에 넣지 않음: 상세페이지 생성·재생성, AI 보조, 가져오기, 업로드, 내보내기(크레딧 선차감·플랜 게이트 — 온라인에서만, request_id 멱등).
4. 소프트 삭제 시각은 서버가 정한다(`deleted_at` 에 무엇을 보내도 now()).

## 로그아웃 시 삭제 키
`nomad.commerce.*`(캐시·outbox·syncstate·ui) + IndexedDB `nomad-commerce`. **`nomad.theme`은 유지**. 조직을 전환하면 `nomad.commerce.*`(ui 제외)를 지우고 새 조직으로 다시 받는다. outbox 에 미전송 편집이 있으면 로그아웃 전에 확인 창을 띄운다.
