# KNOWFLOW-AI 기존 DB 조사 (2026-11-13, scout)

| 위치 | 역할 | DB 접근 | 로컬 저장소 |
|---|---|---|---|
| apps/web | Next.js 16 UI·API | @supabase/ssr. projects·sources 직접 select + RPC(create/update/delete_project, register_pdf_source, register_youtube_source, get_source_chunks, delete_sources, retry_source, list_project_jobs, consume_auth_rate_limit) · Storage `sources` | 없음(persistSession:false) |
| apps/worker | Node 큐 처리(추출·청킹·임베딩) | pg.Pool, SET ROLE service_role, claim_job·complete_job RPC + 직접 SQL | 미확인 |

| 테이블(public, 마이그레이션 17개) | 소유 | RLS |
|---|---|---|
| plans(beta 1종, 수량 한도 컬럼) | 없음 | authenticated 읽기 |
| profiles(id=auth.users.id, handle_new_user 트리거) | 본인 | 본인 |
| user_quotas(월 사용량, RPC로만 갱신) | user_id | 본인 읽기 |
| projects · sources · conversations · reports · processing_jobs · source_moments | user_id | 본인 읽기 |
| source_chunks(project 경유) | 간접 | deny_all |
| messages · report_citations | 간접 | 본인 읽기 |
| usage_events(estimated_cost 원) | user_id(nullable) | 본인 읽기 |
| idempotency_keys · auth_rate_limits | — | deny_all |

- Storage 버킷 `sources`(private, PDF, 50MB), 본인 폴더 select·insert만.
- 인증: 이메일·비밀번호만. 소셜 로그인 없음.
- **개인형(user)**. 겹침: plans·user_quotas → nomad_core.plans·plan_limits. 조직·구독·크레딧·결제 없음. nomad_core 참조 없음(nomad-modules.json은 blueprint 6개 문서만).
- 이 저장소 청사진 nomad_knowflow(조직형, spaces·chunks vector(1536))와 구조가 다르다 — 앱 기준으로 새로 만든다.
- 미확인: docs(PRD·05_DATA_MODEL), worker 로컬 파일, messages 정책식.
