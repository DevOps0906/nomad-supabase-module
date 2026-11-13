-- website-floria AI·음성 상담 스위치와 라우팅 기본값 (원본 2200_site.sql 11절). core 웨이브(task-014: ai) 후 적용.
-- 방문자 채팅·음성은 AI 게이트(Route Handler)와 FastAPI 가 nomad_core 의 ai 표를 쓴다. 이 파일은 사이트별 스위치와 update_ai_settings 만 더한다(제품 AI 테이블 없음).
-- 전제: 0001_floria.sql. 되돌림: alter table nomad_floria.sites drop column accepts_ai_chat, drop column accepts_voice; drop function nomad_floria.update_ai_settings(uuid, boolean, boolean);
begin;

alter table nomad_floria.sites
  add column accepts_ai_chat boolean not null default false,
  add column accepts_voice boolean not null default false,
  add constraint sites_voice_needs_chat_check check (not accepts_voice or accepts_ai_chat);
comment on column nomad_floria.sites.accepts_ai_chat is 'AI 상담(방문자 채팅) 스위치. 기본 false. update_ai_settings 로만 바꾼다';
comment on column nomad_floria.sites.accepts_voice is '음성 상담 스위치. 기본 false. accepts_ai_chat 이 true 일 때만 true 가 될 수 있다';

-- 상담을 끄면 음성도 함께 끈다. update_site_settings 시그니처를 바꾸지 않으려고 별도 함수.
create function nomad_floria.update_ai_settings(
  p_site_id uuid, p_accepts_ai_chat boolean default null, p_accepts_voice boolean default null
)
returns nomad_floria.sites language plpgsql security definer set search_path = ''
as $$
declare v_row nomad_floria.sites; v_before jsonb; v_chat boolean; v_voice boolean;
begin
  select * into v_row from nomad_floria.sites where id = p_site_id for update;
  if not found then raise exception 'update_ai_settings: not found' using errcode = 'P0002'; end if;
  if not nomad_floria_private.is_service_caller() then
    if coalesce(nomad_core.organization_role(v_row.organization_id), '') not in ('owner', 'admin') then
      raise exception 'update_ai_settings: owner/admin only' using errcode = '42501';
    end if;
    if not nomad_core.has_feature(v_row.organization_id, 'floria', 'site') then
      raise exception 'update_ai_settings: no entitlement' using errcode = '42501';
    end if;
  end if;
  v_before := jsonb_build_object('accepts_ai_chat', v_row.accepts_ai_chat, 'accepts_voice', v_row.accepts_voice);
  v_chat  := coalesce(p_accepts_ai_chat, v_row.accepts_ai_chat);
  v_voice := coalesce(p_accepts_voice, v_row.accepts_voice) and v_chat;
  update nomad_floria.sites set accepts_ai_chat = v_chat, accepts_voice = v_voice
   where id = p_site_id returning * into v_row;
  perform nomad_floria_private.write_audit(v_row.organization_id, 'site.ai_settings', 'site', p_site_id::text, v_before,
                                           jsonb_build_object('accepts_ai_chat', v_row.accepts_ai_chat, 'accepts_voice', v_row.accepts_voice));
  return v_row;
end;
$$;
revoke all on function nomad_floria.update_ai_settings(uuid, boolean, boolean) from public, anon, authenticated;
grant execute on function nomad_floria.update_ai_settings(uuid, boolean, boolean) to authenticated, service_role;

-- AI 기능 키(참고, 수치 아님): product 'floria' 기능 'ai_chat'·'voice' 는 core 웨이브에서 features/plan_features 로 정의.
-- 라우팅 기본값(원본 11.1, 제안값)은 nomad_core 에 ai 라우팅 표가 생긴 뒤 같은 형식으로 넣는다. 원본 8행:
--   site.consult(llm,auto): anthropic > openai > google > oss-llm        wiki.query/ingest/lint(llm,auto): oss-llm > anthropic
--   dify.aux(llm,open_source,force_open_source): oss-llm                   site.knowledge(embedding,open_source): oss-embed
--   voice_consult(stt,auto): oss-voice > elevenlabs                        voice_consult(tts,auto): elevenlabs > oss-voice
-- 원본 11.2 체인 검사(제공자 존재·종류·오픈소스 모드)도 그 표 기준으로 옮긴다. 이 파일은 표가 없어 라우팅 insert 를 하지 않는다.

commit;
