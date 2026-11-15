# KNOWFLOW 로컬 저장소 설계 (신규 — 원본 레포에는 없음)

원본 웹은 `persistSession:false`로 로컬 저장소를 쓰지 않는다. 아래는 오프라인 캐시·테마용으로 새로 정한다.
키 규칙: `nomad.knowflow.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`, 제품 전체 공통).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.knowflow` (객체 저장소 = entity) | localStorage `nomad.theme` | **localStorage·IndexedDB 금지**. Supabase 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `knowflow.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at·deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.knowflow.projects.v1` | projects | 목록·이름·보관 상태 |
| `nomad.knowflow.sources.v1` | sources | 메타데이터만(원본 PDF·청크 본문은 캐시하지 않음) |
| `nomad.knowflow.conversations.v1` | conversations | messages는 `nomad.knowflow.messages.v1`로 대화별 캐시(추가만) |
| `nomad.knowflow.reports.v1` | reports | 본문 markdown 포함 |
| `nomad.knowflow.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ projects: ISO, … }` |
캐시하지 않음: source_chunks(직접 접근 불가·용량), processing_jobs·usage_events·쿼터(서버 값이 정답), idempotency 키.
YouTube 메타데이터(제목·채널·길이)는 서버가 29일 안에 파기·재확인하므로 `sources` 캐시에서도 서버가 내려준 값만 쓰고 장기 보관하지 않는다.

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: 테이블별 `updated_at > syncstate` 인 행을 소유 단위(user안 user_id / org안 organization_id)로 증분 조회한다(`*_sync_idx` 사용). RLS가 `deleted_at is null`만 반환하므로, 삭제 전파는 서버(service_role) 엔드포인트가 `deleted_at > syncstate` 행의 id를 따로 내려준다.
2. 올리기: 오프라인 변경은 큐(`nomad.knowflow.outbox.v1`)에 쌓았다가 온라인이 되면 RPC(create/update/delete_project 등)로 보낸다. 서버 `updated_at`이 더 최신이면 서버 값이 이긴다(마지막 쓰기 우선, 시각은 서버 `touch_updated_at` 기준).
3. 삭제는 항상 소프트 삭제(`deleted_at`)이며, 클라이언트는 삭제 행을 캐시에서 지운다.
4. 자료 등록·재시도·유튜브 등록은 멱등 키가 필요하므로 오프라인 큐에 넣지 않는다(온라인에서만).

## 로그아웃 시 삭제 키
`nomad.knowflow.*`(전부) + IndexedDB `nomad.knowflow` 삭제. **`nomad.theme`은 유지**(기기 설정). 앱·데스크톱은 보안 저장소의 토큰·API 키도 함께 삭제한다. org안에서 조직을 전환하면 `nomad.knowflow.*`를 지우고 새 조직으로 다시 받는다.
