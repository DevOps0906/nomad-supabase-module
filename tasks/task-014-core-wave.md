# task-014 코어 웨이브 (platform-docs 이식 C1·C2·C3·C5·C6·C7)

- 위험도: 높음(크레딧·잡·AI·노출) · 근거: docs/design/03-port/platform-docs-mapping.md 1장(코어 대조)·3장·4장·5장 결정(D2 버킷 분리, D6 AI 코어 이식) · 원본 D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\(읽기 전용, 코어 0000~0009)
- 이미 끝난 것: C3 수량 한도(task-006 plan_limits), C4 oauth_states·encrypted_credentials(task-011 provider_credentials)
- 형식: 메모리 규칙 — 새 core 파일은 `supabase/migrations/202611200001NN_nomad_core_<영역>.sql`, 로컬 저장소 동기화 컬럼·touch_updated_at, 라이트/다크 해당 없음

## 범위
- C1 크레딧 원장 보강: plan/pack 버킷, 월 지급분 만료, ref_type/ref_id, 환불 연결, 충전팩=addon, 멱등 키(AGENTS.md#4)
- C2 jobs: 클레임·하트비트·재시도·실패 시 환불, 제품 slug 구분, service_role 전용
- C3 나머지: rate_limit_buckets + rate_limit_hit(고정 윈도우, service_role)
- C5 AI 계층: pgvector·ai_*·wiki_*·ai_usage(원 단위 정수)
- C6 affiliate 5개 · C7 voice 2개
- 각 영역 테스트 파일(tests/credits.sql·jobs.sql·ai.sql 등) + 기존 테스트 통과

## 하지 않을 것
가격 수치, 결제 테이블(D1 계약만), 기존 마이그레이션 수정, 제품 테이블

## challenger REVISE 반영 (2026-11-13) — 단계·결정
- 0단계(builder 1): `20261120000100_nomad_core_audit.sql` — audit_log(추가 전용, service_role 쓰기, owner·admin 자기 조직 읽기 RPC) + `write_audit()` + 원본 헬퍼 대응(is_service_caller=service_role JWT 또는 JWT 없는 관리 세션(session_user postgres·supabase_admin·supabase_auth_admin) — auth.uid() null만으로는 anon도 걸리므로 쓰지 않음, is_privileged_session 등은 organization_role 기반)을 nomad_core 함수로 한 곳에 정의. 이후 단계는 이것만 쓴다.
- 1단계(병렬): C1 `…000200_nomad_core_credits.sql` ‖ C3 `…000300_nomad_core_rate_limit.sql`
  - C1: 백필 금지 — `credit_ledger.bucket text null check (bucket in ('plan','pack'))`(NOT VALID 불필요한 nullable 추가), **null = pack**으로 해석. 기존 `spend_credits`·`write_credit_entry`·`public.nomad_spend_credits` 서명 유지(create or replace, 내부에서 plan 먼저→pack 순 차감, 버킷별 음수 금지는 기존 advisory lock 안). ref_type·ref_id·버킷은 새 함수 `nomad_core.consume_credits(...)`·`refund_credits(...)`(환불 상한 = 원 consume 금액 − 기존 환불 합계, 남은 0이면 no-op) + 멱등 비교에 포함. 월 지급분 만료는 `expire_plan_credits(org, period_key)` service_role RPC만(멱등), 스케줄링·수치 없음. 원장은 추가 전용이라 동기화 컬럼 없음.
- 2단계: C2 `…000400_nomad_core_jobs.sql` — jobs.credit_ledger_id unique, enqueue 시 같은 조직 consume 행 검증, 실패 환불은 refund_credits(no-op 허용), reap 반복 안전. 사용자: `public.nomad_my_jobs(org)`(멤버 읽기, 입력·출력 본문 제외) · `nomad_cancel_job(id)`(생성자 또는 owner·admin). Realtime은 하지 않음.
- 3단계(병렬): C5 AI `…000500` ‖ C6 affiliate `…000600` ‖ C7 voice `…000700`
  - C5: service_role 전용, 사용자 래퍼 0개(테스트로 고정). `ai_runtime` 스키마 제외. 임베딩 vector(1024)(nomad-docker-module TEI bge-m3와 일치). 비용은 원본 단위 컬럼 + `cost_krw integer`(환산은 앱).
- 테스트: tests/audit.sql·credits.sql·rate_limit.sql·jobs.sql·ai.sql·affiliate.sql·voice.sql — AGENTS.md 3장 명령 표와 README 테스트 목록에 추가. 기존 accounts.sql 크레딧 검사 그대로 통과해야 함.
