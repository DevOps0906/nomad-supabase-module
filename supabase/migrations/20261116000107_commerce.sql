-- commerce 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'commerce'; delete from nomad_core.features where product_code = 'commerce'; delete from nomad_core.plans where product_code = 'commerce'; 잠금 정책은 20261115000107_commerce.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('commerce', 'C', '무료'), ('commerce', 'B', '프로'), ('commerce', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('commerce', 'sourcing', '소싱·판매 상품'),
  ('commerce', 'marketplace_listing', '마켓 계정·상품 등록'),
  ('commerce', 'commerce_automation', '자동화 작업');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('commerce', 'C', 'sourcing'),
  ('commerce', 'B', 'sourcing'),
  ('commerce', 'A', 'sourcing'),
  ('commerce', 'B', 'marketplace_listing'),
  ('commerce', 'A', 'marketplace_listing'),
  ('commerce', 'A', 'commerce_automation');

alter policy marketplace_accounts_insert on nomad_commerce.marketplace_accounts
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'commerce', 'marketplace_listing'));
alter policy marketplace_accounts_update on nomad_commerce.marketplace_accounts
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'commerce', 'marketplace_listing'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'commerce', 'marketplace_listing'));
alter policy listings_insert on nomad_commerce.listings
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'commerce', 'marketplace_listing'));
alter policy listings_update on nomad_commerce.listings
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'commerce', 'marketplace_listing'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'commerce', 'marketplace_listing'));
alter policy automation_jobs_insert on nomad_commerce.automation_jobs
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'commerce', 'commerce_automation'));
alter policy automation_jobs_update on nomad_commerce.automation_jobs
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'commerce', 'commerce_automation'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'commerce', 'commerce_automation'));

commit;
