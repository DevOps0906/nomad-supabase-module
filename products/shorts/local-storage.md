# shorts 로컬 저장소 규칙

현재 레포 조사 결과(2026-11-13): 웹은 `localStorage`·`sessionStorage`·IndexedDB를 쓰지 않고, 데스크톱(Tauri 2)은 창·저장 플러그인 없이 `opener` 플러그인만 있는 셸이며, 워커(Python)는 로컬 저장소가 없다. 아래는 **앞으로 로컬에 둘 것의 규칙**이다. 새 키는 이 문서에 먼저 적는다.

## 1. 키 규칙
- 형식 `nomad.shorts.<entity>.v1` (스키마가 바뀌면 `v2`를 새로 만들고 `v1`을 지운다). 공통 키 `nomad.theme`(값 `system`·`light`·`dark`)만 제품 접두가 없다.
- 현재 정의된 키

| 키 | 위치 | 내용 | 비고 |
|---|---|---|---|
| `nomad.theme` | 웹 localStorage · 데스크톱 웹뷰 localStorage | system·light·dark | 로그아웃해도 유지(개인 표시 설정, 비밀 아님) |
| `nomad.shorts.settings.v1` | 웹 localStorage | `user_settings` 행의 캐시(기본 톤·언어·자막·길이·알림) | 동기화 대상. 로그아웃 시 삭제 |

## 2. 플랫폼별 저장 위치
| 플랫폼 | 저장 위치 | 쓰는 것 |
|---|---|---|
| 웹(Next.js 16) | 로그인 세션은 `@supabase/ssr` 쿠키(앱이 직접 만지지 않음), 설정 캐시·테마는 localStorage | 위 표의 2개 키. 대용량·바이너리는 두지 않는다(영상·음성은 서버 버킷 서명 URL) |
| 데스크톱(Tauri 셸) | 현재 없음. 필요해지면 웹뷰 localStorage는 웹과 같은 키, 토큰 등 비밀은 OS 보안 저장소(keyring) 또는 `tauri-plugin-store`가 아닌 보안 플러그인 | 비밀은 `tauri-plugin-store` 평문 파일 금지 |
| 워커(Python) | 로컬 저장소 없음. 영상·음성 임시 파일은 작업 끝에 삭제하고 정본은 버킷 | DB 접속 정보는 환경 변수만 |
| 크롬 확장 | 이 제품의 로컬 저장소 규칙 범위 밖(확장 토큰은 `extension_connections` 해시로 서버가 관리) | 토큰 원문은 확장의 보안 저장소만 |

## 3. 오프라인 캐시 대상 테이블과 동기화
- 캐시 대상은 **`nomad_shorts.user_settings` 하나**다. 컬럼 `updated_at timestamptz not null default now()` · `deleted_at timestamptz` · `nomad_core.touch_updated_at()` 트리거 · `(user_id, updated_at)` 인덱스가 이미 있다.
- 나머지 테이블(projects·scripts·jobs·credit_ledger 등)은 캐시하지 않는다: 단계 승인·크레딧 예약·발행이 서버 RPC의 상태 전이가 정본이라 오프라인 편집이 의미 없고, 소프트 삭제를 넣으면 RPC 수십 개의 조건이 바뀐다. 목록 화면의 일시 캐시는 메모리(React Query)로만 둔다.
- 동기화 규칙: **마지막 쓰기 우선**. 앱 시작 시 `updated_at > <마지막 동기화 시각>` 행만 읽어 로컬과 `updated_at`을 비교해 더 새로운 쪽을 채택하고, 로컬이 새로우면 upsert한다. `deleted_at`이 있으면 로컬에서도 지운다.
- org안에서도 `user_settings`는 사용자 소유(`user_id`)라 조직 전환과 무관하다. org안의 나머지 데이터는 `organization_id`가 키에 들어가야 하는 경우(`nomad.shorts.<entity>.<orgId>.v1`)에만 캐시한다(현재 해당 없음).

## 4. 비밀 · 로그아웃
- 토큰·API 키(Gemini 등)·OAuth 코드·`service_role` 키는 localStorage·IndexedDB에 두지 않는다. 사용자 키는 서버에서 vault에 두고 화면에는 `api_keys.last4`만 보인다.
- 로그아웃 시 삭제: `nomad.shorts.*` 전부(현재 `nomad.shorts.settings.v1`). 유지: `nomad.theme`.
- 계정 전환(다른 user 로그인) 시에도 `nomad.shorts.*`를 먼저 지운다.
