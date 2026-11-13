# POLL 로컬 저장소 설계 (신규 — 원본은 GNB 접기 상태만 localStorage, 청중은 httpOnly 쿠키)

키 규칙: `nomad.poll.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
실시간 제품이라 오프라인 쓰기는 없다. 캐시는 진행자 화면의 빠른 첫 표시용이다.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹(진행자) | IndexedDB `nomad.poll` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.poll.ui.v1` | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 웹(청중) | 저장 안 함(서버 스냅샷 + Realtime) | localStorage `nomad.theme`만 | 참가자 토큰은 httpOnly 쿠키 `lp_pt_<eventId>`(7일)만. JS에서 읽지 않는다 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri, OBS 진행) | tauri store 파일 `poll.json` | tauri store `nomad.theme` | 오버레이 키·토큰은 OS 키체인만 |

## 오프라인 캐시 대상 (진행자, 동기화 컬럼: updated_at, events는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.poll.events.v1` | events | 목록·상태. 삭제 행은 RLS가 숨기므로 서버가 삭제 id를 따로 내려준다 |
| `nomad.poll.polls.v1` | polls · poll_options | 행사별 문항·선택지(draft 편집 초안 포함) |
| `nomad.poll.results.v1` | poll_results | 확정 집계만(종료된 문항) |
| `nomad.poll.syncstate.v1` | — | 테이블별 마지막 동기 시각 |
캐시하지 않음: participants·votes·qna(실시간·개인정보, 서버 값이 정답), banned_words, audit_logs, 오버레이 키 원문(1회 표시 후 폐기).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_org_updated_idx`). live 행사는 Realtime Broadcast(`poll:<organization_id>:<event_id>`)가 우선이고, seq 공백을 보면 스냅샷을 다시 받는다.
2. 올리기: draft 문항·선택지 편집만 오프라인 큐 `nomad.poll.outbox.v1`에 쌓았다가 온라인 때 보낸다. 서버 `updated_at`이 더 최신이면 서버 값이 이긴다. 문항이 이미 열렸으면(PL011·RLS 0행) 큐에서 빼고 알린다.
3. 상태 전이(행사 live·종료, 문항 open·close)·모더레이션·차단은 온라인에서만.

## 로그아웃 시 삭제 키
`nomad.poll.*`(전부) + IndexedDB `nomad.poll`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰·오버레이 키도 삭제. 조직을 전환하면 `nomad.poll.*`를 지우고 다시 받는다. 청중 쿠키는 서버가 행사 종료·보존 기한에 맞춰 만료시킨다.
