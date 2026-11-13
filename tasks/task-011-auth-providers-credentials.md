# task-011 공용 모듈 확장 — 소셜 로그인 · API 키(BYOK)

- 위험도: 높음(인증·비밀) · 근거: C:\Users\skydy\.claude\plans\transient-singing-eich.md "task-011" · supabase/migrations/20261114000100_nomad_core_accounts.sql 67~89행(가입 트리거) · task-006 org_*/멤버 함수 이원화 패턴

## 파일 (challenger REVISE 반영)
- `20261119000100_nomad_core_profile_prefs.sql`(core, 모든 설치): profiles.avatar_url(`^https://` check, 2048자 이하) · profiles.theme(system·light·dark, 기본 system, 본인만 갱신) · display_name 길이 제한(100자, 새 check는 not valid 후 validate) · `nomad_core.touch_updated_at()` 트리거 함수(grant 없음) · `nomad_core.oauth_states(state pk, provider, redirect_to, nonce, expires_at, created_at)` 서버 전용 + `consume_oauth_state(state)`(delete … returning, 만료면 null, 만료 행 정리) + expires_at 인덱스. redirect_to는 상대 경로만(`^/[^/]` check) — 열린 리다이렉트 방지.
- `20261119000150_nomad_core_accounts.sql`(accounts 계열 — 설치기가 `*_nomad_core_accounts.sql`로 --with-accounts일 때만 고름, install-db.sh 수정 불필요): 가입 트리거 함수 create or replace. 기존 이름 우선순위(accounts.sql 75~79)·익명 건너뛰기(72)·on conflict(82) 유지, 뒤에 full_name·nickname, 사진 avatar_url·picture(https만, 아니면 null). 익명→정식 전환(update에서 is_anonymous true→false) 트리거 추가해 같은 프로비저닝.
- `20261119000200_nomad_core_api_credentials.sql`(core): api_providers 시드(youtube_data·openai·anthropic·google_gemini — 제품 조사에서 나온 제공자 추가) · provider_credentials · set/list/revoke(authenticated, owner·admin; list는 멤버) · `org_provider_secret`(service_role 전용, 사용 시 last_used_at 갱신). **public 래퍼**(accounts.sql 348~403 패턴): `public.nomad_set_provider_credential`·`nomad_list_provider_credentials`·`nomad_revoke_provider_credential`(authenticated) · `public.nomad_org_provider_secret`(service_role만, Edge Function용). revoke·같은 label 교체 시 **vault.secrets 행 삭제**. vault 이름 `nomad:<org>:<provider>:<label>:<credential id>`.
- `supabase/config.toml`: `[auth.external.google]`·`[auth.external.kakao]` 틀(enabled=false, secret=env(...)).

## 계정 연결 원칙 (INTEGRATION 문서에 기록)
- Supabase 기본(검증된 같은 이메일 자동 연결)은 유지. 카카오 무이메일·미검증은 연결되지 않음.
- 네이버 중계 Edge Function은 네이버 사용자 id로만 사용자를 찾고 **이메일로 기존 계정을 찾지 않는다**(탈취 방지). 비밀이 RPC 인자로 지나가므로 운영에서 문장 로그(log_statement) 끄기를 문서화.

## 완료 조건
- credentials.sql에 "service_role이 vault.decrypted_secrets를 직접 select할 수 있는가" 실측 결과를 기록(가능하면 문서에 '서버 전체 신뢰' 명시), revoke 후 vault 행 없음, 교체 시 이전 행 삭제, public 래퍼 grant 검사, 익명→정식 전환 프로비저닝, 잘못된 avatar(javascript:) 무시, oauth_states 1회 소비·만료·외부 redirect 거부
- db reset + 기존 테스트 5종 통과, `tests/accounts.sql` 보강(구글·카카오 무이메일·네이버 메타데이터 가입 → profile 이름·사진), 새 `tests/credentials.sql`(viewer·비멤버 등록 거부, authenticated 원문 접근 불가(테이블·vault 직접), service_role 복호화, revoke 후 null, last4 일치), accounts.sql에 theme 기본 system·잘못된 값 거부·타인 theme 갱신 거부
- codex-reviewer(code) + reviewer(security)

## 하지 않을 것
Edge Function 코드, 실제 클라이언트 id·비밀값, 기존 마이그레이션 수정
