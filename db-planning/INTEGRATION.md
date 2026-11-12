# nomad-supabase-monorepo 와의 관계

| 영역 | 위치 | 성격 |
|---|---|---|
| 실제 마이그레이션 · 테스트 | `../supabase/`, `../tests/` | **정본**. 이 폴더가 수정하지 않음 |
| 공통 스키마 | `nomad_core` | 정본. 이 폴더의 `core`는 제안(`core-proposal/`) |
| 서비스 DB 설계 기획 | `db-planning/` (이 폴더) | 15개 프로젝트 초안 · 유형 분류 · 규칙 |

새 프로젝트: `./db-planning/scripts/new-project.sh <org|user|isolated|local> <slug> "<이름>"`, 검증: `./db-planning/scripts/validate.sh`.
초안이 확정되면 `../supabase/migrations/`에 날짜 형식 새 파일로 옮기고 `nomad_core` 이름으로 치환합니다.
