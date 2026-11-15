-- book-trailer AI·음성 기본값(원본 2600_trailer.sql 12·13장). 전제: 0001_trailer.sql · core 20261120000500(AI 계층 C5).
-- 원본 plans.features의 AI 키 → 기능(ai_chat·voice_chat, 원본 free 포함 전 플랜 true → A·B·C). 수치(ai_chat_turns_per_day)는 plan_limits 키만.
-- 원본 plans 가격·monthly_credits·signup_credits·credit_packs는 이식하지 않는다(D1 결제 계약만 · 크레딧 지급은 core grant_plan_credits, existing.md).
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'trailer';
--   delete from nomad_core.plan_features where product_code = 'trailer' and feature_code in ('ai_chat', 'voice_chat');
--   delete from nomad_core.features where product_code = 'trailer' and code in ('ai_chat', 'voice_chat');
begin;

insert into nomad_core.features (product_code, code, name) values
  ('trailer', 'ai_chat', '트레일러 코치(책 근거 Q&A)'),
  ('trailer', 'voice_chat', '음성 대화')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'trailer', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'voice_chat']) f
on conflict do nothing;

-- 기능별 라우팅 기본값(organization_id null = 플랫폼 기본). 원본 13장 16행 그대로.
insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'trailer', 'trailer.digest',     'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'trailer', 'trailer.brief',      'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'trailer', 'trailer.storyboard', 'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'trailer', 'trailer.prompt_en',  'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'trailer', 'trailer.meta',       'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'trailer', 'trailer.compliance', 'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'trailer', 'chat',               'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'trailer', 'wiki.ingest',        'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'trailer', 'wiki.query',         'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'trailer', 'wiki.lint',          'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'trailer', 'dify.aux',           'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'trailer', 'trailer.knowledge',  'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'trailer', 'voice_chat',         'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'trailer', 'dictation',          'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
  (null, 'trailer', 'voice_chat',         'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'trailer', 'narration',          'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
on conflict do nothing;

-- 체인 검사(원본 13장): 제공자 존재·종류·오픈소스 모드, 행 수 16
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'trailer'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'trailer routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'trailer') <> 16 then
    raise exception 'trailer routing defaults: expected 16 rows';
  end if;
end $$;

commit;
