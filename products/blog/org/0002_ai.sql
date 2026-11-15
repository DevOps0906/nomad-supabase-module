-- nomad-blog AI·음성 기본값(원본 1300_blog.sql 9장). 전제: 0001_blog.sql · core 20261120000500(AI 계층 C5).
-- 원본 plans.features 의 AI 키 → 기능: ai_chat·voice_chat·dictation(원본 free 포함 true → A·B·C), product_wiki(pro·business → A·B).
-- 수치(ai_chat_turns_per_day·rag_documents)는 plan_limits 키만(시드 안 함). 원본 가격·monthly_credits·credit_packs 는 이식하지 않는다(D1).
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'blog';
--   delete from nomad_core.plan_features where product_code = 'blog' and feature_code in ('ai_chat', 'voice_chat', 'dictation', 'product_wiki');
--   delete from nomad_core.features where product_code = 'blog' and code in ('ai_chat', 'voice_chat', 'dictation', 'product_wiki');
begin;

insert into nomad_core.features (product_code, code, name) values
  ('blog', 'ai_chat', '글쓰기 도우미 채팅'),
  ('blog', 'voice_chat', '음성 대화'),
  ('blog', 'dictation', '에디터 받아쓰기'),
  ('blog', 'product_wiki', '토픽·키워드 위키')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'blog', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'voice_chat', 'dictation']) f
union all
select 'blog', p, 'product_wiki' from unnest(array['A', 'B']) p
on conflict do nothing;

-- 기능별 라우팅 기본값(organization_id null = 플랫폼 기본). 원본 9.1 12행 그대로.
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'blog', 'blog.post_draft',  'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'blog', 'blog.assist',      'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'blog', 'chat',             'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'blog', 'blog.compliance',  'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'blog', 'wiki.query',       'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'blog', 'wiki.ingest',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'blog', 'wiki.lint',        'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'blog', 'dify.aux',         'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'blog', 'blog.knowledge',   'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'blog', 'voice_chat',       'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'blog', 'voice_chat',       'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'blog', 'dictation',        'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false)
on conflict do nothing;

-- 체인 검사(원본 9.3): 제공자 존재·종류·오픈소스 모드, 행 수 12
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'blog'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'blog routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'blog') <> 12 then
    raise exception 'blog routing defaults: expected 12 rows';
  end if;
end $$;

commit;
