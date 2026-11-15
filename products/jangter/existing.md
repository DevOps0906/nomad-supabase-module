# jangter(동네장터) 기존 DB 분류표

원본: 레포 없음. "기존" = 청사진 `supabase/migrations/20261115000109_jangter.sql`(스키마·RLS) + `20261116000109_jangter.sql`(플랜 C/B/A·기능 `trade_core`) + `blueprints/user/jangter/`.
변환: `user/0001_jangter.sql`(개인형) · `org/0001_jangter.sql`(조직형, 결정 D5). 검사: `check_user.sql` · `check_org.sql` → `bash products/jangter/run_check.sh`(둘 다, 항상 rollback).
스키마 `nomad_jangter`(API 노출) · `nomad_jangter_private`(정책 판정 함수, 노출 금지). 청사진과 같은 스키마 이름이라 검사는 트랜잭션 안에서 drop 후 적용한다.

## 테이블
| 원래 이름 | 분류 | 새 이름 | 접근(공통) | 소유 컬럼 user→org 변화 |
|---|---|---|---|---|
| listings | 이관 | nomad_jangter.listings | 표는 판매자(조직 멤버)만, 공개 열람은 RPC | `seller_id` → `organization_id`(+`created_by`). 두 안 모두 `unique(id, 소유)` 추가(복합 FK 대상) · (신규) `sold_room_id`(sold ⇔ not null, 복합 FK `(sold_room_id, id)`→chat_rooms(id, listing_id)) |
| listing_photos | 이관 | nomad_jangter.listing_photos | 판매자만 | (신규) `seller_id` → `organization_id`. 복합 FK `(listing_id, 소유)`로 글 소유 일치 강제, 경로 접두 CHECK |
| favorites | 이관 | nomad_jangter.favorites | 본인(조직)만, 공개 글만 담기 | `user_id` → `organization_id`(+`created_by`), PK `(organization_id, listing_id)` |
| chat_rooms | 이관 | nomad_jangter.chat_rooms | 두 당사자만 읽기, 생성은 `open_chat` | `buyer_id`·`seller_id` → `buyer_organization_id`·`seller_organization_id`(+`created_by`). 복합 FK `(listing_id, seller)`→listings, 글 삭제 시 `listing_id`만 null |
| messages | 이관 | nomad_jangter.messages | 당사자만, 수정·삭제 없음 | `sender_id` 유지 + `organization_id`(보낸 쪽 조직, 방 당사자여야 함) |
| reviews | 이관 | nomad_jangter.reviews | 작성자·당사자만 읽기, 공개 평점은 RPC | `writer_id` → `writer_organization_id`(+`created_by`), unique `(room_id, writer_organization_id)` |
| (profiles) | 없음 | nomad_core.profiles·organizations 참조 | — | 상대방 표시 이름만 RPC로 |

## 함수 · RPC (전부 신규 — 청사진에는 RPC 없음)
| 이름 | 실행 | 비고 |
|---|---|---|
| list_listings(p_dong, p_limit, p_offset) | anon·authenticated | 정의자. 숨김 제외, 판매자 id·저장 경로 미반환(사진 id만), org안 비활성 조직 제외, limit 1~50, offset 0~1000(초과 22023). DB rate 키 없음 |
| get_listing(p_listing_id) | anon·authenticated | 숨김·없음 같은 빈 결과. 사진 jsonb |
| listing_seller_reviews(p_listing_id, p_limit, p_offset) | anon·authenticated | 판매자가 구매자에게 받은 후기만(org안 비활성 조직 = 없음), 작성자·방 id 미반환 |
| open_chat(p_listing_id) / org: open_chat(p_listing_id, p_buyer_org) | authenticated | 순서: 로그인·잠금·구매 조직 editor+(42501, 비멤버 선거부) → 숨김·없음(P0002) → 판매 완료·자기 글(22023). 같은 글이면 같은 방 |
| my_chat_rooms() / org: my_chat_rooms(p_org) | authenticated | 상대방은 표시 이름(user안 profiles.display_name, org안 organizations.name)만. org 비멤버 42501 |
| _private.can_trade() / org: can_write(org) | 정책용 | 잠금 판정. user안 `nomad_core.user_has_feature`, org안 `organization_role` editor+ + `nomad_core.has_feature` |
| _private.listing_visible · room_sold_for_me / room_sold_for(room, org) | 정책용 | org안은 호출자가 그 조직 멤버가 아니면 거짓(탐색 금지) |

## 청사진 대비 바뀐 점
- 청사진은 `listings_select`가 authenticated 전체에 공개(`status <> 'hidden'`), `reviews_select using(true)` → 표는 본인·당사자만, 공개는 RPC로(판매자 id·작성자 id 비노출).
- `chat_rooms` 직접 insert 정책 → `open_chat` RPC만(구매자가 판매자 id를 몰라도 됨, 숨김 글 존재 노출 금지).
- 사용자 insert는 컬럼 grant(id·소유·created_by 없음). org안은 `organization_id` update grant 없음(조직 이동 금지).
- not null·길이 CHECK 추가: listing_photos `listing_id`·`storage_path`, messages `body`(1~2000자), reviews `score`·`room_id`, title·dong·comment 길이.
- 쓰기만 잠금(`trade_core`), 읽기·공개 열람·삭제는 유지. org안 글·후기 삭제는 owner·admin.

## 한도 → plan_limits 키(수치 시드 안 함, 미구현)
없음. 필요해지면 `listings_active_max`·`photos_per_listing_max` 제안(키 없으면 fail-closed로 구현).

## 팀장 확인 필요
1. 카탈로그는 `trade_core` 하나뿐이고 C 플랜에도 포함 → 구독이 끊겨도(C 취급) 실제로는 잠기지 않는다. 검사는 plan_features 행 삭제로 잠금 경로만 확인.
2. 상대방 표시 이름 `profiles.display_name`·개인 조직 이름은 가입 시 이메일 앞부분일 수 있음(core handle_new_user) → 노출 범위 확인.
3. `listing_photos.position`은 청사진대로 text(정렬이 문자열 순). integer 변경 여부.
4. Storage 버킷·경로 계약(코어 버킷 계약 열린 결정): 현재 `<소유 id>/<listing_id>/…` 접두 CHECK만.
5. org안 거래 당사자를 조직 단위로 둠(개인 사용자는 personal 조직). 채팅 상대 사용자 uuid(`sender_id`)는 당사자에게 보임.
6. 메시지·후기 rate limit 없음(core rate 연결은 서버 경로에서).

## 전환 시 앱 변경 메모
- `.schema('nomad_jangter')`, API 노출 스키마에 `nomad_jangter` 추가(`_private` 제외).
- 공개 RPC는 저장 경로를 돌려주지 않는다(경로 접두 = 판매자·조직 id): `list_listings.thumbnail_photo_id`·`get_listing.photos[].id`만 → 앱 서버가 사진 id로 경로를 찾아 서명 URL 발급.
- 판매 완료는 `update listings set status='sold', sold_room_id=<구매 방>`(그 글의 방, 복합 FK). 후기는 그 방 당사자만, `sold` 해제 시 `sold_room_id`도 null.
- 목록·상세는 `.rpc('list_listings'|'get_listing')`, 채팅 시작은 `.rpc('open_chat')`, 방 목록은 `.rpc('my_chat_rooms')`.
- org안: insert에 `organization_id`(개인은 `public.nomad_my_organizations()`의 personal 조직) 필요.
