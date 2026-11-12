# 용어집

| 용어 | 뜻 |
|---|---|
| 테넌트(tenant) | 데이터를 공유하는 단위. 이 저장소에서는 `core.organizations` 한 행 |
| 조직(organization) | 개인(personal) 또는 팀(team). 구독·크레딧의 주체 |
| 멤버십(membership) | 사용자와 조직의 연결 + 역할 |
| 역할(role) | owner / admin / member / viewer / billing |
| RLS | Row Level Security. 행 단위 접근 제어 |
| RBAC | 역할 기반 접근 제어. 화면·기능 차이를 결정 |
| 1:N | 한 쪽 1개가 다른 쪽 여러 개를 가짐. 화살표는 1쪽 → N쪽, 외래키는 N쪽 테이블이 보유 |
| N:1 | 1:N의 반대 방향 표기 |
| 1:1 | 서로 1개씩 대응 |
| 좌석(seat) | 요금 계산 대상 멤버. viewer 제외 |
| 크레딧 | AI 호출 등에 쓰는 조직 공유 포인트. `credit_ledger`에 원장 기록 |
| 서비스 스키마 | contentflow, flora 등 서비스별 Postgres 스키마 |
| `core` | 계정·조직·결제 공통 스키마 |
| 격리형 | 별도 Supabase 프로젝트로 분리한 서비스 (병원, 학교) |
