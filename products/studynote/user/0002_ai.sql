-- study-note AI·음성 기본값(원본 2100_notes.sql 13·14장). 전제: 0001_studynote.sql · core 20261120000500(AI 계층 C5). user안·org안 공통 내용.
-- 원본 plans.features의 AI 불리언(ai_chat·lecture_note·voice_chat·quiz_voice, free·pro 모두 true) → 기능 A·B·C.
-- 수치(ai_chat_turns_per_day·ai_subjects_max·ai_docs_max·ai_doc_max_chars·lecture_max_minutes)는 plan_limits 키만(시드 안 함).
-- 원본 plans 가격·monthly_credits·credit_packs는 이식하지 않는다(D1 결제 계약만, existing.md).
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'studynote';
--   delete from nomad_core.plan_features where product_code = 'studynote' and feature_code in ('ai_chat', 'lecture_note', 'voice_chat', 'quiz_voice');
--   delete from nomad_core.features where product_code = 'studynote' and code in ('ai_chat', 'lecture_note', 'voice_chat', 'quiz_voice');
begin;

insert into nomad_core.features (product_code, code, name) values
  ('studynote', 'ai_chat', '내 노트 근거 Q&A'),
  ('studynote', 'lecture_note', '강의 녹음 → 노트(STT, 오픈소스 강제)'),
  ('studynote', 'voice_chat', '음성 대화'),
  ('studynote', 'quiz_voice', '퀴즈 음성')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'studynote', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'lecture_note', 'voice_chat', 'quiz_voice']) f
on conflict do nothing;

-- 기능별 라우팅 기본값(organization_id null = 플랫폼 기본). 원본 14.1 13행 그대로(notes.* → studynote.*).
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'studynote', 'studynote.organize',  'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"google","model":"*"}]', false),
  (null, 'studynote', 'studynote.quiz',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"google","model":"*"}]', false),
  (null, 'studynote', 'chat',                'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"}]', false),
  (null, 'studynote', 'wiki.query',          'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'studynote', 'wiki.ingest',         'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'studynote', 'wiki.lint',           'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'studynote', 'dify.aux',            'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'studynote', 'studynote.knowledge', 'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'studynote', 'lecture_note',        'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true),
  (null, 'studynote', 'voice_chat',          'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'studynote', 'voice_chat',          'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'studynote', 'quiz_voice',          'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'studynote', 'quiz_voice',          'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict do nothing;

-- 체인 검사(원본 14.3): 제공자 존재·종류·오픈소스 모드, 행 수 13
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'studynote'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'studynote routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'studynote') <> 13 then
    raise exception 'studynote routing defaults: expected 13 rows';
  end if;
end $$;

commit;
