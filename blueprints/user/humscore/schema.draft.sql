-- humscore · 개인형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 개인형(user_id 기준)

create schema if not exists nomad_humscore;
revoke all on schema nomad_humscore from public, anon, authenticated;
grant usage on schema nomad_humscore to authenticated, service_role;

create table nomad_humscore.scores (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references nomad_core.profiles(user_id),
  title text,
  "key" text,
  notation_json jsonb,
  workspace_id uuid,  -- NULL 확장용
  created_at timestamptz not null default now()
);
alter table nomad_humscore.scores enable row level security;
create policy scores_own on nomad_humscore.scores for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_humscore.recordings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references nomad_core.profiles(user_id),
  score_id uuid references nomad_humscore.scores(id) on delete cascade,
  audio_path text,
  duration numeric,
  created_at timestamptz not null default now()
);
alter table nomad_humscore.recordings enable row level security;
create policy recordings_own on nomad_humscore.recordings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_humscore.settings (
  user_id uuid primary key,
  instrument text,
  default_key text
);
alter table nomad_humscore.settings enable row level security;
create policy settings_own on nomad_humscore.settings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table nomad_humscore.exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references nomad_core.profiles(user_id),
  score_id uuid references nomad_humscore.scores(id) on delete cascade,
  format text,  -- PDF·MusicXML
  file_path text,
  created_at timestamptz not null default now()
);
alter table nomad_humscore.exports enable row level security;
create policy exports_own on nomad_humscore.exports for all using (user_id = auth.uid()) with check (user_id = auth.uid());

