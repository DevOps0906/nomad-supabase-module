# book-trailer 기존 DB → nomad_core 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2600_trailer.sql`(스키마 `trailer`, 17표) · 문서 `products/book-trailer/`(앱 코드 없음, 기획만).
이식: `org/0001_trailer.sql`(조직형만 — 원래 org 제품) · `org/0002_ai.sql`(AI 기능·라우팅 시드, core C5 적용 후). 스키마 `nomad_trailer`(노출) · `nomad_trailer_private`(내부, 노출 안 함).
검증: `bash products/trailer/run_check.sh` (begin → 청사진 drop → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js 16(authenticated), 서버=Route Handler(service_role), 오케=`workers/trailer-orchestrator`(service_role, nomad_core.jobs claim), 렌더=Remotion 렌더러(service_role), API=FastAPI `apps/api`(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('trailer') | 대체 | nomad_core.products('trailer') | — |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | 하위 표 복합 FK (부모 id, organization_id) 유지 |
| core.org_members(member) · has_org_role · is_org_member | 대체 | nomad_core.memberships(editor) · organization_role | 정책 도우미 `nomad_trailer.has_access`·`can_edit` |
| core.has_entitlement(org,'trailer') | 대체 | nomad_core.has_feature(org,'trailer','trailer') · 서버는 org_has_feature | 조직 비활성 = 잠김 |
| core.plans(free/creator/publisher) features | 대체 | A/B/C + features + plan_limits 키 | 아래 표. 원본 publisher→A, creator→B, free→C |
| core.consume_credits(+metadata, actor) | 대체 | nomad_core.consume_credits(org, amount, reason, key, 'trailer', ref_type, ref_id) | 원장 id bigint → uuid. metadata·actor 인자 없음 |
| core.enqueue_job(org, app, queue, type, …) | 대체 | nomad_core.enqueue_job(org, 'trailer', type, payload, queue, …) | 인자 순서 변경(type·payload 다음 queue) |
| core.jobs · refund_on_failure 해제(직접 update) | 대체 | nomad_core.mark_job_delivered(job_id) | finish_run·finish_render. 작업이 이미 failed·canceled면 결과 저장 거부(TR001). 제품 함수의 core jobs·credit_ledger 직접 쓰기 0건(check 회귀) |
| core.write_audit | 대체 | nomad_core.write_audit | action에 `trailer.` 접두사 |
| core.set_updated_at · guard_privileged_write · is_privileged_session | 대체 | nomad_core.touch_updated_at · `nomad_trailer.guard_server_write` · current_user 판별 | 아래 "서버 판별" |
| core.is_platform_admin(카탈로그 draft 보기) | 삭제 | — | draft는 service_role만 본다 |
| core.storage_org_id · 버킷 org-files·exports | 대체 | 제품 버킷 `trailer-files`·`trailer-media` + storage.foldername | 아래 버킷 표 |
| core.plans·credit_packs 시드(가격·크레딧) | 삭제(D1) | — | 결제는 계약만. 월 지급은 nomad_core.grant_plan_credits(서버) |
| core.ai_routing_settings 시드 16행 | 이관 | nomad_core.ai_routing_settings(product_code 'trailer') | org/0002_ai.sql, 체인 검사 포함 |

서버 판별: 원본 `core.is_privileged_session()`은 current_user 기준(사용자 RPC 안에서도 참)이었다. nomad_core 판별은 JWT 기준이라 사용자 RPC(acknowledge_rights) 안에서 거짓이 되므로, 트리거는 `current_user in ('authenticated','anon')`으로 사용자 세션을 가른다. 서버 RPC 진입 검사는 `nomad_core.is_service_caller()`.

## 테이블 (trailer → nomad_trailer, 17)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| runtime_config | 이관(서버 전용) | nomad_trailer.runtime_config | 함수 | 없음 |
| grammars · templates | 이관(카탈로그, 공개 행만 읽기) | 같은 이름 | 웹 읽기 · 오케 | 없음 |
| music_tracks | 이관(storage_path 컬럼 grant 제외) | 같은 이름 | 웹 읽기 · 렌더 | 없음 |
| books | 이관(+소프트 삭제) | nomad_trailer.books | 웹 CRUD · API(원고 파싱 결과 서버 기록) | org_id → organization_id |
| purchase_links | 이관(click_count 서버만) | 같은 이름 | 웹 CRUD · 서버(/b/[code]) | org_id → organization_id |
| brand_kits | 이관 | 같은 이름 | 웹 CRUD | org_id → organization_id |
| trailers | 이관(voice·storyboard_version 서버만) | 같은 이름 | 웹 CRUD | org_id → organization_id |
| briefs | 이관(불변, 사용자는 manual INSERT만) | 같은 이름 | 웹 · 오케 | org_id → organization_id |
| scenes | 이관(엔드카드 트리거, revision) | 같은 이름 | 웹(save_scene·reorder_scenes) · 오케 | org_id → organization_id |
| metadata_packs | 이관(대가성 문구 트리거) | 같은 이름 | 웹 · 오케 | org_id → organization_id |
| book_digests | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 오케 | org_id → organization_id |
| link_clicks | 이관(추가 전용, 서버 쓰기) | 같은 이름 | 웹 통계 · 서버 | org_id → organization_id |
| scene_assets | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 오케 | org_id → organization_id |
| generation_runs | 이관(서버 쓰기, 원장·작업 1:1) | 같은 이름 | 웹 읽기(진행률) · 오케 | org_id → organization_id |
| renders | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 렌더 | org_id → organization_id, plan_code = A/B/C |
| reviews | 이관(token_sha256 컬럼 grant 제외) | 같은 이름 | 웹 읽기 · 서버(/review/[token]) | org_id → organization_id |
- 동기화 대상: books(deleted_at)·trailers·scenes·purchase_links·brand_kits·metadata_packs·briefs — `updated_at`(briefs는 불변이라 created_at) + `nomad_core.touch_updated_at()` + `(organization_id, updated_at)` 인덱스. 소프트 삭제는 books만(원본 그대로), 나머지는 하드 삭제 → 클라이언트는 전체 재조회(local-storage.md).

## 버킷
| 원래 | 새 이름 | 공개 | 정책 |
|---|---|---|---|
| core org-files `<org>/trailer/books·music·brand/…` | `trailer-files` | 비공개 | 이용권 멤버 읽기, editor 이상 업로드·삭제(경로 `<org>/trailer/(books|music|brand)/…`). `music/`은 기능 music_upload 필요. svg 금지(MIME·로고 경로) |
| trailer-media + core exports `<org>/trailer/renders/…` | `trailer-media` | 비공개 | 이용권 멤버 읽기만, 쓰기는 서버 |
| trailer-catalog | `trailer-catalog` | 비공개 | 정책 없음(service_role만) |
| trailer-previews | `trailer-previews` | 공개 URL | storage.objects 정책 없음(원본의 anon select 정책 삭제 — 목록 조회 불가, D8) |

## 함수 (trailer → nomad_trailer, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 실행 | 변화 |
|---|---|---|---|---|
| has_trailer_access | 이관 | has_catalog_access | authenticated(정책) | 이용권 있는 조직 멤버(가입 시 생기는 1인 조직 C 포함) |
| plan_features · plan_code · feature_int/bool/has | 대체 | nomad_core.org_has_feature · `nomad_trailer_private.org_limit`·`plan_code` | 서버 | jsonb 대신 기능·plan_limits |
| valid_palette · valid_hashtags | 이관 | 같은 이름 | CHECK | — |
| config_int | 이관(내부) | nomad_trailer_private.config_int | 서버 | — |
| enforce_plan_limits · books_before_update · trailers_before_write · create_end_card · scenes_before_write · briefs_before_insert · metadata_packs_before_write · enforce_run_status_transition · enforce_review_transition | 이관(트리거) | 같은 이름 | 트리거 | 한도는 nomad_core.plan_limit(없으면 원본 free 값) |
| acknowledge_rights · save_scene · reorder_scenes | 이관 | 같은 이름 | authenticated | acknowledge_rights: 남의 조직 책은 P0002, viewer는 42501 |
| reconcile_runs · start_run · finish_run · fail_run · start_render · finish_render · fail_render · record_link_click · open_review · decide_review | 이관 | 같은 이름 | service_role | 인자 p_org_id → p_organization_id. 보존 판정 free → plan_code 'C' |
| import_flora_book | 이관(인자 변경) | 같은 이름 | service_role | 다른 제품 스키마를 읽지 않는다: 서버가 FLORA 책 정보(title·subtitle·author·genre)를 인자로 넘긴다. max_books 한도 검사, (organization_id, flora_book_id) 유니크(삭제 안 된 책) |
| (신규) has_access · can_edit · guard_server_write · assert_actor | 신규 | nomad_trailer.* / _private.assert_actor | 정책·내부 | — |

## 플랜 기능 · plan_limits 키 (수치 시드 안 함 — 원본 값은 참고)
| 원본 features 키 | 새 위치 | A(publisher) / B(creator) / C(free) |
|---|---|---|
| (작업 공간) | 기능 `trailer` | A·B·C (구독 끊김 = C도 작업 가능) |
| formats(전체) | 기능 `formats_all` | A·B (C는 vertical_9_16만) |
| max_resolution 1080p | 기능 `render_1080p` | A·B |
| watermark false | 기능 `no_watermark` | A·B |
| premium_templates · music_upload · sns_upload · flora_import | 같은 이름 기능 | A·B (music_upload·sns_upload는 앱이 has_feature로 판정, DB 강제 없음) |
| approval_links · priority_render | 같은 이름 기능 | A만 |
| ai_chat · voice_chat | 같은 이름 기능(0002) | A·B·C |
| max_books · max_trailers_per_book · brand_kits_max | plan_limits 같은 키 | 100·20·30 / 10·5·5 / 1·1·1 (없으면 1) |
| max_duration_s | plan_limits `max_duration_s` | 90 / 90 / 30 (없으면 30) |
| members_max · storage_mb · ai_chat_turns_per_day | plan_limits 같은 키 | 5·30000·500 / 1·5000·200 / 1·300·20 (DB 강제 없음, 서버 검사) |

## 앱 변경 (이식 후 웹·서버가 바꿀 것)
- 테이블 이름 `trailer.*` → `nomad_trailer.*`, 컬럼 `org_id` → `organization_id`. 원장 id는 uuid.
- 서버 RPC 인자 `p_org_id` → `p_organization_id`. `import_flora_book`은 FLORA 책 정보를 읽어서 넘긴다.
- `decide_review`: 만료 링크는 raise(TR009) 대신 `status='expired'` 행을 돌려준다(원본은 raise해 만료 표시가 롤백됐다).
- 공개 경로(`/b/[code]` 리다이렉트, `/review/[token]`)는 서버가 service_role로 호출한다(anon 직접 실행 없음, D8). 속도 제한: 서버가 IP 해시 기준 `nomad_core.rate_limit_hit('trailer:click:<ip_hash>', 60, 60)`·`('trailer:review:<ip_hash>', 20, 3600)`(값은 제안)을 먼저 건다.
- **서버 의무(import_flora_book 호출 전)**: ① 요청 사용자가 그 FLORA 책을 가진 조직의 멤버이고 FLORA 쪽 소유 조직 = p_organization_id인지 FLORA API로 확인 ② 그 조직의 FLORA 이용권(`has_feature(org,'flora',…)`) 확인 ③ 책 정보는 FLORA 응답 값만 넘긴다(사용자 입력 금지). DB는 trailer 쪽 이용권·한도·중복만 본다.
- music_upload: DB가 잠근다(trailers.music_path 쓰기 트리거, trailer-files `music/` 업로드 정책, start_render). sns_upload: SNS 업로드는 DB 표가 없어 서버가 `has_feature(org,'trailer','sns_upload')`로 판정한다.
- 스키마 usage는 authenticated·service_role만(anon 0). renders.snapshot에는 카탈로그 음악 원본 경로를 넣지 않는다 — 렌더러는 track_id로 service_role 조회. 소프트 삭제된 책은 렌더 거부. books.deleted_at은 클라이언트 값 대신 now()(복원은 null).
- 잠김 화면: `public.nomad_dashboard_features(org, 'trailer')`로 기능별 잠김·업그레이드 안내.

## 팀장 확인 필요
1. (승인됨) 구독 끊김 = C = 원본 free 기능 유지. 플랜 대응 publisher→A, creator→B, free→C.
2. 버킷 재구성(core org-files·exports 없음 → `trailer-files`·`trailer-media`), `trailer-previews` 공개 버킷 유지 여부(D8은 표 기준이라 버킷은 별도 판단).
3. 카탈로그 시드(장르 문법 6·템플릿 6·runtime_config 8)는 설정 데이터로 보고 넣었다(수치 한도 아님).
