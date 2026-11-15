# 꿈해몽·사주·여행(personal) 로컬 저장소 설계 (신규 — 연결된 레포가 없어 현재 키 없음)

키 규칙: `nomad.personal.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`, 로그인 시 `nomad_core.profiles.theme`과 맞춘다).
금지: 역할·플랜·사용자 id를 권한 판단용으로 저장하지 않는다. **생년월일·출생시각·꿈 내용(readings.input_json)·풀이 결과는 어디에도 캐시하지 않는다**(민감정보 — 매번 서버에서 읽는다). 비밀(토큰·API 키)은 localStorage·IndexedDB 평문 금지.

## 저장 위치
| 환경 | 일반 데이터(여행) | 설정·테마 | 비밀(세션 토큰) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.personal` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.personal.ui.v1` | 쿠키(@supabase/ssr, httpOnly). localStorage·IndexedDB 금지 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore) |
| 데스크톱(tauri) | tauri store 파일 `personal.json` | tauri store `nomad.theme` | OS 키체인 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.personal.trips.v1` | trips | 여행 일정 오프라인 열람(해외에서 자주 오프라인) |
| `nomad.personal.trip_days.v1` | trip_days | plan_json·tools(날씨·환율 스냅샷) |
| `nomad.personal.syncstate.v1` | — | 테이블별 마지막 동기 시각 |
캐시하지 않음: readings·birth_profiles(민감), saved_reports(PDF 경로만, 파일은 서명 URL로 매번 요청).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 소유 단위(user안 `user_id`, org안 `organization_id`)로 증분 조회(`*_updated_idx`). 삭제는 소프트 삭제가 없으므로, 앱 시작 시 캐시 id 목록과 서버 id 목록을 비교해 없는 행을 지운다.
2. 올리기: trips·trip_days 변경만 오프라인 큐 `nomad.personal.outbox.v1`에 쌓는다. 서버 `updated_at`이 큐 항목 시각보다 최신이면 서버 값이 이긴다. 새 행 id는 서버가 만든다(사용자 insert에 id 권한 없음) → 큐는 임시 id를 쓰고 반영 후 서버 id로 바꾼다.
3. 잠김(구독 끊김·조직 비활성)으로 서버 행이 0이 되면 캐시도 비운다(잠긴 자료를 오프라인으로 보여 주지 않는다).

## 로그아웃·삭제 시
로그아웃: `nomad.personal.*` 전부 + IndexedDB `nomad.personal` 삭제, **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 세션 토큰도 삭제.
"내 데이터 삭제"(user안 `erase_my_data()`, org안 `erase_personal_data(org)`) 성공 후에도 같은 키를 지운다. org안에서 조직을 전환하면 `nomad.personal.*`를 지우고 다시 받는다.
