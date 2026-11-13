# book-trailer 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.trailer.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할·플랜·조직 id·기능 잠김 여부는 로컬에 저장하지 않는다(항상 서버 `has_access`·`nomad_dashboard_features`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.trailer` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.trailer.ui.v1`(편집기 패널·미리보기 화면비) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.trailer.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `trailer.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, books는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.trailer.books.v1` | books | 원고·표지 파일은 캐시하지 않음(경로만). deleted_at 행은 캐시에서 지움 |
| `nomad.trailer.trailers.v1` | trailers | — |
| `nomad.trailer.scenes.v1` | scenes | `revision` 함께 보관(save_scene 낙관적 동시성) |
| `nomad.trailer.briefs.v1` | briefs | 불변 → created_at 기준 증분 |
| `nomad.trailer.links.v1` | purchase_links | click_count는 표시용 |
| `nomad.trailer.brandkits.v1` | brand_kits | — |
| `nomad.trailer.metapacks.v1` | metadata_packs | — |
| `nomad.trailer.catalog.v1` | grammars · templates · music_tracks(공개 컬럼) | 하루 1회 전체 재조회 |
| `nomad.trailer.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ books: ISO, … }` |
캐시하지 않음: generation_runs·renders(진행률은 온라인 조회), scene_assets·book_digests(서버 결과, 크기 큼), link_clicks, reviews, runtime_config(접근 불가). 렌더 영상·에셋 파일은 서명 URL로만 받는다.

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_org_updated_idx`). 하드 삭제 표(trailers·scenes·links·brandkits·metapacks)는 증분으로 삭제를 알 수 없으므로 트레일러를 열 때 해당 트레일러 행 전체를 다시 받는다.
2. 올리기: 책·트레일러 메타, 구매 링크, 브랜드 키트, 메타데이터 편집만 오프라인 큐 `nomad.trailer.outbox.v1`에 쌓는다(새 행은 클라이언트 uuid `id`). 서버 `updated_at`이 더 최신이면 서버 값이 이긴다.
3. 장면 편집은 `save_scene(id, patch, expected_revision)`로만 보내고, TR409(충돌)이면 서버 값으로 덮은 뒤 사용자에게 알린다.
4. AI 실행·렌더 요청은 오프라인 큐에 넣지 않는다(크레딧 차감 — 온라인에서 서버가 request_id로 한 번만).

## 로그아웃 시 삭제 키
`nomad.trailer.*`(전부, `nomad.trailer.ui.v1` 포함) + IndexedDB `nomad.trailer`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.trailer.*`를 지우고 새 조직으로 다시 받는다.
