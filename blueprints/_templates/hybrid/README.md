# hybrid-service 템플릿 (혼합형)
개인 작업이 기본이고, 필요할 때 조직(팀)과 공유한다. 예: HumScore, WebNovel-Studio.
- 모든 테이블: `user_id uuid not null`(작성자) + `organization_id uuid null`(공유 대상 조직).
- 읽기·수정: 작성자 본인 또는 `organization_id` 조직의 멤버.
- 쓰기(insert): 본인 `user_id`로만, `organization_id`는 null이거나 내가 멤버인 조직.
- 삭제: 작성자 또는 조직 owner·admin. 인덱스 `user_id`, `organization_id`.
