-- contentflow · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, core/auth만 참조.
-- 유형: 조직형(org_id 기준)

create schema if not exists contentflow;

create table contentflow.blogs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  name text,
  platform text,  -- 네이버·티스토리
  tone text,  -- 글쓰기 톤
  created_at timestamptz not null default now()
);
create index idx_blogs_org_id on contentflow.blogs(org_id);
alter table contentflow.blogs enable row level security;
create policy blogs_select_member on contentflow.blogs for select using (core.is_member(org_id));
create policy blogs_insert_member on contentflow.blogs for insert with check (core.is_member(org_id));
create policy blogs_update_member on contentflow.blogs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy blogs_delete_admin on contentflow.blogs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table contentflow.topics (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  blog_id uuid references contentflow.blogs(id) on delete cascade,
  keyword text,
  status text,  -- 기획·진행
  created_at timestamptz not null default now()
);
create index idx_topics_org_id on contentflow.topics(org_id);
alter table contentflow.topics enable row level security;
create policy topics_select_member on contentflow.topics for select using (core.is_member(org_id));
create policy topics_insert_member on contentflow.topics for insert with check (core.is_member(org_id));
create policy topics_update_member on contentflow.topics for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy topics_delete_admin on contentflow.topics for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table contentflow.posts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  topic_id uuid references contentflow.topics(id) on delete cascade,
  author_id uuid references core.profiles(user_id),
  status text,  -- 검수·승인·발행
  body text,
  created_at timestamptz not null default now()
);
create index idx_posts_org_id on contentflow.posts(org_id);
alter table contentflow.posts enable row level security;
create policy posts_select_member on contentflow.posts for select using (core.is_member(org_id));
create policy posts_insert_member on contentflow.posts for insert with check (core.is_member(org_id));
create policy posts_update_member on contentflow.posts for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy posts_delete_admin on contentflow.posts for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table contentflow.blog_members (
  org_id uuid not null references core.organizations(id) on delete cascade,
  blog_id uuid references contentflow.blogs(id) on delete cascade,
  user_id uuid references core.profiles(user_id),
  role text,  -- 블로그별 역할
  primary key (org_id, blog_id, user_id)
);
create index idx_blog_members_org_id on contentflow.blog_members(org_id);
alter table contentflow.blog_members enable row level security;
create policy blog_members_select_member on contentflow.blog_members for select using (core.is_member(org_id));
create policy blog_members_insert_member on contentflow.blog_members for insert with check (core.is_member(org_id));
create policy blog_members_update_member on contentflow.blog_members for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy blog_members_delete_admin on contentflow.blog_members for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table contentflow.publish_logs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  post_id uuid references contentflow.posts(id) on delete cascade,
  blog_id uuid references contentflow.blogs(id) on delete cascade,
  url text,
  published_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_publish_logs_org_id on contentflow.publish_logs(org_id);
alter table contentflow.publish_logs enable row level security;
create policy publish_logs_select_member on contentflow.publish_logs for select using (core.is_member(org_id));
create policy publish_logs_insert_member on contentflow.publish_logs for insert with check (core.is_member(org_id));
create policy publish_logs_update_member on contentflow.publish_logs for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy publish_logs_delete_admin on contentflow.publish_logs for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

create table contentflow.reviews (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references core.organizations(id) on delete cascade,
  post_id uuid references contentflow.posts(id) on delete cascade,
  reviewer_id uuid references core.profiles(user_id),
  verdict text,  -- 통과·반려
  created_at timestamptz not null default now()
);
create index idx_reviews_org_id on contentflow.reviews(org_id);
alter table contentflow.reviews enable row level security;
create policy reviews_select_member on contentflow.reviews for select using (core.is_member(org_id));
create policy reviews_insert_member on contentflow.reviews for insert with check (core.is_member(org_id));
create policy reviews_update_member on contentflow.reviews for update using (core.is_member(org_id)) with check (core.is_member(org_id));
create policy reviews_delete_admin on contentflow.reviews for delete using (core.has_role(org_id, array['owner','admin']::core.member_role[]));

