-- org안 업그레이드 검사: 0001~0004 적용 → (이 파일 앞부분) 0003 takedown_video로 기존 감사 기록 생성 → 0005 이후 적용 → (뒷부분) 백필·KF451 확인 → rollback.
-- run_check.sh upgrade-org가 '-- @@apply-0005@@' 줄 앞뒤로 나눠 끼운다(단독 실행 금지).
insert into nomad_core.organizations (id, name) values ('09090909-0000-0000-0000-000000000009', '업그레이드 조직');
insert into nomad_knowflow.projects (id, organization_id, name) values
  ('90000000-0000-0000-0000-000000000001', '09090909-0000-0000-0000-000000000009', '업그레이드'),
  ('90000000-0000-0000-0000-000000000002', '09090909-0000-0000-0000-000000000009', '업그레이드 2');
insert into nomad_knowflow.sources (id, project_id, organization_id, source_type, title, original_url, video_id, status)
values ('91000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', '09090909-0000-0000-0000-000000000009', 'youtube', '옛 영상',
        'https://www.youtube.com/watch?v=oldvideo001', 'oldvideo001', 'completed');
select public.t_role('service_role');
select nomad_knowflow.takedown_video('oldvideo001', '옛 권리자 요청');
reset role;
select public.t_eq((select count(*) from nomad_core.audit_log where action = 'knowflow.rights_takedown' and target_id = 'oldvideo001'), 1, '[org 업그레이드] 0003 takedown 감사 기록 1건');
-- @@apply-0005@@
select public.t_eq((select count(*) from nomad_knowflow_private.video_takedowns where video_id = 'oldvideo001' and reason = '옛 권리자 요청'), 1, '[org 업그레이드] 0003 takedown 기록이 차단 목록으로 이관');
select public.t_role('service_role');
select public.t_expect($q$select nomad_knowflow.register_youtube_source('09090909-0000-0000-0000-000000000009', '90000000-0000-0000-0000-000000000002',
  'oldvideo001', '재등록', '채널', 60, 'up-k', 'h')$q$, 'KF451');
reset role;
select 'ORG UPGRADE CHECK PASSED' as result;
rollback;
