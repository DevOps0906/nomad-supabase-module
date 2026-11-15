# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-15
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 015 P4 news — 착수 전 D10(news core 요청 R-1~R-10) 사용자 결정 필요
  - P3 완료(92b9a4e): flora·blog·sceneflow, fable 보안 리뷰 🟡6 반영, run_check 3개 PASS
  - P3 미결(팀장 확인): sceneflow 플랜 대응(advanced→A·pro/basic→B·starter→C) 원본 대조, 사용자 업로드 경로 형식은 코어 버킷 계약 확정 시 맞춤, 표 이름 원본 대조
- 마지막으로 한 일: P3 commerce(8b6c488)·flora·blog·sceneflow(92b9a4e) 커밋
- 다음 한 걸음: D10 결정 받기 → P4 news → db reset 전체 검증·번들 재빌드·tests/bundles.sh·대시보드 데이터 갱신
- P2·P3 교훈(P4 지시에 넣을 것): core 표 직접 쓰기·트리거 금지 · 결과 저장은 실패 잡 거부+mark_job_delivered(잡 행 for update) · definer 반환은 볼 수 있는 컬럼만 · 공개 읽기 RPC는 DB rate 키 없음 · 구독 끊김은 기존 유료 행 경로도 잠금 · 소프트 삭제 now()·owner/admin · 참조 조직 일치 · 수치 한도 시드 없음 · BEFORE 트리거 비멤버 42501 선거부 · 사용자 경로 조직 접두 CHECK · 사용자 insert에 id grant 없음(검사도 id 없이)
- 사용자 결정: 구독 끊기면 잠김(개인정보 삭제 예외) · microweb 게시 청첩장 하객 열람 유지 · flora 공개 책 열람 유지 · export_xlsx core feature · floria core rate/audit · AI 키 ai_chat·voice
- 열린 결정: D10(news core 요청 R-1~R-10), 가격·좌석 수치, 병원 4건, D7, erp 플랜 대응 확인, astro 유료 기능 여부
- 주의: 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`. Docker Desktop 꺼져 있으면 먼저 시작
- 테스트 상태: tests 12종 통과(3a3ed5b 시점), 제품 run_check 커밋분 전부 PASS, 번들 11/11은 4fcc55f 시점(이후 재실행 필요)
- 남은 작업: 015 P4, 007, 008(보류), 발견한 문제 표
