-- user안 업그레이드 검사: 0001~0004 적용 → (이 파일 앞부분) 0003 takedown_video로 기존 감사 기록 생성 → 0005 이후 적용 → (뒷부분) 백필·KF451 확인 → rollback.
-- run_check.sh upgrade-user가 '-- @@apply-0005@@' 줄 앞뒤로 나눠 끼운다(단독 실행 금지).
insert into auth.users (id, email, aud, role) values ('dddddddd-0000-0000-0000-00000000000d', 'd-up@example.invalid', 'authenticated', 'authenticated');
insert into nomad_knowflow.projects (id, user_id, name) values
  ('90000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-00000000000d', '업그레이드'),
  ('90000000-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-00000000000d', '업그레이드 2');
insert into nomad_knowflow.sources (id, project_id, user_id, source_type, title, original_url, video_id, status)
values ('91000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-00000000000d', 'youtube', '옛 영상',
        'https://www.youtube.com/watch?v=oldvideo001', 'oldvideo001', 'completed');
select public.t_role('service_role');
select nomad_knowflow.takedown_video('oldvideo001', '옛 권리자 요청');
reset role;
select public.t_eq((select count(*) from nomad_core.audit_log where action = 'knowflow.rights_takedown' and target_id = 'oldvideo001'), 1, '[user 업그레이드] 0003 takedown 감사 기록 1건');
-- @@apply-0005@@
select public.t_eq((select count(*) from nomad_knowflow_private.video_takedowns where video_id = 'oldvideo001' and reason = '옛 권리자 요청'), 1, '[user 업그레이드] 0003 takedown 기록이 차단 목록으로 이관');
select public.t_role('service_role');
select public.t_expect($q$select nomad_knowflow.register_youtube_source('dddddddd-0000-0000-0000-00000000000d', '90000000-0000-0000-0000-000000000002',
  'oldvideo001', '재등록', '채널', 60, 'up-k', 'h')$q$, 'KF451');
reset role;
select 'USER UPGRADE CHECK PASSED' as result;
rollback;
