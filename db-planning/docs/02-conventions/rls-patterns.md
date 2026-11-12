# RLS 패턴 3종

## 1. 조직형
```sql
alter table <schema>.<table> enable row level security;

create policy "<table>_select_member" on <schema>.<table>
  for select using (core.is_member(org_id));
create policy "<table>_insert_member" on <schema>.<table>
  for insert with check (core.is_member(org_id));
create policy "<table>_update_member" on <schema>.<table>
  for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy "<table>_delete_admin" on <schema>.<table>
  for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));
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
