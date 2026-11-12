-- HumScore · 개인형 · 원본: blueprints/user/humscore/schema.draft.sql
-- 되돌림: drop schema nomad_humscore cascade; delete from nomad_core.products where code = 'humscore';
begin;

create schema nomad_humscore;
revoke all on schema nomad_humscore from public, anon, authenticated;
grant usage on schema nomad_humscore to authenticated, service_role;

insert into nomad_core.products (code, name) values ('humscore', 'HumScore');

create table nomad_humscore.scores (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  "key" text,
  notation_json jsonb,
  workspace_id uuid,  -- NULL 확장용
  created_at timestamptz not null default now(),
  unique (user_id, id)
);

create table nomad_humscore.recordings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  score_id uuid,
  audio_path text,
  duration numeric,
  created_at timestamptz not null default now(),
  foreign key (user_id, score_id) references nomad_humscore.scores(user_id, id) on delete cascade
);

create table nomad_humscore.settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  instrument text,
  default_key text
);

create table nomad_humscore.exports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  score_id uuid,
  format text not null default 'pdf' check (format in ('pdf','musicxml')),
  file_path text,
  created_at timestamptz not null default now(),
  foreign key (user_id, score_id) references nomad_humscore.scores(user_id, id) on delete cascade
);

comment on table nomad_humscore.scores is '악보(사용자 소유)';
comment on table nomad_humscore.recordings is '악보에 딸린 녹음';
comment on table nomad_humscore.settings is '사용자별 악기·기본 조 설정';
comment on table nomad_humscore.exports is '악보 내보내기 결과 파일';
comment on column nomad_humscore.exports.format is 'pdf=PDF, musicxml=MusicXML';

create index scores_user_created_idx on nomad_humscore.scores (user_id, created_at desc);
create index recordings_user_created_idx on nomad_humscore.recordings (user_id, created_at desc);
create index recordings_score_idx on nomad_humscore.recordings (user_id, score_id);
create index exports_user_created_idx on nomad_humscore.exports (user_id, created_at desc);
create index exports_score_idx on nomad_humscore.exports (user_id, score_id);

alter table nomad_humscore.scores enable row level security;
alter table nomad_humscore.recordings enable row level security;
alter table nomad_humscore.settings enable row level security;
alter table nomad_humscore.exports enable row level security;

create policy scores_select on nomad_humscore.scores for select to authenticated using ((select auth.uid()) = user_id);
create policy scores_insert on nomad_humscore.scores for insert to authenticated with check ((select auth.uid()) = user_id);
create policy scores_update on nomad_humscore.scores for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy scores_delete on nomad_humscore.scores for delete to authenticated using ((select auth.uid()) = user_id);

create policy recordings_select on nomad_humscore.recordings for select to authenticated using ((select auth.uid()) = user_id);
create policy recordings_insert on nomad_humscore.recordings for insert to authenticated with check ((select auth.uid()) = user_id);
create policy recordings_update on nomad_humscore.recordings for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy recordings_delete on nomad_humscore.recordings for delete to authenticated using ((select auth.uid()) = user_id);

create policy settings_select on nomad_humscore.settings for select to authenticated using ((select auth.uid()) = user_id);
create policy settings_insert on nomad_humscore.settings for insert to authenticated with check ((select auth.uid()) = user_id);
create policy settings_update on nomad_humscore.settings for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy settings_delete on nomad_humscore.settings for delete to authenticated using ((select auth.uid()) = user_id);

create policy exports_select on nomad_humscore.exports for select to authenticated using ((select auth.uid()) = user_id);
create policy exports_insert on nomad_humscore.exports for insert to authenticated with check ((select auth.uid()) = user_id);
create policy exports_update on nomad_humscore.exports for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy exports_delete on nomad_humscore.exports for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on all tables in schema nomad_humscore from public, anon, authenticated;
grant all on all tables in schema nomad_humscore to service_role;
grant select, insert, delete on all tables in schema nomad_humscore to authenticated;
grant update (title, "key", notation_json, workspace_id) on nomad_humscore.scores to authenticated;
grant update (audio_path, duration) on nomad_humscore.recordings to authenticated;
grant update (instrument, default_key) on nomad_humscore.settings to authenticated;
grant update (format, file_path) on nomad_humscore.exports to authenticated;

commit;
