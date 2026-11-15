-- school AI·음성 기본값(원본 1700_sms.sql 7절). core 웨이브(task-014)의 AI 테이블이 생기기 전에는 아무것도 하지 않는다(적용 안전).
-- core 웨이브 후 적용: nomad_core.ai_routing_settings 의 실제 이름·열은 task-014 결과에 맞춰 이 파일을 고친다(아래는 원본 열을 옮긴 가정).
-- 크레딧 차감은 쓰지 않는다. 한도 수치(ai_turns_per_day 등)는 plan_limits 키로만 두고 시드하지 않는다(수치는 운영자 결정).
-- 되돌림: delete from nomad_core.ai_routing_settings where product_code = 'school'; delete from storage.buckets where id = 'school-ai-docs';
begin;

-- AI 기능 이용권: ai_assistant 는 전 플랜, ai_voice·ai_wiki 는 상위 플랜(A·B)만(원본 default=전부 false 에 가깝던 것을 A/B/C로 옮김).
insert into nomad_core.features (product_code, code, name) values
  ('school', 'ai_assistant', '업무 어시스턴트(교직원)'),
  ('school', 'ai_voice', '업무 음성 질의'),
  ('school', 'ai_wiki', '규정·매뉴얼 위키')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code) values
  ('school', 'A', 'ai_assistant'), ('school', 'B', 'ai_assistant'), ('school', 'C', 'ai_assistant'),
  ('school', 'A', 'ai_voice'), ('school', 'B', 'ai_voice'),
  ('school', 'A', 'ai_wiki'), ('school', 'B', 'ai_wiki')
on conflict do nothing;
-- plan_limits 키(시드 없음): ai_turns_per_day · ai_turns_per_month · ai_commercial_turns_per_month · ai_docs_max

-- 라우팅 기본값. 국외 이전 동의가 없는 조직은 라우터가 상용 제공자를 걸러 낸다. 학생 AI 접근은 MVP 제외(미성년자).
do $$
begin
  if to_regclass('nomad_core.ai_routing_settings') is null then
    raise notice 'school 0002_ai: nomad_core.ai_routing_settings 없음(core 웨이브 전) — 라우팅 시드 건너뜀';
    return;
  end if;
  execute $sql$
    insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
      (null, 'school', 'admin.assistant', 'llm', 'auto', '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
      (null, 'school', 'wiki.query', 'llm', 'auto', '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
      (null, 'school', 'wiki.ingest', 'llm', 'auto', '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
      (null, 'school', 'wiki.lint', 'llm', 'auto', '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
      (null, 'school', 'dify.aux', 'llm', 'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
      (null, 'school', 'admin.knowledge', 'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
      (null, 'school', 'voice_chat', 'stt', 'auto', '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
      (null, 'school', 'voice_chat', 'tts', 'auto', '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false)
    on conflict do nothing
  $sql$;
end $$;

-- AI 문서 원본 버킷: 사용자 정책을 일부러 만들지 않는다(service_role 만 접근). 역할별 공개 범위 규정 문서가 새지 않게 하기 위함.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('school-ai-docs', 'school-ai-docs', false, 20971520,
        array['text/plain', 'text/markdown', 'application/pdf',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;

commit;
