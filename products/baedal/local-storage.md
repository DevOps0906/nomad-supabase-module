# baedal 로컬 저장소 설계

레포가 없어 현재 키는 없다(이관할 키 없음). 아래는 새로 만들 때의 규칙이다.
공통 규칙: 키 `nomad.baedal.<entity>.v<N>`, 테마만 공통 키 `nomad.theme`(system · light · dark; 로그인 시 `nomad_core.profiles.theme`와 맞춘다). 비밀(토큰·API 키)과 **개인정보(주소·전화)**는 localStorage·IndexedDB·평문 파일에 두지 않는다.

## 1. 저장 위치(플랫폼별)
| 대상 | 웹(Next.js) | 앱(Capacitor iOS/Android) |
|---|---|---|
| 장바구니(가게 id·메뉴 id·수량) | localStorage | Capacitor Preferences |
| 주문 멱등 키(결제 진행 중 1건) | sessionStorage | Preferences(결제 완료·취소 시 삭제) |
| 설정·UI 상태 | localStorage | Preferences |
| 배달 주소·전화 | 두지 않는다(서버 `order_contacts`, 입력 폼은 메모리만) | 두지 않는다. 자주 쓰는 주소 저장이 필요하면 서버 표로 따로 설계(팀장 확인) |
| 인증 세션 | @supabase/ssr 쿠키 | 앱 보안 저장소 |

## 2. 키 목록(신규)
| 키 | 내용 | 로그아웃 시 |
|---|---|---|
| `nomad.baedal.cart.v1` | `{store_id, items:[{menu_id, qty}]}` — 금액은 저장하지 않는다(서버가 계산) | 삭제 |
| `nomad.baedal.pending_order.v1` | 진행 중 주문의 `idempotency_key`(재시도 시 같은 키로 `place_order`) | 삭제 |
| `nomad.baedal.last_store.v1` | 마지막으로 본 가게 id | 삭제 |
| `nomad.baedal.rider_mode.v1` | 배달원 화면 전환 여부 | 삭제 |
| `nomad.baedal.preferences.v1` | 정렬·필터 등 비식별 설정 | 유지 |
| `nomad.theme` | 테마 | 유지 |

## 3. 오프라인 캐시
| 테이블 | 캐시 | 비고 |
|---|---|---|
| stores · menus | 예(목록 표시용, `updated_at` 증분) | 가격은 표시만, 주문 합계는 항상 서버 |
| orders · order_items · deliveries | 아니오(온라인 전용, 상태는 실시간 조회) | — |
| order_contacts · payments | 아니오(개인정보·결제) | 캐시 금지 |
