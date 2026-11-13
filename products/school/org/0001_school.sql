-- platform-docs admin-suite/sms(1700_sms.sql) 이식 · 조직형(org안, 학교 = 조직). slug school, 스키마 nomad_school(노출) · nomad_school_private(비노출)
-- core.organizations→nomad_core.organizations, org_members→nomad_core.memberships, has_entitlement→nomad_core.has_feature('school'),
-- plans.features 수치→nomad_core.plan_limits 키(max_students·max_classes·attendance_trend_days, 시드 없음). 대응표: products/school/existing.md
-- 역할: admin = nomad_core owner/admin, teacher·student = nomad_school.members.school_role(코어 역할은 viewer). AI 라우팅·버킷은 0002_ai.sql(core 웨이브 후).
-- 전제: nomad_core.touch_updated_at() (core 20261119000100). 되돌림: drop schema nomad_school cascade; drop schema nomad_school_private cascade;
begin;

create schema nomad_school;
create schema nomad_school_private;
revoke all on schema nomad_school, nomad_school_private from public, anon, authenticated;
grant usage on schema nomad_school to authenticated, service_role;
grant usage on schema nomad_school_private to service_role;

insert into nomad_core.products (code, name) values ('school', 'School (학교 관리)') on conflict (code) do nothing;
insert into nomad_core.plans (product_code, code, name) values ('school', 'A', 'A'), ('school', 'B', 'B'), ('school', 'C', 'C') on conflict do nothing;
insert into nomad_core.features (product_code, code, name) values
  ('school', 'school', '학교 관리 기본(학급·과목·구성원·출석)'),
  ('school', 'export_xlsx', '출석 xlsx 내보내기')
on conflict do nothing;
-- 기본(구독 없음) 플랜 C에도 기본 기능이 있어야 has_feature가 열린다. export_xlsx는 상위 플랜(A·B)만. 수치 한도는 plan_limits(시드 없음).
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('school', 'A', 'school'), ('school', 'B', 'school'), ('school', 'C', 'school'),
  ('school', 'A', 'export_xlsx'), ('school', 'B', 'export_xlsx')
on conflict do nothing;

-- ---------- 내부 도우미 ----------
-- 서버(service_role·postgres)가 아니면 클라이언트 호출. 원본 core.is_service_caller 대체.
create function nomad_school_private.caller_is_client() returns boolean
language sql stable set search_path = ''
as $$
  select case
    when coalesce(current_setting('role', true), '') in ('service_role', 'postgres', 'supabase_admin') then false
    when coalesce(current_setting('role', true), '') in ('none', '') and session_user in ('postgres', 'supabase_admin') then false
    else true
  end
$$;

-- ---------- 테이블 ----------
create table nomad_school.workspaces (
  organization_id uuid primary key references nomad_core.organizations(id) on delete cascade,
  school_name text not null check (char_length(school_name) between 1 and 120),
  school_year integer not null default extract(year from (now() at time zone 'Asia/Seoul'))::integer check (school_year between 2000 and 2100),
  status text not null default 'active' check (status in ('active', 'suspended')),
  teacher_backfill_days integer not null default 7 check (teacher_backfill_days between 0 and 60),
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table nomad_school.workspaces is '학교 작업공간(조직 1:1). 행이 있는 조직만 도메인 데이터를 가진다. 등록은 service_role RPC만.';

create table nomad_school.classes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  grade smallint not null check (grade between 1 and 12),
  homeroom_teacher_id uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (organization_id, id)
);
comment on table nomad_school.classes is '학급. 조회=접근 가능 전원, 쓰기=admin. 개수 한도 plan_limits max_classes.';
create unique index classes_org_name_uniq on nomad_school.classes (organization_id, name) where deleted_at is null;
create index classes_org_updated_idx on nomad_school.classes (organization_id, updated_at);

create table nomad_school.subjects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  class_id uuid not null,
  name text not null check (char_length(name) between 1 and 40),
  teacher_id uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (organization_id, id),
  foreign key (organization_id, class_id) references nomad_school.classes (organization_id, id) on delete cascade
);
comment on table nomad_school.subjects is '과목(학급 소속). 조회=접근 가능 전원, 쓰기=admin.';
create unique index subjects_class_name_uniq on nomad_school.subjects (organization_id, class_id, name) where deleted_at is null;
create index subjects_org_updated_idx on nomad_school.subjects (organization_id, updated_at);

-- 학교 구성원(교사·학생). admin은 코어 역할이라 행이 없어도 된다. 코어 멤버십(수락 완료)이 먼저 있어야 한다.
create table nomad_school.members (
  organization_id uuid not null,
  user_id uuid not null,
  school_role text not null check (school_role in ('teacher', 'student')),
  display_name text not null default '' check (char_length(display_name) <= 80),
  class_id uuid,
  student_no text check (student_no is null or student_no ~ '^[0-9A-Za-z-]{1,20}$'),
  status text not null default 'active' check (status in ('active', 'suspended')),
  invited_by uuid,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id),
  foreign key (organization_id, user_id) references nomad_core.memberships (organization_id, user_id) on delete cascade,
  foreign key (organization_id, class_id) references nomad_school.classes (organization_id, id) on delete set null (class_id),
  check (school_role = 'student' or (class_id is null and student_no is null))
);
comment on table nomad_school.members is '교사·학생(개인정보: 이름·학번·학급). 쓰기 직접 grant 없음, RPC만. 본인 행+교직원만 조회.';
create unique index members_student_no_uniq on nomad_school.members (organization_id, student_no) where student_no is not null;
create index members_class_idx on nomad_school.members (organization_id, class_id) where school_role = 'student';
create index members_user_idx on nomad_school.members (user_id);
create index members_org_updated_idx on nomad_school.members (organization_id, updated_at);

create table nomad_school.attendance (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  class_id uuid not null,
  subject_id uuid not null,
  student_id uuid not null,
  attend_date date not null,
  status text not null check (status in ('present', 'late', 'early_leave', 'absent')),
  note text check (note is null or char_length(note) <= 200),
  marked_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, student_id, subject_id, attend_date),
  foreign key (organization_id, class_id) references nomad_school.classes (organization_id, id) on delete cascade,
  foreign key (organization_id, subject_id) references nomad_school.subjects (organization_id, id) on delete cascade
);
comment on table nomad_school.attendance is '출석(KST 수업일 date). 교직원 전체·학생 본인 행만 조회, 쓰기는 mark_attendance RPC만.';
create index attendance_org_date_idx on nomad_school.attendance (organization_id, attend_date);
create index attendance_class_date_idx on nomad_school.attendance (organization_id, class_id, attend_date);
create index attendance_student_date_idx on nomad_school.attendance (student_id, attend_date);
create index attendance_org_updated_idx on nomad_school.attendance (organization_id, updated_at);

create trigger workspaces_touch before update on nomad_school.workspaces for each row execute function nomad_core.touch_updated_at();
create trigger classes_touch before update on nomad_school.classes for each row execute function nomad_core.touch_updated_at();
create trigger subjects_touch before update on nomad_school.subjects for each row execute function nomad_core.touch_updated_at();
create trigger members_touch before update on nomad_school.members for each row execute function nomad_core.touch_updated_at();
create trigger attendance_touch before update on nomad_school.attendance for each row execute function nomad_core.touch_updated_at();

-- ---------- 역할 도우미 ----------
create function nomad_school.has_access(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select auth.uid()) is not null
     and exists (select 1 from nomad_school.workspaces w where w.organization_id = target_organization and w.status = 'active')
     and nomad_core.has_feature(target_organization, 'school', 'school')
     and (nomad_core.organization_role(target_organization) in ('owner', 'admin')
          or exists (select 1 from nomad_school.members m
                     where m.organization_id = target_organization and m.user_id = (select auth.uid()) and m.status = 'active'))
$$;

create function nomad_school.is_admin(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_school.has_access(target_organization)
     and nomad_core.organization_role(target_organization) in ('owner', 'admin')
$$;

-- 교직원(admin 또는 teacher)
create function nomad_school.is_staff(target_organization uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select nomad_school.has_access(target_organization)
     and (nomad_core.organization_role(target_organization) in ('owner', 'admin')
          or exists (select 1 from nomad_school.members m
                     where m.organization_id = target_organization and m.user_id = (select auth.uid())
                       and m.status = 'active' and m.school_role = 'teacher'))
$$;

create function nomad_school.my_role(target_organization uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when not nomad_school.has_access(target_organization) then null
    when nomad_core.organization_role(target_organization) in ('owner', 'admin') then 'admin'
    else (select m.school_role from nomad_school.members m
          where m.organization_id = target_organization and m.user_id = (select auth.uid()) and m.status = 'active')
  end
$$;

-- ---------- 한도 트리거(plan_limits: max_classes · max_students). 클라이언트는 정의 없으면 거부(fail-closed) ----------
create function nomad_school_private.enforce_class_limit() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare lim integer;
begin
  lim := nomad_core.org_plan_limit(new.organization_id, 'school', 'max_classes');
  if lim is null then
    if nomad_school_private.caller_is_client() then raise exception 'SCHOOL_LIMIT_UNDEFINED: max_classes' using errcode = '42501'; end if;
    return new;
  end if;
  if (select count(*) from nomad_school.classes c where c.organization_id = new.organization_id and c.deleted_at is null) >= lim then
    raise exception 'SCHOOL_CLASS_LIMIT_REACHED' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger classes_limit before insert on nomad_school.classes for each row execute function nomad_school_private.enforce_class_limit();

create function nomad_school_private.enforce_student_limit() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare lim integer;
begin
  if new.school_role <> 'student' or new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.school_role = 'student' and old.status = 'active' then return new; end if;
  lim := nomad_core.org_plan_limit(new.organization_id, 'school', 'max_students');
  if lim is null then
    if nomad_school_private.caller_is_client() then raise exception 'SCHOOL_LIMIT_UNDEFINED: max_students' using errcode = '42501'; end if;
    return new;
  end if;
  if (select count(*) from nomad_school.members m
      where m.organization_id = new.organization_id and m.school_role = 'student' and m.status = 'active') >= lim then
    raise exception 'SCHOOL_STUDENT_LIMIT_REACHED' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger members_limit before insert or update of school_role, status on nomad_school.members
  for each row execute function nomad_school_private.enforce_student_limit();

-- ---------- RLS · grant (anon 없음: 공개 읽기 대상 없음) ----------
alter table nomad_school.workspaces enable row level security;
alter table nomad_school.classes enable row level security;
alter table nomad_school.subjects enable row level security;
alter table nomad_school.members enable row level security;
alter table nomad_school.attendance enable row level security;

revoke all on table nomad_school.workspaces, nomad_school.classes, nomad_school.subjects, nomad_school.members, nomad_school.attendance
  from public, anon, authenticated;
grant all on table nomad_school.workspaces, nomad_school.classes, nomad_school.subjects, nomad_school.members, nomad_school.attendance to service_role;

grant select on nomad_school.workspaces to authenticated;
create policy workspaces_select on nomad_school.workspaces for select to authenticated using (nomad_school.has_access(organization_id));

grant select, insert, update, delete on nomad_school.classes to authenticated;
create policy classes_select on nomad_school.classes for select to authenticated using (nomad_school.has_access(organization_id));
create policy classes_insert on nomad_school.classes for insert to authenticated with check (nomad_school.is_admin(organization_id));
create policy classes_update on nomad_school.classes for update to authenticated
  using (nomad_school.is_admin(organization_id)) with check (nomad_school.is_admin(organization_id));
create policy classes_delete on nomad_school.classes for delete to authenticated using (nomad_school.is_admin(organization_id));

grant select, insert, update, delete on nomad_school.subjects to authenticated;
create policy subjects_select on nomad_school.subjects for select to authenticated using (nomad_school.has_access(organization_id));
create policy subjects_insert on nomad_school.subjects for insert to authenticated with check (nomad_school.is_admin(organization_id));
create policy subjects_update on nomad_school.subjects for update to authenticated
  using (nomad_school.is_admin(organization_id)) with check (nomad_school.is_admin(organization_id));
create policy subjects_delete on nomad_school.subjects for delete to authenticated using (nomad_school.is_admin(organization_id));

-- members: 본인 행 + 교직원 전체(접근 가능한 조직에서만). 쓰기 grant 없음.
grant select on nomad_school.members to authenticated;
create policy members_select on nomad_school.members for select to authenticated
  using (nomad_school.has_access(organization_id) and (user_id = (select auth.uid()) or nomad_school.is_staff(organization_id)));

-- attendance: 교직원 전체, 학생은 자기 행만. 쓰기 grant 없음.
grant select on nomad_school.attendance to authenticated;
create policy attendance_select on nomad_school.attendance for select to authenticated
  using (nomad_school.is_staff(organization_id) or (student_id = (select auth.uid()) and nomad_school.has_access(organization_id)));

-- ---------- RPC ----------
create function nomad_school.register_workspace(p_organization_id uuid, p_school_name text) returns nomad_school.workspaces
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_school.workspaces;
begin
  if nomad_school_private.caller_is_client() then
    raise exception 'register_workspace: service_role only' using errcode = '42501';
  end if;
  insert into nomad_school.workspaces (organization_id, school_name) values (p_organization_id, p_school_name)
  on conflict (organization_id) do update set school_name = excluded.school_name, status = 'active'
  returning * into v_row;
  return v_row;
end $$;

create function nomad_school.update_workspace_settings(p_organization_id uuid, p_school_name text, p_school_year integer, p_teacher_backfill_days integer)
returns nomad_school.workspaces
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_school.workspaces;
begin
  if nomad_school_private.caller_is_client() and not nomad_school.is_admin(p_organization_id) then
    raise exception 'update_workspace_settings: admin only' using errcode = '42501';
  end if;
  update nomad_school.workspaces
  set school_name = coalesce(p_school_name, school_name),
      school_year = coalesce(p_school_year, school_year),
      teacher_backfill_days = coalesce(p_teacher_backfill_days, teacher_backfill_days)
  where organization_id = p_organization_id returning * into v_row;
  if not found then raise exception 'update_workspace_settings: workspace not found' using errcode = 'P0002'; end if;
  return v_row;
end $$;

-- 학교 구성원 등록(admin). 대상은 nomad_core 초대(create_invitation → accept_invitation, 역할 viewer)를 수락해 멤버가 된 사용자여야 한다.
create function nomad_school.invite_school_member(
  p_organization_id uuid, p_user_id uuid, p_school_role text, p_display_name text, p_class_id uuid default null, p_student_no text default null
) returns nomad_school.members
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_school.members;
begin
  if nomad_school_private.caller_is_client() then
    if not nomad_school.is_admin(p_organization_id) then
      raise exception 'invite_school_member: admin only' using errcode = '42501';
    end if;
    if p_user_id = (select auth.uid()) then
      raise exception 'invite_school_member: cannot register yourself' using errcode = '22023';
    end if;
  end if;
  if coalesce(p_school_role, '') not in ('teacher', 'student') then
    raise exception 'invite_school_member: role must be teacher/student' using errcode = '22023';
  end if;
  if p_school_role = 'teacher' and (p_class_id is not null or p_student_no is not null) then
    raise exception 'invite_school_member: teacher has no class_id/student_no' using errcode = '22023';
  end if;
  if p_class_id is not null and not exists (select 1 from nomad_school.classes c where c.id = p_class_id and c.organization_id = p_organization_id) then
    raise exception 'invite_school_member: class not in organization' using errcode = '22023';
  end if;
  if not exists (select 1 from nomad_core.memberships m where m.organization_id = p_organization_id and m.user_id = p_user_id) then
    raise exception 'invite_school_member: target must accept the nomad_core invitation first' using errcode = 'P0002';
  end if;
  if exists (select 1 from nomad_core.memberships m where m.organization_id = p_organization_id and m.user_id = p_user_id and m.role in ('owner', 'admin')) then
    raise exception 'invite_school_member: target is an admin' using errcode = '22023';
  end if;
  insert into nomad_school.members (organization_id, user_id, school_role, display_name, class_id, student_no, invited_by)
  values (p_organization_id, p_user_id, p_school_role, left(coalesce(btrim(p_display_name), ''), 80), p_class_id, nullif(btrim(p_student_no), ''), (select auth.uid()))
  on conflict (organization_id, user_id) do update
    set school_role = excluded.school_role, display_name = excluded.display_name, class_id = excluded.class_id,
        student_no = excluded.student_no, invited_by = excluded.invited_by
  returning * into v_row;
  return v_row;
end $$;

create function nomad_school.set_member_role(p_organization_id uuid, p_user_id uuid, p_school_role text) returns nomad_school.members
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_school.members;
begin
  if nomad_school_private.caller_is_client() then
    if not nomad_school.is_admin(p_organization_id) then raise exception 'set_member_role: admin only' using errcode = '42501'; end if;
    if p_user_id = (select auth.uid()) then raise exception 'set_member_role: cannot change your own role' using errcode = '42501'; end if;
  end if;
  if coalesce(p_school_role, '') not in ('teacher', 'student') then
    raise exception 'set_member_role: role must be teacher/student' using errcode = '22023';
  end if;
  perform 1 from nomad_school.members where organization_id = p_organization_id and user_id = p_user_id for update;
  if not found then raise exception 'set_member_role: member not found' using errcode = 'P0002'; end if;
  update nomad_school.members
  set school_role = p_school_role,
      class_id = case when p_school_role = 'teacher' then null else class_id end,
      student_no = case when p_school_role = 'teacher' then null else student_no end
  where organization_id = p_organization_id and user_id = p_user_id returning * into v_row;
  return v_row;
end $$;

create function nomad_school.assign_class(p_organization_id uuid, p_user_id uuid, p_class_id uuid, p_student_no text default null)
returns nomad_school.members
language plpgsql security definer set search_path = ''
as $$
declare v_before nomad_school.members; v_row nomad_school.members;
begin
  if nomad_school_private.caller_is_client() and not nomad_school.is_admin(p_organization_id) then
    raise exception 'assign_class: admin only' using errcode = '42501';
  end if;
  if p_class_id is not null and not exists (select 1 from nomad_school.classes c where c.id = p_class_id and c.organization_id = p_organization_id) then
    raise exception 'assign_class: class not in organization' using errcode = '22023';
  end if;
  select * into v_before from nomad_school.members where organization_id = p_organization_id and user_id = p_user_id for update;
  if not found then raise exception 'assign_class: member not found' using errcode = 'P0002'; end if;
  if v_before.school_role <> 'student' then raise exception 'assign_class: only students have a class' using errcode = 'SM003'; end if;
  update nomad_school.members set class_id = p_class_id, student_no = coalesce(nullif(btrim(p_student_no), ''), student_no)
  where organization_id = p_organization_id and user_id = p_user_id returning * into v_row;
  return v_row;
end $$;

create function nomad_school.set_member_status(p_organization_id uuid, p_user_id uuid, p_status text) returns nomad_school.members
language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_school.members;
begin
  if nomad_school_private.caller_is_client() then
    if not nomad_school.is_admin(p_organization_id) then raise exception 'set_member_status: admin only' using errcode = '42501'; end if;
    if p_user_id = (select auth.uid()) then raise exception 'set_member_status: cannot change your own status' using errcode = '42501'; end if;
  end if;
  if coalesce(p_status, '') not in ('active', 'suspended') then
    raise exception 'set_member_status: invalid status' using errcode = '22023';
  end if;
  update nomad_school.members set status = p_status where organization_id = p_organization_id and user_id = p_user_id returning * into v_row;
  if not found then raise exception 'set_member_status: member not found' using errcode = 'P0002'; end if;
  return v_row;
end $$;

-- 출석 체크(admin/teacher). 미래 날짜 불가, teacher는 KST 오늘 기준 teacher_backfill_days 이전까지만, admin은 제한 없음.
create function nomad_school.mark_attendance(p_subject_id uuid, p_student_id uuid, p_attend_date date, p_status text, p_note text default null)
returns nomad_school.attendance
language plpgsql security definer set search_path = ''
as $$
declare
  v_subj nomad_school.subjects;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_back integer;
  v_row nomad_school.attendance;
begin
  select * into v_subj from nomad_school.subjects where id = p_subject_id and deleted_at is null;
  if not found then raise exception 'mark_attendance: subject not found' using errcode = 'P0002'; end if;
  if nomad_school_private.caller_is_client() and not nomad_school.is_staff(v_subj.organization_id) then
    raise exception 'mark_attendance: admin/teacher only' using errcode = '42501';
  end if;
  if coalesce(p_status, '') not in ('present', 'late', 'early_leave', 'absent') then
    raise exception 'mark_attendance: invalid status' using errcode = '22023';
  end if;
  if p_attend_date is null or p_attend_date > v_today then
    raise exception 'mark_attendance: future date not allowed' using errcode = 'SM002';
  end if;
  if nomad_school_private.caller_is_client() and nomad_core.organization_role(v_subj.organization_id) not in ('owner', 'admin') then
    select w.teacher_backfill_days into v_back from nomad_school.workspaces w where w.organization_id = v_subj.organization_id;
    if p_attend_date < v_today - coalesce(v_back, 7) then
      raise exception 'mark_attendance: date older than % days requires admin', coalesce(v_back, 7) using errcode = 'SM002';
    end if;
  end if;
  if not exists (select 1 from nomad_school.members m
                 where m.organization_id = v_subj.organization_id and m.user_id = p_student_id and m.school_role = 'student'
                   and m.status = 'active' and m.class_id = v_subj.class_id) then
    raise exception 'mark_attendance: student is not an active member of the subject class' using errcode = 'SM001';
  end if;
  insert into nomad_school.attendance (organization_id, class_id, subject_id, student_id, attend_date, status, note, marked_by)
  values (v_subj.organization_id, v_subj.class_id, p_subject_id, p_student_id, p_attend_date, p_status, nullif(btrim(p_note), ''), (select auth.uid()))
  on conflict (organization_id, student_id, subject_id, attend_date) do update
    set status = excluded.status, note = excluded.note, marked_by = excluded.marked_by
  returning * into v_row;
  return v_row;
end $$;

-- 일괄 체크: p_entries = [{"student_id": "...", "status": "present", "note": null}, ...] 최대 200건
create function nomad_school.mark_attendance_bulk(p_subject_id uuid, p_attend_date date, p_entries jsonb) returns integer
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; v_count integer := 0;
begin
  if jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) > 200 then
    raise exception 'mark_attendance_bulk: entries must be an array of at most 200' using errcode = '22023';
  end if;
  for r in select value from jsonb_array_elements(p_entries) loop
    perform nomad_school.mark_attendance(p_subject_id, (r ->> 'student_id')::uuid, p_attend_date, r ->> 'status', r ->> 'note');
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- 관리자/교사 대시보드 통계. attendance_rate=(present+late+early_leave)/records, on_time_rate=present/records,
-- expected=학급별(활성 학생 수 x 과목 수) 합, unchecked=expected-records
create function nomad_school.dashboard_stats(p_organization_id uuid, p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Seoul')::date);
  v_res jsonb;
begin
  if nomad_school_private.caller_is_client() and not nomad_school.is_staff(p_organization_id) then
    raise exception 'dashboard_stats: admin/teacher only' using errcode = '42501';
  end if;
  with a as (
    select status, class_id from nomad_school.attendance where organization_id = p_organization_id and attend_date = v_date
  ), cls as (
    select c.id, c.name, c.grade,
           (select count(*) from nomad_school.members m where m.organization_id = p_organization_id and m.class_id = c.id and m.school_role = 'student' and m.status = 'active') as students,
           (select count(*) from nomad_school.subjects s where s.organization_id = p_organization_id and s.class_id = c.id and s.deleted_at is null) as subjects
    from nomad_school.classes c where c.organization_id = p_organization_id and c.deleted_at is null
  )
  select jsonb_build_object(
    'date', v_date,
    'student_count', (select count(*) from nomad_school.members m where m.organization_id = p_organization_id and m.school_role = 'student' and m.status = 'active'),
    'class_count', (select count(*) from cls),
    'records', (select count(*) from a),
    'present', (select count(*) from a where status = 'present'),
    'late', (select count(*) from a where status = 'late'),
    'early_leave', (select count(*) from a where status = 'early_leave'),
    'absent', (select count(*) from a where status = 'absent'),
    'attendance_rate', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where status <> 'absent') / count(*), 1) end from a),
    'on_time_rate', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where status = 'present') / count(*), 1) end from a),
    'expected', (select coalesce(sum(students * subjects), 0) from cls),
    'unchecked', greatest((select coalesce(sum(students * subjects), 0) from cls) - (select count(*) from a), 0),
    'by_class', coalesce((select jsonb_agg(jsonb_build_object(
                    'class_id', cls.id, 'name', cls.name, 'grade', cls.grade,
                    'records', (select count(*) from a where a.class_id = cls.id),
                    'attendance_rate', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where a.status <> 'absent') / count(*), 1) end
                                        from a where a.class_id = cls.id)) order by cls.grade, cls.name) from cls), '[]'::jsonb)
  ) into v_res;
  return v_res;
end $$;

-- 기간별 출석 추이(admin/teacher). 최대 일수 = plan_limits attendance_trend_days(정의 없으면 31), 상한 366.
create function nomad_school.attendance_trend(p_organization_id uuid, p_from date, p_to date, p_class_id uuid default null)
returns table (attend_date date, records bigint, attended bigint, attendance_rate numeric)
language plpgsql stable security definer set search_path = ''
as $$
declare v_max integer;
begin
  if nomad_school_private.caller_is_client() and not nomad_school.is_staff(p_organization_id) then
    raise exception 'attendance_trend: admin/teacher only' using errcode = '42501';
  end if;
  v_max := least(coalesce(nomad_core.org_plan_limit(p_organization_id, 'school', 'attendance_trend_days'), 31), 366);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > v_max then
    raise exception 'attendance_trend: invalid range' using errcode = '22023';
  end if;
  return query
    select a.attend_date, count(*)::bigint, (count(*) filter (where a.status <> 'absent'))::bigint,
           round(100.0 * count(*) filter (where a.status <> 'absent') / count(*), 1)
    from nomad_school.attendance a
    where a.organization_id = p_organization_id and a.attend_date between p_from and p_to
      and (p_class_id is null or a.class_id = p_class_id)
    group by a.attend_date
    order by a.attend_date;
end $$;

-- 학생 본인 요약: 이번 달(KST) 출석률, 지각/조퇴/결석 횟수, 오늘 과목
create function nomad_school.student_summary(p_organization_id uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_from date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Seoul')::date))::date;
  v_to date := (date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Seoul')::date)) + interval '1 month')::date;
  v_me nomad_school.members;
begin
  if not nomad_school.has_access(p_organization_id) then
    raise exception 'student_summary: no access' using errcode = '42501';
  end if;
  select * into v_me from nomad_school.members
  where organization_id = p_organization_id and user_id = (select auth.uid()) and school_role = 'student' and status = 'active';
  if not found then raise exception 'student_summary: students only' using errcode = 'SM003'; end if;
  return (
    with a as (select status from nomad_school.attendance where organization_id = p_organization_id and student_id = (select auth.uid())
               and attend_date >= v_from and attend_date < v_to)
    select jsonb_build_object(
      'month', v_from,
      'records', (select count(*) from a),
      'attendance_rate', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where status <> 'absent') / count(*), 1) end from a),
      'late', (select count(*) from a where status = 'late'),
      'early_leave', (select count(*) from a where status = 'early_leave'),
      'absent', (select count(*) from a where status = 'absent'),
      'class_id', v_me.class_id,
      'today_subjects', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name)
                                  from nomad_school.subjects s where s.organization_id = p_organization_id and s.class_id = v_me.class_id and s.deleted_at is null), '[]'::jsonb)
    )
  );
end $$;

-- ---------- 함수 권한: PUBLIC·anon 회수 후 필요한 만큼만 ----------
revoke execute on all functions in schema nomad_school from public, anon;
revoke execute on all functions in schema nomad_school_private from public, anon, authenticated;
grant execute on all functions in schema nomad_school to service_role;
grant execute on function
  nomad_school.has_access(uuid), nomad_school.is_admin(uuid), nomad_school.is_staff(uuid), nomad_school.my_role(uuid),
  nomad_school.update_workspace_settings(uuid, text, integer, integer),
  nomad_school.invite_school_member(uuid, uuid, text, text, uuid, text),
  nomad_school.set_member_role(uuid, uuid, text), nomad_school.assign_class(uuid, uuid, uuid, text), nomad_school.set_member_status(uuid, uuid, text),
  nomad_school.mark_attendance(uuid, uuid, date, text, text), nomad_school.mark_attendance_bulk(uuid, date, jsonb),
  nomad_school.dashboard_stats(uuid, date), nomad_school.attendance_trend(uuid, date, date, uuid), nomad_school.student_summary(uuid, date)
  to authenticated;
grant execute on all functions in schema nomad_school_private to service_role;

-- ---------- Realtime: 출석 보드·학생 알림(채널 school:<org>:attendance) ----------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'nomad_school' and tablename = 'attendance') then
    alter publication supabase_realtime add table nomad_school.attendance;
  end if;
end $$;

commit;
