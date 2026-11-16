begin;

insert into auth.users (id) values
 ('00000000-0000-4000-8000-000000000001'),
 ('00000000-0000-4000-8000-000000000002'),
 ('00000000-0000-4000-8000-000000000003'),
 ('00000000-0000-4000-8000-000000000004');
insert into nomad_core.organizations (id, name) values
 ('00000000-0000-4000-8000-000000000011', 'A 실습 업체'),
 ('00000000-0000-4000-8000-000000000012', 'B 실습 업체'),
 ('00000000-0000-4000-8000-000000000013', 'C 실습 업체');
insert into nomad_core.memberships values
 ('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001', 'owner'),
 ('00000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000002', 'owner'),
 ('00000000-0000-4000-8000-000000000013', '00000000-0000-4000-8000-000000000003', 'owner'),
 ('00000000-0000-4000-8000-000000000013', '00000000-0000-4000-8000-000000000004', 'viewer');
insert into nomad_core.subscriptions (organization_id, product_code, plan_code, status) values
 ('00000000-0000-4000-8000-000000000011', 'contentflow_example', 'A', 'active'),
 ('00000000-0000-4000-8000-000000000012', 'contentflow_example', 'B', 'active'),
 ('00000000-0000-4000-8000-000000000013', 'contentflow_example', 'C', 'active');
insert into nomad_contentflow_example.posts (organization_id, title) values
 ('00000000-0000-4000-8000-000000000011', 'A 게시물'),
 ('00000000-0000-4000-8000-000000000012', 'B 게시물'),
 ('00000000-0000-4000-8000-000000000013', 'C 게시물');
insert into nomad_contentflow_example.analytics_reports (organization_id, title, report) values
 ('00000000-0000-4000-8000-000000000011', 'A 보고서', '{}'),
 ('00000000-0000-4000-8000-000000000013', 'C 보고서', '{}');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
do $$
begin
  if (select count(*) from nomad_contentflow_example.posts) <> 1
     or (select count(*) from nomad_contentflow_example.analytics_reports) <> 1
     or (select count(*) from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000011', 'contentflow_example') where unlocked) <> 5
     or exists (select 1 from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000013', 'contentflow_example'))
  then raise exception 'A access or cross-tenant isolation failed'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
do $$
begin
  if (select count(*) from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000012', 'contentflow_example') where unlocked) <> 3
     or exists (select 1 from nomad_contentflow_example.analytics_reports)
  then raise exception 'B plan access failed'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
do $$
begin
  if (select count(*) from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000013', 'contentflow_example') where unlocked) <> 2
     or not exists (
       select 1 from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000013', 'contentflow_example')
       where feature_code = 'advanced_analytics' and not unlocked and upgrade_to = 'A' and addon_sku = 'advanced-analytics' and can_purchase
     )
     or exists (select 1 from nomad_contentflow_example.analytics_reports)
  then raise exception 'C lock or purchase metadata failed'; end if;
  begin
    insert into nomad_contentflow_example.posts (organization_id, title)
    values ('00000000-0000-4000-8000-000000000011', 'cross-tenant');
    raise exception 'cross-tenant insert succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
insert into nomad_core.addon_purchases
  (id, organization_id, product_code, sku, feature_code, provider, provider_purchase_id, status)
values (
  '00000000-0000-4000-8000-000000000021', '00000000-0000-4000-8000-000000000013',
  'contentflow_example', 'advanced-analytics', 'advanced_analytics', 'fixture', 'purchase-1', 'paid'
);
insert into nomad_core.feature_grants (organization_id, product_code, feature_code, purchase_id, source)
values ('00000000-0000-4000-8000-000000000013', 'contentflow_example', 'advanced_analytics',
  '00000000-0000-4000-8000-000000000021', 'purchase');
set local role authenticated;

do $$
begin
  if (select count(*) from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000013', 'contentflow_example') where unlocked) <> 3
     or (select count(*) from nomad_contentflow_example.analytics_reports where title = 'C 보고서') <> 1
     or (select count(*) from nomad_contentflow_example.analytics_reports) <> 1
     or nomad_core.has_feature('00000000-0000-4000-8000-000000000013', 'contentflow_example', 'scheduled_publish')
  then raise exception 'addon unlocked the wrong feature or organization'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000004', true);
do $$
begin
  if exists (
    select 1 from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000013', 'contentflow_example')
    where can_purchase
  ) then raise exception 'viewer purchase permissions failed'; end if;
  begin
    insert into nomad_contentflow_example.posts (organization_id, title)
    values ('00000000-0000-4000-8000-000000000013', 'viewer insert');
    raise exception 'viewer insert succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
update nomad_core.addon_purchases set status = 'refunded' where provider_purchase_id = 'purchase-1';
set local role authenticated;
do $$
begin
  if exists (select 1 from nomad_contentflow_example.analytics_reports)
  then raise exception 'refund did not close the feature'; end if;
end;
$$;

reset role;
update nomad_core.subscriptions set plan_code = 'A'
where organization_id = '00000000-0000-4000-8000-000000000013' and product_code = 'contentflow_example';
set local role authenticated;
do $$
begin
  if (select count(*) from public.nomad_dashboard_features('00000000-0000-4000-8000-000000000013', 'contentflow_example') where unlocked) <> 5
     or (select count(*) from nomad_contentflow_example.posts where title = 'C 게시물') <> 1
  then raise exception 'plan upgrade or retained tenant data failed'; end if;
end;
$$;

-- 앱 읽기 RPC(core 20261122000100): 대기 초대 목록(owner·admin, token 미노출) · 내 조직 플랜 한도(멤버)
reset role;
insert into nomad_core.invitations (organization_id, email, role, invited_by, accepted_at) values
 ('00000000-0000-4000-8000-000000000011', 'pending-a@example.test', 'editor', '00000000-0000-4000-8000-000000000001', null),
 ('00000000-0000-4000-8000-000000000011', 'done-a@example.test', 'viewer', '00000000-0000-4000-8000-000000000001', now()),
 ('00000000-0000-4000-8000-000000000012', 'pending-b@example.test', 'viewer', '00000000-0000-4000-8000-000000000002', null),
 ('00000000-0000-4000-8000-000000000013', 'pending-c@example.test', 'viewer', '00000000-0000-4000-8000-000000000003', null);
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
 ('contentflow_example', 'A', 'zz_check_posts', 10),
 ('contentflow_example', 'B', 'zz_check_posts', 5);
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
do $$
begin
  if (select count(*) from public.nomad_organization_invitations('00000000-0000-4000-8000-000000000011')) <> 1
     or not exists (select 1 from public.nomad_organization_invitations('00000000-0000-4000-8000-000000000011')
                    where email = 'pending-a@example.test' and invited_by = '00000000-0000-4000-8000-000000000001')
     or exists (select 1 from information_schema.routines r
                join information_schema.parameters p on p.specific_name = r.specific_name
                where r.routine_schema = 'public' and r.routine_name = 'nomad_organization_invitations' and p.parameter_name = 'token')
     or (select limit_value from public.nomad_plan_limits('00000000-0000-4000-8000-000000000011', 'contentflow_example')
         where limit_key = 'zz_check_posts' and plan_code = 'A') is distinct from 10
     or exists (select 1 from public.nomad_plan_limits('00000000-0000-4000-8000-000000000012', 'contentflow_example'))
  then raise exception 'A invitation list or plan limits failed'; end if;
  begin
    perform public.nomad_organization_invitations('00000000-0000-4000-8000-000000000012');
    raise exception 'cross-tenant invitation list succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000004', true);
do $$
begin
  -- viewer는 초대 목록 거부, 플랜 한도는 읽는다(C 업체는 위에서 A로 올림)
  if (select limit_value from public.nomad_plan_limits('00000000-0000-4000-8000-000000000013', 'contentflow_example')
      where limit_key = 'zz_check_posts') is distinct from 10
     or exists (select 1 from public.nomad_plan_limits('00000000-0000-4000-8000-000000000011', 'contentflow_example'))
  then raise exception 'viewer plan limits failed'; end if;
  begin
    perform public.nomad_organization_invitations('00000000-0000-4000-8000-000000000013');
    raise exception 'viewer invitation list succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
set local role anon;
do $$
begin
  begin
    perform public.nomad_plan_limits('00000000-0000-4000-8000-000000000011', 'contentflow_example');
    raise exception 'anon plan limits succeeded';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;
rollback;
