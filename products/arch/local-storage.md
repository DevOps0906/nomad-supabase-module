# Arch Studio 로컬 저장소 설계 (원본: 데스크톱 로컬 SQLite가 정본 B 분류, 클라우드는 사본·실행 기록)

키 규칙: `nomad.arch.<entity>.v1` (스키마가 바뀌면 `.v2`를 새로 만들고 `.v1`을 지운다). 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
원본 원칙 유지: 로컬 기능 권한(체험 만료·폴백)은 서명 라이선스 파일(`license_store`)만 믿는다. 로컬 DB·localStorage 값으로 플랜·역할을 판정하지 않는다.

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(토큰·API 키·PKCE verifier) |
|---|---|---|---|
| 데스크톱(tauri, 주 환경) | 로컬 SQLite(B 분류: 프로젝트 DesignModel·판정·시트·rule_pack_cache) + tauri store 파일 `arch.json`(클라우드 캐시) | tauri store `nomad.theme` · `nomad.arch.ui.v1` | **OS 키체인만**(세션·verifier). `localStorage` 0건(원본 9.2절) |
| 웹(계정 화면) | 캐시 없음(라이선스·기기·크레딧은 매번 서버) | localStorage `nomad.theme` · `nomad.arch.ui.v1` | localStorage·IndexedDB 금지. 세션은 쿠키(@supabase/ssr, httpOnly) |
| 앱(Capacitor) | 해당 없음(모바일 앱 없음) — 생기면 SQLite | Capacitor Preferences `nomad.theme` | 보안 저장소(Keychain/Keystore)만 |

## 오프라인 캐시 대상 (클라우드 → 데스크톱, 동기화 컬럼 updated_at)
| 키 | 테이블 | 비고 |
|---|---|---|
| `nomad.arch.drafting_profile.v1` | drafting_profiles | 오프라인이면 읽기 전용("온라인에서 저장합니다"). 저장은 upsert_drafting_profile |
| `nomad.arch.cloud_projects.v1` | cloud_projects | 목록·version 만. 스냅샷 파일은 서명 URL로 필요할 때 받는다 |
| `nomad.arch.rule_packs.v1` | eligible_rule_packs 결과 · rule_pack_changes | 팩 본문은 서명 매니페스트 검증 후 SQLite `rule_pack_cache` |
| `nomad.arch.cost_catalog.v1` | latest_cost_catalog 결과 | 단가표 1개(최신 자격본) |
| `nomad.arch.runs.v1` | renders·reviews·intake_runs·proposals(최근 30일 메타데이터) | 결과 이미지·PDF 는 캐시하지 않음(만료 90일, 서명 URL) |
| `nomad.arch.syncstate.v1` | — | 항목별 마지막 동기 시각 |
캐시하지 않음: license_orders·licenses·license_activations(계정 화면 온라인 조회, 권한은 라이선스 파일), runtime_config·builds(서버 전용), site_lookups.

## 동기화 규칙 (마지막 쓰기 우선, 클라우드 사본은 version 우선)
1. 내려받기: `updated_at > syncstate` 행을 `organization_id` 단위로 증분 조회(`*_org_updated_idx`). 실행 기록은 진행 중 행만 재조회.
2. 클라우드 사본 올리기: `save_cloud_project(local_id, name, path, expected_version)`. `AR041`이면 서버 사본을 받아 비교 화면을 띄운다(자동 덮어쓰기 금지). 로컬 SQLite가 정본이므로 오프라인 큐 `nomad.arch.outbox.v1`에는 "올릴 사본" 표시만 둔다.
3. 표제란은 마지막 쓰기 우선(서버 `updated_at`이 더 최신이면 서버 값).
4. AI 실행·대지 조회·주문은 큐에 넣지 않는다(크레딧 선차감·일일 상한 — 온라인에서만, request_id 멱등).

## 로그아웃 시 삭제 키
`nomad.arch.*`(A 분류 캐시 전부, `nomad.arch.ui.v1` 포함) + 키체인 세션·verifier. **`nomad.theme`은 유지**. 로컬 정본(SQLite B 분류 프로젝트)은 지우지 않고 사용자에게 묻는다(원본 9.2절). 조직을 전환하면 `nomad.arch.*`(ui 제외)를 지우고 새 조직으로 다시 받는다.
