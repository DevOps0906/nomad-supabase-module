# admin-suite ERP 기존 DB → nomad_core 이식 대응표 (task-015 P1)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1600_erp.sql`(스키마 `erp`) · 문서 `products/admin-suite/`(Next.js 16 웹, 워커 없음, AI는 Dify·FastAPI).
이식: `org/0001_erp.sql`(조직형만 — 원래 org 제품) · `org/0002_ai.sql`(**core 웨이브 후 적용**). 스키마 `nomad_erp`(노출) · `nomad_erp_private`(내부, 노출 안 함).
검증: `bash products/erp/run_check.sh` (begin → 청사진 drop → 임시 touch_updated_at → 0001·0002 → `check_org.sql` → rollback, 통과).
사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler·Server Action(service_role).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('erp', signup_policy approval) | 대체: nomad_core.products | products('erp') | 승인제 가입은 제품 표 join_requests + join_codes로 유지 |
| core.organizations · org_id | 대체: nomad_core.organizations | organization_id | — |
| core.org_members(role member) | 대체: nomad_core.memberships | owner/admin = master_admin(파생) · 나머지 editor/viewer | ERP 역할은 employees.erp_role |
| core.has_org_role | 대체: nomad_core.organization_role | nomad_erp.has_access / has_role / my_role | 정책 도우미(definer). has_access는 기능 이용권 `erp/workspace`(org_has_feature)까지 본다 |
| core.invite_member | 대체: nomad_core.create_invitation | decide_join_request 안에서 호출 | staff→viewer, 관리자급→editor |
| core.write_audit · audit_log | 대체(2026-11-16 결정 4) | nomad_core.write_audit → nomad_core.audit_log | action 접두 `erp.`(원본 action 앞에 붙임). 제품 표·정책·grant 없음 |
| core.plans(default/standard features) | 대체: A/B/C + features + plan_limits 키 | 아래 표 | 기능 `workspace`(A·B)·`export_xlsx`(A) 시드, C에는 기능 없음 = 구독이 끊기면(구독 없음·inactive·만료 = C 취급) 잠김. 수치 시드 안 함 |
| core.ai_routing_settings 시드 · ai-docs 버킷 | **core 웨이브 후 적용** | org/0002_ai.sql | AI 표가 없으면 notice만 |

## 테이블 (erp → nomad_erp)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| workspaces | 이관 | nomad_erp.workspaces | 웹 읽기 · 서버 register_workspace | org_id → organization_id(PK) |
| join_codes | 이관(사용자 접근 없음) | nomad_erp.join_codes | get/rotate_join_code RPC | org_id → organization_id |
| departments | 이관 | nomad_erp.departments | 웹 CRUD(master_admin) | org_id → organization_id |
| employees | 이관(쓰기 RPC만) | nomad_erp.employees | 웹 읽기·RPC | (org_id,user_id) → (organization_id,user_id) |
| join_requests | 이관 | nomad_erp.join_requests | 웹(신청자·master_admin) | org_id → organization_id |
| products | 이관(+deleted_at 소프트 삭제) | nomad_erp.products | 웹 CRUD(quantity는 RPC만) | org_id → organization_id |
| inventory_moves | 이관(append-only) | nomad_erp.inventory_moves | 웹 읽기·RPC | org_id → organization_id |
| sales | 이관 | nomad_erp.sales | 웹 읽기·RPC | org_id → organization_id |
| (core audit_log) | 대체(결정 4) | nomad_core.audit_log | 웹 읽기 `rpc('nomad_audit_log', {target_organization})`(owner·admin = master_admin) | organization_id |
| 버킷 product-images | 이관 | `erp-product-images`(비공개) | 웹 업로드·조회 | 경로 `<organization_id>/erp/product/<uuid>` |
| 버킷 ai-docs | 이관(**core 웨이브 후**) | `ai-docs`(0002, service_role만) | 서버·FastAPI | — |
- 동기화 대상: workspaces·departments·employees·join_requests·products·sales — `updated_at` + `nomad_core.touch_updated_at()` 트리거 + `(organization_id, updated_at)` 인덱스(products·departments). 소프트 삭제는 products만(`deleted_at`), 나머지는 상태 컬럼(status)으로 비활성.

## 함수 (erp → nomad_erp, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 변화 |
|---|---|---|---|---|
| has_access · has_role · my_role | 이관 | nomad_erp.* | 정책·웹 | 코어 역할 기반으로 재작성 |
| new_join_code | 이관(내부) | nomad_erp_private.new_join_code | RPC 내부 | — |
| register_workspace | 이관(service_role) | nomad_erp.register_workspace | 서버 | 인자 org_id → p_organization_id |
| get_join_code · rotate_join_code · update_workspace_settings | 이관 | nomad_erp.* | 웹(master_admin) | — |
| request_join · cancel_join_request · decide_join_request | 이관 | nomad_erp.* | 웹 | 승인 시 nomad_core.create_invitation, max_members 한도 ER004. request_join은 사용자당 10회/시간(nomad_core.rate_limit_take) |
| set_employee_role · set_employee_status · update_employee_profile · update_my_contact | 이관 | nomad_erp.* | 웹 | 자기 자신 변경 금지 |
| record_inventory_move · record_sale · complete_sale · cancel_sale | 이관(멱등 request_id) | nomad_erp.* | 웹 | 금액 bigint(원) — 결정 3 |
| dashboard_metrics · sales_trend | 이관 | nomad_erp.* | 웹 | sales_trend 기간 상한 = plan_limits. 합계(today_sales_total·total)는 bigint |
| inventory_moves_immutable · guard_product_columns · sales_guard_transition · join_requests_guard_transition | 이관(트리거) | nomad_erp.* | 트리거 | — |
| (신규) caller_is_client | 신규(내부) | nomad_erp_private.* | RPC 내부 | 감사는 nomad_core.write_audit 직접 호출 |

## plan_limits 키 (수치 시드 안 함 — 원본 값은 참고)
| 원본 features 키 | limit_key (product `erp`) | 원본 default / standard |
|---|---|---|
| max_members | max_members | 5 / 50 |
| storage_mb | storage_mb | 500 / 10240 (DB에서 강제하지 않음, 서버 검사) |
| sales_trend_days | sales_trend_days | 31 / 366 (없으면 366) |
| export_xlsx(불리언) | — (nomad_core.features `erp/export_xlsx`, 플랜 A만) | false / true |

## 앱 변경 (이식 후 웹이 바꿀 것)
- `request_join` 반환이 `join_requests` 행 → jsonb: `{ok:true, request:{…}}` · `{ok:false, code:'P0002'}`(잘못된 가입 코드, 이전엔 raise) · `{ok:false, code:'ER006', reset_at}`(시도 초과). raise하면 시도 카운트가 롤백되므로 결과로 돌려준다. ER005(이미 멤버·초대)는 그대로 raise. 없는 코드·교체된(rotate) 이전 코드·정지(suspended) 조직 코드·구독이 끊긴(기능 잠긴, `erp/workspace` 없음) 조직 코드는 모두 같은 `{ok:false, code:'P0002'}`(존재 노출 금지, 2026-11-16 결정, 시도 횟수에 듦) — 웹은 이 넷을 구분하는 문구를 두지 않는다. 시도 초과는 맞는 코드여도 ER006(창 안).
- request_join 한도는 사용자(계정) 단위라 계정을 여러 개 만들면 우회된다(코드 공간 32^8이라 위험 낮음). 앞단 Route Handler에서 IP 단위 제한을 함께 건다(예: IP당 30회/시간, 서버 `nomad_core.rate_limit_hit('erp:join_ip:<IP 해시>', …)`).
- 구독이 끊긴 조직은 has_access=false → 모든 표 0건·RPC 거부. 웹은 `nomad_core.has_feature(org, 'erp', 'workspace')`(또는 `public.nomad_dashboard_features`)로 잠김 화면을 띄운다.
- 엑셀 내보내기 버튼은 `has_feature(org, 'erp', 'export_xlsx')`로 판정(앱 플래그 대신).

## 금액 bigint(원) (2026-11-16 결정 3)
- `products.price` · `sales.unit_price` · 생성열 `sales.total_price`(= unit_price × quantity) 모두 bigint. 합계(`dashboard_metrics.today_sales_total` · `sales_trend.total`)는 `sum(...)::bigint`.
- 앱 계약: 웹은 정수(원)만 보낸다. supabase-js로 소수(예: `1000.5`)를 보내면 **22P02**(invalid input syntax for type bigint) — 웹은 입력 단계에서 정수만 받는다. sales_trend 반환 `total` 타입이 numeric → bigint로 바뀐다(JS number, 2^53 미만).
- 이관: 원본 `numeric(12,2)`에 소수 금액이 있으면 **이관을 중단**한다(반올림 금지 — 사람이 원본을 고친 뒤 다시). 이관 전에 원본 DB에서:
```sql
do $$ begin
  if exists (select 1 from erp.products where price <> trunc(price)) or exists (select 1 from erp.sales where unit_price <> trunc(unit_price)) then
    raise exception 'erp 이관 중단: 소수 금액 행이 있다(반올림 금지)';
  end if;
end $$;
```
  통과하면 `price::bigint` · `unit_price::bigint`로 넣는다(total_price는 생성열이라 넣지 않는다).

## 감사 로그 → nomad_core.write_audit (2026-11-16 결정 4)
- 기록: RPC 안에서 `nomad_core.write_audit(조직, 'erp.<원본 action>', 대상 종류, 대상 id, before, after)`(예: `erp.sale.cancel` · `erp.employee.role`). actor는 write_audit가 auth.uid()로 강제한다.
- before/after에 연락처(전화·이메일)를 넣지 않는다(employee.update는 부서·직위만, update_my_contact는 기록 안 함). 검사가 `phone|email` 키 0을 확인한다.
- 읽기: 웹 감사 화면은 `rpc('nomad_audit_log', {target_organization, page_size, before_id})`(owner·admin = master_admin). 제품 표 `nomad_erp.audit_logs`·정책·grant는 없다.
- 보존: core audit_log에는 조직 FK가 없어 **조직을 삭제해도 감사 로그가 남는다**(삭제 연쇄 없음, 추가 전용). 개인정보 삭제 요청 시 감사 로그 처리는 core 정책을 따른다.
- 원본 로그 이관(postgres 세션, 서버 콘솔에서 1회): write_audit는 actor를 auth.uid()로 덮으므로 쓰지 않고 표에 직접 넣어 actor·시각을 보존한다(audit_log는 service_role·소유자만 insert, update·delete 트리거 거부).
```sql
-- postgres(소유자) 세션. 원본 erp.audit_logs → nomad_core.audit_log, 연락처 키는 제거
insert into nomad_core.audit_log (organization_id, actor_id, actor_role, action, target_type, target_id, before, after, metadata, created_at)
select a.org_id, a.actor_id, case when a.actor_id is null then 'system' else 'user' end, 'erp.' || a.action, a.target_type, a.target_id,
       a.before_data - 'phone' - 'email', a.after_data - 'phone' - 'email', '{"migrated_from":"erp.audit_logs"}'::jsonb, a.created_at
  from erp.audit_logs a order by a.created_at, a.id;
```
  확인: 원본 행 수 = `select count(*) from nomad_core.audit_log where metadata ->> 'migrated_from' = 'erp.audit_logs'`. 원본 이름이 다르면(조직 컬럼 org_id 등) 원본 표에 맞춰 고친다.

## 팀장 확인 필요
1. (처리됨 2026-11-16 결정 3) 금액 bigint(원) — 위 "금액 bigint" 장.
2. 0002의 공용 `ai-docs` 버킷 이름(school은 `school-ai-docs`) 통일.
3. 플랜 대응을 원본 default→B, standard→A로 잡았다. C에 기능이 없어 C 구독은 "구독 없음"과 같은 잠김 상태 — C를 무료·체험판으로 쓸 계획이면 잠김 판정을 따로 둬야 한다. request_join 한도 10회/시간은 임의값.
4. (처리됨 2026-11-16 결정 4) 감사 로그 → `nomad_core.write_audit` — 위 "감사 로그" 장.
