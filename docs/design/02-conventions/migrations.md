# 마이그레이션 규칙

1. 파일명 `YYYYMMDDHHMMSS_<설명>.sql`, 위치는 `supabase/migrations/` 한 곳.
2. **이미 적용된 파일은 수정 금지.** 변경은 새 날짜 파일로 추가.
3. 한 파일 = 한 주제. 되돌림(rollback) 메모를 주석으로 남긴다.
4. 청사진의 `schema.draft.sql`은 초안이다. 확정되면 내용을 새 날짜 마이그레이션으로 옮기고 청사진 `status`를 갱신한다.
5. 적용 순서: `nomad_core` → 서비스. 서비스 마이그레이션은 `nomad_core` 헬퍼가 있다고 가정한다.
6. 옮긴 뒤 `sql2erd`로 `docs/diagrams/erd.mmd`를 갱신하고 `tests/`에 접근 검증을 추가한다.
7. 적용 전 로컬(`supabase start`)에서 먼저 실행한다.
