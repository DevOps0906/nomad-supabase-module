-- sceneflow 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'sceneflow'; delete from nomad_core.features where product_code = 'sceneflow'; delete from nomad_core.plans where product_code = 'sceneflow'; 잠금 정책은 20261115000106_sceneflow.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('sceneflow', 'C', '무료'), ('sceneflow', 'B', '프로'), ('sceneflow', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('sceneflow', 'video_project', '프로젝트·자산·장면'),
  ('sceneflow', 'ai_auto_edit', 'AI 자동편집'),
  ('sceneflow', 'render_export', '렌더링'),
  ('sceneflow', 'channel_upload', '채널 연결·업로드 예약');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('sceneflow', 'C', 'video_project'),
  ('sceneflow', 'B', 'video_project'),
  ('sceneflow', 'A', 'video_project'),
  ('sceneflow', 'B', 'ai_auto_edit'),
  ('sceneflow', 'A', 'ai_auto_edit'),
  ('sceneflow', 'C', 'render_export'),
  ('sceneflow', 'B', 'render_export'),
  ('sceneflow', 'A', 'render_export'),
  ('sceneflow', 'A', 'channel_upload');

alter policy edit_jobs_insert on nomad_sceneflow.edit_jobs
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'sceneflow', 'ai_auto_edit'));
alter policy edit_jobs_update on nomad_sceneflow.edit_jobs
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'sceneflow', 'ai_auto_edit'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'sceneflow', 'ai_auto_edit'));
alter policy channels_insert on nomad_sceneflow.channels
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'sceneflow', 'channel_upload'));
alter policy channels_update on nomad_sceneflow.channels
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'sceneflow', 'channel_upload'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin') and nomad_core.has_feature(organization_id, 'sceneflow', 'channel_upload'));
alter policy uploads_insert on nomad_sceneflow.uploads
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'sceneflow', 'channel_upload'));
alter policy uploads_update on nomad_sceneflow.uploads
  using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'sceneflow', 'channel_upload'))
  with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and nomad_core.has_feature(organization_id, 'sceneflow', 'channel_upload'));

commit;
