# hospital 로컬 저장소 설계 (격리형 · 서버 전용)

키 규칙: `nomad.hospital.<entity>.v1`. 공통 테마 키: `nomad.theme` = `system` | `light` | `dark`(기본 `system`).
환자 정보(이름·전화·생년월일·메모·연락·예약)는 의료 개인정보라 **어떤 환경에도 로컬 저장하지 않는다**. 화면은 매번 앱 서버를 거쳐 조회하고, 조회는 DB 감사 로그에 남는다.
역할·담당 관계·HMAC 키·보존 기간도 로컬에 두지 않는다(항상 서버 판정).

## 저장 위치
| 환경 | 일반 데이터 | 설정·테마 | 비밀(세션 토큰) |
|---|---|---|---|
| 웹 | 없음 | localStorage `nomad.theme` · `nomad.hospital.ui.v1`(목록 정렬·표시 열) | httpOnly 쿠키(앱 서버 세션)만. localStorage 금지 |
| 앱(Capacitor) | 없음 | Capacitor Preferences `nomad.theme` · `nomad.hospital.ui.v1` | 보안 저장소(Keychain/Keystore)만 |
| 데스크톱(tauri) | 없음 | tauri store `nomad.theme` · `nomad.hospital.ui.v1` | OS 키체인만 |

## 오프라인 캐시 대상
없음. 오프라인이면 읽기·쓰기 모두 막고 안내한다(오프라인 큐 없음 — 감사 행위자·시각이 서버 기준이어야 함).

## 로그아웃 시 삭제 키
`nomad.hospital.*`(전부) + 보안 저장소 세션 토큰. **`nomad.theme`은 유지**.
