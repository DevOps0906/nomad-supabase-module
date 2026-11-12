# jangter · 개인형 (마켓플레이스)

- 소유자 = 판매자, 접근 = 거래 당사자
- 조직 개념 없음

| 항목 | 값 |
|---|---|
| slug | `jangter` |
| 유형 | `user` |
| DB | Supabase 프로젝트 A |

## ER 다이어그램

```mermaid
erDiagram
  nomad_core_profiles {
    uuid id PK
    text name
    text type
  }
  listings {
    uuid id PK
    uuid seller_id FK
    text title
    numeric price
    text status
    text dong
    timestamptz created_at
  }
  listing_photos {
    uuid id PK
    uuid listing_id FK
    text storage_path
    text position
    timestamptz created_at
  }
  favorites {
    uuid user_id PK
    uuid listing_id PK
    timestamptz created_at
  }
  chat_rooms {
    uuid id PK
    uuid listing_id FK
    uuid buyer_id FK
    uuid seller_id FK
    timestamptz created_at
  }
  messages {
    uuid id PK
    uuid room_id FK
    uuid sender_id FK
    text body
    timestamptz sent_at
    timestamptz created_at
  }
  reviews {
    uuid id PK
    uuid room_id FK
    uuid writer_id FK
    numeric score
    text comment
    timestamptz created_at
  }
  nomad_core_profiles ||--o{ listings : "판매자"
  listings ||--o{ listing_photos : "1:N"
  nomad_core_profiles ||--o{ favorites : "1:N"
  favorites ||--o{ listings : "찜"
  listings ||--o{ chat_rooms : "1:N"
  chat_rooms ||--o{ messages : "1:N"
  chat_rooms ||--o{ reviews : "1:N"
```

## 테이블

| 테이블 | 컬럼 수 |
|---|---|
| `listings` | 7 |
| `listing_photos` | 5 |
| `favorites` | 3 |
| `chat_rooms` | 5 |
| `messages` | 6 |
| `reviews` | 6 |

초안 SQL: [`schema.draft.sql`](./schema.draft.sql)

## 접근 규칙

- 상품: 누구나 열람 · 수정은 seller_id = 나
- 채팅·메시지: 거래 당사자(구매자·판매자)만
- 찜: 본인 것만 · 동네(dong) 값으로 지역 필터

> 이 문서는 제안 초안입니다. 실제 레포 스키마와 대조 후 확정하세요.
