# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-18
- 브랜치: feat/local-kit(task-033 로컬 Studio 키트 구현 중: local/·install-local.sh·install-db 연동·번들 config.toml, 테스트 tests/install_local.sh 51/0, 리뷰·푸시 대기)
- 최우선(사용자 2026-11-16): KNOWFLOW 유튜브 요약·중요 장면 캡처. 029·030 구현·리뷰 반영 완료, 플래그 기본 꺼짐
- 제품 레포 5개 worktree `D:/WorkSpace/DEV/_wt/<레포>-nomad-db` 브랜치 feat/nomad-db 푸시·PR(병합 보류): humscore#12 · LOTTO-LAB#4 · ContentFlow#1 · KNOWFLOW#5 · Shorts#1
- task-032(운영 데이터 이관) 진행 중: 레포마다 `supabase/nomad-cutover/`(01 동결·undo, 02 복사 dry-run 기본, 03 Storage[KNOWFLOW·Shorts], check.sh)와 `docs/ops/NOMAD_DB_CUTOVER.md` 커밋·푸시. 각 check.sh 로컬 PASS(humscore·LOTTO-LAB은 accounts 파일 추가 조건에서 PASS)
  - 커밋: humscore 84d4ba6 · LOTTO-LAB 643fa9b · ContentFlow fb8b417 · KNOWFLOW b549f56 · Shorts(최신)
  - install-db: core 설치에 accounts 항상 포함으로 수정(credits 등이 credit_ledger 의존, 없으면 db push 실패). install_db 테스트 PASS
- task-032 남은 일(다음 세션 이어서):
  1. humscore·LOTTO-LAB worktree에 accounts 3개 재설치(install-db 재실행) 후 원래 check.sh PASS 확인
  2. 보안 리뷰(reviewer security + fable 검증) 아직 안 함 → 🔴 반영
  3. 사람 결정: KNOWFLOW beta→A/B/C, ContentFlow 플랜 대응(free→C·basic→B·pro→A 가정), ContentFlow 옛 NOT VALID 제약 위반 행 처리, 운영 DB에 제품·A/B/C 플랜 시드 선행
  4. 동결 중 로그인(KNOWFLOW)·계정 삭제(ContentFlow) 불가 — 절차서에 기록됨, 점검 공지 필요
- 사용자 결정(2026-11-17): 옛 플랜→구독 행, 익명 소유 행 있으면 중단, Shorts 큐 비운 뒤 전환
- 보류(사업·법무): 가격·좌석 수치, hospital 보존 기간, 동의 이력 보관 기간, astro 유료 기능, D7, news·erp 플랜 대응, 유튜브 법무(task-026)·실측(025)
- 주의: Docker Desktop 먼저. psql `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`. 이관 검사는 같은 컨테이너의 일회용 DB(cutover_<slug>)를 쓰고 지운다
