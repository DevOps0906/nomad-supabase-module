# flora-publishing 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.flora.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
`nomad.theme`(라이트/다크)와 제품 화면 테마 `member_settings.theme_key`(flora-dark 등)는 별개다. theme_key 는 서버 행이 정본(플랜 잠금)이라 로컬에는 캐시만.
역할·플랜·조직 id·기능 잠김 여부는 로컬에 저장하지 않는다(항상 서버 `has_access`·`nomad_dashboard_features`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.flora` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.flora.ui.v1`(편집기 패널·글꼴 크기) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.flora.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `flora.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, books 는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.flora.books.v1` | books | deleted_at 행은 캐시에서 지움. 공개 여부·slug 는 표시용 |
| `nomad.flora.chapters.v1` | chapters | — |
| `nomad.flora.sections.v1` | sections | `revision`·`gen_status` 함께 보관. queued·generating 섹션은 오프라인 편집 금지(서버 PB005) |
| `nomad.flora.personas.v1` | custom_personas | 이름·보관 상태 |
| `nomad.flora.settings.v1` | member_settings(본인 행) | 플랜이 바뀌면 서버가 테마·모드를 내릴 수 있다 → 저장 응답으로 덮는다 |
| `nomad.flora.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ books: ISO, … }` |
캐시하지 않음: cover_images·book_exports·manuscript_uploads·generation_runs·agent_tasks(서버 결과·진행률은 온라인 조회·Realtime), webhook_*, waitlist(접근 불가). 표지·원고·내보내기 파일은 서명 URL 로만 받는다.

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_org_updated_idx`). 하드 삭제 표(chapters·sections·personas)는 증분으로 삭제를 알 수 없으므로 책을 열 때 그 책의 목차·원고 행 전체를 다시 받는다.
2. 올리기: 책 정보·목차·원고 편집만 오프라인 큐 `nomad.flora.outbox.v1`에 쌓는다(새 행은 클라이언트 uuid `id`). 서버 `updated_at`이 더 최신이면 서버 값이 이긴다. 원고는 보낸 `revision` 이 서버와 다르면 서버 본문을 보여 주고 사용자에게 알린다.
3. 소프트 삭제는 `deleted_at` 에 아무 값이나 보내도 서버가 now()로 바꾼다. 복원은 서버만(PB010) — 오프라인 큐에 넣지 않는다.
4. AI 생성·전체 생성·표지·내보내기·업로드 요청은 오프라인 큐에 넣지 않는다(크레딧 차감 — 온라인에서 서버가 멱등 키로 한 번만).

## 로그아웃 시 삭제 키
`nomad.flora.*`(전부, `nomad.flora.ui.v1` 포함) + IndexedDB `nomad.flora`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.flora.*`를 지우고 새 조직으로 다시 받는다.
