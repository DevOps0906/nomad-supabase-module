-- knowflow 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'knowflow'; delete from nomad_core.features where product_code = 'knowflow'; delete from nomad_core.plans where product_code = 'knowflow'; 잠금 정책은 20261115000103_knowflow.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('knowflow', 'C', '무료'), ('knowflow', 'B', '프로'), ('knowflow', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('knowflow', 'knowledge_base', '지식 공간·자료 수집'),
  ('knowflow', 'knowledge_chat', '지식 대화'),
  ('knowflow', 'space_reports', '공간 분석 보고서');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('knowflow', 'C', 'knowledge_base'),
  ('knowflow', 'B', 'knowledge_base'),
  ('knowflow', 'A', 'knowledge_base'),
  ('knowflow', 'C', 'knowledge_chat'),
  ('knowflow', 'B', 'knowledge_chat'),
  ('knowflow', 'A', 'knowledge_chat'),
  ('knowflow', 'B', 'space_reports'),
  ('knowflow', 'A', 'space_reports');

alter policy reports_insert on nomad_knowflow.reports
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'knowflow', 'space_reports'));
alter policy reports_update on nomad_knowflow.reports
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'knowflow', 'space_reports'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'knowflow', 'space_reports'));

commit;
