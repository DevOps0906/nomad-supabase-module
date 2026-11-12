-- classroom 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'classroom'; delete from nomad_core.features where product_code = 'classroom'; delete from nomad_core.plans where product_code = 'classroom'; 잠금 정책은 20261115000104_classroom.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('classroom', 'C', '무료'), ('classroom', 'B', '프로'), ('classroom', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('classroom', 'course_core', '강좌·회차·자료·수강 등록'),
  ('classroom', 'quiz_bank', '퀴즈 문항'),
  ('classroom', 'pre_post_assessment', '사전·사후 평가');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('classroom', 'C', 'course_core'),
  ('classroom', 'B', 'course_core'),
  ('classroom', 'A', 'course_core'),
  ('classroom', 'B', 'quiz_bank'),
  ('classroom', 'A', 'quiz_bank'),
  ('classroom', 'A', 'pre_post_assessment');

alter policy quiz_items_insert on nomad_classroom.quiz_items
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'classroom', 'quiz_bank'));
alter policy quiz_items_update on nomad_classroom.quiz_items
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'classroom', 'quiz_bank'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'classroom', 'quiz_bank'));
alter policy assessments_insert on nomad_classroom.assessments
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'classroom', 'pre_post_assessment'));
alter policy assessments_update on nomad_classroom.assessments
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'classroom', 'pre_post_assessment'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'classroom', 'pre_post_assessment'));

commit;
