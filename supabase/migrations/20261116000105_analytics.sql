-- analytics 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'analytics'; delete from nomad_core.features where product_code = 'analytics'; delete from nomad_core.plans where product_code = 'analytics'; 잠금 정책은 20261115000105_analytics.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('analytics', 'C', '무료'), ('analytics', 'B', '프로'), ('analytics', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('analytics', 'data_analysis', '프로젝트·데이터셋·분석 실행'),
  ('analytics', 'dashboard', '대시보드·위젯'),
  ('analytics', 'report_output', '분석 보고서'),
  ('analytics', 'share_links', '외부 공유 링크');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('analytics', 'C', 'data_analysis'),
  ('analytics', 'B', 'data_analysis'),
  ('analytics', 'A', 'data_analysis'),
  ('analytics', 'B', 'dashboard'),
  ('analytics', 'A', 'dashboard'),
  ('analytics', 'B', 'report_output'),
  ('analytics', 'A', 'report_output'),
  ('analytics', 'A', 'share_links');

alter policy dashboards_insert on nomad_analytics.dashboards
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'dashboard'));
alter policy dashboards_update on nomad_analytics.dashboards
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'dashboard'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'dashboard'));
alter policy widgets_insert on nomad_analytics.widgets
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'dashboard'));
alter policy widgets_update on nomad_analytics.widgets
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'dashboard'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'dashboard'));
alter policy reports_insert on nomad_analytics.reports
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'report_output'));
alter policy reports_update on nomad_analytics.reports
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'report_output'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'analytics', 'report_output'));
alter policy share_links_insert on nomad_analytics.share_links
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'analytics', 'share_links'));
alter policy share_links_update on nomad_analytics.share_links
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'analytics', 'share_links'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'analytics', 'share_links'));

commit;
