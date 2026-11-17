# task-033 로컬 Studio 환경 키트 (위험도 보통)

근거: 계획 "로컬 Studio 환경 키트 ①"(사용자 요청 2026-11-18: KNOWFLOW-AI의 로컬 Studio 구성을 모듈로, 다른 저장소에 한 줄로 적용).

## 산출물
- `local/ports.yaml`(제품별 10단위 포트 블록, 고정: module 58120 · knowflow 56520) · `local/config.toml.tmpl` · `local/local-dev.md.tmpl` · `local/render.sh`
- `scripts/install-local.sh <대상> --product <slug>... [--site-url URL] [--check] [--force]`: config.toml·docs/runbooks/local-dev.md 생성. 표식 없는 기존 파일은 보존(제안본 `*.nomad.*`, exit 2). 종료 코드 0/1/2/64. 잠금에 `# local <slug> <포트> <해시>`.
- `scripts/install-db.sh`: `--product`가 있으면 복사 뒤 install-local 실행(`--no-local`로 끔), 제품이 있으면 migrations 폴더 자동 생성(제품 없으면 기존처럼 supabase init 요구), `--check`는 로컬 키트를 보지 않음.
- `scripts/build-bundles.sh`: 번들에 완성된 `supabase/config.toml`·`docs/local-dev.md`(config.snippet.toml 유지).

## 완료 조건
`bash tests/install_local.sh` 전부 PASS · `bash tests/install_db.sh` 82/0 · 번들에 config.toml·docs/local-dev.md · Docker 스모크(임시 project_id·포트로 start → Studio 응답 → stop).

## 하지 않을 것
products/**·supabase/migrations/** 수정, 제품 레포 파일 수정(KNOWFLOW-AI는 `--check`로 보존만 확인), 새 의존성.
