-- sceneflow AI·음성 기능별 라우팅 기본값(원본 1200_video.sql 11절, 모든 값 제안). 0001_sceneflow.sql 이후, core C5(nomad_core.ai_routing_settings) 후 적용.
-- 원본 org_id null·app_id 'video' → organization_id null(플랫폼 기본)·product_code 'sceneflow'. 기능 키는 원본 그대로(video.*).
--   - video.script/translate/bling, chat : 품질 우선 Claude 먼저(채널 토큰·이메일·원본 영상/오디오는 보내지 않는다).
--   - video.analyze/compliance, wiki.*  : 분류·요약·대량 처리라 오픈소스 먼저.
--   - dify.aux : 조직을 알 수 없어 국외 이전 동의를 확인할 수 없으므로 오픈소스 강제.
--   - video.knowledge/rag(embedding) : 임베딩 모델 고정, 오픈소스. video.stt : 제3자 저작물·목소리라 오픈소스 강제.
--   - narration(tts) : 작업 도중 다른 제공자로 대체하지 않는 규칙은 음성 어댑터·오케스트레이터가 강제(체인 밖).
-- 원본 11.2(플랜 AI 키 ai_chat·voice_chat·ai_script)는 0001 의 기능 이용권으로, ai_chat_turns_per_day 는 plan_limits 키(시드 없음)로 옮겼다.
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'sceneflow';
begin;

insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'sceneflow', 'video.script',     'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'sceneflow', 'video.translate',  'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'sceneflow', 'video.analyze',    'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'sceneflow', 'video.bling',      'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'sceneflow', 'video.compliance', 'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'sceneflow', 'chat',             'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'sceneflow', 'wiki.query',       'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'sceneflow', 'wiki.ingest',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'sceneflow', 'wiki.lint',        'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'sceneflow', 'dify.aux',         'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'sceneflow', 'video.knowledge',  'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'sceneflow', 'video.rag',        'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'sceneflow', 'video.stt',        'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true),
  (null, 'sceneflow', 'voice_chat',       'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'sceneflow', 'dictation',        'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'sceneflow', 'voice_chat',       'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'sceneflow', 'narration',        'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict on constraint ai_routing_settings_scope_uniq do update
  set mode = excluded.mode, chain = excluded.chain, force_open_source = excluded.force_open_source;

-- 체인 검사(원본 11.3): 제공자 존재·종류·오픈소스 모드, 행 수 17
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'sceneflow'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'sceneflow routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'sceneflow') <> 17 then
    raise exception 'sceneflow routing defaults: expected 17 rows';
  end if;
end $$;

commit;
