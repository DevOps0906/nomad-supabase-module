# Microweb 로컬 저장소 설계 (신규 — 원본은 편집기 자동 저장·하객 음성 동의 쿠키 외 로컬 저장 규칙 없음)

키 규칙: `nomad.microweb.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
금지 패턴: 역할·플랜·studio 접근 여부·사용자 id·시안 토큰 원문을 localStorage 에 쓰지 않는다(판정은 서버 세션과 RPC). 청첩장 계좌·연락처(content)는 편집 중인 기기에만, 공유 기기 경고.
대상 화면: 공개 청첩장 `/i/[slug]`·쇼룸(방문자, 로그인 없음)과 `/studio` 콘솔(조직 멤버). 앱·데스크톱 클라이언트는 원본에 없음 — 아래 행은 생길 때의 규칙.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키) |
|---|---|---|---|
| 웹(공개 청첩장·쇼룸) | 저장 안 함. 방명록 작성 중 초안만 **sessionStorage** `nomad.microweb.guestbook_draft.v1`(이름·본문, 제출 시 삭제) | localStorage `nomad.theme` | **localStorage·sessionStorage 금지**. 하객 음성 동의는 서버 발급 httpOnly 쿠키, `voice_token`은 메모리만 |
| 웹(콘솔) | IndexedDB `nomad.microweb` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.microweb.ui.v1`(GNB 접기·목록 정렬) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 시안 링크 토큰은 발급 직후 화면에만 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `microweb.json` | tauri store `nomad.theme` | OS 키체인만 |

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, deleted_at 없음)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.microweb.sites.v1` | sites | 편집본(content 포함). 오프라인 편집은 `nomad.microweb.site_drafts.v1`에 따로 두고 온라인 때 PATCH |
| `nomad.microweb.site_drafts.v1` | (로컬 전용) | 사이트별 미전송 content + 기준 `updated_at`(base_updated_at) |
| `nomad.microweb.site_publications.v1` | site_publications | 게시 상태·버전 표시용(읽기 전용) |
| `nomad.microweb.site_assets.v1` | site_assets | 메타만(파일은 서명 URL로 그때그때) |
| `nomad.microweb.guestbook.v1` | guestbook_entries | 검토용 목록(ip_hash 는 애초에 안 내려옴). 최근 90일 |
| `nomad.microweb.orders.v1` | production_orders | owner/admin/editor 만(RLS). 고객명 포함 — 조직 전환·로그아웃 시 즉시 삭제 |
| `nomad.microweb.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ sites: ISO, ... }` |
캐시하지 않음: leads·rsvp_responses(연락처·참석 개인정보, 온라인 조회만), studio_access(판정은 서버), templates·portfolio_items(공개 RPC·CDN 캐시가 정본), 요청 제한·감사·voice_jobs(nomad_core, 클라이언트 접근 없음).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`sites_org_updated_idx`·`site_publications_org_updated_idx`·`site_assets_org_updated_idx`·`guestbook_entries_org_updated_idx`·`production_orders_org_updated_idx`).
2. 하드 삭제(사이트 cascade·방명록 삭제·정리 작업)는 증분으로 안 내려오므로, 온라인 때 캐시 범위의 id 목록을 전체 재조회해 사라진 행을 지운다.
3. 올리기: 콘텐츠 편집만 오프라인 큐(`site_drafts`). 보낼 때 서버 `updated_at`이 base 와 다르면 서버 값이 이긴다(마지막 쓰기 우선) — 로컬 초안은 "충돌 사본"으로 남겨 사용자가 다시 적용. 상태 전이·게시·주문·동의는 온라인 RPC 만.
4. 하객 쓰기(방명록·RSVP·견적)는 큐에 쌓지 않는다(한도·게시 상태를 서버가 그 시점에 판정). 실패하면 입력만 화면에 유지.

## 로그아웃 시 삭제 키
`nomad.microweb.*`(전부, `ui.v1`·`site_drafts.v1` 포함 — 미전송 초안이 있으면 로그아웃 전에 경고) + IndexedDB `nomad.microweb`. **`nomad.theme`은 유지**. sessionStorage `nomad.microweb.guestbook_draft.v1`은 탭 종료·제출 시 삭제. 앱·데스크톱은 보안 저장소 토큰도 삭제. 조직 전환 시 `nomad.microweb.*`를 지우고 새 조직으로 다시 받는다.
