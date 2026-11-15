# nomad-blog 기존 DB → nomad_core 이식 대응표 (task-015 P3)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1300_blog.sql`(스키마 `blog`, 표 4개) · 문서 `products/nomad-blog/`(앱 코드 없음, 기획만).
이식: `org/0001_blog.sql`(조직형만 — 원래 org 제품, 원본 0~8장) · `org/0002_ai.sql`(원본 9장 라우팅 12행 + AI 기능). 스키마 `nomad_blog`(노출, anon 0).
D4: contentflow 에 흡수하지 않는 별도 제품(slug `blog`). 제휴(Af)는 core C6 `nomad_core.affiliate_*`·`brandconnect_applications` 참조만(제품 표에 복사 안 함).
검증: `bash products/blog/run_check.sh` (begin → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler(service_role), 워커=발행 워커(Playwright·WP API, service_role), 리다이렉트=`/r/<code>` 서버.

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('blog') | 대체 | nomad_core.products('blog') | 새로 등록 |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | 하위 표 복합 FK |
| core.org_members(member) · is_org_member · has_org_role | 대체 | nomad_core.memberships(editor) · organization_role | 정책 도우미 `nomad_blog.has_access`·`can_edit`·`can_manage` |
| core.has_entitlement(org,'blog') | 대체 | nomad_core.has_feature(org,'blog','blog') · 서버 org_has_feature | 조직 비활성 = 잠김 |
| core.plans 3행 features · credit_packs 3행 | 대체 / 삭제(D1) | A/B/C + features + plan_limits 키 | 가격·크레딧 수치 이식 안 함 |
| core.encrypted_credentials(naver_blog·tistory·wordpress·instagram) | 대체 | nomad_core.provider_credentials (id, organization_id) 복합 FK | api_providers 4코드 등록(on conflict do nothing) |
| core.revoke_credential | 대체 | nomad_core.revoke_provider_credential | 공유(다른 채널·affiliate_accounts) 중이면 남김. 재폐기 no-op(core 0800) |
| core.affiliate_links(source_app 'blog') | 대체 | nomad_core.affiliate_links(product_code 'blog') (id, organization_id) 복합 FK | 제공자 일치 검사 트리거 |
| core.affiliate_accounts.credential_id | 대체 | nomad_core.affiliate_accounts | disconnect 공유 검사(읽기만) |
| core.brandconnect_applications(target_kind 'blog') | 대체 | nomad_core.brandconnect_applications | (id, org) 유니크가 없어 트리거로 같은 조직·blog 형 검사 |
| core.jobs · cancel_job | 대체 | nomad_core.jobs (id, organization_id) 복합 FK · cancel_job | cancel_publication 은 사용자 문맥 cancel_job(owner·admin 또는 작업 생성자) |
| core.write_audit | 대체 | nomad_core.write_audit | action `blog.` 접두사 유지 |
| core.set_updated_at · guard_privileged_write · is_privileged_session | 대체 | nomad_core.touch_updated_at · `nomad_blog.guard_server_write` · current_user 판별 | RPC 진입은 `nomad_core.is_service_caller()` |
| core.ai_routing_settings 12행 · plans AI 키 병합 | 이관(0002) | nomad_core.ai_routing_settings(product_code 'blog') · 기능 4개 | 기능 키 원본 그대로 |

## 테이블 (blog → nomad_blog, 4, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| channel_accounts | 이관(서버 쓰기, 인스타그램 = 기능 instagram_channel) | nomad_blog.channel_accounts | 웹 읽기·동의·해제 · 서버(연결) · 워커(잠금) | org_id → organization_id |
| posts | 이관(콘텐츠 컬럼 GRANT + 보호 컬럼 트리거) | nomad_blog.posts | 웹 CRUD · 서버(검사·렌더) · 워커(AI 초안) | org_id → organization_id |
| post_affiliate_links | 이관(서버 쓰기, 자동 삽입 = affiliate_auto_insert) | 같은 이름 | 웹 읽기 · 서버(제휴 링크 라우트) | org_id → organization_id |
| post_publications | 이관(서버 쓰기, 발행 게이트·상태 전이·집계) | 같은 이름 | 웹 읽기·취소·확인 · 서버 · 워커 | org_id → organization_id |
- 동기화 대상: posts — `updated_at` + touch 트리거 + `(organization_id, updated_at)` 인덱스. 원본에 소프트 삭제 없음(archived 상태·하드 삭제) → 삭제는 목록 전체 재조회(local-storage.md). post_publications 는 읽기 캐시(`(organization_id, updated_at)` 인덱스).

## 함수 (blog → nomad_blog, 이름 유지)
| 원래 이름 | 분류 | 실행 | 변화 |
|---|---|---|---|
| cancel_publication · resolve_unconfirmed_publication · acknowledge_compliance_warning · set_post_archived | 이관 | authenticated(editor 이상)·서버 | 남의 조직 P0002, viewer 42501. 반환 행은 사용자 SELECT 가능 표 |
| consent_channel_automation_risk · disconnect_channel_account | 이관 | authenticated(owner·admin)·서버 | 해제는 revoke_provider_credential |
| monthly_post_usage(p_org_id → p_organization_id) | 이관 | authenticated(멤버)·서버 | 한도 posts_per_month 비교는 서버 |
| acquire_channel_lock · release_channel_lock | 이관 | service_role | TTL 30~3600초로 제한 |
| posts_guard · posts_status_transition · post_publications_gate · post_publications_transition · sync_post_status · post_affiliate_links_consistency | 이관(트리거) | 트리거 | brandconnect 검사는 `posts_brandconnect_check`(DEFINER)로 분리, 게이트에 플랜 기능 추가 |
| (신규) has_access · can_edit · can_manage · org_feature · guard_server_write · channel_accounts_features · deliver_job_result | 신규 | 정책·트리거 | 아래 |

## 플랜 기능 · plan_limits 키 (원본 business→A, pro→B, free→C. 수치 시드 안 함)
| 원본 features 키 | 새 위치 | A / B / C | DB 강제 위치 |
|---|---|---|---|
| (작업 공간) · affiliate(전 플랜 true) | 기능 `blog` | O / O / O | 모든 정책·RPC |
| ai_modes quality | 기능 `quality_mode` | O / O / — | 서버(원고 표에 모드 컬럼 없음) |
| affiliate_auto_insert | 같은 이름 | O / O / — | post_affiliate_links(inserted_by auto) |
| brandconnect | 같은 이름 | O / O / — | posts 지원서 연결 · 그 원고 발행 시작 |
| schedule | 같은 이름 | O / O / — | 발행 INSERT(scheduled) · 예약 행 발행 시작 |
| channel_types instagram | 기능 `instagram_channel` | O / — / — | channel_accounts(→active) · 발행 시작 |
| automation | 같은 이름 | O / — / — | DB 표 없음 — 서버 |
| ai_chat · voice_chat · dictation / product_wiki | 기능(0002) | O·O·O / product_wiki A·B | 서버 |
| posts_per_month · max_channel_accounts · team_members | plan_limits `posts_per_month`·`max_channel_accounts`·`members_max` | 300·30·5 / 50·10·1 / 10·2·1 | 서버(monthly_post_usage) |
| ai_chat_turns_per_day · rag_documents | plan_limits 같은 키 | 500·1000 / 200·100 / 50·10 | 서버 |

## 구독 끊김 · 결과 저장 · 참조 조직 (P2 리뷰 교훈 반영)
- 구독 없음·inactive·만료 = C. 기존 유료 행 경로: 구독 중 예약한 발행의 발행 시작, 지원서가 붙은 원고의 새 발행, 인스타그램 계정 재활성화·발행, 자동 삽입 — 잠김. 즉시 발행·수동 제휴 링크·원고 작성은 유지(check 6절).
- 결과 저장: posts generating→draft(본문 변경 = 생성 결과), post_publications publishing→published|unconfirmed 일 때 작업이 failed·canceled 면 BL007 거부, 아니면 `nomad_core.mark_job_delivered`. 본문 없이 draft 로 돌리는 실패 정리는 허용. core 표 직접 쓰기 0, core 표 트리거 0.
- 참조 조직: jobs·provider_credentials·affiliate_links·posts·channel_accounts 복합 FK, brandconnect_applications 트리거.

## 버킷
| 원래 | 새 이름 | 공개 | 정책 |
|---|---|---|---|
| core org-files `<org>/blog/…`(대표 이미지) | `blog-files` | 비공개 | 이용권 멤버 읽기, editor 이상 `<org>/blog/covers/` 업로드·삭제, svg 금지 |

## 앱 변경
- `blog.*` → `nomad_blog.*`, `org_id` → `organization_id`, `monthly_post_usage(p_org_id)` → `p_organization_id`.
- 제휴 링크는 `nomad_core.affiliate_links.product_code = 'blog'` 로 만든다(원본 source_app). 클릭 기록은 core `record_affiliate_click`.
- 워커 결과 저장 순서: 표 갱신(전달 트리거) → `complete_job`. 예약 발행 워커는 BL006(schedule) 을 받으면 발행 행을 취소 처리한다.

## 팀장 확인 필요
1. 플랜 대응 business→A·pro→B·free→C, 기능 이름 8개(blog·quality_mode·affiliate_auto_insert·brandconnect·schedule·instagram_channel·automation + AI 4).
2. 원본 `affiliate`(전 플랜 true)는 별도 기능 없이 작업 공간 `blog` 에 포함.
3. cancel_publication 은 core cancel_job 규칙상 editor 가 남이 만든 작업은 취소 못 한다(owner·admin·생성자만) — 원본과 같음.
