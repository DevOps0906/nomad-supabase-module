-- personal 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'personal'; delete from nomad_core.features where product_code = 'personal'; delete from nomad_core.plans where product_code = 'personal'; 잠금 정책은 20261115000111_personal.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('personal', 'C', '무료'), ('personal', 'B', '프로'), ('personal', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('personal', 'divination', '꿈·사주·타로 풀이'),
  ('personal', 'report_save', '풀이 리포트 저장'),
  ('personal', 'trip_planner', '여행 계획');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('personal', 'C', 'divination'),
  ('personal', 'B', 'divination'),
  ('personal', 'A', 'divination'),
  ('personal', 'B', 'report_save'),
  ('personal', 'A', 'report_save'),
  ('personal', 'B', 'trip_planner'),
  ('personal', 'A', 'trip_planner');

alter policy saved_reports_insert on nomad_personal.saved_reports
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('personal', 'report_save')));
alter policy saved_reports_update on nomad_personal.saved_reports
  using ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('personal', 'report_save')))
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('personal', 'report_save')));
alter policy trips_insert on nomad_personal.trips
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('personal', 'trip_planner')));
alter policy trips_update on nomad_personal.trips
  using ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('personal', 'trip_planner')))
  with check ((select auth.uid()) = user_id and (select nomad_core.user_has_feature('personal', 'trip_planner')));
alter policy trip_days_insert on nomad_personal.trip_days
  with check (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())) and (select nomad_core.user_has_feature('personal', 'trip_planner')));
alter policy trip_days_update on nomad_personal.trip_days
  using (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())) and (select nomad_core.user_has_feature('personal', 'trip_planner')))
  with check (exists (select 1 from nomad_personal.trips p where p.id = trip_id and p.user_id = (select auth.uid())) and (select nomad_core.user_has_feature('personal', 'trip_planner')));

commit;
