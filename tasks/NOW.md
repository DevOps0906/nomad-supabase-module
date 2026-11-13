# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-14
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 015 P3 — 세션 종료로 중단. 미커밋 3개 디렉터리(products/flora·blog·sceneflow)
  - flora·blog: 이식 완료·run_check PASS였음. 팀장 결정 반영 중 중단 → 다시 확인: (3) 구독 끊겨도 공개된 책 페이지 열람 유지(get_public_book), (4) 라우팅 기능 키 publishing.* → flora.*. 그 뒤 보안 리뷰(fable) → 커밋
  - sceneflow: 0001·0002·check_org·run_check까지 작성 중 중단(existing.md·local-storage.md 없음, run_check 미확인) → 상태 확인 후 이어서
- 마지막으로 한 일: P2 8개 커밋, P3 commerce(8b6c488), school 검사 KST 수정(243167b), 청사진 중복 발견 등록(ebfcd3d)
- 다음 한 걸음: 위 P3 마무리 → P4 news(D10 사용자 결정 필요) → db reset 전체 검증·번들 재빌드·tests/bundles.sh·대시보드 데이터 갱신
- P2 교훈(P3·P4 지시에 넣을 것): core 표 직접 쓰기·트리거 금지 · 결과 저장은 실패 잡 거부+mark_job_delivered · definer 반환은 볼 수 있는 컬럼만 · 공개 읽기 RPC는 DB rate 키 없음 · 구독 끊김은 기존 유료 행 경로도 잠금 · 소프트 삭제 now() · 참조 조직 일치 · 수치 한도 시드 없음(원본 기본값 상수)
- 사용자 결정: 구독 끊기면 잠김(개인정보 삭제 예외) · microweb 게시 청첩장 하객 열람 유지(2026-11-14) · export_xlsx core feature · floria core rate/audit · AI 키 ai_chat·voice
- 열린 결정: D10(news core 요청 R-1~R-10), 가격·좌석 수치, 병원 4건, D7, erp 플랜 대응 확인, astro 유료 기능 여부
- 주의: 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- 테스트 상태: tests 12종 통과(3a3ed5b 시점), 제품 run_check 커밋분 전부 PASS, 번들 11/11은 4fcc55f 시점(이후 재실행 필요)
- 남은 작업: 015 P3 마무리·P4, 007, 008(보류), 발견한 문제 표
