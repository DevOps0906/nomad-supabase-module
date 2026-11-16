# task-021 — 2026-11-16 결정 8건 반영 (위험도 높음)

근거: 사용자 결정(2026-11-16, 권장안 일괄) + challenger 착수 전 점검. 이식본(products/)은 아직 어떤 운영 DB에도 적용 전이라 직접 수정하고, core는 새 번호 파일로만 추가한다.

| # | 내용 | 반드시 지킬 것 |
|---|---|---|
| 1 | personal readings 쓰기 서버(service_role) 전용 | user·org 둘 다 readings insert·update 정책 제거·authenticated grant 회수. 서버는 RLS를 우회하므로 existing.md 앱 계약에 "서버가 has_feature·멤버십을 먼저 검사" 명시. run_check에 authenticated 쓰기 42501 추가 |
| 2 | knowflow 답변 실패 시 질문 쿼터 환불 RPC | service_role만 실행. messages에 차감 달 표식 열, update…returning 한 문장으로 1회만(refund_report_quota 방식). 지난달 차감분은 사용량 그대로, 표식 null(이관 행) 환불 안 함. **환불된 질문은 답변 저장 거부, 답변이 이미 있으면 환불 거부**(같은 멱등 키 재시도로 공짜 질문 방지). user·org 둘 다 |
| 3 | erp 금액 numeric(12,2) → bigint(원) | price·unit_price·생성열 total_price·sales_trend의 total까지. sum은 ::bigint. 이관 시 소수 금액 행이 있으면 중단(반올림 금지). 앱 계약에 소수 입력 22P02 기록 |
| 4 | erp audit_logs → nomad_core.write_audit | action 접두 `erp.`. before/after에 연락처 넣지 않음. 조직 삭제 후에도 로그가 남는 점을 existing.md에 기록. 읽기는 rpc('nomad_audit_log'). 원본 로그 이관 절차(actor·created_at 보존, postgres 세션) 문서화. erp 표·정책·grant 제거 |
| 5 | pg_trgm 확장을 core 새 마이그레이션으로 | 파일명 `*_nomad_core_*.sql`. 확장이 extensions 스키마가 아닌 곳에 이미 있으면 분명한 메시지로 실패. knowflow·news 이식본의 create extension 줄 처리 통일, tests/bundles.sh 설명 갱신 |
| 6 | news 자기 기사 자기 승인 금지 | approve 분기 안에서 created_by·author_id 둘 다 `is distinct from`으로 비교. **발행인이 신문사 유일 staff면 예외 허용**. 새 오류 코드 + check_org 케이스 |
| 7 | 대상의 옛 청사진 정리 | install-db.sh는 DB 접속 없는 복사기로 유지. 별도 `scripts/cleanup-legacy-blueprints.sh`(대상 DB 주소 인자): 스키마 이름이 정확히 같을 때만, 옛 plan_features·features 행까지 정리, 행 수 표시 → 대화형 확인 필수(비대화 환경 기본 거부), 실행 전 BACKUP_RESTORE.md 백업 안내 |
| 8 | lottolab org안 계정 삭제 시 1인 조직 정리 | 조직은 남기고 nomad_lottolab 행만 삭제(결제 원장·다른 제품 보존). service_role RPC, 사용자 삭제 **전에** 호출(EF account-delete 계약에 기록). 대상: kind='personal'이고 본인만 멤버인 조직 |

## 완료 조건
- `npx supabase db reset --local` 후 core tests 전부 통과, 바뀐 제품(personal·knowflow·erp·news·lottolab) `products/<slug>/run_check.sh` PASS
- `bash tests/install_db.sh` 통과, 번들 재생성(`scripts/build-bundles.sh`) 후 표본 확인
- 각 existing.md "팀장 확인 필요"에서 처리한 항목 정리

## 하지 않을 것
- 적용된 core 마이그레이션 수정 · 가격·좌석 수치 시드 · hospital 보존 기간 · astro 유료 기능 · D7
