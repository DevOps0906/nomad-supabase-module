# task-007 knowflow 대화·업로드를 기능 이용권에 연결 (쿼터 유지)

- 위험도: 높음(기능 잠금·과금) · 선행: task-004, task-012 · 담당: builder → reviewer(security)
- 결정(2026-11-16 사용자): 자체 월간 쿼터(org_quotas·consume_quota_for)는 유지한다. core 크레딧 원장으로 바꾸지 않는다.
- 근거: products/knowflow/{user,org}/0001_knowflow.sql(쿼터·멱등 키·enqueue_job), tests/feature_gating.sql, tasks/NOW.md 교훈

## 할 일
- 대화(messages 생성)·소스 등록(PDF·YouTube)·재시도 경로가 모두 `org_has_feature('knowflow', 기능)` 잠금을 거친다(구독 끊기면 쓰기 잠금, 읽기 유지).
- 쿼터 차감은 요청 멱등 키로 한 번만, 실패 잡은 환불(이미 있으면 검사로 고정).
- 쿼터 수치는 plan_limits 키, 키 없으면 fail-closed.

## 완료 조건
- `bash products/knowflow/run_check.sh` PASS(user·org), 잠김 상태에서 대화·등록·재시도 거부와 읽기 유지 검사, 같은 멱등 키 재요청 시 차감 1회 검사

## 하지 않을 것
core 크레딧 연동, supabase/migrations 수정, 앱 코드
