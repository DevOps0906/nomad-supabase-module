# live-poll 기존 DB → nomad_core 이식 대응표 (task-015 P1)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1800_poll.sql`(스키마 `poll`) · 문서 `products/live-poll/`(Next.js 웹, 청중은 Route Handler `/api/p/*` + 참가자 토큰 쿠키, 브로드캐스터 워커).
이식: `org/0001_poll.sql`(조직형만) · `org/0002_ai.sql`(**core 웨이브 후 적용** — AI 기능 이용권만 넣고, 라우팅 시드는 AI 표가 없으면 건너뜀). 스키마 `nomad_poll`(노출) · `nomad_poll_private`(내부, 노출 안 함).
검증: `bash products/poll/run_check.sh` (begin → 청사진 drop → 임시 touch_updated_at → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=진행자 Next.js(authenticated) · 청중=`/api/p/*`(원본 service_role → 결정 D8로 anon 공개 RPC) · 워커=브로드캐스터(service_role) · 서버=정리 작업(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('poll', open, beta) | 대체: nomad_core.products | products('poll') | — |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members(member) | 대체: nomad_core.memberships | owner/admin/editor(쓰기) · viewer(읽기) | member→editor |
| core.has_entitlement(poll) | 대체: nomad_core.has_feature('poll', 'host') · org_has_feature | 정책·RPC | 기능 host = A·B·C |
| core.is_service_caller | 대체 | nomad_poll_private.caller_is_client · host_ok | — |
| core.write_audit | 이관(제품 표) | nomad_poll.audit_logs + nomad_poll_private.write_audit | owner/admin 읽기 |
| plan_feature_int(plans.features) | 대체: nomad_core.org_plan_limit | nomad_poll_private.limit_int | 키 없으면 원본 기본값 |
| (원본 없음) 요청 제한 | 신규(D8) | nomad_poll_private.rate_limits · rate_hit · rate_peek | 청중 입장 실패·투표·질문·추천·행사 생성 |
| core.ai_routing_settings 시드 · plans AI 키 | **core 웨이브 후 적용** | org/0002_ai.sql | 기능 ai_chat·voice_chat·qna_assist·voice_question·event_wiki(A·B·C) |
| core.plans signup_credits 100 · monthly_credits 1,000/5,000 | **core 웨이브(credits) 후** | (넣지 않음) | D2 버킷 분리 채택 후 코어 시드 |

## 테이블 (poll → nomad_poll)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| events | 이관(+deleted_at 소프트 삭제, 7일 뒤 물리 삭제) | nomad_poll.events | 웹 · 청중 RPC · 워커 | org_id → organization_id |
| polls | 이관(draft만 편집) | nomad_poll.polls | 웹 · 청중 RPC | org_id → organization_id |
| poll_options | 이관 | nomad_poll.poll_options | 웹 · 청중 RPC | org_id → organization_id |
| participants | 이관(token_hash 컬럼은 진행자에게도 비공개) | nomad_poll.participants | 청중 RPC · 웹 읽기 | org_id → organization_id |
| votes | 이관(쓰기 cast_vote만) | nomad_poll.votes | 청중 RPC · 웹 읽기 | org_id → organization_id |
| poll_results | 이관 | nomad_poll.poll_results | 웹 · 청중 스냅샷 | org_id → organization_id |
| qna_questions · qna_upvotes | 이관 | nomad_poll.* | 청중 RPC · 웹 | org_id → organization_id |
| banned_words | 이관(organization_id null = 플랫폼 기본, service_role만) | nomad_poll.banned_words | 웹(owner/admin) | org_id → organization_id |
| (core audit_log) | 신규(제품 표) | nomad_poll.audit_logs | 웹 읽기(owner/admin) | organization_id |
| 시퀀스 change_seq | 이관 | nomad_poll.poll_change_seq | 트리거 | — |
- 동기화 대상: events·polls·poll_options·poll_results·qna_questions — `updated_at` + touch 트리거, events·polls·poll_options는 `(organization_id, updated_at)` 인덱스. events만 `deleted_at`(RLS가 숨김, 삭제 전파는 서버가 조회).
- 변경: `qna_questions` 상태 전이에 `answered → hidden` 추가(원본은 빠져 있어 답변된 질문이 있는 참가자를 차단하면 block_participant가 실패 — 검사에서 발견).

## 함수 (poll → nomad_poll, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 권한·변화 |
|---|---|---|---|---|
| create_event · transition_event · set_current_poll · transition_poll · moderate_question · block_participant · rotate_overlay_key · host_poll_results | 이관 | nomad_poll.* | 웹 | authenticated, 역할 owner/admin/editor |
| set_event_passcode · delete_event | 이관 | nomad_poll.* | 웹 | owner/admin만 |
| join_event · participant_snapshot · cast_vote · ask_question · upvote_question · overlay_snapshot | 이관(D8 공개 RPC) | nomad_poll.* | 청중·OBS 오버레이 | **anon**·authenticated 실행(원본 service_role만). 입력 검증 + rate limit, 업무 오류는 `{ok:false, code}` |
| collect_broadcasts | 이관 | nomad_poll.collect_broadcasts | 워커 | service_role만 |
| purge_expired_events | 이관 | nomad_poll.purge_expired_events | 서버(매시간) | service_role만 |
| normalize_text · clean_text | 이관 | nomad_poll.* | 생성 컬럼·RPC | normalize_text만 authenticated |
| contains_banned_word · new_event_code · token_hash · resolve_participant · build_* · finalize_poll · end_event_internal | 이관(내부, 클라이언트 실행 없음) | nomad_poll.* | RPC 내부 | service_role만 |
| events_before_update · polls_before_write · qna_questions_before_update | 이관(트리거) | nomad_poll.* | 트리거 | — |
| plan_feature_int | 대체 | nomad_poll_private.limit_int | RPC 내부 | — |
| (원본 없음) settings 안전 읽기 | 신규 | nomad_poll_private.setting_bool | RPC 내부 | boolean 아닐 때 기본값 |
- Realtime Broadcast 정책(realtime.messages): `poll_broadcast_read_member`(조직 멤버) · `poll_broadcast_read_audience`(서버 발급 단기 JWT의 poll_topic). 토픽 `poll:<organization_id>:<event_id>`.

## plan_limits 키 (수치 시드 안 함 — 괄호는 키가 없을 때 코드 기본값)
| limit_key (product `poll`) | 기본값 | 원본 pro / business |
|---|---|---|
| max_events | 50 | 500 / 2000 |
| max_live_events | 1 | 원본 플랜 참고 |
| max_participants | 100 | 원본 플랜 참고 |
| polls_per_event | 50 | 200 / 500 |
| retention_days | 30 | 원본 플랜 참고 |
| (0002) ai_chat_turns_per_day · qna_assist_runs_per_event · audience_voice_per_event · audience_voice_per_participant · materials_max_docs · materials_max_mb | — | 원본 19.2 참고 |

## 팀장 확인 필요
1. D8: 청중 RPC를 anon에 직접 열었다(원본은 Route Handler가 service_role로 호출). Route Handler 경유를 유지하면 anon grant를 빼도 된다.
2. 키가 없을 때 코드 기본값(max_events 50 등)으로 열린다(fail-open) — school처럼 fail-closed로 바꿀지.
3. `answered → hidden` 전이 추가(원본 버그 수정)를 원본 문서에도 반영할지.
