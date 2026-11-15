-- nomad-commerce AI·음성 라우팅 기본값(원본 1400_commerce.sql 20.1·20.3절). 코어 웨이브(C5 ai) 적용 후 — nomad_core.ai_routing_settings 를 직접 참조한다.
-- 원본 20.2절(plans.features 의 ai_chat·ai_chat_turns_per_day·voice_chat·shorts_narration 병합)은 0001 의 기능(ai_chat·voice_chat·shorts_narration)과
--   plan_limits 키 ai_chat_turns_per_day(시드 없음)로 대체했다. 내레이션 대체 금지는 음성 어댑터(feature=shorts_narration) 몫(원본 그대로).
-- 전제: 0001_commerce.sql. 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'commerce';
begin;

insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'commerce', 'commerce.detail_page', 'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'commerce', 'commerce.compliance',  'llm',       'auto',        '[{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'commerce', 'commerce.assist',      'llm',       'auto',        '[{"provider":"google","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'commerce', 'commerce.vision',      'llm',       'auto',        '[{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'commerce', 'chat',                 'llm',       'auto',        '[{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'commerce', 'wiki.query',           'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'commerce', 'wiki.ingest',          'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'commerce', 'wiki.lint',            'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'commerce', 'dify.aux',             'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'commerce', 'commerce.knowledge',   'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'commerce', 'voice_chat',           'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'commerce', 'voice_chat',           'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'commerce', 'product_voice',        'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'commerce', 'shorts_narration',     'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
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
    where s.organization_id is null and s.product_code = 'commerce'
      and (p.id is null or not (s.kind = any (p.kinds))
           or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
    if v_bad is not null then
      raise exception 'commerce routing defaults: invalid chain providers %', v_bad;
    end if;
  end if;
end $$;

commit;
