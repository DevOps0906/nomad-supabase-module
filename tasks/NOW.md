# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-16
- 브랜치: main (PR #2 병합 완료, cf4cae8)
- 현재 작업: 없음 — 대기 작업 0. 작업 표 전부 완료(task-001~020)
- 마지막으로 한 일: 015 완료·번들 전 제품(aa75c36), 대시보드(e815b22), task-016(15b56fc)·019(997f6af) erp 가입 제한, task-007(9d977b7)·017(3f48625) knowflow 잠금·쿼터 RPC, task-018 personal 암호문(9fbd010), task-020 설치기 products/ 기준(2f2c0bf)
- 테스트 상태: db reset 후 core tests 12/12, 제품 run_check 28개 PASS(2026-11-15), 이후 변경 제품(erp·knowflow·personal) 재확인 PASS, tests/install_db.sh 82/0, 번들 표본 5/5(번들은 2f2c0bf 시점 재생성)
- 교훈(다음 지시에 넣을 것): core 표 직접 쓰기 금지 · 결과 저장은 실패 잡 거부+mark_job_delivered(잡 행 for update) · definer 반환은 볼 수 있는 컬럼만 · 공개 RPC는 경로·소유 id 비노출·offset 상한 · 소프트 삭제 now()·owner/admin · 참조 조직 일치(복합 FK) · 수치 한도 시드 없음·키 없으면 fail-closed · BEFORE 트리거 비멤버 42501 · 사용자 경로 조직(·작성자) 접두, 경로는 서버만 · 전역 유일값은 RPC 난수 · 인가 전 존재 노출 금지(P0002) · 결제·차감 이벤트 id 필수·잠금 뒤 재조회 · 환불은 차감 표식 1회 · 열람 감사에 대상 id · 배포 경로(번들·설치기)가 무엇을 싣는지 함께 확인
- 사용자 결정(2026-11-16 추가): knowflow 쿼터 유지+기능 잠금·멱등 RPC · C 플랜은 무료 체험(끊김 잠금은 C에 없는 유료 기능만) · personal 입력 암호문 · erp 잠긴 조직 코드 = 없는 코드
- 열린 결정: personal readings 쓰기 서버 전용 여부, knowflow 확인 1~5(질문 길이·답변 실패 환불·viewer 질문·보고서 잡 생성), 대상 저장소의 옛 청사진 정리 방법, hospital 보존 기간 법무, news existing.md 13건, 가격·좌석 수치, D7, erp 플랜 대응, astro 유료 기능, 코어 버킷 계약
- 주의: Docker Desktop 먼저. 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`. psql `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- 다음 후보: 열린 결정 처리 → 각 제품 레포 앱 적용(발견한 문제 표 "제품 레포 앱 코드"), lottolab 1인 조직 정리
