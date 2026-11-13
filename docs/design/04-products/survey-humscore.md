# humscore 기존 DB 조사 (2026-11-13, scout)

| 구성 | 기술 | DB·로컬 저장소 |
|---|---|---|
| 웹 | Next.js(App Router), Vercel | Supabase public.* + localStorage `humscore.scores.v1`(로그인 시 동기화) |
| iOS/Android | Capacitor(appId com.nomadaifactory.humscore), 운영 Vercel 원격 로드 | 웹과 같음(native-shell은 오프라인 안내만) |
| 기타 로컬 키 | keysDraft · humscore.llm.v1(LLM 키, 서버 미전송) · preferences · instrument · record.source | IndexedDB 없음 |
| 워커 | transcription_jobs 큐 소비(Python, 레포 밖) | 미확인 |

| 마이그레이션(public, 5개) | 테이블 | 소유 | RLS |
|---|---|---|---|
| 20261019211413_scores | scores · transcription_jobs | user_id | 예(jobs 갱신은 service_role) |
| 20261019212458_scores_sync_hardening | scores.deleted_at, 트리거 3(시각 보정·LWW 가드·2000개 제한) | — | — |
| 20261102100000_share_links | share_links(score_id→scores) | owner_id | 예, anon은 RPC get_shared_score만 |
| 20261103100000_setlists | setlists(items jsonb) | user_id | 예 |
| 20261103100100_share_links_setlists | share_links.setlist_id(둘 중 하나만) | owner_id | 예 |

- 인증: Supabase Auth 이메일 OTP 기본 + Google OAuth, 쿠키 세션(@supabase/ssr).
- organization_id 없음 → **개인형(user)**. 공용 모듈 겹침 없음, nomad_core 참조 없음.
- 이 저장소 humscore 스키마(supabase/migrations/*_humscore.sql)와 차이는 설계 단계에서 대조.
- 미확인: 원격 적용 여부, 워커 위치, humscore/docs/05_DATA_MODEL.md·adr 미독.
