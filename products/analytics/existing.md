# analytics 기존 DB → nomad_core 이식 대응표 (task-015)

원본: `D:\WorkSpace\DEV\analytics-flow-studio\supabase\migrations\` 8개(20261024000000~0700, 스키마 `public`, 개인형 `owner_id`, 표 18개). 0100~0700 의 ALTER·정책 교체는 최종 모양으로 합침.
이식: `org/0001_analytics.sql`(조직형만). 스키마 `nomad_analytics`(노출, anon 은 공개 RPC `get_shared_report` 하나만). AI 라우팅 시드는 원본에 없어 0002 없음.
청사진 `supabase/migrations/*_analytics.sql` 과 스키마 이름이 같아 함께 설치하지 않는다(참고만).
검증: `bash products/analytics/run_check.sh` (begin → 기존 스키마 drop → 0001 → `check_org.sql` → rollback). 사용처 약어: 웹=Next.js `apps/web`(authenticated), 서버=분석 서비스 `services/analysis`(service_role), 공개=공유 링크 방문자(anon RPC).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| (없음, 개인형) · owner_id | 대체 | nomad_core.organizations · organization_id | 행위자는 created_by·user_id. 하위 표는 (id, organization_id) 복합 FK |
| public.profiles · handle_new_user 트리거 | 삭제 | nomad_core 프로필(코어 가입 처리) | display_name 은 코어 프로필에서 |
| auth.uid() = owner_id 정책 | 대체 | nomad_analytics.has_access·can_edit·can_manage | 읽기 멤버, 쓰기 editor 이상, 프로젝트 삭제·공유 owner·admin |
| (플랜 없음) | 신규 | nomad_core.has_feature / org_has_feature(org,'analytics',기능) + plan_limits | 아래 플랜 표. 수치 시드 없음 |
| public.url_token() | 대체 | nomad_analytics.new_token() | service_role·DEFINER 안에서만(표 기본값) |
| storage 버킷 datasets · reports | 대체 | analytics-datasets · analytics-reports | 경로 `<조직>/analytics/…` |

## 테이블 (public → nomad_analytics, 17, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| profiles | 삭제 | (코어) | 웹 | — |
| projects | 이관(이름만 editor, 삭제 owner·admin) | 같은 이름 | 웹 CRUD · 서버(상태·목표) | owner_id → organization_id + created_by |
| datasets | 이관(올리기·시트·옮기기 editor, 빼기는 실행 참조 없을 때만(23503), 파일 한도 트리거) | 같은 이름 | 웹 · 서버(검사·웹훅) | owner_id → organization_id + created_by |
| dataset_versions | 이관(사용자는 raw v1 고정 경로만, 수정·삭제 없음) | 같은 이름 | 웹(업로드 완료) · 서버(정제본) | owner_id → organization_id |
| analysis_runs | 이관(사용자는 수동 실행만, 상태 서버) | 같은 이름 | 웹 · 서버 | owner_id → organization_id + created_by |
| run_steps · cleaning_proposals · change_logs | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 서버 | owner_id → organization_id |
| dashboards · widgets | 이관(서버 쓰기, 원본 사용자 update 정책 미사용이라 뺌) | 같은 이름 | 웹 읽기 · 서버 | owner_id → organization_id |
| reports | 이관(서버 쓰기, 경로 조직 접두 CHECK) | 같은 이름 | 웹 읽기 · 서버 | owner_id → organization_id |
| report_sections | 이관(editor 는 content.chart 만(트리거), chart 는 `^[a-z][a-z0-9_]{0,31}$` CHECK) | 같은 이름 | 웹(그래프 유형) · 서버 | owner_id → organization_id |
| pipelines | 이관(서버 생성, editor 켜기·끄기, webhook_token SELECT 제외) | 같은 이름 | 웹 · 서버(웹훅·예약) | owner_id → organization_id + created_by |
| schedules | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 서버 | owner_id → organization_id |
| usage_events | 이관(서버 쓰기, 조직 단위 집계) | 같은 이름 | 웹(이번 달 AI 횟수) · 서버 | owner_id → organization_id + user_id |
| questions | 이관(서버 생성, 고정·삭제 editor) | 같은 이름 | 웹 · 서버 | owner_id → organization_id + created_by |
| report_shares | 이관(쓰기는 RPC, 읽기 owner·admin) | 같은 이름 | 웹 · 공개 | owner_id → organization_id + created_by, revoked_at 추가 |
| notifications | 이관(서버 생성, 본인 read_at 만) | 같은 이름 | 웹(벨) · 서버 | owner_id → user_id + organization_id(멤버십 복합 FK, 탈퇴 시 삭제) |
- updated_at 추가·touch 트리거: projects·datasets·dashboards·report_sections·pipelines·schedules·questions.

## 함수
| 원래 이름 | 분류 | 실행 | 변화 |
|---|---|---|---|
| get_shared_report(text) | 이관 | anon·authenticated | 토큰 형식 검사, 조직 비활성 null, 섹션 200개 상한, 반환 키 4개 그대로 |
| url_token() | 대체 | service_role | new_token() |
| handle_new_user() | 삭제 | — | 코어 |
| (신규) create_report_share · revoke_report_share | 신규 | authenticated(owner·admin) | 만들기는 share_links, 해제는 잠긴 조직도 가능. 감사 로그 기록 |
| (신규) pipeline_webhook_token | 신규 | authenticated(owner·admin + automation) | 웹훅 주소 표시용 |
| (신규) has_access · can_edit · can_manage / org_feature · limit_of | 신규 | authenticated(불리언) / 내부 | — |
| (신규 트리거) guard_server_write · enforce_file_limit · dataset_versions_before_insert · analysis_runs_before_insert · report_sections_before_update · notifications_before_update | 신규 | 트리거 | BEFORE 트리거는 비멤버를 먼저 42501 |

## 플랜 기능 · plan_limits 키 (원본은 플랜 없음 = 전부 무료. 수치 시드 안 함)
| 키 | 새 위치 | A / B / C | DB 강제 위치 |
|---|---|---|---|
| data_analysis | 기능(작업 공간) | O / O / O | 모든 읽기·쓰기 정책 |
| automation | 기능 | O / O / — | pipelines 켜기 정책 · 예약·웹훅 실행 트리거(AN002) · 토큰 RPC |
| share_links | 기능 | O / — / — | create_report_share(AN002) |
| max_files_per_project | plan_limits(키 없으면 0) | 시드 없음 | datasets 트리거(AN001, 원본 앱 상수 10) |
| ai_calls_per_day | plan_limits | 시드 없음 | 서버(원본 설정 100/사용자) |

## 구독 끊김 · 참조 조직
- 구독 없음·inactive·만료 = C. 자동화 켜기·토큰·예약/웹훅 실행·새 공유 잠김. 읽기·자동화 끄기·공유 해제·기존 공유 열람 유지(검사 6절).
- 참조 조직: 모든 하위 표 (부모 id, organization_id) 복합 FK, analysis_runs.dataset_ids 배열은 트리거로 같은 조직·프로젝트(AN003). 원본에 core jobs·크레딧 연동이 없어 결과 전달·환불 트리거 없음.

## 버킷
- `analytics-datasets`(비공개 50MB): 원본 `<조직>/analytics/datasets/<프로젝트>/<데이터셋>/raw/source.(csv|xlsx)` 는 editor 가 서명 업로드, 정제본 `…/v<n>.parquet` 은 서버. 읽기 멤버. editor 삭제는 raw 이면서 버전 행 기록 전만(원본 불변 우회 차단), 그 밖은 서버.
- `analytics-reports`(비공개 50MB, PDF·HTML·DOCX): `<조직>/analytics/reports/…` 서버 쓰기, 읽기 멤버, 삭제 owner·admin.

## 앱 변경
- `.from(…)` 는 `nomad_analytics` 스키마(supabase-js `db.schema` 또는 `.schema('nomad_analytics')`), Python `client.schema('nomad_analytics').table(…)`. 모든 insert 에 organization_id(현재 조직), `owner_id` 제거.
- 경로: `${user.id}/${project}/${dataset}/raw/source.ext` → `${org}/analytics/datasets/${project}/${dataset}/raw/source.ext`, 버킷 이름 변경, 서버 보고서 경로도 `${org}/analytics/reports/…`. `path.startsWith(user.id)` 검사는 조직 접두로.
- projects·pipelines update 에서 `updated_at` 직접 지정 제거(트리거). `pipelines.select("*")` → 컬럼 나열 + 웹훅 주소는 `rpc('pipeline_webhook_token')`.
- 공유: `report_shares.insert/update` → `rpc('create_report_share')`·`rpc('revoke_report_share')`. 공유 목록은 owner·admin 에게만 보인다.
- 서버: notifications 는 `user_id`(멤버) + organization_id, usage_events 는 조직·user_id, AI 한도는 `org_plan_limit(…,'ai_calls_per_day')`. 웹훅·예약 실행은 기능이 꺼지면 AN002.
- 파일 빼기 순서: datasets 행 삭제(버전 연쇄 삭제) → 스토리지 remove. 실행이 있는 파일은 빼지 못한다(프로젝트 삭제로만).
- Realtime 필터 `owner_id=eq.` → `user_id=eq.`(notifications), 스키마 `nomad_analytics`.

## 팀장 확인 필요
1. 플랜 배정: 원본은 전부 무료인데 automation(A·B)·share_links(A)를 유료로 잠금 — 청사진 catalog(dashboard·report_output)는 DB 강제 지점이 없어 넣지 않음.
2. 파일 한도 fail-closed: 운영에서 plan_limits `max_files_per_project` 를 A·B·C 모두 시드해야 업로드 가능.
3. pipeline_webhook_token 은 사용자가 SELECT 못 하는 컬럼을 DEFINER 로 돌려줌(owner·admin 한정, 의도된 예외).
4. 편집자가 업로드 도중 실패한 빈 프로젝트를 지우던 흐름(원본 projects.delete)은 owner·admin 만 가능 → 서버 정리로 바꿀지.
