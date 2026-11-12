-- flora 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'flora'; delete from nomad_core.features where product_code = 'flora'; delete from nomad_core.plans where product_code = 'flora'; 잠금 정책은 20261115000102_flora.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('flora', 'C', '무료'), ('flora', 'B', '프로'), ('flora', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('flora', 'writing_core', '프로젝트·챕터·자산'),
  ('flora', 'persona_style', '집필 페르소나(문체 고정)'),
  ('flora', 'pipeline_auto', '파이프라인 자동 실행'),
  ('flora', 'audiobook', '오디오북');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('flora', 'C', 'writing_core'),
  ('flora', 'B', 'writing_core'),
  ('flora', 'A', 'writing_core'),
  ('flora', 'B', 'persona_style'),
  ('flora', 'A', 'persona_style'),
  ('flora', 'B', 'pipeline_auto'),
  ('flora', 'A', 'pipeline_auto'),
  ('flora', 'A', 'audiobook');

alter policy personas_insert on nomad_flora.personas
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'persona_style'));
alter policy personas_update on nomad_flora.personas
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'persona_style'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'persona_style'));
alter policy pipeline_runs_insert on nomad_flora.pipeline_runs
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'pipeline_auto'));
alter policy pipeline_runs_update on nomad_flora.pipeline_runs
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'pipeline_auto'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'pipeline_auto'));
alter policy audiobooks_insert on nomad_flora.audiobooks
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'audiobook'));
alter policy audiobooks_update on nomad_flora.audiobooks
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'audiobook'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'flora', 'audiobook'));

commit;
