-- baedal 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'baedal'; delete from nomad_core.features where product_code = 'baedal'; delete from nomad_core.plans where product_code = 'baedal'; 잠금 정책은 20261115000110_baedal.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('baedal', 'C', '무료'), ('baedal', 'B', '프로'), ('baedal', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('baedal', 'order_core', '가게·메뉴·후기');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('baedal', 'C', 'order_core'),
  ('baedal', 'B', 'order_core'),
  ('baedal', 'A', 'order_core');


commit;
