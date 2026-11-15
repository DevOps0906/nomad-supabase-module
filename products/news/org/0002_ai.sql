-- news AI·음성 기능별 라우팅 기본값(원본 2500_news.sql 14.2절, 모든 값 제안). 0001_news.sql 이후, core C5(nomad_core.ai_routing_settings) 후 적용.
-- 원본 org_id null·app_id 'news' → organization_id null(플랫폼 기본)·product_code 'news'. 기능 키는 원본 그대로(news.*·wiki.*·dify.aux).
--   - news.draft : 보도자료 → 기사 초안. 공개 자료라 상용 먼저. 사람 승인 필수(review_article, NW006).
--   - news.headline/summary/proofread : 짧은 생성·교정. 비용 때문에 오픈소스 먼저.
--   - news.alt_text : 사진 대체텍스트 초안(이미지 입력). 상용 먼저, 오픈소스 대체.
--   - news.moderation : 댓글 모더레이션 보조. 독자 개인정보가 들어가므로 오픈소스 강제.
--   - news.assistant : 편집국 AI 어시스턴트(과거 기사·사내 규정 RAG). 상용 먼저(동의 없으면 resolve_ai_route 가 오픈소스로).
--   - news.knowledge(embedding) : 국내 오픈소스 임베딩 고정. news.tts : ElevenLabs 먼저(AI 음성 표시는 화면이 한다).
--   - news.stt : 인터뷰 받아쓰기. 취재원(제3자) 목소리라 국외로 보내지 않는다. 오픈소스 강제, 녹음 원본 미저장.
--   - wiki.*, dify.aux : 공통 규칙과 같다(dify.aux 오픈소스 강제).
-- 원본 14.1 플랜 키 ai_monthly_credits 는 plan_limits 키(시드 없음, 서버 몫)로 옮겼다.
-- 되돌림: delete from nomad_core.ai_routing_settings where organization_id is null and product_code = 'news';
begin;

insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
  (null, 'news', 'news.draft',      'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'news', 'news.headline',   'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"}]', false),
  (null, 'news', 'news.summary',    'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"}]', false),
  (null, 'news', 'news.proofread',  'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"}]', false),
  (null, 'news', 'news.alt_text',   'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"google","model":"*"},{"provider":"openai","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'news', 'news.moderation', 'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
  (null, 'news', 'news.assistant',  'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
  (null, 'news', 'news.knowledge',  'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', false),
  (null, 'news', 'news.tts',        'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
  (null, 'news', 'news.stt',        'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true),
  (null, 'news', 'wiki.query',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'news', 'wiki.ingest',     'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'news', 'wiki.lint',       'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
  (null, 'news', 'dify.aux',        'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true)
on conflict on constraint ai_routing_settings_scope_uniq do update
  set mode = excluded.mode, chain = excluded.chain, force_open_source = excluded.force_open_source;

-- 체인 검사(원본 14.3): 제공자 존재·종류·오픈소스 모드, 행 수 14
do $$
declare v_bad text;
begin
  select string_agg(s.feature || '/' || s.kind || ':' || coalesce(e.item ->> 'provider', '?'), ', ') into v_bad
  from nomad_core.ai_routing_settings s
  cross join lateral jsonb_array_elements(s.chain) as e(item)
  left join nomad_core.ai_providers p on p.id = e.item ->> 'provider'
  where s.organization_id is null and s.product_code = 'news'
    and (p.id is null or not (s.kind = any (p.kinds))
         or ((s.mode = 'open_source' or s.force_open_source) and p.source <> 'open_source'));
  if v_bad is not null then
    raise exception 'news routing defaults: invalid chain providers %', v_bad;
  end if;
  if (select count(*) from nomad_core.ai_routing_settings s where s.organization_id is null and s.product_code = 'news') <> 14 then
    raise exception 'news routing defaults: expected 14 rows';
  end if;
end $$;

commit;
