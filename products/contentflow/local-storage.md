# ContentFlow 로컬 저장소 규칙 (org안)

키 규칙 `nomad.contentflow.<entity>.v1`. 테마만 공통 키 `nomad.theme`(`system`|`light`|`dark`, 로그인 후 `nomad_core.profiles.theme`과 맞춤).

## 기존 → 새 키
| 영역 | 기존 | 새 규칙 | 비고 |
|---|---|---|---|
| 웹 localStorage | `contentflow.articles.v2` (v1은 읽기 전용 레거시) | `nomad.contentflow.articles.v1` | 로컬 모드(Supabase 미설정) 글. 로그인 시 서버로 이전 후 삭제 |
| 웹 localStorage | `contentflow.keywords.v1` | `nomad.contentflow.keywords.v1` | |
| 웹 localStorage | `contentflow.revenue.v1` | `nomad.contentflow.revenue.v1` | 서버 이전은 row_key 멱등 insert |
| 웹 localStorage | `contentflow.ai.choice.v1` | `nomad.contentflow.ai-choice.v1` | 모델 선택만(키 아님). 서버 동기화 안 함 |
| 웹 localStorage | (없음) | `nomad.theme` | 즉시 적용 |
| 모바일(Capacitor) 보안 저장소 | `cf.session` (Keystore/Keychain, @aparajita/capacitor-secure-storage) | `nomad.contentflow.session` | 토큰은 여기만. Preferences·localStorage 금지 |
| 웹 세션(shell-bridge) | 메모리(새로고침 시 재로그인) | 변경 없음 | 토큰을 localStorage에 두지 않음 |
| 데스크톱(Tauri) | WebView localStorage(고정 포트 34110 origin). tauri store 사용 없음 | 웹과 같은 키 | 포트가 바뀌면 로컬 데이터가 사라지므로 고정 유지 |

이행: 앱이 처음 뜰 때 기존 키가 있으면 새 키로 복사 후 기존 키를 지운다(레거시 v1 포함).

## 저장 위치
- 웹·데스크톱: localStorage(작은 JSON). 글이 많아 용량 한계에 닿으면 IndexedDB 검토(팀장 확인).
- 모바일: 데이터는 서버 API 경유(직접 저장 없음), 토큰만 보안 저장소.

## 오프라인 캐시 · 동기화
- 캐시 대상 테이블: `articles`, `keywords`, `blogs`(읽기·쓰기), `revenue_rows`(읽기 캐시만, 쓰기는 서버 API).
- 동기화 테이블(`articles`·`keywords`·`blogs`)은 `updated_at`·`deleted_at`(소프트 삭제)·`nomad_core.touch_updated_at()` 트리거·`(organization_id, updated_at)` 인덱스를 가진다(org/0001에 반영).
- 증분 조회: `updated_at > 마지막 동기화 시각`(삭제 표시 포함). 충돌은 마지막 쓰기 우선(서버 `updated_at` 기준). 글의 상태·승인은 서버 트리거 규칙이 우선하며 거부되면 로컬 변경을 버린다.

## 무인증(로컬 모드) → 로그인 후 서버 업로드
1. 로그인 후 조직을 고르고, 로컬 키가 있으면 1회 이전을 제안한다(자동 덮어쓰기 금지).
2. 글은 planning 단계로만 insert(승인·발행 상태는 서버 트리거만 만든다), keywords는 중복 키 건너뛰기, revenue는 row_key 멱등.
3. 성공한 항목만 로컬에서 삭제, 실패는 남기고 재시도. 서버 값과 충돌하면 서버를 유지.
4. 한도 초과(블로그 수 등)는 거부 메시지를 보이고 로컬 데이터는 보존한다.

## 비밀 · 로그아웃
- 토큰·API 키·WordPress 비밀번호는 localStorage 금지(모바일 보안 저장소만, 웹은 메모리).
- 로그아웃 시 삭제: `nomad.contentflow.session`, 서버에서 내려받은 캐시(articles·keywords·revenue·blogs 서버 사본). 유지: `nomad.theme`, 아직 이전하지 않은 로컬 모드 작성분(삭제하지 않고 안내).
