-- contentflow · 조직형 · schema.draft.sql
-- 초안(draft): 실제 서비스 확정 전에 검증하세요. 서비스 스키마 간 외래키 없음, nomad_core/auth만 참조.
-- 유형: 조직형(organization_id 기준)

create schema if not exists nomad_contentflow;
revoke all on schema nomad_contentflow from public, anon, authenticated;
grant usage on schema nomad_contentflow to authenticated, service_role;

create table nomad_contentflow.blogs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text,
  platform text,  -- 네이버·티스토리
  tone text,  -- 글쓰기 톤
  created_at timestamptz not null default now()
);
create index idx_blogs_org_id on nomad_contentflow.blogs(organization_id);
alter table nomad_contentflow.blogs enable row level security;
create policy blogs_select_member on nomad_contentflow.blogs for select using (nomad_core.organization_role(organization_id) is not null);
create policy blogs_insert_member on nomad_contentflow.blogs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy blogs_update_member on nomad_contentflow.blogs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy blogs_delete_admin on nomad_contentflow.blogs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.topics (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  blog_id uuid references nomad_contentflow.blogs(id) on delete cascade,
  keyword text,
  status text,  -- 기획·진행
  created_at timestamptz not null default now()
);
create index idx_topics_org_id on nomad_contentflow.topics(organization_id);
alter table nomad_contentflow.topics enable row level security;
create policy topics_select_member on nomad_contentflow.topics for select using (nomad_core.organization_role(organization_id) is not null);
create policy topics_insert_member on nomad_contentflow.topics for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy topics_update_member on nomad_contentflow.topics for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy topics_delete_admin on nomad_contentflow.topics for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.posts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  topic_id uuid references nomad_contentflow.topics(id) on delete cascade,
  author_id uuid references nomad_core.profiles(user_id),
  status text,  -- 검수·승인·발행
  body text,
  created_at timestamptz not null default now()
);
create index idx_posts_org_id on nomad_contentflow.posts(organization_id);
alter table nomad_contentflow.posts enable row level security;
create policy posts_select_member on nomad_contentflow.posts for select using (nomad_core.organization_role(organization_id) is not null);
create policy posts_insert_member on nomad_contentflow.posts for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy posts_update_member on nomad_contentflow.posts for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy posts_delete_admin on nomad_contentflow.posts for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.blog_members (
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  blog_id uuid references nomad_contentflow.blogs(id) on delete cascade,
  user_id uuid references nomad_core.profiles(user_id),
  role text,  -- 블로그별 역할
  primary key (organization_id, blog_id, user_id)
);
create index idx_blog_members_org_id on nomad_contentflow.blog_members(organization_id);
alter table nomad_contentflow.blog_members enable row level security;
create policy blog_members_select_member on nomad_contentflow.blog_members for select using (nomad_core.organization_role(organization_id) is not null);
create policy blog_members_insert_member on nomad_contentflow.blog_members for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy blog_members_update_member on nomad_contentflow.blog_members for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy blog_members_delete_admin on nomad_contentflow.blog_members for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.publish_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  post_id uuid references nomad_contentflow.posts(id) on delete cascade,
  blog_id uuid references nomad_contentflow.blogs(id) on delete cascade,
  url text,
  published_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_publish_logs_org_id on nomad_contentflow.publish_logs(organization_id);
alter table nomad_contentflow.publish_logs enable row level security;
create policy publish_logs_select_member on nomad_contentflow.publish_logs for select using (nomad_core.organization_role(organization_id) is not null);
create policy publish_logs_insert_member on nomad_contentflow.publish_logs for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy publish_logs_update_member on nomad_contentflow.publish_logs for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy publish_logs_delete_admin on nomad_contentflow.publish_logs for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  post_id uuid references nomad_contentflow.posts(id) on delete cascade,
  reviewer_id uuid references nomad_core.profiles(user_id),
  verdict text,  -- 통과·반려
  created_at timestamptz not null default now()
);
create index idx_reviews_org_id on nomad_contentflow.reviews(organization_id);
alter table nomad_contentflow.reviews enable row level security;
create policy reviews_select_member on nomad_contentflow.reviews for select using (nomad_core.organization_role(organization_id) is not null);
create policy reviews_insert_member on nomad_contentflow.reviews for insert with check (nomad_core.organization_role(organization_id) is not null);
create policy reviews_update_member on nomad_contentflow.reviews for update using (nomad_core.organization_role(organization_id) is not null) with check (nomad_core.organization_role(organization_id) is not null);
create policy reviews_delete_admin on nomad_contentflow.reviews for delete using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

