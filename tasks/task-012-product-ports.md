# task-012 최우선 5개 제품 DB 변환 (실제 레포 기준)

- 위험도: 높음(RLS·노출 스키마) · 근거: C:\Users\skydy\.claude\plans\transient-singing-eich.md "task-012" · docs/design/04-products/survey-<slug>.md · docs/design/01-architecture/tenancy-models.md
- slug ↔ 레포: humscore↔D:\WorkSpace\DEV\humscore · shorts↔Shopping-Shorts-Maker · contentflow↔ContentFlow-AI-V2.0 · lottolab↔LOTTO-LAB · knowflow↔KNOWFLOW-AI

## 산출물 (products/<slug>/만)
- `existing.md`: 레포 기존 테이블·함수·버킷 전부 분류표 — 열: 원래 이름 | 분류(대체:nomad_core.X / 이관 / 삭제) | 새 이름 | 사용처(웹·앱·워커·서버) | 소유 컬럼 user→org 변화
- `user/0001_<slug>.sql`(+필요 시 0002_storage.sql): 단일안. 소유 user_id, RLS `auth.uid() = user_id`. ContentFlow는 생략(조직형 전용).
- `org/0001_<slug>.sql`(+storage): 테넌트안. 소유 organization_id → nomad_core.organizations, RLS `nomad_core.organization_role(organization_id) is not null`(쓰기는 역할 조건). 개인 데이터는 1인 조직으로.
- `app/*.sql`: 앱 전용 테이블이 문서에만 있으면 여기에(예: lottolab push_devices). 없으면 생략.

## 변환 규칙
- 스키마 `nomad_<slug>`(API 노출 대상) · 내부용은 `nomad_<slug>_private`(노출 안 함). public 사용 금지.
- 자체 profiles·조직·멤버십·초대·플랜 → nomad_core 참조로 대체하고 만들지 않는다. 한도 컬럼은 existing.md에 plan_limits 키로 적는다(수치 시드 안 함).
- 큐·크레딧·사용량은 제품 스키마에 남긴다. 레포의 RPC는 이름 유지, 본문은 새 스키마·소유로 고친다.
- `grant usage on schema nomad_<slug> to anon, authenticated, service_role` + 테이블별 필요한 권한만. anon은 레포가 공개 읽기한 것만.
- security definer: `set search_path = ''` + 스키마 한정 이름. 모든 테이블 RLS + 정책 컬럼 인덱스 + 코멘트 한 줄.
- 파일은 `begin; … commit;`. nomad_core 함수만 참조(다른 제품 스키마 참조 금지).


## 추가 요구 (2026-11-13 사용자): 로컬 저장소 · 라이트/다크
- 모든 제품에 `local-storage.md`: 키 규칙 `nomad.<slug>.<entity>.v1`, 웹(localStorage/IndexedDB)·앱(Capacitor Preferences·보안 저장소)·데스크톱(tauri store)별 저장 위치, 오프라인 캐시 대상 테이블, 동기화 규칙(마지막 쓰기 우선), 비밀(토큰·API 키)은 localStorage 금지(앱 보안 저장소만), 로그아웃 시 삭제 키. 테마 키 `nomad.theme`(system·light·dark)는 공통.
- 동기화 대상 테이블은 `updated_at timestamptz not null default now()` + `deleted_at timestamptz`(소프트 삭제) + `nomad_core.touch_updated_at()` 트리거(task-011이 core `20261119000100_nomad_core_profile_prefs.sql`에 추가 — 그 전에는 파일 안에서 `nomad_core.touch_updated_at`을 호출만 하고 검사 시 begin 안에서 임시 정의). 증분 동기화용 `(소유 컬럼, updated_at)` 인덱스.

## 완료 조건
- 로컬 DB(`docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1`)에서 `begin;` → (청사진 같은 이름이 있으면 `drop schema nomad_<slug> cascade;`) → user안 적용 → 합성 사용자 2명 교차 접근 거부 확인 → `rollback;`. org안도 같은 방식으로 조직 2곳 교차 거부 확인. 사용한 검사 SQL은 `products/<slug>/check_user.sql`·`check_org.sql`로 남긴다.
- 레포 앱 코드가 쓰는 테이블·RPC 이름이 existing.md에 모두 있음.

## 하지 않을 것
레포 파일 수정, supabase/migrations·tests 수정, 수치 시드, 데이터 이전, 다른 제품 디렉터리 쓰기
