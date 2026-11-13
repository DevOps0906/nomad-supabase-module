# task-008 격리형 hospital 확정 마이그레이션 — 보류

> 2026-11-13 사용자 결정: 병원만 격리. school은 platform-docs(sms, 1700)처럼 조직형으로 task-009 이식 대상.
> 보류 사유(challenger REVISE): 사람 결정 필요 — ① 앱 접근 경로(브라우저 직접 vs 서버 service_role: RLS·감사·암호화가 전부 달라짐) ② 이름·전화 검색용 해시 허용 여부 ③ 첫 admin 부트스트랩 ④ 의료기록 보존 기간.
> 해결해야 할 🔴: staff·auth 삭제 cascade가 진료기록을 지움(restrict로) · appointments 기반 담당 판정의 자가 배정·간호사 누락 · records select 차단과 insert…returning/update 충돌(읽기·쓰기·목록 경로 설계).
> 🟡: rules/blueprints.md(격리형은 설계 문서만)와 위치 충돌 · `current_role` 예약어 · definer 함수 EXECUTE revoke · 감사 로그 actor 보존 · 테스트는 isolated/<slug>에서 실제 db reset.
> 참고: platform-docs/products/admin-suite(hms 별도 DB 설계)도 근거에 추가.


- 위험도: 높음 (의료·학생 개인정보 · RLS · 감사 로그) · 선행: task-004 (task-005·006과 파일이 겹치지 않아 병렬)
- 근거: blueprints/isolated/{hospital,school}/(README.md#접근 규칙 · schema.draft.sql), docs/design/01-architecture/supabase-layout.md(격리형: 별도 프로젝트·자체 인증·Pro+백업+감사 로그), tasks/task-002-blueprint-migrations.md#변환 규칙(공통 규칙 재사용)
- 결정(사용자 2026-11-13): 격리형 2개를 지금 확정한다(병렬 진행).

## 위치 (공용 프로젝트와 분리)
- `isolated/<slug>/supabase/migrations/20261118000100_<slug>.sql` — 서비스마다 독립 Supabase 프로젝트 폴더. `nomad_core` 참조 없음, 공용 `supabase/migrations/`·install-db.sh는 건드리지 않는다.
- 테스트 `isolated/<slug>/tests/access.sql` — 로컬 공용 DB에 트랜잭션으로 적용→검증→rollback (별도 스택 없이 실행).

## 설계 초안 (challenger가 공격할 대상)
1. task-002 변환 규칙 1·3·4·6·7·8·9를 그대로 쓰되 조직 대신 **역할 테이블**: hospital `staff(user_id, role in ('doctor','nurse','reception','admin'))`, school `teachers(user_id, role in ('homeroom','subject','admin'))` + `guardians(user_id)`.
2. 역할 판정 함수 `<schema>.current_role()`·담당 관계 함수(`is_assigned_patient(patient_id)`, `teaches_class(class_id)`, `is_guardian_of(student_id)`)는 `security definer` + `set search_path = ''` + `stable`. RLS 재귀 방지용.
3. 접근: 의사·간호 = 담당 환자의 records(담당 = appointments의 staff_id) · 접수 = patients 기본 정보·appointments만, records 불가 · admin = staff 관리. 교사 = 담당 학급 학생·출결·성적 · 학부모 = 본인 자녀 select만.
4. 감사: hospital `audit_logs`, school `grade_logs`(성적 변경). 쓰기는 트리거(security definer)만, authenticated는 insert/update/delete 불가, select는 admin만. records의 select 감사는 DB로 못 잡으므로 열람 기록은 RPC `read_record(id)` 경유로만 열고 테이블 직접 select는 막는다(검토 대상).
5. 암호화: DB 키로 컬럼 암호화는 하지 않는다(키가 같은 DB에 있으면 의미 없음). 주민번호 등 고유식별정보는 컬럼을 두지 않거나 앱 측 암호문(text)만 저장 — 문서에 명시.

## 완료 조건
- 두 파일이 빈 Postgres(로컬 DB의 트랜잭션)에 적용되고 `isolated/<slug>/tests/access.sql` 통과: 역할별 허용·거부, 담당 외 환자/학생 거부, 감사 로그 직접 쓰기 거부·트리거 기록, anon 전면 거부
- 기존 공용 테스트 5개 영향 없음
- blueprints/registry.yaml status `migrated`, docs/INTEGRATION.md에 격리형 설치 절 한 단락
- codex-reviewer(code) + reviewer(security)

## 하지 않을 것
- 공용 프로젝트·nomad_core 연결, 플랜·기능 잠금(계약/납품형), 실제 환자·학생 데이터, 키 관리 구현
