# stock-dashboard 기존 DB → nomad_stock 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1900_stock.sql`(스키마 `stock`, 19표) · 문서 `products/stock-dashboard/`(Next.js 16 웹, quote-relay 워커, AI는 FastAPI·Dify).
이식(D5: user 제안 제품 → 두 안 모두): `user/0001_stock.sql`·`org/0001_stock.sql` + 공통 `0002_ai.sql`(두 폴더에 같은 내용). 스키마 `nomad_stock`(노출). 내부 도우미는 같은 스키마에 두고 실행 권한을 주지 않는다.
검증: `bash products/stock/run_check.sh user` · `bash products/stock/run_check.sh org` (begin → 청사진 drop → 0001·0002 → `check_<안>.sql` → rollback, 둘 다 통과).
사용처 약어: 웹=Next.js(authenticated, RLS 직접 읽기) · 서버=Route Handler(service_role) · 워커=동기화·quote-relay·주문 워커(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('stock', invite, beta) | 대체: nomad_core.products | products('stock') | 초대제는 제품 표 beta_invites·beta_access로 유지(D7 미결) |
| core.organizations · org_id | 대체 | org안 `organization_id` / user안 `user_id`(auth.users) | user안 코어 호출은 사용자의 개인 조직(`personal_organization`) |
| core.is_org_member · has_org_role | 대체: nomad_core.organization_role | owner/admin 판정, member→editor·viewer | trade_notes 쓰기는 owner·admin·editor(viewer 읽기만) |
| core.has_entitlement(org,'stock') | 대체: nomad_core.has_feature / user_has_feature | 기능 `stock/dashboard` | has_stock_access = 이용권 + 베타 접근 |
| core.plans default/beta/pro | 대체: A/B/C + features | pro→A, beta→B, default→C(기능 없음) | 구독이 끊기면(C) 전부 잠김. 수치는 plan_limits 키만 |
| core.encrypted_credentials | 대체: nomad_core.provider_credentials | broker_connections.credential_id | api_providers에 `kis`·`kiwoom`·`hana` 등록 |
| core.credit_ledger(bigint id) | 대체: nomad_core.credit_ledger(uuid) | ai_reports.credit_ledger_id uuid | 차감 `consume_credits(키 consume:stock:<request_id>)` |
| core.write_audit · audit_log 직접 insert | 대체: nomad_core.write_audit | — | user안은 개인 조직으로 기록 |
| core.is_privileged_session | 대체: nomad_core.is_service_caller | — | — |
| core.set_updated_at · guard_privileged_write | 대체 / 삭제 | nomad_core.touch_updated_at / GRANT 미부여 | 사용자 쓰기 권한 자체가 없음 |
| core.allow_purge GUC(append-only 예외) | 대체 | `pg_trigger_depth() > 1`(소유자 삭제 cascade만 통과) | 직접 UPDATE·DELETE는 ST000 |
| core.ai_routing_settings 시드 · plans AI 키 | 이관(0002_ai.sql) | nomad_core.ai_routing_settings 12행 + 기능 ai_chat·voice_chat·briefing(A·B) | 체인 제공자 검사 포함 |

## 테이블 (stock → nomad_stock, 19개)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| beta_invites | 이관(service_role만) | nomad_stock.beta_invites | 서버(초대·수락) | org안 accepted_org_id→accepted_organization_id, user안은 accepted_user_id만 |
| beta_access | 이관 | nomad_stock.beta_access | 웹 읽기 · 서버 | PK org_id → user_id / organization_id |
| instruments · fundamentals · market_calendar | 이관(전역 참조, 로그인 읽기) | 같은 이름 | 웹 · 워커 | 없음 |
| daily_prices | 이관(사용자 권한 없음) | nomad_stock.daily_prices | 워커(성과 계산) | 없음 |
| broker_connections | 이관(쓰기 서버) | 같은 이름 | 웹 읽기 · 서버 | org_id → user_id / organization_id |
| balance_snapshots · holdings · trades | 이관(쓰기 워커) | 같은 이름 | 웹 읽기 · 워커 | 같음. 금액 `*_krw` numeric(18,0)→bigint |
| trade_notes | 이관(유일한 사용자 쓰기, +deleted_at) | 같은 이름 | 웹 CRUD | 같음. user안은 created_by 제거(소유자=작성자) |
| ai_reports · ai_report_items | 이관(쓰기 서버) | 같은 이름 | 웹 읽기 · 서버 | 같음. advice_check CHECK를 표 정의에 포함 |
| idea_evaluations | 이관(읽기는 기능 leaderboard) | 같은 이름 | 웹(P2) · 워커 | 같음 |
| consents | 이관(append-only, record_consent) | 같은 이름 | 웹 RPC | org안 (organization_id,user_id) / user안 user_id |
| order_limits | 이관(set_order_limits) | 같은 이름 | 웹(P3) | PK org_id → user_id / organization_id. max_order_krw integer→bigint |
| kill_switches | 이관 | 같은 이름 | 웹(P3) · 서버 | scope `org` → user안 `user` |
| order_requests · order_events | 이관(env=paper만, events append-only) | 같은 이름 | 웹 읽기 · 서버 · 워커 | 같음. est_amount_krw bigint 생성 컬럼 |
- 동기화 대상(updated_at + touch 트리거 + (소유, updated_at) 인덱스): broker_connections·holdings·trades·trade_notes. 소프트 삭제는 trade_notes만(deleted_at).

## 함수 (이름 유지)
| 원래 이름 | 분류 | 사용처 | 변화 |
|---|---|---|---|
| has_stock_access | 이관(authenticated) | 정책 · 웹 | user안 인자는 user_id(본인일 때만 true) |
| redeem_beta_invite · revoke_beta_access | 이관(service_role) | 서버 | 이메일은 auth.users, 개인 조직 = kind personal + owner. user안 revoke 인자 user_id |
| record_consent | 이관(authenticated) | 웹 | user안 `(p_kind, p_version)` — 조직 인자 없음 |
| set_order_limits · engage_kill_switch · release_kill_switch · confirm_paper_order | 이관(authenticated) | 웹(P3) | user안은 조직 인자 없음(본인). 금액 인자 bigint |
| create_paper_order · apply_order_update · expire_pending_orders · is_trading_blocked | 이관(service_role) | 서버 · 워커 · 스케줄 1분 | create_paper_order에 기능 `paper_orders` 검사(ST040) + 다른 소유자의 client_order_id 재사용 거부(22023) 추가 |
| enforce_status_transition · reject_log_mutation | 이관(트리거) | — | — |
| (신규) user_feature · personal_organization | 신규(user안 내부, 실행 권한 없음) | 정의자 함수 내부 | — |

## plan_limits 키 (수치 시드 안 함 — 원본 beta / pro)
ai_diagnosis_per_day 10/20 · broker_connections_max 2/3 · history_days 365/730 · monthly_credits 300/400 · ai_chat_turns_per_day 100/200 · ai_research_per_day 20/40. 기능(불리언)은 features: dashboard(A·B) · ai_compare·ideas·leaderboard·paper_orders(A) · ai_chat·voice_chat·briefing(A·B).

## 팀장 확인 필요
1. 베타 초대제(beta_invites·beta_access)를 제품 표로 유지했다 — D7(초대제 가입) 미결. 코어 초대제가 생기면 대체 대상.
2. 시세·단가(price·avg_price·limit_price 등)는 numeric(18,2) 유지, 원 단위 금액(`*_krw`)만 bigint로 바꿨다.
3. api_providers에 증권사 코드 `kis`·`kiwoom`·`hana`를 제품 파일이 등록한다(코어 참조 표에 행 추가).
4. user안 감사·크레딧은 사용자의 개인 조직(kind personal, owner)으로 기록 — 개인 조직이 없으면 감사 organization_id가 null.

## 보안 리뷰 반영 (2026-11-14, user안·org안 공통 — 회귀는 check_*.sql)
| 항목 | 반영 |
|---|---|
| 베타 수락 | `auth.users.email_confirmed_at`이 있어야 수락(ST032) |
| 사람 최종 확인 | `confirm_paper_order`는 사용자 세션 전용(service_role 실행 권한 회수), `confirmed_by = auth.uid()` |
| 자격 증명 | 트리거 `broker_connections_check_credential`: 같은 조직(user안은 개인 조직)·`provider_code = broker`·미폐기만(ST050). 코어 표에는 트리거를 걸지 않는다. 사용 시점(주문 생성·확인·제출)에 `revoke_if_credential_revoked`가 키의 `revoked_at`을 보고 폐기면 연결을 revoked·orders_enabled false로 표시(제품 표만), 주문은 blocked `not_eligible`. `order_eligible`도 키 미폐기를 본다 |
| 원장 조직 일치 | 트리거 `ai_reports_check_ledger`(같은 조직·차감 행만, ST051). user안 기능 판정·과금은 모두 개인 조직(`user_feature`·`my_feature`, user_has_feature 미사용) |
| 주문 | 행위자 멤버십(owner·admin·editor, user안은 본인)+베타 확인, 종목 비중 한도(`max_position_weight`, 스냅샷 없으면 차단), 확인·제출 시 적격 재확인(`order_eligible` → blocked `not_eligible`), 킬 스위치 켜기는 구독·베타와 무관(org안 멤버, user안 로그인) |
| 컬럼 권한 | broker_connections `account_ref_hash`·`credential_id` 사용자 권한 없음, Realtime은 컬럼 목록 발행 |
| 읽기 범위 | instruments·fundamentals·market_calendar·전역 킬 스위치는 이용 가능(구독+베타) 사용자만(`has_any_stock_access`), 스키마 anon usage 제거 |
- 팀장 승인(2026-11-14): 비중 판정 = (보유 수량 × 지정가 + 주문 금액) / 최근 스냅샷(현금+평가), 스냅샷 없으면 차단. 코어 표 트리거는 불허 → 사용 시점 판정으로 대체.
