# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-15
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 015 마무리 — P1~P4 이식 완료. 남은 것: db reset 전체 검증 · 번들 재빌드 · tests/bundles.sh · 대시보드 데이터 갱신 · ERD 갱신
- 마지막으로 한 일: P3 flora·blog·sceneflow(92b9a4e), P4 news(545a655, D10 수용 안 함·N1~N3, challenger+fable 보안 2회+계약 리뷰 반영)
- 다음 한 걸음: `npx supabase db reset --local` → tests 12종 → 제품 run_check 전부(products/*/run_check.sh) → 번들 재빌드·bundles.sh(11/11은 4fcc55f 시점) → 대시보드 갱신 → 015 완료 커밋
- 교훈(다음 이식·수정 지시에 넣을 것): core 표 직접 쓰기·트리거 금지 · 결과 저장은 실패 잡 거부+mark_job_delivered(잡 행 for update) · definer 반환은 볼 수 있는 컬럼만 · 공개 읽기 RPC는 DB rate 키 없음(offset 상한) · 구독 끊김은 쓰기 잠금·공개분 열람 유지 · 소프트 삭제 now()·owner/admin · 참조 조직 일치(복합 FK) · 수치 한도 시드 없음·키 없으면 fail-closed · BEFORE 트리거 비멤버 42501 선거부 · 사용자 경로 조직 접두 CHECK · 사용자 insert에 id grant 없음 · 인가 전 존재 노출 금지(P0002) · 결제 반영 이벤트 id 필수
- 사용자 결정: 구독 끊기면 잠김(개인정보 삭제 예외) · microweb 청첩장·flora 공개 책·news 공개 기사 열람 유지 · D10 news core 요청 수용 안 함, N2 신청자가 조직 생성, N3 toss_merchant 1행·편집국=core editor(2026-11-15) · export_xlsx core feature · floria core rate/audit · AI 키 ai_chat·voice
- 열린 결정: 가격·좌석 수치, 병원 4건, D7, erp 플랜 대응 확인, astro 유료 기능 여부, news existing.md 팀장 확인 13건(데스크 자기 승인·플랜 대응·pg_trgm·소유권 이전 등), sceneflow 플랜 대응·표 이름 원본 대조, 코어 버킷 계약(제품 경로 형식)
- 주의: Docker Desktop 꺼져 있으면 먼저 시작. 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`. news는 pg_trgm 확장 필요
- 테스트 상태: 제품 run_check 커밋분 전부 PASS(news·sceneflow 2026-11-15 재확인), tests 12종은 3a3ed5b 시점, 번들 11/11은 4fcc55f 시점(재실행 필요)
- 남은 작업: 015 전체 검증, 007, 008(보류), 발견한 문제 표
