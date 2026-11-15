# 신비로운AI(astro) 로컬 저장소 설계 (신규 — 원본은 GNB 접기 상태만 localStorage)

키 규칙: `nomad.astro.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`). PDF 테마(`themes.key`)는 화면 테마와 별개다.
원본 금지 패턴 유지: 역할·플랜·사용자 id를 쿠키·localStorage에 쓰지 않는다. 실명·생년월일시·질문 원문(복호화 값)은 어디에도 캐시하지 않는다.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·키·개인정보 원문) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.astro` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.astro.ui.v1`(GNB 접기) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)에 세션 토큰만 |
| 데스크톱(tauri) | tauri store 파일 `astro.json` | tauri store `nomad.theme` | OS 키체인(세션 토큰만) |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, subjects는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.astro.subjects.v1` | subjects | 호칭·관계·성별 등 권한 있는 컬럼만(암호문 컬럼은 애초에 읽을 수 없음) |
| `nomad.astro.readings.v1` | readings | 완료(completed) 리딩의 content·chart만. 진행 중 상태는 Realtime 구독으로 갱신 |
| `nomad.astro.preferences.v1` | preferences | 1행 |
| `nomad.astro.themes.v1` | themes | 전역 참조(`list_themes`), 하루 1회 갱신 |
| `nomad.astro.syncstate.v1` | — | 테이블별 마지막 동기 시각 |
캐시하지 않음: reading_renders(PDF는 7일 서명 URL — 만료되므로 매번 요청), deliveries, consents.

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 소유 단위(org안 `organization_id`, user안 `user_id`)로 증분 조회(`*_updated_idx`). subjects는 `deleted_at`이 찍힌 행도 내려오므로 캐시에서 지운다.
2. 올리기: preferences 변경만 오프라인 큐 `nomad.astro.outbox.v1`에 쌓는다(서버 `updated_at`이 더 최신이면 서버 값이 이긴다). 보관함·리딩 생성은 서버 암호화·크레딧 차감이 필요하므로 항상 온라인이며, `request_id`(멱등)를 화면에서 만들어 재전송해도 이중 차감이 없다.

## 로그아웃 시 삭제 키
`nomad.astro.*`(전부, `nomad.astro.ui.v1` 포함) + IndexedDB `nomad.astro`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 세션 토큰도 삭제. 탈퇴(`/api/account/delete`) 시에도 같은 키를 지운다. org안에서 조직을 전환하면 `nomad.astro.*`를 지우고 다시 받는다.
