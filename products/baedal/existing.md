# baedal(동네배달) 기존 DB 분류표

원본(기존): 레포 없음 → 청사진 `blueprints/user/baedal/`(README·schema.draft.sql) + `supabase/migrations/20261115000110_baedal.sql`·`20261116000110_baedal.sql`(스키마 `nomad_baedal`, 6표).
변환: `user/0001_baedal.sql`(개인형) · `org/0001_baedal.sql`(조직형, 결정 D5: 개인형 제품도 두 안). 검사: `check_user.sql` · `check_org.sql`, 실행 `bash products/baedal/run_check.sh user|org`(같은 스키마 이름이라 트랜잭션 안에서 청사진을 drop 후 적용, 항상 rollback).
스키마 `nomad_baedal`(API 노출) · `nomad_baedal_private`(정책 판정 함수, 노출 금지). anon 사용 없음(공개 RPC 없음, 가게·메뉴 열람도 로그인 사용자만).

## 테이블
| 원래 이름 | 분류 | 새 이름 | 소유 컬럼 user→org 변화 | 비고 |
|---|---|---|---|---|
| nomad_baedal.stores | 이관 | nomad_baedal.stores | `owner_id` → `organization_id`(+`created_by`). 가게 직원 = 조직 멤버(청사진 "직원 계정이 필요해지면 조직으로 확장") | `deleted_at` 추가(폐점 = `close_store` 소프트 삭제 now()), delete 권한 제거 |
| nomad_baedal.menus | 이관 | nomad_baedal.menus | user안 변화 없음 / org안 `organization_id` 추가 + 복합 FK `(store_id, organization_id)` | `store_id` not null, 가격 bigint 0~1억 원 |
| nomad_baedal.orders | 이관 | nomad_baedal.orders | `buyer_id` 유지(주문자는 사용자) / org안 `store_organization_id` + 복합 FK | 쓰기는 RPC만. `idempotency_key` 전역 unique → `(buyer_id, idempotency_key)` unique(다른 사용자 키 존재 노출 방지). `paid_at` 추가 |
| nomad_baedal.order_items | 이관 | nomad_baedal.order_items | 변화 없음(주문 따라감) | `menu_name`·`unit_price` 스냅숏 추가(메뉴 수정·삭제 후에도 금액 근거 유지) |
| nomad_baedal.deliveries | 이관 | nomad_baedal.deliveries | `rider_id` 유지(배달원은 사용자) | `order_id` unique(주문당 1건), 기본 상태 waiting→assigned(배정 시 생성), 주문 취소 시 `cancelled`(배달원 개인정보 열람 종료) |
| nomad_baedal.reviews | 이관 | nomad_baedal.reviews | `writer_id` 유지 | `order_id`·`rating` not null |
| (없음) | 신규 | nomad_baedal.order_contacts | 변화 없음(주문 따라감) | 배달 주소·주문자 전화·배달원 전화. 주문자·가게(org안 owner/admin/editor)·**진행 중**(배달 assigned·picked_up이고 주문 accepted·cooking·delivering) 배정 배달원만 열람 |
| (없음) | 신규 | nomad_baedal.payments | 변화 없음 | 결제 반영. `pg_event_id` not null unique = 멱등, 서버 전용 |

## 함수 · RPC (모두 신규 — 청사진은 "서버 전용 쓰기"만 적고 경로가 없었다)
| 이름 | 실행 | 내용 |
|---|---|---|
| place_order(store, items, address, phone, idempotency_key) | authenticated | 합계를 서버가 메뉴 가격×수량으로 계산(메뉴 for share 잠금, 저장 후 total = 항목 합으로 확정). 같은 (주문자, 키) = 기존 주문 id. 가게 없음·폐점·잠김 = P0002 |
| set_order_status(order, status) | authenticated | 가게: requested→accepted(결제 후)→cooking, requested·accepted→cancelled / 주문자: requested→cancelled. 비당사자 P0002 |
| update_delivery(order, status, eta) | authenticated | 배정 배달원만: assigned→picked_up(주문 delivering)→delivered(주문 delivered) |
| close_store(store) | authenticated | user안 점주, org안 owner/admin. 권한 없으면 P0002 |
| apply_payment(order, amount, pg_event_id) | service_role | 이벤트 id 필수·재전송 멱등(주문 잠금 뒤 재조회), 같은 id에 다른 주문·금액이면 거부, 금액 = 주문 합계, 취소·기결제 거부 |
| assign_rider(order, rider, rider_phone) | service_role | 접수·조리중 주문만, 같은 배달원 재호출 무시, 다른 배달원 23505 |
| nomad_baedal_private.* (manages_store·store_staff(org)·store_writable·is_order_buyer_or_store·order_visible·contacts_visible·owner_has_feature(user, 내부)) | 정책 판정 | security definer, boolean만 반환(RLS 재귀 방지) |

## 기능 잠금 · 한도
- 카탈로그는 마이그레이션과 같다(C·B·A 모두 `order_core`, `on conflict do nothing`). 판정: user안 = 점주의 owner 개인 조직 `org_has_feature`, org안 = 가게 조직.
- 잠기면 가게·메뉴 쓰기·접수/조리·새 주문 받기가 막히고, 취소·열람·배달 진행은 유지된다.
- 수치 한도(plan_limits) 시드 없음. 제안 키: `stores_max` · `menus_per_store_max`(현재 하드코딩도 없음, 키 없으면 fail-closed로 붙일 것).

## 팀장 확인 필요
1. org안에서 주문자·배달원을 사용자 단위로 둔 것(가게만 조직). 배달 대행사를 조직으로 둘지.
2. 결제 후 취소의 환불 경로(현재 상태만 cancelled, 환불 반영 없음).
3. 배달원 전화(`rider_phone`)는 배정 시 서버가 넘긴 값을 주문별로 복사 — 배달원 프로필 표를 둘지.
4. 배달 완료 후 order_contacts 파기 주기(현재 배달원만 열람 종료, 주문자·가게는 계속 열람). 개인정보 보존 기간 결정 필요.
5. org안 viewer는 주문은 보지만 개인정보·처리는 불가로 정함.
