# LOTTO-LAB 기존 DB → nomad_lottolab 분류표

원본: D:\WorkSpace\DEV\LOTTO-LAB\supabase\migrations (6개) · docs/05_DATA_MODEL.md. 스키마 `nomad_lottolab`(API 노출) · `nomad_lottolab_private`(내부). 판단: 개인형(user안)이 기본, org안은 변환 가능성 확인용(개인 데이터 = 1인 조직).
앱 코드가 쓰는 이름: 테이블 `fortune_profiles`·`user_consents`(모바일 supabase-js), EF `account-delete`·`waitlist`·`waitlist-confirm`, REST `rpc/waitlist_*`(EF), `rest/v1/waitlist_signups`(EF 통합 테스트). 데스크톱·웹은 공개 읽기만.

## 테이블
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| public.game_type(enum) | 이관 | nomad_lottolab.game_type | 전 테이블 | 해당 없음 |
| waitlist_signups | 이관(소유 없음, service_role) | nomad_lottolab.waitlist_signups (+0002 확인 컬럼 병합) | 웹 EF(waitlist·confirm) | 없음 |
| private.rate_limits | 이관(내부) | nomad_lottolab_private.rate_limits | EF 레이트리밋 | 없음 |
| ingestion_runs | 이관(service_role만) | nomad_lottolab.ingestion_runs | 수집 워커·관리자 | 없음 (reviewed_by만 auth.users) |
| draws_lotto · draws_pension | 이관(anon 공개 읽기) | nomad_lottolab.draws_lotto · draws_pension | 모바일·데스크톱·웹(app-core fetch) | 없음 |
| statistics_cache | 이관(anon 공개 읽기) | nomad_lottolab.statistics_cache | 모바일·데스크톱 | 없음 |
| generator_profiles | 이관 | nomad_lottolab.generator_profiles | 모바일(예정) | user_id → organization_id |
| generated_batches · generated_numbers | 이관(추가 전용) | 같은 이름 | 모바일 | batches: user_id → organization_id, numbers는 batch 경유 |
| saved_tickets | 이관 | nomad_lottolab.saved_tickets | 모바일 | user_id → organization_id, 멱등 키 unique (org, key) |
| draw_checks | 이관(쓰기 service_role) | nomad_lottolab.draw_checks | 서버 판정 | ticket 경유 |
| fortune_profiles | 이관 | nomad_lottolab.fortune_profiles | 모바일 `.from("fortune_profiles")` | user안 PK user_id. org안 PK (organization_id, user_id): 조직 안에서도 본인만 CRUD(owner·admin도 못 봄). 앱 upsert 충돌 키 `organization_id,user_id`, user_id는 기본값 auth.uid() |
| user_consents | 이관(추가 전용) | nomad_lottolab.user_consents | 모바일 `.from("user_consents")` | organization_id 추가, user_id는 동의한 사람(행위자)으로 유지 |
| push_devices (문서만) | 신규(app/) | nomad_lottolab.push_devices | 모바일·데스크톱 알림 | user_id 유지(기기는 사람 소속) |
| subscription_accounts (문서만, P2) | 신규(app/) | nomad_lottolab.subscription_accounts | 스토어 영수증 검증 | user_id 유지. state 값은 Q3 후 확정, 팀 결제는 nomad_core.subscriptions |
| profiles·조직·멤버십·플랜 | 대체 | nomad_core.profiles·organizations·memberships·plans | — | (레포에 없음, 신규 생성 금지) |

## 동기화 컬럼 (task-012 추가 요구)
generator_profiles · saved_tickets · fortune_profiles: `updated_at not null default now()` + `deleted_at` + `nomad_core.touch_updated_at()` 트리거 + `(소유, updated_at)` 인덱스(fortune은 PK). generated_*·user_consents는 추가 전용이라 증분 동기화 대상이 아님(내려받기만). 원본 `updated_at` null 허용·fortune 전용 트리거는 대체.

## 함수·RPC
| 원래 이름 | 분류 | 새 이름 | 사용처 |
|---|---|---|---|
| public.waitlist_rate_hit | 이관(이름 유지) | nomad_lottolab.waitlist_rate_hit | EF waitlist (service_role) |
| public.waitlist_request_confirm | 이관 | nomad_lottolab.waitlist_request_confirm | EF waitlist |
| public.waitlist_confirm | 이관 | nomad_lottolab.waitlist_confirm | EF waitlist-confirm |
| private.valid_numbers · valid_ticket | 이관(내부) | nomad_lottolab_private.valid_numbers · valid_ticket | CHECK |
| private.saved_tickets_guard_transition · _check_source | 이관(내부 트리거) | nomad_lottolab_private.* | saved_tickets |
| private.fortune_profiles_set_updated_at | 삭제 | nomad_core.touch_updated_at 로 대체 | — |
| pg_cron: waitlist_purge_6m · rate_limits_purge · waitlist_purge_unconfirmed | 이관(pg_cron 있을 때만 등록) | 같은 이름 | 서버 |
| EF account-delete | 레포 유지 | auth 사용자 삭제 → user안은 CASCADE 파기, org안은 삭제 **전에** `rpc('purge_personal_org_data', {p_user_id})`(결정 8) | 모바일 |
| (신규, 2026-11-16 결정 8) purge_personal_org_data(user) | 신규(service_role만) | nomad_lottolab.purge_personal_org_data | EF account-delete |

- EF의 `/rest/v1/rpc/…`·`/rest/v1/waitlist_signups` 호출은 `Content-Profile`/`Accept-Profile: nomad_lottolab` 헤더와 API 노출 스키마 설정이 필요하다(레포 수정은 이 작업 범위 밖, 팀장 확인).
- 버킷: 없음(스토리지 사용 안 함).
- 한도(plan_limits 키 후보): 현재 한도 컬럼 없음. 저장 티켓·프리셋 수 제한이 생기면 `saved_tickets_max`·`generator_profiles_max` 키로(수치 시드 안 함).

## EF account-delete 계약 (org안, 2026-11-16 결정 8)
1. EF(service_role)가 **auth 사용자 삭제 전에** `nomad_lottolab.purge_personal_org_data(p_user_id)`를 부른다. 삭제 뒤에는 멤버십이 사라져 대상 조직을 찾을 수 없다.
2. 대상: `kind='personal'`이고 멤버가 그 사용자 1명뿐인 조직. 다른 사람이 함께 있는 조직·팀 조직은 건드리지 않는다.
3. 조직 행은 남긴다(결제 원장·다른 제품 데이터 보존). nomad_lottolab 행(saved_tickets→draw_checks, generated_batches→generated_numbers, generator_profiles, fortune_profiles, user_consents)만 지운다. 반환 jsonb에 조직 수·표별 행 수.
4. 그다음 auth 사용자를 삭제한다(fortune_profiles·user_consents·push_devices·subscription_accounts는 user_id CASCADE로도 지워진다). RPC가 실패하면 사용자 삭제를 하지 않고 재시도한다.
