-- arch-studio AI·음성 라우팅 기본값(원본 2400_arch.sql 14장). 코어 웨이브(C5 ai) 적용 후 — nomad_core.ai_routing_settings 를 직접 참조한다.
-- 이미지 arch.render(fal)는 라우팅 종류(llm·embedding·stt·tts)가 아니라 워커 서버 상수(원본 그대로). 대화 턴 한도는 plan_limits 키 ai_chat_turns_per_day.
-- 전제: 0001_arch.sql. 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'arch';
begin;

insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'arch', 'arch.review',             'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'arch', 'arch.intake',             'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'arch', 'arch.intake_consult',     'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'arch', 'arch.proposal_narrative', 'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'arch', 'arch.chat',               'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'arch', 'arch.layout',             'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'arch', 'arch.compliance',         'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'arch', 'wiki.ingest',             'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'arch', 'wiki.query',              'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'arch', 'wiki.lint',               'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'arch', 'dify.aux',                'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'arch', 'arch.knowledge',          'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'arch', 'consult_recording',       'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true),
  (null, 'arch', 'voice_chat',              'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false)
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
    where s.organization_id is null and s.product_code = 'arch'
      and (p.id is null or not (s.kind = any (p.kinds))
           or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
    if v_bad is not null then
      raise exception 'arch routing defaults: invalid chain providers %', v_bad;
    end if;
  end if;
end $$;

commit;
