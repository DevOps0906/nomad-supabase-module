# nomad-blog 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.blog.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할·플랜·조직 id·기능 잠김 여부는 로컬에 저장하지 않는다(항상 서버 `has_access`·`nomad_dashboard_features`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키·채널 비밀번호·세션 쿠키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.blog` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.blog.ui.v1`(에디터 패널·미리보기 채널) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 채널 비밀은 서버 provider_credentials 에만 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.blog.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `blog.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.blog.posts.v1` | posts | `version`·`status`·`compliance_verdict` 함께 보관. generating·publishing 원고는 오프라인 편집 금지(서버 정책) |
| `nomad.blog.publications.v1` | post_publications | 읽기 캐시(캘린더·상태 표시). 쓰기 없음 |
| `nomad.blog.channels.v1` | channel_accounts | 읽기 캐시(채널·상태·동의 여부만, credential_id 는 쓰지 않음) |
| `nomad.blog.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ posts: ISO, … }` |
캐시하지 않음: post_affiliate_links(원고를 열 때 온라인 조회), 제휴 링크·클릭(core RPC), 대표 이미지 파일(서명 URL 로만).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`posts_org_updated_idx`·`post_publications_org_updated_idx`). 원고는 하드 삭제라 목록 화면을 열 때 id 목록 전체를 비교해 캐시에서 지운다.
2. 올리기: 원고 콘텐츠 컬럼(title·body_json·excerpt·tags·category·target_keyword·template·experience_note·cover_image_path) 편집만 오프라인 큐 `nomad.blog.outbox.v1`에 쌓는다(새 행은 클라이언트 uuid `id`). 서버 `updated_at`이 더 최신이면 서버 값이 이긴다. 콘텐츠가 바뀌면 서버가 컴플라이언스 검사를 무효로 돌리므로 올린 뒤 다시 검사한다.
3. 발행·예약·취소·동의·연결 해제·AI 초안 요청은 오프라인 큐에 넣지 않는다(외부 발행·크레딧 — 온라인에서 서버가 멱등 키로 한 번만).

## 로그아웃 시 삭제 키
`nomad.blog.*`(전부, `nomad.blog.ui.v1` 포함) + IndexedDB `nomad.blog`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.blog.*`를 지우고 새 조직으로 다시 받는다.
