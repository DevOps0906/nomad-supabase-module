# news 기존 DB → nomad_core 이식 대응표 (task-015 P4)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\2500_news.sql`(스키마 `news`, 표 40, 0~14절).
정본 설계: `docs/design/03-port/news-port-notes.md`(D10·N1~N3·변환 규칙). 원본과 다르면 메모를 따랐다.
이식: `org/0001_news.sql`(조직형, 표 42 = 원본 40 + `staff_invitations` + `membership_events`) · `org/0002_ai.sql`(원본 14.2 라우팅 14행). 스키마 `nomad_news` 하나(노출, anon 은 공개 RPC 10개만).
검증: `bash products/news/run_check.sh` (begin → 기존 스키마 drop → 0001·0002 → `check_org.sql` → rollback). 사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler(service_role), 워커=크론·발송(service_role), 공개=방문자·독자(anon/authenticated RPC).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('news') | 대체 | nomad_core.products('news') | 새로 등록, 플랜 A·B·C |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | 하위 표 복합 FK 그대로 |
| core.org_members(active) + staff | 대체 | nomad_core.organization_role(owner·admin·editor) + staff(active) | `staff_role`·`is_newsroom`. 조직 비활성이면 역할 없음 |
| publisher=owner · editor=admin · 나머지=member | 대체(N3) | publisher=owner, 도메인 역할 5종=core editor | core admin 을 주지 않는다 |
| core.has_entitlement(org,'news') · plans.features jsonb | 대체 | org_has_feature('news','newsroom'/기능) + plan_limits 키 | 수치 시드 없음, 키 없으면 0 |
| core.invite_member · accept_invite · change_member_role | 대체 | core create_invitation(email, editor)·accept_invitation + `staff_invitations` | 도메인 역할 변경은 staff 표만 |
| core.remove_member | 이관 | nomad_core.remove_member | 본인 탈퇴 또는 발행인(owner) |
| approve_newspaper 의 core 쓰기(조직·멤버·구독·이용권·크레딧) | 삭제(N2) | — | 조직은 신청 전 create_team_organization, 플랜·체험·크레딧은 외부 결제 서버(D1) |
| core.encrypted_credentials(app 'news') | 대체 | nomad_core.provider_credentials('toss_merchant') | api_providers 1행 추가(D10 예외). 설정은 core owner·admin |
| core.rate_limit_hit | 대체 | nomad_core.rate_limit_take | 키 접두 `news:` 그대로 |
| core.profiles.email | 대체 | auth.users.email(호출자 본인 행만, ensure_reader 안) | auth.users 노출 없음 |
| core.is_platform_admin | 삭제 | — | 운영자 판정은 서버(service_role) |
| core.guard_privileged_write · set_updated_at | 삭제 / 대체 | — · nomad_core.touch_updated_at | 사용자 표 쓰기 grant 0(검사로 고정) |
| core.storage_org_id · org-files 제한 정책 | 삭제 | 경로 CHECK `is_org_path`(`<org>/news/<folder>/…`) | 버킷 정책은 코어 버킷 계약 확정 시 |
| core.ai_routing_settings(app 'news') · plans 14절 | 이관(0002) / 대체 | ai_routing_settings(product 'news') / 머리 기능 시드 | 기능 키 원본 그대로(news.*·wiki.*·dify.aux) |

## 테이블 (news → nomad_news, 이름 유지)
| 원래 이름 | 분류 | 사용처 | 변화 |
|---|---|---|---|
| newspaper_applications | 이관(변경) | 웹(신청·철회) · 서버(승인·반려) | applicant_org_id 삭제, organization_id not null(신청 조직), 조직당 대기 1건 |
| newspapers | 이관(slug·plan_lapsed_at 추가) | 웹 · 공개(get_public_newspaper) · 워커 | slug 컬럼(유일, 불변) — 원본은 core.organizations.slug. plan_lapsed_at = 구독 끊김을 처음 본 시각(run_scheduled_publishing 이 매분 기록·해제, 엠바고 판정) |
| staff | 이관 | 웹 · 공개(공개 프로필) | core 역할 대응 변경(N3) |
| staff_invitations | 신규 | 웹(발행인·편집인 읽기) | core 초대 1:1, 초대 취소 시 cascade |
| sections · regions · tags · wire_contracts · media_assets · articles · article_revisions · article_regions · article_tags · home_layouts · print_editions · live_updates | 이관 | 웹(RPC) · 공개 RPC | anon 컬럼 grant 삭제 |
| readers · membership_tiers · memberships · donations · paywall_rules | 이관 | 웹 · 서버(결제) · 공개 | memberships.billing_credential_id → provider_credentials 복합 FK. memberships 는 authenticated 컬럼 grant(billing_credential_id·platform_fee_bps·last_event_id·external_ref 제외) |
| membership_events | 신규 | 서버(record_membership) | 처리한 결제 이벤트 id(조직별 유일) — 예전 이벤트 재전송도 멱등. service_role 전용 |
| ad_slots · advertisers · ad_campaigns · ad_creatives · ad_daily_stats · local_listings · public_notices | 이관 | 웹 · 서버 · 공개(serve_ads·list_public_items) | — |
| newsletter_lists · newsletter_subscriptions · newsletter_issues · push_subscriptions | 이관 | 웹 · 서버 · 공개(확인·수신 거부) | 토큰 해시 컬럼 grant 없음 유지 |
| comments · comment_reports · tips · life_events · syndication_settings · correction_requests · election_periods · article_view_hourly · events | 이관 | 웹 · 서버 · 공개 | — |
- 뷰 `correction_sla`(security_invoker) 유지. 모든 표 RLS, 정책은 authenticated SELECT 만, anon 정책·grant 0.

## 함수 (news → nomad_news)
| 원래 이름 | 분류 | 실행 | 변화 |
|---|---|---|---|
| request_newspaper | 이관(변경) | authenticated(조직 owner) | 인자 p_org 추가(팀 조직), p_plan_code 는 희망 플랜 기록만 |
| approve_newspaper · reject_newspaper · set_newspaper_status | 이관(변경) | service_role | approve: p_plan_code 삭제, nomad_news 표만 씀 |
| invite_staff | 이관(변경) | authenticated(발행인) | 인자 user_id → email, 반환 jsonb(core 초대 토큰) |
| accept_staff_invite → accept_staff_invitation(token) | 대체 | authenticated | core accept_invitation 뒤 staff 행 |
| set_staff_role · remove_staff | 이관(변경) | authenticated | core 역할 변경 없음 / 제거는 본인·발행인만 |
| plan_feature | 대체 | — | has_feature(기능) · limit_int(plan_limits, 기본 0) · plan_active(newsroom) |
| is_public_newspaper · article_is_live · is_article_live · is_profile_complete | 이관(변경) / 삭제 | service_role(내부) | 플랜 조건 제거(N1), anon EXECUTE 회수(D8). is_profile_complete 는 미사용이라 삭제 |
| (신규) get_public_newspaper · list_public_articles · list_public_items | 신규(D8) | anon·authenticated | 원본 anon 표 SELECT 대체, 공개 컬럼만 jsonb |
| read_article · serve_ads · list_comments · most_read · search_articles · confirm_newsletter · unsubscribe_newsletter | 이관 | anon·authenticated | read_article 에 media(잠기면 빈 배열)·live_updates 추가 |
| 그 밖 편집국·독자 RPC 60여 개 · 트리거 | 이관 | authenticated / service_role / 트리거 | assert_staff 에 구독 끊김 잠금(NW014), 예외는 아래 |
| (신규) assert_staff_row | 신규(내부) | service_role | 행 id 로 부르는 RPC 17개: 그 조직 편집국이 아니면 P0002(존재 비노출), 인가 뒤 행 잠금 |

## 플랜 기능 · plan_limits 키 (수치 시드 안 함)
| 원본 features 키 | 새 위치 | A / B / C | DB 강제 위치 |
|---|---|---|---|
| (has_entitlement news) | 기능 `newsroom` | O / O / — | assert_staff·독자 쓰기 RPC(NW014) |
| news_print_pdf | 기능 `print_pdf` | O / — / — | save_print_edition(NW014) |
| news_regional_editions · news_api · news_support_reports | 기능 같은 이름(news_ 제거) | O / — / — | 서버 |
| news_staff_max | plan_limits(키 없으면 0) | 시드 없음 | invite_staff(NW014, 발행인 포함 인원 + 유효 초대) |
| news_reader_fee_bps | plan_limits(키 없으면 0) | 시드 없음 | record_membership·record_donation |
| news_newsletter_monthly · news_custom_domains · news_storage_gb · ai_monthly_credits · theming_level | plan_limits 같은 키 | 시드 없음 | 서버 |

## 구독 끊김(N1) · 열어 둔 경로
- 구독 없음·inactive·만료 = C(기능 없음). 공개 RPC 의 공개 판정(is_public_newspaper)은 플랜과 무관 → 공개 기사·법정 공고·정정문 열람 유지. 기존 멤버십 독자의 프리미엄 본문 유지. 편집국 SELECT 정책에 플랜 조건 없음.
- 잠금(NW014): 편집국 쓰기 RPC 전부(서버 예약 게시 포함 → approved/draft 로 되돌림), 초대·수락, 새 독자 가입·재가입, 댓글·업소 신청·경조사 신청·제보·뉴스레터 구독·푸시 등록, 업소 게재 활성화, 새 멤버십·(재)활성화·기간 연장, 새 후원 주문, 숨긴 라이브 업데이트 다시 보이기. 끊긴 뒤(plan_lapsed_at 이후) 풀리는 엠바고 기사는 공개되지 않는다.
- 열림: 게시 중단·보관(unpublish·archive), 정정 청구 접수·처리·정정문 기록, 댓글 임시조치·숨김(moderate)·신고·본인 삭제, 독자 차단, 라이브 업데이트 숨김, 편집국 제거·내 프로필, 독자 탈퇴, 수신 거부·확인, 멤버십 해지·만료·연체 기록, 기존 후원 결제·환불 기록, 주간 자체기사 지표, 조회·광고 통계 적재.

## 버킷
- 원본 `public-assets`·`org-files` 버킷 이름은 media_assets.bucket CHECK 에 그대로 남겼다(코어 버킷 계약 확정 시 바꿈). 원본 Storage 제한 정책(제보·정정 첨부 데스크 이상)은 옮기지 않았다 — 계약 확정 때 다시 넣어야 한다.
- 경로 컬럼(certificate_path·photo_path·storage_path·pdf_path·media_path·attachment_path(s)·image_path)은 CHECK 로 `<organization_id>/news/<folder>/…`만 받는다(첫 폴더 = 자기 조직, `..` 금지).

## 앱 변경
- 함수 계약 변경: `request_newspaper(p_org uuid, …원본 9개…, p_message, p_plan_code text default null)` — p_org 가 맨 앞에 새로 들어가고 p_plan_code(희망 플랜, 기록만)는 선택. `approve_newspaper(p_application_id, p_note)` — p_plan_code 삭제, 반환 타입은 원본과 같은 `newspapers` 행. `invite_staff` 반환은 `staff` 행 → jsonb(token), `accept_staff_invite(org)` → `accept_staff_invitation(token)`.
- 남의 조직 행 id 로 부르는 편집국 RPC(submit·review·publish·archive_article 등 17개)는 원본 42501 → P0002. 화면은 둘 다 "찾을 수 없음"으로.
- `search_articles` 의 p_offset 은 0~1000(밖이면 NW015). 프리미엄 기사는 본문이 검색 색인에서 빠진다(제목·부제·요약만).
- `news.*` → `nomad_news.*`, `org_id` → `organization_id`. 방문자·독자 화면은 표 직접 조회 대신 `get_public_newspaper(slug)` → `list_public_articles`·`read_article`·`list_public_items`.
- 개설: `nomad_core.create_team_organization` → `request_newspaper(org, …)` → 운영자 `approve_newspaper` → 결제 서버가 nomad_core 구독 부여.
- 편집국 초대: `invite_staff(org, email, role, byline)` 반환 token 으로 메일 → 수락 화면 `accept_staff_invitation(token)`. 가맹 키: `nomad_core.set_provider_credential(org, 'toss_merchant', label, key)`(owner·admin).

## 오류 매핑(앱)
| 코드·메시지 | 원인 | 화면 처리 |
|---|---|---|
| P0001 `invalid invitation` · `invitation expired` · `organization inactive` · `email not confirmed` · `already a member` · `seat limit reached` | core accept_invitation(편집국 초대 수락) | 초대 링크 무효·만료 / 이메일 인증 요청 / 좌석 한도 안내 |
| 42501 `email mismatch` | 초대받은 이메일과 로그인 계정이 다름 | 초대받은 계정으로 다시 로그인 안내 |
| P0001 `member not found` · `last owner`, 42501 `forbidden` | core remove_member(remove_staff 안) | 이미 나간 구성원 / 마지막 발행인 제거 불가 / 권한 없음 |
| NW014 | 구독 끊김 잠금(새 발행·편집·초대·새 결제·새 독자 등) 또는 플랜 기능 없음(print_pdf)·인원 한도(news_staff_max) | 구독 갱신 안내(발행인), 독자 화면은 "지금은 이용할 수 없음" |
| NW011 | rate_limit_take 한도 초과(개설 신청·댓글·신고·업소·경조사·뉴스레터·제보·정정 청구) | 잠시 후 다시 시도 |
| P0002 | 행 없음 또는 남의 조직 행(W7) | 찾을 수 없음 |

## 팀장 확인 필요
1. 플랜 대응: A = 원본 pro(+enterprise), B = starter·standard(체험 포함), C = 구독 없음(기능 없음). core 가 "구독 없음 = C"라 news 의 C 는 유료 플랜이 될 수 없다. starter 와 standard 를 한도로 나누려면 B 를 둘로 나눠야 함.
2. `create extension if not exists pg_trgm with schema extensions`(원본 결정 D-7, 제목 부분 일치 GIN) — 로컬 DB 에 없던 확장. core 마이그레이션으로 옮길지, 이식본에 둘지.
3. N1 열어 둔 경로 목록(위 장)과 서버 예약 게시 실패 시 approved 되돌림, 기존 승인 광고(serve_ads)는 끊김 뒤에도 노출되는 점.
4. 초대·타인 제거는 발행인(core owner)만 가능 — core create_invitation·remove_member 가 owner·admin 만 허용하고 N3 가 admin 을 주지 않으므로 원본의 "편집인도 초대·제거"는 사라졌다. 발행인 이전(소유권 이전) 절차 미정.
5. `memberships.billing_credential_id` 는 신문사 toss_merchant 키를 가리키게 했다(독자 빌링키 저장 위치는 원본에서도 불명확 — 결제 서버 설계 때 확인).
6. 버킷: 위 "버킷" 장(원본 Storage 제한 정책 미이식, 버킷 이름 미확정).
7. `get_public_newspaper.reader_signup_open`(= 플랜 활성 여부)이 공개 응답에 들어간다 — 가입 버튼 표시용. 노출이 싫으면 빼고 가입 실패(NW014)로만 처리.
8. 원본 표 수는 머리 주석 기준 40개로 대조(37 + 이력·연결 3). 청사진 `supabase/migrations` 에는 nomad_news 가 없어 중복 등록 문제 없음.
9. 데스크 자기 기사 자기 승인: 원본 정책 유지(review_article 이 작성자와 승인자를 구분하지 않는다). 막으려면 approved_by <> created_by 검사 1줄.
10. rate_limit_take 뒤 raise: 같은 트랜잭션이라 실패한 호출(검증 오류)의 카운트는 롤백되어 세지 않는다. PG 에 자율 트랜잭션이 없어 DB 만으로는 실패 시도를 셀 수 없고, take 를 검증 뒤로 옮겨도 결과는 같아 그대로 두었다. 실패 시도 무차별 대입은 Route Handler·엣지 레이트 리밋이 막아야 한다(C3).
11. 엠바고(S2): 구독 끊김 시각을 core 가 주지 않아 `newspapers.plan_lapsed_at` 을 두고 run_scheduled_publishing(매분)이 기록한다. 기록 전(최대 1분)에는 끊긴 신문사의 엠바고 기사가 모두 비공개(fail-closed), 기록 시각은 실제 끊김보다 최대 1분 늦다. 끊긴 시각은 실제 끊김이 아니라 예약 실행 시각(now())이라, 예약 실행이 밀리면 그만큼 창이 늘어난다(끊김 중 풀린 엠바고가 기록 순간 공개될 수 있음).
12. 도메인 역할 재가입(S1): core 멤버십에 생성 시각이 없어, staff 합류(joined_at) 뒤 편집국 초대가 아닌 core 초대로 수락한 기록이 있으면 역할을 인정하지 않는다. 초대 없이 core 표에 직접 넣은 멤버십(운영 수작업)은 이 검사를 피한다. 또 core `revoke_invitation` 이 수락된 초대 행도 지우므로, owner 가 재가입 초대를 지우면 판정 근거가 사라져 예전 역할이 살아난다(owner 만 가능, 위험 낮음. core 에서 수락된 초대 삭제 금지가 근본 수정).
13. 결제 반영 멱등: `record_membership` 은 이벤트 id 없으면 NW015(인자 default 는 원본 계약 순서 유지용). 기자·기고자는 draft 가 아닌 기사가 싣고 있는 자산도 못 고친다(승인~게시 사이 창).
