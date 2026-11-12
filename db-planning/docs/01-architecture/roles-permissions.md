# 역할 · 권한

| 역할 | 조직 설정 | 결제 | 멤버 관리 | 데이터 쓰기 | 데이터 읽기 |
|---|---|---|---|---|---|
| owner | ○ | ○ | ○ | ○ | ○ |
| admin | ○ | ✕ | ○ | ○ | ○ |
| billing | ✕ | ○ | ✕ | ✕ | ✕ |
| member | ✕ | ✕ | ✕ | ○ | ○ |
| viewer | ✕ | ✕ | ✕ | ✕ | ○ |

## 서비스별 세부 역할
`core.memberships.service_roles` (jsonb)에 서비스별 역할을 저장한다.

```json
{ "contentflow": "editor", "flora": "writer" }
```

- 조직 공통 역할은 `role`, 서비스 안의 직책은 `service_roles`.
- 대시보드는 `role`과 `service_roles`를 조합해 화면을 분기한다 (RBAC).

## 원칙
- 화면 숨김은 UX, **차단은 RLS**가 한다. 프런트 분기만 믿지 않는다.
- 삭제 권한은 owner/admin만.
