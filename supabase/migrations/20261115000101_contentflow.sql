-- ContentFlow AI · 조직형
-- 원본 청사진: blueprints/org/contentflow/schema.draft.sql
-- 되돌림: drop schema nomad_contentflow cascade; delete from nomad_core.products where code = 'contentflow';
begin;

create schema nomad_contentflow;
revoke all on schema nomad_contentflow from public, anon, authenticated;
grant usage on schema nomad_contentflow to authenticated, service_role;

insert into nomad_core.products (code, name) values ('contentflow', 'ContentFlow AI');

create table nomad_contentflow.blogs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  name text not null,
  platform text not null default 'naver' check (platform in ('naver', 'tistory')),
  tone text,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
comment on table nomad_contentflow.blogs is '블로그 계정(채널) 목록';
comment on column nomad_contentflow.blogs.platform is '블로그 플랫폼: naver 네이버, tistory 티스토리';
comment on column nomad_contentflow.blogs.tone is '글쓰기 톤';
create index idx_blogs_org_created on nomad_contentflow.blogs(organization_id, created_at desc);
alter table nomad_contentflow.blogs enable row level security;
create policy blogs_select on nomad_contentflow.blogs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy blogs_insert on nomad_contentflow.blogs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy blogs_update on nomad_contentflow.blogs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy blogs_delete on nomad_contentflow.blogs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.topics (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  blog_id uuid,
  keyword text,
  status text not null default 'planning' check (status in ('planning', 'in_progress')),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, blog_id) references nomad_contentflow.blogs(organization_id, id) on delete cascade
);
comment on table nomad_contentflow.topics is '블로그별 글 주제(키워드) 기획';
comment on column nomad_contentflow.topics.status is '주제 상태: planning 기획, in_progress 진행';
create index idx_topics_org_created on nomad_contentflow.topics(organization_id, created_at desc);
create index idx_topics_blog_id on nomad_contentflow.topics(organization_id, blog_id);
alter table nomad_contentflow.topics enable row level security;
create policy topics_select on nomad_contentflow.topics for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy topics_insert on nomad_contentflow.topics for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy topics_update on nomad_contentflow.topics for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy topics_delete on nomad_contentflow.topics for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.posts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  topic_id uuid,
  author_id uuid default auth.uid() references auth.users(id) on delete set null,
  status text not null default 'review' check (status in ('review', 'approved', 'published')),
  body text,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, topic_id) references nomad_contentflow.topics(organization_id, id) on delete cascade
);
comment on table nomad_contentflow.posts is '주제별 글(초안~발행)';
comment on column nomad_contentflow.posts.status is '글 상태: review 검수, approved 승인, published 발행';
create index idx_posts_org_created on nomad_contentflow.posts(organization_id, created_at desc);
create index idx_posts_topic_id on nomad_contentflow.posts(organization_id, topic_id);
create index idx_posts_author_id on nomad_contentflow.posts(author_id);
alter table nomad_contentflow.posts enable row level security;
create policy posts_select on nomad_contentflow.posts for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy posts_insert on nomad_contentflow.posts for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and author_id = (select auth.uid()));
create policy posts_update on nomad_contentflow.posts for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy posts_delete on nomad_contentflow.posts for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.blog_members (
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  blog_id uuid not null,
  user_id uuid not null,
  role text,
  primary key (organization_id, blog_id, user_id),
  foreign key (organization_id, blog_id) references nomad_contentflow.blogs(organization_id, id) on delete cascade,
  foreign key (organization_id, user_id) references nomad_core.memberships(organization_id, user_id) on delete cascade
);
comment on table nomad_contentflow.blog_members is '블로그별 멤버와 역할';
comment on column nomad_contentflow.blog_members.role is '블로그별 역할';
create index idx_blog_members_user_id on nomad_contentflow.blog_members(organization_id, user_id);
alter table nomad_contentflow.blog_members enable row level security;
create policy blog_members_select on nomad_contentflow.blog_members for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy blog_members_insert on nomad_contentflow.blog_members for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy blog_members_update on nomad_contentflow.blog_members for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin'));
create policy blog_members_delete on nomad_contentflow.blog_members for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.publish_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  post_id uuid,
  blog_id uuid,
  url text,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organization_id, post_id) references nomad_contentflow.posts(organization_id, id) on delete cascade,
  foreign key (organization_id, blog_id) references nomad_contentflow.blogs(organization_id, id) on delete cascade
);
comment on table nomad_contentflow.publish_logs is '글 발행 기록';
create index idx_publish_logs_org_created on nomad_contentflow.publish_logs(organization_id, created_at desc);
create index idx_publish_logs_post_id on nomad_contentflow.publish_logs(organization_id, post_id);
create index idx_publish_logs_blog_id on nomad_contentflow.publish_logs(organization_id, blog_id);
alter table nomad_contentflow.publish_logs enable row level security;
create policy publish_logs_select on nomad_contentflow.publish_logs for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy publish_logs_insert on nomad_contentflow.publish_logs for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy publish_logs_update on nomad_contentflow.publish_logs for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy publish_logs_delete on nomad_contentflow.publish_logs for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

create table nomad_contentflow.reviews (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references nomad_core.organizations(id) on delete cascade,
  post_id uuid,
  reviewer_id uuid default auth.uid() references auth.users(id) on delete set null,
  verdict text not null default 'pass' check (verdict in ('pass', 'reject')),
  created_at timestamptz not null default now(),
  foreign key (organization_id, post_id) references nomad_contentflow.posts(organization_id, id) on delete cascade
);
comment on table nomad_contentflow.reviews is '글 검수 결과';
comment on column nomad_contentflow.reviews.verdict is '검수 결과: pass 통과, reject 반려';
create index idx_reviews_org_created on nomad_contentflow.reviews(organization_id, created_at desc);
create index idx_reviews_post_id on nomad_contentflow.reviews(organization_id, post_id);
create index idx_reviews_reviewer_id on nomad_contentflow.reviews(reviewer_id);
alter table nomad_contentflow.reviews enable row level security;
create policy reviews_select on nomad_contentflow.reviews for select to authenticated using (nomad_core.organization_role(organization_id) is not null);
create policy reviews_insert on nomad_contentflow.reviews for insert to authenticated with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor') and reviewer_id = (select auth.uid()));
create policy reviews_update on nomad_contentflow.reviews for update to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor')) with check (nomad_core.organization_role(organization_id) in ('owner', 'admin', 'editor'));
create policy reviews_delete on nomad_contentflow.reviews for delete to authenticated using (nomad_core.organization_role(organization_id) in ('owner', 'admin'));

revoke all on all tables in schema nomad_contentflow from public, anon, authenticated;
grant all on all tables in schema nomad_contentflow to service_role;
grant select, insert, delete on nomad_contentflow.blogs to authenticated;
grant update (name, platform, tone) on nomad_contentflow.blogs to authenticated;
grant select, insert, delete on nomad_contentflow.topics to authenticated;
grant update (blog_id, keyword, status) on nomad_contentflow.topics to authenticated;
grant select, insert, delete on nomad_contentflow.posts to authenticated;
grant update (topic_id, status, body) on nomad_contentflow.posts to authenticated;
grant select, insert, delete on nomad_contentflow.blog_members to authenticated;
grant update (role) on nomad_contentflow.blog_members to authenticated;
grant select, insert, delete on nomad_contentflow.publish_logs to authenticated;
grant update (post_id, blog_id, url, published_at) on nomad_contentflow.publish_logs to authenticated;
grant select, insert, delete on nomad_contentflow.reviews to authenticated;
grant update (post_id, verdict) on nomad_contentflow.reviews to authenticated;

commit;
