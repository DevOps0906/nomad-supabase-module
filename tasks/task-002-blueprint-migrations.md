# task-002 청사진 → 확정 마이그레이션 (공용 프로젝트 11개 서비스)

- 위험도: 높음 (마이그레이션 · RLS) · 선행: task-001(accounts 마이그레이션 테스트)
- 근거: `blueprints/<org|user>/<slug>/schema.draft.sql`, `docs/design/01-architecture/roles-permissions.md`, `docs/design/01-architecture/tenancy-models.md`, `docs/design/02-conventions/migrations.md`, AGENTS.md 4장

## 범위
- 대상: 조직형 7(contentflow, flora, knowflow, classroom, analytics, sceneflow, commerce) + 개인형 4(humscore, jangter, baedal, personal).
- 제외: 격리형(hospital, school) — 별도 Supabase 프로젝트·자체 인증이므로 이 저장소 마이그레이션에 넣지 않는다(설계 문서로 유지).
- 제외: 요금 플랜·기능 카탈로그(`plans`·`features`·`plan_features`) — 수치가 미확정(billing-credits). 이번에는 `nomad_core.products` 등록만.

## 파일
- 서비스 1개 = 마이그레이션 1개: `supabase/migrations/202611150001NN_<slug>.sql` (NN: 아래 순서 01~11).
  01 contentflow · 02 flora · 03 knowflow · 04 classroom · 05 analytics · 06 sceneflow · 07 commerce · 08 humscore · 09 jangter · 10 baedal · 11 personal
- `begin; … commit;`으로 감싼다. 맨 위 주석: 서비스 이름 · 유형 · 원본 청사진 경로 · 되돌림 메모(`drop schema nomad_<slug> cascade; delete from nomad_core.products where code = '<slug>';`).

## 변환 규칙 (청사진 초안 대비 바뀌는 점) — challenger 반영판
결정(사용자 2026-11-13): 제품 잠금 없이 멤버십·역할만 확인 · 장터/배달은 두 당사자 설계로 포함 · Data API 노출 안 함(config.toml 그대로).

1. 스키마 `create schema nomad_<slug>;` (`if not exists` 금지) → `revoke all on schema … from public, anon, authenticated;` → `grant usage … to authenticated, service_role;`
2. `insert into nomad_core.products (code, name) values ('<slug>', '<blueprint.yaml name>');`
3. 테이블·컬럼 이름과 의미는 초안을 따른다. 추가·삭제·이름 변경 금지(예외: 4·B의 orders.idempotency_key). 다만:
   - 상태·종류 값 주석(예: `-- 검수·승인·발행`)은 영어 코드 `check (status in ('review','approved','published'))` + `not null default '<첫 값>'`, 한국어 뜻은 `comment on column`. **주석이 없는 상태 컬럼은 `text` 그대로 두고 보고**(B의 baedal은 아래에 정함).
   - 이름·제목 성격 컬럼(`name`, `title`)은 `not null`.
   - 금액(price·total·amount 등) → `bigint not null check (x >= 0)` (원). 개수(qty·count) → `int not null check (x > 0)`. 점수(score·rating) → `int check (x between 1 and 5)`. 그 밖의 numeric은 그대로 두고 보고.
   - `"key"`·`"position"` 같은 예약어 컬럼은 따옴표 유지.
4. 사용자 참조 (모두 `auth.users(id)`를 참조, nomad_core.profiles 참조 대신)
   - 소유 컬럼(자기 데이터의 주인: user_id·seller_id·owner_id 등): `uuid not null default auth.uid() references auth.users(id) on delete cascade`.
   - PK에 속한 사용자 컬럼(예: blog_members.user_id): `not null … on delete cascade`.
   - 행위자 컬럼(author_id·reviewer_id·writer_id·sender_id·created_by): `uuid default auth.uid() references auth.users(id) on delete set null`, insert 정책 with check에 `<col> = (select auth.uid())`.
   - 상대방 컬럼(두 당사자 기록의 다른 쪽: seller_id in chat_rooms, rider_id 등): `uuid references auth.users(id) on delete set null`.
5. 같은 테넌트 안에서만 참조
   - 조직형: 모든 부모 테이블에 `unique (organization_id, id)`, 자식의 부모 참조는 복합 FK `foreign key (organization_id, x_id) references nomad_<slug>.<parent>(organization_id, id) on delete cascade`.
   - 개인형: 복합 FK·cascade는 **같은 소유자의 부모·자식**(humscore scores→recordings/exports, personal 등)에만 쓴다. 다른 사람의 행을 가리키는 FK(favorites.listing_id 제외)는 `on delete set null`(컬럼 null 허용).
6. RLS: `enable row level security`, 모든 정책 `to authenticated`, `true`로 여는 쓰기 정책 금지.
   - 조직형: select `organization_role(organization_id) is not null` · insert/update `in ('owner','admin','editor')`(update는 using + with check) · delete `in ('owner','admin')`.
     예외: 역할·멤버를 담는 테이블(이름이 *_members 이거나 role 컬럼 보유)은 insert/update/delete 모두 `in ('owner','admin')`.
   - 개인형(단일 당사자): 소유자 `(select auth.uid()) = <소유 컬럼>` 으로 select/insert/update/delete 각각. 소유 컬럼 없는 자식은 부모 `exists`.
   - 공개 읽기(초안 `using (true)`)는 `to authenticated` select만.
7. 권한 (컬럼 단위로 update 제한 — 소유·행위자 컬럼 바꿔치기 차단)
   - `revoke all on all tables in schema nomad_<slug> from public, anon, authenticated;` → `grant all … to service_role;`
   - authenticated: 테이블마다 `grant select, insert, delete`, 그리고 `grant update (<수정 가능 컬럼>)` — id·organization_id·소유/행위자/상대방 컬럼·created_at 제외.
   - 아래 B의 "서버 전용" 테이블은 authenticated에 select만.
8. 인덱스: 소유 컬럼(조직형은 `(organization_id, created_at desc)` 가능하면), 모든 FK 컬럼, 정책에 쓰는 상대방 컬럼.
9. `comment on table` 한 줄씩(한국어).
10. 함수·트리거·`security definer`는 만들지 않는다(필요하면 보고만).

### B. 두 당사자 서비스
**jangter**
- listings: 소유 seller_id. status `check in ('on_sale','reserved','sold','hidden')` default 'on_sale'. select: 인증 사용자 전체 중 `status <> 'hidden' or seller_id = auth.uid()`. 쓰기: seller.
- listing_photos: 쓰기 listing의 seller(`exists`), select 인증 사용자 전체(부모 hidden 제외 조건 동일).
- favorites: 소유 user_id, listing_id → listings on delete cascade(예외 허용).
- chat_rooms: buyer_id = 행위자(default auth.uid()), seller_id = 상대방, listing_id → on delete set null. insert check: `buyer_id = auth.uid()` and `seller_id = (select l.seller_id from listings l where l.id = listing_id)` and `buyer_id <> seller_id`. select: buyer 또는 seller. update·delete: 없음(grant도 안 함).
- messages: sender_id 행위자. insert check: sender = auth.uid() and 방 참여자. select: 방 참여자. update·delete 없음.
- reviews: writer_id 행위자, 방 참여자만 insert, `unique (room_id, writer_id)`, select 인증 사용자 전체, update·delete는 writer.
**baedal**
- stores: 소유 owner_id, select 인증 사용자 전체, 쓰기 owner. menus: 쓰기 store owner(`exists`), price bigint, select 전체.
- orders (서버 전용 쓰기): buyer_id 상대방 규칙(set null) + default auth.uid(), store_id → stores on delete set null, status `check in ('requested','accepted','cooking','delivering','delivered','cancelled')` default 'requested', total bigint, **추가 컬럼 `idempotency_key text not null unique`**(결제 멱등, AGENTS 4장). select: buyer 또는 store owner. authenticated 쓰기 grant 없음.
- order_items (서버 전용): order_id → orders on delete cascade, menu_id → menus on delete set null, qty int. select: 해당 order의 buyer 또는 store owner.
- deliveries (서버 전용): rider_id 상대방, status `check in ('waiting','assigned','picked_up','delivered')` default 'waiting'. select: buyer·store owner·rider.
- reviews: writer_id 행위자, insert는 해당 order의 buyer만, `unique (order_id)`, select 전체, update·delete writer.

## 완료 조건
- 각 파일 단독 확인(동시 작업 안전, DB에 남기지 않음):
  `( echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' <파일>; echo 'rollback;' ) | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q`
- 전체: `npx supabase db reset --local` 성공 (팀장이 실행)
- `bash scripts/validate-blueprints.sh` 통과(청사진 파일은 건드리지 않음)
- `tests/services_access.sql` 통과: pg_policies 카탈로그 검사(roles = {authenticated}, 쓰기 정책 qual/with_check에 true 없음, 조직형 delete·멤버 테이블 쓰기는 owner/admin만), anon 권한 없음, 소유 컬럼 not null, 조직형 서비스별 대표 테이블 행동 검사, jangter·baedal 두 당사자 테이블 행동 검사
- `blueprint.yaml`·`registry.yaml` status `draft → migrated`, `docs/diagrams/erd.mmd` 재생성

## 리뷰 반영 결정 (2026-11-13, security·code 리뷰 후)
- 서버 전용 값: 점수(classroom.quiz_attempts)·크레딧(commerce.automation_jobs.credits_used)·주문(commerce.orders, baedal orders·order_items·deliveries)은 authenticated가 쓰지 못한다(select만).
- 조직 안 가시성: knowflow 비공개 공간·개인 대화, classroom 미공개 자료·숨김 문제·타 학생 기록은 소유자 또는 owner/admin/editor만.
- 연동 토큰(token_ref)은 authenticated select 불가, 공유 토큰은 서버 발급(default).
- 역할 테이블 대상(blog_members.user_id, enrollments.student_id)은 nomad_core.memberships 복합 FK로 조직 멤버만.
- 규칙 4 예외: analytics.projects.owner_id는 조직 데이터의 작성자이므로 행위자 컬럼(set null)으로 둔다 — 사용자 삭제가 조직 데이터를 지우지 않게.
- knowflow.messages.role은 대화 역할(user/assistant)이지 권한 역할이 아니다 → 규칙 6 멤버 테이블 예외 대상 아님. 사용자는 role='user'만 쓰고 assistant는 서버.
- 후기: jangter는 판매완료(sold) 거래 참여자만, baedal은 배달완료 주문의 구매자만. chat_rooms (listing_id, buyer_id) 유일.
- personal.birth_profiles 생년월일은 평문 저장 — 암호화는 앱·서버 책임(코멘트로 명시).

## 하지 않을 것
- 기존 마이그레이션 3개 수정, `blueprints/**/schema.draft.sql` 수정, 격리형 변환, 플랜·기능 카탈로그 작성
