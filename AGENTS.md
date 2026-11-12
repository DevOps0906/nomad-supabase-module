# AGENTS.md — nomad-supabase-module

> 모든 AI 코딩 도구(Claude Code · ChatGPT Codex · Gemini CLI · OpenCode · Cursor)가 읽는 **단일 정본**. 80줄 이내로 유지한다.
> 영역별 상세 규칙은 `.claude/rules/*.md`(7장 표), 사용법은 `README.md`·`docs/`.

## 1. 무엇인가
여러 NOMAD 제품이 가져다 쓰는 Supabase DB 청사진(업체 격리·멤버십·A/B/C 플랜·단품 이용권)과 ContentFlow 실습 예시 SQL. 앱 코드는 없고 SQL·테스트·문서만 둔다.

## 2. 스택 (작업 시 최신 stable 확인 후 버전 고정)
| 영역 | 선택 | 위치 |
|---|---|---|
| DB·인증 | Supabase (Postgres · RLS · Auth) · Supabase CLI(`npx supabase`) | `supabase/migrations/` |
| 테스트 | 합성 데이터 + 트랜잭션 롤백 SQL (`psql`) | `tests/` |
| 문서 | 통합·백업 복구 절차 | `docs/` |

## 3. 명령
| 목적 | 명령 |
|---|---|
| 로컬 DB 시작 | `npx supabase start` |
| 마이그레이션 재적용 | `npx supabase db reset --local` (이 저장소 전용 디렉터리에서만) |
| 접근 테스트 | `psql "<npx supabase status의 DB 주소>" -v ON_ERROR_STOP=1 -f tests/tenant_access.sql` |
| ERD 갱신 | `~/.claude/nomad/bin/sql2erd supabase/migrations -o docs/diagrams/erd.mmd` |
긴 출력 명령은 `~/.claude/nomad/bin/q <명령>`으로 실행한다.

## 4. 절대 규칙 (위반 = 리뷰 🔴)
- 비밀(API 키 · service_role 키 · DB 비밀번호)과 실제 고객 데이터는 저장소에 넣지 않는다. 테스트는 합성 데이터만, 고객 백업은 별도 저장소.
- 모든 테이블 RLS. 적용된 마이그레이션 파일은 수정하지 않고 새 번호 파일로 추가한다.
- 공통 스키마는 `nomad_core`, 제품 스키마는 제품 키로 분리한다. 실습 예시 키는 `contentflow_example`(운영 ContentFlow와 섞지 않는다).
- `security definer` 함수는 `set search_path = ''`와 스키마 한정 이름을 쓴다. 권한은 `authenticated`·`service_role`에 필요한 만큼만 grant.
- 업체 간 격리·기능 잠금을 바꾼 작업은 `tests/tenant_access.sql`에 검증을 추가하고 통과시킨다.
- 금액은 정수(원). 결제·차감 요청에는 멱등 키.
- 문서·커밋·주석 문구는 한국어, SQL 식별자는 영어.

## 5. 문서 지도 (필요한 장만 읽는다)
| 문서 | 내용 |
|---|---|
| `README.md` | 파일 목록 · 제품과 플랜 · 범위 |
| `docs/INTEGRATION.md` | 설치·기존 제품 통합 · 기능 이용권 계약 |
| `docs/BACKUP_RESTORE.md` | 스키마 재현 · 데이터 복구 절차 |
| `docs/diagrams/*.mmd` | 전체 구조도 · RLS 흐름 · ERD (Mermaid) |
| `docs/design/` · `blueprints/README.md` | 서비스 DB 설계 기획 · 서비스별 청사진(초안) |
| `tasks/README.md` · `tasks/NOW.md` | 작업 표 · 현재 상태 |

## 6. 작업 방식
작업은 `tasks/README.md`의 순서대로 하나씩. 작업 파일의 "근거"와 "하지 않을 것"을 지키고, 완료 조건을 실행으로 확인한 뒤 커밋한다.
커밋: `[task-NNN] 요약` + 본문(무엇을 · 확인 방법).

## 7. 영역 규칙 · 도구별 로드 (규칙 정본은 `.claude/rules/` 한 곳)
아래 경로의 파일을 만들거나 고치기 **전에** 해당 규칙 파일을 읽는다. Claude Code는 `paths:` 조건으로 자동 로드하므로 다시 읽지 않는다.
| 작업 경로 | 규칙 파일 |
|---|---|
| `supabase/**` · `tests/**` | `.claude/rules/db.md` |
| `docs/**` | `.claude/rules/docs.md` |
| `blueprints/**` | `.claude/rules/blueprints.md` |
- 읽지 않는 파일: `.env*` · lock 파일 · `node_modules/` · `.nomad/` (Claude는 `.claude/settings.json`, Gemini는 `.geminiignore`가 강제, ChatGPT Codex는 이 줄로 지킨다).
- 도구별 설정: Claude Code `CLAUDE.md`·`.claude/` · ChatGPT Codex `.codex/config.toml` · Gemini CLI `.gemini/settings.json`·`.geminiignore`.
- 새 규칙 파일을 추가하면 이 표에도 한 줄 추가한다.

## 8. Codex 네이티브 팀
- 주 모델은 gpt-6.1-sol, 부 모델은 사용자가 확인한 지원 ID로만 지정한다. 초기 설정은 비활성이다.
- `nomad-os codex init . --worker-model <ID>` 적용 후 새 세션에서 시작하고 `nomad-os codex check .`로 검사한다.
- nomad_scout/designer/builder/tester/reviewer, 부 작업 최대 3개·깊이 1. 소유 파일을 명시하고 타인의 변경을 되돌리지 않는다.
- 설정 검사와 실제 모델 실행은 별개다. 운영 지침: NOMAD `global/nomad/CODEX_TEAM.md`.
