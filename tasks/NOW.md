# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 없음 — 014 코어 웨이브 완료(C1·C2·C3·C5·C6·C7), 013 완료, 015 P1 완료
- 마지막으로 한 일: C2 jobs(5ab41b7) · C5 AI(c9f1f50) · C6 affiliate(985a011) · C7 voice(77195d3) · 문서(3fca063) · erp·floria 잠금(cbf1ccd)
- 다음 한 걸음: P1 0002_ai.sql 라우팅 시드를 C5 확정 컬럼으로 채우기(erp) → 015 P2~P4 이식 웨이브(코어 의존 해소됨) → 번들에 P1 제품 포함 여부 결정
- 사용자 결정(2026-11-13): 구독 끊기면 erp·floria 잠김(개인정보 삭제만 예외) · export_xlsx는 core feature(A) · floria는 core rate/audit 사용 · AI 키 ai_chat·voice 그대로
- 팀장 결정(보고함): plan 새 기간 지급 전 만료·만료 기간 plan 환불 0 · queued 취소는 항상 환불 · last_error 비노출 · jobs 멱등은 조직 단위 · brandconnect 기능 키 · voice 탈퇴 cascade·Storage 버킷 없음
- 열린 결정: 가격·좌석 수치, 병원 4건, D7·D10, erp 플랜 대응(default→B·standard→A) 확인, poll 입장 한도 300/10분
- 주의: 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- 테스트 상태: db reset 후 tests 12종 + install_db 68/68 + 제품 run_check 전부 통과(3fca063), 번들 11/11(4fcc55f 시점)
- 남은 작업: 015 P2~P4, 007, 008(보류), 발견한 문제 표
