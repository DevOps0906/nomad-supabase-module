-- KNOWFLOW AI · user안 Storage: 비공개 버킷 knowflow-sources(PDF 50MB). 경로 첫 폴더 = user_id.
-- UPDATE·DELETE 정책 없음(삭제는 서버가 service_role로). 원본 버킷명 sources → knowflow-sources(다른 제품과 섞이지 않게).
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('knowflow-sources', 'knowflow-sources', false, 52428800, array['application/pdf'])
on conflict (id) do nothing;

create policy knowflow_sources_objects_select_own on storage.objects for select to authenticated
  using (bucket_id = 'knowflow-sources' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy knowflow_sources_objects_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'knowflow-sources' and (storage.foldername(name))[1] = (select auth.uid())::text);

commit;
