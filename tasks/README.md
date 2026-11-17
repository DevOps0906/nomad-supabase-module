# 작업 표

| 번호 | 제목 | 웨이브 | 선행 | 위험도 | 담당 | 상태 |
|---|---|---|---|---|---|---|
| task-001 | 계정 확장 마이그레이션 · 혼합형 청사진 템플릿 · 로컬 Supabase 구성 | W1 | — | 높음 | builder | 완료 |
| task-002 | 서비스 청사진 11개를 확정 마이그레이션으로 전환 | W1 | task-001 | 높음 | builder | 완료 |
| task-003 | DB 설치기 `scripts/install-db.sh` | W1 | task-002 | 보통 | builder | 완료 |
| task-004 | 요금 플랜 · 기능 카탈로그와 기능 잠금 | W1 | task-003 | 높음 | builder | 완료 |
| task-005 | 보류 status 값 목록 확정 · 컬럼 정리 | W2 | task-004 | 높음 | builder | 완료 |
| task-006 | 플랜별 수량 한도 구조 (수치는 billing-credits 결정 후) | W2 | task-009 | 높음 | builder | 완료 |
| task-007 | knowflow 대화·업로드를 기능 이용권에 연결(쿼터 유지, 2026-11-16 결정) | W2 | task-004 | 높음 | builder | 완료(쿼터 차감 경로·C 플랜 잠금은 결정 대기) |
| task-008 | 격리형 hospital 확정 (school은 task-009에서 조직형으로 이식) | W2 | task-004 | 높음 | builder | 완료(products/hospital/isolated, 보존 기간 법무 확인 남음) |
| task-009 | platform-docs 코어·제품 16개 대응표와 이식 계획 | W2 | task-005 | 보통 | planner | 완료 |
| task-010 | DB 스키마 대시보드(종류별 분류, 디자인 먼저 → Docker 로컬 서빙, 웨이브마다 갱신) | W2 | — | 낮음 | designer·builder | 완료(28개 제품·격리형·분류별 화면, e815b22·b97ea12) |
| task-011 | 공용 모듈 확장: 소셜 로그인(구글·카카오·네이버) · API 키 BYOK(Vault) | W2 | task-006 | 높음 | builder | 완료 |
| task-012 | 최우선 5개 제품 DB 변환(실제 레포 기준, 단일 user안·테넌트 org안) | W2 | task-006 | 높음 | builder | 완료 |
| task-013 | 번들 빌더(단일·테넌트·모노레포) 와 구조별 검증 | W2 | task-011·012 | 보통 | builder | 완료 |
| task-014 | 코어 웨이브(C1 크레딧 버킷·C2 jobs·C3 rate limit·C5 AI·C6 affiliate·C7 voice) | W3 | task-011 | 높음 | builder | 완료 |
| task-015 | platform-docs 제품 이식 P1(erp·school·poll·floria) → P2~P4(코어 웨이브 후) | W3 | task-012 | 높음 | builder | 완료(2026-11-16: db reset 후 core 12/12·제품 28개 PASS, 번들 56개·표본 5/5) |

| task-016 | erp 가입 코드 무차별 시도 제한(값 반환 + rate_limit_take) | W3 | task-015 | 높음 | builder | 완료(구현은 cbf1ccd, 응답 동일성 검사 추가) |
| task-017 | knowflow 질문·보고서 쿼터 차감 멱등 RPC(ask_question·create_report, 실패 환불, 서버 직접 insert 차단) | W3 | task-007 | 높음 | builder | 완료 |
| task-018 | personal 생년월일·사주 입력 암호문 전환(astro 방식, 풀이 결과는 평문) | W3 | task-015 | 높음 | builder | 완료(readings 쓰기 서버 전용 여부는 결정 대기) |
| task-019 | erp 구독 끊긴 조직 가입 코드 거부(없는 코드와 같은 P0002 응답) | W3 | task-016 | 보통 | builder | 완료 |
| task-020 | install-db.sh --product를 청사진 대신 products/<slug> 이식본 설치로(보안 리뷰 전 청사진 배포 차단) | W3 | task-013 | 높음 | builder | 완료 |
| task-021 | 2026-11-16 결정 8건 반영(personal·knowflow·erp·news·lottolab·pg_trgm·옛 청사진 정리) | W3 | task-020 | 높음 | builder | 완료(리뷰 🔴 1건 정리 스크립트 수정 21722a4) |
| task-022 | contentflow 이식본 보강: 옛 0020~0027(publish_jobs·analytics_*·sync RPC·metric tool 값) + 조직 대기 초대 목록·plan_limits 읽기 public RPC | W3 | task-021 | 높음 | builder | 완료(보안 리뷰 ACCEPT) |
| task-023 | shorts 이식본 보강: Shopping-Shorts HEAD 3face90의 추가 마이그레이션 8개(job_queue_status·extension_*·썸네일·격리) 반영 | W3 | task-021 | 높음 | builder | 완료(org 확장 소유 검사 교정 edc6c57, 보안 리뷰 🔴 없음) |
| task-032 | 제품 레포 5개 운영 데이터 이관 스크립트(01 동결·02 복사·03 Storage·check.sh·전환 절차서) + install-db가 accounts 항상 포함 | W3 | task-031 | 높음 | builder | 진행 중(스크립트·로컬 검증 완료분 커밋, 보안 리뷰·humscore·LOTTO-LAB accounts 재설치 남음) |
| task-033 | 로컬 Studio 환경 키트(local/ 템플릿·포트 등록부, install-local.sh, install-db·번들 연동) | W3 | task-032 | 보통 | builder | 진행(Docker 스모크·리뷰 대기) |
상태: 대기 / 진행 / 완료 / 보류

## 발견한 문제 (범위 밖 — 나중 작업 후보)
| 날짜 | 위치 | 내용 | 제안 |
|---|---|---|---|
| 2026-11-13 | nomad_core 초대·멤버 | ContentFlow 앱이 쓰는 my_invitations·change_member_role·remove_member·초대 거절이 core에 없음 | 해결: 20261119000300_nomad_core_accounts.sql |
| 2026-11-13 | nomad_core 역할 | reviewer 역할 없음 → contentflow 제품 표 reviewers로 보강 | 제품 표 유지(core 역할은 공통만) |
| 2026-11-13 | lottolab org안 | 계정 삭제 시 1인 조직 정리 필요 | 데이터 이전·계정 삭제 작업에서 |
| 2026-11-13 | 제품 레포 앱 코드 | public → nomad_<slug> 스키마 지정(Accept-Profile·.schema()), 일부 이름 변경, ContentFlow 키워드 upsert → 조회 후 insert/update | 각 레포 적용 작업(existing.md 대응표 기준) |
| 2026-11-13 | erp request_join | 가입 코드 무차별 시도 제한 없음(core rate_limit_hit은 서버 전용, 오류는 raise라 카운트 롤백) | 해결: cbf1ccd(값 반환·사용자당 10회/시간) + task-016 응답 동일성 검사. IP 제한은 Route Handler |
| 2026-11-14 | 청사진 flora·sceneflow·commerce | supabase/migrations의 청사진(nomad_flora·nomad_sceneflow·nomad_commerce)과 products/ 이식본이 같은 스키마 이름 — 로컬 실습 DB에 청사진 기능 행이 남음 | 해결(2026-11-16): 번들·install-db.sh 모두 products/ 이식본만 설치(task-020), 대상에 옛 청사진이 있으면 경고. 청사진은 로컬 실습·core 테스트 전용. 대상의 옛 청사진 정리 방법은 미정 |

## 교훈 (다음 작업에 그대로 적용할 것만, 20줄 이내 유지)
- 
