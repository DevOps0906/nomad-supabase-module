# sceneflow 기존 DB → nomad_core 이식 대응표 (task-015 P3)

원본: `D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\1200_video.sql`(스키마 `video`, 표 36개, 1~13절. 12·13절 ALTER·create or replace 는 최종 모양으로 합침).
이식: `org/0001_sceneflow.sql`(조직형만) · `org/0002_ai.sql`(원본 11절 라우팅 17행). 스키마 `nomad_sceneflow`(노출, anon 은 공개 RPC 2개만) · `nomad_sceneflow_private`(트리거·내부 도우미, 비노출).
D9: platform-docs 기준으로 새로 작성. 청사진 `supabase/migrations/*_sceneflow.sql` 과 스키마 이름이 같아 함께 설치하지 않는다(참고만).
검증: `bash products/sceneflow/run_check.sh` (begin → 기존 스키마 drop → 0001·0002 → `check_org.sql` → rollback). 사용처 약어: 웹=Next.js(authenticated), 서버=Route Handler(service_role), 워커=렌더·업로드 워커(service_role), 공개=방문자(anon RPC).

## 코어 참조 변환
| 원래 이름 | 분류 | 새 이름 | 비고 |
|---|---|---|---|
| core.apps('video') | 대체 | nomad_core.products('sceneflow') | 새로 등록 |
| core.organizations · org_id | 대체 | nomad_core.organizations · organization_id | 하위 표 복합 FK |
| has_org_role(member) · is_org_member | 대체 | nomad_core.organization_role(editor) | 정책 도우미 `has_access`·`can_write` |
| core.has_entitlement(org,'video') · plan_features jsonb | 대체 | nomad_core.org_has_feature(org,'sceneflow',기능) + plan_limits 키 | 작업 공간 기능 `studio`. 수치 시드 없음 |
| core.jobs · ai_runs · affiliate_links · encrypted_credentials | 대체 | nomad_core.jobs · ai_runs · affiliate_links · provider_credentials (id, organization_id) 복합 FK | cancel_upload 는 cancel_job, 채널 해제는 revoke_provider_credential(재폐기 no-op) |
| core.credit_ledger(bigint) · brandconnect_applications | 대체 | nomad_core.credit_ledger(uuid) · brandconnect_applications | 복합 키가 없어 트리거로 같은 조직 확인(`check_ledger_org`·`check_refs`, VD002) |
| core.guard_privileged_write · set_updated_at | 삭제 / 대체 | — · nomad_core.touch_updated_at | 사용자 쓰기 grant 없는 표는 RPC·service_role 만(nomad_core.is_service_caller). core 표 트리거·직접 쓰기 없음 |
| core.ai_routing_settings(app 'video') · plans AI 키 | 이관(0002) | nomad_core.ai_routing_settings(product_code 'sceneflow') | 기능 키 원본 그대로(video.*·chat·wiki.*·dify.aux·narration 등) |

## 테이블 (video → nomad_sceneflow, 36, 이름 유지)
| 원래 이름 | 분류 | 새 이름 | 사용처 | 소유 컬럼 user→org |
|---|---|---|---|---|
| channels | 이관(서버 쓰기, 한도 트리거) | 같은 이름 | 웹 읽기·설정·해제 RPC · 서버(연결) | org_id → organization_id |
| trend_videos | 이관(공용, radar 기능) | 같은 이름 | 웹 읽기 · 워커(수집) | 조직 없음 |
| radar_reports | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| sources | 이관(서버 쓰기, purge) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| clients | 이관(owner·admin 쓰기, agency, 소프트 삭제) | 같은 이름 | 웹 CRUD · set_client_status | org_id → organization_id |
| productions | 이관(서버 쓰기, request_id 멱등) | 같은 이름 | 웹 읽기 · 서버 · 워커 | org_id → organization_id |
| longform_projects | 이관(editor 쓰기, track_d, 신규 생성 안 함) | 같은 이름 | 웹 CRUD · 워커 | org_id → organization_id |
| longform_sections | 이관(editor 쓰기, track_d) | 같은 이름 | 웹 CRUD · 워커 | org_id → organization_id |
| longform_highlights | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| music_tracks | 이관(title 만 editor, track_e) | 같은 이름 | 웹 읽기·수정 · 워커(Suno) | org_id → organization_id |
| music_library | 이관(editor 쓰기, track_f, 소프트 삭제) | 같은 이름 | 웹 CRUD | org_id → organization_id |
| playlists | 이관(editor 쓰기, track_f, 소프트 삭제) | 같은 이름 | 웹 CRUD · 워커 | org_id → organization_id |
| playlist_items | 이관(editor 쓰기, track_f) | 같은 이름 | 웹 CRUD | org_id → organization_id |
| landing_pages | 이관(문구만 editor, coupang_landing) | 같은 이름 | 웹 · 공개(get_public_landing) | org_id → organization_id |
| linkinbio_profiles | 이관(owner·admin 쓰기) | 같은 이름 | 웹 CRUD · 공개(get_public_linkinbio) | org_id → organization_id |
| linkinbio_items | 이관(editor 쓰기) | 같은 이름 | 웹 CRUD · 공개 | org_id → organization_id |
| storyboard_templates | 이관(공용 카탈로그 5종 시드, storyboard 기능) | 같은 이름 | 웹 읽기 | 조직 없음 |
| edit_presets | 이관(editor 쓰기·삭제) | 같은 이름 | 웹 CRUD | org_id → organization_id |
| storyboards | 이관(editor 쓰기, storyboard, 소프트 삭제) | 같은 이름 | 웹 CRUD·RPC · 서버 · 워커 | org_id → organization_id |
| scenes | 이관(RPC 만) | 같은 이름 | 웹 읽기·save_scene 등 · 서버 | org_id → organization_id |
| scene_assets | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커(finish_scene_asset) | org_id → organization_id |
| storyboard_cuts | 이관(서버 쓰기, credit_ledger_id 이식 추가) | 같은 이름 | 웹 읽기 · 서버(렌더 RPC) | org_id → organization_id |
| storyboard_snapshots | 이관(읽기 전용 트리거) | 같은 이름 | 웹 읽기 · 서버 | org_id → organization_id |
| outputs | 이관(서버 쓰기, 결과 전달 가드) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| uploads | 이관(서버 쓰기, 컴플라이언스·승인 게이트) | 같은 이름 | 웹 읽기·RPC · 워커 | org_id → organization_id |
| upload_links | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 서버 | org_id → organization_id |
| compliance_checks | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| analytics_snapshots | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| workflows | 이관(editor 쓰기, 소프트 삭제) | 같은 이름 | 웹 CRUD | org_id → organization_id |
| banned_words | 이관(editor 추가, owner·admin 삭제) | 같은 이름 | 웹 · 워커(검사) | org_id → organization_id |
| client_channels | 이관(owner·admin, agency) | 같은 이름 | 웹 | org_id → organization_id |
| client_reviews | 이관(서버 쓰기, token_hash 컬럼 grant 제외) | 같은 이름 | 웹 읽기 · 서버(승인 링크) | org_id → organization_id |
| client_reports | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커 | org_id → organization_id |
| pronunciation_lexicon | 이관(editor 쓰기·삭제, 2,000개) | 같은 이름 | 웹 CRUD · 워커(TTS) | org_id → organization_id |
| clip_transcripts | 이관(서버 쓰기) | 같은 이름 | 웹 읽기 · 워커(STT) | org_id → organization_id |
| edit_plans | 이관(서버 생성, 사용자 적용·되돌림·거절 RPC) | 같은 이름 | 웹 RPC · 서버 | org_id → organization_id |
- 동기화 대상(`(organization_id, updated_at)` 인덱스): clients·music_library·playlists·playlist_items·landing_pages·linkinbio_profiles·linkinbio_items·edit_presets·storyboards·scenes·workflows·pronunciation_lexicon. 소프트 삭제 deleted_at: clients·music_library·playlists·storyboards·workflows(시각은 서버 now(), 삭제·복구 owner·admin).

## 함수 (video → nomad_sceneflow / nomad_sceneflow_private)
| 원래 이름 | 분류 | 실행 | 변화 |
|---|---|---|---|
| update_channel_settings · disconnect_channel · consent_clip_automation_risk · revoke_clip_automation_consent · set_client_status | 이관 | authenticated(owner·admin)·서버 | 해제는 revoke_provider_credential. 철회는 잠긴 조직도 가능 |
| acknowledge_compliance_warning · cancel_upload · set_landing_status · set_music_distribution_status | 이관 | authenticated(editor 이상)·서버 | 랜딩 비공개 전환은 잠긴 조직도 가능 |
| save_scene · reorder_scenes · add_scene · delete_scene · set_shorts_candidate · apply_edit_plan · undo_edit_plan · reject_edit_plan | 이관(원본 12.6·13.13 최종) | authenticated(editor 이상)·서버 | revision 불일치 VD409, 렌더 중 VD020 |
| open_client_review · decide_client_review · purge_expired_sources · reset_channel_quotas · record_landing_view · apply_storyboard_result · finish_scene_asset · snapshot_storyboard | 이관 | service_role(is_service_caller) | 잠긴 조직 랜딩은 조회수 안 셈 |
| (신규) start_cut_render · finish_cut_render · fail_cut_render | 신규 | service_role | 스냅샷 → consume_credits → enqueue_job 한 트랜잭션, 실패 시 refund_credits |
| get_public_landing · get_public_linkinbio | 이관(D8) | anon·authenticated | 공개 컬럼만 jsonb, 없으면 null |
| has_access · can_write · has_feature · caller_has_feature · storage_org_id · storyboard_aspect_allowed · valid_preset_settings / (private) feat · limit_int · require_role · scene_count_limits · valid_scene_sources · render_dimensions · valid_edit_commands · valid_cut_ranges · valid_caption_emphasis · clip_notice_version · lock_storyboard_for_edit · storyboard_fingerprint | 신규·이관(도우미) | authenticated(불리언만) / service_role·내부 | — |
| enforce_status_transition · guard_user_edit · soft_delete_guard · check_ledger_org · guard_job_delivery · check_refs · enforce_channel_limit · guard_storyboard_edit · enforce_storyboard_limits · storyboard_render_settings_changed · cut_scenes_valid · check_storyboard_refs · scenes_before_update · storyboard_snapshots_readonly · check_edit_refs | 이관(트리거, private) | 트리거 | 원본 enforce_storyboard_transition 은 enforce_status_transition 에 합침 |

## 플랜 기능 · plan_limits 키 (원본 advanced→A, pro→B(basic 포함), starter→C. 수치 시드 안 함)
| 원본 features 키 | 새 위치 | A / B / C | DB 강제 위치 |
|---|---|---|---|
| (작업 공간) · track_a · ai_chat · voice_chat | 기능 `studio`·같은 이름 | O / O / O | 모든 읽기 정책·RPC |
| track_b·c·d·e·f · lang_multi · multi_platform · brandconnect · radar · compliance · silence_cut · layer_composite · coupang_landing · suno · osmu · priority_render · ai_script · storyboard · ai_edit · nle_export · watermark(true=워터마크) | 같은 이름 · watermark 는 반대 의미 `no_watermark` | O / O / — | 쓰기 정책·트리거(VD004·VD009)·RPC, 나머지(워터마크 포함)는 서버 |
| react_flow_full · api_access · agency · render_4k60 | 같은 이름 | O / — / — | agency=clients·client_channels, render_4k60=storyboards 트리거 |
| max_channels · storyboard_max_minutes · shorts_extract_max · aspect_variants_max · edit_presets_max · render_max_resolution · render_max_fps | plan_limits 같은 키(키 없으면 0, 해상도 1080 · fps 30) | 시드 없음 | 트리거(VD003·VD009·VD021·VD022) |
| bling_monthly_limit · team_members · ai_chat_turns_per_day · credit_discount_pct | plan_limits 같은 키 | 시드 없음 | 서버 |

## 구독 끊김 · 결과 저장 · 참조 조직 (P2 리뷰 교훈 반영)
- 구독 없음·inactive·만료 = C. 쓰기 정책 식에 기능이 들어 있어 유료 기능의 신규 생성뿐 아니라 기존 행 수정·게시·업로드·렌더도 잠김. 읽기는 studio 로 유지. 공개 랜딩은 not found, 링크인바이오는 무료라 유지.
- `enforce_storyboard_limits` 트리거는 BEFORE 라 RLS 보다 먼저 돈다 → 비멤버를 먼저 42501 로 거른 뒤 플랜 검사(남의 조직 플랜·한도 VD009 노출 방지, 원본과 다름).
- 결과 저장: music_tracks·sources·client_reports·storyboard_cuts·outputs 가 ready 가 될 때 잡이 failed·canceled 면 55000 거부, 아니면 `nomad_core.mark_job_delivered`. 참조 조직: jobs·ai_runs·provider_credentials·affiliate_links 복합 FK, credit_ledger·brandconnect_applications 트리거.

## 버킷
- 대용량 미디어 → `sceneflow-media`(비공개, 5GB, 영상·음원·이미지·자막·zip). 읽기 = 같은 조직 멤버 + studio, 쓰기는 서버만. 경로 `<organization_id>/sceneflow/<entity>/…`.
- 사용자 업로드(라이선스 증빙·라이브러리 음원) → 코어 공용 버킷 계약. 이 이식본에서 만들지 않음(팀장 확인 2). 경로 컬럼(music_library.license_proof_path·audio_path, linkinbio_profiles.avatar_path, clients.brand_guide_path)은 CHECK 로 `<organization_id>/sceneflow/<music_library|linkinbio|clients>/<uuid>.<확장자>`만 받는다(첫 폴더 = 자기 조직).

## 앱 변경
- `video.*` → `nomad_sceneflow.*`, `org_id` → `organization_id`, 원장 id bigint → uuid.
- 렌더: `start_cut_render(storyboard, actor, request_id, credits)` → 워커 `claim_jobs('sceneflow.orchestrate')` → outputs ready → `finish_cut_render` → `complete_job`. 최종 실패는 `fail_job` → `fail_cut_render`. 공개 페이지는 RPC 만(anon 표 grant 없음), 조회수는 서버가 `record_landing_view`.

## 팀장 확인 필요
1. 플랜 대응 advanced→A·pro→B·starter→C, 기능 29개(AI 기능은 0002 라우팅 키와 별개로 0001 기능 이용권).
2. 사용자 업로드용 코어 공용 버킷 이름·정책이 core 마이그레이션에 없음(SQL 주석은 existing.md 를 가리킴) — 계약 확정 필요.
3. 표 이름은 SQL 주석에 이름 변경 기록이 없어 원본과 같다고 가정(원본 파일 미열람).
