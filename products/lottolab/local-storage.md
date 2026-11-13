# LOTTO-LAB 로컬 저장소 규칙

원본: LOTTO-LAB packages/app-core (storage.ts·local-data.ts) · apps/mobile/src/platform · apps/desktop/src/platform. 정본 키 규칙: `nomad.<slug>.<entity>.v1` (slug = lottolab), 테마만 공통 `nomad.theme`(system·light·dark).

## 기존 → 새 키 (이름만 바꾼다. 값 형식은 레코드 JSON 그대로)
| 기존 | 새 | 저장 위치 |
|---|---|---|
| `ll:v1:ticket:<id>` | `nomad.lottolab.ticket.v1:<id>` | 모바일 Capacitor Preferences · 데스크톱 tauri store(`lotto-lab.json`) |
| `ll:v1:generated:<id>` | `nomad.lottolab.generated.v1:<id>` | 동일 |
| `ll:v1:settings:app` (age_confirmed_at·last_config) | `nomad.lottolab.settings.v1:app` | 동일 |
| `ll:v1:cache:<id>` (공개 회차·통계 캐시) | `nomad.lottolab.cache.v1:<id>` | 동일 (CACHE_VERSION 따로) |
| `ll:v1:pref:theme` (system·light·dark) | `nomad.theme` | 동일, 앱 공통 키 |
| `ll:v1:pref:fortune_secret` | `nomad.lottolab.fortune_secret.v1` | 동일(비밀 아님: 사주 입력 표시 선호. 토큰·키 아님) |
| 세션(Supabase Auth, 접두사 `lottolab_`) | 변경 없음 | 모바일 Keychain(whenUnlockedThisDeviceOnly)·Keystore 보안 저장소만 |
- 접두사 `ll:`·`ll:v1:` 일괄 삭제(clearAll)는 `nomad.lottolab.`·`nomad.theme`을 지우도록 바꾼다. 이전 키는 첫 실행 시 한 번 새 키로 옮긴 뒤 삭제(마이그레이션 `v1` 유지).
- 웹(apps/web)은 로컬 저장 없음. 필요해지면 localStorage에 `nomad.theme`만, 데이터는 IndexedDB `nomad.lottolab.<entity>.v1`.

## 오프라인 캐시 대상
| 대상 | 방향 | 비고 |
|---|---|---|
| draws_lotto · draws_pension · statistics_cache | 서버 → 로컬 캐시 | 무인증 앱도 anon 읽기, 서버가 정본 |
| generator_profiles · saved_tickets · fortune_profiles | 양방향 동기화 | `updated_at`·`deleted_at` 사용 |
| generated_batches · generated_numbers · user_consents | 서버 → 로컬(추가 전용) | 로컬 생성분은 로그인 후 업로드 |
| draw_checks | 서버 → 로컬 | 쓰기는 서버 판정만 |

## 동기화 규칙
- 마지막 쓰기 우선: 같은 id를 로컬·서버가 모두 고치면 `updated_at`이 큰 쪽. 삭제는 `deleted_at` 설정(소프트 삭제)이고, 더 늦은 수정이 있으면 되살아난다.
- 증분: 소유 키별 `updated_at > 마지막 동기화 시각`만 요청, 기본 인덱스 `(소유, updated_at)`. 시각은 서버 값(클라이언트 시계 신뢰 금지)을 저장.
- 구매 상태는 purchased → favorite 역전환 거부(PT422)이므로 충돌 시 purchased 유지.
- 멱등 키: 로컬에서 만든 티켓은 uuid `idempotency_key`를 붙여 올린다(재시도해도 중복 없음).

## 무인증(데스크톱·웹) 로컬 데이터 → 로그인 후 서버 업로드
1. 로그인 전 데이터는 로컬에만 둔다. 서버 쓰기 시도 금지.
2. 로그인 성공 직후 한 번: 로컬 `ticket`·`generated`·`generator_profiles`·`fortune_profile`을 읽어 소유자를 지금 로그인한 계정(org안은 그 사용자의 개인 조직)으로 `idempotency_key`/id 기준 upsert. 서버에 같은 id가 있으면 `updated_at` 비교(마지막 쓰기 우선).
3. 업로드는 사용자 동의 후 실행. user_consents는 로컬에서 만들지 않고 로그인 화면에서 새로 기록한다.
4. 성공한 레코드에 서버 `updated_at`을 기록. 실패분은 남겨 다음 로그인·동기화에 재시도.
5. 다른 계정으로 로그인하면 이전 계정 전용 키를 먼저 지우고(아래 로그아웃 목록) 업로드하지 않는다(계정 간 데이터 섞임 방지). 무인증 로컬 데이터는 이 경우에도 사용자에게 올릴지 묻는다.

## 비밀 · 로그아웃
- 토큰·API 키·세션은 localStorage·Preferences·tauri store 금지. 모바일은 Keychain/Keystore(`SecureStorage`)만. 데스크톱은 로그인 없음.
- 로그아웃 시 삭제: 보안 저장소 세션 전부(`lottolab_*`), `nomad.lottolab.ticket.v1:*` · `generated.v1:*` · `fortune_secret.v1` · `settings.v1:app`의 계정 종속 값(last_config). 남김: `nomad.theme`, `cache.v1:*`(공개 데이터), 19세 확인 기록은 기기 단위라 유지.
- 계정 삭제(account-delete) 시 위 전부 + 서버 CASCADE 파기.
