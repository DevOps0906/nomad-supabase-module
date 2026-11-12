# 역할 · 권한

`nomad_core.memberships.role` 값(owner·admin·editor·viewer) 기준.

| 역할 | 조직 설정 | 멤버 관리 | 데이터 쓰기 | 데이터 읽기 |
|---|---|---|---|---|
| owner | ○ | ○ | ○ | ○ |
| admin | ○ | ○ | ○ | ○ |
| editor | ✕ | ✕ | ○ | ○ |
| viewer | ✕ | ✕ | ✕ | ○ |

- 결제·운영 권한은 조직 역할이 아니라 `nomad_core.platform_admins.scope`(operations·billing)로 분리한다. 이 레코드만으로 고객 데이터 RLS가 열리지 않는다.
- 기능 잠금은 역할과 별개로 `nomad_core.has_feature()`가 판단한다.

## 원칙
- 화면 숨김은 UX, **차단은 RLS**가 한다. 프런트 분기만 믿지 않는다.
- 삭제 권한은 owner/admin만 (`nomad_core.organization_role(organization_id) in ('owner','admin')`).
- 서비스 안의 세부 직책이 필요하면 서비스 스키마에 별도 테이블로 둔다.
