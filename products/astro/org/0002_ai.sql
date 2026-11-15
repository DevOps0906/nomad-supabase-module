-- astro-ai AI·음성 기능 이용권과 라우팅 기본값 (원본 1100_astro.sql 13절). core AI 계층(nomad_core.ai_*) 직접 사용, 제품 AI 표 없음.
-- 원본 13.2: starter(무료) 플랜에 ai_chat·voice_chat·narration → 원본 무료 기능이므로 A·B·C 모두.
-- 수치 한도(ai_chat_turns_per_day 200)는 plan_limits 키로만 두고 시드하지 않는다.
-- user안·org안 공통 파일(제품 단위 설정). 전제: 0001_astro.sql. 되돌림:
--   delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'astro';
--   delete from nomad_core.plan_features where product_code = 'astro' and feature_code in ('ai_chat', 'voice_chat', 'narration');
--   delete from nomad_core.features where product_code = 'astro' and code in ('ai_chat', 'voice_chat', 'narration');
begin;

insert into nomad_core.features (product_code, code, name) values
  ('astro', 'ai_chat', '내 사주 AI 대화'),
  ('astro', 'voice_chat', '음성 질문'),
  ('astro', 'narration', '리딩 낭독')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'astro', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'voice_chat', 'narration']) f
on conflict do nothing;

-- 기능별 라우팅 기본값(organization_id null = 플랫폼 기본). 값은 원본 제안 그대로.
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'astro', 'astro.reading',   'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'astro', 'chat',            'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'astro', 'wiki.query',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'astro', 'wiki.ingest',     'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'astro', 'wiki.lint',       'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'astro', 'dify.aux',        'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'astro', 'astro.knowledge', 'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'astro', 'voice_chat',      'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'astro', 'voice_chat',      'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'astro', 'narration',       'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict on constraint ai_routing_settings_scope_uniq do update
  set mode = excluded.mode, chain = excluded.chain, force_open_source = excluded.force_open_source;

-- 체인 검사(원본 13.3): 제공자 존재·종류·오픈소스 모드
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'astro'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'astro routing defaults: invalid chain providers %', v_bad;
  end if;
end $$;

commit;
