# LOTTO-LAB 기존 DB 조사 (2026-11-13, scout)

| 앱 | 구성 | 서버 DB 접근 | 로컬 저장소 |
|---|---|---|---|
| apps/mobile | Capacitor + Vite React | Supabase Auth·PostgREST·Edge Function(anon) | Capacitor Preferences, 세션 Keychain/Keystore |
| apps/desktop | Tauri + Vite React | 공개 읽기만(app-core fetch) | tauri-plugin-store(lotto-lab.json) |
| apps/web | Next.js 랜딩·대기자 | Edge Function waitlist·waitlist-confirm(Turnstile) | 없음 |

| 마이그레이션 | 테이블 | 소유 | RLS |
|---|---|---|---|
| 20261112150000_waitlist | waitlist_signups · private.rate_limits | 없음 | ON, 정책 없음(service_role) |
| 20261112160000_waitlist_confirm | RPC waitlist_request_confirm·waitlist_confirm | — | — |
| 20261112170000_public_draws | ingestion_runs | 없음 | ON, 정책 없음 |
| 〃 | draws_lotto · draws_pension · statistics_cache | 없음 | SELECT 공개(anon) |
| 20261112180000_user_data | generator_profiles · generated_batches · saved_tickets | user_id | 본인 |
| 〃 | generated_numbers(batch 경유) · draw_checks(ticket 경유, 쓰기 service_role) | 간접 | 본인 |
| 20261113120000_fortune_profiles | fortune_profiles | user_id(PK) | 본인 CRUD |
| 20261113130000_user_consents | user_consents | user_id | 본인 SELECT/INSERT |
| 문서만(docs/05) | push_devices · subscription_accounts | user_id | 미구현 |

- enum `game_type`, private 스키마. Edge Function: waitlist·waitlist-confirm·account-delete(service_role).
- 인증: 이메일 OTP/비밀번호, 모바일만 로그인, 동의 기록 필수. 웹·데스크톱 무인증.
- 공용 모듈 겹침: 없음(subscription_accounts는 문서만, 결제 결정 Q3 대기). nomad_core 참조 없음.
- 판단: **개인형(user)** + 공개 데이터(추첨 결과)는 anon 읽기.
- 미확인: 원격 적용 여부, pg_cron 등록, push_devices 시점. 정본 문서: LOTTO-LAB/docs/05_DATA_MODEL.md
