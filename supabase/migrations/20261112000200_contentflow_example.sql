begin;

create schema nomad_contentflow_example;
revoke all on schema nomad_contentflow_example from public, anon, authenticated;
grant usage on schema nomad_contentflow_example to authenticated, service_role;

insert into nomad_core.products values ('contentflow_example', 'ContentFlow 실습');
insert into nomad_core.plans values
  ('contentflow_example', 'C', '기본'), ('contentflow_example', 'B', '중간'),
  ('contentflow_example', 'A', '최상위');
insert into nomad_core.features values
  ('contentflow_example', 'posts', '게시물 관리'),
  ('contentflow_example', 'basic_analytics', '기본 통계'),
  ('contentflow_example', 'scheduled_publish', '예약 발행'),
  ('contentflow_example', 'advanced_analytics', '고급 분석'),
  ('contentflow_example', 'approvals', '승인 워크플로');
insert into nomad_core.plan_features
select p.product_code, p.code, f.code
from nomad_core.plans p
join nomad_core.features f on f.product_code = p.product_code
where p.product_code = 'contentflow_example'
  and (f.code in ('posts', 'basic_analytics')
    or (f.code = 'scheduled_publish' and p.code in ('A', 'B'))
    or p.code = 'A');
insert into nomad_core.addon_products
values ('contentflow_example', 'advanced-analytics', 'advanced_analytics', true);

create table nomad_contentflow_example.posts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  title text not null check (length(trim(title)) > 0),
  created_at timestamptz not null default now()
);
create index posts_by_organization on nomad_contentflow_example.posts(organization_id, created_at desc);

create table nomad_contentflow_example.analytics_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id),
  title text not null,
  report jsonb not null
);
create index reports_by_organization on nomad_contentflow_example.analytics_reports(organization_id);

revoke all on all tables in schema nomad_contentflow_example from public, anon, authenticated;
grant select, insert, update on nomad_contentflow_example.posts to authenticated;
grant select on nomad_contentflow_example.analytics_reports to authenticated;
grant select, insert, update, delete on all tables in schema nomad_contentflow_example to service_role;

alter table nomad_contentflow_example.posts enable row level security;
alter table nomad_contentflow_example.analytics_reports enable row level security;

create policy posts_read on nomad_contentflow_example.posts
  for select to authenticated
  using (nomad_core.has_feature(organization_id, 'contentflow_example', 'posts'));
create policy posts_insert on nomad_contentflow_example.posts
  for insert to authenticated
  with check (nomad_core.has_feature(organization_id, 'contentflow_example', 'posts')
    and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy posts_update on nomad_contentflow_example.posts
  for update to authenticated
  using (nomad_core.has_feature(organization_id, 'contentflow_example', 'posts')
    and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'))
  with check (nomad_core.has_feature(organization_id, 'contentflow_example', 'posts')
    and nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));

-- Allow editing content while preserving tenant ownership and row identity.
revoke update on nomad_contentflow_example.posts from authenticated;
grant update (title) on nomad_contentflow_example.posts to authenticated;

create policy reports_read on nomad_contentflow_example.analytics_reports
  for select to authenticated
  using (nomad_core.has_feature(organization_id, 'contentflow_example', 'advanced_analytics'));

commit;
