# 기능 카탈로그 (확정 2026-11-13)

서비스 11개의 기능 묶음 → 잠그는 테이블 → A/B/C 플랜 대응표. 요금·가격 수치는 쓰지 않는다(`billing-credits.md` 참고). 테이블 출처는 `supabase/migrations/20261115000101~111_*.sql`.

## 1. 규칙
1. 플랜 대응: C=무료 · B=프로/팀 · A=비즈니스. 구독이 없는 조직은 C로 취급한다.
2. 잠금 단위는 테이블이 아니라 **기능 묶음**(feature_code)이다. 쓰기 가능한 테이블은 정확히 한 기능에 속한다.
3. 잠금은 해당 테이블의 insert/update에만 건다. select는 멤버십만 확인한다(다운그레이드 후에도 기존 데이터 열람 가능).
4. 서버 전용 쓰기 테이블(`classroom.quiz_attempts`, `commerce.orders`, `baedal.orders`·`order_items`·`deliveries`)은 잠금 대상이 아니다.
5. 개인형 4개(humscore·jangter·baedal·personal)는 1인 조직 구독을 쓴다. jangter·baedal은 잠금 없음(전 기능 C). 판매자 도구는 테이블이 생기면 새 기능으로 추가한다.

표기: ○ 포함 · ✕ 미포함. 이름은 한국어, feature_code는 영어 snake.

## 2. 조직형 서비스

### contentflow (블로그 자동화)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| blog_core | 블로그·주제·글 작성 | blogs, topics, posts | ○ | ○ | ○ |
| blog_team | 블로그 멤버 관리 | blog_members | ○ | ○ | ○ |
| publish_automation | 발행 기록·자동 발행 | publish_logs | ✕ | ○ | ○ |
| quality_review | 글 검수 | reviews | ✕ | ✕ | ○ |

### flora (집필)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| writing_core | 프로젝트·챕터·자산 | projects, chapters, assets | ○ | ○ | ○ |
| persona_style | 집필 페르소나(문체 고정) | personas | ✕ | ○ | ○ |
| pipeline_auto | 파이프라인 자동 실행 | pipeline_runs | ✕ | ○ | ○ |
| audiobook | 오디오북 | audiobooks | ✕ | ✕ | ○ |

### knowflow (지식 관리)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| knowledge_base | 지식 공간·자료 수집 | spaces, sources, chunks | ○ | ○ | ○ |
| knowledge_chat | 지식 대화 | chats, messages | ○ | ○ | ○ |
| space_reports | 공간 분석 보고서 | reports | ✕ | ○ | ○ |

### classroom (강의)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| course_core | 강좌·회차·자료·수강 등록 | courses, sessions, materials, enrollments | ○ | ○ | ○ |
| quiz_bank | 퀴즈 문항 | quiz_items | ✕ | ○ | ○ |
| pre_post_assessment | 사전·사후 평가 | assessments | ✕ | ✕ | ○ |
(`quiz_attempts`는 서버 전용 — 잠금 제외)

### analytics (데이터 분석)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| data_analysis | 프로젝트·데이터셋·분석 실행 | projects, datasets, analysis_runs | ○ | ○ | ○ |
| dashboard | 대시보드·위젯 | dashboards, widgets | ✕ | ○ | ○ |
| report_output | 분석 보고서 | reports | ✕ | ○ | ○ |
| share_links | 외부 공유 링크 | share_links | ✕ | ✕ | ○ |

### sceneflow (영상 제작)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| video_project | 프로젝트·자산·장면 | projects, assets, scenes | ○ | ○ | ○ |
| ai_auto_edit | AI 자동편집 | edit_jobs | ✕ | ○ | ○ |
| render_export | 렌더링 | render_jobs | ○ | ○ | ○ |
| channel_upload | 채널 연결·업로드 예약 | channels, uploads | ✕ | ✕ | ○ |

### commerce (커머스 자동화)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| sourcing | 소싱·판매 상품 | sourcing_items, products | ○ | ○ | ○ |
| marketplace_listing | 마켓 계정·상품 등록 | marketplace_accounts, listings | ✕ | ○ | ○ |
| commerce_automation | 자동화 작업 | automation_jobs | ✕ | ✕ | ○ |
(`orders`는 서버 전용 — 잠금 제외)

## 3. 개인형 서비스 (1인 조직 구독 전제)

### humscore (악보)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| score_editor | 악보 작성·설정 | scores, settings | ○ | ○ | ○ |
| recording | 녹음 | recordings | ✕ | ○ | ○ |
| score_export | 악보 내보내기 | exports | ✕ | ○ | ○ |

### personal (풀이·여행)
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| divination | 꿈·사주·타로 풀이 | readings, birth_profiles | ○ | ○ | ○ |
| report_save | 풀이 리포트 저장 | saved_reports | ✕ | ○ | ○ |
| trip_planner | 여행 계획 | trips, trip_days | ✕ | ○ | ○ |

### jangter (중고 거래) — 거래는 잠그지 않음
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| trade_core | 판매 글·사진·관심·채팅·후기 | listings, listing_photos, favorites, chat_rooms, messages, reviews | ○ | ○ | ○ |

### baedal (배달) — 거래는 잠그지 않음
| feature_code | 이름 | 잠그는 테이블 | C | B | A |
|---|---|---|---|---|---|
| order_core | 가게·메뉴·후기 | stores, menus, reviews | ○ | ○ | ○ |
(`orders`·`order_items`·`deliveries`는 서버 전용 — 잠금 제외)

## 4. 결정 기록 (2026-11-13)
- sceneflow 렌더링·contentflow 블로그 멤버는 C로(무료도 결과물·협업 가능, 팀 크기는 좌석 한도가 제한).
- jangter·baedal 판매자 도구는 테이블이 없어 삭제. 두 서비스는 잠금 없음.
- knowflow 지식 대화는 C. AI 비용은 크레딧 차감(서버가 assistant 답변을 쓸 때)으로 제한.
- 퀴즈(B)/평가(A) 분리, 커머스 마켓 연동 B, 여행 계획 B, A 전용 기능(외부 공유·오디오북·채널 업로드·자동화·검수·평가)은 초안대로.
- "블로그 N개" 같은 수량 한도는 범위 밖(후속).
- 구현: C 기능은 멤버면 항상 열리므로 RLS 잠금은 B·A 기능의 테이블 insert/update에만 건다.
