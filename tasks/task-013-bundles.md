# task-013 번들 빌더 · 구조별 검증 (단일 · 테넌트 · 모노레포)

- 위험도: 보통 · 근거: ~/.claude/plans/transient-singing-eich.md "task-013"·"산출물 배치" · products/<slug>/ · scripts/install-db.sh(core 선택 패턴 51~60행)

## 산출물
- `scripts/build-bundles.sh` → `bundles/` (생성물, git 제외 — .gitignore 한 줄)
  - core = `supabase/migrations`의 `*_nomad_core.sql`·`*_nomad_core_*.sql`(accounts 포함 — 모든 번들은 계정 확장 포함). 청사진 제품 파일·contentflow_example 제외.
  - `bundles/single/<slug>/supabase/migrations/`: core + products/<slug>/user/*(없으면 org/*) + app/*
  - `bundles/tenant/<slug>/…`: core + org/* + app/*
  - `bundles/monorepo/…`: core + 5개 제품 org/* + app/*
  - 제품 파일 번호는 core 뒤로 오도록 `20261201000<NN><MM>_<slug>_<원파일명>.sql` 형식으로 재명명(제품 순서 고정).
  - 각 번들 `supabase/config.snippet.toml`: `[api] schemas`에 nomad_<slug> 추가(private·nomad_core 제외) · `[auth.external.google|kakao]` 틀 · 필요한 확장(pgmq·pg_cron 등) 메모 · `README.md`(적용: 새 프로젝트에 `supabase link` → `supabase db push`, 워커 DB 역할 생성 방법, 앱 변경은 products/<slug>/existing.md)
- `tests/bundles.sh`: 각 번들을 임시 디렉터리(scratchpad 아님 → 저장소 밖 임시 경로)에 `npx supabase init` + 고유 project_id·포트(예 5920x대, 581xx와 겹치지 않게) → `supabase start`(필요한 서비스만) → `db reset` → 해당 제품 check_*.sql을 적용 상태 DB에 맞게 실행(마이그레이션 끼워넣기 없이) → `supabase stop --no-backup`. 모노레포는 5개 check 전부 + 스키마 5개 공존 확인. 11개 결과 표 출력.

## 완료 조건
- `bash scripts/build-bundles.sh` 재실행해도 같은 결과(멱등)
- `bash tests/bundles.sh` 11/11 통과(시간이 길면 백그라운드 실행 후 로그 `.nomad/logs/`)
- check_*.sql이 begin 안에서 임시 touch_updated_at을 정의하던 부분은 core에 함수가 있으므로 번들 검사에선 건너뛰게(필요 시 `create or replace` 회피만)
- codex-reviewer(code) + reviewer(contract: 각 레포 앱이 쓰는 테이블·RPC 이름과 번들 대조)

## 하지 않을 것
기존 supabase/migrations·install-db.sh 수정, products/ SQL 내용 변경(버그 발견 시 보고만), 실제 원격 프로젝트 적용
