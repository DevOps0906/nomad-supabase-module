-- humscore · 개인형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 개인형(user_id 기준)

create schema if not exists humscore;

create table humscore.scores (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references core.profiles(user_id),
  title text,
  "key" text,
  notation_json jsonb,
  workspace_id uuid,  -- NULL 확장용
  created_at timestamptz not null default now()
);
alter table humscore.scores enable row level security;
create policy scores_own on humscore.scores for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table humscore.recordings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references core.profiles(user_id),
  score_id uuid references humscore.scores(id) on delete cascade,
  audio_path text,
  duration numeric,
  created_at timestamptz not null default now()
);
alter table humscore.recordings enable row level security;
create policy recordings_own on humscore.recordings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table humscore.settings (
  user_id uuid primary key,
  instrument text,
  default_key text
);
alter table humscore.settings enable row level security;
create policy settings_own on humscore.settings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table humscore.exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references core.profiles(user_id),
  score_id uuid references humscore.scores(id) on delete cascade,
  format text,  -- PDF·MusicXML
  file_path text,
  created_at timestamptz not null default now()
);
alter table humscore.exports enable row level security;
create policy exports_own on humscore.exports for all using (user_id = auth.uid()) with check (user_id = auth.uid());

