# news 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.news.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할(staff_role)·플랜·조직 id·구독 끊김 여부·plan_limits 수치·독자 멤버십 상태는 로컬에 저장하지 않는다(항상 서버 `staff_role`·`nomad_core.has_feature`·`read_article.locked`).
독자 사이트(공개 페이지)는 CDN·ISR 캐시를 쓰고 브라우저 로컬 저장은 하지 않는다(미터형 페이월 카운트는 서버 쿠키, 원본 05장 7절).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(세션·초대 토큰·뉴스레터 토큰·가맹 키) |
|---|---|---|---|
| 웹(편집국) | IndexedDB `nomad.news` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.news.ui.v1`(편집기 패널·목록 필터·미리보기 기기) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 가맹 키는 서버 provider_credentials 에만, 초대·뉴스레터 토큰은 링크로만 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.news.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `news.json` | tauri store `nomad.theme` | OS 키체인만 |
사진·지면 PDF·첨부는 로컬 캐시하지 않는다(서명 URL 로만). 제보·정정 청구 첨부와 독자 개인정보(readers.email)는 캐시 금지.

## 오프라인 캐시 대상 (동기화 컬럼: updated_at, 편집국만)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.news.drafts.v1` | articles(status draft, 내 기사) · article_regions · article_tags | 본문 초안. 쓰기는 `save_article`(autosave) RPC 만 |
| `nomad.news.taxonomy.v1` | sections · regions · tags | 기사 편집기 선택지(읽기 전용) |
| `nomad.news.media.v1` | media_assets(메타만) | 대체텍스트·출처. 파일은 서명 URL |
| `nomad.news.layouts.v1` | home_layouts(draft) | 홈 편집 초안 |
| `nomad.news.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ drafts: ISO, … }` |
캐시하지 않음: 게시·예약·승인 상태 기사(워크플로가 서버에서 바뀜), readers·memberships·donations·comments·comment_reports·tips·correction_requests(개인정보·법정 기한 — 온라인 조회), 광고·뉴스레터 회차·통계, newspapers(매체정보는 서버 정본).

## 동기화 규칙 (마지막 쓰기 우선, 단 게시 후 수정은 서버 판정)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회. 분류는 `is_active=false` 를 받으면 선택지에서 숨긴다(삭제 없음).
2. 올리기: 내 draft 기사·홈 편집 draft 만 오프라인 큐 `nomad.news.outbox.v1`에 쌓는다(새 행은 서버가 id 를 만든다 — 큐에는 임시 키만). 서버 `updated_at`이 더 최신이면 서버 값이 이기고 사용자에게 병합을 묻는다.
3. 제출·승인·게시·예약·게시 중단·정정문·댓글 처리·독자 차단·초대·결제·뉴스레터 발송은 오프라인 큐에 넣지 않는다(워크플로·법정 기록 — 온라인에서 서버가 한 번만). 구독이 끊긴 조직(NW014)은 큐를 비우지 말고 보관만 한다.

## 로그아웃 시 삭제 키
`nomad.news.*`(전부, `nomad.news.ui.v1` 포함) + IndexedDB `nomad.news`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 신문사(조직)를 전환하면 `nomad.news.*`를 지우고 새 조직으로 다시 받는다.
