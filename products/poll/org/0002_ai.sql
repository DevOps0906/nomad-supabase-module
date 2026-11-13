-- live-poll AI·음성 기본값(원본 1800_poll.sql 19절). core 웨이브(task-014: ai·credits) 후 적용. AI 표가 없으면 라우팅 시드는 건너뛴다(적용 안전).
-- core 웨이브 후: nomad_core.ai_routing_settings 의 실제 이름·열은 task-014 결과에 맞춰 이 파일을 고친다(아래는 원본 열을 옮긴 가정).
-- 원본 19.2 의 크레딧(signup_credits 100 · monthly 1,000/5,000)은 core credits 웨이브 대상 — 여기서 넣지 않는다(existing.md 참고).
-- 수치 한도(ai_chat_turns_per_day 등)는 plan_limits 키로만 두고 시드하지 않는다. 원칙: 청중 원문(질문·음성) 입력 단계는 오픈소스 강제.
-- 전제: 0001_poll.sql. 되돌림: delete from nomad_core.plan_features where product_code = 'poll' and feature_code <> 'host'; delete from nomad_core.features where product_code = 'poll' and code <> 'host';
begin;

-- AI 기능 이용권: 원본은 free·pro·business 모두 true → A·B·C 전부.
insert into nomad_core.features (product_code, code, name) values
  ('poll', 'ai_chat', '진행자 AI 어시스턴트'),
  ('poll', 'voice_chat', '진행자 음성 대화'),
  ('poll', 'qna_assist', 'Q&A 모더레이션·요약 보조'),
  ('poll', 'voice_question', '청중 음성 질문(STT, 오픈소스 강제)'),
  ('poll', 'event_wiki', '행사 자료 위키')
on conflict do nothing;
insert into nomad_core.plan_features (product_code, plan_code, feature_code)
select 'poll', p, f from unnest(array['A', 'B', 'C']) p, unnest(array['ai_chat', 'voice_chat', 'qna_assist', 'voice_question', 'event_wiki']) f
on conflict do nothing;
-- plan_limits 키(시드 없음): ai_chat_turns_per_day · qna_assist_runs_per_event · audience_voice_per_event · audience_voice_per_participant
--                            · materials_max_docs · materials_max_mb

-- 라우팅 기본값(organization_id null = 플랫폼 기본). 체인 제공자 검사(원본 19.3)는 core ai_providers 가 생긴 뒤 core 쪽에서 한다.
do $$
begin
  if to_regclass('nomad_core.ai_routing_settings') is null then
    raise notice 'poll 0002_ai: nomad_core.ai_routing_settings 없음(core 웨이브 전) — 라우팅 시드 건너뜀';
    return;
  end if;
  execute $sql$
    insert into nomad_core.ai_routing_settings (organization_id, product_code, feature, kind, mode, chain, force_open_source) values
      (null, 'poll', 'chat',           'llm',       'auto',        '[{"provider":"anthropic","model":"*"},{"provider":"openai","model":"*"},{"provider":"google","model":"*"},{"provider":"oss-llm","model":"*"}]', false),
      (null, 'poll', 'poll.moderate',  'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
      (null, 'poll', 'poll.summary',   'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
      (null, 'poll', 'poll.knowledge', 'embedding', 'open_source', '[{"provider":"oss-embed","model":"*"}]', true),
      (null, 'poll', 'wiki.query',     'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
      (null, 'poll', 'wiki.ingest',    'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
      (null, 'poll', 'wiki.lint',      'llm',       'auto',        '[{"provider":"oss-llm","model":"*"},{"provider":"anthropic","model":"*"}]', false),
      (null, 'poll', 'dify.aux',       'llm',       'open_source', '[{"provider":"oss-llm","model":"*"}]', true),
      (null, 'poll', 'voice_question', 'stt',       'open_source', '[{"provider":"oss-voice","model":"*"}]', true),
      (null, 'poll', 'voice_chat',     'stt',       'auto',        '[{"provider":"oss-voice","model":"*"},{"provider":"elevenlabs","model":"*"}]', false),
      (null, 'poll', 'voice_chat',     'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false),
      (null, 'poll', 'qna_read_aloud', 'tts',       'auto',        '[{"provider":"elevenlabs","model":"*"},{"provider":"oss-voice","model":"*"}]', false)
    on conflict do nothing
  $sql$;
end $$;

commit;
