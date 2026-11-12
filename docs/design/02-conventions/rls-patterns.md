# RLS 패턴 3종

`<schema>`는 `nomad_<slug>`. 실제 예: `supabase/migrations/20261112000200_contentflow_example.sql`.

## 1. 조직형
```sql
alter table <schema>.<table> enable row level security;

create policy "<table>_select_member" on <schema>.<table>
  for select using (nomad_core.organization_role(organization_id) is not null);
create policy "<table>_insert_member" on <schema>.<table>
  for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy "<table>_update_member" on <schema>.<table>
  for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy "<table>_delete_admin" on <schema>.<table>
  for delete using (nomad_core.organization_role(organization_id) in ('owner','admin'));
```

## 2. 개인형
```sql
create policy "<table>_own" on <schema>.<table>
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```
공개 읽기(동네장터 목록 등)는 별도 `select using (true)` 정책을 **추가**하고 쓰기는 본인만.

## 3. 격리형
```sql
alter table <schema>.<table> enable row level security;
-- 기본 거부. 역할 정책은 서비스 확정 후 작성.
```
민감 컬럼은 `*_enc`로 암호화하고 열람은 `audit_logs`에 기록한다.

## 점검 쿼리
```sql
select schemaname, tablename from pg_tables
where schemaname not in ('pg_catalog','information_schema')
  and not rowsecurity;   -- 결과가 비어 있어야 함
```
