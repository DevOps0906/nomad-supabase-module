# classroom · 조직형

- tenant = 교육기관·강사 팀
- 시간별 자료 공개, 사전·사후 평가, 3면도 퀴즈

| 항목 | 값 |
|---|---|
| slug | `classroom` |
| 유형 | `org` |
| DB | Supabase 프로젝트 A |

## ER 다이어그램

```mermaid
erDiagram
  core_organizations {
    uuid id PK
    text name
    text type
  }
  courses {
    uuid id PK
    uuid org_id FK
    text title
    text subject
    timestamptz created_at
  }
  sessions {
    uuid id PK
    uuid org_id FK
    uuid course_id FK
    timestamptz starts_at
    timestamptz open_at
    timestamptz created_at
  }
  materials {
    uuid id PK
    uuid org_id FK
    uuid session_id FK
    text kind
    text file_path
    timestamptz created_at
  }
  enrollments {
    uuid id PK
    uuid org_id FK
    uuid course_id FK
    uuid student_id FK
    text role
    timestamptz created_at
  }
  assessments {
    uuid id PK
    uuid org_id FK
    uuid course_id FK
    text phase
    timestamptz created_at
  }
  quiz_items {
    uuid id PK
    uuid org_id FK
    numeric level
    numeric views
    boolean is_hidden
    timestamptz created_at
  }
  quiz_attempts {
    uuid id PK
    uuid org_id FK
    uuid student_id FK
    numeric level
    numeric score
    timestamptz created_at
  }
  core_organizations ||--o{ courses : "1:N"
  courses ||--o{ sessions : "1:N"
  sessions ||--o{ materials : "1:N"
  courses ||--o{ enrollments : "1:N"
  courses ||--o{ assessments : "1:N"
  assessments ||--o{ quiz_items : "문항 구성"
  assessments ||--o{ quiz_attempts : "응시"
  quiz_items ||--o{ quiz_attempts : "1:N"
```

## 테이블

| 테이블 | 컬럼 수 |
|---|---|
| `courses` | 5 |
| `sessions` | 6 |
| `materials` | 6 |
| `enrollments` | 6 |
| `assessments` | 5 |
| `quiz_items` | 6 |
| `quiz_attempts` | 6 |

초안 SQL: [`schema.draft.sql`](./schema.draft.sql)

## 역할별 화면

- owner  기관 대표: 강의·강사·수강생 전체 관리
- instructor  자료 공개 시각 설정, 평가·성적 확인
- student  내 강의 자료와 내 성적만 열람
- 3면도 퀴즈: 단계별 70% 이상이면 다음 단계, 만점이면 히든 문제 개방
- RLS: org_id + 수강생은 본인 응시 기록만

> 이 문서는 제안 초안입니다. 실제 레포 스키마와 대조 후 확정하세요.
