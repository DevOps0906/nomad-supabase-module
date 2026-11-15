-- toon-factory AI·음성 기본값(원본 2000_toon.sql 10장). 코어 웨이브(C5 ai) 적용 후 — nomad_core.ai_routing_settings 를 직접 참조한다.
-- 원본 10.2 플랜 AI 키: free(하루 20턴, 영상 음성 없음) / pro(하루 200턴, 영상 음성) → 기능 이용권 + plan_limits 키 ai_chat_turns_per_day(시드 없음).
-- 원본 10.3 체인 검사는 아래 do 블록(제공자 존재·종류·오픈소스 모드)으로 옮겼다.
-- 전제: 0001_toon.sql. 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'toon';
--   delete from nomad_core.plan_features where product_code = 'toon' and feature_code in ('ai_chat', 'voice_chat', 'dialogue_voice', 'video_voice');
--   delete from nomad_core.features where product_code = 'toon' and code in ('ai_chat', 'voice_chat', 'dialogue_voice', 'video_voice');
begin;

insert into nomad_core.features (product_code, code, name) values
  ('toon', 'ai_chat', '창작 어시스턴트 채팅'),
  ('toon', 'voice_chat', '음성 질문·읽어 주기'),
  ('toon', 'dialogue_voice', '대사 음성 미리듣기'),
  ('toon', 'video_voice', 'MP4 음성 입히기')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'toon', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'voice_chat', 'dialogue_voice']) f
union all
select 'toon', p, 'video_voice' from unnest(array['A', 'B']) p
on conflict do nothing;
-- plan_limits 키(시드 없음): ai_chat_turns_per_day (원본 free 20 / pro 200)

-- 라우팅 기본값(organization_id null = 플랫폼 기본). video_voice 의 제공자 고정은 음성 어댑터가 강제(원본 주석 그대로).
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'toon', 'toon.storyboard',  'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'toon', 'toon.consistency', 'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'toon', 'toon.dialogue',    'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'toon', 'toon.prompt_en',   'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'toon', 'chat',             'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'toon', 'wiki.query',       'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'toon', 'wiki.ingest',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'toon', 'wiki.lint',        'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'toon', 'dify.aux',         'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'toon', 'toon.knowledge',   'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'toon', 'voice_chat',       'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'toon', 'voice_chat',       'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'toon', 'dialogue_voice',   'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'toon', 'video_voice',      'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict do nothing;

-- 체인 검사: 제공자 행이 있을 때만 존재·종류·오픈소스 모드를 확인한다.
do $$
declare v_bad text;
begin
  if exists (select 1 from nomad_core.ai_providers) then
    select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
    from nomad_core.ai_routing_settings s
    cross join lateral jsonb_array_elements(s.chain) as e(item)
    left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
    where s.organization_id is null and s.product_code = 'toon'
      and (p.id is null or not (s.kind = any (p.kinds))
           or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
    if v_bad is not null then
      raise exception 'toon routing defaults: invalid chain providers %', v_bad;
    end if;
  end if;
end $$;

commit;
