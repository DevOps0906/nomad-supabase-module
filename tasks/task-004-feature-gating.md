# task-004 요금 플랜·기능 카탈로그와 기능 잠금

- 위험도: 높음 (RLS · 결제 권한) · 선행: task-002
- 근거: docs/design/01-architecture/feature-catalog.md (확정), billing-credits.md, supabase/migrations/20261112000100_nomad_core.sql(has_feature·dashboard_features)

## 파일 (설치기 패턴에 맞춤 — challenger 반영)
- core: `supabase/migrations/20261116000100_nomad_core_default_plan.sql` — 함수만(1·2·5). 제품 데이터 없음.
- 제품별 11개: `supabase/migrations/2026111600010N_<slug>.sql` (N=01 contentflow … 11 personal, task-002와 같은 순서) — 그 제품의 plans·features·plan_features + RLS 잠금. jangter·baedal은 카탈로그 데이터만.
- 각 파일 `begin; … commit;` + 되돌림 메모(함수는 "이전 본문은 20261112000100_nomad_core.sql 참조").

## 내용
1. **has_feature 기본 C**: `create or replace function nomad_core.has_feature(uuid, text, text)` — 시그니처·security definer·`set search_path = ''`·grant 그대로. 기존 두 경로에 세 번째 경로 추가: 멤버이고, 그 조직에 그 제품의 **활성 구독이 없고**(활성 = 경로 1과 같은 조건: status='active' and starts_at <= now() and (ends_at is null or ends_at > now())), 그 기능이 그 제품 C 플랜에 포함되면 true.
2. **dashboard_features**: `create or replace`. 구독이 없으면 `coalesce(s.plan_code, 'C')` 기준으로 upgrade_to 계산, **unlocked인 기능은 upgrade_to = null**. 나머지 동일.
3. **카탈로그 데이터**(제품 파일): plans (C '무료', B '프로', A '비즈니스'), features(카탈로그 표 전부), plan_features(표의 ○). 기준 docs/design/01-architecture/feature-catalog.md.
4. **조직형 잠금**(제품 파일): B·A 전용 기능 테이블만, insert with check와 update using·with check에 `and nomad_core.has_feature(organization_id, '<slug>', '<feature_code>')` 추가(`alter policy`로 기존 식 전체 재작성). select·delete 그대로.
   - contentflow: publish_logs(publish_automation), reviews(quality_review)
   - flora: personas(persona_style), pipeline_runs(pipeline_auto), audiobooks(audiobook)
   - knowflow: reports(space_reports)
   - classroom: quiz_items(quiz_bank), assessments(pre_post_assessment)
   - analytics: dashboards·widgets(dashboard), reports(report_output), share_links(share_links)
   - sceneflow: edit_jobs(ai_auto_edit), channels·uploads(channel_upload)
   - commerce: marketplace_accounts·listings(marketplace_listing), automation_jobs(commerce_automation)
5. **개인형 잠금**: core 파일에 `nomad_core.user_has_feature(target_product text, target_feature text) returns boolean` — security definer, `set search_path = ''`, stable, execute는 authenticated만. true 조건: 호출자가 **role = 'owner'** 인 활성 조직 중 하나라도 has_feature true(viewer·editor로 속한 팀 조직 구독은 공유되지 않음. `kind` 컬럼은 accounts 미설치 DB에 없으므로 쓰지 않음). 정책에서는 `(select nomad_core.user_has_feature('<slug>', '<feature>'))`로 감싼다.
   - humscore: recordings(recording), exports(score_export)
   - personal: saved_reports(report_save), trips·trip_days(trip_planner)
6. 잠금 대상 아닌 테이블·서버 전용 테이블은 손대지 않는다. service_role은 RLS를 우회하므로 **서버·워커는 쓰기 전에 has_feature를 확인**한다 — docs/INTEGRATION.md "대시보드와 기능 이용권" 절에 한 문장 추가.

## 완료 조건
- `npx supabase db reset --local` 성공, 기존 테스트 4개 통과
- 새 `tests/feature_gating.sql` 통과: 구독 없는 조직 C 쓰기 가능·B 거부 / B 구독 B 가능·A 거부 / A 구독 B·A 가능 / 만료·미래 시작 구독은 C로 / 다운그레이드 후 기존 B 행 select 가능·update 거부 / manual feature_grants로 개별 해제 / 개인형: 구독 없는 owner 조직 → C만, owner 조직 B 구독 → B 가능, 팀 조직 viewer는 그 팀의 B 구독으로 개인형 B 거부, 비활성 조직 구독 무효, 멤버십 없는 사용자 B 거부 / dashboard_features: 구독 없는 조직의 C 기능 unlocked·upgrade_to null, B 기능 locked·upgrade_to 'B'
- `tests/install_db.sh`에 부분 설치 케이스 추가: `--product humscore`만 설치 시 humscore 파일 2개 + core 파일이 복사되고 다른 제품 파일은 없음
- codex-reviewer(code) + reviewer(security)

## 하지 않을 것
- 가격·좌석 수치, 수량 한도, 크레딧 차감 연결, 기존 마이그레이션 수정
