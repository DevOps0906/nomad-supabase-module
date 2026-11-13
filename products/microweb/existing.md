# microweb-studio 기존 DB → nomad_core 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1500_microweb.sql`(스키마 `microweb`) · 문서 `products/microweb-studio/`(01_PRD 4장 플랜, 04_API 2·3장 Route Handler·RPC, 05_DATA_MODEL). Next.js 웹(공개 청첩장 `/i/[slug]` + 쇼룸 + `/studio` 콘솔) · 워커(asset.process·site.publish 등) · FastAPI AI·음성.
이식: `org/0001_microweb.sql`(조직형만 — 원래 org 제품, 원본 1~19절 + 20.4·20.5 음성 연결) · `org/0002_ai.sql`(원본 20.1·20.3 AI 라우팅 기본값). 스키마 `nomad_microweb`(노출). 비노출 스키마 없음(core 공용 도우미 사용).
core 웨이브(C1 credits · C2 jobs · C5 ai · C7 voice)가 끝난 뒤라 jobs·credits·voice 참조는 0001 에 직접 넣었다(분리 불필요).
검증: `bash products/microweb/run_check.sh` (begin → 청사진 drop → 임시 touch_updated_at → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 공개=방문자 페이지·Route Handler, 콘솔=`/studio` Server Action·Route Handler(authenticated 세션), 서버=Route Handler(service_role), 워커=잡 워커·pg_cron(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('microweb', invite, beta) | 대체: nomad_core.products | products('microweb') | 초대제는 `studio_access` 허용 목록으로 유지 |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members(role member) · is_org_member · has_org_role | 대체: nomad_core.memberships · organization_role | owner/admin/editor/viewer | 원본 member → editor. 참석·견적·주문(개인정보)은 viewer 제외 |
| core.has_entitlement(org, 'microweb') | 대체: has_feature / org_has_feature | 기능 `microweb/studio`(A·B만) | 정책·사용자 RPC는 has_feature(has_studio_access), 서버·공개 RPC는 org_has_feature(org_studio_open) |
| core.plans('free').features 불리언 10개 | 대체: features + plan_features | guestbook·rsvp·ai_greeting·bgm_upload·custom_slug·ai_copy·ai_chat·voice_chat·voice_greeting·guestbook_voice (A·B·C) | 원본 무료 플랜 기능만 C. 항상 studio 와 함께 검사 → C 단독으론 안 열림 |
| core.is_service_caller · is_privileged_session | 대체 | nomad_core.is_service_caller | 원본 is_privileged_session 쓰던 곳도 is_service_caller(서버 판정 단일화) |
| core.rate_limit_hit | 대체 | nomad_core.rate_limit_take | definer 내부용. 키 접두사 `microweb:`(gb·rsvp·lead·pub) |
| core.write_audit | 대체 | nomad_core.write_audit | 개인정보 없음(상태·건수만). 공개(anon) RPC는 감사 안 남김 |
| core.set_updated_at · guard_privileged_write 트리거 | 대체 / 삭제 | nomad_core.touch_updated_at / — | 쓰기 grant·정책이 없는 표는 RPC·service_role 만 쓴다 |
| core.credit_ledger(bigint, entry_type consume) | 대체 | nomad_core.credit_ledger(uuid) | `publish_ledger_id uuid`. 셀프 게시 원장 = consume_credits(p_product 'microweb', p_ref_type 'microweb_publish', p_ref_id 사이트 id) 대표 행 |
| core.jobs | 대체 | nomad_core.jobs | sites.publish_job_id · site_publications.job_id FK. 실패 환불은 nomad_core.fail_job |
| core.voice_jobs(app_id, org_id) | 대체 | nomad_core.voice_jobs(product_code, organization_id) | attach_guestbook_voice 가 product_code 'microweb'·feature 'microweb_guestbook_voice' 확인 |
| core.ai_routing_settings(app_id) | 대체 | nomad_core.ai_routing_settings(product_code) | 0002, 12행 제안값 그대로 + 체인 검사 |
| core.payment_orders · confirm_payment_order(Phase 2 크레딧팩) | 이식 안 함(D1) | — | 결제는 계약만 유지 |

## 테이블 (microweb → nomad_microweb, 10개 전부 RLS)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| templates | 이관(쓰기 service_role) | nomad_microweb.templates | 공개(카탈로그 RPC) · 콘솔 읽기 | 전역(조직 없음) |
| portfolio_items | 이관(쓰기 service_role) | nomad_microweb.portfolio_items | 공개(쇼룸 RPC) · 콘솔 읽기 | 전역 |
| studio_access | 이관(쓰기 service_role) | nomad_microweb.studio_access | 콘솔(안내, note·granted_by 제외 컬럼 GRANT) · 관리자 서버 | org_id(PK) → organization_id |
| sites | 이관(콘텐츠 컬럼만 사용자 UPDATE) | nomad_microweb.sites | 콘솔 PATCH · 서버 게시 · 워커 | org_id → organization_id |
| site_publications | 이관(쓰기 DEFINER·service_role) | nomad_microweb.site_publications | 공개 `/i/[slug]`(get_public_site) · 콘솔 | org_id → organization_id |
| site_assets | 이관(캡션·순서만 사용자 UPDATE) | nomad_microweb.site_assets | 콘솔 · 서버 업로드 · 워커 asset.process | org_id → organization_id(storage_path 첫 칸) |
| guestbook_entries (+voice_job_id·has_voice) | 이관 | nomad_microweb.guestbook_entries | 공개(서버 쓰기·공개 RPC 읽기) · 콘솔 검토·삭제 | org_id → organization_id |
| rsvp_responses | 이관 | nomad_microweb.rsvp_responses | 공개(서버 쓰기) · 콘솔 CSV | org_id → organization_id |
| leads | 이관(+ template_code 형식 check) | nomad_microweb.leads | 공개 `/api/public/leads`(서버) · 콘솔 | org_id → organization_id |
| production_orders | 이관(+ idempotency_key) | nomad_microweb.production_orders | 콘솔 주문 | org_id → organization_id |
| 버킷 org-files · public-assets · voice-audio | 없음(core 결정 대기) | — | 서버·워커 | 경로 규칙 `<organization_id>/microweb/...` 유지(site_assets_path_check) |
- 동기화 대상: sites·site_publications·site_assets·guestbook_entries·leads·production_orders — `updated_at` + touch 트리거 + `(organization_id, updated_at)` 인덱스. `deleted_at` 없음: 삭제는 하드 삭제(서버·정리 작업). rsvp_responses 는 추가 전용(updated_at 없음, created_at 증분).
- anon(D8): 원본 anon 직접 SELECT 12건(templates·portfolio_items·site_publications 9컬럼·guestbook_entries 7컬럼+has_voice, is_site_live·is_guestbook_public 실행)을 모두 없애고 공개 읽기 RPC 4개로 대체. 테이블 grant 0.

## 함수 (microweb → nomad_microweb, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| (신규) list_public_templates · list_public_portfolio(category) | 공개(anon·authenticated·service_role) | nomad_microweb.* | 공개 카탈로그·쇼룸 | DB 요청 제한 없음(앞단 CDN·WAF) |
| (신규) get_public_site(slug) | 공개 | nomad_microweb.get_public_site | 공개 `/i/[slug]` | slug 형식 검증. DB 요청 제한 없음(없는 slug 도 행을 만들지 않음). 없음·만료·중지·조직 비활성 = not_found. 잠긴 조직(구독 끊김·허용 목록 회수)도 게시 중이면 열람 유지, guestbook_open·rsvp_open 은 false. organization_id 비노출 |
| (신규) list_public_guestbook(slug, before, limit) | 공개 | nomad_microweb.list_public_guestbook | 공개 방명록 | visible 만, 1~50건 커서, DB 요청 제한 없음. ip_hash 비노출 |
| has_studio_access | 이관(정책 헬퍼, authenticated) | nomad_microweb.has_studio_access | RLS | 멤버 + has_feature studio + 허용 목록 |
| is_site_live · is_guestbook_public | 이관(**service_role 만**) | nomad_microweb.* | 서버(bgm·voice 서명 URL) | anon 실행 회수(D8). 게시 중 + 조직 활성이면 true(구독 잠김 무관, 사용자 결정), 방명록은 guestbook 기능도 확인 |
| (신규) org_studio_open | 내부(service_role) | nomad_microweb.org_studio_open | 서버·공개 RPC 내부 | org_has_feature studio + 허용 목록 |
| require_org_role | 내부(실행 권한 없음) | nomad_microweb.require_org_role | 사용자 RPC 내부 | 역할 배열 member → editor |
| create_site | 이관(authenticated) | nomad_microweb.create_site | 콘솔 | 인자 p_org_id → **p_organization_id** |
| transition_site · issue_preview_token · confirm_disclosure_consent | 이관(authenticated) | nomad_microweb.* | 콘솔 | member → editor. 반환 sites 행은 멤버가 이미 SELECT 할 수 있는 컬럼뿐 |
| moderate_guestbook_entry · set_lead_status | 이관(authenticated) | nomad_microweb.* | 콘솔 | member → editor. **반환 타입 행 → jsonb**(컬럼 GRANT 와 같은 공개 컬럼만: ip_hash·voice_job_id·moderated_by 제외) |
| attach_order_site | 이관(authenticated, owner/admin) | nomad_microweb.attach_order_site | 콘솔 | **주문 1건당 사이트 1개**(같은 사이트 재호출 no-op, 다른 사이트 22023) |
| (신규) studio_access_detail(org) | authenticated(owner/admin)·service_role | nomad_microweb.studio_access_detail | 콘솔 설정 | note·granted_by 포함 jsonb. 잠긴 조직도 조회 가능 |
| delete_lead | 이관(authenticated, owner/admin) | nomad_microweb.delete_lead | 콘솔 | **기능 잠금·허용 목록을 보지 않음**(개인정보 삭제 예외) |
| create_order | 이관(authenticated, owner/admin) | nomad_microweb.create_order | 콘솔 `POST /api/studio/orders` | p_organization_id, **p_idempotency_key 필수**(같은 요청 재호출 = 기존 행, 다르면 22023) |
| transition_order | 이관(authenticated, owner/admin) | nomad_microweb.transition_order | 콘솔 | 이미 목표 상태면 no-op(결제 시각 재기록 안 함) |
| request_publish | 이관(service_role) | nomad_microweb.request_publish | 서버 publish | p_ledger_id **uuid**, 원장은 같은 조직·microweb·consume·ref(microweb_publish, 사이트 id)·미환불·미사용, **차감액(같은 멱등 키 묶음 합) >= 템플릿 self_publish_credits, 단가 null 이면 거부** |
| finalize_publish · fail_publish · record_customer_approval · expire_sites · purge_expired_data | 이관(service_role) | nomad_microweb.* | 워커·서버·pg_cron | purge 는 건수 감사 추가 |
| submit_guestbook_entry · submit_rsvp | 이관(service_role) | nomad_microweb.* | 공개 Route Handler(IP 해시 계산) | 잠긴 조직·guestbook/rsvp 기능 없음 = closed. 한도 IP 3/10분·사이트 500/일, RSVP IP 5/시간·사이트 2000/일 |
| create_lead | 이관(service_role) | nomad_microweb.create_lead | 공개 `/api/public/leads` | p_organization_id. 대행 모드 + studio 기능 없으면 closed. IP 3/10분·조직 300/일 |
| attach_guestbook_voice | 이관(service_role) | nomad_microweb.attach_guestbook_voice | 공개 방명록 음성 | 결과 `closed` 추가(잠긴 조직·guestbook_voice 없음) |
| sites_status_transition · sites_guard_edit · sites_sync_publication · leads_status_transition · production_orders_status_transition | 이관(트리거) | nomad_microweb.* | 트리거 | guard_edit 의 서버 판정은 is_service_caller |
| core.session_context · resolve_ai_route · set_ai_cross_border_ack · consume_credits · enqueue_job 등 | 코어 참조(이식 안 함) | nomad_core 대응 | 서버 | 앱이 nomad_core 함수로 교체 |

## plan_limits 키 (수치 시드 안 함, product `microweb`)
| 원본 features 키 | limit_key | 원본 값(free, 제안) |
|---|---|---|
| ai_greeting_per_site_30d | ai_greeting_per_site_30d | 300 |
| max_gallery_photos / max_hero_photos | max_gallery_photos / max_hero_photos | 30 / 5 |
| ai_copy_runs_per_site_30d | ai_copy_runs_per_site_30d | 20 |
| ai_chat_turns_per_day | ai_chat_turns_per_day | 100 |
| guestbook_voice_per_site_30d | guestbook_voice_per_site_30d | 100 |
| (studio_access.max_active_sites) | — 컬럼 유지(운영자가 조직별 부여, 기본 3) | 3 |
- 템플릿 가격(agency_price_min/max_krw·price_note·self_publish_credits)은 시드하지 않았다(가격 수치 열린 결정). 원본 값: wedding_classic 80,000~250,000원·20크레딧, dol_basic 40,000~100,000원·20, obituary_basic 30,000~60,000원·10 외(원본 19절).

## 기능 잠금
- 구독이 끊기면 잠긴다: 구독 없음·만료·inactive = C, C에 studio 없음. 허용 목록 회수(revoked_at)도 같은 효과. 잠긴 조직은 콘솔 조회 0건·사용자 RPC 거부(`no studio access`), 하객 쓰기(방명록·RSVP)·견적·음성 연결 closed, `request_publish`(새 게시) 거부.
- **의도된 예외**: ① 이미 게시된 청첩장의 하객 열람(`get_public_site`·`list_public_guestbook`·`is_site_live`)은 잠김과 무관하게 유지 — 조직 비활성·게시 중지·만료만 not_found(사용자 결정 2026-11-14). 공개 응답의 `guestbook_open`·`rsvp_open`은 false로 쓰기를 닫는다. ② `delete_lead`(개인정보 삭제)는 잠금을 보지 않는다. `expire_sites`·`purge_expired_data` 는 플랜과 무관하게 돈다.
- 검증: `check_org.sql` 10절(만료·inactive·구독 행 없음 각각 잠김 + 게시 중 열람 유지·쓰기 표시 false·미게시 not_found, 잠긴 상태 삭제 허용, 허용 목록 회수 잠김·열람 유지, 조직 비활성 not_found, 재구독 시 풀림).

## 운영 메모 (설치 필수 절차)
- **공개 읽기 과부하는 앞단 CDN·WAF 몫**: 공개 읽기 RPC 4개(get_public_site·list_public_guestbook·list_public_templates·list_public_portfolio)는 DB 요청 제한을 하지 않는다. 사이트·slug 단위 키는 anon 한 명이 남의 청첩장 열람을 막는 수단이 되고, 전역 키는 전체를 막으며, 없는 slug 를 세면 카운터 행이 끝없이 는다(보안 리뷰). Route Handler·페이지가 CDN 캐시(`/i/[slug]` s-maxage=30, 카탈로그·쇼룸은 더 길게) 뒤에서 부르고, 홍수·열거는 CDN·WAF·IP 제한이 막는다. 쓰기 경로(방명록·RSVP·견적) 한도는 DB 에 유지.
- 요청 제한 정리 작업: floria 와 같은 `nomad-core-purge-rate-limit`(DB당 1개, 이미 있으면 생략). microweb 최대 윈도우 = 1일.
- pg_cron(service): `select cron.schedule('microweb-expire-sites', '*/10 * * * *', $$select nomad_microweb.expire_sites()$$);` · `select cron.schedule('microweb-purge', '40 18 * * *', $$select nomad_microweb.purge_expired_data()$$);` (expire_sites 가 돌려준 id 의 공개 파생본 삭제 잡은 워커가 넣는다)

## 팀장 확인 필요
1. (사용자 결정 2026-11-14) 구독이 끊겨도 이미 게시된 청첩장의 하객 열람은 유지. 편집·새 게시·방명록/RSVP 쓰기·제작은 계속 잠김. 조직 비활성·비게시는 not_found.
2. (반영, 보안 리뷰) 공개 읽기 RPC 의 DB 요청 제한은 전부 제거(view·gb·miss·catalog 키 없음). 과부하는 앞단 CDN·WAF. 쓰기 한도는 유지.
3. (승인) 하객 쓰기(방명록·RSVP·견적)는 원본처럼 service_role 전용(anon 직접 호출이면 IP 해시 위조 가능).
4. (승인) 음성 기능 키는 원본 이름(voice_chat·voice_greeting·guestbook_voice), voice_jobs.feature 는 라우팅 키 `microweb_guestbook_voice`.
5. 원본 is_site_live·is_guestbook_public 의 authenticated 실행을 회수했다(정책에서 안 씀). 앱이 직접 부르면 서버 경로로 바꿔야 한다.
