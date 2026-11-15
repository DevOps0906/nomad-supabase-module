# 대시보드 설명 콘텐츠 (사람이 쓰는 원본)

`scripts/schema-dashboard.py`가 이 폴더를 읽어 `data/schema.json`에 합친다. 분류는 `_categories.json`, 제품별 설명은 `<slug>.json`, 공통 코어는 `core.json`.

## `<slug>.json` / `core.json` 형식
```json
{
  "slug": "news",
  "icon": "📰",
  "tagline": "이 DB가 하는 일 한 줄(30자 이내)",
  "overview": "3~5문장. 누가 쓰는가(역할), 어떤 데이터를 담는가, 플랜·기능 잠금, 특별한 보안 규칙.",
  "diagrams": [
    { "title": "주요 흐름", "mermaid": "flowchart LR\n  ..." }
  ],
  "files": {
    "products/news/org/0001_news.sql": {
      "summary": "2~3문장: 이 파일을 적용하면 무엇이 생기는가",
      "parts": [
        { "title": "표", "items": [["articles", "기사 본문과 상태(draft→published)"]] },
        { "title": "함수(RPC)", "items": [["save_article(p_org, …)", "편집국이 기사 저장. desk 미만은 자기 기사만, 구독 끊김 시 NW014"]] },
        { "title": "보안·잠금 규칙", "items": [["조직 격리", "모든 표 RLS, 같은 조직 멤버만"]] }
      ]
    }
  }
}
```

## 작성 규칙
- 근거는 SQL 파일 자체. 추측 금지, 모르면 쓰지 않는다. 한국어, 식별자는 영어 그대로.
- `files` 키는 저장소 기준 경로(`products/<slug>/<org|user|isolated>/<파일>.sql`, 코어는 `supabase/migrations/<파일>.sql`). `check_*.sql`은 한 줄 요약만(`parts` 생략 가능).
- 표는 전부, 함수는 사용자·서버가 부르는 것 전부(내부 트리거 함수는 묶어서 1줄). 항목 설명은 1문장.
- 구조도는 1~2개, 각 25노드 이내. 역할(사용자·서버·워커) → 함수 → 표 흐름, 또는 상태 전이(`stateDiagram-v2`). 표 관계(ERD)는 대시보드가 FK로 자동으로 그리므로 `erDiagram`은 쓰지 않는다. 라벨에 괄호·따옴표가 있으면 `["..."]`로 감싼다.
- 구조도는 `~/.claude/nomad/bin/mmd-check`로 문법 검사 후 넣는다.
