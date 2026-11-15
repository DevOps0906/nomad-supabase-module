-- ERP AI 기본값(원본 1600_erp.sql 7장). core 웨이브 C5(AI 계층) 적용 후에만 적용한다. 0001_erp.sql 이후.
-- AI 라우팅 시드는 core 표 이름·컬럼이 확정된 뒤 채운다(원본: ai_routing_settings, org_id=null, app_id='erp'). 체인 값은 existing.md 참고.
-- 되돌림: delete from storage.buckets where id = 'ai-docs';  (ai-docs는 다른 제품이 쓰면 건드리지 말 것)
begin;

-- AI 문서 원본 버킷: 사용자 정책을 일부러 만들지 않는다(service_role만 접근). 역할별 공개 범위가 있는 규정 문서가 새지 않게.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ai-docs', 'ai-docs', false, 20971520,
        array['text/plain', 'text/markdown', 'application/pdf',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;

-- 라우팅 기본 시드: C5가 끝나기 전에는 표가 없으므로 건너뛴다(알림만). 이후 이 블록을 확정 컬럼명으로 채운다.
do $$
begin
  if to_regclass('nomad_core.ai_routing_settings') is null then
    raise notice 'erp 0002_ai: nomad_core.ai_routing_settings 없음 - 라우팅 시드 건너뜀(core 웨이브 C5 후 채움)';
  else
    raise notice 'erp 0002_ai: 라우팅 시드는 확정 컬럼명으로 작성 필요(existing.md 7장 표)';
  end if;
end $$;

commit;
