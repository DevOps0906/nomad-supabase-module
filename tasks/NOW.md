# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-15
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 전 제품 products/ 완성(사용자 지시 2026-11-15) — 남은 것: 번들 전 제품 확장(builder 진행 중: build-bundles SLUGS 자동 수집·hospital isolated 번들·실행기 인자 통일·bundles.sh 표본/--all) → 대시보드 데이터 갱신 → 015 완료
- 마지막으로 한 일: 새 제품 analytics(d6da24f)·classroom(5e1b776)·jangter(df94cfb)·baedal(2e95dbe)·personal(8be4e5b)·hospital 격리형(3eb4d3e, task-008 완료), 우선 3제품 실행기(009d419). 전부 fable 보안 리뷰 반영
- 전체 검증(2026-11-15 db reset 후): core tests 12/12 PASS, 제품 run_check 28개 전부 PASS(astro·knowflow·lottolab·stock·studynote는 인자 user/org 필요 — 통일 중)
- 교훈(다음 지시에 넣을 것): core 표 직접 쓰기·트리거 금지 · 결과 저장은 실패 잡 거부+mark_job_delivered(잡 행 for update) · definer 반환은 볼 수 있는 컬럼만 · 공개 RPC는 경로·소유 id 비노출·offset 상한 · 구독 끊김은 쓰기 잠금·공개분 열람 유지 · 소프트 삭제 now()·owner/admin · 참조 조직 일치(복합 FK) · 수치 한도 시드 없음·키 없으면 fail-closed · BEFORE 트리거 비멤버 42501 · 사용자 경로 조직(·작성자) 접두 CHECK, 경로는 서버만 기록 · 사용자 insert에 id·코드 grant 없음(전역 유일값은 RPC 난수) · 인가 전 존재 노출 금지(P0002) · 결제 반영 이벤트 id 필수·잠금 뒤 재조회 · 열람 감사에 대상 id
- 사용자 결정: 구독 끊기면 잠김(개인정보 삭제 예외) · 공개분 열람 유지(microweb·flora·news) · D10·N1~N3(news) · hospital ①서버 전용 ②HMAC 정확 일치 ③bootstrap 1회 ④법정 보존 표, 행위자=서버 보증+DB 최소 검사, CRM 한정, 파기=목록+관리자 함수 · export_xlsx core feature · floria core rate/audit · AI 키 ai_chat·voice
- 열린 결정: 가격·좌석 수치, D7, erp 플랜 대응, astro 유료 기능, 각 제품 existing.md "팀장 확인 필요"(news 13·hospital 보존 기간 법무·personal 생년월일 암호화·jangter/baedal C 플랜 잠금 무효·analytics max_files 시드), sceneflow 플랜·표 이름 대조, 코어 버킷 계약
- 주의: Docker Desktop 먼저. 대시보드 `cd tools/schema-dashboard/docker && DASHBOARD_PORT=8766 docker compose up -d --build`(hospital isolated 폴더는 대시보드 미인식 — 후속). psql `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- 남은 작업: 번들 확장 마무리, 대시보드, 007, 발견한 문제 표
