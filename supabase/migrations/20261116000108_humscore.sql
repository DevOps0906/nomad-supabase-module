-- humscore 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'humscore'; delete from nomad_core.features where product_code = 'humscore'; delete from nomad_core.plans where product_code = 'humscore'; 잠금 정책은 20261115000108_humscore.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('humscore', 'C', '무료'), ('humscore', 'B', '프로'), ('humscore', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('humscore', 'score_editor', '악보 작성·설정'),
  ('humscore', 'recording', '녹음'),
  ('humscore', 'score_export', '악보 내보내기');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('humscore', 'C', 'score_editor'),
  ('humscore', 'B', 'score_editor'),
  ('humscore', 'A', 'score_editor'),
  ('humscore', 'B', 'recording'),
  ('humscore', 'A', 'recording'),
  ('humscore', 'B', 'score_export'),
  ('humscore', 'A', 'score_export');

alter policy recordings_insert on nomad_humscore.recordings
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('humscore', 'recording')));
alter policy recordings_update on nomad_humscore.recordings
  using ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('humscore', 'recording')))
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('humscore', 'recording')));
alter policy exports_insert on nomad_humscore.exports
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('humscore', 'score_export')));
alter policy exports_update on nomad_humscore.exports
  using ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('humscore', 'score_export')))
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('humscore', 'score_export')));

commit;
