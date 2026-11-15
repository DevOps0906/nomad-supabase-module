# sceneflow 로컬 저장소 설계 (신규 — 원본에 로컬 저장 설계 없음)

키 규칙: `nomad.sceneflow.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
역할·플랜·조직 id·기능 잠김 여부·plan_limits 수치는 로컬에 저장하지 않는다(항상 서버 `has_access`·`has_feature`·`nomad_dashboard_features`).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키·채널 OAuth·고객 승인 토큰) |
|---|---|---|---|
| 웹 | IndexedDB `nomad.sceneflow` (객체 저장소 = entity) | localStorage `nomad.theme` · `nomad.sceneflow.ui.v1`(편집기 패널·타임라인 확대·미리보기 화면비) | **localStorage·IndexedDB 금지**. 세션은 쿠키(@supabase/ssr, httpOnly). 채널 토큰은 서버 provider_credentials 에만 |
| 앱(Capacitor) | SQLite 또는 IndexedDB | Capacitor Preferences `nomad.theme` · `nomad.sceneflow.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | tauri store 파일 `sceneflow.json` | tauri store `nomad.theme` | OS 키체인만 |
영상·음원·이미지 파일은 로컬 캐시하지 않는다(`sceneflow-media` 서명 URL 로만, 최대 5GB).

## 오프라인 캐시 대상 (동기화 컬럼: updated_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.sceneflow.storyboards.v1` | storyboards | `revision`·`status`·`deleted_at` 함께 보관. rendering·archived 는 오프라인 편집 금지(VD020·VD005) |
| `nomad.sceneflow.scenes.v1` | scenes | `revision` 함께 보관. 쓰기는 save_scene 등 RPC 만 |
| `nomad.sceneflow.edit_presets.v1` | edit_presets | 편집 프리셋 |
| `nomad.sceneflow.lexicon.v1` | pronunciation_lexicon | 발음 사전(조직당 2,000개) |
| `nomad.sceneflow.workflows.v1` | workflows | 소프트 삭제 deleted_at |
| `nomad.sceneflow.library.v1` | music_library · playlists · playlist_items | Track F. 소프트 삭제 deleted_at(라이브러리·플리) |
| `nomad.sceneflow.clients.v1` | clients | agency. 소프트 삭제 deleted_at |
| `nomad.sceneflow.linkinbio.v1` | linkinbio_profiles · linkinbio_items · landing_pages | 편집 화면용. 공개 페이지는 캐시 안 함 |
| `nomad.sceneflow.syncstate.v1` | — | 테이블별 마지막 동기 시각 `{ storyboards: ISO, … }` |
캐시하지 않음: channels·uploads·outputs·storyboard_cuts·storyboard_snapshots·scene_assets·edit_plans·client_reviews(서버 상태가 계속 바뀜 — 온라인 조회), trend_videos·radar_reports(조회 시점 기준), 크레딧·잡(core RPC).

## 동기화 규칙 (마지막 쓰기 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_sync_idx`). 소프트 삭제 표는 `deleted_at` 이 채워진 행을 받으면 캐시에서 지운다. 하드 삭제 표(edit_presets·pronunciation_lexicon·playlist_items·linkinbio_items·scenes)는 목록 화면을 열 때 id 목록 전체를 비교해 지운다.
2. 올리기: 컬럼 grant 가 있는 콘텐츠 편집(storyboards 제목·주제·렌더 설정, edit_presets, pronunciation_lexicon, workflows, music_library, playlists·playlist_items(draft 만), clients, linkinbio)만 오프라인 큐 `nomad.sceneflow.outbox.v1`에 쌓는다(새 행은 클라이언트 uuid `id`). 서버 `updated_at`이 더 최신이면 서버 값이 이긴다.
3. 장면 편집(save_scene·reorder_scenes·add_scene·delete_scene)은 `revision` 을 함께 보내고, VD409 를 받으면 서버 값을 다시 받아 사용자에게 병합을 묻는다(자동 덮어쓰기 금지).
4. 렌더·업로드·업로드 취소·컴플라이언스 확인·고객 승인·채널 연결·해제·위험 동의·AI 편집안 적용·Suno 생성은 오프라인 큐에 넣지 않는다(크레딧·외부 게시 — 온라인에서 서버가 request_id 멱등 키로 한 번만).

## 로그아웃 시 삭제 키
`nomad.sceneflow.*`(전부, `nomad.sceneflow.ui.v1` 포함) + IndexedDB `nomad.sceneflow`. **`nomad.theme`은 유지**. 앱·데스크톱은 보안 저장소의 토큰도 삭제. 조직을 전환하면 `nomad.sceneflow.*`를 지우고 새 조직으로 다시 받는다.
