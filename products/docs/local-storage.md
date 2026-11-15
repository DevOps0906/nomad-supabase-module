# NOMAD Docs 로컬 저장소 설계 (신규 — 원본 2300·제품 문서에 로컬 저장 규칙 없음)

키 규칙: `nomad.docs.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할·플랜·기능 잠금 결과·사용자 id 는 로컬에 판정용으로 두지 않는다(항상 서버 RLS·RPC 가 판정). 대상: 로그인 후 워크스페이스(웹). 앱·데스크톱은 원본에 없음 — 아래 행은 생길 때의 규칙.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.docs` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.docs.ui.v1`(보드 열·정렬) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 연동 토큰은 서버만 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `docs.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, 소프트 삭제 deleted_at 은 parties·projects 만)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.docs.parties.v1` | parties | 거래처 연락처 포함 — 로그아웃·조직 전환 시 즉시 삭제 |
| `nomad.docs.projects.v1` | projects | — |
| `nomad.docs.checklist_answers.v1` · `requirements.v1` · `artifacts.v1` · `line_items.v1` | 같은 이름 | 프로젝트 단위로 받는다 |
| `nomad.docs.documents.v1` | documents | 목록 필드만(본문 버전은 캐시하지 않음) |
| `nomad.docs.catalog.v1` | doc_types · checklist_items | 읽기 전용 카탈로그 |
| `nomad.docs.syncstate.v1` | — | 테이블별 마지막 동기 시각 |
캐시하지 않음: document_versions 본문(최대 2MB·확정 문서), uploads·doc_exports(서명 URL 은 만료형), generation_runs(Realtime 구독), 연동·웹훅 표(owner/admin 설정), 크레딧·잡(core).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id`(카탈로그는 전체) 단위로 증분 조회.
2. 하드 삭제(requirements·artifacts·line_items·checklist_answers 의 delete, 효과 엔진 제거)는 증분으로 오지 않으므로 온라인 때 프로젝트 단위 id 목록을 다시 받아 사라진 행을 지운다. parties·projects 는 deleted_at 으로 내려온다.
3. 올리기: 정본(답·요구사항·산출물·비용·거래처) 편집은 오프라인 큐에 쌓았다가 온라인에서 순서대로 보낸다. 같은 행을 두 사람이 바꾸면 서버 값(마지막 쓰기)이 이긴다. 코드(FR-001 등)·금액 합계·문서번호는 서버 값만 쓴다.
4. 생성·확정·내보내기·크레딧 차감은 큐에 쌓지 않는다(온라인 RPC 만).

## 로그아웃 시 삭제 키
`nomad.docs.*`(전부, `nomad.docs.ui.v1` 포함) + IndexedDB `nomad.docs`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.docs.*`를 지우고 새 조직으로 다시 받는다(카탈로그 제외 가능).
