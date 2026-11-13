# astro-ai(신비로운AI) 기존 DB → nomad_astro 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1100_astro.sql`(스키마 `astro`, 7표) · 문서 `products/astro-ai/`(Next.js 웹, astro-worker, AI는 FastAPI·Dify).
이식(D5: user 제안 제품 → 두 안 모두): `user/0001_astro.sql`·`org/0001_astro.sql` + 공통 `0002_ai.sql`(두 폴더에 같은 내용). 스키마 `nomad_astro`(노출). 기존 `nomad_personal`(사주·꿈해몽·여행)과 겹치지만 별도 제품(D4) — 서로 참조하지 않는다.
검증: `bash products/astro/run_check.sh user` · `bash products/astro/run_check.sh org` (begin → 청사진 drop → 0001·0002 → `check_<안>.sql` → rollback, 둘 다 통과).
사용처 약어: 웹=Next.js(authenticated, RLS 직접 읽기) · 서버=Route Handler(service_role) · 워커=astro-worker(리딩 생성·PDF 렌더·발송, service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('astro', open) | 대체: nomad_core.products | products('astro') | — |
| core.organizations · org_id | 대체 | org안 `organization_id` / user안 `user_id`(auth.users) | user안 코어 호출(감사·크레딧·작업)은 사용자의 개인 조직(`personal_organization`) |
| core.is_org_member · has_org_role(owner/admin/member) | 대체: nomad_core.organization_role | owner/admin/editor(member→editor), viewer는 읽기만 | cancel_reading·preferences 쓰기 |
| core.has_entitlement(org,'astro') | 대체: nomad_core.has_feature / user_has_feature | 기능 `astro/reading` | 정책 도우미 `nomad_astro.has_access` |
| core.plans starter(무료, 크레딧팩만) | 대체: A/B/C + features | reading·ai_chat·voice_chat·narration 모두 A·B·C | 원본 무료 기능이라 C에도 열림 → 구독이 끊겨도 리딩 가능(크레딧 과금) |
| core.credit_ledger(bigint) · core.jobs · core.cancel_job | 대체: nomad_core 같은 이름 | readings·reading_renders.credit_ledger_id uuid, job_id → nomad_core.jobs | 차감 키 `consume:astro:<request_id>`, 작업 키 `job:astro:<request_id>`. 취소 시 cancel_job이 환불 |
| core.write_audit | 대체: nomad_core.write_audit | — | — |
| core.set_updated_at · guard_privileged_write | 대체 / 삭제 | nomad_core.touch_updated_at / GRANT 미부여 | preferences 외 사용자 쓰기 권한 없음 |
| themes anon select | 대체(D8) | 공개 definer RPC `nomad_astro.list_themes()` | 표 직접 anon 권한 0 |
| core.ai_routing_settings 시드 · plans AI 키 | 이관(0002_ai.sql) | nomad_core.ai_routing_settings 10행 + 기능 3개 | 체인 제공자 검사 포함 |

## 테이블 (astro → nomad_astro, 7개)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| themes | 이관(전역, 쓰기 service_role) | nomad_astro.themes (+시드 2종) | 웹(로그인 읽기·비로그인 RPC) | 없음 |
| subjects | 이관(쓰기 서버, 암호문 컬럼 권한 없음, +deleted_at) | nomad_astro.subjects | 웹 읽기 · 서버(암·복호화) | org_id → user_id / organization_id. self 1개 유일 인덱스는 삭제되지 않은 행만 |
| readings | 이관(쓰기 서버·워커, 질문 암호문 권한 없음) | nomad_astro.readings | 웹 읽기·Realtime · 워커 | 같음 |
| reading_renders | 이관 | nomad_astro.reading_renders | 웹 읽기·Realtime · 워커 | 같음. pdf_path 접두사 `<소유 id>/astro/pdf/` |
| deliveries | 이관(수신자 암호문 권한 없음) | nomad_astro.deliveries | 웹 읽기 · 워커 | 같음 |
| consents | 이관(append-only, 쓰기 서버) | nomad_astro.consents | 웹 읽기 · 서버 | org안 (organization_id,user_id) / user안 user_id(본인만 읽기) |
| preferences | 이관(사용자 직접 쓰기) | nomad_astro.preferences | 웹 | PK org_id → user_id / organization_id |
- 동기화 대상(updated_at + touch 트리거 + (소유, updated_at) 인덱스): subjects·readings·preferences. 소프트 삭제는 subjects만(deleted_at, 서버가 찍음).

## 함수 (이름 유지)
| 원래 이름 | 분류 | 사용처 | 변화 |
|---|---|---|---|
| cancel_reading | 이관(authenticated) | 웹 `POST /api/readings/[id]/cancel` | org안: owner/admin/editor + 이용권, 남의 조직은 P0002. user안: 본인만. nomad_core.cancel_job(환불) 호출 |
| claim_due_deliveries · finish_delivery | 이관(service_role) | 워커(발송기) | — |
| readings/reading_renders/deliveries_check_transition | 이관(트리거) | — | — |
| (신규) has_access | 신규(정책 도우미, authenticated) | 정책 | — |
| (신규) list_themes | 신규(anon·authenticated 공개 RPC) | 가격표·테마 미리보기 | 입력 없음·읽기 전용 |
| (신규) personal_organization | 신규(user안 내부, 실행 권한 없음) | cancel_reading 감사 | — |
- 앱이 쓰는 코어 RPC(이름만 nomad_core로): grant_credits(welcome 30, 키 `signup:<org>:astro`) · consume_credits · refund_credits · enqueue_job · rate_limit_hit(`astro:download:<org>` 등) · write_audit · set_ai_cross_border_ack · resolve_ai_route. 결제(payment_orders·webhook_events)는 D1에 따라 이식 안 함(외부 결제 서버 계약).

## plan_limits 키 (수치 시드 안 함 — 원본 starter)
max_subjects 20 · welcome_credits 30 · ai_chat_turns_per_day 200. 테마·리딩 종류 목록(pdf_themes·readings)은 기능 reading 하나로 묶었다.

## 팀장 확인 필요
1. 원본 플랜이 무료 하나뿐이라 모든 기능을 C까지 열었다 → "구독이 끊기면 잠김"이 astro에서는 실제로 잠그지 않는다(잠김 = 조직 비활성·개인 조직 없음). 유료 구독 기능을 따로 둘지 결정 필요.
2. readings_tarot_cards_check는 원본 그대로라 tarot·combined에서 tarot_cards가 null이어도 통과한다(CHECK의 null 통과). 서버 zod가 막는다는 전제 — DB에서도 막을지.
3. user안 감사·크레딧·작업은 사용자의 개인 조직으로 기록된다.

## 보안 리뷰 반영 (2026-11-14, user안·org안 공통 — 회귀는 check_*.sql)
| 항목 | 반영 |
|---|---|
| 원장·작업 조직 일치 | 트리거 `check_billing_links`(readings·reading_renders): 같은 조직(user안은 개인 조직)의 차감 행·product astro 작업만(AS005). user안 기능 판정도 개인 조직(`org_has_feature`, user_has_feature 미사용) |
| 취소 환불 | 작업 있으면 `cancel_job`, 없고 원장 있으면 `refund_credits_internal`(키 `reading:<id>`), 과금했는데 원장 없으면 거부(AS004) |
| 결과 전달 | readings completed·renders succeeded 시 `nomad_core.mark_job_delivered`(이후 작업 실패로 환불 안 함) |
| 동의 열람 | org안 consents(ip_hash 포함)는 본인 또는 owner/admin만 |
| last_error | 제공자 오류 코드만(컬럼 주석), 200자 절단 |
| updated_by | 트리거 `preferences_set_actor`가 auth.uid()로 강제, 사용자 컬럼 권한에서 제외 |
- anon은 `list_themes()` 때문에 스키마 usage를 유지한다(표 권한 0).
- refund_credits는 service_role 판별이 있어 사용자 RPC 안에서는 같은 본문인 `refund_credits_internal`을 부른다(정의자 함수 소유자만 실행 가능).
