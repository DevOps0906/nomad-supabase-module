-- 검사 공통 준비(트랜잭션 안에서만 쓰고 rollback). 실행: bash products/knowflow/run_check.sh user|org
-- 1) 청사진 nomad_knowflow 제거  2) nomad_core.touch_updated_at 임시 정의(task-011 전)  3) 제품·플랜·한도 시드(검사용 작은 값)  4) 검사 보조 함수
drop schema if exists nomad_knowflow cascade;
drop schema if exists nomad_knowflow_private cascade;

create or replace function nomad_core.touch_updated_at() returns trigger
language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end; $$;

insert into nomad_core.products (code, name) values ('knowflow', 'KNOWFLOW AI') on conflict do nothing;
insert into nomad_core.plans (product_code, code, name) values ('knowflow', 'C', 'C') on conflict do nothing;
insert into nomad_core.plan_limits (product_code, plan_code, limit_key, limit_value) values
  ('knowflow', 'C', 'max_projects', 2),
  ('knowflow', 'C', 'max_sources_per_project', 2),
  ('knowflow', 'C', 'monthly_questions', 5),
  ('knowflow', 'C', 'monthly_reports', 5),
  ('knowflow', 'C', 'monthly_source_jobs', 3),
  ('knowflow', 'C', 'max_video_seconds', 600),
  ('knowflow', 'C', 'monthly_video_seconds', 1000)
on conflict (product_code, plan_code, limit_key) do update set limit_value = excluded.limit_value;

create function public.t_login(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function public.t_role(r text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', json_build_object('role', r)::text, true);
  perform set_config('role', r, true);
end $$;
-- 지정한 SQLSTATE로 실패해야 통과
create function public.t_expect(q text, st text) returns void language plpgsql as $$
begin
  begin
    execute q;
  exception when others then
    if sqlstate = st then return; end if;
    raise exception 'FAIL expected % got % (%): %', st, sqlstate, sqlerrm, q;
  end;
  raise exception 'FAIL expected % but succeeded: %', st, q;
end $$;
create function public.t_eq(actual bigint, expected bigint, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL % : expected % got %', label, expected, actual; end if;
  raise notice 'ok  %', label;
end $$;
