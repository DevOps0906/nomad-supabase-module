# 작업 표

| 번호 | 제목 | 웨이브 | 선행 | 위험도 | 담당 | 상태 |
|---|---|---|---|---|---|---|
| task-001 | 계정 확장 마이그레이션 · 혼합형 청사진 템플릿 · 로컬 Supabase 구성 | W1 | — | 높음 | builder | 완료 |
| task-002 | 서비스 청사진 11개를 확정 마이그레이션으로 전환 | W1 | task-001 | 높음 | builder | 완료 |
| task-003 | DB 설치기 `scripts/install-db.sh` | W1 | task-002 | 보통 | builder | 완료 |
| task-004 | 요금 플랜 · 기능 카탈로그와 기능 잠금 | W1 | task-003 | 높음 | builder | 완료 |
| task-005 | 보류 status 값 목록 확정 · 컬럼 정리 | W2 | task-004 | 높음 | builder | 완료 |
| task-006 | 플랜별 수량 한도 구조 (수치는 billing-credits 결정 후) | W2 | task-009 | 높음 | builder | 완료 |
| task-007 | knowflow 대화 크레딧 차감을 기능 이용권에 연결 (멱등 키) | W2 | task-004 | 높음 | builder | 대기 |
| task-008 | 격리형 hospital 확정 (school은 task-009에서 조직형으로 이식) | W2 | task-004 | 높음 | builder | 보류 |
| task-009 | platform-docs 코어·제품 16개 대응표와 이식 계획 | W2 | task-005 | 보통 | planner | 완료 |
| task-010 | DB 스키마 대시보드(종류별 분류, 마이그레이션에서 자동 생성 → Artifact, 웨이브마다 갱신) | W2 | task-006 | 낮음 | builder | 대기 |

상태: 대기 / 진행 / 완료 / 보류

## 발견한 문제 (범위 밖 — 나중 작업 후보)
| 날짜 | 위치 | 내용 | 제안 |
|---|---|---|---|

## 교훈 (다음 작업에 그대로 적용할 것만, 20줄 이내 유지)
- 
