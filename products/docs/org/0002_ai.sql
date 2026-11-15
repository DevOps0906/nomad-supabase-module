-- nomad-docs AI·음성 기능별 라우팅 기본값(원본 2300_docs.sql 26절, 모든 값 제안). core 웨이브 C5(nomad_core.ai_routing_settings) 후 적용. 0001_docs.sql 이후.
-- 원본 org_id null·app_id 'docs' → organization_id null(플랫폼 기본)·product_code 'docs'. 범위 유일 제약 ai_routing_settings_scope_uniq 로 upsert.
--   - docs.extract : 고객 RFP 기밀성 때문에 오픈소스 먼저.
--   - docs.minutes : 회의 전사본에 제3자 발언이 담기므로 오픈소스 강제.
--   - dify.aux     : 조직을 알 수 없어 국외 이전 동의를 확인할 수 없으므로 오픈소스 강제.
--   - docs.knowledge(embedding): 컬렉션 임베딩 모델 고정, 국내 오픈소스.
--   - meeting_minutes(stt): 제3자 음성, 오픈소스 강제.
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'docs';
begin;

insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'docs', 'docs.generate',   'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'docs', 'docs.assist',     'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'docs', 'docs.extract',    'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"google","model":"*"}]', false),
  (null, 'docs', 'docs.minutes',    'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'docs', 'chat',            'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"}]', false),
  (null, 'docs', 'wiki.ingest',     'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'docs', 'wiki.query',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'docs', 'wiki.lint',       'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'docs', 'dify.aux',        'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'docs', 'docs.knowledge',  'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'docs', 'meeting_minutes', 'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true),
  (null, 'docs', 'voice_chat',      'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'docs', 'voice_chat',      'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict on constraint ai_routing_settings_scope_uniq do update
  set mode = excluded.mode, chain = excluded.chain, force_open_source = excluded.force_open_source;

-- 체인 검사(원본 26절): 제공자 존재·종류·오픈소스 모드, 행 수 13
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'docs'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'docs routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'docs') <> 13 then
    raise exception 'docs routing defaults: expected 13 rows';
  end if;
end $$;

commit;
