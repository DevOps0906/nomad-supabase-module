# shorts 기존 DB 분류표 (Shopping-Shorts-Maker → nomad_shorts)

- 원본: `D:\WorkSpace\DEV\Shopping-Shorts-Maker\supabase\migrations\` 51개를 순서대로 적용한 최종 상태를 로컬 DB에 재현해 센 값이다(2026-11-13).
- **확정 수: 테이블 31개**(public 28 + private 3), **함수 166개**(원본 기준: public RPC 래퍼 47 + private 119 · 이식 후 private 117), 트리거 20, 정책 43, 버킷 4, pgmq 큐 3, pg_cron 3, 역할 2.
- 변환: public → `nomad_shorts`(API 노출), private → `nomad_shorts_private`(비노출). 파일: `user/0001_shorts.sql`·`org/0001_shorts.sql`(+`0002_storage.sql`), 검사 `user/check_user.sql`·`org/check_org.sql`.
- 이식 결과 테이블: nomad_shorts 28(user_settings 신규 1 포함, user_profiles 제거) + nomad_shorts_private 3 = 31. 함수: 166 − 2(삭제) = 164.
- 원본 52~59번째(3face90 `legacy-migrations/` 의 20261113150000~20261114110300 8개)는 `{user,org}/0003_queue_extension.sql`로 이식했다(7절, task-023). 위 수는 0001 기준이다.

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

## 7. 원본 52~59번째 이식 (task-023, `{user,org}/0003_queue_extension.sql`)
근거: Shopping-Shorts-Maker 커밋 3face90 `supabase/legacy-migrations/`. 같은 함수를 여러 번 바꾼 것은 최종본 하나로 합쳤다.

| 원본 파일 | 처리 | 새 이름·내용 | org안 차이 |
|---|---|---|---|
| 20261113150000_job_backpressure | **교정 이식**(0001에 들어 있었지만 큐 이름과 job type 을 섞어 비교해 상한·미룸·적체가 동작하지 않음) | `job_queue_limit(p_queue)`·`job_user_busy(p_job_id, p_queue)` 다시 만듦(인자 이름 변경이라 drop→create), `queue_health` 큐 기준 집계, `create_job` 큐 기준 상한 | job_user_busy 는 워커 호출이라 `organization_role` 대신 소유 조직으로 비교(0001 org안은 항상 false) |
| 20261113160000_job_queue_status | 이관 | `nomad_shorts.job_queue_status()`(authenticated) → `nomad_shorts_private.job_queue_status`, `job_queue_slots`·`upload_est_seconds`·`job_eta_basis`, 인덱스 `jobs_succeeded_type_finished_idx`. 슬롯 키는 `shorts_*` 큐 이름 | "본인" → 내가 속한 조직(`organization_role is not null`), 미룸·순번 계산은 조직 단위 |
| 20261114100000_analyze_thumbnail_context | 이관 | `analyze_sources_context` 에 `thumbnail_path` | 반환 키 `organization_id`(0001과 같음) |
| 20261114100100_quarantine_sticky | 이관 | `save_source_scores`: 격리는 재분석으로 풀리지 않음 | 없음 |
| 20261114110000_extension_auth | 이관 | `extension_connections` 열 3개(prev_refresh_token_hash·rotated_at·activated_at, authenticated 열 권한 없음), `nomad_shorts_private.rate_counters`(RLS, 정책 없음), RPC `extension_issue`·`extension_authenticate`·`extension_rotate`·`extension_revoke`·`extension_rate_hit`(service_role), `ext_heartbeat` 가 activated_at 기록 | `p_user_id` → `p_organization_id`, `extension_authenticate` 반환 열 `organization_id` |
| 20261114110100_extension_reports | 이관 | `jobs.files_reported_at`, 부분 unique `jobs_one_active_collect_download_idx`(+기존 중복 정리 update), 큐 **sources → shorts_sources**(권한은 0001 큐와 같음), RPC `extension_report_complete`·`extension_report_abort`(service_role) | 확장·작업 소유 비교가 organization_id |
| 20261114110200_extension_sweeper_guards | 이관(최종본에 합침) | `sweep_jobs`: 보고된 collect_download 는 끊김 제외, 미활성 10분 확장 폐기, 1일 지난 속도 창 삭제. `set_source_checks`: 활성 확장 작업 중 EX001. `create_job` 중간본은 110300 으로 대체 | 크레딧 반환 행이 organization_id |
| 20261114110300_extension_review_fixes | 이관 | `create_job`: 활성 확장 작업 중 collect·collect_download·select_sources EX001, collect_download 도 waiting_extension 으로 시작(0001은 queued 로 넣고 null 큐에 send 하던 차이 해소). `ext_collect_download`: 보고 뒤 기록 EX409. `rate_hit`: 키 접두 `ext:`·`user:`·`ip:` 만 | create_job 은 0001 org안처럼 잔액·대기 수·잠금을 조직(`v_org`)으로, 멱등 키 접두는 사용자 |

- 이식하지 않은 항목: 없음. 원본의 기존 데이터 정리 update 2건(activated_at 채우기, 중복 collect_download superseded)은 새 설치에서는 0건이라 그대로 두었다.
- 앱 변경: 워커는 큐 `sources` 대신 `shorts_sources` 를 읽는다. org안 서버는 `extension_issue`·`extension_revoke` 에 조직 id 를 넘기고 그 전에 조직 권한을 확인해야 한다.
- 팀장 확인 필요: (1) org안 `rate_hit` 키 접두에 `org:` 를 추가할지(지금은 원본 그대로 ext·user·ip). (2) [해결] 0001 org안 `ext_job_project` 의 확장 소유 검사를 `organization_role(e.organization_id)`(서버 호출에서 항상 42501) → `e.organization_id = v_uid`(프로젝트 조직, 0003 `ext_report_job` 과 같은 비교)로 교정. 미배포 이식본이라 0001 을 직접 고쳤고 `check_org.sql` 에 collect_list·collect_download 정상 기록과 다른 조직 확장 42501 검사를 추가했다.
- 검사: `check_{user,org}.sql` 에 0003 절(상한·미룸·적체, 순번 교차 노출, 토큰 발급·회전·재사용 폐기·교차 폐기, 보고 교차 거부·재전송·재검사 메시지, 활성 collect_download 1개, EX001, 속도 제한) 추가.

## 보안 리뷰 메모 (task-023, 2026-11-16) — 앱 계약
- `extension_issue`는 p_organization_id를 검증하지 않는다(service_role 전용). 앱 서버는 발급 전에 호출자가 그 조직의 owner·admin인지(`nomad_core.organization_role`) 반드시 확인한다. 비멤버 발급 거부는 앱 책임이다.
- `rate_hit` 키는 호출자가 만든 문자열이다. IP·사용자 값은 서버에서 정규화·해시해 넣는다(예: `ip:<sha256 앞 32자>`). 원문 IP를 그대로 넣지 않는다(행 무한 증가·개인정보).
- `job_queue_status`는 다른 조직 작업을 수(순번·예상 시간)로만 반영한다. 조직·프로젝트 식별자는 노출하지 않지만 전체 큐 부하는 간접적으로 드러난다(설계상 수용).

## 8. 운영 데이터 이관 (task-032, org안)
스크립트·절차: Shorts 레포 `supabase/nomad-cutover/`(01 freeze·undo·queue_check, 02 copy, 03 storage, check.sh) · `docs/ops/NOMAD_DB_CUTOVER.md`. 검증: `bash supabase/nomad-cutover/check.sh`.

| 원본 | 대상 | 규칙 |
|---|---|---|
| 1절 표 31개(public 27 + private 4: channel_quotas·click_salts·metrics_runs·rate_counters) | 같은 이름 nomad_shorts·nomad_shorts_private | 열 그대로. 소유 `user_id` 9개 표는 `organization_id` = 그 사용자의 개인 조직(kind='personal', created_by, owner 멤버십). id·created_at·updated_at·번호·상태 원본 유지(replica 모드) |
| user_profiles.name | nomad_core.profiles.display_name | upsert. 이름이 비어 있으면 백필 값 유지 |
| user_profiles 기본값 열 6개 | nomad_shorts.user_settings | user_id 그대로, updated_at = 복사 시각 |
| 저장 경로 4열(sources.file_path·thumbnail_path, voice_takes.audio_path, renders.mp4_path) | 같은 열 | `<user_id>/<project_id>/…` → `<organization_id>/<project_id>/…`. 형식이 다르면 중단 |
| 버킷 sources·voices·renders·thumbnails 객체 | shorts-* (4절) | 03_storage.mjs 서버 측 copy, 같은 경로 규칙, 개수·크기 대조. 옛 버킷 유지 |
| 시퀀스 metrics_runs_id_seq | nomad_shorts_private 같은 이름 | max(id)와 원본 위치 중 큰 값 |

- **플랜 대응표**: 옛 스키마에 플랜 열이 없다 → 대응할 값 없음, `nomad_core.subscriptions` 행을 만들지 않는다(구독 없는 조직 = C 플랜, default_plan).
- **중단 규칙**(02 시작 검사, 하나라도 있으면 변경 없이 중단): 새 표가 비어 있지 않음(재실행 방지) · 옛 pgmq 큐에 메시지 있음(사용자 결정 3) · 익명 사용자 소유 행(건수만 보고, 사용자 결정 2) · 개인 조직 없는 사용자 소유 행 · 경로 형식 불일치.
- **끝 검사**: 표마다 행 수 + 전체 값(대응 규칙 적용) 양방향 대조, FK 고아 행(복합 FK 포함), 소유 조직 일치(chat_proposals·credit_ledger↔project, jobs 확장↔project, channel_slot_events↔account, bio_items↔page·link), 새 경로 형식.
- **옮기지 않음**: user_profiles.email(정본 auth.users.email), 옛 pgmq 메시지, 옛 cron(새 이름으로 마이그레이션이 만든다), jsonb 안 값(jobs.payload 등).
- **freeze 범위**: 옛 public·private 표의 insert·update·delete·truncate와 옛 public RPC(nomad_* 제외) execute를 PUBLIC·anon·authenticated·service_role에서 회수. worker_role은 큐를 비우도록 남긴다. 옛 가입 트리거는 auth.users 소유자가 아니면 disable할 수 없어 트리거 함수 본문을 무력화한다(undo가 원래 정의 복원).
- **앱 계약**: 옛 행과 새 행이 같은 Vault 비밀(accounts.oauth_token_ref·api_keys.secret_ref)을 가리킨다. 옛 표를 정리할 때는 옛 vault_cleanup 트리거를 먼저 없앤다.
