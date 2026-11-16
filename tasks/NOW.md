# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-16 (밤)
- 브랜치: main(9c09a2c, 푸시 완료). chore/status-sync-1116 병합됨
- 최우선(사용자 2026-11-16): KNOWFLOW 유튜브 요약·중요 장면 캡처. 029(요약·장면 카드·플레이어)·030(사용자 승인 탭 캡처) 구현·리뷰 반영 완료, 플래그 기본 꺼짐
- 제품 레포 5개 nomad DB 전환: 각 레포 worktree `D:/WorkSpace/DEV/_wt/<레포>-nomad-db` 브랜치 feat/nomad-db 푸시·PR(병합 보류): humscore#12 · LOTTO-LAB#4(base dev/fortune-and-w0) · ContentFlow#1 · KNOWFLOW#5(base wip/task-004) · Shorts#1(base feat/015b-extension-web, 이번에 원격 생성)
  - humscore 469ca69 · LOTTO-LAB b30f375 · ContentFlow e807f51 · Shorts ed8598f · KNOWFLOW ff2eb0a (각 최신)
- 테스트: 이 저장소 knowflow·lottolab·contentflow·shorts·personal·erp·news run_check PASS, tenant_access PASS, install_db PASS(82). KNOWFLOW web 332 통과, worker 24 실패는 Node 24 환경(26 필요)
- 진행 중: 없음. 유튜브 029·030 구현·리뷰 반영·재설치 완료(KNOWFLOW worktree ff2eb0a), ContentFlow·Shorts 재연결 완료
- 병합 전 남은 일(레포별): 데이터 이관 SQL·운영 노출 스키마 추가·사용자 백필, humscore는 main 병합 시 운영 DB 자동 push 주의, KNOWFLOW db-tests 옛 스키마·egress allowlist·env 문서, LOTTO-LAB validation 표 16/17, ContentFlow plan_limits 수치 시드 없음(가격 결정 대기)·내 초대 초대자 표시 없음, Shorts 확장 API 구현 시 발급 전 권한 확인·rate_hit 키 해시, KNOWFLOW 운영 호스트 egress·로컬 Storage 주소
- 사용자 결정 대기: lottolab 계정 삭제 시 user_consents(동의 이력) 보관 여부
- 보류(사업·법무): 가격·좌석 수치, hospital 보존 기간, astro 유료 기능, D7, news·erp 플랜 대응, 유튜브 법무(task-026)·실측(025)
- 주의: Docker Desktop 먼저. psql `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`. 로컬 DB에 20261122000100이 직접 적용돼 있음(db reset으로 정리 가능)
