# shorts 기존 DB 분류표 (Shopping-Shorts-Maker → nomad_shorts)

- 원본: `D:\WorkSpace\DEV\Shopping-Shorts-Maker\supabase\migrations\` 51개를 순서대로 적용한 최종 상태를 로컬 DB에 재현해 센 값이다(2026-11-13).
- **확정 수: 테이블 31개**(public 28 + private 3), **함수 166개**(원본 기준: public RPC 래퍼 47 + private 119 · 이식 후 private 117), 트리거 20, 정책 43, 버킷 4, pgmq 큐 3, pg_cron 3, 역할 2.
- 변환: public → `nomad_shorts`(API 노출), private → `nomad_shorts_private`(비노출). 파일: `user/0001_shorts.sql`·`org/0001_shorts.sql`(+`0002_storage.sql`), 검사 `user/check_user.sql`·`org/check_org.sql`.
- 이식 결과 테이블: nomad_shorts 28(user_settings 신규 1 포함, user_profiles 제거) + nomad_shorts_private 3 = 31. 함수: 166 − 2(삭제) = 164.

## 1. 테이블
소유 열은 "user안 → org안". 간접은 `projects`(또는 `accounts`·`affiliate_links`·`publications`)를 거쳐 소유가 정해지는 하위 테이블로, 컬럼은 그대로고 RLS 식만 `organization_role(projects.organization_id)`로 바뀐다.

| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| user_profiles | 대체:nomad_core.profiles(이름) + 이관(기본값) | nomad_shorts.user_settings | 웹 | user_id 유지(개인 설정은 조직로 올리지 않음). name·email 컬럼 삭제 → `profiles.display_name`·`auth.users.email`. `updated_at`·`deleted_at` 추가 |
| accounts | 이관 | nomad_shorts.accounts | 웹·서버 | user_id → organization_id |
| projects | 이관 | nomad_shorts.projects | 웹·서버·워커(RPC) | user_id → organization_id |
| project_events | 이관 | nomad_shorts.project_events | 웹 | 간접(project_id) |
| topics | 이관 | nomad_shorts.topics | 웹·서버 | 간접(project_id) |
| sources | 이관 | nomad_shorts.sources | 웹·서버·확장·워커 | 간접(project_id) |
| scripts | 이관 | nomad_shorts.scripts | 웹·서버 | 간접(project_id) |
| voice_takes | 이관 | nomad_shorts.voice_takes | 웹·서버·워커 | 간접(project_id) |
| renders | 이관 | nomad_shorts.renders | 웹·서버·워커 | 간접(project_id) |
| chat_messages | 이관 | nomad_shorts.chat_messages | 웹·서버 | 간접(project_id) |
| chat_proposals | 이관(클라이언트 접근 없음) | nomad_shorts.chat_proposals | 서버(RPC) | user_id → organization_id |
| extension_connections | 이관 | nomad_shorts.extension_connections | 서버·크롬 확장(토큰 해시) | user_id → organization_id(확장 연결 시 조직 선택) |
| jobs | 이관(큐·작업 상태는 제품 스키마에 유지) | nomad_shorts.jobs | 웹·서버·워커 | 간접(project_id) |
| credit_ledger | 이관(제품 크레딧. nomad_core.credit_ledger와 별개) | nomad_shorts.credit_ledger | 웹(읽기)·RPC | user_id → organization_id(잔액이 조직 단위) |
| publications | 이관 | nomad_shorts.publications | 웹·서버 | 간접(project_id, account_id) |
| video_metrics | 이관 | nomad_shorts.video_metrics | 웹·서버(수집) | 간접(publication_id) |
| policy_checks | 이관 | nomad_shorts.policy_checks | 웹 | 간접(project_id) |
| affiliate_links | 이관 | nomad_shorts.affiliate_links | 웹·서버 | 간접(project_id) |
| bio_pages | 이관 | nomad_shorts.bio_pages | 웹 | 간접(account_id) |
| bio_items | 이관 | nomad_shorts.bio_items | 웹 | 간접(bio_page_id→account) |
| link_clicks | 이관 | nomad_shorts.link_clicks | 웹(읽기)·서버(기록) | 간접(affiliate_link_id) |
| api_keys | 이관(키 본문은 vault, 여기는 참조·끝 4자리) | nomad_shorts.api_keys | 웹(읽기) | user_id → organization_id |
| oauth_states | 이관(클라이언트 접근 없음) | nomad_shorts.oauth_states | 서버(RPC) | user_id → organization_id |
| channel_slot_events | 이관 | nomad_shorts.channel_slot_events | 웹(읽기)·RPC | user_id → organization_id |
| publication_upload_sessions | 이관(클라이언트 접근 없음) | nomad_shorts.publication_upload_sessions | 서버(RPC) | 간접(publication_id). 소유 컬럼 없음 확인 |
| youtube_upload_quota | 이관(전역 일일 합계, 소유 없음) | nomad_shorts.youtube_upload_quota | 서버(RPC) | 없음 |
| categories | 이관(공용 읽기) | nomad_shorts.categories | 웹 | 없음(전체 공개 읽기) |
| trend_items | 이관(공용 읽기) | nomad_shorts.trend_items | 웹 | 없음(전체 공개 읽기) |
| private.channel_quotas | 이관(비노출) | nomad_shorts_private.channel_quotas | 서버 내부 | user_id → organization_id (개별 한도 재정의. 아래 3절) |
| private.click_salts | 이관(비노출) | nomad_shorts_private.click_salts | 서버 내부 | 없음 |
| private.metrics_runs | 이관(비노출) | nomad_shorts_private.metrics_runs | 서버 내부 | 없음 |

anon에게 주는 권한은 없다(원본도 공개 읽기 없음). 공용 읽기 2개(categories·trend_items)는 `authenticated`만이다.

## 2. 함수·트리거·확장
| 원래 | 분류 | 새 이름 | 사용처 |
|---|---|---|---|
| private.handle_new_user + auth.users 가입 트리거 | 삭제(nomad_core.handle_new_user 대체) | — | DB |
| private.channel_quotas_seed | 삭제(기존 데이터 이전용) | — | 일회성 |
| 트리거 20개와 그 함수(set_updated_at 외) | 이관 | nomad_shorts_private.* | DB |
| public RPC 래퍼 47개(아래) | 이관, 이름 유지 | nomad_shorts.<같은 이름> | 웹·서버 |
| private 함수 117개(본체·헬퍼·트리거 함수 포함 = 원본 119 − 삭제 2) | 이관, 이름 유지 | nomad_shorts_private.<같은 이름> | RPC 본체·워커·cron |
| pgmq 큐 render·tts·analyze | 이관, 접두 | shorts_render·shorts_tts·shorts_analyze | 워커 |
| pg_cron sweep-jobs·collect-metrics·cleanup-analytics | 이관, 접두 | shorts_sweep_jobs·shorts_collect_metrics·shorts_cleanup_analytics | cron |
| 역할 worker_role·worker_login | 이관(비밀번호는 별도 설정) | 이름 유지 | 워커 |
| Realtime 발행 projects | 이관 | nomad_shorts.projects | 웹 |

- **웹이 부르는 RPC(authenticated)**: add_direct_source, approve_step, assign_bio_number, chat_consume_proposal, chat_start_collect, confirm_policy_check, create_job, edit_input_sources, mark_step_ready, prepare_publication, publication_confirm_absent, publication_retry, publish_policy, request_step_change, save_source_use, set_source_checks.
- **서버(service_role)가 부르는 RPC**: channel_slot_status, chat_create_proposal, extension_claim_job, extension_collect_download, extension_collect_list, extension_heartbeat, metrics_run_finish, metrics_run_start, metrics_targets, oauth_state_consume, oauth_state_create, publication_attempt_fail, publication_claim, publication_finish, publication_reject_copy, publication_resume_check, publication_session_begin, publication_session_save, publish_recheck, queue_health, record_link_click, retention_confirm, retention_due, retention_mark_deleted, retention_reserve, save_video_metrics, youtube_clear_token, youtube_expire_token, youtube_refresh_token, youtube_save_connection, youtube_token_for.
- **워커(worker_login)가 직접 부르는 함수**(psycopg, `nomad_shorts_private.`): job_start, job_succeed, job_fail, job_retry, job_heartbeat, job_stop, render_job_context, save_render, tts_job_context, save_voice_take, analyze_sources_context, save_source_scores (+ release_job·settle_job·job_user_busy·job_time_limit).
- 앱의 `private.` 스키마 접두 7곳(워커 db.py·render·analyze·tts)은 `nomad_shorts_private.`로 바꿔야 한다.
- org안의 함수 변경: `projects.user_id = auth.uid()` 검사는 모두 `nomad_core.organization_role(organization_id) in ('owner','admin','editor')`로, `create_job`은 크레딧·동시 작업 수·잠금을 조직 단위(`v_org`)로 센다. 멱등 키 접두(`<user>:<key>`)는 사용자 단위로 둔다.

## 3. 한도 컬럼 → nomad_core.plan_limits 키 (수치는 시드하지 않음)
| 원본 위치 | 현재 값 | plan_limits 키(product_code=`shorts`) |
|---|---|---|
| private.channel_quotas.channel_limit / channel_limit_of() 기본 | 기본 1, 상한 50 | `channel_limit` |
| private.job_queue_limit(type) | render 3 · tts 5 · analyze 5 | `queue_limit_render`·`queue_limit_tts`·`queue_limit_analyze` |
| private.job_cost(type) | render 30 · tts 10 · analyze 5 · select_sources 5 | `job_cost_render`·`job_cost_tts`·`job_cost_analyze` (크레딧 충전량은 `credits_monthly`) |
| 보관 기간(retention 함수) | 원본 7일·프로젝트 30일 등 | `retention_days_*` (필요 시) |
| 채널 연결 슬롯 30일 회전 | 30일 | 상수 유지(플랜 아님) |

## 4. 스토리지 버킷 (`0002_storage.sql`)
| 버킷 | 한도 | 분류 | 경로 규칙(user안 → org안) |
|---|---|---|---|
| shorts-sources (원래 sources) | 200MiB, mp4·mov·webm | 이관 | `<user_id>/<project_id>/…` → `<organization_id>/<project_id>/…` |
| shorts-voices (원래 voices) | 50MiB, 오디오 | 이관 | 같음 |
| shorts-renders (원래 renders) | 200MiB, mp4 | 이관 | 같음 |
| shorts-thumbnails (원래 thumbnails) | 512KiB, jpeg·webp | 이관 | 같음 |
모두 비공개, `storage.objects` 정책 없음(서버가 서명 URL 발급).

## 5. 앱 변경이 필요한 곳 (이 작업에서는 레포를 고치지 않음)
- 웹 `.from("user_profiles")` 1곳(server/projects/queries.ts) → `user_settings` + 이름은 `nomad_core.profiles`. 스키마 지정 `db: { schema: "nomad_shorts" }`(전 클라이언트).
- org안: projects·accounts INSERT에 `organization_id`를 넘겨야 한다(기본값 auth.uid() 없음). 서비스 키 RPC(`oauth_state_create`·`youtube_*`·`chat_create_proposal` 등)의 `p_user_id` 인자는 `p_organization_id`가 된다.
- 워커: `private.` → `nomad_shorts_private.`.

- **이름 대응표(원래 → 새)**: 버킷 sources→shorts-sources, voices→shorts-voices, renders→shorts-renders, thumbnails→shorts-thumbnails. 큐 render→shorts_render, tts→shorts_tts, analyze→shorts_analyze. cron sweep-jobs→shorts_sweep_jobs, collect-metrics→shorts_collect_metrics, cleanup-analytics→shorts_cleanup_analytics. 웹 `storage.from("…")` 5곳·`bucket:` 3곳과 워커의 큐 이름 인자가 바뀐다. `job_queue()`·`create_job`(pgmq.send)·`queue_health`·`retention_candidates`(버킷 값)는 SQL 안에서 이미 새 이름이다. job type 값(render·tts 등)은 그대로.

## 6. 결정 기록 (팀장 승인 2026-11-13)
1. 큐·버킷·cron 이름에 shorts 접두 적용(위 대응표).
2. user_settings 신설 방식 승인.
3. org안에서 extension_connections·api_keys·credit_ledger 조직 소유 승인.
4. 동기화 대상은 user_settings 하나(`local-storage.md`).
