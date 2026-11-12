# 서비스 유형 선택 흐름

> DB가 필요 없는 서비스(로컬 유형)는 이 모듈 대상 아님.

```mermaid
flowchart TD
  A[DB가 필요한 새 서비스] --> C{민감 개인정보<br/>의료·학생·금융?}
  C -- 예 --> I[isolated · 별도 Supabase 프로젝트]
  C -- 아니오 --> D{2명 이상이<br/>같은 데이터를 공유?}
  D -- 예 --> O[org · 조직형 멀티테넌트]
  D -- 아니오 --> E{고객사별 DB 납품<br/>또는 화이트라벨?}
  E -- 예 --> I
  E -- 아니오 --> U[user · 개인형]
```

## 표로 보기
| 질문 | 예 → | 아니오 → |
|---|---|---|
| 의료·학생 등 민감정보인가 | **isolated** | 다음 질문 |
| 2명 이상이 데이터를 공유하는가 | **org** | 다음 질문 |
| 고객사별로 DB를 따로 납품하는가 | **isolated** | **user** |

## 전환 경로
- user → org: 팀 기능이 생길 때. 소유자 컬럼을 `organization_id`로 확장 (humscore는 `workspace_id` NULL 컬럼을 미리 둠).
- isolated → org: 병원이 여러 곳 구독하는 SaaS가 되면 `clinic_id` 추가.
