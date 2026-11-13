-- admin-suite ERP 이식 · 조직형(org안). 원본: platform-docs/products/_supabase-modular/migrations/1600_erp.sql 1~6장(재고·판매·인사)
-- core.organizations→nomad_core.organizations, org_members→nomad_core.memberships, core.has_org_role→nomad_core.organization_role,
-- invite_member→nomad_core.create_invitation, 플랜 features→plan_limits 키(max_members·storage_mb·sales_trend_days). 대응표: products/erp/existing.md
-- AI 라우팅·플랜 AI 키(원본 7장)는 org/0002_ai.sql(core 웨이브 C5 후 적용). 전제: nomad_core.touch_updated_at() (core 20261119000100)
-- 되돌림: drop schema nomad_erp cascade; drop schema nomad_erp_private cascade; delete from storage.buckets where id = 'erp-product-images';
begin;

create schema nomad_erp;
create schema nomad_erp_private;
revoke all on schema nomad_erp, nomad_erp_private from public, anon, authenticated;
grant usage on schema nomad_erp to anon, authenticated, service_role;
alter default privileges in schema nomad_erp revoke execute on functions from public;
alter default privileges in schema nomad_erp_private revoke execute on functions from public;

insert into nomad_core.products (code, name) values ('erp', 'Admin Suite ERP') on conflict (code) do nothing;
-- 플랜 A/B/C 와 기능 잠금. 구독이 끊긴 조직은 C로 취급(core 규칙)되므로 C에는 기능을 두지 않는다 = 구독이 끊기면 잠긴다.
-- workspace = ERP 전체 접근(has_access가 본다) · export_xlsx = 엑셀 내보내기(앱이 has_feature로 확인). 원본 default→B, standard→A.
insert into nomad_core.plans (product_code, code, name) values ('erp', 'A', 'A'), ('erp', 'B', 'B'), ('erp', 'C', 'C')
  on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values ('erp', 'workspace', 'ERP 워크스페이스'), ('erp', 'export_xlsx', '엑셀 내보내기')
  on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
  values ('erp', 'A', 'workspace'), ('erp', 'B', 'workspace'), ('erp', 'A', 'export_xlsx') on conflict do nothing;

-- ---------- 비노출 도우미 ----------
-- 사용자 세션(authenticated/anon)이면 true. 보안 정의 RPC 안에서도 role 설정은 바뀌지 않으므로 호출자 구분에 쓴다.
create function nomad_erp_private.caller_is_client() returns boolean
language sql stable set search_path = ''
as $$
  select case
    when coalesce(current_setting('role', true), '') in ('service_role', 'postgres', 'supabase_admin') then false
    when coalesce(current_setting('role', true), '') in ('none', '') and session_user in ('postgres', 'supabase_admin') then false
    else true
  end
$$;

-- ---------- 테이블 ----------
-- 역할: master_admin = nomad_core 역할 owner/admin(파생, 저장 안 함). inventory_manager·sales_manager·staff = employees.erp_role.
-- ERP를 쓰는 조직은 workspaces 행이 있어야 한다(서버 프로비저닝). 개인 조직은 workspaces 행이 없어 도메인 데이터를 만들 수 없다.
create table nomad_erp.workspaces (
  organization_id      uuid primary key references nomad_core.organizations(id) on delete cascade,
  company_name         text not null constraint workspaces_company_name_check check (char_length(company_name) between 1 and 120),
  status               text not null default 'active' constraint workspaces_status_check check (status in ('active', 'suspended')),
  default_safety_stock integer not null default 10 constraint workspaces_default_safety_stock_check check (default_safety_stock between 0 and 1000000),
  low_stock_alert      boolean not null default true,
  settings             jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
comment on table nomad_erp.workspaces is 'ERP 사용 조직(고객사). 서버(service_role)가 register_workspace로 프로비저닝, 사용자는 조회만.';

create table nomad_erp.join_codes (
  organization_id uuid primary key references nomad_erp.workspaces(organization_id) on delete cascade,
  join_code       text not null unique constraint join_codes_join_code_check check (join_code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  rotated_at      timestamptz not null default now()
);
comment on table nomad_erp.join_codes is '승인제 가입 코드. 사용자 grant·정책 없음(get_join_code RPC, master_admin 전용).';

create table nomad_erp.departments (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name            text not null constraint departments_name_check check (char_length(name) between 1 and 60),
  parent_id       uuid,
  sort_order      integer not null default 0,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint departments_org_id_uniq unique (organization_id, id),
  constraint departments_org_name_uniq unique (organization_id, name),
  constraint departments_parent_fk foreign key (organization_id, parent_id) references nomad_erp.departments (organization_id, id) on delete set null (parent_id),
  constraint departments_parent_check check (parent_id is null or parent_id <> id)
);
create index departments_org_updated_idx on nomad_erp.departments (organization_id, updated_at);
comment on table nomad_erp.departments is '부서 트리. 조회는 접근 가능한 전원, 쓰기는 master_admin. 하드 삭제(오프라인 캐시는 전체 재조회).';

create table nomad_erp.employees (
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  display_name    text not null default '' constraint employees_display_name_check check (char_length(display_name) <= 80),
  department_id   uuid,
  position        text constraint employees_position_check check (position is null or char_length(position) <= 40),
  phone           text constraint employees_phone_check check (phone is null or phone ~ '^[0-9+() -]{7,20}$'),
  erp_role        text not null default 'staff'
                  constraint employees_erp_role_check check (erp_role in ('inventory_manager', 'sales_manager', 'staff')),
  status          text not null default 'active' constraint employees_status_check check (status in ('active', 'suspended')),
  joined_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (organization_id, user_id),
  constraint employees_department_fk foreign key (organization_id, department_id) references nomad_erp.departments (organization_id, id) on delete set null (department_id)
);
create index employees_user_idx on nomad_erp.employees (user_id);
comment on table nomad_erp.employees is '임직원 디렉토리 + ERP 역할. 쓰기 grant 없음(RPC만).';

create table nomad_erp.join_requests (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  applicant_name  text not null constraint join_requests_applicant_name_check check (char_length(applicant_name) between 1 and 80),
  message         text constraint join_requests_message_check check (message is null or char_length(message) <= 500),
  status          text not null default 'pending'
                  constraint join_requests_status_check check (status in ('pending', 'approved', 'rejected', 'canceled')),
  decided_by      uuid,
  decided_at      timestamptz,
  decision_note   text constraint join_requests_decision_note_check check (decision_note is null or char_length(decision_note) <= 500),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index join_requests_pending_uniq on nomad_erp.join_requests (organization_id, user_id) where status = 'pending';
create index join_requests_org_status_idx on nomad_erp.join_requests (organization_id, status, created_at desc);
create index join_requests_user_idx on nomad_erp.join_requests (user_id);
comment on table nomad_erp.join_requests is '승인제 가입 요청. 신청자는 아직 조직 멤버가 아니다. 승인 시 nomad_core 초대(이메일)가 만들어진다.';

create table nomad_erp.products (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  sku             text not null constraint products_sku_check check (sku ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'),
  name            text not null constraint products_name_check check (char_length(name) between 1 and 200),
  category        text not null default '기타' constraint products_category_check check (char_length(category) between 1 and 60),
  price           numeric(12, 2) not null default 0 constraint products_price_check check (price >= 0),
  quantity        integer not null default 0 constraint products_quantity_check check (quantity >= 0),
  safety_stock    integer not null default 10 constraint products_safety_stock_check check (safety_stock >= 0),
  is_low_stock    boolean generated always as (quantity <= safety_stock) stored,
  image_path      text,
  is_active       boolean not null default true,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  constraint products_org_id_uniq unique (organization_id, id)
);
create unique index products_org_sku_uniq on nomad_erp.products (organization_id, sku) where deleted_at is null;
create index products_low_stock_idx on nomad_erp.products (organization_id) where is_low_stock and is_active and deleted_at is null;
create index products_org_category_idx on nomad_erp.products (organization_id, category);
create index products_org_updated_idx on nomad_erp.products (organization_id, updated_at);
comment on table nomad_erp.products is '상품. quantity는 RPC만 바꾼다(컬럼 grant 제외). 소프트 삭제(deleted_at)·증분 동기화 대상.';

create table nomad_erp.inventory_moves (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_id      uuid not null,
  move_type       text not null constraint inventory_moves_move_type_check check (move_type in ('IN', 'OUT', 'ADJUSTMENT', 'SALE', 'SALE_CANCEL')),
  quantity_delta  integer not null constraint inventory_moves_quantity_delta_check check (quantity_delta <> 0),
  quantity_after  integer not null constraint inventory_moves_quantity_after_check check (quantity_after >= 0),
  reason          text constraint inventory_moves_reason_check check (reason is null or char_length(reason) <= 300),
  sale_id         uuid,
  request_id      text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  constraint inventory_moves_product_fk foreign key (organization_id, product_id) references nomad_erp.products (organization_id, id),
  constraint inventory_moves_request_uniq unique (organization_id, request_id)
);
create index inventory_moves_org_created_idx on nomad_erp.inventory_moves (organization_id, created_at desc);
create index inventory_moves_product_idx on nomad_erp.inventory_moves (product_id, created_at desc);
comment on table nomad_erp.inventory_moves is '입출고·조정·판매 이력. append-only(UPDATE 트리거 거부), 쓰기는 RPC만.';

create table nomad_erp.sales (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  product_id      uuid not null,
  quantity        integer not null constraint sales_quantity_check check (quantity > 0),
  unit_price      numeric(12, 2) not null constraint sales_unit_price_check check (unit_price >= 0),
  total_price     numeric(14, 2) generated always as (unit_price * quantity) stored,
  status          text not null default 'completed' constraint sales_status_check check (status in ('pending', 'completed', 'canceled')),
  sold_by         uuid,
  sold_at         timestamptz not null default now(),
  completed_at    timestamptz,
  canceled_at     timestamptz,
  canceled_by     uuid,
  cancel_reason   text constraint sales_cancel_reason_check check (cancel_reason is null or char_length(cancel_reason) <= 300),
  request_id      text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint sales_product_fk foreign key (organization_id, product_id) references nomad_erp.products (organization_id, id),
  constraint sales_request_uniq unique (organization_id, request_id),
  constraint sales_completed_at_check check (status <> 'completed' or completed_at is not null)
);
create index sales_org_completed_idx on nomad_erp.sales (organization_id, completed_at desc) where status = 'completed';
create index sales_org_status_idx on nomad_erp.sales (organization_id, status, sold_at desc);
comment on table nomad_erp.sales is '판매(pending/completed/canceled). 금액 컬럼은 원본의 numeric(원 단위, 소수 2자리). 전이는 트리거+RPC.';

-- 감사 로그(core 0004 audit_log 이식 전까지 제품 표). 기록은 write_audit만.
create table nomad_erp.audit_logs (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  actor_id        uuid,
  action          text not null,
  target_type     text not null,
  target_id       text,
  before_data     jsonb,
  after_data      jsonb,
  created_at      timestamptz not null default now()
);
create index audit_logs_org_created_idx on nomad_erp.audit_logs (organization_id, created_at desc);
comment on table nomad_erp.audit_logs is '재고 조정·직원·판매 취소·가입 승인 감사 기록. master_admin 조회만, core audit_log 이식 후 대체 검토.';

create function nomad_erp_private.write_audit(
  p_org uuid, p_action text, p_target_type text, p_target_id text default null, p_before jsonb default null, p_after jsonb default null
) returns void
language sql security definer set search_path = ''
as $$
  insert into nomad_erp.audit_logs (organization_id, actor_id, action, target_type, target_id, before_data, after_data)
  values (p_org, (select auth.uid()), p_action, p_target_type, p_target_id, p_before, p_after)
$$;

-- updated_at 트리거(증분 동기화)
create trigger workspaces_touch before update on nomad_erp.workspaces for each row execute function nomad_core.touch_updated_at();
create trigger departments_touch before update on nomad_erp.departments for each row execute function nomad_core.touch_updated_at();
create trigger employees_touch before update on nomad_erp.employees for each row execute function nomad_core.touch_updated_at();
create trigger join_requests_touch before update on nomad_erp.join_requests for each row execute function nomad_core.touch_updated_at();
create trigger products_touch before update on nomad_erp.products for each row execute function nomad_core.touch_updated_at();
create trigger sales_touch before update on nomad_erp.sales for each row execute function nomad_core.touch_updated_at();

-- ---------- 트리거 가드 ----------
create function nomad_erp.inventory_moves_immutable() returns trigger
language plpgsql set search_path = ''
as $$
begin
  -- 조직 삭제의 FK cascade(트리거 깊이 2 이상)만 DELETE 허용. 직접 UPDATE·DELETE 는 service_role 포함 모두 거부
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'nomad_erp.inventory_moves is append-only (%)', tg_op using errcode = '42501';
end $$;
create trigger inventory_moves_immutable before update or delete on nomad_erp.inventory_moves for each row execute function nomad_erp.inventory_moves_immutable();

-- products: 이미지 경로는 자기 조직 폴더만. (quantity·organization_id는 컬럼 grant로 사용자 변경 불가)
create function nomad_erp.guard_product_columns() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.image_path is not null and new.image_path not like new.organization_id::text || '/erp/product/%' then
    raise exception 'products: image_path must be under <organization_id>/erp/product/' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger products_guard_columns before insert or update on nomad_erp.products for each row execute function nomad_erp.guard_product_columns();

create function nomad_erp.sales_guard_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and not (
       (old.status = 'pending'   and new.status in ('completed', 'canceled'))
    or (old.status = 'completed' and new.status = 'canceled')) then
    raise exception 'sales: transition % -> % not allowed', old.status, new.status using errcode = '22023';
  end if;
  if new.quantity is distinct from old.quantity or new.unit_price is distinct from old.unit_price
     or new.product_id is distinct from old.product_id or new.organization_id is distinct from old.organization_id then
    raise exception 'sales: quantity/price/product are immutable' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger sales_guard_transition before update on nomad_erp.sales for each row execute function nomad_erp.sales_guard_transition();

create function nomad_erp.join_requests_guard_transition() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status is distinct from old.status and not (old.status = 'pending' and new.status in ('approved', 'rejected', 'canceled')) then
    raise exception 'join_requests: transition % -> % not allowed', old.status, new.status using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger join_requests_guard_transition before update on nomad_erp.join_requests for each row execute function nomad_erp.join_requests_guard_transition();

-- ---------- 역할 도우미 (security definer·stable, 정책 안 재귀 방지) ----------
-- 접근 = 활성 워크스페이스 + 기능 이용권 erp/workspace(A·B 구독) + 활성 조직 멤버십 + (owner/admin 이거나 활성 employees 행)
create function nomad_erp.has_access(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) is not null
     and exists (select 1 from nomad_erp.workspaces w where w.organization_id = target_organization and w.status = 'active')
     and nomad_core.org_has_feature(target_organization, 'erp', 'workspace')
     and nomad_core.organization_role(target_organization) is not null
     and (nomad_core.organization_role(target_organization) in ('owner', 'admin')
          or exists (select 1 from nomad_erp.employees e
                     where e.organization_id = target_organization and e.user_id = (select auth.uid()) and e.status = 'active'))
$$;

create function nomad_erp.has_role(target_organization uuid, roles text[]) returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_erp.has_access(target_organization)
     and (
          ('master_admin' = any (roles) and nomad_core.organization_role(target_organization) in ('owner', 'admin'))
       or exists (select 1 from nomad_erp.employees e
                  where e.organization_id = target_organization and e.user_id = (select auth.uid()) and e.status = 'active'
                    and e.erp_role = any (roles))
     )
$$;

create function nomad_erp.my_role(target_organization uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when not nomad_erp.has_access(target_organization) then null
    when nomad_core.organization_role(target_organization) in ('owner', 'admin') then 'master_admin'
    else (select e.erp_role from nomad_erp.employees e
          where e.organization_id = target_organization and e.user_id = (select auth.uid()) and e.status = 'active')
  end
$$;

-- ---------- RLS · grant ----------
alter table nomad_erp.workspaces      enable row level security;
alter table nomad_erp.join_codes      enable row level security;
alter table nomad_erp.departments     enable row level security;
alter table nomad_erp.employees       enable row level security;
alter table nomad_erp.join_requests   enable row level security;
alter table nomad_erp.products        enable row level security;
alter table nomad_erp.inventory_moves enable row level security;
alter table nomad_erp.sales           enable row level security;
alter table nomad_erp.audit_logs      enable row level security;

revoke all on all tables in schema nomad_erp from public, anon, authenticated;
grant all on all tables in schema nomad_erp to service_role;
grant usage, select on all sequences in schema nomad_erp to service_role;

grant select on nomad_erp.workspaces to authenticated;
create policy workspaces_select on nomad_erp.workspaces for select to authenticated
  using (nomad_erp.has_access(organization_id));

-- join_codes: 정책·grant 없음(사용자 접근 불가)

grant select, insert, update, delete on nomad_erp.departments to authenticated;
create policy departments_select on nomad_erp.departments for select to authenticated
  using (nomad_erp.has_access(organization_id));
create policy departments_insert on nomad_erp.departments for insert to authenticated
  with check (nomad_erp.has_role(organization_id, array['master_admin']));
create policy departments_update on nomad_erp.departments for update to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin']))
  with check (nomad_erp.has_role(organization_id, array['master_admin']));
create policy departments_delete on nomad_erp.departments for delete to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin']));

grant select on nomad_erp.employees to authenticated;
create policy employees_select on nomad_erp.employees for select to authenticated
  using ((user_id = (select auth.uid()) and nomad_erp.has_access(organization_id)) or nomad_erp.has_role(organization_id, array['master_admin']));

grant select on nomad_erp.join_requests to authenticated;
create policy join_requests_select on nomad_erp.join_requests for select to authenticated
  using (user_id = (select auth.uid()) or nomad_erp.has_role(organization_id, array['master_admin']));

-- products: 조회 = master_admin·inventory_manager·sales_manager(staff는 대시보드 RPC만). 쓰기 = master_admin·inventory_manager.
grant select on nomad_erp.products to authenticated;
grant insert (organization_id, sku, name, category, price, safety_stock, image_path, is_active) on nomad_erp.products to authenticated;
grant update (sku, name, category, price, safety_stock, image_path, is_active, deleted_at) on nomad_erp.products to authenticated;
grant delete on nomad_erp.products to authenticated;
create policy products_select on nomad_erp.products for select to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin', 'inventory_manager', 'sales_manager']));
create policy products_insert on nomad_erp.products for insert to authenticated
  with check (nomad_erp.has_role(organization_id, array['master_admin', 'inventory_manager']));
create policy products_update on nomad_erp.products for update to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin', 'inventory_manager']))
  with check (nomad_erp.has_role(organization_id, array['master_admin', 'inventory_manager']));
create policy products_delete on nomad_erp.products for delete to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin']));

grant select on nomad_erp.inventory_moves to authenticated;
create policy inventory_moves_select on nomad_erp.inventory_moves for select to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin', 'inventory_manager', 'sales_manager']));

-- sales: 금액 정보라 inventory_manager·staff 제외
grant select on nomad_erp.sales to authenticated;
create policy sales_select on nomad_erp.sales for select to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin', 'sales_manager']));

grant select on nomad_erp.audit_logs to authenticated;
create policy audit_logs_select on nomad_erp.audit_logs for select to authenticated
  using (nomad_erp.has_role(organization_id, array['master_admin']));

-- ---------- RPC ----------
create function nomad_erp_private.new_join_code() returns text
language plpgsql volatile set search_path = ''
as $$
declare
  v_alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code  text;
  i       integer;
begin
  for attempt in 1..5 loop
    v_bytes := extensions.gen_random_bytes(8);
    v_code := '';
    for i in 0..7 loop
      v_code := v_code || substr(v_alpha, (get_byte(v_bytes, i) % 32) + 1, 1);
    end loop;
    if not exists (select 1 from nomad_erp.join_codes j where j.join_code = v_code) then
      return v_code;
    end if;
  end loop;
  raise exception 'new_join_code: could not generate unique code' using errcode = 'P0001';
end;
$$;

-- 프로비저닝(서버 전용): 조직 생성·owner 지정·구독은 서버가 먼저 수행한다.
create function nomad_erp.register_workspace(p_organization_id uuid, p_company_name text) returns nomad_erp.workspaces
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_erp.workspaces;
begin
  if nomad_erp_private.caller_is_client() then
    raise exception 'register_workspace: service_role only' using errcode = '42501';
  end if;
  insert into nomad_erp.workspaces (organization_id, company_name)
  values (p_organization_id, p_company_name)
  on conflict (organization_id) do update set company_name = excluded.company_name, status = 'active'
  returning * into v_row;
  insert into nomad_erp.join_codes (organization_id, join_code) values (p_organization_id, nomad_erp_private.new_join_code())
  on conflict (organization_id) do nothing;
  perform nomad_erp_private.write_audit(p_organization_id, 'erp_workspace.register', 'organization', p_organization_id::text);
  return v_row;
end;
$$;

create function nomad_erp.get_join_code(p_organization_id uuid) returns text
language plpgsql stable security definer set search_path = ''
as $$
begin
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(p_organization_id, array['master_admin']) then
    raise exception 'get_join_code: master_admin only' using errcode = '42501';
  end if;
  return (select j.join_code from nomad_erp.join_codes j where j.organization_id = p_organization_id);
end;
$$;

create function nomad_erp.rotate_join_code(p_organization_id uuid) returns text
language plpgsql security definer set search_path = ''
as $$
declare v_code text;
begin
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(p_organization_id, array['master_admin']) then
    raise exception 'rotate_join_code: master_admin only' using errcode = '42501';
  end if;
  v_code := nomad_erp_private.new_join_code();
  update nomad_erp.join_codes set join_code = v_code, rotated_at = now() where organization_id = p_organization_id;
  if not found then
    raise exception 'rotate_join_code: workspace not found' using errcode = 'P0002';
  end if;
  perform nomad_erp_private.write_audit(p_organization_id, 'erp_workspace.rotate_join_code', 'organization', p_organization_id::text);
  return v_code;
end;
$$;

create function nomad_erp.update_workspace_settings(p_organization_id uuid, p_company_name text, p_default_safety_stock integer, p_low_stock_alert boolean)
returns nomad_erp.workspaces
language plpgsql security definer set search_path = ''
as $$
declare v_before nomad_erp.workspaces; v_row nomad_erp.workspaces;
begin
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(p_organization_id, array['master_admin']) then
    raise exception 'update_workspace_settings: master_admin only' using errcode = '42501';
  end if;
  select * into v_before from nomad_erp.workspaces where organization_id = p_organization_id for update;
  if not found then
    raise exception 'update_workspace_settings: workspace not found' using errcode = 'P0002';
  end if;
  update nomad_erp.workspaces
  set company_name = coalesce(p_company_name, company_name),
      default_safety_stock = coalesce(p_default_safety_stock, default_safety_stock),
      low_stock_alert = coalesce(p_low_stock_alert, low_stock_alert)
  where organization_id = p_organization_id
  returning * into v_row;
  perform nomad_erp_private.write_audit(p_organization_id, 'erp_workspace.update', 'organization', p_organization_id::text,
    jsonb_build_object('company_name', v_before.company_name, 'default_safety_stock', v_before.default_safety_stock, 'low_stock_alert', v_before.low_stock_alert),
    jsonb_build_object('company_name', v_row.company_name, 'default_safety_stock', v_row.default_safety_stock, 'low_stock_alert', v_row.low_stock_alert));
  return v_row;
end;
$$;

-- 가입 요청(승인제): 로그인 사용자가 가입 코드로 요청. 입력 검증은 코드·이름 길이·멤버/초대 중복.
-- 코드 추측 방지: 사용자당 10회/시간(nomad_core.rate_limit_take, 성공·실패 모두 1회). 잘못된 코드·한도 초과는 raise하면
-- 시도 카운트까지 롤백되므로 결과로 돌려준다: {ok:true, request:{…}} · {ok:false, code:'P0002'(잘못된 코드)} · {ok:false, code:'ER006'(시도 초과), reset_at}.
create function nomad_erp.request_join(p_join_code text, p_applicant_name text, p_message text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_org uuid; v_email text; v_row nomad_erp.join_requests; v_rl record;
begin
  if (select auth.uid()) is null then
    raise exception 'request_join: login required' using errcode = '42501';
  end if;
  select * into v_rl from nomad_core.rate_limit_take('erp:join:' || (select auth.uid())::text, 10, 3600);
  if not v_rl.allowed then
    return jsonb_build_object('ok', false, 'code', 'ER006', 'reset_at', v_rl.reset_at);
  end if;
  select w.organization_id into v_org from nomad_erp.join_codes j join nomad_erp.workspaces w on w.organization_id = j.organization_id
  where j.join_code = upper(btrim(p_join_code)) and w.status = 'active';
  if v_org is null then
    return jsonb_build_object('ok', false, 'code', 'P0002');
  end if;
  select lower(btrim(au.email)) into v_email from auth.users au where au.id = (select auth.uid());
  if exists (select 1 from nomad_core.memberships m where m.organization_id = v_org and m.user_id = (select auth.uid()))
     or exists (select 1 from nomad_core.invitations i
                where i.organization_id = v_org and i.email = v_email and i.accepted_at is null and i.expires_at > now()) then
    raise exception 'request_join: already a member or invited' using errcode = 'ER005';
  end if;
  select * into v_row from nomad_erp.join_requests r where r.organization_id = v_org and r.user_id = (select auth.uid()) and r.status = 'pending';
  if not found then
    insert into nomad_erp.join_requests (organization_id, user_id, applicant_name, message)
    values (v_org, (select auth.uid()), btrim(p_applicant_name), p_message)
    returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'request', to_jsonb(v_row));
end;
$$;

create function nomad_erp.cancel_join_request(p_request_id uuid) returns nomad_erp.join_requests
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_erp.join_requests;
begin
  update nomad_erp.join_requests set status = 'canceled'
  where id = p_request_id and user_id = (select auth.uid()) and status = 'pending'
  returning * into v_row;
  if not found then
    raise exception 'cancel_join_request: no pending request' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

-- 가입 요청 결정(master_admin). 승인 = employees 행 + nomad_core.create_invitation(신청자 이메일, 관리자급은 editor·staff는 viewer).
-- 신청자는 nomad_core.my_invitations/accept_invitation으로 활성화한다. 호출자는 조직 owner/admin 세션이어야 한다(core 초대 규칙).
create function nomad_erp.decide_join_request(
  p_request_id uuid, p_approve boolean, p_erp_role text default 'staff', p_department_id uuid default null, p_note text default null
) returns nomad_erp.join_requests
language plpgsql security definer set search_path = ''
as $$
declare v_req nomad_erp.join_requests; v_email text; v_limit integer;
begin
  select * into v_req from nomad_erp.join_requests where id = p_request_id for update;
  if not found then
    raise exception 'decide_join_request: not found' using errcode = 'P0002';
  end if;
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(v_req.organization_id, array['master_admin']) then
    raise exception 'decide_join_request: master_admin only' using errcode = '42501';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'decide_join_request: request is %', v_req.status using errcode = 'ER002';
  end if;

  if p_approve then
    if coalesce(p_erp_role, '') not in ('inventory_manager', 'sales_manager', 'staff') then
      raise exception 'decide_join_request: invalid erp_role' using errcode = '22023';
    end if;
    if p_department_id is not null and not exists (select 1 from nomad_erp.departments d where d.id = p_department_id and d.organization_id = v_req.organization_id) then
      raise exception 'decide_join_request: department not in organization' using errcode = '22023';
    end if;
    v_limit := nomad_core.org_plan_limit(v_req.organization_id, 'erp', 'max_members');
    if v_limit is not null and (select count(*) from nomad_erp.employees e where e.organization_id = v_req.organization_id and e.status = 'active') >= v_limit then
      raise exception 'decide_join_request: max_members reached' using errcode = 'ER004';
    end if;
    select au.email into v_email from auth.users au where au.id = v_req.user_id;
    if v_email is null then
      raise exception 'decide_join_request: applicant has no email' using errcode = '22023';
    end if;
    perform nomad_core.create_invitation(v_req.organization_id, v_email, case when p_erp_role = 'staff' then 'viewer' else 'editor' end);
    insert into nomad_erp.employees (organization_id, user_id, display_name, department_id, erp_role, status)
    values (v_req.organization_id, v_req.user_id, v_req.applicant_name, p_department_id, p_erp_role, 'active')
    on conflict (organization_id, user_id) do update
      set erp_role = excluded.erp_role, department_id = excluded.department_id, status = 'active', display_name = excluded.display_name;
    update nomad_erp.join_requests set status = 'approved', decided_by = (select auth.uid()), decided_at = now(), decision_note = p_note
    where id = p_request_id returning * into v_req;
    perform nomad_erp_private.write_audit(v_req.organization_id, 'join_request.approve', 'user', v_req.user_id::text, null,
                                          jsonb_build_object('erp_role', p_erp_role, 'department_id', p_department_id));
  else
    update nomad_erp.join_requests set status = 'rejected', decided_by = (select auth.uid()), decided_at = now(), decision_note = p_note
    where id = p_request_id returning * into v_req;
    perform nomad_erp_private.write_audit(v_req.organization_id, 'join_request.reject', 'user', v_req.user_id::text);
  end if;
  return v_req;
end;
$$;

-- ERP 역할 변경(master_admin). 자기 자신 불가. owner/admin의 권한은 nomad_core.change_member_role로 관리.
create function nomad_erp.set_employee_role(p_organization_id uuid, p_user_id uuid, p_erp_role text) returns nomad_erp.employees
language plpgsql security definer set search_path = ''
as $$
declare v_before nomad_erp.employees; v_row nomad_erp.employees;
begin
  if nomad_erp_private.caller_is_client() then
    if not nomad_erp.has_role(p_organization_id, array['master_admin']) then
      raise exception 'set_employee_role: master_admin only' using errcode = '42501';
    end if;
    if p_user_id = (select auth.uid()) then
      raise exception 'set_employee_role: cannot change your own role' using errcode = '42501';
    end if;
  end if;
  if coalesce(p_erp_role, '') not in ('inventory_manager', 'sales_manager', 'staff') then
    raise exception 'set_employee_role: invalid erp_role' using errcode = '22023';
  end if;
  select * into v_before from nomad_erp.employees where organization_id = p_organization_id and user_id = p_user_id for update;
  if not found then
    raise exception 'set_employee_role: employee not found' using errcode = 'P0002';
  end if;
  update nomad_erp.employees set erp_role = p_erp_role where organization_id = p_organization_id and user_id = p_user_id returning * into v_row;
  perform nomad_erp_private.write_audit(p_organization_id, 'employee.role', 'user', p_user_id::text,
                                        jsonb_build_object('erp_role', v_before.erp_role), jsonb_build_object('erp_role', p_erp_role));
  return v_row;
end;
$$;

create function nomad_erp.set_employee_status(p_organization_id uuid, p_user_id uuid, p_status text) returns nomad_erp.employees
language plpgsql security definer set search_path = ''
as $$
declare v_before nomad_erp.employees; v_row nomad_erp.employees;
begin
  if nomad_erp_private.caller_is_client() then
    if not nomad_erp.has_role(p_organization_id, array['master_admin']) then
      raise exception 'set_employee_status: master_admin only' using errcode = '42501';
    end if;
    if p_user_id = (select auth.uid()) then
      raise exception 'set_employee_status: cannot change your own status' using errcode = '42501';
    end if;
  end if;
  if coalesce(p_status, '') not in ('active', 'suspended') then
    raise exception 'set_employee_status: invalid status' using errcode = '22023';
  end if;
  if exists (select 1 from nomad_core.memberships m where m.organization_id = p_organization_id and m.user_id = p_user_id and m.role in ('owner', 'admin')) then
    raise exception 'set_employee_status: change the core role of owner/admin first' using errcode = '42501';
  end if;
  select * into v_before from nomad_erp.employees where organization_id = p_organization_id and user_id = p_user_id for update;
  if not found then
    raise exception 'set_employee_status: employee not found' using errcode = 'P0002';
  end if;
  update nomad_erp.employees set status = p_status where organization_id = p_organization_id and user_id = p_user_id returning * into v_row;
  perform nomad_erp_private.write_audit(p_organization_id, 'employee.status', 'user', p_user_id::text,
                                        jsonb_build_object('status', v_before.status), jsonb_build_object('status', p_status));
  return v_row;
end;
$$;

create function nomad_erp.update_employee_profile(
  p_organization_id uuid, p_user_id uuid, p_department_id uuid, p_position text, p_phone text, p_display_name text
) returns nomad_erp.employees
language plpgsql security definer set search_path = ''
as $$
declare v_before nomad_erp.employees; v_row nomad_erp.employees;
begin
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(p_organization_id, array['master_admin']) then
    raise exception 'update_employee_profile: master_admin only' using errcode = '42501';
  end if;
  if p_department_id is not null and not exists (select 1 from nomad_erp.departments d where d.id = p_department_id and d.organization_id = p_organization_id) then
    raise exception 'update_employee_profile: department not in organization' using errcode = '22023';
  end if;
  select * into v_before from nomad_erp.employees where organization_id = p_organization_id and user_id = p_user_id for update;
  if not found then
    raise exception 'update_employee_profile: employee not found' using errcode = 'P0002';
  end if;
  update nomad_erp.employees
  set department_id = p_department_id, position = nullif(btrim(p_position), ''), phone = nullif(btrim(p_phone), ''),
      display_name = coalesce(nullif(btrim(p_display_name), ''), display_name)
  where organization_id = p_organization_id and user_id = p_user_id
  returning * into v_row;
  perform nomad_erp_private.write_audit(p_organization_id, 'employee.update', 'user', p_user_id::text,
    jsonb_build_object('department_id', v_before.department_id, 'position', v_before.position),
    jsonb_build_object('department_id', v_row.department_id, 'position', v_row.position));
  return v_row;
end;
$$;

create function nomad_erp.update_my_contact(p_organization_id uuid, p_phone text) returns nomad_erp.employees
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_erp.employees;
begin
  if not nomad_erp.has_access(p_organization_id) then
    raise exception 'update_my_contact: no access' using errcode = '42501';
  end if;
  update nomad_erp.employees set phone = nullif(btrim(p_phone), '')
  where organization_id = p_organization_id and user_id = (select auth.uid())
  returning * into v_row;
  if not found then
    raise exception 'update_my_contact: employee not found' using errcode = 'P0002';
  end if;
  return v_row;
end;
$$;

-- 입출고·조정. IN/OUT 양수, ADJUSTMENT 부호 있음. master_admin·inventory_manager 전부, sales_manager는 OUT만. request_id 멱등.
create function nomad_erp.record_inventory_move(
  p_product_id uuid, p_move_type text, p_quantity integer, p_reason text default null, p_request_id text default null
) returns nomad_erp.inventory_moves
language plpgsql security definer set search_path = ''
as $$
declare v_prod nomad_erp.products; v_delta integer; v_row nomad_erp.inventory_moves;
begin
  select * into v_prod from nomad_erp.products where id = p_product_id and deleted_at is null for update;
  if not found then
    raise exception 'record_inventory_move: product not found' using errcode = 'P0002';
  end if;
  if nomad_erp_private.caller_is_client() then
    if not (nomad_erp.has_role(v_prod.organization_id, array['master_admin', 'inventory_manager'])
            or (p_move_type = 'OUT' and nomad_erp.has_role(v_prod.organization_id, array['sales_manager']))) then
      raise exception 'record_inventory_move: role not allowed' using errcode = '42501';
    end if;
  end if;
  if p_request_id is not null then
    if char_length(p_request_id) not between 8 and 100 then
      raise exception 'record_inventory_move: request_id length 8..100' using errcode = '22023';
    end if;
    perform pg_advisory_xact_lock(hashtext('erp:move:' || v_prod.organization_id::text || ':' || p_request_id));
    select * into v_row from nomad_erp.inventory_moves m where m.organization_id = v_prod.organization_id and m.request_id = p_request_id;
    if found then
      return v_row;
    end if;
  end if;
  if coalesce(p_move_type, '') not in ('IN', 'OUT', 'ADJUSTMENT') then
    raise exception 'record_inventory_move: move_type must be IN/OUT/ADJUSTMENT' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity = 0 or (p_move_type in ('IN', 'OUT') and p_quantity < 0) then
    raise exception 'record_inventory_move: invalid quantity' using errcode = '22023';
  end if;
  if p_move_type = 'ADJUSTMENT' and char_length(btrim(coalesce(p_reason, ''))) < 2 then
    raise exception 'record_inventory_move: reason required for ADJUSTMENT' using errcode = '22023';
  end if;
  v_delta := case p_move_type when 'OUT' then -p_quantity else p_quantity end;
  if v_prod.quantity + v_delta < 0 then
    raise exception 'record_inventory_move: insufficient stock (have %, change %)', v_prod.quantity, v_delta using errcode = 'ER001';
  end if;
  update nomad_erp.products set quantity = quantity + v_delta where id = p_product_id;
  insert into nomad_erp.inventory_moves (organization_id, product_id, move_type, quantity_delta, quantity_after, reason, request_id, created_by)
  values (v_prod.organization_id, p_product_id, p_move_type, v_delta, v_prod.quantity + v_delta, nullif(btrim(p_reason), ''), p_request_id, (select auth.uid()))
  returning * into v_row;
  if p_move_type = 'ADJUSTMENT' then
    perform nomad_erp_private.write_audit(v_prod.organization_id, 'inventory.adjust', 'product', p_product_id::text,
                                          jsonb_build_object('quantity', v_prod.quantity), jsonb_build_object('quantity', v_row.quantity_after, 'reason', v_row.reason));
  end if;
  return v_row;
end;
$$;

-- 판매 등록: completed면 조건부 UPDATE로 원자 차감 + SALE 이력. 단가는 상품 단가 고정. request_id 멱등.
create function nomad_erp.record_sale(p_product_id uuid, p_quantity integer, p_request_id text, p_status text default 'completed')
returns nomad_erp.sales
language plpgsql security definer set search_path = ''
as $$
declare v_prod nomad_erp.products; v_sale nomad_erp.sales; v_after integer;
begin
  select * into v_prod from nomad_erp.products where id = p_product_id and deleted_at is null;
  if not found then
    raise exception 'record_sale: product not found' using errcode = 'P0002';
  end if;
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(v_prod.organization_id, array['master_admin', 'sales_manager']) then
    raise exception 'record_sale: master_admin/sales_manager only' using errcode = '42501';
  end if;
  if p_request_id is null or char_length(p_request_id) not between 8 and 100 then
    raise exception 'record_sale: request_id required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('erp:sale:' || v_prod.organization_id::text || ':' || p_request_id));
  select * into v_sale from nomad_erp.sales s where s.organization_id = v_prod.organization_id and s.request_id = p_request_id;
  if found then
    return v_sale;
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'record_sale: quantity must be positive' using errcode = '22023';
  end if;
  if coalesce(p_status, '') not in ('completed', 'pending') then
    raise exception 'record_sale: status must be completed or pending' using errcode = '22023';
  end if;
  if not v_prod.is_active then
    raise exception 'record_sale: product is inactive' using errcode = 'ER003';
  end if;
  if p_status = 'completed' then
    update nomad_erp.products set quantity = quantity - p_quantity
    where id = p_product_id and quantity >= p_quantity
    returning quantity into v_after;
    if not found then
      raise exception 'record_sale: insufficient stock' using errcode = 'ER001';
    end if;
  end if;
  insert into nomad_erp.sales (organization_id, product_id, quantity, unit_price, status, sold_by, completed_at, request_id)
  values (v_prod.organization_id, p_product_id, p_quantity, v_prod.price, p_status, (select auth.uid()),
          case when p_status = 'completed' then now() end, p_request_id)
  returning * into v_sale;
  if p_status = 'completed' then
    insert into nomad_erp.inventory_moves (organization_id, product_id, move_type, quantity_delta, quantity_after, reason, sale_id, created_by)
    values (v_prod.organization_id, p_product_id, 'SALE', -p_quantity, v_after, null, v_sale.id, (select auth.uid()));
  end if;
  return v_sale;
end;
$$;

create function nomad_erp.complete_sale(p_sale_id uuid) returns nomad_erp.sales
language plpgsql security definer set search_path = ''
as $$
declare v_sale nomad_erp.sales; v_after integer;
begin
  select * into v_sale from nomad_erp.sales where id = p_sale_id for update;
  if not found then
    raise exception 'complete_sale: not found' using errcode = 'P0002';
  end if;
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(v_sale.organization_id, array['master_admin', 'sales_manager']) then
    raise exception 'complete_sale: master_admin/sales_manager only' using errcode = '42501';
  end if;
  if v_sale.status <> 'pending' then
    raise exception 'complete_sale: sale is %', v_sale.status using errcode = 'ER002';
  end if;
  update nomad_erp.products set quantity = quantity - v_sale.quantity
  where id = v_sale.product_id and quantity >= v_sale.quantity
  returning quantity into v_after;
  if not found then
    raise exception 'complete_sale: insufficient stock' using errcode = 'ER001';
  end if;
  update nomad_erp.sales set status = 'completed', completed_at = now() where id = p_sale_id returning * into v_sale;
  insert into nomad_erp.inventory_moves (organization_id, product_id, move_type, quantity_delta, quantity_after, sale_id, created_by)
  values (v_sale.organization_id, v_sale.product_id, 'SALE', -v_sale.quantity, v_after, v_sale.id, (select auth.uid()));
  return v_sale;
end;
$$;

create function nomad_erp.cancel_sale(p_sale_id uuid, p_reason text) returns nomad_erp.sales
language plpgsql security definer set search_path = ''
as $$
declare v_sale nomad_erp.sales; v_prev text; v_after integer;
begin
  select * into v_sale from nomad_erp.sales where id = p_sale_id for update;
  if not found then
    raise exception 'cancel_sale: not found' using errcode = 'P0002';
  end if;
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(v_sale.organization_id, array['master_admin', 'sales_manager']) then
    raise exception 'cancel_sale: master_admin/sales_manager only' using errcode = '42501';
  end if;
  if v_sale.status = 'canceled' then
    raise exception 'cancel_sale: already canceled' using errcode = 'ER002';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 2 then
    raise exception 'cancel_sale: reason required' using errcode = '22023';
  end if;
  v_prev := v_sale.status;
  if v_prev = 'completed' then
    update nomad_erp.products set quantity = quantity + v_sale.quantity where id = v_sale.product_id returning quantity into v_after;
    insert into nomad_erp.inventory_moves (organization_id, product_id, move_type, quantity_delta, quantity_after, reason, sale_id, created_by)
    values (v_sale.organization_id, v_sale.product_id, 'SALE_CANCEL', v_sale.quantity, v_after, btrim(p_reason), v_sale.id, (select auth.uid()));
  end if;
  update nomad_erp.sales set status = 'canceled', canceled_at = now(), canceled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
  where id = p_sale_id returning * into v_sale;
  perform nomad_erp_private.write_audit(v_sale.organization_id, 'sale.cancel', 'sale', p_sale_id::text,
                                        jsonb_build_object('status', v_prev), jsonb_build_object('status', 'canceled', 'reason', v_sale.cancel_reason));
  return v_sale;
end;
$$;

-- 대시보드 지표(접근 가능한 전원). "오늘" = KST 자정 경계.
create function nomad_erp.dashboard_metrics(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_start timestamptz := (date_trunc('day', now() at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul';
  v_end   timestamptz := ((date_trunc('day', now() at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul') + interval '1 day';
  v_result jsonb;
begin
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_access(p_organization_id) then
    raise exception 'dashboard_metrics: no access' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'kst_day_start', v_start,
    'today_sales_total', coalesce((select sum(s.total_price) from nomad_erp.sales s
                                    where s.organization_id = p_organization_id and s.status = 'completed'
                                      and s.completed_at >= v_start and s.completed_at < v_end), 0),
    'today_sales_count', (select count(*) from nomad_erp.sales s
                          where s.organization_id = p_organization_id and s.status = 'completed'
                            and s.completed_at >= v_start and s.completed_at < v_end),
    'today_canceled_count', (select count(*) from nomad_erp.sales s
                             where s.organization_id = p_organization_id and s.status = 'canceled'
                               and s.canceled_at >= v_start and s.canceled_at < v_end),
    'sku_count', (select count(*) from nomad_erp.products p where p.organization_id = p_organization_id and p.is_active and p.deleted_at is null),
    'low_stock_count', (select count(*) from nomad_erp.products p where p.organization_id = p_organization_id and p.is_active and p.deleted_at is null and p.is_low_stock),
    'active_employees', (select count(*) from nomad_erp.employees e where e.organization_id = p_organization_id and e.status = 'active'),
    'low_stock_items', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'sku', x.sku, 'name', x.name,
                                                                     'quantity', x.quantity, 'safety_stock', x.safety_stock))
                                 from (select p.id, p.sku, p.name, p.quantity, p.safety_stock from nomad_erp.products p
                                       where p.organization_id = p_organization_id and p.is_active and p.deleted_at is null and p.is_low_stock
                                       order by (p.quantity - p.safety_stock), p.name limit 5) x), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- 판매 추이(KST 버킷). 기간 상한 = plan_limits 'sales_trend_days'(없으면 366일).
create function nomad_erp.sales_trend(p_organization_id uuid, p_from timestamptz, p_to timestamptz, p_bucket text default 'hour')
returns table (bucket_start timestamptz, total numeric, sale_count bigint)
language plpgsql stable security definer set search_path = ''
as $$
declare v_days integer := least(366, coalesce(nomad_core.org_plan_limit(p_organization_id, 'erp', 'sales_trend_days'), 366));
begin
  if nomad_erp_private.caller_is_client() and not nomad_erp.has_role(p_organization_id, array['master_admin', 'sales_manager']) then
    raise exception 'sales_trend: master_admin/sales_manager only' using errcode = '42501';
  end if;
  if coalesce(p_bucket, '') not in ('hour', 'day', 'month') or p_from is null or p_to is null
     or p_to <= p_from or p_to - p_from > make_interval(days => v_days) then
    raise exception 'sales_trend: invalid range or bucket' using errcode = '22023';
  end if;
  return query
    select (date_trunc(p_bucket, s.completed_at at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul' as bucket_start,
           sum(s.total_price) as total,
           count(*) as sale_count
    from nomad_erp.sales s
    where s.organization_id = p_organization_id and s.status = 'completed' and s.completed_at >= p_from and s.completed_at < p_to
    group by 1
    order by 1;
end;
$$;

-- ---------- 함수 권한 ----------
-- 일괄 회수 후 필요한 것만 연다. 정책 도우미 3개 + 사용자 RPC = authenticated, 프로비저닝 = service_role만.
revoke execute on all functions in schema nomad_erp from public, anon, authenticated;
grant execute on all functions in schema nomad_erp to service_role;
revoke execute on function nomad_erp.register_workspace(uuid, text) from authenticated;
grant execute on function
  nomad_erp.has_access(uuid), nomad_erp.has_role(uuid, text[]), nomad_erp.my_role(uuid),
  nomad_erp.get_join_code(uuid), nomad_erp.rotate_join_code(uuid), nomad_erp.update_workspace_settings(uuid, text, integer, boolean),
  nomad_erp.request_join(text, text, text), nomad_erp.cancel_join_request(uuid),
  nomad_erp.decide_join_request(uuid, boolean, text, uuid, text),
  nomad_erp.set_employee_role(uuid, uuid, text), nomad_erp.set_employee_status(uuid, uuid, text),
  nomad_erp.update_employee_profile(uuid, uuid, uuid, text, text, text), nomad_erp.update_my_contact(uuid, text),
  nomad_erp.record_inventory_move(uuid, text, integer, text, text), nomad_erp.record_sale(uuid, integer, text, text),
  nomad_erp.complete_sale(uuid), nomad_erp.cancel_sale(uuid, text),
  nomad_erp.dashboard_metrics(uuid), nomad_erp.sales_trend(uuid, timestamptz, timestamptz, text)
to authenticated;
revoke execute on all functions in schema nomad_erp_private from public, anon, authenticated;
grant usage on schema nomad_erp_private to service_role;

-- ---------- Realtime (RLS 하에서 postgres_changes). 채널 erp:<organization_id>:<entity> ----------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['products', 'inventory_moves', 'sales'] loop
      execute format('alter publication supabase_realtime add table nomad_erp.%I', t);
    end loop;
  end if;
end $$;

-- ---------- Storage: 상품 이미지 버킷(비공개). 경로 <organization_id>/erp/product/<uuid> ----------
-- 읽기 = master_admin·inventory_manager·sales_manager, 업로드 = master_admin·inventory_manager. UPDATE·DELETE 정책 없음(서버가 service_role로).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('erp-product-images', 'erp-product-images', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy erp_product_images_select on storage.objects for select to authenticated
  using (bucket_id = 'erp-product-images' and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then nomad_erp.has_role(((storage.foldername(name))[1])::uuid, array['master_admin', 'inventory_manager', 'sales_manager']) else false end);
create policy erp_product_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'erp-product-images' and name like '%/erp/product/%' and case when (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then nomad_erp.has_role(((storage.foldername(name))[1])::uuid, array['master_admin', 'inventory_manager']) else false end);

commit;
