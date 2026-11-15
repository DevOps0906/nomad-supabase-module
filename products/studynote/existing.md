# study-note 기존 DB → nomad_core 이식 대응표 (task-015 P2)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2100_notes.sql`(스키마 `notes`, 7표) · 문서 `products/study-note/`(앱 코드 없음, 기획만). knowflow·classroom과 별도 제품(D4).
이식(D5 — 둘 다): `user/0001_studynote.sql`(개인형) · `org/0001_studynote.sql`(조직형) + 각 `0002_ai.sql`(AI 기능·라우팅 시드, 두 파일 내용 같음). 스키마 `nomad_studynote`(노출) · `nomad_studynote_private`(내부).
검증: `bash products/studynote/run_check.sh user` · `bash products/studynote/run_check.sh org` (begin → 청사진 drop → 0001·0002 → `check_<안>.sql` → rollback, 둘 다 통과).
사용처 약어: 웹=Next.js 16(authenticated, 일지·설정·진행률 Realtime), 워커=Node 워커(service_role: start_run·record_step·finish_run·정리 크론), API=FastAPI `apps/api`(새 AI 기능, service_role).

## 형태별 소유 (user안 ↔ org안)
| 표 | user안 소유 | org안 소유 | 비고 |
|---|---|---|---|
| user_settings | PK user_id | PK (organization_id, user_id) | 본인 행만 |
| entries | user_id(기본 auth.uid()) | organization_id + created_by | org안: editor 이상 쓰기, 삭제는 owner·admin |
| runs | user_id + organization_id(과금 조직) | organization_id + created_by | user안 과금 조직 = 사용자가 owner인 조직(가입 시 자동 생성되는 1인 조직) |
| run_steps | user_id | organization_id | — |
| model_catalog · runtime_config · cost_guard | 없음(공통) | 없음(공통) | — |
- 이용권: user안 `nomad_core.user_has_feature('studynote','notes')`(owner인 활성 조직 중 하나), org안 `nomad_core.has_feature(org,'studynote','notes')`. 서버 RPC는 둘 다 `org_has_feature(과금·소유 조직)`.

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('notes') | 대체 | nomad_core.products('studynote') | 제품 키 notes → studynote |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | user안은 runs.organization_id(과금)만 |
| core.org_members(member) · has_org_role · is_org_member | 대체 | nomad_core.memberships(editor) · organization_role | user안 start_run은 role='owner'만 |
| core.has_entitlement(org,'notes') | 대체 | has_feature / user_has_feature / org_has_feature | 조직 비활성 = 잠김 |
| notes.org_features(core.plans.features) | 대체 | 기능 `premium_models` + `nomad_studynote_private.org_limit`(plan_limits) | 아래 표 |
| core.consume_credits(+metadata, actor) | 대체 | nomad_core.consume_credits(org, amount, 'studynote.organize', 'consume:studynote:<request_id>', 'studynote', 'studynote_run', run_id) | 원장 id bigint → uuid |
| core.refund_credits(ledger, reason, amount, key, null) | 대체 | nomad_core.refund_credits(ledger, reason, key, amount) | failed는 fail_job과 같은 요청('job:<작업 id>', 'job_failed', 전액)으로 이중 환불 방지 |
| core.enqueue_job · cancel_job | 대체 | nomad_core.enqueue_job · cancel_job | 큐 'studynote.organize', 작업 유형 'studynote.organize' |
| core.write_audit | 대체 | nomad_core.write_audit | action 'studynote.run.cancel' |
| core.ai_usage(id bigint) | 대체 | nomad_core.ai_usage(id) | run_steps.ai_usage_id FK on delete set null |
| core.set_updated_at · guard_privileged_write · is_privileged_session | 대체 | nomad_core.touch_updated_at · `guard_server_write` · current_user 판별 | 원본과 같은 뜻(사용자 세션만 막음) |
| core.plans 시드(free·pro 가격·월 크레딧) · credit_packs | 삭제(D1) | — | 결제 계약만. 지급은 nomad_core.grant_plan_credits |
| core.ai_routing_settings 시드 13행 | 이관 | nomad_core.ai_routing_settings(product_code 'studynote') | 기능 키 notes.* → studynote.* (organize·quiz·knowledge) |

## 테이블 (notes → nomad_studynote, 7)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| model_catalog | 이관(사용자 읽기, is_active) | nomad_studynote.model_catalog | 웹(모델 선택) · 워커 | 없음 |
| runtime_config | 이관(서버 전용) | 같은 이름 | 워커 | 없음 |
| cost_guard | 이관(서버 전용) | 같은 이름 | 워커(start_run) | 없음 |
| user_settings | 이관 | 같은 이름 | 웹 `.from('user_settings')` | (org_id,user_id) → user안 user_id / org안 (organization_id,user_id) |
| entries | 이관(결과 컬럼 서버만, 소프트 삭제) | 같은 이름 | 웹 CRUD · 워커 | org_id·created_by → user안 user_id / org안 organization_id·created_by |
| runs | 이관(서버 쓰기, Realtime) | 같은 이름 | 웹 읽기·진행률 · 워커 | org_id → user안 user_id(+과금 organization_id) / org안 organization_id |
| run_steps | 이관(서버 쓰기, Realtime) | 같은 이름 | 웹 읽기 · 워커 | org_id → user안 user_id / org안 organization_id |
- 동기화 대상: user_settings·entries — `updated_at` + `nomad_core.touch_updated_at()` + `(소유 컬럼, updated_at)` 인덱스, entries는 `deleted_at`(원본 휴지통 30일).
- entries insert 컬럼 grant에 `id`를 추가했다(원본에 없음) — 오프라인 생성 멱등용(local-storage.md).

## 함수 (notes → nomad_studynote, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 실행 | 변화 |
|---|---|---|---|---|
| guard_entry_write · check_entry_transition · check_run_transition | 이관(트리거) | 같은 이름 | 트리거 | — |
| org_features | 대체 | nomad_core.org_has_feature · `_private.org_limit` | 서버 | — |
| start_run | 이관 | 같은 이름 | service_role | 인자 p_org_id → p_organization_id(user안: 과금 조직). request_id 다른 조직·사용자 재사용 42501 |
| record_step · purge_deleted | 이관 | 같은 이름 | service_role | — |
| finish_run | 이관 | 같은 이름 | service_role | 성공·부분은 nomad_core.mark_job_delivered. 작업이 이미 failed·canceled면 거부(NT003). 환불액만큼 cost_guard 되돌림 |
| (신규) reconcile_runs(p_organization_id default null) | 신규 | 같은 이름 | service_role | 스케줄러가 reap_stale_jobs 뒤 호출: 작업이 failed·canceled인데 queued·running에 남은 실행 정리(단계·실행 종료, 일지 상태 복귀, 예산 되돌림, 크레딧은 core가 이미 환불) |
| enforce_retention | 이관 | 같은 이름 | service_role | user안 인자 (p_user_id, p_organization_id) |
| request_run_cancel | 이관 | 같은 이름 | authenticated | org안: 생성자(editor 이상) 또는 owner·admin(원본은 member 전원, core cancel_job 규칙에 맞춤). user안: 본인만. 남의 실행 P0002 |
| (신규) has_access · can_edit(org안) · guard_server_write | 신규 | nomad_studynote.* | 정책 | user안 has_access()는 인자 없음 |

## 플랜 기능 · plan_limits 키 (수치 시드 안 함 — 원본 값은 참고)
| 원본 features 키 | 새 위치 | A·B(pro) / C(free) |
|---|---|---|
| (정리 기능) | 기능 `notes` | A·B·C (구독 끊김 = C도 정리 가능) |
| allowed_tiers premium | 기능 `premium_models` | A·B (C는 lite·standard) |
| ai_chat · lecture_note · voice_chat · quiz_voice | 같은 이름 기능(0002) | A·B·C |
| max_input_chars | plan_limits `max_input_chars` | 10000 / 5000 (없으면 5000) |
| history_max_entries · history_max_bytes | plan_limits 같은 키 | 500·50000000 / 50·5000000 (없으면 free 값) |
| ai_chat_turns_per_day · ai_subjects_max · ai_docs_max · ai_doc_max_chars · lecture_max_minutes | plan_limits 같은 키(0002 주석) | 200·30·300·100000·120 / 30·5·20·20000·20 (DB 강제 없음, API 검사) |

## 비용 상한(보안 리뷰 반영)
- 전체 일일 예산 `cost_guard`(runtime_config daily_credit_cap 5000): 환불(부분·실패·취소·reconcile)한 만큼 되돌린다 → 한 사용자가 실행·취소를 반복해 전체를 NT005로 막을 수 없다(check 회귀).
- 조직(user안은 과금 조직)별 일일 상한: 오늘(KST) 접수 실행의 순사용(차감 − 환불) + 이번 비용 > 한도면 NT005. 한도 = plan_limits `daily_credit_cap` → 없으면 runtime_config `daily_credit_cap_per_org`(300, 제안) → 없으면 300.
- entries.deleted_at은 클라이언트 값 대신 now()(복원은 null). 스키마 usage는 authenticated·service_role만(anon 0). 제품 함수의 core jobs·credit_ledger 직접 쓰기 0건(check 회귀).

## 앱 변경 (이식 후 웹·워커가 바꿀 것)
- 스키마 `notes.*` → `nomad_studynote.*`, `org_id` → user안 `user_id` / org안 `organization_id`. 원장 id uuid.
- 워커 `start_run(p_organization_id, p_user_id, …)`: user안은 사용자의 과금 조직(1인 조직 id)을 넘긴다.
- 웹 모델 선택: premium 등급 표시는 `has_feature(org,'studynote','premium_models')`(user안 `user_has_feature`)로 잠금.
- Realtime 구독 테이블 이름 변경(`nomad_studynote.runs`·`run_steps`).

## 팀장 확인 필요
1. (C 기능 유지는 승인됨) 플랜 대응 pro→A·B, free→C (원본은 2단계뿐). B를 별도 중간 등급으로 쓸 계획이면 premium_models·한도를 다시 나눈다.
2. user안 과금 조직 = 사용자가 owner인 조직(start_run 인자)으로 둔 설계, runs에 organization_id를 함께 저장.
3. 조직별 일일 상한 기본값 300 크레딧(제안값, 원본에 없음).
4. model_catalog(13모델·크레딧 단가)·runtime_config(daily_credit_cap 5000 등) 시드는 설정 데이터로 보고 넣었다.
5. org안 request_run_cancel 권한 축소(원본 member 전원 → 생성자·owner·admin).
