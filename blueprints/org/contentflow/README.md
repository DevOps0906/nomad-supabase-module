# contentflow · 조직형

- tenant = 블로그를 함께 운영하는 팀·에이전시
- 개인 가입자는 1인 조직으로 자동 생성

| 항목 | 값 |
|---|---|
| slug | `contentflow` |
| 유형 | `org` |
| DB | Supabase 프로젝트 A |

## ER 다이어그램

```mermaid
erDiagram
  nomad_core_organizations {
    uuid id PK
    text name
    text type
  }
  blogs {
    uuid id PK
    uuid organization_id FK
    text name
    text platform
    text tone
    timestamptz created_at
  }
  topics {
    uuid id PK
    uuid organization_id FK
    uuid blog_id FK
    text keyword
    text status
    timestamptz created_at
  }
  posts {
    uuid id PK
    uuid organization_id FK
    uuid topic_id FK
    uuid author_id FK
    text status
    text body
    timestamptz created_at
  }
  blog_members {
    uuid organization_id PK
    uuid blog_id PK
    uuid user_id PK
    text role
  }
  publish_logs {
    uuid id PK
    uuid organization_id FK
    uuid post_id FK
    uuid blog_id FK
    text url
    timestamptz published_at
    timestamptz created_at
  }
  reviews {
    uuid id PK
    uuid organization_id FK
    uuid post_id FK
    uuid reviewer_id FK
    text verdict
    timestamptz created_at
  }
  nomad_core_organizations ||--o{ blogs : "1:N"
  blogs ||--o{ topics : "1:N"
  topics ||--o{ posts : "1:N"
  blogs ||--o{ blog_members : "1:N"
  posts ||--o{ publish_logs : "1:N"
  posts ||--o{ reviews : "1:N"
```

## 테이블

| 테이블 | 컬럼 수 |
|---|---|
| `blogs` | 6 |
| `topics` | 6 |
| `posts` | 7 |
| `blog_members` | 4 |
| `publish_logs` | 7 |
| `reviews` | 6 |

초안 SQL: [`schema.draft.sql`](./schema.draft.sql)

## 역할별 화면

- owner · admin  전체 블로그, 팀원, 결제 관리
- editor  검수 대기 글을 승인·반려
- writer  내가 맡은 블로그의 글 작성
- viewer  발행 결과와 성과만 열람
- RLS: org_id가 내가 속한 조직인 행만 읽고 씀

> 이 문서는 제안 초안입니다. 실제 레포 스키마와 대조 후 확정하세요.
