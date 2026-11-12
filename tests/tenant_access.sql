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
rollback;
