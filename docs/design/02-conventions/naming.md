# 네이밍 규칙

| 대상 | 규칙 | 예 |
|---|---|---|
| 스키마 | `nomad_<slug>`, 소문자 (하이픈은 `_`) | `nomad_contentflow` |
| 테이블 | snake_case 복수형 | `publish_logs` |
| 컬럼 | snake_case | `created_at` |
| PK | `id uuid default gen_random_uuid()` | `id` |
| 조직 FK | `organization_id` → `nomad_core.organizations(id)` | |
| 소유자 FK | `user_id` 또는 의미 있는 이름(`owner_id`, `buyer_id`) | |
| 시간 | `*_at timestamptz` | `published_at` |
| JSON | `*_json jsonb` | `settings_json` |
| 암호화 | `*_enc text` | `phone_enc` |
| 임베딩 | `embedding vector(1536)` | |
| 정책 | `<table>_<action>_<who>` | `posts_select_member` |
| 인덱스 | `idx_<table>_<cols>` | `idx_posts_org_id` |
| 마이그레이션 | `YYYYMMDDHHMMSS_<설명>.sql` | `20261120000100_add_audit.sql` |
| 청사진 slug | 소문자 kebab-case | `knowflow` |
