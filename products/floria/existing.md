# website-floria 기존 DB → nomad_core 이식 대응표 (task-015 P1)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2200_site.sql`(스키마 `site`) · 문서 `products/website-floria/`(Next.js 16 웹 = 공개 브랜드 사이트 + 초대제 운영 콘솔, 앱 없음, AI는 AI 게이트 Route Handler·FastAPI·Dify).
이식: `org/0001_floria.sql`(조직형만 — 원래 org 제품, 원본 1~10절) · `org/0002_ai.sql`(원본 11절, **core 웨이브 후 적용**). 스키마 `nomad_floria`(노출). 내부 도우미는 nomad_core 공용(제품 비노출 스키마 없음).
검증: `bash products/floria/run_check.sh` (begin → 청사진 drop → 임시 touch_updated_at → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 공개=방문자 Route Handler(service_role, `submit_inquiry`만 anon도 허용), 콘솔=Server Action(authenticated 세션), 워커=pg_cron·알림 메일 워커(service_role).
원본 원칙 유지: 사이트 콘텐츠(문구·컬렉션·이미지)는 DB에 두지 않는다(저장소 `src/content/*.ts`가 정본). DB는 방문자가 남기는 것과 사이트 등록부만. 결제·크레딧 없음.

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('site', signup_policy invite) | 대체: nomad_core.products | products('floria') | 초대제는 nomad_core 초대 + `provision_site`(service_role) 2차 게이트로 유지 |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members(role member) | 대체: nomad_core.memberships | owner/admin/editor/viewer | 원본 member → editor. 문의·구독자는 viewer 제외(개인정보) |
| core.is_org_member · has_org_role | 대체: nomad_core.organization_role | `organization_role(organization_id) is not null` / `in ('owner','admin','editor')` | 역할 비교는 coalesce(role,'') |
| core.has_entitlement(org_id, 'site') | 대체: nomad_core.has_feature / org_has_feature | 기능 `floria/site` (A·B만 — C에 없음 = 구독이 끊기면 잠김) | 정책·운영 RPC는 has_feature, 공개·service_role RPC는 org_has_feature |
| core.is_service_caller | 대체: nomad_core.is_service_caller | nomad_core.is_service_caller | service_role JWT 또는 JWT 없는 관리 세션(pg_cron) |
| core.rate_limit_hit | 대체: nomad_core.rate_limit_take | nomad_core.rate_limit_buckets | anon RPC 안에서 쓰므로 서버 전용 rate_limit_hit 대신 definer 내부용 take. 키 접두사 `floria:`(inq:·nl:) |
| core.write_audit · audit_log | 대체: nomad_core.write_audit | nomad_core.audit_log | 개인정보 없음. 콘솔 조회는 public.nomad_audit_log(owner/admin) |
| core.set_updated_at 트리거 | 대체 | nomad_core.touch_updated_at | — |
| core.guard_privileged_write 트리거 | 삭제 | — | 쓰기 grant·정책이 없어 테이블 쓰기는 service_role·RPC뿐 |
| core.plans(default) · app_entitlements | 대체: A/B/C + features('site') | plan_features 2행(A·B) | 원본 플랜 features에 수치 한도 없음 → plan_limits 키 없음 |
| core.ai_routing_settings 시드 8행 · 11.2 체인 검사 · core.ai_* | **core 웨이브 후 적용** | org/0002_ai.sql(주석으로 보존) | 0002는 sites 스위치 2컬럼 + update_ai_settings만 |

## 테이블 (site → nomad_floria)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| sites | 이관(쓰기 RPC만) | nomad_floria.sites | 공개(`GET /api/ai/config`, slug 조회) · 콘솔 읽기 · provision/update RPC | org_id → organization_id |
| sites.accepts_ai_chat · accepts_voice | 이관(**core 웨이브 후**) | 0002 컬럼 추가 | 콘솔 `update_ai_settings` | — |
| inquiries | 이관(쓰기 RPC만) | nomad_floria.inquiries | 공개 `POST /api/inquiries` · 콘솔 목록(owner/admin/editor) · 워커 알림 | org_id → organization_id |
| newsletter_subscribers | 이관(쓰기 service_role RPC만) | nomad_floria.newsletter_subscribers | 공개 `/api/newsletter/*` · 콘솔 목록(owner/admin/editor) | org_id → organization_id |
| (core rate_limit) | 대체(제품 표 없음) | nomad_core.rate_limit_buckets | rate_limit_take 내부 | — |
| (core audit_log) | 대체(제품 표 없음) | nomad_core.audit_log | write_audit 내부 | organization_id(purge는 null) |
| 버킷 | 없음 | — | 원본에 Storage 버킷 없음(이미지는 저장소 정적 자산) | — |
- 동기화 대상: sites·inquiries·newsletter_subscribers — `updated_at` + `nomad_core.touch_updated_at()` 트리거 + `(organization_id, updated_at)` 인덱스(`sites_org_idx`·`inquiries_org_updated_idx`·`newsletter_org_updated_idx`). `deleted_at` 없음: 문의는 하드 삭제(delete_inquiry·purge_expired), 구독자는 상태(unsubscribed)·email 비우기로 비식별화.
- anon(D8): 테이블 grant 없음. 공개 쓰기는 `submit_inquiry`(definer, 입력 검증·허니팟·스팸 점수·rate limit 사이트 100/시간·500/일, 이메일 해시 3/시간·6/일) 하나뿐. IP 제한·Turnstile은 앞단 Route Handler 몫.

## 함수 (site → nomad_floria, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| submit_inquiry | 이관(anon·authenticated·service_role) | nomad_floria.submit_inquiry | 공개 | 오류 SI002~SI004 raise 유지, 한도 초과 SI001은 {ok:false, code:'SI001'} 반환 |
| subscribe_newsletter · confirm_newsletter · unsubscribe_newsletter | 이관(service_role) | nomad_floria.* | 공개(확인 메일 발송 Route Handler) | 구독 rate limit 200/시간·이메일 3/시간, 확인 메일 최대 5회 |
| set_inquiry_status | 이관(authenticated) | nomad_floria.set_inquiry_status | 콘솔 | 역할 owner/admin/editor + has_feature |
| delete_inquiry · erase_subscriber · update_site_settings | 이관(authenticated, owner/admin) | nomad_floria.* | 콘솔 | — |
| update_ai_settings | 이관(**core 웨이브 후**) | nomad_floria.update_ai_settings(0002) | 콘솔 `PATCH /api/admin/ai/settings` | 상담 끄면 음성도 끔 |
| provision_site | 이관(service_role) | nomad_floria.provision_site | 운영 절차 | 인자 p_org_id → p_organization_id |
| purge_expired | 이관(service_role) | nomad_floria.purge_expired | 워커(pg_cron `floria-purge-expired` 30 18 * * * UTC) | 문의 보존 일수·spam 30일·pending 7일·해지 30일 후 email 비움 |
| inquiry_status_transition · newsletter_status_transition | 이관(트리거) | nomad_floria.* | 트리거 | — |
| (원본 core) is_service_caller · rate_limit_hit · write_audit | 대체 | nomad_core.is_service_caller · rate_limit_take · write_audit | RPC 내부 | 제품 사본·`nomad_floria_private` 스키마 없음 |
| core.session_context('site') · set_ai_cross_border_ack · resolve_ai_route · match_ai_chunks | 코어 참조(이식 안 함) | — | 콘솔·AI 게이트 | 앱이 nomad_core 대응으로 교체(core 웨이브) |

## plan_limits 키 (수치 시드 안 함)
| 원본 features 키 | limit_key (product `floria`) | 원본 값 |
|---|---|---|
| (없음 — 원본 기본 플랜 1행, 한도 키 없음) | — | rate limit 수치는 RPC 상수로 유지(플랜 무관) |
| (AI) ai_chat · voice | — (core 웨이브에서 features로 정의, 0002 주석) | 사이트 스위치는 sites 컬럼 |

## 기능 잠금
- 구독이 끊기면 잠긴다: 구독 없음·만료·inactive는 core 규칙상 C로 취급되고, C에는 `site`가 없다. 잠긴 조직은 공개 `submit_inquiry`·`subscribe_newsletter`(SI002), 콘솔 조회(0건)·`set_inquiry_status`·`update_site_settings`·`update_ai_settings`, 서버 `provision_site`가 모두 거부된다.
- **의도된 예외**: `delete_inquiry`·`erase_subscriber`(개인정보 삭제)는 기능 잠금을 보지 않는다 — 구독이 끊긴 조직도 owner/admin·서버가 삭제 요청을 처리할 수 있어야 한다. `purge_expired`(보존 기한 삭제)도 플랜과 무관하게 돈다.
- 검증: `check_org.sql` 7절(만료·inactive·구독 행 없음 각각 잠김, 잠긴 상태 삭제 허용, 재구독 시 풀림).

## 운영 메모 (설치 필수 절차)
- 요청 제한 카운터는 core 공용 표 `nomad_core.rate_limit_buckets`라 정리가 자동이 아니다(제품 사본의 2% 확률 삭제 없음). 설치 때 pg_cron에 정리 작업을 **반드시** 등록한다. DB당 1개면 되므로 다른 제품이 이미 걸었으면(`select jobname from cron.job`) 생략한다. pg_cron은 JWT 없는 postgres 세션이라 `is_service_caller()`를 통과한다.
```sql
-- 매일 03:10 KST(18:10 UTC). 윈도우가 끝난 지 1일 지난 키만 지운다(floria 최대 윈도우 = 1일).
select cron.schedule('nomad-core-purge-rate-limit', '10 18 * * *', $$select nomad_core.purge_rate_limit_buckets()$$);
```

## 팀장 확인 필요
1. 콘솔 세션 판정 `core.session_context('site')`의 nomad_core 대응이 없음(앱 쪽 교체 대상).
2. AI 기능 키 이름 `ai_chat`·`voice`(0002 주석)를 core 웨이브에서 그대로 쓸지.
