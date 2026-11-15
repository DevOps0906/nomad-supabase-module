# classroom 기존 DB → nomad_core 이식 대응표 (task-015)

원본: `D:\WorkSpace\DEV\nomad-classroom\supabase\migrations\` 7개(스키마 `classroom`, 표 12개, 버킷 `course-materials`). 0004~0007 의 ALTER·create or replace 는 최종 모양으로 합침.
이식: `org/0001_classroom.sql`(조직형만, AI 없음 → 0002 없음). 스키마 `nomad_classroom`(authenticated·service_role 만, anon 은 usage 도 없음).
D9: 원본 레포 기준으로 새로 작성. 청사진 `supabase/migrations/*_classroom.sql`(sessions·enrollments·assessments·quiz_items)은 원본과 모양이 달라 참고만, 같은 스키마 이름이라 함께 설치하지 않는다.
검증: `bash products/classroom/run_check.sh` (begin → 기존 스키마 drop → 0001 → `check_org.sql` → rollback). 사용처 약어: 웹=Next.js 강사 화면(authenticated), 서버=학생 게이트·Route Handler(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| classroom.organizations | 대체 | nomad_core.organizations | `plan` 컬럼 → nomad_core.subscriptions(원본 basic → A) |
| classroom.profiles(role admin) | 대체 | nomad_core.memberships owner·admin + nomad_core.profiles(display_name) | 조직 전체 과정 manager |
| classroom.profiles(role instructor) | 대체 | nomad_core.memberships editor + course_instructors 배정 | 배정 과정만 instructor |
| (없음) | 신규 | memberships viewer + course_instructors 배정 | observer(참관): 과정 구조만, 학생 정보·정답 없음 |
| is_org_admin · is_org_member · is_course_admin · is_course_member · quiz_course · survey_course | 대체 | course_role(과정) · can_read_private · can_write(과정, 기능) · is_org_manager · is_teacher_survey | 하위 표에 course_id 를 직접 두어 quiz_course·survey_course 불필요 |
| try_uuid | 대체 | storage_course_role(경로) | 경로 조직 = 과정 조직일 때만 역할 반환 |
| guard_course_update(0007) | 이관 | 같은 이름(security definer) | 강사 규칙 그대로 + 평가 시각 변경에 기능 pre_post_assessment(CL001) |

## 테이블 (classroom → nomad_classroom, 12 → 10, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 컬럼 변화 |
|---|---|---|---|---|
| organizations | 삭제(core 대체) | — | — | — |
| profiles | 삭제(core 대체) | — | 웹(teacher/auth.ts) | 역할은 memberships, 이름은 nomad_core.profiles |
| courses | 이관 | 같은 이름 | 웹 · 서버 | org_id → organization_id, overview·pre_eval_from 합침. 삭제는 서버만(원본과 같음) |
| course_instructors | 이관 | 같은 이름 | 웹 | + organization_id, profile_id → user_id(memberships 복합 FK) |
| course_days | 이관 | 같은 이름 | 웹 · 서버 | + organization_id, detail 합침 |
| materials | 이관 | 같은 이름 | 웹 · 서버 | + organization_id, quiz_id·bundle 합침, storage_path CHECK |
| student_codes | 이관(발급은 RPC) | 같은 이름 | 웹 · 서버(입장 시각) | + organization_id, first/last_entered_at 합침(사용자 grant 없음). 사용자 insert 권한 없음 → `issue_student_codes(과정, 이름[], 유효기간)` 이 난수 발급 |
| quizzes | 이관(quiz_bank) | 같은 이름 | 웹 · 서버 | + organization_id |
| quiz_questions | 이관(quiz_bank, 정답) | 같은 이름 | 웹(결과) · 서버 | + organization_id, course_id |
| quiz_attempts | 이관(서버 쓰기, pre_post_assessment) | 같은 이름 | 웹 읽기 · 서버(upsert) | + organization_id, course_id(코드·퀴즈 같은 과정 복합 FK) |
| surveys | 이관 | 같은 이름 | 웹 · 서버 | + organization_id |
| survey_responses | 이관 | 같은 이름 | 웹(강사 응답) · 서버(학생 응답) | + organization_id, course_id, profile_id → auth.users |

## 역할별 노출 (학생 개인정보 최소 노출)
| 표 | manager(owner·admin) | instructor(배정 editor) | observer(배정 viewer) | 미배정 멤버 · 다른 조직 · anon |
|---|---|---|---|---|
| courses · course_days · quizzes · surveys | 읽기·쓰기(퀴즈는 quiz_bank) | 읽기, courses 는 평가 시작 시각만 | 읽기 | 0 |
| materials(+ Storage 파일) | 읽기·쓰기 | 읽기 | 교사용(audience teacher)·연습풀이(bundle solution) 제외 읽기 | 0 |
| student_codes · quiz_attempts · quiz_questions(정답) | 읽기(+코드 RPC 발급·수정, 문항 쓰기) | 읽기 | 0 | 0 |
| survey_responses | 전부 읽기 | 학생 응답 + 본인 응답, teacher 설문 본인 1회 쓰기 | 0 | 0 |
| course_instructors | 읽기·쓰기 | 본인 배정 | 본인 배정 | 0 |

## 플랜 기능 (청사진 카탈로그와 같은 값, 수치 한도 없음)
| 기능 | A / B / C | DB 강제 위치 |
|---|---|---|
| course_core(과정·일차·자료·코드·설문) | O / O / O | 모든 정책(course_role) |
| quiz_bank(퀴즈·문항 쓰기) | O / O / — | quizzes·quiz_questions 쓰기 정책 |
| pre_post_assessment(평가 시작·응시 기록) | O / — / — | guard_course_update · guard_attempt 트리거(CL001, 서버 포함) |
- 구독 끊김(없음·inactive·만료 = C): 퀴즈·문항 쓰기와 평가 시작·응시 기록이 잠기고, 기존 퀴즈·문항·응시 기록 읽기는 유지(검사 8절). 조직 비활성은 전부 0.

## 버킷 · 경로 규칙
- `course-materials` → `classroom-materials`(비공개, 50MB, MIME 제한 없음 — 원본과 같음).
- 경로: `<organization_id>/classroom/<course_id>/<uuid>.<확장자 소문자 1~10자>`. 원본 `{course_id}/<uuid>.<ext>` 앞에 조직·제품 접두가 붙는다.
- materials.storage_path CHECK 가 자기 행의 조직·과정 접두만 받는다(`..`·다른 조직 거부). Storage 정책: 읽기 = 그 과정 역할(manager·instructor, observer 는 교사용·풀이 자료 행이 가리키는 파일 제외), 올리기·지우기 = manager. update 정책 없음(upsert:false).
- 학생 파일은 지금처럼 서버가 service_role 로 내려받아 중계한다.

## 앱 변경
- 스키마 `classroom` → `nomad_classroom`(클라이언트 `db.schema`·노출 스키마 설정). 버킷 `course-materials` → `classroom-materials`, 업로드 경로 `${orgId}/classroom/${courseId}/${uuid}${ext}`(materials/upload/route.ts).
- 학생 코드 발급(teacher/actions.ts:223 `student_codes.insert(rows)`) → `rpc('issue_student_codes', {p_course, p_labels})`. 앱이 코드를 만들지 않는다(전역 PK 라 직접 지정하면 남의 조직 코드 존재가 드러남).
- 모든 insert 에 `organization_id` 를 함께 보낸다(과정의 조직). quiz_questions·quiz_attempts·survey_responses 는 `course_id` 도. 사용자 insert 에 `id` 를 넣지 않는다.
- teacher/auth.ts: `profiles` 대신 `nomad_core.my_organizations()` 역할 + `course_role(course_id)`. 강사 이름은 nomad_core.profiles.display_name.
- course_instructors.profile_id → user_id. survey_responses.profile_id 는 그대로(auth.users id).
- 서버(student/session.ts 입장 시각, quiz.ts upsert): 구독 끊김이면 응시 기록 저장이 CL001 → "평가 잠김" 안내로 처리.
- 원본 데이터 이관: organizations → nomad_core.organizations + subscriptions(classroom, A), profiles → memberships(admin→admin 또는 owner 1명, instructor→editor), storage 객체를 새 경로로 복사 후 storage_path 갱신(서버 스크립트, 이 저장소 밖).

## 팀장 확인 필요
1. 플랜 대응: 원본 basic → A, C = course_core 만(무료로 과정 운영 가능). 무료 범위를 더 좁힐지(예: course_core 도 유료) 결정.
2. viewer = 참관(observer) 역할은 원본에 없던 신규 해석. 미배정 editor 는 아무 과정도 못 본다(원본 강사와 같음) — 조직 전체 열람 역할이 필요한지.
3. 청사진(sessions·enrollments·assessments·quiz_items, 수강생 = 계정)과 원본(학생 코드, 계정 없음)이 다르다. 이식본은 원본을 따랐다 — 청사진 문서 갱신 여부.
4. B 플랜은 quiz_bank 는 있으나 pre_post_assessment 가 없어 학생이 응시할 수 없다(원본은 평가 시작 전 퀴즈 잠금). B 에 평가를 열지 결정.
5. 버킷 MIME 제한 없음(원본 동일, CAD 파일 형식 다양). 필요하면 허용 목록 확정.
