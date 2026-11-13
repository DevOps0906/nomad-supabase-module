# Toon Factory 로컬 저장소 설계 (원본: GNB 접기·최근 연 작품만 localStorage)

키 규칙: `nomad.toon.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
원본 금지 패턴 유지: 역할·플랜·잠금 해제 여부를 쿠키·localStorage에 쓰지 않는다(플랜은 항상 서버 `plan_features`, CI 금지 문자열 `nomad_role`·`nomad_plan`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.toon` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.toon.ui.v1`(GNB 접기·최근 연 작품 id) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.toon.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `toon.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, user_assets 는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.toon.series.v1` | series | 하드 삭제 → 목록 화면 진입 시 id 목록 전체 재조회로 지운 행 정리 |
| `nomad.toon.episodes.v1` | episodes | 작품 단위로 보관. script(콘티)는 128KB 이하 |
| `nomad.toon.cuts.v1` | cuts | 에디터 자동 저장 큐의 기준(revision 포함). 하드 삭제 → 회차 열 때 회차 단위 전체 재조회 |
| `nomad.toon.series_characters.v1` | series_characters | 작품 단위 전체 재조회 |
| `nomad.toon.sponsorships.v1` | sponsorships | 읽기 캐시만(상태 전이는 온라인) |
| `nomad.toon.user_assets.v1` | user_assets | 메타데이터만. 이미지 원본은 캐시하지 않음(서명 URL 만료) |
| `nomad.toon.catalog.v1` | catalog_assets(뷰) · asset_packs · characters | 미리보기 경로만(공개 버킷). 원본·편집 이미지는 캐시하지 않음 |
| `nomad.toon.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ series: ISO, … }` |
캐시하지 않음: generations·exports(진행률은 온라인 조회), 플랜·한도 값(`plan_features`는 매번 서버).

## 동기화 규칙 (마지막 쓰기 우선, 컷 문서는 revision 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_org_updated_idx`). user_assets 는 RLS 가 `deleted_at` 행을 숨기므로 전체 id 비교로 지운다.
2. 올리기: 작품·회차·캐스트 메타데이터는 오프라인 큐 `nomad.toon.outbox.v1`에 쌓고 온라인에서 보낸다. 서버 `updated_at`이 더 최신이면 서버 값이 이긴다.
3. 컷 문서는 `save_cut_doc(cut, doc, expected_revision)`로만 올린다. `TN409`(다른 기기에서 먼저 저장)면 서버 문서를 받아 사용자에게 "다른 곳에서 수정됨"을 보여 주고 로컬 사본은 `nomad.toon.conflict.v1`에 남긴다(자동 덮어쓰기 금지).
4. 생성·내보내기 요청은 오프라인 큐에 넣지 않는다(크레딧 선차감 — 온라인에서만, 멱등 request_id 는 서버 요청 시 생성).

## 로그아웃 시 삭제 키
`nomad.toon.*`(전부, `nomad.toon.ui.v1` 포함) + IndexedDB `nomad.toon`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.toon.*`(ui 제외)를 지우고 새 조직으로 다시 받는다.
