# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 015 P3 이식 중(sceneflow · flora·blog · commerce 병렬) → 보안 리뷰 → 제품별 커밋
- 마지막으로 한 일: P2 8개 커밋(microweb 2e93e89·arch·toon 7110aaa·docs aba3e28·trailer·studynote d21ae54·stock·astro 2b7cabd), core 보완 mark_job_delivered·자격 회수(3a3ed5b), 제품 SQL 카드(72e846c)
- 다음 한 걸음: P3 리뷰·커밋 → P4 news(D10 사용자 결정 필요) → db reset 전체 검증·번들 재빌드
- 사용자 결정(2026-11-13): 구독 끊기면 erp·floria 잠김(개인정보 삭제만 예외) · export_xlsx는 core feature(A) · floria는 core rate/audit 사용 · AI 키 ai_chat·voice 그대로
- 팀장 결정(보고함): plan 새 기간 지급 전 만료·만료 기간 plan 환불 0 · queued 취소는 항상 환불 · last_error 비노출 · jobs 멱등은 조직 단위 · brandconnect 기능 키 · voice 탈퇴 cascade·Storage 버킷 없음
- 열린 결정: 가격·좌석 수치, 병원 4건, D7·D10, erp 플랜 대응(default→B·standard→A) 확인, poll 입장 한도 300/10분
- 주의: 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- 테스트 상태: db reset 후 tests 12종 + install_db 68/68 + 제품 run_check 전부 통과(3fca063), 번들 11/11(4fcc55f 시점)
- 남은 작업: 015 P2~P4, 007, 008(보류), 발견한 문제 표
