# hospital 격리형 DB 대응표 (task-008, 2026-11-15 결정)

원본: `blueprints/isolated/hospital/schema.draft.sql`(표 5개 초안) + 참고 `D:\WorkSpace\DEV\platform-docs\products\admin-suite\supabase\monolith\hms\migrations\0002_hms_domain.sql`(append-only 트리거·열람 사유 검사만 차용. 검사·수납·처방·근무표 표는 CRM 범위 밖이라 이식 안 함).
이식: `isolated/0001_hospital.sql` — 스키마 `nomad_hospital` 하나. **별도 Supabase 프로젝트 전용**, 공용 프로젝트 스키마·플랜·기능 잠금 연결 없음(참조는 `auth.users`·`vault`·`extensions.hmac` 만).
검증: `bash products/hospital/run_check.sh` (공용 스키마 문자열 grep 0 → begin → 0001 → `check_isolated.sql` → rollback, 로컬 공용 DB 트랜잭션 안에서). 사용처 약어: 서버=앱 서버(service_role, 직원 로그인은 앱이 확인 후 p_actor 로 전달), 설치=설치 스크립트(service_role 1회).

## 접근 경로 (결정 ①·행위자)
| 역할 | 스키마 | 표·시퀀스 | 함수 |
|---|---|---|---|
| anon · authenticated | 권한 없음 | 0 | 0 |
| service_role | usage | 0 (직접 select·insert·update·delete·truncate 모두 거부) | API 19개 EXECUTE 만 (내부 `_*`·트리거 함수 0. 검사가 실행 가능 함수 = API 목록 정확 일치 확인) |
| API 함수 | security definer · `search_path = ''` | — | 첫 인자 `p_actor`: 없음·null·비활성 → HP001, 역할 밖 → 42501 |

## 테이블 (초안 5 → 9, 모든 FK `on delete restrict`)
| 원래 이름 | 분류 | 새 이름 | 쓰기 | 읽기 |
|---|---|---|---|---|
| staff(user_id, role, dept) | 이관(+display_name·active·deactivated_at) | staff | 관리자(add_staff·deactivate_staff) · 설치(bootstrap_admin) | 관리자(list_staff) |
| — | 신규 | bootstrap_state(단일 행) | bootstrap_admin(advisory 잠금) | 없음 |
| patients(name·birth·phone_enc, consent_at) | 이관(+name_hash·phone_hash·hash_key_version·created_by) | patients | 접수·관리자(register_patient) | 접수·관리자 전체, 의사·간호 담당만 |
| — (담당 = appointments.staff_id 안 폐기) | 신규 | care_assignments | 관리자만(assign_care·end_care) → 자가 배정 불가, 간호사 포함 | 함수 내부 판정 |
| appointments(patient, staff, at, status) | 이관(at→scheduled_at, status check) | appointments | 접수·관리자 | 접수·관리자 전체, 의사·간호 담당만 |
| — | 신규(CRM 연락) | contact_logs (append-only) | 접수·관리자·담당 의료진 | 같은 범위 |
| records(note_enc) | 이관(이름 변경, append-only, 정정은 amends_id 새 행) | consult_notes | 담당 의사·간호사 | 담당 의사·간호사만(접수·관리자 본문 접근 없음) |
| audit_logs(actor_id FK auth) | 이관(FK 제거, 행위자 이름·역할 스냅샷, purpose·row_count·detail) | audit_logs (append-only + TRUNCATE 차단) | 함수 내부 `_audit` 만 | 관리자(list_audit_logs, 열람도 감사) |
| — | 신규 | retention_policies | 마이그레이션만 | 함수 내부 |

## 보존 기간 (법무 확인 필요 — 확정 전 초안)
| 기록 종류 | 보존 | 근거(초안) | 파기 |
|---|---|---|---|
| consult_note(상담·진료 메모) | 10년 | 의료법 시행규칙 제15조 진료기록부 10년 준용. 간호 메모를 간호기록부(5년)로 볼지 **법무 확인 필요** | 기간 후 purge_record |
| appointment(예약) | 5년 | 같은 조 환자 명부 5년 준용 — **법무 확인 필요** | 기간 후 purge_record |
| contact_log(연락 기록) | 3년 | 개인정보 보호법 제21조(목적 달성 후 파기) 내부 기준 — **법무 확인 필요** | 기간 후 purge_record |
| patients(환자 기본 정보) | — | 환자 명부 5년 준용 예상 — **법무 확인 필요** | 이 파일에 파기 함수 없음(후속) |
| audit_logs(접속·처리 기록) | 영구(삭제 경로 없음) | 개인정보의 안전성 확보조치 기준 접속기록 1~2년 이상 — **법무 확인 필요** | 없음(파기 스위치도 무시) |
- 기간 = `created_at + retain_years`. 자동 삭제 없음: `list_purge_candidates`(관리자, 감사) → 사람이 확인 → `purge_record(kind, id, 사유)`. `legal_review_pending = true`(기본, 법무 확인 전)면 기간이 지나도 HP005(fail-closed), 기간 전이면 HP003, 사유 2자 미만 22023. 법무 확인 후 새 마이그레이션으로 false 로 바꾼다.
- 파기는 트랜잭션 로컬 `nomad_hospital.allow_purge` 스위치를 켠 함수 안에서만 append-only 트리거를 통과하고, 감사 행(`purge.record`, 사유·원래 작성 시각)을 남긴다. 정정본(amends_id)이 가리키는 원본은 정정본보다 먼저 지울 수 없다(restrict).

## 함수 (service_role EXECUTE, 전부 p_actor 확인)
| 함수 | 허용 역할 | 감사 action |
|---|---|---|
| bootstrap_admin(user_id, 이름) | 설치 1회(staff·bootstrap_state 있으면 HP004) | staff.bootstrap |
| add_staff · deactivate_staff(자기 자신 불가, 담당 자동 종료) · list_staff | admin | staff.add · staff.deactivate |
| assign_care · end_care | admin | care.assign · care.end |
| register_patient(평문 이름·전화는 해시용, 암호문 3개) | reception · admin | patient.register |
| search_patients(이름·전화 정확 일치, 사유 → id·등록일만, 감사 detail 에 반환 id 배열) · get_patient(사유 → 암호문) | 전 역할(의사·간호 담당만) | patient.search · patient.view |
| create_appointment · set_appointment_status | reception · admin | appointment.create · appointment.status |
| list_appointments(기간, 사유) | 전 역할(의사·간호 담당만) | appointment.list |
| add_contact_log · list_contact_logs(사유) | 전 역할(의사·간호 담당만) | contact.add · contact.list |
| add_consult_note(amends_id 선택) · list_consult_notes(사유) | doctor · nurse(담당만) | note.add · note.list |
| list_purge_candidates · purge_record · list_audit_logs | admin | purge.candidates · purge.record · audit.list |
- 열람 사유(purpose): `treatment` · `reception` · `admin_review` · `patient_request` 외 22023. 열람 함수는 VOLATILE, 호출마다 감사 1행(결과 행 수 기록).

## HMAC 검색 (결정 ②)
- 키: Vault 비밀 이름 `nomad_hospital_hmac_v<N>`, 가장 큰 N 이 현재 키. 없으면 등록·검색 모두 HP002(fail-closed). 저장소·시드에 키 없음.
- 정규화: 전화 = 숫자만, 국가번호(`+82`·`82`·`(+82)`·`0082`) → `0`, 앞자리 0 반복은 하나로(`+82 010…` → `010…`) · 이름 = NFKC + 소문자 + 공백·폭 없는 문자(U+200B~200D·2060·FEFF) 제거. 값은 `종류:정규화값` 을 HMAC-SHA256(hex). 오류 문구에 평문 인자를 넣지 않는다(검사로 확인).
- 검색은 정확 일치만(부분 검색 없음), 현재 key_version 행만 찾는다. 키 교체 시 앱이 평문을 다시 보내 재해시해야 함(재해시 함수는 후속).

## 앱 계약
- 앱 서버만 DB 에 접근한다(service_role). 브라우저용 anon 키로 이 스키마를 부르는 코드는 두지 않는다. PostgREST RPC 를 쓰면 프로젝트 API 설정의 노출 스키마에 `nomad_hospital` 추가, 아니면 서버의 직접 Postgres 연결.
- 직원 인증은 이 프로젝트의 Supabase Auth. 앱 서버가 세션을 검증한 user_id 를 `p_actor` 로 넘긴다(클라이언트가 보낸 값 그대로 금지). DB 는 활성·역할·담당만 다시 확인한다.
- 이름·전화·생년월일·메모·연락 요약은 앱이 암호화한 암호문(`*_enc`)만 보낸다. 해시용 평문 이름·전화는 register_patient·search_patients 인자로만 전달하고 로그에 남기지 않는다. 주민등록번호는 수집하지 않는다.
- 거부 기록 의무: HP001·42501 거부는 DB 트랜잭션과 함께 rollback 되어 감사 로그에 남지 않으므로, 앱 서버가 자체 로그에 행위자·함수·시각·SQLSTATE 를 반드시 남긴다(평문 인자 제외).
- RPC 당 autocommit: API 함수 호출은 각각 독립 트랜잭션으로 커밋한다. 열람 뒤 트랜잭션을 rollback 해 감사 행을 지우는 사용(명시적 begin … rollback 으로 감싸기)은 금지.
- 파라미터 바인딩 필수: 평문 이름·전화를 SQL 문자열 리터럴로 조립하지 않는다(DB·풀러 쿼리 로그에 평문이 남음). 드라이버 바인딩 또는 PostgREST RPC 본문으로만 전달한다.
- 퇴사: `deactivate_staff`(담당 배정도 함께 종료). Auth 사용자 삭제(deleteUser)는 staff FK restrict 로 실패한다 — 계정 차단은 Auth ban 으로.
- 설치: 마이그레이션 적용 → Vault 에 `nomad_hospital_hmac_v1` 생성 → `bootstrap_admin` 1회(service_role). 이후 관리자 추가는 add_staff.
- 오류 코드: HP001 행위자 · HP002 HMAC 키 · HP003 보존 기간 전 · HP004 bootstrap 완료 · HP005 보존 기간 법무 확인 전 · 42501 권한·담당·append-only · 22023 입력·사유 · 23503 restrict.

## 팀장 확인 필요
1. 보존 기간 3종·근거 조문은 초안(법무 확인 전). 환자 기본 정보 파기·감사 로그 보존 상한은 이 파일 범위 밖.
2. 관리자는 상담 메모 본문을 볼 수 없게 했다(hms 원칙). 원장 겸 의사는 doctor 역할 계정을 따로 써야 함.
3. 위치 `products/hospital/isolated/`. 대시보드·task-008 위치 문구 갱신은 후속(결정대로).
