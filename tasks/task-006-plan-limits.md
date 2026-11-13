# task-006 플랜별 수량 한도 구조

- 위험도: 높음 (RLS · 요금 경계) · 선행: task-009(결정 D3=B 정규화)
- 근거: docs/design/03-port/platform-docs-mapping.md#3 · supabase/migrations/20261112000100_nomad_core.sql(plans·plan_features·has_feature 경로 1·3)

## 파일
- `supabase/migrations/20261118000100_nomad_core_plan_limits.sql` (설치기 `*_nomad_core_*.sql` 패턴으로 core에 포함). `begin; … commit;` + 되돌림 메모.

## 내용 (challenger REVISE 반영)
1. `nomad_core.plan_limits(product_code, plan_code, limit_key text, limit_value integer not null check (limit_value >= 0))`, PK (product_code, plan_code, limit_key), FK → plans. `limit_key`는 `^[a-z][a-z0-9_]*$` check. **무제한 = 2147483647**(integer 최대, -1·null 금지). 앱은 이 값과 같으면 "무제한"으로 표시. 테이블 주석에 적는다.
2. 이 파일에서 직접 `enable row level security` + `grant select, insert, update, delete … to service_role`. 정책 없음 = 서버 전용 카탈로그(plan_features와 같은 상태, core.sql 122~134 반복문은 새 테이블에 안 걸림).
3. 함수 두 개(has_feature 패턴: default_plan.sql 5~59). 매개변수 이름은 `target_organization, target_product, target_key`.
   - `nomad_core.org_plan_limit(...) returns integer` — security definer, stable, `set search_path = ''`, execute는 service_role만. 조직이 없거나 `organizations.active`가 false면 null. 활성 구독(status='active' · starts_at <= now() · ends_at 없거나 미래)의 plan_code, 없으면 'C'로 plan_limits 조회. 행 없으면 null.
   - `nomad_core.plan_limit(...) returns integer` — security definer, stable, `set search_path = ''`, execute는 authenticated만. `nomad_core.organization_role(target_organization)`이 null이면 null, 아니면 org_plan_limit 결과.
   - public execute revoke.
4. **null 규칙(fail-closed)**: null = 비멤버·비활성 조직·정의 없음. 호출자는 null이면 생성을 거부한다. INTEGRATION.md "대시보드와 기능 이용권" 절에 3문장(서버는 org_plan_limit, 현재 개수를 세어 비교, null 거부·2147483647 무제한).

## 완료 조건
- `npx supabase db reset --local` 성공, 기존 테스트 5종 통과
- `tests/feature_gating.sql`에 추가(트랜잭션 안 합성 한도 행, service_role로 insert 성공 확인 포함): 멤버 authenticated — 구독 없음 → C 값 / B 활성 → B 값 / 만료·미래 시작 → C 값 / 키 없음 → null · 비멤버 authenticated → null · service_role(claims 없이) org_plan_limit → 실제 값 · 비활성 조직 → null(두 함수 모두) · limit_value -1 거부 · 잘못된 limit_key 거부
- `tests/install_db.sh`: core만 설치 시 plan_limits 파일 포함 확인
- `sql2erd supabase/migrations -o docs/diagrams/erd.mmd` 갱신, README 파일 표 확인(db.md 규칙)
- codex-reviewer(code) + reviewer(security)

## 하지 않을 것
- 한도 수치 시드(billing-credits 결정 후), 조직별 한도 덮어쓰기, rate_limit_buckets(C3 별도), 제품 RPC 검사 지점, 기존 마이그레이션 수정
