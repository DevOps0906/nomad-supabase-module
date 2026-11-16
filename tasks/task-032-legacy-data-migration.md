# task-032 — 제품 레포 5개 운영 데이터 이관 (위험도 높음)

근거: 사용자 요청(2026-11-17 "데이터 이관 SQL 진행") + challenger 착수 전 점검(REVISE 반영) + 사용자 결정 3건(아래).
대상: `D:/WorkSpace/DEV/_wt/{humscore,LOTTO-LAB,ContentFlow,KNOWFLOW,Shorts}-nomad-db` (브랜치 feat/nomad-db). 표별 대응 정본은 이 저장소 `products/<slug>/existing.md` 매핑 표.

## 사용자 결정 (2026-11-17)
1. 옛 플랜은 `nomad_core.subscriptions` 행으로 옮긴다. 옛 값→A/B/C 대응표를 existing.md에 적고, 대응 없는 값이 하나라도 있으면 중단.
2. 익명 사용자(auth.users.is_anonymous) 소유 행이 있으면 건수만 보고하고 이관 중단(버리지 않는다).
3. Shorts pgmq 큐는 쓰기 중지 후 비워진 것을 확인하고 전환(메시지 옮기지 않음). 비어 있지 않으면 중단.

## 구조 — 마이그레이션 파일이 아니라 사람이 실행하는 1회 스크립트
스키마는 `supabase/migrations/`(이미 있음)로만 push하고, 데이터 복사는 `supabase/nomad-cutover/`의 psql 스크립트로 한다(humscore는 main 병합 = CI 자동 push라 복사가 통제 밖에서 일어나면 안 됨).
| 파일 | 내용 |
|---|---|
| `01_freeze.sql` / `01_freeze_undo.sql` | 옛 public 표의 insert·update·delete를 anon·authenticated·service_role에서 revoke, 옛 pg_cron 작업 unschedule(이름 기록), 옛 auth.users 트리거 disable. undo는 정확히 되돌림. 표·함수는 남긴다 |
| `02_copy.sql` | 한 트랜잭션. `\if :apply` commit `\else` rollback(기본 dry-run). 시작 검사: 대상 제품 표가 비어 있지 않으면 중단(재실행 방지), 익명 소유 행·대응 없는 플랜·개인 조직 없는 user_id면 중단. `set local session_replication_role = replica`로 대상 트리거(행 수 제한·stamp·번호·잠금)를 끄고 id·created_at·updated_at·번호 원본 유지, 파생 표도 직접 복사. 겹치는 core 행(profiles 등 백필이 먼저 만든 것)은 upsert로 원본 값을 덮는다. 끝 검사: 표마다 원본 대비 행 수 **와** 핵심 값(소유자·id 집합) 대조, FK 고아 행 + 복합 FK `(organization_id, id)` 소유 일치 검사 → 하나라도 어긋나면 raise. 시퀀스 setval |
| `03_storage.*` (knowflow·shorts만) | 옛 버킷→새 버킷(`knowflow-sources`, `shorts-*`)·새 경로(knowflow 첫 폴더 uid→조직 id) 객체 복사 스크립트(레포 언어, service 키는 env에서만). 순서: 객체 복사 → 개수·크기 대조 → 그 다음에 경로 컬럼 갱신(02 안에서 새 경로로 쓰면 앱 전환 전 복사 완료가 조건). 옛 버킷은 지우지 않음 |
| `check.sh` | 일회용 로컬 DB: `legacy-migrations` 적용 → 합성 데이터 seed(사용자 2명+익명 0명, 표마다 2~3행, 소프트 삭제·공유 링크·멱등 키·유료 플랜 포함) → 새 `migrations/` 적용 → 01 → 02 dry-run(변경 없음 확인) → 02 apply → 값 대조·RLS 격리(다른 사용자 못 봄) → 02 재실행 거부 → 익명 행 넣고 중단 확인 → 01_undo 되돌림 확인. `set local`이 실제로 먹는지 확인 |
| `docs/ops/NOMAD_DB_CUTOVER.md` | 순서: 백업 → 대시보드 노출 스키마 추가(앱 배포 전) → 01 freeze(+Shorts 큐 비움 확인) → `supabase migration repair --status reverted <옛 버전>` → `db push` → 02 dry-run → 02 apply → 03 → 새 앱 배포·확인 → 쓰기 재개. **되돌릴 수 없는 지점**(쓰기 재개 후)과 그 전까지의 되돌리기 절차 명시 |

## 레포별 주의
- humscore: 절차서 맨 앞 "repair·백업·01 전에 main 병합 금지". storage 없음.
- KNOWFLOW: legacy `20261112000100_youtube_sources`와 새 `20261112000100_nomad_core`가 같은 버전 → repair 생략 시 nomad_core가 적용된 것으로 오인. 절차서 별도 항목. beta(plan_code) 대응.
- ContentFlow: workspace = team 조직(가능하면 workspace id를 조직 id로 유지), workspace 멤버 → memberships(역할 대응, reviewer는 viewer + reviewers 행). 1인 워크스페이스도 team 유지. 백필이 만든 빈 개인 조직이 목록 맨 앞에 오는 문제는 앱 계약(마지막 사용 조직 기본 선택)으로 existing.md에 기록.
- Shorts: user_profiles → profiles(upsert)+user_settings, 큐 이름 변경, pg_cron(sweep-jobs·collect-metrics·cleanup-analytics) 정리.
- LOTTO-LAB: user안, user_consents는 보관 결정 유지.

## 완료 조건
- 레포마다 `bash supabase/nomad-cutover/check.sh` PASS. 이 저장소 해당 제품 run_check.sh 회귀 없음.
- existing.md에 "운영 데이터 이관" 절(플랜 대응표·제외 규칙), INTEGRATION.md에 "기존 제품 데이터 이관"·"새 프로젝트에 적용" 절.

## 하지 않을 것
운영 DB 접속·적용, PR 병합, 옛 public 표·버킷 삭제, 실제 고객 데이터 사용, 비밀 커밋.
