# study-note 로컬 저장소 설계 (원본 레포의 브라우저 BYOK 키 입력은 폐지, 일지는 서버 정본)

키 규칙: `nomad.studynote.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
원본의 `user_settings.theme`은 서버 동기화용으로 남기되, 첫 화면 깜빡임 방지는 로컬 `nomad.theme`을 먼저 읽는다(로그인 후 서버 값이 다르면 서버 값으로 맞춘다).
원본 BYOK(사용자 OpenRouter API 키)는 없앴다 — 어떤 환경에도 API 키를 저장하지 않는다.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.studynote` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.studynote.ui.v1`(마지막 탭·정렬) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.studynote.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `studynote.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, entries는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.studynote.entries.v1` | entries | 원문·최종본·키워드. user안 = 본인, org안 = 조직(이용권 멤버) |
| `nomad.studynote.settings.v1` | user_settings | 본인 1행 |
| `nomad.studynote.models.v1` | model_catalog | is_active 행, 하루 1회 전체 재조회 |
| `nomad.studynote.syncstate.v1` | — | 테이블별 마지막 동기 시각 |
캐시하지 않음: runs·run_steps(진행률은 Realtime·온라인 조회, 결과는 entries.final_text에 들어감), runtime_config·cost_guard(접근 불가).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 증분(user안 `entries_user_updated_idx`, org안 `entries_org_updated_idx`). `deleted_at`이 찍힌 행은 휴지통으로 옮기고, 30일 뒤 서버 영구 삭제 시 증분에서 사라지므로 휴지통 화면을 열 때 전체 재조회.
2. 올리기: 일지 작성·원문 수정·소프트 삭제만 오프라인 큐 `nomad.studynote.outbox.v1`에 쌓는다. 새 일지는 클라이언트 uuid `id`로 만들어 재전송해도 중복이 없다. 서버 `updated_at`이 더 최신이면 서버 값이 이긴다. 정리 중(organizing)인 일지의 원문 수정은 서버가 거부(NT001)하므로 큐에서 빼고 알린다.
3. 정리 실행(start_run)은 오프라인 큐에 넣지 않는다(크레딧 차감 — 온라인에서 서버가 request_id로 한 번만).

## 로그아웃 시 삭제 키
`nomad.studynote.*`(전부, `nomad.studynote.ui.v1` 포함) + IndexedDB `nomad.studynote`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. org안에서 조직을 전환하면 `nomad.studynote.*`를 지우고 새 조직으로 다시 받는다.
