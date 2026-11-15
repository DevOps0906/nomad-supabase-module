# task-016 erp 가입 코드 무차별 시도 제한

- 위험도: 높음(인증 경계) · 선행: task-015 · 담당: builder → reviewer(security)
- 근거: tasks/README.md "발견한 문제" 2026-11-13 erp request_join 행, products/erp/org/0001_erp.sql(request_join), nomad_core.rate_limit_take(definer 안에서만 호출 — 사용자 grant 없음, 20261120000310)

## 할 일
- request_join: 잘못된 코드는 raise 대신 값(예: jsonb {"ok":false,"code":"invalid_code"})으로 돌려줘 시도 카운트가 롤백되지 않게 한다. 사용자·IP 키(사용자 id 기준)로 rate_limit_take, 초과 시 거부.
- 존재 노출 금지: 없는 코드·만료 코드·다른 조직 코드 응답을 같게.
- existing.md 앱 계약 변경(반환형) 기록.

## 완료 조건
- `bash products/erp/run_check.sh` PASS, 연속 오답 N회 뒤 거부·정답도 거부(창 안), 응답 동일성 검사

## 하지 않을 것
core 수정, 다른 제품
