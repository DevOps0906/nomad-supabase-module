-- KNOWFLOW AI · user안: 자료 다이제스트(source_digests·save_source_digest) + PDF 자료 요약 + 권리자 삭제 영상 재등록 차단(KF451).
-- 원본: KNOWFLOW-AI 20261118000200_source_digests · 20261118000100_pdf_source_summaries · 20261112000500(register_youtube_source KF451)을
--   nomad_knowflow·user_id 기준으로 옮겼다. 0001~0004는 고치지 않고 이 파일에서 재정의한다.
-- 1) source_digests: 자료(유튜브·PDF) 1:1 다이제스트. 읽기 = 소유자, 자료가 보이고(미삭제) unavailable_at is null일 때만. 쓰기는 RPC만.
--    청크가 바뀌어도 행을 지우지 않는다(행 job_id가 최신 성공 source_ingest와 다르면 조회 API가 pending으로 보고, 현재 청크에 없는 인용은 뺀다).
-- 2) save_source_digest(job, 상태, 다이제스트, 모델): service_role(Worker) 전용. 저장 조건은 save_source_summary와 같다.
-- 3) save_source_summary 재정의: PDF 자료도 받는다. 오류 목록이 0003 주석과 달라진다 —
--    22023 invalid_summary(형식·모델명) · unsupported_summary_source(유튜브·PDF 아닌 자료, url). 0003의 not_youtube_source는 더 나지 않는다.
-- 4) nomad_knowflow_private.video_takedowns: 권리자 삭제된 video_id(전역, 모든 사용자 공통 차단 키). RLS·접근 없음(postgres만).
--    takedown_video 재정의: 여기에 기록하고 같은 영상 자료의 다이제스트도 지운다(반환에 digests_deleted 추가).
--    register_youtube_source 재정의: video_takedowns에 있는 영상은 KF451 video_taken_down(같은 프로젝트 중복 23505 다음, 한도·쿼터 전).
--    두 함수는 영상 단위 advisory 잠금으로 직렬화한다(takedown 중 동시 등록이 비활성화를 비껴가지 않게).
--    업그레이드: 0003 takedown_video가 남긴 감사 기록(nomad_core.audit_log 'knowflow.rights_takedown')으로 video_takedowns를 채운다.
-- 전제: 0001~0004.
-- 되돌림: drop function nomad_knowflow.save_source_digest(uuid, text, jsonb, text); drop table nomad_knowflow.source_digests,
--   nomad_knowflow_private.video_takedowns; save_source_summary·takedown_video는 0003, register_youtube_source는 0001 정의로 다시 만든다.
begin;

-- ===== 1) source_digests =====
create table nomad_knowflow.source_digests (
  source_id uuid primary key,
  project_id uuid not null,
  user_id uuid not null,
  -- 다이제스트를 만든 source_ingest 작업(최신 성공 작업과 비교해 오래됨을 판정한다)
  job_id uuid not null,
  status text not null check (status in ('ready', 'failed')),
  -- ready면 계약 형식(형식 검사는 save_source_digest), failed면 null
  digest jsonb,
  model text not null check (char_length(btrim(model)) between 1 and 200),
  created_at timestamptz not null default now(),
  check ((status = 'ready') = (digest is not null)),
  foreign key (source_id, project_id) references nomad_knowflow.sources (id, project_id) on delete cascade,
  foreign key (project_id, user_id) references nomad_knowflow.projects (id, user_id) on delete cascade
);
comment on table nomad_knowflow.source_digests is
  '자료 다이제스트(유튜브·PDF, 자료 1:1). 항목마다 그 자료의 청크 인용. 쓰기는 save_source_digest만. 권리자 삭제 시 삭제';
alter table nomad_knowflow.source_digests enable row level security;
create index source_digests_user_id_idx on nomad_knowflow.source_digests (user_id);
create index source_digests_project_id_idx on nomad_knowflow.source_digests (project_id);

revoke all on nomad_knowflow.source_digests from public, anon, authenticated, service_role;
grant select on nomad_knowflow.source_digests to authenticated, service_role;
-- 소유자만, 자료가 보이고(sources RLS: 미삭제·프로젝트 미삭제) 비활성이 아닐 때만. 쓰기 정책 없음(RPC만)
create policy source_digests_select_own on nomad_knowflow.source_digests for select to authenticated
  using ((select auth.uid()) = user_id
    and exists (select 1 from nomad_knowflow.sources s where s.id = source_digests.source_id and s.unavailable_at is null));

-- ===== 2) save_source_digest =====
-- 다이제스트 저장(upsert). Worker(service_role) 전용, 작업 완료 뒤 후행 단계에서 부른다.
-- p_status 'ready'는 p_digest(계약 형식)를, 'failed'는 p_digest null을 받는다(MAX_TOKENS·형식 불량 기록).
-- 저장 조건: p_job_id가 그 자료의 가장 늦게 끝난 succeeded source_ingest 작업, 자료가 미삭제·비활성 아님,
--   (ready면) 모든 chunk_id가 지금 그 자료의 청크. 아니면 false(아무것도 바꾸지 않음).
-- 자료 행을 잠가(for no key update) replace_source_chunks·takedown_video와 직렬화한다.
-- 오류(SQLSTATE 22023): invalid_digest(형식·256KB 초과·모델명·상태) · unsupported_digest_source(유튜브·PDF 아닌 자료)
create function nomad_knowflow.save_source_digest(p_job_id uuid, p_status text, p_digest jsonb, p_model text) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_job nomad_knowflow.processing_jobs;
  v_source nomad_knowflow.sources;
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
  if p_model is null or char_length(btrim(p_model)) not between 1 and 200 then
    raise exception 'invalid_digest' using errcode = '22023';
  end if;
  if p_status is null or p_status not in ('ready', 'failed') then
    raise exception 'invalid_digest' using errcode = '22023';
  end if;
  if p_status = 'failed' and p_digest is not null then
    raise exception 'invalid_digest' using errcode = '22023';
  end if;

  if p_status = 'ready' then
    if p_digest is null or jsonb_typeof(p_digest) <> 'object' or octet_length(p_digest::text) > 262144 then
      raise exception 'invalid_digest' using errcode = '22023';
    end if;
    -- 최상위: version 1, title 1~120자, glance 2~5·terms 0~6·chapters 1~6 배열
    -- (키가 없으면 jsonb_typeof가 NULL이라 coalesce로 거부한다. 길이 검사는 배열일 때만 한다 — OR는 평가 순서를 보장하지 않는다)
    if p_digest -> 'version' is distinct from '1'::jsonb
       or coalesce(jsonb_typeof(p_digest -> 'title'), '') <> 'string'
       or char_length(btrim(p_digest ->> 'title')) not between 1 and 120
       or (case when jsonb_typeof(p_digest -> 'glance') = 'array' then jsonb_array_length(p_digest -> 'glance') not between 2 and 5 else true end)
       or (case when jsonb_typeof(p_digest -> 'terms') = 'array' then jsonb_array_length(p_digest -> 'terms') > 6 else true end)
       or (case when jsonb_typeof(p_digest -> 'chapters') = 'array' then jsonb_array_length(p_digest -> 'chapters') not between 1 and 6 else true end)
    then
      raise exception 'invalid_digest' using errcode = '22023';
    end if;

    -- 항목 형식: 글자 수와 하위 배열 개수
    if exists (
      select 1 from jsonb_array_elements(p_digest -> 'glance') g
       where jsonb_typeof(g) <> 'object'
          or coalesce(jsonb_typeof(g -> 'text'), '') <> 'string'
          or char_length(btrim(g ->> 'text')) not between 1 and 300
          or case when jsonb_typeof(g -> 'details') = 'array'
                  then jsonb_array_length(g -> 'details') > 3
                    or exists (select 1 from jsonb_array_elements(g -> 'details') d
                                where jsonb_typeof(d) <> 'string' or char_length(btrim(d #>> '{}')) not between 1 and 200)
                  else true end
    ) or exists (
      select 1 from jsonb_array_elements(p_digest -> 'terms') t
       where jsonb_typeof(t) <> 'object'
          or coalesce(jsonb_typeof(t -> 'term'), '') <> 'string'
          or char_length(btrim(t ->> 'term')) not between 1 and 40
          or coalesce(jsonb_typeof(t -> 'desc'), '') <> 'string'
          or char_length(btrim(t ->> 'desc')) not between 1 and 200
    ) or exists (
      select 1 from jsonb_array_elements(p_digest -> 'chapters') c
       where jsonb_typeof(c) <> 'object'
          or coalesce(jsonb_typeof(c -> 'title'), '') <> 'string'
          or char_length(btrim(c ->> 'title')) not between 1 and 120
          or coalesce(jsonb_typeof(c -> 'intro'), '') <> 'string'
          or char_length(c ->> 'intro') > 400
          or case when jsonb_typeof(c -> 'points') = 'array'
                  then jsonb_array_length(c -> 'points') not between 1 and 4
                    or exists (
                      select 1 from jsonb_array_elements(c -> 'points') p
                       where jsonb_typeof(p) <> 'object'
                          or coalesce(jsonb_typeof(p -> 'text'), '') <> 'string'
                          or char_length(btrim(p ->> 'text')) not between 1 and 300
                          or case when jsonb_typeof(p -> 'subpoints') = 'array'
                                  then jsonb_array_length(p -> 'subpoints') > 3
                                    or exists (
                                      select 1 from jsonb_array_elements(p -> 'subpoints') s
                                       where jsonb_typeof(s) <> 'object'
                                          or coalesce(jsonb_typeof(s -> 'text'), '') <> 'string'
                                          or char_length(btrim(s ->> 'text')) not between 1 and 300
                                    )
                                  else true end
                    )
                  else true end
    ) then
      raise exception 'invalid_digest' using errcode = '22023';
    end if;

    -- 인용: 모든 항목(glance·terms·chapters·points·subpoints)이 소문자 UUID 1~20개 배열을 가진다
    if exists (
      select 1
        from (
          select g as item from jsonb_array_elements(p_digest -> 'glance') g
          union all select t from jsonb_array_elements(p_digest -> 'terms') t
          union all select c from jsonb_array_elements(p_digest -> 'chapters') c
          union all select p from jsonb_array_elements(p_digest -> 'chapters') c, jsonb_array_elements(c -> 'points') p
          union all select s from jsonb_array_elements(p_digest -> 'chapters') c, jsonb_array_elements(c -> 'points') p,
                                  jsonb_array_elements(p -> 'subpoints') s
        ) i
       where coalesce(jsonb_typeof(i.item -> 'chunk_ids'), '') <> 'array'
          or case when jsonb_typeof(i.item -> 'chunk_ids') = 'array'
                  then jsonb_array_length(i.item -> 'chunk_ids') not between 1 and 20
                    or exists (select 1 from jsonb_array_elements(i.item -> 'chunk_ids') x
                                where jsonb_typeof(x) <> 'string' or (x #>> '{}') !~ v_uuid)
                  else true end
    ) then
      raise exception 'invalid_digest' using errcode = '22023';
    end if;
  end if;

  select * into v_job from nomad_knowflow.processing_jobs
   where id = p_job_id and job_type = 'source_ingest' and status = 'succeeded';
  if not found then return false; end if;

  select * into v_source from nomad_knowflow.sources
   where id = v_job.source_id and deleted_at is null and unavailable_at is null
   for no key update;
  if not found then return false; end if;
  if v_source.source_type not in ('youtube', 'pdf') then
    raise exception 'unsupported_digest_source' using errcode = '22023';
  end if;

  -- 더 늦게 끝난 succeeded source_ingest 작업이 있으면 낡은 작업이다
  if exists (
    select 1 from nomad_knowflow.processing_jobs j
     where j.source_id = v_source.id and j.job_type = 'source_ingest' and j.status = 'succeeded' and j.id <> v_job.id
       and (j.finished_at, j.id) > (v_job.finished_at, v_job.id)
  ) then return false; end if;

  -- 모든 인용이 지금 그 자료의 청크여야 한다(형식 검사를 통과했으므로 chunk_ids 값은 UUID 문자열이다)
  if p_status = 'ready' and exists (
    select 1 from jsonb_path_query(p_digest, 'lax $.**.chunk_ids[*]') x
     where not exists (select 1 from nomad_knowflow.source_chunks sc where sc.id = (x #>> '{}')::uuid and sc.source_id = v_source.id)
  ) then return false; end if;

  insert into nomad_knowflow.source_digests (source_id, project_id, user_id, job_id, status, digest, model)
  values (v_source.id, v_source.project_id, v_source.user_id, v_job.id, p_status, p_digest, btrim(p_model))
  on conflict (source_id) do update
     set job_id = excluded.job_id, status = excluded.status, digest = excluded.digest, model = excluded.model, created_at = now();
  return true;
end;
$$;
comment on function nomad_knowflow.save_source_digest(uuid, text, jsonb, text) is
  '자료 다이제스트(ready·failed)를 최신 완료 작업·현재 청크 기준으로 저장한다. Worker(service_role) 전용';

-- ===== 3) save_source_summary 재정의 (PDF 허용) =====
-- 0003 정의와 같고 자료 유형 검사만 바꾼다(유튜브·PDF 허용, url은 22023 unsupported_summary_source). chunk_ids 누락은 형식 오류.
create or replace function nomad_knowflow.save_source_summary(p_job_id uuid, p_sentences jsonb, p_model text) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_job nomad_knowflow.processing_jobs; v_source nomad_knowflow.sources;
begin
  if p_model is null or char_length(btrim(p_model)) not between 1 and 200 then
    raise exception 'invalid_summary' using errcode = '22023';
  end if;
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array' or jsonb_array_length(p_sentences) not between 1 and 50 then
    raise exception 'invalid_summary' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_sentences) e
     where jsonb_typeof(e) <> 'object'
        -- 키가 없으면 jsonb_typeof가 NULL이라 비교가 NULL이 된다(필수 키는 coalesce로 거부)
        or coalesce(jsonb_typeof(e -> 'text'), '') <> 'string'
        or char_length(btrim(e ->> 'text')) not between 1 and 1000
        or coalesce(jsonb_typeof(e -> 'chunk_ids'), '') <> 'array'
        -- 길이·요소 검사는 배열일 때만 한다(OR는 평가 순서를 보장하지 않는다)
        or case when jsonb_typeof(e -> 'chunk_ids') = 'array'
                then jsonb_array_length(e -> 'chunk_ids') not between 1 and 20
                  or exists (
                    select 1 from jsonb_array_elements(e -> 'chunk_ids') c
                     where jsonb_typeof(c) <> 'string'
                        or (c #>> '{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                else true end
  ) then raise exception 'invalid_summary' using errcode = '22023'; end if;

  select * into v_job from nomad_knowflow.processing_jobs
   where id = p_job_id and job_type = 'source_ingest' and status = 'succeeded';
  if not found then return false; end if;

  select * into v_source from nomad_knowflow.sources
   where id = v_job.source_id and deleted_at is null and unavailable_at is null
   for no key update;
  if not found then return false; end if;
  -- 유튜브·PDF만 요약한다(url은 본문 추출 연결 전이라 거부)
  if v_source.source_type not in ('youtube', 'pdf') then
    raise exception 'unsupported_summary_source' using errcode = '22023';
  end if;

  -- 더 늦게 끝난 succeeded source_ingest 작업이 있으면 낡은 작업이다
  if exists (
    select 1 from nomad_knowflow.processing_jobs j
     where j.source_id = v_source.id and j.job_type = 'source_ingest' and j.status = 'succeeded' and j.id <> v_job.id
       and (j.finished_at, j.id) > (v_job.finished_at, v_job.id)
  ) then return false; end if;

  if exists (
    select 1 from jsonb_array_elements(p_sentences) e, jsonb_array_elements_text(e -> 'chunk_ids') c
     where not exists (select 1 from nomad_knowflow.source_chunks sc where sc.id = c::uuid and sc.source_id = v_source.id)
  ) then return false; end if;

  insert into nomad_knowflow.source_summaries (source_id, project_id, user_id, job_id, sentences, model)
  select v_source.id, v_source.project_id, v_source.user_id, v_job.id,
         jsonb_agg(jsonb_build_object('text', btrim(e ->> 'text'), 'chunk_ids', e -> 'chunk_ids') order by n),
         btrim(p_model)
    from jsonb_array_elements(p_sentences) with ordinality as t(e, n)
  on conflict (source_id) do update
     set job_id = excluded.job_id, sentences = excluded.sentences, model = excluded.model, created_at = now();
  return true;
end;
$$;
comment on table nomad_knowflow.source_summaries is
  '자료 단위 요약(유튜브·PDF, 자료 1:1). 문장마다 그 자료의 청크 인용. 청크 교체·권리자 삭제 시 삭제';
comment on function nomad_knowflow.save_source_summary(uuid, jsonb, text) is
  '자료(유튜브·PDF) 요약을 최신 완료 작업·현재 청크 기준으로 저장한다. Worker(service_role) 전용';

-- ===== 4) video_takedowns =====
-- 권리자 삭제된 영상(전역 차단 키 = video_id). takedown_video만 쓰고 register_youtube_source가 읽는다. 사용자·Worker 접근 없음
create table nomad_knowflow_private.video_takedowns (
  video_id text primary key check (video_id ~ '^[A-Za-z0-9_-]{11}$'),
  -- 처음 처리한 사유(재실행 사유·건수는 nomad_core.audit_log에 남는다)
  reason text not null check (char_length(btrim(reason)) between 1 and 1000),
  created_at timestamptz not null default now()
);
comment on table nomad_knowflow_private.video_takedowns is
  '권리자 삭제된 video_id(모든 사용자 재등록 차단, KF451). takedown_video만 쓴다. 감사 상세는 nomad_core.audit_log';
alter table nomad_knowflow_private.video_takedowns enable row level security;
revoke all on nomad_knowflow_private.video_takedowns from public, anon, authenticated, service_role;
create policy video_takedowns_deny_all on nomad_knowflow_private.video_takedowns
  for all to anon, authenticated using (false) with check (false);

-- 업그레이드: 0003 takedown_video로 이미 처리된 영상(감사 기록)을 차단 목록에 넣는다
insert into nomad_knowflow_private.video_takedowns (video_id, reason, created_at)
select distinct on (a.target_id) a.target_id, coalesce(nullif(btrim(a.metadata ->> 'reason'), ''), '0003 감사 기록에서 이관'), a.created_at
  from nomad_core.audit_log a
 where a.action = 'knowflow.rights_takedown' and a.target_type = 'youtube_video'
   and a.target_id ~ '^[A-Za-z0-9_-]{11}$'
 order by a.target_id, a.created_at
on conflict (video_id) do nothing;

-- ===== 5) takedown_video 재정의 =====
-- 0003 정의와 같고, 차단 목록에 기록(첫 사유 유지)한 뒤 같은 영상 자료의 다이제스트도 지운다.
-- 반환: {"sources", "chunks_deleted", "moments_deleted", "summaries_deleted", "digests_deleted", "active_jobs"}.
-- create or replace라 기존 EXECUTE 권한(service_role)은 그대로다.
create or replace function nomad_knowflow.takedown_video(p_video_id text, p_reason text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_sources integer; v_chunks integer; v_moments integer; v_summaries integer; v_digests integer; v_active integer; v_result jsonb;
begin
  if p_video_id is null or p_video_id !~ '^[A-Za-z0-9_-]{11}$' then
    raise exception 'invalid_video_id' using errcode = '22023';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;

  -- register_youtube_source와 같은 영상 단위 잠금: 차단 기록 전에 시작한 등록이 끝난 뒤 비활성화한다
  perform pg_advisory_xact_lock(hashtextextended('knowflow.video:' || p_video_id, 0));
  insert into nomad_knowflow_private.video_takedowns (video_id, reason) values (p_video_id, btrim(p_reason))
  on conflict (video_id) do nothing;

  update nomad_knowflow.sources set unavailable_at = coalesce(unavailable_at, now()) where video_id = p_video_id;
  get diagnostics v_sources = row_count;

  delete from nomad_knowflow.source_chunks c using nomad_knowflow.sources s
   where s.id = c.source_id and s.video_id = p_video_id;
  get diagnostics v_chunks = row_count;

  delete from nomad_knowflow.source_moments m using nomad_knowflow.sources s
   where s.id = m.source_id and s.video_id = p_video_id;
  get diagnostics v_moments = row_count;

  delete from nomad_knowflow.source_summaries ss using nomad_knowflow.sources s
   where s.id = ss.source_id and s.video_id = p_video_id;
  get diagnostics v_summaries = row_count;

  delete from nomad_knowflow.source_digests sd using nomad_knowflow.sources s
   where s.id = sd.source_id and s.video_id = p_video_id;
  get diagnostics v_digests = row_count;

  select count(*) into v_active
    from nomad_knowflow.processing_jobs j join nomad_knowflow.sources s on s.id = j.source_id
   where s.video_id = p_video_id and j.job_type = 'source_ingest' and j.status in ('queued', 'running');

  v_result := jsonb_build_object('sources', v_sources, 'chunks_deleted', v_chunks, 'moments_deleted', v_moments,
                                 'summaries_deleted', v_summaries, 'digests_deleted', v_digests, 'active_jobs', v_active);
  perform nomad_core.write_audit(null, 'knowflow.rights_takedown', 'youtube_video', p_video_id, null, null,
                                 v_result || jsonb_build_object('reason', btrim(p_reason)));
  return v_result;
end;
$$;
comment on function nomad_knowflow.takedown_video(text, text) is
  '권리자 삭제 요청 처리. 차단 목록 기록 + 해당 video_id의 모든 자료 비활성 + 청크·장면·요약·다이제스트 삭제 + 감사 기록. service_role 전용';

-- ===== 6) register_youtube_source 재정의 (KF451) =====
-- 0001 정의와 같고, 같은 프로젝트 중복(23505) 다음에 권리자 삭제 영상이면 KF451 video_taken_down(한도·쿼터 차감 전).
-- 멱등 키 재요청(이미 등록된 자료 반환)은 그대로 둔다. create or replace라 기존 EXECUTE 권한(service_role)은 그대로다.
create or replace function nomad_knowflow.register_youtube_source(
  p_user_id uuid, p_project_id uuid, p_video_id text, p_title text, p_channel_title text,
  p_duration_seconds integer, p_idempotency_key text, p_request_hash text
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_project_id uuid;
  v_source_id uuid := gen_random_uuid();
  v_job_id uuid;
  v_inserted integer;
  v_existing nomad_knowflow_private.idempotency_keys;
  v_max_sources integer;
  v_max_video integer;
begin
  if p_user_id is null then raise exception 'invalid_user' using errcode = '22023'; end if;
  if p_video_id is null or p_video_id !~ '^[A-Za-z0-9_-]{11}$' then raise exception 'invalid_video_id' using errcode = '22023'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 1 and 300 then raise exception 'invalid_title' using errcode = '22023'; end if;
  if p_channel_title is null or char_length(btrim(p_channel_title)) not between 1 and 300 then
    raise exception 'invalid_channel_title' using errcode = '22023';
  end if;
  if p_duration_seconds is null or p_duration_seconds < 1 then raise exception 'invalid_duration' using errcode = '22023'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 1 and 200
     or p_request_hash is null or char_length(p_request_hash) not between 1 and 128 then
    raise exception 'invalid_idempotency_input' using errcode = '22023';
  end if;

  select id into v_project_id from nomad_knowflow.projects
   where id = p_project_id and user_id = p_user_id and deleted_at is null for update;
  if not found then raise exception 'project_not_found' using errcode = 'P0002'; end if;
  perform nomad_knowflow_private.require_feature(p_user_id, 'knowledge_base');

  insert into nomad_knowflow_private.idempotency_keys (user_id, key, request_hash, resource_type, resource_id)
  values (p_user_id, p_idempotency_key, p_request_hash, 'source', v_source_id)
  on conflict (user_id, key) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    select * into v_existing from nomad_knowflow_private.idempotency_keys k where k.user_id = p_user_id and k.key = p_idempotency_key;
    if v_existing.request_hash <> p_request_hash or v_existing.resource_type <> 'source' then
      raise exception 'idempotency_conflict' using errcode = 'KF409';
    end if;
    select s.id, j.id into v_source_id, v_job_id
      from nomad_knowflow.sources s
      left join lateral (
        select id from nomad_knowflow.processing_jobs where source_id = s.id and job_type = 'source_ingest' order by created_at desc limit 1
      ) j on true
     where s.id = v_existing.resource_id and s.user_id = p_user_id;
    if v_source_id is null then raise exception 'idempotency_resource_missing' using errcode = 'KF410'; end if;
    return jsonb_build_object('source_id', v_source_id, 'job_id', v_job_id, 'duplicate', true);
  end if;

  if exists (select 1 from nomad_knowflow.sources where project_id = v_project_id and video_id = p_video_id and deleted_at is null) then
    raise exception 'duplicate_video' using errcode = '23505';
  end if;

  -- 권리자 요청으로 삭제(takedown_video)된 영상은 어느 사용자도 다시 등록할 수 없다(takedown과 영상 단위 잠금으로 직렬화)
  perform pg_advisory_xact_lock(hashtextextended('knowflow.video:' || p_video_id, 0));
  if exists (select 1 from nomad_knowflow_private.video_takedowns where video_id = p_video_id) then
    raise exception 'video_taken_down' using errcode = 'KF451';
  end if;

  v_max_sources := nomad_knowflow_private.limit_of('max_sources_per_project');
  v_max_video := nomad_knowflow_private.limit_of('max_video_seconds');
  if v_max_sources is null or v_max_video is null then raise exception 'quota_not_initialized' using errcode = 'P0002'; end if;
  if p_duration_seconds > v_max_video then raise exception 'video_too_long' using errcode = 'KF413'; end if;
  if (select count(*) from nomad_knowflow.sources where project_id = v_project_id and deleted_at is null) >= v_max_sources then
    raise exception 'source_limit_exceeded' using errcode = 'KF429';
  end if;

  perform nomad_knowflow_private.consume_quota_for(p_user_id, 'source_jobs', 1);
  perform nomad_knowflow_private.consume_quota_for(p_user_id, 'video_seconds', p_duration_seconds);

  insert into nomad_knowflow.sources (
    id, project_id, user_id, source_type, title, original_url,
    video_id, channel_title, duration_seconds, metadata_checked_at, video_seconds_charged, video_seconds_charged_period
  ) values (
    v_source_id, v_project_id, p_user_id, 'youtube', btrim(p_title), 'https://www.youtube.com/watch?v=' || p_video_id,
    p_video_id, btrim(p_channel_title), p_duration_seconds, now(), p_duration_seconds, nomad_knowflow_private.current_period_start()
  );
  insert into nomad_knowflow.processing_jobs (user_id, source_id, job_type)
  values (p_user_id, v_source_id, 'source_ingest') returning id into v_job_id;
  return jsonb_build_object('source_id', v_source_id, 'job_id', v_job_id, 'duplicate', false);
end;
$$;

revoke execute on function
  nomad_knowflow.save_source_digest(uuid, text, jsonb, text), nomad_knowflow.save_source_summary(uuid, jsonb, text),
  nomad_knowflow.takedown_video(text, text), nomad_knowflow.register_youtube_source(uuid, uuid, text, text, text, integer, text, text)
from public, anon, authenticated, service_role;
grant execute on function
  nomad_knowflow.save_source_digest(uuid, text, jsonb, text), nomad_knowflow.save_source_summary(uuid, jsonb, text),
  nomad_knowflow.takedown_video(text, text), nomad_knowflow.register_youtube_source(uuid, uuid, text, text, text, integer, text, text)
to service_role;

commit;
