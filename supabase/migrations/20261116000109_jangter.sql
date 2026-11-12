-- jangter 기능 카탈로그(플랜 C/B/A·기능·대응)와 기능 잠금. 기준: docs/design/01-architecture/feature-catalog.md
-- 되돌림: delete from nomad_core.plan_features where product_code = 'jangter'; delete from nomad_core.features where product_code = 'jangter'; delete from nomad_core.plans where product_code = 'jangter'; 잠금 정책은 20261115000109_jangter.sql의 원래 식으로 alter policy.
begin;

insert into nomad_core.plans (product_code, code, name) values ('jangter', 'C', '무료'), ('jangter', 'B', '프로'), ('jangter', 'A', '비즈니스');
insert into nomad_core.features (product_code, code, name) values
  ('jangter', 'trade_core', '판매 글·사진·관심·채팅·후기');
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('jangter', 'C', 'trade_core'),
  ('jangter', 'B', 'trade_core'),
  ('jangter', 'A', 'trade_core');


commit;
