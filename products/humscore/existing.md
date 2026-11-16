# humscore 기존 DB 분류표 (task-012)

원본: `D:\WorkSpace\DEV\humscore\supabase\migrations\` 5개 + `docs/05_DATA_MODEL.md`. 변환: `user/0001_humscore.sql`(개인형) · `org/0001_humscore.sql`(조직형). 검사: `check_user.sql` · `check_org.sql`.
스키마 `nomad_humscore`(API 노출) · `nomad_humscore_private`(검사·트리거 함수, 노출 금지). 앱은 `.schema('nomad_humscore')`로 호출한다. 레포에 Storage 버킷·Edge Function은 없다.

## 테이블
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org 변화 |
|---|---|---|---|---|
| public.scores | 이관 | nomad_humscore.scores | 웹 `src/app/actions/scores.ts`(upsert·soft delete)·`lib/storage/scores.ts`·setlists 검증 | `user_id` → `organization_id`(+ `created_by` 작성자). id는 클라이언트가 만든 uuid 유지 |
| public.setlists | 이관 | nomad_humscore.setlists | 웹 `actions/setlists.ts`·`actions/share.ts` | `user_id` → `organization_id`(+`created_by`) |
| public.share_links | 이관 | nomad_humscore.share_links | 웹 `actions/share.ts`(insert·select·update revoked_at·delete) | `owner_id` → `organization_id`(+`created_by`). 악보·콘티 둘 중 하나만(score_id/setlist_id) |
| public.transcription_jobs | 이관 | nomad_humscore.transcription_jobs | 앱 코드 사용 없음. 워커(Python, 레포 밖)가 큐 소비 — service_role | `user_id` → `organization_id`(+`created_by`) |
| (자체 profiles·조직·멤버십·플랜) | 없음 | nomad_core.* 참조 | — | 레포에 없음. org안은 nomad_core.organizations/memberships 사용 |

## 함수 · RPC
| 원래 이름 | 분류 | 새 이름 | 사용처 | 비고 |
|---|---|---|---|---|
| public.get_shared_score(p_token) | 이관(RPC 이름 유지) | nomad_humscore.get_shared_score | 웹 `lib/storage/shared-score.ts`(anon) | security definer, anon·authenticated 실행. org안은 조직 일치로 조인 |
| public.get_shared_setlist(p_token) | 이관(RPC 이름 유지) | nomad_humscore.get_shared_setlist | 웹 `lib/storage/shared-setlist.ts`(anon) | 동일 |
| public.reissue_share_link(p_score_id, p_token_hash, p_expires_at) | 이관(RPC 이름 유지) | nomad_humscore.reissue_share_link | 웹 `actions/share.ts` | security invoker. org안은 조직을 악보에서 읽고 editor 미만이면 42501 |
| public.setlist_items_valid | 이관(내부) | nomad_humscore_private.setlist_items_valid | setlists check 제약 | |
| scores_clamp_updated_at · scores_lww_guard · scores_row_cap | 이관(내부 트리거) | nomad_humscore_private.* (scores_a_clamp·b_lww·c_row_cap) | scores 동기화 | LWW 키는 클라이언트 updated_at → `touch_updated_at` 미적용(팀장 확인 필요 1) |
| scores_revoke_shares · setlists_revoke_shares | 이관(내부 트리거) | nomad_humscore_private.* | 삭제 시 링크 회수 | |
| setlists_touch | 대체:nomad_core.touch_updated_at | trigger setlists_a_touch | setlists 서버 시각 | core 마이그레이션 20261119000100 전에는 검사 SQL이 임시 정의 |
| setlists_row_cap · setlists_items_owner | 이관(내부 트리거) | nomad_humscore_private.* | | org안은 조직 기준(타 조직 악보 금지) |
| share_links_guard · share_links_no_revive | 이관(내부 트리거) | nomad_humscore_private.* | | org안 활성 링크 200개는 조직당 |
| (신규, org안만) org_immutable | 신규 | nomad_humscore_private.org_immutable | scores·setlists | organization_id 변경 금지 |

## 한도 → plan_limits 키(수치 시드 안 함, 현재는 트리거에 하드코딩)
| 현재 값 | 위치 | 제안 plan_limits 키(product=humscore) |
|---|---|---|
| 살아있는 악보 2000 | scores_row_cap | `scores_max` |
| 살아있는 콘티 2000 | setlists_row_cap | `setlists_max` |
| 활성 공유 링크 200 | share_links_guard | `active_share_links_max` |
| 콘티 곡 50 · items 64KB | check 제약 | 플랜 무관(데이터 형식) |

## 로컬 저장소 키·LLM 제공자
키 이관표는 [local-storage.md](local-storage.md). 앱이 쓰는 LLM 제공자: `openai`(OpenAI API, 기본 gpt-4o-mini), `claude`(Claude API, claude-3-5-haiku-latest), `gemini`(Gemini API, gemini-1.5-flash). 키는 현재 localStorage `humscore.llm.v1`에만 있고 서버로 가지 않는다(`lib/storage/llm-keys.ts`) → BYOK 이관 대상(task-011 provider_credentials의 제공자 코드 `openai`·`claude`·`gemini`).

## 문서에만 있는 계획 테이블(레포 미구현, 만들지 않음)
folders · tags · score_tags · youtube_sources — 구현되면 같은 규칙(소유 컬럼·updated_at/deleted_at·RLS)으로 새 번호 파일에 추가. `setlist_items`는 문서 계획과 달리 `setlists.items jsonb`로 구현됨.

## 앱 코드 사용 목록 대조(.from/.rpc 전수)
`.from`: scores · setlists · share_links. `.rpc`: get_shared_score · get_shared_setlist · reissue_share_link. 모두 위 표에 있다. transcription_jobs는 코드 사용 없음.
## 전환 시 앱 변경 메모(레포는 수정하지 않음)
- `.schema('nomad_humscore')` 지정, API 노출 스키마 설정.
- org안: 모든 insert에 `organization_id`(개인 사용자는 본인 personal 조직 id, `public.nomad_my_organizations()`) 필요. `user_id`·`owner_id` 필드 제거.
- 원본 `public` 테이블은 레포 쪽에서 별도 이관(데이터 이전은 이 작업 범위 밖).

## 운영 데이터 이관 (task-032, user안)
스크립트: 제품 레포 `supabase/nomad-cutover/`(01_freeze·01_freeze_undo·02_copy·check.sh), 절차: 제품 레포 `docs/ops/NOMAD_DB_CUTOVER.md`.
| 옛 값 | 새 값 | 규칙 |
|---|---|---|
| public.scores·setlists·share_links·transcription_jobs | nomad_humscore 같은 이름 | 열 그대로 복사(user_id·owner_id 유지), id·created_at·updated_at·deleted_at 원본 유지 |
| 플랜 | 없음 | 옛 DB 에 플랜 값이 없다 → subscriptions 행 만들지 않음(구독 없음 = C) |
| profiles·조직 | 없음 | user안이라 nomad_core 에 쓰는 행 없음 |
- 제외·중단 규칙: 익명 사용자 소유 행 1건이라도 있으면 건수만 알리고 중단. 대상 표가 비어 있지 않으면 재실행 거부.
- 복사 중 `session_replication_role = replica`(트랜잭션 한정)로 행 수 제한·touch·콘티 소유 확인·링크 가드 트리거를 끈다 — 삭제된 악보를 가리키는 콘티, 회수된 링크, 서버 updated_at 을 그대로 옮기기 위해. FK 도 꺼지므로 끝에서 고아·링크 소유 일치를 직접 검사한다.
