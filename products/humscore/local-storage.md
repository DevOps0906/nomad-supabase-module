# humscore 로컬 저장소 설계

공통 규칙: 키 `nomad.humscore.<entity>.v<N>`, 테마만 공통 키 `nomad.theme`(system · light · dark; 로그인 시 `nomad_core.profiles.theme`와 맞춘다). 비밀(토큰·API 키)은 localStorage·IndexedDB·tauri store 평문에 두지 않는다.

## 1. 저장 위치(플랫폼별)
| 대상 | 웹(Next.js) | 앱(Capacitor iOS/Android, 원격 로드) | 데스크톱(Tauri, 계획) |
|---|---|---|---|
| 악보 캐시·동기화 큐 | localStorage(현행 유지). 2000곡·곡당 큰 jsonb라 용량 한계 시 IndexedDB `nomad-humscore` 로 이동 | 원격 로드 웹뷰 localStorage 그대로 + 오프라인 안내는 native-shell | tauri store(파일) 또는 IndexedDB |
| 설정·UI 상태 | localStorage | Capacitor Preferences(웹뷰 정리 대비) | tauri store |
| 비밀(LLM 키 등) | 두지 않는다 | 보안 저장소(Keychain/Keystore 플러그인) | OS 키체인(tauri 보안 저장소) |
| 인증 세션 | @supabase/ssr 쿠키 | 쿠키(웹뷰) | 앱 보안 저장소 |

## 2. 키 이관표(현재 코드 기준 → 새 키)
| 현재 키(실제 코드) | 새 키 | 내용 | 로그아웃 시 |
|---|---|---|---|
| `humscore.scores.v1` | `nomad.humscore.scores.v1` | 악보 캐시(로그인 시 서버와 동기화) | 삭제 |
| `humscore.dirty.v1` | `nomad.humscore.scores_dirty.v1` | 업로드 대기 id | 삭제 |
| `humscore.deleted.v1` | `nomad.humscore.scores_tombstones.v1` | 삭제 표식(오프라인 삭제 전파) | 삭제 |
| `humscore.owner.v1` | `nomad.humscore.owner.v1` | 캐시 소유자 id(계정 전환 감지) | 삭제 |
| `humscore.scores.mock.v1` · `humscore.authMock.signedOut` | 개발용 목업 — 이관 안 함 | — | — |
| `humscore.llm.v1` | **폐기** | LLM API 키(openai·claude·gemini) = 비밀 → localStorage 금지. 앱은 보안 저장소, 서버 위임이면 BYOK `provider_credentials`로 이전 | 삭제(즉시 폐기, 이관 시 1회 읽어 옮기고 지움) |
| `humscore.keysDraft` | `nomad.humscore.keys_draft.v1` | 조 선택 화면의 작곡 편집 초안(음표·BPM·가사·제목 등). **비밀 없음 확인**(필드 목록에 키·토큰 없음). `keys`는 음악 조(key)다 | 삭제(개인 창작물) |
| `humscore.prefs.v1` | `nomad.humscore.preferences.v1` | 사용자 설정(코드 실제 키는 `prefs`). 테마는 여기 말고 `nomad.theme` | 유지 가능(비식별) |
| `humscore.instrument` | `nomad.humscore.instrument.v1` | 선택 악기 | 유지 가능 |
| `humscore.record.source` | `nomad.humscore.record_source.v1` | 녹음 입력 소스 | 유지 가능 |
| `humscore.record.meter` | `nomad.humscore.record_meter.v1` | 박자 | 유지 가능 |
| `humscore.latencyMs` | `nomad.humscore.latency_ms.v1` | 오디오 지연 보정(기기 고유) | 유지(기기 값) |
| `humscore.sustainRatio` | `nomad.humscore.sustain_ratio.v1` | 서스테인 비율 | 유지 |
| (신규) | `nomad.theme` | system · light · dark(현재 레포에 테마 구현 없음) | 유지 |

로그아웃 삭제 대상은 계정에 속하는 캐시·초안(`scores`·`scores_dirty`·`scores_tombstones`·`owner`·`keys_draft`)이다. 기기 값은 남긴다.

## 3. 오프라인 캐시 대상 테이블
| 테이블 | 캐시 | 동기화 컬럼 |
|---|---|---|
| nomad_humscore.scores | 예(핵심) | `updated_at`(클라이언트 시각, LWW 트리거) · `deleted_at`(소프트 삭제) · 증분 인덱스 `(user_id|organization_id, updated_at)` |
| nomad_humscore.setlists | 예 | `updated_at`(서버 `nomad_core.touch_updated_at`) · `deleted_at` · 같은 증분 인덱스 |
| share_links · transcription_jobs | 아니오(온라인 전용) | — |

## 4. 동기화 규칙(마지막 쓰기 우선)
1. 로컬 변경은 `dirty`에 id를 올리고, 온라인이 되면 scores를 upsert한다. 서버 `scores_lww_guard`가 `updated_at`이 더 새롭지 않으면 조용히 건너뛰므로 클라이언트는 반환 행이 없으면 stale로 본다(현행 동작).
2. 삭제는 `deleted_at`·`updated_at`을 함께 올리는 update(소프트 삭제). 삭제 표식은 서버 반영 후 제거한다.
3. 내려받기는 `updated_at > 마지막 동기화 시각`으로 증분 조회, 서버 시각 기준(미래 5분 초과는 서버가 보정).
4. setlists는 서버가 `updated_at`을 now()로 덮으므로 충돌은 서버 시각 기준 마지막 쓰기.
5. 계정이 바뀌면(`owner` 불일치) 캐시·dirty를 비우고 새로 받는다.
6. org안: 캐시 키에 조직을 구분해야 하면 `nomad.humscore.scores.<orgId>.v1`로 확장한다(personal 조직 1개만 쓰는 동안은 현행 키).
