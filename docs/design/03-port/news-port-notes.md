# local-news 이식 설계 메모 (task-015 P4, 2026-11-15)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2500_news.sql`(5,222줄, 표 40). 대상: `products/news/`(스키마 `nomad_news`, org안).
기계적 변환이 아니다. challenger(2026-11-15) 판정 REVISE → 아래 결정으로 재설계한다.

## 1. 사용자 결정 (2026-11-15)
| 번호 | 결정 |
|---|---|
| D10 | core 스키마 변경 없음. R-1~R-11은 앱·후속 |
| N1 구독 끊김 | 이미 공개된 기사·법정 공고·정정문과 기존 유료 독자 열람은 유지. 새 발행·편집·새 결제·새 독자 가입은 잠금. 편집국 읽기는 유지(쓰기만 잠금) |
| N2 조직 개설 | 신청자가 `nomad_core.create_team_organization`으로 조직(owner)을 만든 뒤 news 개설 신청. 플랫폼 승인은 `nomad_news` 표 상태만 바꾼다(service_role). 체험·플랜 부여는 외부 결제 서버(D1). 슬러그 유일성은 `nomad_news.newspapers` |
| N3 가맹 키·역할 | news 제품 파일에서 `nomad_core.api_providers`에 `toss_merchant` 1행 추가(데이터만, D10 예외). 편집국 도메인 역할 6종은 core `editor`에 대응(core admin을 주지 않음). 가맹 키 설정은 core owner·admin만 |

## 2. 변환 규칙 (challenger 지적)
- D8: anon 표 grant 0. 원본 anon SELECT(컬럼 grant 16표·전체 grant 5표)는 공개 RPC로 바꾼다(반환은 공개 컬럼만, jsonb). 조직 판정 헬퍼(is_public_newspaper 등)의 anon EXECUTE는 회수.
- core 직접 쓰기 금지: approve_newspaper·invite·change_role의 core 표 쓰기 제거. 편집국 초대는 core 초대(email+token, `accept_invitation`) + `nomad_news.staff` 행. `invite_member(user_id)`·'member' 역할 없음.
- `guard_privileged_write` 대응 없음 → 쓰기는 definer RPC만, 사용자 표 쓰기 grant 0을 검사로 고정.
- `rate_limit_hit`(서버 전용) → 사용자 RPC는 `rate_limit_take`.
- `encrypted_credentials` → `provider_credentials`(app_id 없음, product 키 확인).
- Storage: `storage_org_id`·`org-files` 없음 → 경로 `<organization_id>/news/<folder>/<파일>` 조직 접두 CHECK만, 버킷 정책은 코어 버킷 계약 확정 시.
- `core.apps` → 제품 등록(다른 제품 방식), `is_platform_admin`·`profiles.email`·`org_members.status` 없음 → 서버(service_role) 판정·auth.users 미노출.
- 수치 한도 시드 없음. 키 없을 때 fail-closed(0/false)로(`news_staff_max` null=무제한 금지). 원본 플랜 5종 → A/B/C 대응은 existing.md에 적고 팀장 확인.
- P2·P3 교훈 전부(`tasks/NOW.md`): BEFORE 트리거 비멤버 42501 선거부, 결과 전달 잡 for update, 소프트 삭제 owner·admin, 사용자 insert에 id grant 없음 등.

## 3. 독자 범위 (문서에 명시)
독자 = auth 사용자 + `nomad_news.readers(organization_id, user_id)`, 조직 멤버 아님. 같은 auth 계정이 여러 신문사·제품에 공유되고 가입 시 개인 조직이 생긴다(core provision). 신문사 발행인·편집인은 자기 신문사 독자 email만 본다.

## 4. 필수 검사(check_org.sql)
다른 조직 독자·편집국 접근 0 · anon 표 접근 0(모든 표) · 사용자 표 쓰기 grant 0 · 구독 끊김 후 공개분 열람 유지·새 발행 잠금 · 가맹 키 설정은 owner·admin만(editor 거부) · 공개 RPC가 비공개 컬럼(body 제외 조건 등)을 내지 않음.
