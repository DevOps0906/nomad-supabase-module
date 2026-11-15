# classroom 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.classroom.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할·과정 역할(course_role)·플랜·기능 잠김 여부는 로컬에 저장하지 않는다(항상 서버 판정).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(세션·학생 토큰) |
|---|---|---|---|
| 웹(강사) | 캐시 안 함(온라인 조회) | localStorage `nomad.theme` · `nomad.classroom.ui.v1`(목록 정렬·접힘) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 웹(학생) | 캐시 안 함 | localStorage `nomad.theme` | 학생 토큰은 서버가 발급한 httpOnly 쿠키만(원본 student-gate) |
자료 파일·정답·학생 코드·응시 기록·설문 응답은 로컬에 저장하지 않는다(개인정보·정답 — 서버 중계·서명 URL 로만).

## 오프라인 캐시 대상
- 없음. 원본 표에 `updated_at` 이 없고 수업 중 실시간 공개(open_at·평가 시작)가 바뀌므로 화면을 열 때마다 서버에서 받는다.
- 퀴즈 풀이 중 임시 답안만 `nomad.classroom.quiz-draft.v1`(sessionStorage, 퀴즈 id·단계별 선택 보기)에 둔다. 제출하면 지운다. 점수·정답은 두지 않는다.

## 로그아웃 시 삭제 키
`nomad.classroom.*`(전부, `nomad.classroom.ui.v1` 포함) + sessionStorage `nomad.classroom.quiz-draft.v1`. **`nomad.theme`은 유지**. 조직을 전환하면 `nomad.classroom.*`를 지운다.
