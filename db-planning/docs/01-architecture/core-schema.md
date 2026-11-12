# core 스키마 설계

모든 서비스가 공유하는 계정 계층. 서비스 스키마는 `core`만 참조한다.

```mermaid
erDiagram
  AUTH_USERS ||--|| PROFILES : "1:1"
  PROFILES ||--o{ MEMBERSHIPS : "1:N"
  ORGANIZATIONS ||--o{ MEMBERSHIPS : "1:N"
  ORGANIZATIONS ||--o{ INVITATIONS : "1:N"
  ORGANIZATIONS ||--o| SUBSCRIPTIONS : "1:1"
  PLANS ||--o{ SUBSCRIPTIONS : "1:N"
  ORGANIZATIONS ||--o{ CREDIT_LEDGER : "1:N"
  ORGANIZATIONS {
    uuid id PK
    text name
    org_type type
    uuid created_by
  }
  PROFILES {
    uuid user_id PK
    text name
    text email
  }
  MEMBERSHIPS {
    uuid org_id FK
    uuid user_id FK
    member_role role
    jsonb service_roles
  }
  INVITATIONS {
    uuid id PK
    uuid org_id FK
    text email
    member_role role
    text token
    timestamptz expires_at
  }
  PLANS {
    text code PK
    int seat_limit
    int monthly_credits
  }
  SUBSCRIPTIONS {
    uuid org_id PK
    text plan_code FK
    text status
  }
  CREDIT_LEDGER {
    uuid id PK
    uuid org_id FK
    int delta
    text reason
  }
```

## 테이블 요약
| 테이블 | 역할 | 쓰기 권한 |
|---|---|---|
| `core.profiles` | auth.users 1:1 프로필 | 본인 |
| `core.organizations` | 개인/팀 조직 | 트리거·`create_team_org()` |
| `core.memberships` | 조직-사용자-역할 | owner/admin |
| `core.invitations` | 이메일 초대 | owner/admin |
| `core.plans` | 요금제 정의 | service_role |
| `core.subscriptions` | 조직별 구독 | service_role |
| `core.credit_ledger` | 크레딧 원장 | `spend_credits()` / service_role |

## 헬퍼 함수 (security definer)
- `core.is_member(org uuid) → boolean`
- `core.has_role(org uuid, roles core.member_role[]) → boolean`
- `core.shares_org_with(uid uuid) → boolean`
- `core.create_team_org(name text) → uuid`
- `core.accept_invitation(token text) → uuid`
- `core.spend_credits(org uuid, amount int, reason text) → int`

SQL은 `core-proposal/sql/0001~0006`에 있다.
