# 마이그레이션 규칙

1. 파일명 `NNNN_설명.sql`, 번호는 4자리 증가.
2. **이미 적용된 파일은 수정 금지.** 변경은 새 번호로 추가.
3. 한 파일 = 한 주제. 되돌림(rollback) 메모를 주석으로 남긴다.
4. `core`는 `core-proposal/sql/`, 서비스는 `projects/<유형>/<slug>/` 안에서 관리한다.
5. 적용 순서: core → 서비스. 서비스 마이그레이션은 core 헬퍼가 있다고 가정한다.
6. 초안 파일 이름은 `schema.draft.sql`. 확정되면 `migrations/0001_init.sql`로 승격.
7. 적용 전 로컬(`supabase start`)에서 먼저 실행한다.
