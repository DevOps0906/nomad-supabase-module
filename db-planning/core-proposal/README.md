# core 제안 SQL (참고용 · 적용하지 않음)

이 저장소의 실제 공통 스키마는 `supabase/migrations/20261112000100_nomad_core.sql`(`nomad_core`)입니다.
여기 SQL은 기획 단계에서 만든 **대안 초안**(`core` 스키마)이며 `supabase/migrations/`에 넣지 않습니다.

## 반영 후보 (nomad_core에 없을 때만 새 번호 마이그레이션으로 추가)
| 제안 | 내용 | 확인할 것 |
|---|---|---|
| 가입 트리거 | 가입 시 프로필 + 개인 조직(1인 조직) + owner 멤버십 + 무료 구독 | nomad_core가 이미 하는지 |
| `invitations` + 수락 함수 | 이메일 초대, 만료, 좌석 한도 검사 | 좌석 한도의 기준(플랜 A/B/C) |
| `credit_ledger` | 조직 공유 크레딧 원장 | 단품 이용권(addon)과의 관계 |
| 헬퍼 `is_member`·`has_role` | RLS 공통 함수 | nomad_core 기존 함수명 |

## 이름 대응 (초안 → 실제)
| 초안 | 실제 |
|---|---|
| `core` | `nomad_core` |
| `core.profiles(user_id)` | `nomad_core.profiles` |
| `core.organizations` | `nomad_core.organizations` |
| `core.memberships` | `nomad_core.memberships` |
| `core.plans` 4단계(free/pro/team/business) | `nomad_core.plans` A/B/C 플랜 (기존 기준 우선) |

`projects/*/schema.draft.sql`은 초안 이름(`core.*`)으로 쓰여 있습니다. 확정해 마이그레이션으로 옮길 때 위 표대로 치환하고
날짜 형식 파일명(`YYYYMMDDHHMMSS_*.sql`)과 `docs/diagrams/erd.mmd` 갱신 절차를 따르세요.
