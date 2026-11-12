-- 0006: helper functions, signup trigger, RLS policies

-- ── helpers ───────────────────────────────────────────
create or replace function core.is_member(org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.memberships m
                 where m.org_id = org and m.user_id = auth.uid());
$$;

create or replace function core.has_role(org uuid, roles core.member_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.memberships m
                 where m.org_id = org and m.user_id = auth.uid() and m.role = any(roles));
$$;

create or replace function core.shares_org_with(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from core.memberships a
    join core.memberships b on a.org_id = b.org_id
    where a.user_id = auth.uid() and b.user_id = uid);
$$;

-- ── signup trigger: profile + personal org + owner + free plan ──
create or replace function core.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare new_org uuid;
begin
  insert into core.profiles (user_id, name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)), new.email);

  insert into core.organizations (name, type, created_by)
  values (coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)) || ' (개인)', 'personal', new.id)
  returning id into new_org;

  insert into core.memberships (org_id, user_id, role) values (new_org, new.id, 'owner');
  insert into core.subscriptions (org_id, plan_code) values (new_org, 'free');
  insert into core.credit_ledger (org_id, delta, reason)
    select new_org, monthly_credits, 'signup_grant' from core.plans where code = 'free';
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function core.handle_new_user();

-- ── team conversion ──────────────────────────────────
create or replace function core.create_team_org(org_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare new_org uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into core.organizations (name, type, created_by)
  values (org_name, 'team', auth.uid()) returning id into new_org;
  insert into core.memberships (org_id, user_id, role) values (new_org, auth.uid(), 'owner');
  insert into core.subscriptions (org_id, plan_code) values (new_org, 'free');
  return new_org;
end $$;

-- ── accept invitation: email match, expiry, seat limit ──
create or replace function core.accept_invitation(invite_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare inv core.invitations; seats int; seat_cap int; my_email text;
begin
  select * into inv from core.invitations where token = invite_token and accepted_at is null;
  if not found then raise exception 'invalid invitation'; end if;
  if inv.expires_at < now() then raise exception 'invitation expired'; end if;

  select email into my_email from auth.users where id = auth.uid();
  if lower(my_email) <> lower(inv.email) then raise exception 'email mismatch'; end if;

  if inv.role <> 'viewer' then
    select count(*) into seats from core.memberships where org_id = inv.org_id and role <> 'viewer';
    select p.seat_limit into seat_cap from core.subscriptions s
      join core.plans p on p.code = s.plan_code where s.org_id = inv.org_id;
    if seats >= coalesce(seat_cap, 1) then raise exception 'seat limit reached'; end if;
  end if;

  insert into core.memberships (org_id, user_id, role) values (inv.org_id, auth.uid(), inv.role)
    on conflict (org_id, user_id) do update set role = excluded.role;
  update core.invitations set accepted_at = now() where id = inv.id;
  return inv.org_id;
end $$;

-- ── credits ──────────────────────────────────────────
create or replace function core.spend_credits(org uuid, amount int, reason text)
returns int language plpgsql security definer set search_path = '' as $$
declare bal int;
begin
  if not core.is_member(org) then raise exception 'forbidden'; end if;
  select coalesce(sum(delta),0) into bal from core.credit_ledger where org_id = org;
  if bal < amount then raise exception 'insufficient credits'; end if;
  insert into core.credit_ledger (org_id, delta, reason, created_by) values (org, -amount, reason, auth.uid());
  return bal - amount;
end $$;

-- ── policies ─────────────────────────────────────────
create policy profiles_select_self_or_peer on core.profiles
  for select using (user_id = auth.uid() or core.shares_org_with(user_id));
create policy profiles_update_self on core.profiles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy orgs_select_member on core.organizations
  for select using (core.is_member(id));
create policy orgs_update_admin on core.organizations
  for update using (core.has_role(id, array['owner','admin']::core.member_role[]));

create policy memberships_select_member on core.memberships
  for select using (core.is_member(org_id));
create policy memberships_write_admin on core.memberships
  for all using (core.has_role(org_id, array['owner','admin']::core.member_role[]))
  with check (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create policy invitations_admin on core.invitations
  for all using (core.has_role(org_id, array['owner','admin']::core.member_role[]))
  with check (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create policy plans_read_all on core.plans for select using (true);
create policy subscriptions_select_member on core.subscriptions
  for select using (core.is_member(org_id));   -- 쓰기는 service_role만
create policy credit_ledger_select_member on core.credit_ledger
  for select using (core.is_member(org_id));   -- 쓰기는 spend_credits()/service_role
