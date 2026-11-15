-- FLORA Publishing AI·음성 기본값(원본 1000_publishing.sql 15장). 전제: 0001_flora.sql · core 20261120000500(AI 계층 C5).
-- 원본 plans.features 의 AI 키 → 기능: ai_chat·book_wiki·voice_dictation(원본 free 포함 true → A·B·C), narration(basic만 → A·B).
-- 수치(ai_chat_turns_per_day·rag_files_max)는 plan_limits 키만(시드 안 함). 원본 가격·monthly_credits·credit_packs 는 이식하지 않는다(D1).
-- 라우팅 기능 키는 원본 publishing.* → flora.* 로 바꾼다(팀장 결정 2026-11-14, 앱의 resolve_ai_route 호출 문자열도 변경). 나머지 키는 그대로.
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'flora';
--   delete from nomad_core.plan_features where product_code = 'flora' and feature_code in ('ai_chat', 'book_wiki', 'voice_dictation', 'narration');
--   delete from nomad_core.features where product_code = 'flora' and code in ('ai_chat', 'book_wiki', 'voice_dictation', 'narration');
begin;

insert into nomad_core.features (product_code, code, name) values
  ('flora', 'ai_chat', '글쓰기 도우미 채팅'),
  ('flora', 'book_wiki', '책 설정집 위키'),
  ('flora', 'voice_dictation', '받아쓰기·채팅 음성'),
  ('flora', 'narration', '원고 낭독·오디오북 미리듣기')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'flora', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'book_wiki', 'voice_dictation']) f
union all
select 'flora', p, 'narration' from unnest(array['A', 'B']) p
on conflict do nothing;

-- 기능별 라우팅 기본값(organization_id null = 플랫폼 기본). 원본 15.1 12행 그대로.
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'flora', 'flora.draft',     'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'flora', 'flora.assist',    'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'flora', 'chat',                 'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'flora', 'wiki.query',           'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'flora', 'wiki.ingest',          'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'flora', 'wiki.lint',            'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'flora', 'dify.aux',             'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'flora', 'flora.knowledge', 'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'flora', 'flora.dictation', 'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'flora', 'voice_chat',           'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'flora', 'voice_chat',           'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'flora', 'narration',            'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict do nothing;

-- 체인 검사(원본 15.3): 제공자 존재·종류·오픈소스 모드, 행 수 12
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'flora'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'flora routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'flora') <> 12 then
    raise exception 'flora routing defaults: expected 12 rows';
  end if;
end $$;

commit;
