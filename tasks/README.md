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
| task-010 | DB 스키마 대시보드(종류별 분류, 디자인 먼저 → Docker 로컬 서빙, 웨이브마다 갱신) | W2 | — | 낮음 | designer·builder | 진행 |
| task-011 | 공용 모듈 확장: 소셜 로그인(구글·카카오·네이버) · API 키 BYOK(Vault) | W2 | task-006 | 높음 | builder | 완료 |
| task-012 | 최우선 5개 제품 DB 변환(실제 레포 기준, 단일 user안·테넌트 org안) | W2 | task-006 | 높음 | builder | 완료 |
| task-013 | 번들 빌더(단일·테넌트·모노레포) 와 구조별 검증 | W2 | task-011·012 | 보통 | builder | 진행 |
| task-014 | 코어 웨이브(C1 크레딧 버킷·C2 jobs·C3 rate limit·C5 AI·C6 affiliate·C7 voice) | W3 | task-011 | 높음 | builder | 진행(challenger) |
| task-015 | platform-docs 제품 이식 P1(erp·school·poll·floria) → P2~P4(코어 웨이브 후) | W3 | task-012 | 높음 | builder | 진행 |

상태: 대기 / 진행 / 완료 / 보류

## 발견한 문제 (범위 밖 — 나중 작업 후보)
| 날짜 | 위치 | 내용 | 제안 |
|---|---|---|---|
| 2026-11-13 | nomad_core 초대·멤버 | ContentFlow 앱이 쓰는 my_invitations·change_member_role·remove_member·초대 거절이 core에 없음 | 해결: 20261119000300_nomad_core_accounts.sql |
| 2026-11-13 | nomad_core 역할 | reviewer 역할 없음 → contentflow 제품 표 reviewers로 보강 | 제품 표 유지(core 역할은 공통만) |
| 2026-11-13 | lottolab org안 | 계정 삭제 시 1인 조직 정리 필요 | 데이터 이전·계정 삭제 작업에서 |
| 2026-11-13 | 제품 레포 앱 코드 | public → nomad_<slug> 스키마 지정(Accept-Profile·.schema()), 일부 이름 변경, ContentFlow 키워드 upsert → 조회 후 insert/update | 각 레포 적용 작업(existing.md 대응표 기준) |

## 교훈 (다음 작업에 그대로 적용할 것만, 20줄 이내 유지)
- 
