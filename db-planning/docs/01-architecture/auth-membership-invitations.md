# 가입 · 조직 · 초대 흐름

```mermaid
flowchart TD
  S[소셜 로그인 / 이메일 가입] --> U[auth.users 생성]
  U --> T[트리거 handle_new_user]
  T --> P[core.profiles]
  T --> O[개인 조직 자동 생성 type=personal]
  T --> M[memberships owner]
  T --> SUB[subscriptions free]
  M --> D[대시보드]
  D --> Q{팀원 초대?}
  Q -- 아니오 --> D
  Q -- 예 --> V[create_team_org 로 팀 전환]
  V --> I[invitations 발송]
  I --> A[accept_invitation 토큰·이메일·만료·좌석 검사]
  A --> R[역할 부여]
  R --> X[서비스 데이터 org_id 기준 격리]
```

## 가입 화면
- 카드 2개("개인으로 시작" / "팀·기업으로 시작")는 **UI 선택일 뿐** DB는 동일하다.
- 개인: 소셜 로그인 → 자동으로 1인 조직.
- 팀: 가입 후 `create_team_org()` 호출 → 회사명 입력 → 초대.

## 초대 규칙
- 초대는 이메일 기준. 수락 시 로그인 이메일과 일치해야 한다.
- 만료 7일(기본). 만료 후 재발송.
- 좌석 한도는 **초대 시점**에 검사한다 (viewer 제외).
- 계정 공유(1개 ID로 여러 명) 방식은 쓰지 않는다. 사람마다 계정을 가진다.
