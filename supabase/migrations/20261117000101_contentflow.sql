-- contentflow 보류 상태·종류 컬럼 값 목록 확정(nomad_contentflow.blog_members.role): not null·check·기본값·설명. 기준: tasks/task-005-status-values.md
-- 기존 데이터는 바꾸지 않는다. null·목록 밖 값이 있으면 맨 앞 점검에서 실패한다(docs/INTEGRATION.md 상태 값 사전 점검).
-- 되돌림: alter table nomad_contentflow.blog_members drop constraint blog_members_role_check, alter column role drop not null, alter column role drop default; 설명은 이전 문구로 comment on column.
begin;

-- 사전 점검: null 또는 목록 밖 값이 있으면 아무것도 바꾸지 않고 중단
do $$
declare
  r record;
  v_bad text;
begin
  for r in select * from (values
    ('nomad_contentflow', 'blog_members', 'role', array['owner', 'editor', 'viewer'])
  ) as v(sch, tbl, col, allowed)
  loop
    execute format(
      'select string_agg(coalesce(quote_literal(%1$I), ''null'') || '' '' || n || ''건'', '', '' order by n desc) '
      'from (select %1$I, count(*) as n from %2$I.%3$I where %1$I is null or not (%1$I = any ($1)) group by %1$I) s',
      r.col, r.sch, r.tbl)
    into v_bad using r.allowed;
    if v_bad is not null then
      raise exception '%.%.% 에 null 또는 목록 밖 값이 있습니다: % (허용: %). docs/INTEGRATION.md 사전 점검 참조', r.sch, r.tbl, r.col, v_bad, array_to_string(r.allowed, ', ');
    end if;
  end loop;
end;
$$;

alter table nomad_contentflow.blog_members
  alter column role set default 'editor',
  alter column role set not null,
  add constraint blog_members_role_check check (role in ('owner', 'editor', 'viewer'));
comment on column nomad_contentflow.blog_members.role is '블로그별 역할: owner 소유자, editor 편집자, viewer 열람자';

commit;
