# 테넌시 모델 비교

| 항목 | 개인형 (user) | 조직형 (org) | 격리형 (isolated) |
|---|---|---|---|
| 소유 컬럼 | `user_id` | `organization_id` | 역할(role) 또는 기관 1곳 고정 |
| RLS 기준 | `auth.uid() = user_id` | `nomad_core.organization_role(organization_id) is not null` | 역할 + 감사 로그 |
| 데이터 공유 | 본인만 | 조직 멤버끼리 | 기관 내 역할별 |
| 대시보드 차이 | 없음(본인 것만) | 역할별로 다름 | 역할별로 다름 |
| 구독 | 개인 구독(별도 설계) | 제품별 A/B/C 플랜 + 단품 | 계약/납품 |
| DB 위치 | 공용 프로젝트 | 공용 프로젝트 | 별도 프로젝트 |
| 개발 난이도 | 낮음 | 중간 | 높음(보안) |

## 핵심 정리
- **대시보드가 달라지는 것**은 역할(RBAC) 때문이다. 개인형이든 조직형이든 UI 분기는 가능하다.
- **데이터 분리**는 소유 컬럼(`user_id` vs `organization_id`)과 RLS로 결정된다.
- **한 번 가입으로 여러 서비스 사용(SSO)** 은 `nomad_core` 계정 계층의 역할이며 테넌시와 무관하다.

## 권장안
조직형 7개 서비스는 모두 `nomad_core.organizations`를 공유한다. 개인 가입자는 "1인 조직"으로 다루므로
서비스 코드는 항상 `organization_id` 하나만 다루면 된다. 개인형 4개 서비스는 단순함을 위해 `user_id`를 유지한다.
