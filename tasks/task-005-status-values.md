# task-005 보류 상태·종류 컬럼 값 목록 확정

- 위험도: 높음 (마이그레이션 · 설치된 DB의 기존 행) · 선행: task-004
- 근거: tasks/task-002-blueprint-migrations.md#변환 규칙 3 ("주석 없는 상태 컬럼은 text 그대로 두고 보고"), 같은 파일 #리뷰 반영 결정(knowflow.messages.role)
- 결정(사용자 2026-11-13): 아래 값 목록 그대로. `baedal.stores.category`는 업종명이라 자유 텍스트 유지.

## 대상 (첫 값 = 기본값, 단 blog_members.role 기본값은 editor · knowflow.messages.role은 기본값 없음)
| 컬럼 | 값 | 한국어 뜻(comment) |
|---|---|---|
| nomad_contentflow.blog_members.role | owner·editor·viewer (기본 editor) | 블로그 소유자·편집자·열람자 |
| nomad_flora.pipeline_runs.status | queued·running·succeeded·failed·cancelled | 대기·실행 중·성공·실패·취소 |
| nomad_knowflow.messages.role | user·assistant | 사용자·AI 응답 |
| nomad_classroom.materials.kind | document·video·link·image | 문서·영상·링크·이미지 |
| nomad_sceneflow.edit_jobs.kind | cut·subtitle·render | 컷 편집·자막·렌더링 |
| nomad_sceneflow.edit_jobs.status | queued·running·succeeded·failed·cancelled | (위와 같음) |
| nomad_commerce.automation_jobs.status | queued·running·succeeded·failed·cancelled | (위와 같음) |
| nomad_commerce.orders.status | pending·paid·shipped·delivered·cancelled·refunded | 결제 대기·결제 완료·배송 중·배송 완료·취소·환불 |

## 파일 (설치기 패턴: 제품별 파일 — task-004와 같음)
- `supabase/migrations/2026111700010N_<slug>.sql` — 대상 제품 6개만(01 contentflow · 02 flora · 03 knowflow · 04 classroom · 06 sceneflow · 07 commerce). 각 `begin; … commit;` + 되돌림 메모.
- 컬럼마다: 사전 점검 → `set default`(messages.role 제외) → `set not null` → `add constraint <table>_<col>_check check (... in (...))` → `comment on column`.

## challenger 반영 결정 (2026-11-13)
- **기존 데이터는 바꾸지 않는다**(update 백필 금지 · `not valid` 금지). 각 파일 맨 앞 `do $$ … $$` 블록에서 대상 컬럼마다 null 또는 목록 밖 값이 있으면 `raise exception`(메시지: 테이블.컬럼, 위반 값 목록·건수, "docs/INTEGRATION.md 사전 점검 참조"). 이유: null을 queued/pending으로 채우면 끝난 작업·결제가 다시 돌 수 있고, 원래 값은 복구 불가.
- knowflow.messages.role: 기본값 없음(not null + check만). tests/services_access.sql의 role 생략 insert 거부 기대(약 521행)를 그대로 유지.
- blog_members.role 기본 editor 유지(사용자 결정). DB 권한 상승 없음(쓰기는 org owner·admin만). role 생략 insert가 editor가 되는 것을 테스트로 고정.
- docs/INTEGRATION.md에 절 추가: 적용 전 위반 행 점검 SQL(컬럼별 null·목록 밖 값 집계), 실패 시 부분 적용 상태(파일 단위 원자성, 앞 제품만 적용될 수 있음)와 정리 후 재실행 절차, 큰 테이블은 ACCESS EXCLUSIVE 잠금이므로 한가한 시간대 적용 안내.

## 완료 조건
- `npx supabase db reset --local` 성공, 기존 테스트 5개(tenant_access·accounts·services_access·feature_gating·install_db) 통과
- `tests/services_access.sql`에 추가: 컬럼마다 목록 밖 값 거부 · 명시적 null 거부 · 값 생략 시 기본값(messages.role 제외, blog_members는 editor) — 최소 컬럼별 1건
- 사전 점검 검증: 마이그레이션 적용 전 상태에 null 행이 있으면 새 파일이 실패하는지 1건 확인(방법은 builder 재량, 결과를 보고)
- `tests/install_db.sh`: `--product contentflow` 부분 설치 시 contentflow 파일 3개(+core)가 복사되고 다른 제품 새 파일은 없음
- docs/INTEGRATION.md 새 절
- codex-reviewer(code) + reviewer(contract)

## 하지 않을 것
- 기존 마이그레이션 수정, 컬럼 추가·삭제·이름 변경, RLS 정책·grant 변경, baedal.stores.category, 수량 한도·크레딧
