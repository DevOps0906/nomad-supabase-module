# flora-publishing 기존 DB → nomad_core 이식 대응표 (task-015 P3)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1000_publishing.sql`(스키마 `publishing`, 표 13개) · 문서 `products/flora-publishing/`(앱 코드 없음, 기획만) · 플랜 `_supabase-modular/seed.sql` publishing free·basic.
이식: `org/0001_flora.sql`(조직형만 — 원래 org 제품, 원본 0~14·16장) · `org/0002_ai.sql`(원본 15장 라우팅 12행 + AI 기능, core C5 적용 후). 스키마 `nomad_flora`(노출, anon 은 공개 RPC 하나).
D9: platform-docs 기준으로 새로 작성. 저장소 청사진 `supabase/migrations/2026111{5,6,7}*_flora.sql`(projects·personas·pipeline_runs·audiobooks 등 6표)은 참고만 했고, 같은 스키마 이름이라 검사는 트랜잭션 안에서 청사진을 drop 한 뒤 적용한다.
검증: `bash products/flora/run_check.sh` (begin → 청사진 drop → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js 16(authenticated), 서버=Route Handler(service_role), 워커=LLM·파서·렌더 워커(service_role, nomad_core.jobs claim), 공개=공개 책 페이지 서버.

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('publishing') | 대체 | nomad_core.products('flora') | 청사진이 이미 등록(on conflict do nothing) |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | 하위 표 복합 FK (부모 id, organization_id) 유지 |
| core.org_members(member) · is_org_member · has_org_role | 대체 | nomad_core.memberships(editor) · organization_role | 정책 도우미 `nomad_flora.has_access`·`can_edit`·`can_manage` |
| core.has_entitlement(org,'publishing') | 대체 | nomad_core.has_feature(org,'flora','flora') · 서버는 org_has_feature | 조직 비활성 = 잠김 |
| book_plan_limit · book_plan_flag · book_theme_allowed | 대체 | `nomad_flora.limit_of`(org_plan_limit) · `org_feature`(org_has_feature) · `theme_allowed` | jsonb features 대신 기능·plan_limits. 사용자 실행 권한 없음(트리거·서버 전용) |
| core.jobs(id) FK | 대체 | nomad_core.jobs (id, organization_id) 복합 FK | 다른 조직 작업 참조 불가(on delete set null (컬럼)) |
| core.credit_ledger(id) bigint | 대체 | nomad_core.credit_ledger(id) **uuid** | book_exports·agent_tasks.credit_ledger_id. 같은 조직 검사 트리거 `check_ledger_org` |
| core.ai_runs(id) | 대체 | nomad_core.ai_runs (id, organization_id) 복합 FK | agent_tasks.ai_run_id |
| core.encrypted_credentials(provider 'outbound_webhook') | 대체 | nomad_core.provider_credentials (id, organization_id) 복합 FK | api_providers 에 `outbound_webhook` 등록(on conflict do nothing) |
| core.write_audit | 대체 | nomad_core.write_audit | action 에 `flora.` 접두사 |
| core.set_updated_at · guard_privileged_write · is_service_caller(트리거) | 대체 | nomad_core.touch_updated_at · `nomad_flora.guard_server_write` · current_user 판별 | 아래 "서버 판별" |
| core.plans free·basic features · credit_packs | 대체 / 삭제(D1) | A/B/C + features + plan_limits 키 | 가격·크레딧 수치 이식 안 함 |
| core.ai_routing_settings 12행 · plans AI 키 병합 | 이관(0002) | nomad_core.ai_routing_settings(product_code 'flora') · 기능 4개 | 기능 키 문자열은 원본 그대로(`publishing.draft` 등) |
| books_select_public(anon 정책) | 대체(D8) | `nomad_flora.get_public_book(slug)` 공개 RPC | 표 직접 anon 권한 0 |

서버 판별: 사용자 경로 강제값·서버 표 잠금은 `current_user in ('authenticated','anon')`(사용자 DEFINER RPC 안에서는 소유자라 서버로 본다). 한도·기능·결과 전달 트리거는 SECURITY DEFINER 라 서버·사용자 모두에 적용. member_settings 트리거와 RPC 진입 검사는 `nomad_core.is_service_caller()`(JWT 기준).

## 테이블 (publishing → nomad_flora, 13, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| custom_personas | 이관(INSERT 서버만, 기능 persona_blend) | nomad_flora.custom_personas | 웹(이름·보관·삭제) · 서버(합성) | org_id → organization_id |
| books | 이관(+소프트 삭제, 컬럼 GRANT) | nomad_flora.books | 웹 CRUD · 서버 · 공개(RPC) · trailer 서버(book_for_trailer) | org_id → organization_id |
| chapters · sections | 이관 | 같은 이름 | 웹 CRUD · 워커(섹션 생성 결과) | org_id → organization_id |
| cover_images | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커(fal) | org_id → organization_id |
| manuscript_uploads | 이관(서버 쓰기, 기능 upload) | 같은 이름 | 웹 읽기 · 서버(서명 업로드 URL) · 파서 워커 | org_id → organization_id |
| book_exports | 이관(서버 쓰기, 워터마크 없음 = no_watermark) | 같은 이름 | 웹 읽기 · 렌더 워커 | org_id → organization_id |
| generation_runs | 이관(서버 쓰기, write_all·quality_mode) | 같은 이름 | 웹 읽기·취소 요청 · 워커 | org_id → organization_id |
| member_settings | 이관(본인 행) | 같은 이름 | 웹 | (org_id, user_id) → (organization_id, user_id) |
| webhook_endpoints · webhook_deliveries | 이관(서버 쓰기, 기능 webhooks) | 같은 이름 | 웹(owner·admin 읽기) · 서버·발송 워커 | org_id → organization_id |
| waitlist | 이관(서버 전용) | 같은 이름 | 서버(랜딩) | 없음 |
| agent_tasks | 이관(서버 쓰기, 검수 결정 RPC) | 같은 이름 | 웹 읽기·결정 · 서버·워커 | org_id → organization_id |
- 동기화 대상: books(deleted_at)·chapters·sections·custom_personas·member_settings — `updated_at` + touch 트리거 + `(organization_id, updated_at)` 인덱스(member_settings 는 `(user_id, updated_at)`). 소프트 삭제는 books 만(원본 그대로), 나머지는 하드 삭제 → 책을 열 때 그 책 행 전체 재조회(local-storage.md).

## 함수 (publishing → nomad_flora, 이름 유지)
| 원래 이름 | 분류 | 실행 | 변화 |
|---|---|---|---|
| request_generation_cancel | 이관 | authenticated(editor 이상)·서버 | 남의 조직 P0002, viewer 42501 |
| set_book_visibility | 이관 | authenticated(owner·admin)·서버 | 켜기는 completed + 기능 public_page(PB009), 끄기는 기능 없이도 |
| decide_agent_task | 이관 | authenticated(editor 이상)·서버 | 같음 |
| books_before_insert · books_before_update · sections_before_write · book_exports_transition · generation_runs_transition · manuscript_uploads_transition · member_settings_before_write · agent_tasks_before_insert · agent_tasks_transition | 이관(트리거) | 트리거 | books_before_update: 사용자 소프트 삭제 시각 now() 강제. member_settings: 끊기면 기존 프로 테마·quality 를 다음 저장 때 기본값으로 |
| chapters_before_insert · sections 쿼터 부분 | 대체 | `enforce_plan_limits`(DEFINER 트리거) | books·chapters·sections INSERT + paragraph_target |
| custom_personas_guard_insert · core.guard_privileged_write | 대체 | `guard_server_write` 트리거 | 서버 표 8개 + custom_personas INSERT |
| (신규) has_access · can_edit · can_manage · limit_of · org_feature · theme_allowed | 신규 | 정책·내부 | 위 표 |
| (신규) enforce_plan_features | 신규(트리거) | — | 아래 "구독 끊김" |
| (신규) deliver_job_result | 신규(트리거) | — | 아래 "결과 저장" |
| (신규) check_ledger_org | 신규(트리거) | — | 원장 같은 조직 |
| (신규) book_for_trailer(p_organization_id, p_book_id, p_actor) | 신규 | service_role | book-trailer `import_flora_book` 서버 의무 ①②③ 계약(아래) |
| (신규) get_public_book(p_slug) | 신규(D8 공개 RPC) | anon·authenticated | 공개 컬럼 jsonb만, DB 요청 제한 없음(CDN·WAF 몫) |

## 플랜 기능 · plan_limits 키 (수치 시드 안 함 — 원본 값은 참고)
| 원본 features 키 | 새 위치 | A·B(basic) / C(free) | DB 강제 위치 |
|---|---|---|---|
| (작업 공간) | 기능 `flora` | O / O | 모든 정책·RPC |
| watermark false | 기능 `no_watermark` | O / — | book_exports INSERT(watermark=false) |
| themes pro | 기능 `themes_pro` | O / — | member_settings 트리거(PB008) |
| write_all | 기능 `write_all` | O / — | generation_runs INSERT |
| upload | 기능 `upload` | O / — | manuscript_uploads INSERT·→parsing |
| quality_mode | 기능 `quality_mode` | O / — | generation_runs(mode quality)·member_settings |
| persona_blend | 기능 `persona_blend` | O / — | custom_personas INSERT · books.custom_persona_id 지정 · 그 책의 generation_runs |
| webhooks | 기능 `webhooks` | O / — | webhook_endpoints INSERT·→active · webhook_deliveries INSERT |
| public_page | 기능 `public_page` | O / — | set_book_visibility · get_public_book(끊기면 not_found) |
| tone_slider · writing_assist | 같은 이름 기능 | O / — | DB 표 없음 — 서버가 has_feature 로 판정 |
| ai_chat · book_wiki · voice_dictation / narration | 기능(0002) | O / O, narration O / — | 서버 |
| max_books · max_chapters · max_sections · max_paragraphs | plan_limits 같은 키 | 100·20·200·5 / 3·3·6·3 | enforce_plan_limits(키 없으면 free 값) |
| exports_per_month · personas · ai_chat_turns_per_day · rag_files_max | plan_limits 같은 키 | 100·60·300·20 / 2·40·50·3 | 서버(book_exports_org_month_idx 로 셈) |

## 구독 끊김 · 결과 저장 · 참조 조직 (P2 리뷰 교훈 반영)
- 구독 없음·inactive·만료 = C = 원본 free 기능만. 기존 유료 행 경로: 업로드된 원고의 파싱 시작, 기존 엔드포인트 재활성화·발송, 구독 중 공개한 책의 공개 페이지, 구독 중 만든 페르소나를 책에 붙이기·그 책 생성, 프로 테마·quality 설정 행 — 모두 잠김(check 6절).
- 결과 저장: 서버가 sections→generated, cover_images·book_exports→succeeded, manuscript_uploads→parsed, generation_runs·agent_tasks→succeeded|partial 로 바꿀 때 작업이 failed·canceled 면 PB015 거부, 아니면 `nomad_core.mark_job_delivered`. 제품 함수의 core 표 직접 쓰기 0, core 표 트리거 0(check 0절).
- 참조 조직: jobs·ai_runs·provider_credentials·cover_images·custom_personas·books 는 복합 FK, credit_ledger 는 트리거.

## trailer 계약 (book-trailer `import_flora_book`)
서버가 `nomad_flora.book_for_trailer(org, flora_book_id, actor)` 를 service_role 로 불러 ① actor 가 그 조직 멤버 ② 조직에 flora 이용권(조직 활성) ③ 책이 그 조직 소유·삭제 안 됨을 DB 가 확인한 값(title·subtitle·author_name·genre)만 받아 `nomad_trailer.import_flora_book` 인자로 넘긴다. genre 값 목록은 두 제품이 같다.

## 버킷
| 원래 | 새 이름 | 공개 | 정책 |
|---|---|---|---|
| core org-files `<org>/publishing/manuscripts·covers` | `flora-files` | 비공개 | 이용권 멤버 읽기(`<org>/flora/…`). 쓰기는 서버(원고는 서명 업로드 URL, 기능 upload 확인 후) |
| core exports | `flora-exports` | 비공개 | 이용권 멤버 읽기, 쓰기는 서버 |

## 앱 변경 (이식 후 웹·서버가 바꿀 것)
- `publishing.*` → `nomad_flora.*`, `org_id` → `organization_id`, 원장 id uuid, 저장 경로 `<org>/publishing/…` → `<org>/flora/…`.
- 공개 책 페이지는 anon 표 SELECT 대신 `rpc('get_public_book', {p_slug})`.
- 서버 RPC·작업 등록은 `nomad_core.consume_credits(org, n, reason, key, 'flora', ref_type, ref_id)`·`enqueue_job(org, 'flora', type, payload, queue, …)`. 결과 저장 순서: 표 갱신(전달 트리거) → `complete_job`.
- 서버가 계속 판정: tone_slider·writing_assist·exports_per_month·personas·AI 키(현재 기능 표).

## 팀장 확인 필요
1. 플랜 대응: 원본은 free·basic 두 개뿐 → basic→A·B(같은 기능), free→C. B 를 A 와 다르게 할지.
2. 청사진 flora 행: products 'flora' 의 기존 기능 4개(writing_core·persona_style·pipeline_auto·audiobook)와 `nomad_flora` 청사진 표는 그대로 둔다(supabase/ 수정 금지). 운영 반영 시 청사진 제거 마이그레이션 필요.
3. 구독이 끊기면 이미 공개한 책 페이지도 내린다(microweb 은 게시 유지로 결정됨 — flora 도 유지할지).
4. 라우팅 기능 키를 원본 `publishing.*` 로 유지(앱 호출 문자열 보존). `flora.*` 로 바꿀지.
