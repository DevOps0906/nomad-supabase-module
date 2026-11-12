-- contentflow 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'contentflow'; delete from nomad_core.features where product_code = 'contentflow'; delete from nomad_core.plans where product_code = 'contentflow'; 잠금 정책은 20261115000101_contentflow.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('contentflow', 'C', '무료'), ('contentflow', 'B', '프로'), ('contentflow', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('contentflow', 'blog_core', '블로그·주제·글 작성'),
  ('contentflow', 'blog_team', '블로그 멤버 관리'),
  ('contentflow', 'publish_automation', '발행 기록·자동 발행'),
  ('contentflow', 'quality_review', '글 검수');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('contentflow', 'C', 'blog_core'),
  ('contentflow', 'B', 'blog_core'),
  ('contentflow', 'A', 'blog_core'),
  ('contentflow', 'C', 'blog_team'),
  ('contentflow', 'B', 'blog_team'),
  ('contentflow', 'A', 'blog_team'),
  ('contentflow', 'B', 'publish_automation'),
  ('contentflow', 'A', 'publish_automation'),
  ('contentflow', 'A', 'quality_review');

alter policy publish_logs_insert on nomad_contentflow.publish_logs
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'contentflow', 'publish_automation'));
alter policy publish_logs_update on nomad_contentflow.publish_logs
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'contentflow', 'publish_automation'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'contentflow', 'publish_automation'));
alter policy reviews_insert on nomad_contentflow.reviews
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and reviewer_id = (select auth.uid()) and nomad_core.has_feature(organization_id, 'contentflow', 'quality_review'));
alter policy reviews_update on nomad_contentflow.reviews
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'contentflow', 'quality_review'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'contentflow', 'quality_review'));

commit;
