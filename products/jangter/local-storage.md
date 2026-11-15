# jangter 로컬 저장소 설계

공통 규칙: 키 `nomad.jangter.<entity>.v<N>`, 테마만 공통 키 `nomad.theme`(system · light · dark; 로그인 시 `nomad_core.profiles.theme`와 맞춘다). 비밀(토큰·API 키)은 localStorage·IndexedDB·tauri store 평문에 두지 않는다.
레포가 없어 "현재 키"는 없다. 아래는 새로 만들 때의 정본이다.

## 1. 저장 위치(플랫폼별)
| 대상 | 웹(Next.js) | 앱(Capacitor iOS/Android) | 데스크톱(Tauri) |
|---|---|---|---|
| 목록 캐시·작성 초안 | localStorage(초안), 목록은 메모리 | Capacitor Preferences | tauri store |
| 채팅 메시지 캐시 | IndexedDB `nomad-jangter`(방별) | IndexedDB(웹뷰) | IndexedDB |
| 설정·UI 상태(동네 선택 등) | localStorage | Capacitor Preferences | tauri store |
| 인증 세션 | @supabase/ssr 쿠키 | 쿠키(웹뷰) | 앱 보안 저장소 |
| 비밀 | 두지 않는다 | 보안 저장소 | OS 키체인 |

## 2. 키 목록
| 키 | 내용 | 로그아웃 시 |
|---|---|---|
| `nomad.jangter.dong.v1` | 선택한 동네(목록 필터 `p_dong`) | 유지(비식별) |
| `nomad.jangter.listing_draft.v1` | 판매 글 작성 초안(제목·가격 정수 원·동네·사진 로컬 경로) | 삭제 |
| `nomad.jangter.recent_views.v1` | 최근 본 글 id(최대 50) | 삭제 |
| `nomad.jangter.owner.v1` | 캐시 소유자 user id(org안은 `<user>:<org>`) — 계정·조직 전환 감지 | 삭제 |
| IndexedDB `nomad-jangter` / `messages` | 방별 메시지 캐시(상대방 표시 이름 포함) | 삭제 |
| `nomad.theme` | 테마 | 유지 |

관심 글(favorites)은 서버가 정본이라 로컬 키를 두지 않는다.

## 3. 오프라인 캐시 대상 테이블
| 테이블·RPC | 캐시 | 동기화 기준 |
|---|---|---|
| list_listings · get_listing | 짧게(메모리, 화면 단위) | 다시 호출. offset 0~1000 상한이라 깊은 페이지는 동네 필터로 좁힌다 |
| messages | 예(읽은 방) | `created_at > 마지막 수신 시각`으로 증분 조회. 보내기는 온라인 전용(수정·삭제 없음) |
| chat_rooms(my_chat_rooms) · reviews · favorites | 아니오(온라인 조회) | — |

## 4. 규칙
1. 오프라인에서 쓴 메시지는 대기열에 두지 않고 "전송 실패"로 보여 재시도한다(서버 `created_at` 기준 순서).
2. 사진은 Storage 경로 `<user_id|organization_id>/<listing_id>/<파일>`로 올린 뒤 `listing_photos`에 행을 넣는다(경로 접두 CHECK).
3. 계정·조직이 바뀌면(`owner` 불일치) 초안·최근 본 글·메시지 캐시를 비운다.
