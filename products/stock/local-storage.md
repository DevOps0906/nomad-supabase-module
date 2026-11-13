# Stock Dashboard 로컬 저장소 설계 (신규 — 원본은 GNB 접기 상태만 localStorage)

키 규칙: `nomad.stock.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
원본 금지 패턴 유지: 역할·플랜·베타 여부·사용자 id를 쿠키·localStorage에 쓰지 않는다(판정은 항상 서버 `has_stock_access`·`session_context`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·증권사 키·계좌번호) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.stock` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.stock.ui.v1`(GNB 접기) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 증권사 키는 서버 Vault(provider_credentials)에만 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)에 세션 토큰만. 증권사 키는 기기에 두지 않음 |
| 데스크톱(tauri) | tauri store 파일 `stock.json` | tauri store `nomad.theme` | OS 키체인(세션 토큰만) |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, trade_notes는 deleted_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.stock.connections.v1` | broker_connections | 마스킹 계좌·상태만(원래 비밀 컬럼 없음) |
| `nomad.stock.holdings.v1` | holdings | 표시용. 실시간 시세는 캐시하지 않음(quote-relay SSE만, 재배포 제한) |
| `nomad.stock.trades.v1` | trades | 최근 history_days 범위만 |
| `nomad.stock.trade_notes.v1` | trade_notes | 오프라인 작성 가능(아래 올리기 규칙) |
| `nomad.stock.instruments.v1` | instruments | 전역 참조, 하루 1회 전체 갱신 |
| `nomad.stock.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ holdings: ISO, … }` |
캐시하지 않음: daily_prices(권한 없음), ai_reports·ai_report_items(온라인 조회), order_*·kill_switches(주문은 실시간 상태가 정답), consents, beta_*.

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 소유 단위(org안 `organization_id`, user안 `user_id`)로 증분 조회(`*_updated_idx`). trade_notes는 `deleted_at`이 찍힌 행도 내려오므로 클라이언트가 캐시에서 지운다.
2. 올리기: trade_notes 작성·수정·삭제만 오프라인 큐 `nomad.stock.outbox.v1`에 쌓고 온라인 때 보낸다. 서버 `updated_at`이 더 최신이면 서버 값이 이긴다.
3. 주문·킬 스위치·동의는 오프라인 큐에 넣지 않는다(항상 온라인, 실패 시 사용자에게 알림). 주문 미리보기는 `client_order_id`(멱등)를 화면에서 만들고 재전송해도 중복이 없다.

## 로그아웃 시 삭제 키
`nomad.stock.*`(전부, `nomad.stock.ui.v1` 포함) + IndexedDB `nomad.stock`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 세션 토큰도 삭제. org안에서 조직을 전환하면 `nomad.stock.*`를 지우고 새 조직으로 다시 받는다. 베타 회수·구독 끊김(잠김) 응답을 받으면 캐시 전체를 지운다.
