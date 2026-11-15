# DB 스키마 대시보드 — DESIGN

정답 소스는 `tokens.css`(일반 CSS 변수, 번들러 없음). 색·대비·크기 표 전체는 `DESIGN_TOKENS.md`(design-preview가 tokens.css에서 생성), 미리보기는 `preview.html`.

## 1. 브리프
- 대상: 로컬에서 공용 모듈(nomad_core)과 제품 5개의 스키마를 훑어보는 개발자·기획자. 읽기 전용.
- 주된 일: 제품별 테이블(소유·RLS·사용처·동기화·기존→새 이름) 확인, 구조(기존/단일/테넌트/모노레포) 비교, RLS 없는 테이블 찾기.
- 분위기: 차분함 · 정돈됨 · 밀도 높음. 피할 것: 장식, 웹폰트 로딩, 외부 CDN(예외: 구조도용 Mermaid 1개 — 5장), 색만으로 상태 구분(배지에 글자를 함께 표기).

## 2. 화면 구성
상단(제목·검색·테마 system/light/dark) · 좌측 내비 · 본문.
- 내비: 맨 위 제품 검색(이름·slug·tagline) → 공용 모듈 / 제품 / 비교. 제품은 `content/_categories.json`의 분류별 그룹(분류 아이콘·이름·제품 수), 분류에 없는 제품은 "기타". 그룹 머리 = 이름 버튼(분류 화면으로 이동 + 그 그룹 펼침, 현재 분류면 `aria-current`) + 화살표 버튼(접기·펴기만, `aria-expanded`). 하위 항목 = 아이콘 + 이름 + tagline(작게), 누르면 제품 화면. 기본 펼침은 현재 제품·분류의 그룹과 검색 중인 그룹, 사용자가 화살표로 정한 상태는 기억. 모바일(~767)은 "☰ 메뉴 · 현재 위치" 버튼으로 접고 펴며 항목을 누르면 닫힘, 태블릿 이상은 항상 펼침(세로 sticky·자체 스크롤).
- 화면 머리(공용 모듈·제품 공통): 아이콘·이름·배지 → tagline → 메타(레포·출처) → overview(최대 48rem). 그 아래 "구조도" 섹션: content `diagrams` + 표 관계 ERD 자동 생성(공용 모듈은 nomad_core 전체, 제품은 지금 탭 구조 — 표가 없거나 SQL 카드·로컬 탭이면 테넌트→단일→격리형→모노레포→기존 중 첫 구조). ERD 컬럼은 PK/FK만, 바깥 스키마 표(nomad_core·auth)는 참조된 컬럼만. 각 구조도는 가로 스크롤 박스(`tabindex=0`).
- 공용 모듈: [영역 | SQL 카드]. 영역 카드 5개(계정·조직 / 플랜·기능·한도 / 구독·이용권·크레딧 / 인증·소셜 로그인 / API 키) → 테이블 행 + 함수 배지, 카드 제목의 "SQL 보기"로 그 영역 SQL을 펼침.
- SQL 카드(공용 모듈·제품 공통): 묶음별 카드 격자(1/2/3열) — 카드 = 파일명·경로·설명(content `files`의 summary, 없으면 첫 설명 주석)·구성(parts: 표·함수·규칙을 접이식 목록, 항목 수 표시)·줄 수·테이블/함수/정책 수 → 맨 아래 "SQL 보기" 버튼. 설명은 원본 경로(`products/<slug>/<dir>/<file>.sql`)로 매칭 — 단일·테넌트는 같은 파일, 모노레포 파일(`2026120100NNMM_<slug>_<file>.sql`)은 생성기가 같은 내용의 원본을 찾아 `src`로 붙이고 경로 줄에 "원본 …"을 표시. 맨 앞은 묶음 합본. "SQL 보기"를 누르면 모달(`<dialog>`, 너비 `--size-dialog-max`, 배경 `--color-overlay`)로 원문(구문 강조·복사·다운로드), 닫으면 누른 카드로 포커스 복귀. 제품 묶음: 기존(원본) · 단일(user) · 테넌트(org) · 앱 공통(app) · 모노레포 · 번들(구조별 전체 SQL, 열 때 불러옴).
- 제품(products/ 아래 전부): 탭 [기존 | 단일 | 테넌트 | 모노레포 | 로컬 저장소 | SQL 카드]. 행 = 이름 · 소유 · RLS · 사용처 · 동기화 · 기존→새 이름. 행을 펼치면 컬럼·정책·출처.
- 분류(`#category/<key>`, `#/category/<key>`도 허용): 머리 = 분류 아이콘·이름·제품 수 배지. 본문 = 제품 카드 격자(1열 / 2열 / 3~4열 — 데스크톱은 `auto-fill`, 카드 최소 폭 max(`--size-nav`×1.25, 22%)). 카드(button) = 아이콘·이름·tagline·형태 배지(user형·org형·격리형)·표 수(형태의 대표 구조: user→단일, org→테넌트, isolated→격리형, 표가 없으면 기존). 클릭·Enter로 `#product/<slug>/existing`.
- SQL 카드의 parts는 첫 그룹만 펼친 상태로 시작.
- 비교: 제품 × 구조 테이블 수 매트릭스. 필터: 스키마·소유·사용처·RLS 없음, 검색은 테이블·컬럼명.
- 데이터: 생성기가 `content/`(분류 `_categories.json` → `categories`, `core.json` → `core.doc`, `<slug>.json` → 제품 `doc`)를 `schema.json`에 합친다. 없거나 JSON 오류면 경고 후 건너뜀(`check_*.sql`은 생성기가 파일 목록에서 빼므로 설명이 있어도 카드 없음).
- 라우팅: `#core` · `#core/sql` · `#category/<key>` · `#product/<slug>/<탭>`(SQL 카드는 `sql`) · `#compare`.

## 3. 반응형 3구간 폰트 표
| 토큰 | 모바일 ~767 | 태블릿 768~1199 | 데스크톱 1200~ |
|---|---|---|---|
| `--text-display` | 28px | 36px | 48px |
| `--text-h1` | 24px | 28px | 34px |
| `--text-h2` | 20px | 22px | 26px |
| `--text-body` | 15px | 16px | 16px |
| `--text-caption` | 12px | 13px | 13px |

- `--text-h1` 페이지 제목, `--text-h2` 카드·상단 제목, `--text-body` 본문, `--text-caption` 배지·표·메타. `--text-display`는 이 화면에서 쓰지 않음(토큰 규격 유지).
- 서체: 본문 `--font-sans`(Pretendard 우선, 없으면 시스템/Noto Sans KR), 이름·타입·키는 `--font-mono`. 웹폰트는 내려받지 않고 설치된 서체만 쓴다.
- 레이아웃: 모바일 내비 "메뉴" 버튼으로 접힘 / 태블릿 좌측 내비(204px 상당) / 데스크톱 `--size-nav` 240px + 제품 카드 2열(공용 모듈).

## 4. 테마
- 라이트 `:root`, 다크 `:root[data-theme="dark"]` + (저장값 없음 & OS 다크) `prefers-color-scheme`. 저장 키 `nomad.theme`(system·light·dark, system은 키 삭제). `?theme=dark`는 스크린샷용 임시 지정(저장 안 함).
- 대비 검사 `design-preview tokens.css --check` 전부 통과(본문 4.5:1, 입력 경계 3:1).

## 5. 접근성·검사 메모
- 키보드: 건너뛰기 링크, 내비·탭(버튼 그룹 `role=group` + `aria-pressed`)·행(details/summary)·SQL 카드(button) 모두 Tab·Enter·Space, 가로 스크롤 표는 `tabindex=0` 영역. 포커스 링 `--focus-width`. `prefers-reduced-motion` 시 전환 없음.
- `design-preview --scan`의 px 4건은 `@media (width >= 768px/1200px)` 구간 경계뿐(CSS 변수를 미디어 쿼리에 쓸 수 없음). 그 외 hex·px 직접 사용 0건.
- 데이터는 DOM `textContent`로만 삽입. 예외 1건: Mermaid가 `securityLevel: 'strict'`(DOMPurify 정화)로 만든 SVG만 innerHTML로 넣는다.
- Mermaid: `cdn.jsdelivr.net/npm/mermaid@11.4.1` 고정 + SRI(sha384)·`crossorigin=anonymous`, 구조도가 있는 화면에서만 지연 로드. 테마는 라이트=default / 다크=dark(테마 버튼·OS 변경 시 다시 그림, 테마+원문 단위 캐시). 로드·파싱 실패 시 안내 문구 + 원문 코드 블록. 오프라인이면 원문만 보인다.

## 6. 사람이 확정할 것
브랜드색 `--color-primary`(#2f5bea / 다크 #7f9bff), 반경 8/12px, 밀도(행 높이·카드 간격), 배지 색 의미(소유=파랑, RLS 없음=빨강, 동기화=주황).
