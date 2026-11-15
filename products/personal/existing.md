# personal(꿈해몽·사주·여행) 기존 DB → nomad_personal 이식 대응표 (task-015)

원본(기존): 연결된 레포 없음(`blueprints/user/personal/blueprint.yaml` repos 비어 있음) → 저장소 청사진 `supabase/migrations/20261115000111_personal.sql`(5표) + `20261116000111_personal.sql`(플랜·기능·잠금)을 "기존"으로 본다. 앱 코드가 없어 사용처는 청사진 README 기준 추정이다.
이식(D5: user 제안 제품 → 두 안 모두): `user/0001_personal.sql`(개인형) · `org/0001_personal.sql`(조직형). 스키마 `nomad_personal`(노출, anon 접근 0 — 공개 RPC 없음).
같은 스키마 이름이라 검사는 트랜잭션 안에서 청사진을 drop 한 뒤 적용한다(flora 방식). 검증: `bash products/personal/run_check.sh` (인자 없으면 user·org 둘 다, 항상 rollback, 둘 다 통과).
사용처 약어: 웹=웹 앱(authenticated, RLS 직접 읽기·쓰기) · 서버=AI 풀이·PDF 생성 서버(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| nomad_core.products('personal') · plans C/B/A · features 3 · plan_features | 유지 | 같은 행(on conflict do nothing) | divination=C·B·A, report_save·trip_planner=B·A(청사진 그대로) |
| auth.uid() = user_id | 대체 | user안 `nomad_personal.has_access(user_id, 기능)` / org안 `created_by·user_id = auth.uid()` + `nomad_core.has_feature(조직, 'personal', 기능)` | user안 판정은 개인 조직의 `org_has_feature`(astro와 같음, user_has_feature 미사용) |
| user_has_feature 잠금(insert·update만) | 대체 | select·insert·update·delete 모두 잠금 | 사용자 결정 "구독 끊기면 잠김(개인정보 삭제 예외)" → 삭제는 RPC |

## 테이블 (5개, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org | 기능 |
|---|---|---|---|---|---|
| readings | 이관(+updated_at, input_json → input_ciphertext·key_version 암호문) | nomad_personal.readings | 웹(풀이 기록) · 서버(AI 결과, 입력 암·복호화) | user_id → organization_id + created_by. **작성자만 열람**(owner/admin도 못 봄) | divination |
| saved_reports | 이관 | nomad_personal.saved_reports | 웹 · 서버(PDF) | 같음. 복합 FK가 같은 조직·같은 작성자의 풀이만 허용. pdf_path 접두 `<user_id>/personal/` · `<organization_id>/personal/<created_by>/`, org안 pdf_path는 서버만 기록(사용자 권한 없음) | report_save |
| birth_profiles | 이관(+updated_at, birth_date·birth_time → birth_ciphertext·key_version 암호문, 쓰기 서버만) | nomad_personal.birth_profiles | 웹(읽기·삭제) · 서버(암·복호화·쓰기) | PK user_id → (organization_id, user_id). 본인만 | divination |
| trips | 이관(+updated_at, 날짜 역전 CHECK) | nomad_personal.trips | 웹(여행 일정) | user_id → organization_id + created_by. **조직 공유**: 멤버 읽기, owner/admin/editor 쓰기 | trip_planner |
| trip_days | 이관(+소유 컬럼, +updated_at) | nomad_personal.trip_days | 웹 | 원본은 소유 컬럼 없음(부모 조인 정책) → user_id / organization_id + 복합 FK (소유, trip_id). trip_id not null | trip_planner |
- 사용자 컬럼 권한: 암호문 컬럼(birth_ciphertext·input_ciphertext)은 select·insert·update 모두 없음(birth_profiles는 사용자 쓰기 없음, 읽기·삭제만). id·소유·작성자(기본값 auth.uid())·시각 컬럼은 insert·update 권한 없음, 조직·부모 참조(organization_id·trip_id·reading_id)는 insert만. org안 saved_reports.pdf_path는 권한 없음(서버가 PDF 생성 후 기록).
- 동기화 컬럼: updated_at(touch 트리거) + (소유, updated_at) 인덱스 — readings·birth_profiles·trips·trip_days. 소프트 삭제 없음(개인정보는 물리 삭제).

## 함수
| 이름 | 안 | 분류 | 사용처 | 비고 |
|---|---|---|---|---|
| has_access(user, feature) | user | 신규(정책 도우미, authenticated) | 정책 | 본인 + 개인 조직 이용권 |
| personal_organization(user) | user | 신규(내부, 실행 권한 없음) | has_access | — |
| erase_my_data() | user | 신규(authenticated) | 웹 "내 데이터 삭제" | 잠김과 무관, 본인 5표 전부 삭제, 지운 리포트의 pdf_path 목록 반환 |
| erase_personal_data(org, user default 본인) | org | 신규(authenticated·service_role) | 웹 "내 데이터 삭제"·관리자 탈퇴자 정리 | 민감 3표만(여행 제외). 본인은 탈퇴 후에도 가능, 남의 것은 활성 조직 owner/admin이 탈퇴자(비멤버)만 — 현직 멤버·권한 없음은 42501. 서버는 대상 지정 필수(22023). 남의 것 삭제는 감사 `personal.erase`(metadata `{"result":"erased"}`, 행 수 없음). 지운 리포트의 pdf_path 목록 반환 |

- 삭제 절차: 웹이 삭제 RPC를 부르고 → 반환된 pdf_path 목록을 서버(service_role)에 넘겨 스토리지 파일을 지운다(DB 행은 이미 삭제됨, 파일 삭제 실패는 서버가 재시도).

## astro(신비로운AI)와 겹치는 부분 (D4: 흡수하지 않고 별도 제품, 서로 참조하지 않음)
| 영역 | personal | astro | 차이 |
|---|---|---|---|
| 사주·타로 풀이 | readings(kind dream·saju·tarot, input_json·result_md) | readings(saju·tarot·combined, 상태 전이·크레딧·작업) | personal은 단순 기록(웹이 직접 씀), astro는 크레딧 과금·작업 큐·PDF 렌더 파이프라인 |
| 생년월일 | birth_profiles(앱 계층 암호문, 사용자당 1행) | subjects(앱 계층 암호문, 본인·가족·지인 여러 명, 제3자 동의) | 같은 방식(task-018). personal은 형식 CHECK 추가 |
| PDF | saved_reports.pdf_path | reading_renders(테마·렌더 이력·발송) | — |
| 꿈해몽·여행 | 있음 | 없음 | personal만 |
| 기능·플랜 | divination(C) · report_save·trip_planner(B·A) | reading(A·B·C) + AI 기능 | 같은 사용자가 두 제품을 쓰면 생년월일을 두 번 입력 |

## 암호화 (task-018, 2026-11-16 사용자 결정 — astro 방식): 입력 암호화, 결과 평문(재수록 금지 계약)
| 항목 | 내용 |
|---|---|
| 대상 | birth_profiles.birth_ciphertext(생년월일·출생시각·필요 시 출생지, not null) · readings.input_ciphertext(풀이 입력 JSON, 없으면 null). 풀이 결과 result_md·성별·kind는 평문 |
| 누가 | 앱 서버(service_role)만 암·복호화하고 쓴다. 웹은 원문을 서버 API로 보내고, DB에서는 암호문 컬럼을 읽을 수 없다(권한 없음) |
| 방식 | AES-256-GCM, 행마다 새 iv. 저장 형식 base64(iv 12바이트 ‖ 암호문 ‖ 태그 16바이트) = 최소 40자·4의 배수. 형식 CHECK(23514)는 날짜·JSON 원형만 거부한다 — 실제 암호화 여부는 DB가 못 보므로 방어선은 서버 암·복호화 왕복 테스트 |
| AAD | 암호문을 다른 행·열로 옮겨 붙이지 못하게 AAD에 소유자 id·행 id·열 이름을 넣는다. birth_profiles: user안 `user_id`, org안 `organization_id`+`user_id`(행 키), 열 `birth_ciphertext`. readings: user안 `user_id`+`id`, org안 `organization_id`+`created_by`+`id`, 열 `input_ciphertext` → 서버는 id를 먼저 정하고(service_role이 id 지정 insert) 암호화한다 |
| 재수록 금지 | 서버는 result_md·PDF(saved_reports)에 생년월일·사주 원국 입력을 다시 싣지 않는다. 결과는 평문이므로 입력을 옮겨 적으면 암호화가 무의미해진다(앱 계약, DB가 막지 못함) |
| 키 위치 | 앱 서버 비밀 저장소(배포 환경변수·KMS). DB·저장소·클라이언트에 두지 않는다. 키 백업은 비밀 관리 도구의 별도 보관(DB 백업과 다른 위치·권한), 절차 `docs/BACKUP_RESTORE.md` "앱 데이터 암호화 키" |
| 키 교체 | key_version(>0) N으로 새 키 사용 → 옛 버전 행은 서버가 다시 암호화. 완료 확인: `select (select count(*) from nomad_personal.birth_profiles where key_version < N) + (select count(*) from nomad_personal.readings where key_version < N);` = 0. 옛 키는 0이 된 뒤에도 최소 DB 백업 보존 기간만큼 보존(옛 백업 복구용) 후 폐기 |
| 앱 변경 | 열 단위 select 권한이라 웹의 `select *`·`returning *`(supabase-js `.select()` 인자 없음 포함)는 권한 오류 → 열을 명시한다(readings: id·kind·key_version·result_md·시각, birth_profiles: user_id·key_version·gender·updated_at) |
| 검사 | `run_check.sh` user·org: 평문 컬럼 부재, 암호문 컬럼 authenticated 권한 0, 형식 CHECK·key_version 필수 거부 |

## 교훈 반영
core 표 직접 쓰기·트리거 없음(감사는 write_audit) · 참조 조직 일치(복합 FK) · 사용자 경로 조직(소유) 접두 CHECK · 사용자 insert에 id 권한 없음 · 구독 끊김 = 잠김, 개인정보 삭제만 예외(RPC) · 공개분 없음(anon 0) · 수치 한도 키 없음 · definer 함수는 set search_path = '' 이고 행을 반환하지 않음(삭제 행 수만).
해당 없음: 결과 저장 잡(jobs·mark_job_delivered) — 기존에 작업·크레딧 연결이 없다(확인 3) · 결제 이벤트 · 공개 읽기 RPC · BEFORE 검사 트리거(touch만).

## 팀장 확인 필요
1. 평문 저장 → task-018: 입력 암호화, 결과 평문(재수록 금지 계약 — 위 "암호화" 장, 사용자 결정). 남은 확인: 사용자 직접 쓰기는 readings(kind·result_md)만 남았다 — 입력이 서버 경유가 되므로 readings 쓰기도 서버 전용으로 할지(확인 3과 함께).
2. org안 민감 표를 작성자만 열람하게 했다(owner/admin은 열람 불가, erase로 탈퇴자 것만 삭제). 여행은 조직 공유. 범위가 맞는지.
3. AI 풀이 결과(result_md)를 사용자가 직접 쓴다(청사진 그대로). 서버 작업(nomad_core.jobs)·크레딧 과금으로 바꿀지 — 바꾸면 결과 저장 교훈(실패 잡 거부·mark_job_delivered) 적용 필요.
4. org안 viewer도 본인 풀이·생년월일은 쓸 수 있다(개인 자료). 여행은 viewer 읽기만.
5. user안 erase_my_data는 감사 기록을 남기지 않는다(본인 요청, 개인 조직이 비활성일 수 있음).
