# analytics 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.analytics.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할·플랜·조직 id·기능 잠김 여부·plan_limits 수치는 로컬에 저장하지 않는다(항상 서버 `has_access`·`nomad_dashboard_features`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(세션 토큰·공유 토큰·웹훅 토큰) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.analytics` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.analytics.ui.v1`(사이드바·표 열 너비·그래프 보기) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 공유·웹훅 토큰은 화면에만 표시 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.analytics.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `analytics.json` | tauri store `nomad.theme` | OS 키체인만 |
업로드 원본(CSV·엑셀)·정제본·보고서 파일은 로컬 캐시하지 않는다(서명 URL 로만, 최대 50MB).

## 오프라인 캐시 대상 (읽기 전용 캐시)
| 키 | 테이블 | 동기화 컬럼 |
|---|---|---|
| `nomad.analytics.projects.v1` | projects | updated_at |
| `nomad.analytics.datasets.v1` | datasets(profile·inspection 제외) | updated_at |
| `nomad.analytics.dashboards.v1` | dashboards · widgets | updated_at(dashboards) |
| `nomad.analytics.reports.v1` | reports · report_sections | created_at(reports) · updated_at(sections) |
| `nomad.analytics.questions.v1` | questions | updated_at |
| `nomad.analytics.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ projects: ISO, … }` |
캐시하지 않음: analysis_runs·run_steps·cleaning_proposals(진행 중 상태 — Realtime·온라인 조회), dataset_versions·change_logs, pipelines·schedules, usage_events, report_shares(owner·admin 전용·토큰), notifications(온라인 벨).

## 동기화 규칙
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회. 하드 삭제 표(projects·datasets·questions)는 목록 화면을 열 때 id 목록 전체를 비교해 지운다.
2. 올리기: 오프라인 큐 없음. 쓰기(프로젝트 이름, 시트 선택, 질문 고정, 그래프 유형, 자동화 끄기)는 온라인에서만 바로 보낸다 — 분석·업로드는 서버 상태가 필요하고 사용자 insert 에 id grant 가 없다.
3. 업로드·분석 실행·공유 만들기/해제·자동화 켜기는 온라인 전용(파일 한도 AN001·기능 잠김 AN002 를 서버가 판정).

## 로그아웃 시 삭제 키
`nomad.analytics.*`(전부, `nomad.analytics.ui.v1` 포함) + IndexedDB `nomad.analytics`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.analytics.*`를 지우고 새 조직으로 다시 받는다.
