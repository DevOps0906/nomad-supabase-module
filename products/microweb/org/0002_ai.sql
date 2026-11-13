-- microweb-studio AI·음성 라우팅 기본값 (원본 1500_microweb.sql 20.1·20.3). core 웨이브(C5 ai) 적용 후.
-- 원본 core.ai_routing_settings(org_id null, app_id 'microweb') → nomad_core.ai_routing_settings(organization_id null, product_code 'microweb').
-- 원본 20.2(free 플랜 AI features 병합)는 0001 의 features/plan_features 로 옮겼다(수치 키는 plan_limits 이름만, 시드 안 함).
-- 원본 20.4·20.5(방명록 음성 연결·site_assets voice)는 core voice 가 있으므로 0001 에 넣었다.
-- 모든 값은 원본 제안값. 전제: 0001_microweb.sql. 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'microweb';
begin;

-- 기능 키 메모(원본 20.1): microweb_copy(문구·구성 제안, 실명·전화·계좌 미전송) · microweb_greeting(하객 AI 축하말, 오픈소스 먼저)
--   · chat(제작 상담) · wiki.*(운영자 문구 위키) · dify.aux(조직 불명 → 오픈소스 강제) · microweb_knowledge(공통 지식 임베딩, 오픈소스 고정)
--   · voice_chat(STT 오픈소스 먼저 / TTS ElevenLabs 먼저) · microweb_voice_greeting(인사말 TTS)
--   · microweb_guestbook_voice(하객 음성 STT: 하객은 국외 이전에 동의한 적이 없으므로 오픈소스 강제, 조직이 해제할 수 없다)
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'microweb', 'microweb_copy',            'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'microweb', 'microweb_greeting',        'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'microweb', 'chat',                     'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'microweb', 'wiki.query',               'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'microweb', 'wiki.ingest',              'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'microweb', 'wiki.lint',                'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'microweb', 'dify.aux',                 'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'microweb', 'microweb_knowledge',       'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'microweb', 'voice_chat',               'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'microweb', 'voice_chat',               'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'microweb', 'microweb_voice_greeting',  'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'microweb', 'microweb_guestbook_voice', 'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true)
on conflict on constraint ai_routing_settings_scope_uniq do update
  set mode = excluded.mode, chain = excluded.chain, force_open_source = excluded.force_open_source;

-- 체인 검사(원본 20.3): 제공자 존재·종류·오픈소스 모드. core 가 제공자 9개를 시드하므로 항상 검사한다.
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'microweb'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'microweb routing defaults: invalid chain providers %', v_bad;
  end if;
end $$;

commit;
