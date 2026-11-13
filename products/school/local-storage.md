# SCHOOL 로컬 저장소 설계 (신규 — 원본은 GNB 접기 상태만 localStorage)

키 규칙: `nomad.school.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할(admin/teacher/student)·플랜은 저장하지 않는다(항상 서버 `my_role`). 학생 개인정보(미성년자)는 기기 캐시를 최소화한다.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.school` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.school.ui.v1` | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `school.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, classes·subjects는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.school.classes.v1` | classes | 삭제 행(`deleted_at`)도 내려오므로 캐시에서 지운다 |
| `nomad.school.subjects.v1` | subjects | 같음 |
| `nomad.school.members.v1` | members | 교직원은 학교 전체, 학생은 본인 행만(RLS) |
| `nomad.school.attendance.v1` | attendance | 최근 31일만. 학생 기기는 본인 출석만 |
| `nomad.school.syncstate.v1` | — | 테이블별 마지막 동기 시각 |
캐시하지 않음: workspaces 설정(로그인 때 조회), 대시보드·추이(서버 계산), AI 대화(0002, 서버 보관).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_org_updated_idx`). attendance는 Realtime 채널 `school:<organization_id>:attendance`로 보강.
2. 올리기: 출석 체크는 오프라인 큐 `nomad.school.outbox.v1`에 쌓았다가 온라인 때 `mark_attendance_bulk`로 보낸다. 같은 (학생·과목·날짜)는 서버 upsert라 마지막 쓰기가 이긴다. teacher 소급 기한(teacher_backfill_days)을 넘기면 서버가 거부 → 큐에서 빼고 알린다.
3. 학급·과목·구성원 변경(admin)은 온라인에서만(한도·역할 검사가 서버에 있음).

## 로그아웃 시 삭제 키
`nomad.school.*`(전부) + IndexedDB `nomad.school`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 학교(조직)를 전환하면 `nomad.school.*`를 지우고 다시 받는다. 공용 기기(교무실 PC)는 로그아웃 시 캐시 전체 삭제가 기본.
