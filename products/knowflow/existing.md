# KNOWFLOW-AI 기존 DB → nomad_core 이식 대응표 (task-012)

원본: `D:\WorkSpace\DEV\KNOWFLOW-AI\supabase\migrations\` 17개(최종 상태) · 앱 코드 `apps/web`(@supabase/ssr) · `apps/worker`(pg.Pool, SET ROLE service_role).
이식: `user/0001_knowflow.sql`+`0002_storage.sql`(단일안, 소유 user_id) · `org/…`(조직안, 소유 organization_id). 스키마 `nomad_knowflow`(노출) · `nomad_knowflow_private`(내부, 노출 안 함).
검증: `bash products/knowflow/run_check.sh user|org` (begin → 청사진 drop → 적용 → 교차 거부 → rollback, 둘 다 통과).
사용처 약어: 웹=apps/web, 워커=apps/worker, 서버=웹 서버(service_role).

## 테이블 (public → nomad_knowflow)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| plans | 대체: nomad_core.plans + plan_limits | (만들지 않음) 한도 키는 아래 표 | 쿼터 RPC 내부 | — (beta 1종 → 제품 플랜 A·B·C, 시드는 코어) |
| profiles | 대체: nomad_core.profiles | (만들지 않음) | RPC 내부만(웹 직접 사용 없음) | — |
| user_quotas | 이관(사용량만. plan_code 컬럼 삭제) | user: nomad_knowflow.user_quotas / org: nomad_knowflow.org_quotas | RPC 내부 · 웹 읽기(본인) | user_id → organization_id (조직 단위 월 사용량) |
| projects | 이관 | nomad_knowflow.projects | 웹 select·RPC · 워커 update/join | user_id → organization_id |
| sources | 이관(youtube·재확인 컬럼 포함) | nomad_knowflow.sources | 웹 select·RPC · 워커 직접 SQL | user_id → organization_id |
| source_chunks | 이관(직접 접근 deny_all) | nomad_knowflow.source_chunks | RPC·워커 | project 경유(소유 컬럼 없음, 그대로) |
| source_moments | 이관 | nomad_knowflow.source_moments | 워커 RPC 쓰기 · 웹 읽기 | user_id → organization_id |
| conversations | 이관(+deleted_at) | nomad_knowflow.conversations | 웹(대화) | user_id → organization_id |
| messages | 이관 | nomad_knowflow.messages | 웹 | 간접(대화 경유) |
| reports | 이관(+deleted_at) | nomad_knowflow.reports | 웹·워커(report_generate) | user_id → organization_id |
| report_citations | 이관 | nomad_knowflow.report_citations | 웹 | 간접(리포트 경유) |
| processing_jobs | 이관 | nomad_knowflow.processing_jobs | 웹 RPC·워커 RPC | user_id → organization_id |
| usage_events | 이관(원 단위 정수) | nomad_knowflow.usage_events | 워커 insert · 웹 읽기 | user_id(null 허용) → organization_id(null 허용) |
| idempotency_keys | 이관(내부) | nomad_knowflow_private.idempotency_keys | RPC 내부 | PK (user_id,key) → (organization_id,key) |
| auth_rate_limits | 이관(내부) | nomad_knowflow_private.auth_rate_limits | RPC 내부 | 비식별 키(소유 컬럼 없음) |
- 동기화 대상 4개(projects·sources·conversations·reports): `updated_at`·`deleted_at`·`nomad_core.touch_updated_at()` 트리거·`(소유 컬럼, updated_at)` 인덱스(`*_user_sync_idx`/`*_org_sync_idx`). conversations·reports는 `deleted_at`을 새로 추가했다(원본에는 없음). RLS는 `deleted_at is null`만 보여 주고, 삭제 전파는 서버/RPC(service_role)가 `deleted_at > 마지막 동기 시각`으로 조회한다.

## plan_limits 키 (수치 시드 안 함 — 원본 beta 값은 참고용, 설정은 코어 시드가 정한다)
| 원본 컬럼 (plans) | limit_key (product `knowflow`) | 원본 beta 값 |
|---|---|---|
| max_projects | max_projects | 20 |
| max_sources_per_project | max_sources_per_project | 50 |
| monthly_questions | monthly_questions | 300 |
| monthly_reports | monthly_reports | 30 |
| monthly_source_jobs | monthly_source_jobs | 100 |
| max_video_seconds | max_video_seconds | 7200 |
| monthly_video_seconds | monthly_video_seconds | 72000 |
- org안: `nomad_core.org_plan_limit(조직, 'knowflow', 키)`(구독 없으면 플랜 C). user안: 조직이 없으므로 plan_limits의 knowflow **플랜 C 행**을 읽는다(`nomad_knowflow_private.limit_of`). 값이 없으면 `quota_not_initialized`(P0002)로 거부(fail-closed) — 코어 시드가 먼저 필요.

## 함수 (public → nomad_knowflow, 이름 유지. 본문은 새 스키마·소유로 변경)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 시그니처·소유 변화 |
|---|---|---|---|---|
| create_project | 이관 | nomad_knowflow.create_project | 웹 RPC | org안만 첫 인자 `p_organization_id uuid` 추가 |
| update_project · delete_project | 이관 | nomad_knowflow.* | 웹 RPC | 동일(org안: 대상 프로젝트의 조직에서 owner·admin·editor만) |
| register_pdf_source | 이관 | nomad_knowflow.register_pdf_source | 웹 RPC | 동일. 저장 경로 첫 폴더 user_id→organization_id, 버킷 knowflow-sources |
| register_youtube_source | 이관(service_role) | nomad_knowflow.register_youtube_source | 서버 RPC | 첫 인자 `p_user_id` → org안 `p_organization_id` |
| retry_source · delete_sources · get_source_chunks · list_project_jobs | 이관 | nomad_knowflow.* | 웹 RPC | 동일(조회는 멤버 전원, 변경은 owner·admin·editor) |
| consume_auth_rate_limit | 이관(anon·authenticated 호출) | nomad_knowflow.consume_auth_rate_limit | 웹 RPC | 동일 |
| claim_job · heartbeat_job · progress_job · complete_job · fail_job | 이관(service_role) | nomad_knowflow.* | 워커 RPC | 동일 |
| replace_source_chunks · replace_source_moments · apply_source_recheck · sweep_source_rechecks | 이관(service_role) | nomad_knowflow.* | 워커 RPC | 동일 |
| consume_quota · consume_quota_for · refund_quota · refund_source_video_seconds | 이관(내부화) | nomad_knowflow_private.* | RPC 내부 | org안은 `consume_quota`(auth 기준)를 삭제하고 `consume_quota_for(조직 id,…)`만 둔다. user안은 `consume_quota`(auth 기준)도 `nomad_knowflow_private`에 유지한다(내부 RPC가 호출, 노출 안 함). `refund_quota`의 service_role grant 회수(앱 코드 직접 호출 없음). 월 사용량 행은 첫 차감 때 지연 생성 |
| claim_idempotency_key · enqueue_job · sync_source_status · reap_expired_jobs · current_period_start | 이관(내부) | nomad_knowflow_private.* | RPC 내부 | org안 `claim_idempotency_key`는 첫 인자 조직 id |
| (신규) limit_of / org_limit · ensure_quota · can_write | 신규(내부) | nomad_knowflow_private.* | RPC 내부 | plan_limits 조회, 쓰기 권한(org안) |
| (신규, task-017) ask_question(대화 id, 내용, 멱등 키) | 신규 | nomad_knowflow.ask_question | 웹 RPC(authenticated) | 반환 `{message_id, answer_id, duplicate}`. org안은 쓰기 역할(owner·admin·editor)만 |
| (신규, task-017) save_answer(질문 메시지 id, 내용, 인용 jsonb) | 신규 | nomad_knowflow.save_answer | 서버 RPC(service_role) | 반환 `{answer_id, duplicate}`. 질문당 답변 1개(`messages.reply_to`) |
| (신규, task-017) create_report(프로젝트 id, 제목, 멱등 키) | 신규 | nomad_knowflow.create_report | 웹 RPC(authenticated) | 반환 `{report_id, job_id, duplicate}`. 보고서(generating)+report_generate 잡 생성 |
| handle_new_user(auth.users 트리거) · update_profile | 대체: nomad_core.handle_new_user(프로필·개인 조직 자동 생성) | (만들지 않음) | 앱 직접 사용 없음 | — |
| touch_updated_at | 대체: nomad_core.touch_updated_at (task-011, 그 전엔 검사 때 임시 정의) | (만들지 않음) | 트리거 | — |

## Storage · 역할 · 확장
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| 버킷 `sources`(private, PDF, 50MB) | 이관 | `knowflow-sources` | 웹(업로드·서명 URL) | 앱 코드의 버킷명 변경 필요. 경로 `<소유 id>/<project_id>/<uuid>.pdf`. user안 첫 폴더=user_id, org안=organization_id |
| 정책 sources_objects_select/insert_own | 이관 | knowflow_sources_objects_select/insert_(own\|org) | 웹 | org안: 조회=멤버, 업로드=owner·admin·editor |
| 롤 `knowflow_worker`(LOGIN, service_role 부여) | 삭제(클러스터 롤 — 이 SQL 범위 밖) | 배포 환경에서 별도 생성 | 워커 | 워커는 `SET ROLE service_role`로 `nomad_knowflow.*` 호출 |
| 확장 pg_trgm | 유지(`create extension if not exists`) | — | 키워드 검색 | — |
- 워커 직접 SQL이 `public.sources`·`public.projects`·`public.usage_events`를 쓰므로 스키마 접두를 `nomad_knowflow.`로, 소유 컬럼을 `organization_id`(org안)로 바꿔야 한다.
- 웹은 `.from("projects")`·`.from("sources")`·`.rpc(...)`에 `schema: 'nomad_knowflow'`(supabase-js `db.schema`)가 필요하고, Supabase API 노출 스키마에 `nomad_knowflow`를 추가한다(`nomad_knowflow_private`는 노출 금지).

## 기능 잠금 (task-007, 2026-11-16) — 쿼터는 자체 월간 쿼터 유지(core 크레딧 아님)
| 쓰기 경로 | 기능(`knowflow`) | 잠금 위치 | 잠김 시 |
|---|---|---|---|
| 대화 생성(conversations insert) · 질문 생성(task-017부터 `ask_question` RPC, 트리거는 방어선) | knowledge_chat | 대화: BEFORE INSERT 트리거 `nomad_knowflow_private.require_chat_feature` · 질문: RPC 안 인가 직후·멱등 키 전 | KF403 `feature_locked`(HINT 기능). assistant 답변(`save_answer`)은 허용 |
| 보고서 생성(task-017부터 `create_report` RPC, 트리거는 방어선) | space_reports | RPC 안 인가 직후·멱등 키 전 + BEFORE INSERT 트리거 `nomad_knowflow_private.require_reports_feature` | KF403(C 플랜에는 space_reports 없음 → 무료 조직은 항상 잠김) |
| register_pdf_source · register_youtube_source · retry_source | knowledge_base | RPC 안, 인가(프로젝트·자료 조회) 직후·멱등 키 전 `require_feature` | KF403(존재 노출 없음: 남의 것은 계속 P0002) |
- org안: `nomad_core.org_has_feature(조직, 'knowflow', 기능)`. user안: 사용자가 owner인 활성 조직(가입 시 개인 조직) 중 하나라도 기능이 열려 있으면 허용(`user_has_feature`와 같은 기준, 서버 경로용으로 사용자 id를 받음).
- 구독이 끊기면(만료·inactive) C 플랜 기능만 남는다. 잠겨도 읽기(select·get_source_chunks·list_project_jobs)와 삭제는 막지 않는다. 잠김 상태에서는 같은 멱등 키 재요청도 KF403.
- user안 기준은 owner만: 구독한 팀 조직의 admin·editor에게는 열리지 않는다(검사로 고정). `ends_at` 만료도 inactive와 같이 잠김.
- 자동 경로: `fail_job` 재시도는 같은 잡을 queued로 되돌릴 뿐 쿼터를 다시 차감하지 않고, `sweep_source_rechecks`·`apply_source_recheck`는 유튜브 메타데이터 재확인(30일 보존 정책 준수용) 잡만 만들고 쿼터를 차감하지 않는다 → 잠금 적용 안 함(잠긴 조직도 정책상 재확인·삭제는 계속돼야 함).
- 이관 절차(기존 데이터 복사): 대상 DB에서 conversations·messages·reports insert가 이 트리거에 걸리지 않도록 복사 세션에서 `set local session_replication_role = replica;`로 넣고 끝나면 `origin`으로 되돌린다(잠긴 조직의 과거 기록도 그대로 옮긴다). touch 트리거도 함께 꺼지므로 `updated_at`은 원본 값을 유지한다.
- 멱등 차감 1회·실패 잡 환불은 기존 동작을 검사로 고정(PDF 등록·재시도 재요청 시 source_jobs·video_seconds 1회, fail_job 환불).

## 질문·보고서 월간 쿼터 RPC (task-017, 2026-11-16 사용자 결정: 멱등 RPC 추가)
| 경로 | 순서 | 오류 |
|---|---|---|
| ask_question | 인증 → 대화(본인·org안 쓰기 역할, 삭제 안 됨) 잠금 → knowledge_chat → 멱등 키(요청 해시 = md5(대화 id:내용)) → `monthly_questions` 1 차감 → user 메시지 | 남의·없는 대화 P0002 · 잠김 KF403(같은 키도) · 같은 키 다른 내용 KF409 · 한도 KF429 · 내용 빈 값/2만 자 초과 22023 |
| save_answer | 질문(role user, 대화 삭제 안 됨) 잠금 → assistant 메시지(`reply_to` = 질문) | 질문 아님·없음 P0002. 재저장은 첫 답변 반환(duplicate). 잠김과 무관 |
| create_report | 인증 → 프로젝트 잠금 → space_reports → 멱등 키(md5(프로젝트 id:제목)) → `monthly_reports` 1 차감 → 보고서 generating + report_generate 잡 | P0002 · KF403 · KF409 · KF429 |
| fail_job(최종 실패) · reap_expired_jobs | report_generate 잡: 보고서 generating→failed. 환불은 `reports.quota_charged_period`(create_report가 차감한 달 기록) 표식을 지울 때만 1회, ready 보고서는 환불 없음, 차감한 달이 이번 달이 아니면 사용량 불변 | — |
- 직접 쓰기 차단: service_role의 `messages` insert·update, `reports` insert 권한을 회수했다(서버도 RPC 경유만). 대화(conversations) insert와 보고서 update(워커가 본문·상태 기록)는 그대로.
- 스키마: `messages.reply_to`(답변→같은 대화의 질문, 복합 FK, 질문당 답변 1개 부분 유일 인덱스, assistant만). 이관한 과거 답변은 null.
- 앱 계약 변경: 웹은 질문 저장 `.from('messages').insert` → `rpc('ask_question')`, 보고서 생성 `.from('reports').insert`(+잡 insert) → `rpc('create_report')`, 같은 요청 재시도에 같은 멱등 키. 서버는 답변 저장을 `rpc('save_answer', {p_question_id})`로. 워커는 report_generate 잡 실패를 `fail_job`으로 보고(환불·failed 처리는 DB). KF429 HINT `questions`·`reports`는 한도 초과 안내.
- 이관 절차: 기존 messages·reports 복사는 postgres 세션에서 한다(service_role insert 불가).
- 앱 영향: 웹·서버는 KF403을 "플랜에서 잠긴 기능"으로 처리(업그레이드 안내, HINT로 기능 구분). 서버가 대화·메시지를 직접 insert할 때도 KF403이 난다(유튜브 등록 전 서버의 "기능 플래그 확인"은 DB가 다시 강제). 워커 변경 없음.

## 팀장 확인 필요
1. user안의 한도 기준(플랜 C 행 고정)과 코어의 knowflow 플랜 C 시드 필요.
2. org안 쓰기 역할(owner·admin·editor)·`create_project` 시그니처 변경(조직 id 인자).
3. 버킷 이름 변경(`sources`→`knowflow-sources`)과 앱 코드 스키마 지정 수정(레포 수정은 이 작업 범위 밖).
4. 청사진 `nomad_knowflow`(조직형 spaces·chunks)와 같은 스키마 이름이다 — 둘을 한 DB에 함께 둘 수 없다(검사는 begin 안에서 drop).
5. (task-007) 코어 시드상 C 플랜에 knowledge_base·knowledge_chat이 있어 구독이 끊겨도 실제로는 잠기지 않는다(C 무료 한도로 계속 사용). "끊기면 잠김"을 원하면 C 플랜 기능 시드 조정 필요(검사는 트랜잭션 안에서 C 기능을 빼고 확인).
6. ~~(task-007) 질문·보고서 쿼터 차감 경로 없음~~ → task-017에서 멱등 RPC로 해결(2026-11-16 결정). 남은 확인: 질문 답변 실패 시 질문 쿼터 환불 경로 없음(현재 차감 유지) · 보고서 환불은 차감 표식 기준(지난달 차감분은 환불 안 함), 서버(service_role)는 reports update 권한이 있어 표식을 고칠 수 있음(신뢰 경계) · 질문 길이 상한 2만 자·답변 10만 자는 임의 값 · org안 viewer는 질문 불가(쓰기 역할만).
