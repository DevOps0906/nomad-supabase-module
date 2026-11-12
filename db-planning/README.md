# NOMAD DB Architecture

> NOMAD AI Factory / 디지털노마드연구소의 **모든 플랫폼이 공유하는 DB 설계 기준 저장소**입니다.
> 새 프로젝트를 만들 때 이 저장소에서 유형을 고르고, 템플릿을 복사해서 시작합니다.

- 상태: 기획 단계 (v0.1.0, 2026-11-13) · 레포 푸시 전
- 대상 DB: Supabase (PostgreSQL 15+)
- 언어: 문서 한국어 / 코드·SQL 영어 식별자

## 1. 이 저장소가 해결하는 문제

| 문제 | 해결 |
|---|---|
| 서비스마다 DB 구조가 제각각 | 4가지 유형(조직형·개인형·격리형·로컬)으로 표준화 |
| 로그인·결제를 서비스마다 새로 만듦 | 공통 `core` 스키마 1벌을 모든 서비스가 참조 |
| 개인/팀 요금제가 달라 구조가 갈라짐 | 개인도 "1인 조직"으로 만들고 플랜만 다르게 |
| 프로젝트가 늘수록 문서가 흩어짐 | `projects/<유형>/<slug>/` 규칙으로 계속 쌓음 |

## 2. 폴더 구조 (한눈에)

```
nomad-db/
├─ README.md                 이 문서
├─ CHANGELOG.md              버전별 변경 기록
├─ RULES.md                  이 폴더에서 지킬 규칙
├─ docs/                     기획 문서 (읽는 순서대로 번호)
│  ├─ 00-overview/           원칙, 선택 흐름도, 용어집
│  ├─ 01-architecture/       테넌시, core 스키마, Supabase 배치, 초대, 결제, 역할
│  ├─ 02-conventions/        네이밍, RLS 패턴, 마이그레이션, 체크리스트, 폴더 규칙
│  └─ 03-diagrams/           Mermaid 구조도
├─ core-proposal/            core 제안 SQL (참고용, 적용 안 함)
│  └─ sql/                   0001~0006 SQL
├─ templates/                유형별 시작 템플릿 (복사해서 사용)
│  ├─ org-service/
│  ├─ user-service/
│  ├─ isolated-project/
│  └─ local-only/
├─ projects/                 실제 프로젝트가 쌓이는 곳 ★ 계속 늘어남
│  ├─ _template/             새 프로젝트 폴더 뼈대
│  ├─ org/<slug>/            조직형 (멀티테넌트)
│  ├─ user/<slug>/           개인형 (user_id 기준)
│  ├─ isolated/<slug>/       격리형 (별도 Supabase 프로젝트)
│  └─ local/<slug>/          DB 불필요 / 로컬
├─ registry/                 전체 현황 (프로젝트 목록, 계정 분석 결과)
│  ├─ projects.yaml
│  └─ accounts.yaml
└─ scripts/
   ├─ new-project.sh         프로젝트 폴더 생성기
   └─ validate.sh            규칙 검증기
```

## 3. 새 프로젝트 추가 방법 (30초)

```bash
./scripts/new-project.sh <org|user|isolated|local> <slug> "<표시 이름>"
./scripts/validate.sh
```

생성되는 폴더에는 `project.yaml`, `README.md`(ER 다이어그램 포함), `schema.draft.sql`이 들어 있습니다.
레지스트리(`registry/projects.yaml`)에도 자동으로 한 줄이 추가됩니다.

## 4. 현재 등록된 프로젝트 (15)

| 유형 | 개수 | 프로젝트 |
|---|---|---|
| 조직형 `org` | 7 | contentflow, flora, knowflow, classroom, analytics, sceneflow, commerce |
| 개인형 `user` | 4 | humscore, jangter, baedal, personal |
| 격리형 `isolated` | 2 | hospital, school |
| 로컬 `local` | 2 | motion, docs |

## 5. 읽는 순서

1. `docs/00-overview/principles.md` 원칙 8가지
2. `docs/00-overview/decision-flow.md` 내 프로젝트는 어떤 유형인가
3. `docs/01-architecture/core-schema.md` 공통 계정 계층
4. `docs/02-conventions/new-project-checklist.md` 새 프로젝트 체크리스트
