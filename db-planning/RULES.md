# RULES.md — db-planning 폴더 규칙 (상위 AGENTS.md가 우선)

이 저장소는 **DB 설계 기준 문서**입니다. 서비스 코드를 담지 않습니다.

## 반드시 지킬 것
1. 응답과 문서는 한국어. SQL 식별자·파일명은 영어 snake_case / kebab-case.
2. 새 프로젝트는 `scripts/new-project.sh`로 만들고 `projects/<유형>/<slug>/` 밖에 두지 않는다.
3. 서비스 스키마끼리 외래키·조인 금지. 참조는 `core`만 허용한다. (`validate.sh`가 검사)
4. 모든 테이블은 RLS를 켠다. 정책 없는 테이블은 만들지 않는다.
5. 조직형 테이블은 `org_id uuid not null references core.organizations(id)`를 가진다.
6. 개인형 테이블은 소유자 컬럼(`user_id`)을 가진다.
7. 격리형(병원·학교)은 이 저장소에 **설계 문서만** 둔다. 실제 개인정보·키·접속정보는 절대 커밋하지 않는다.
8. 마이그레이션은 추가만 한다. 이미 적용된 파일은 수정하지 않고 새 번호로 추가한다.
9. 비밀값(키, 토큰, DB URL)은 어떤 파일에도 쓰지 않는다.
10. 변경 시 `CHANGELOG.md`와 `registry/projects.yaml`을 함께 갱신한다.

## 하지 말 것
- 서비스 코드(Next.js 등)를 이 저장소에 추가
- `core.*` 테이블 컬럼 의미 변경 (필요하면 새 마이그레이션 + 문서 갱신)
- 요금제 수치를 문서 밖에서 임의 결정 (docs/01-architecture/billing-credits.md 기준)

## 작업 후 점검
```bash
./scripts/validate.sh
```
