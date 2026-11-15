# Shopping-Shorts-Maker 기존 DB 조사 (2026-11-13, scout)

| 항목 | 내용 |
|---|---|
| 앱/웹 | web(Next.js 16, Supabase anon 클라이언트) · worker(Python, psycopg로 `worker_login` 직접, `private.job_*` 함수만) · desktop(Tauri 셸, DB 없음). extension·mobile 폴더 없음, 로컬 저장소 없음 |
| DB | 셀프 호스팅 Supabase 1개, 마이그레이션 51개(20261112160000~20261113140000) |
| public 테이블(~28) | categories, trend_items, user_profiles, accounts, projects, project_events, topics, sources, scripts, voice_takes, renders, chat_messages, extension_connections, jobs, credit_ledger, publications, video_metrics, policy_checks, affiliate_links, bio_pages, bio_items, link_clicks, api_keys, chat_proposals, oauth_states, channel_slot_events, publication_upload_sessions, youtube_upload_quota |
| private 테이블 | channel_quotas, click_salts, metrics_runs (+ private 헬퍼 함수) |
| storage | 버킷 `sources`(비공개, 200MiB) |
| 소유 | user_id 직접(user_profiles·accounts·projects·extension_connections·api_keys) + project_id→projects.user_id 간접. organization_id 없음 → **개인형** |
| RLS | 전부 활성 |
| 인증 | 이메일/비밀번호(signUp·signInWithPassword) |
| 공용 모듈 겹침 | credit_ledger·jobs(크레딧 차감)만. 조직·멤버십·플랜·구독·결제 없음 |
| nomad_core 참조 | 없음. commerce·sceneflow 키 없음 |

미확인: publication_upload_sessions·youtube_upload_quota 소유 컬럼, 정답 대조(supabase/tests/rls_core.sql · apps/web/src/types/db.ts).
