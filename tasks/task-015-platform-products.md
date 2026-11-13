# task-015 platform-docs 제품 이식 (products/<slug>/, task-012 형식)

- 위험도: 높음 · 근거: tasks/task-012-product-ports.md(형식·변환 규칙·추가 요구 전부 그대로 적용) · docs/design/03-port/platform-docs-mapping.md 2장(slug·형태·코어 의존)·5장 결정
- 원본("기존"): D:\WorkSpace\DEV\platform-docs\products\_supabase-modular\migrations\<번호>_<이름>.sql + products/<제품>/ 문서(데이터 모델·앱 구성) — 읽기만
- 저쪽 `core.*` 참조 변환: org_members→nomad_core.memberships(member→editor), org_id→organization_id, has_entitlement→nomad_core.has_feature, plans 시드→A/B/C features(수치 없음). jobs·credits·ai·affiliate·voice는 task-014 core 웨이브 대상 — 그 전에 만드는 제품은 해당 참조 부분을 `0002_<영역>.sql` 같은 별도 파일로 분리하고 existing.md에 "core 웨이브 후 적용" 표시.
- anon(D8): 테이블 직접 grant 금지, 공개용 security definer RPC만(입력 검증·rate limit 메모).
- 형태: 원래 org 제품은 org안만, user 제안 제품(astro·studynote·stock)은 user안·org안 둘 다(D5).
- 산출물·검사·local-storage.md·테마는 task-012와 동일. 번들 반영은 task-013 빌더가 products/ 를 읽으므로 자동.

## 웨이브
- P1(코어 의존 AI만): erp(1600) · school(1700 sms) · poll(1800) · floria(2200 site)
- P2/P3/P4: task-014 core 웨이브 이후
