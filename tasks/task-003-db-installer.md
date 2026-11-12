# task-003 DB 설치기 (scripts/install-db.sh)

- 위험도: 보통(외부 저장소에 파일 복사, DB 접속 없음) · 선행: task-002
- 근거: 계획 페이지(db-installer-plan) 기본값 — 파일 복사 · 초안 제외 · accounts는 플래그 · 이름 유지+순서 경고. docs/INTEGRATION.md "기존 제품에 적용"

## 인터페이스 (builder·tester 공통 계약)
`bash scripts/install-db.sh <대상 저장소> [--product <slug>]... [--with-accounts] [--with-example] [--check]`
- 대상에 `supabase/migrations/`가 없으면 "먼저 npx supabase init" 출력, exit 64. 알 수 없는 옵션·인자 누락도 64.
- 고르는 파일(이 저장소 `supabase/migrations/`, 이름 순):
  - 항상: `*_nomad_core.sql`, `*_nomad_core_*.sql` 중 `*_nomad_core_accounts.sql` 제외
  - `--with-accounts`: `*_nomad_core_accounts.sql`
  - `--with-example`: `*_contentflow_example.sql`
  - `--product <slug>`: `*_<slug의 - 를 _로>.sql` 정확히 끝나는 파일. 없으면 "<slug>: 확정 마이그레이션 없음 (blueprints/ 초안은 설치 대상 아님)", exit 64.
  - 재실행 시 잠금 파일의 `# flags` 줄에 기록된 옵션을 이번 옵션과 합친다(한 번 넣은 제품·accounts는 계속 추적).
- 잠금 파일 `<대상>/supabase/nomad.lock`:
  ```
  # nomad-supabase-module install-db.sh 가 씁니다. 손으로 고치지 마세요.
  # source <이 저장소 git short sha 또는 unknown>
  # flags --with-accounts --product contentflow
  <파일명>  <sha256>
  ```
  해시는 CR을 제거한 내용 기준(`tr -d '\r' | sha256sum`) — Windows 줄바꿈 변환을 어긋남으로 보지 않는다.
- 판정(쓰기 전에 전부 검사, 전부 아니면 전무):
  - 대상에 없음 → 복사 대상(`+ 파일명`)
  - 대상에 있고 원본 해시와 같음 → 건너뜀(`= 파일명`)
  - 대상에 있고 다름 → `✗ 파일명`, 하나라도 있으면 "아무 파일도 쓰지 않았습니다." exit 2
- `--check`: 쓰기 없음. exit 0 최신 · 1 복사할 새 파일 있음 · 2 어긋남.
- 경고(복사는 막지 않음, `!`로 시작):
  - accounts 선택 시: 가입 트리거·기존 사용자 백필 안내 2줄 + 대상의 nomad 외 마이그레이션에 `on auth.users` 트리거가 있으면 파일명과 함께 경고
  - 순서: 새로 복사하는 파일의 타임스탬프가 대상의 nomad 외 최신 마이그레이션보다 이르면 경고 + `npx supabase db push --include-all` 안내
- 정상 끝: `✓ N개 복사 · supabase/nomad.lock 기록`, 다음 단계 `npx supabase db reset --local` 안내, exit 0. 복사 0개여도 잠금 갱신·exit 0.
- DB 주소·키를 받지 않는다. bash + coreutils(sha256sum)만. Windows Git Bash에서 동작.

## 완료 조건
- `bash tests/install_db.sh` exit 0 (임시 폴더, 실제 저장소 미변경)
- 임시 대상에 설치 후 그 대상에서 마이그레이션 순서대로 적용 가능(tester가 로컬 DB에 begin…rollback으로 확인)
- docs/INTEGRATION.md "기존 제품에 적용" 1단계, README 파일 표, AGENTS.md 3장 명령 표 갱신

## 하지 않을 것
- 대상 config.toml 수정, DB 접속, 청사진 초안 설치, 기존 마이그레이션 수정
