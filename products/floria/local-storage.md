# Floria 로컬 저장소 설계 (신규 — 원본은 GNB 접기 상태 localStorage · 상담 초안 sessionStorage만)

키 규칙: `nomad.floria.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
원본 금지 패턴 유지: 역할·플랜·사이트 권한·사용자 id를 쿠키·localStorage에 쓰지 않는다(판정은 항상 서버 세션과 RPC 역할 검사).
대상 화면: 공개 사이트(방문자, 로그인 없음)와 운영 콘솔(초대받은 조직 멤버). 앱·데스크톱 클라이언트는 원본에 없음 — 아래 행은 생길 때의 규칙.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹(공개 사이트) | 저장 안 함. 상담 → 문의 초안 `nomad.floria.inquiry_hint.v1`만 **sessionStorage**(원본 `inquiry_hint`, 서버 미저장) | localStorage `nomad.theme` | **localStorage·sessionStorage 금지**. 방문자 AI 대화 쿠키는 서버 발급 httpOnly |
| 웹(콘솔) | IndexedDB `nomad.floria` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.floria.ui.v1`(GNB 접기) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `floria.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, deleted_at 없음)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.floria.sites.v1` | sites | 조직의 사이트 설정(표시용). 쓰기는 온라인 RPC만 |
| `nomad.floria.inquiries.v1` | inquiries | owner/admin/editor만(RLS, viewer는 0행). 개인정보 — 최근 30일·목록 필드만 보관, 로그아웃·조직 전환 시 즉시 삭제 |
| `nomad.floria.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ sites: ISO, inquiries: ISO }` |
캐시하지 않음: newsletter_subscribers(이메일 개인정보, 온라인 조회만), 요청 제한·감사 로그(nomad_core 공용 표, 클라이언트 접근 없음), 사이트 콘텐츠(정적 자산이 정본), AI 대화(서버 보관).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`sites_org_idx`·`inquiries_org_updated_idx`).
2. 하드 삭제(delete_inquiry·purge_expired)는 증분으로 내려오지 않으므로, 캐시 범위(30일) 안의 id 목록을 온라인 때 전체 재조회해 사라진 행을 지운다.
3. 올리기: 오프라인 쓰기 없음. 문의 상태 변경(`set_inquiry_status`)·사이트 설정은 온라인에서만 RPC로 보내고, 결과 행(서버 `updated_at`)으로 캐시를 덮는다. 같은 행을 두 사람이 바꾸면 서버 값(마지막 쓰기)이 이긴다.
4. 방문자 문의·구독은 큐에 쌓지 않는다(동의 버전·rate limit을 서버가 그 시점에 판정). 실패하면 폼 입력만 화면에 유지.

## 로그아웃 시 삭제 키
`nomad.floria.*`(전부, `nomad.floria.ui.v1` 포함) + IndexedDB `nomad.floria`. **`nomad.theme`은 유지**. sessionStorage `nomad.floria.inquiry_hint.v1`은 탭을 닫거나 문의 제출 시 삭제. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.floria.*`를 지우고 새 조직으로 다시 받는다.
