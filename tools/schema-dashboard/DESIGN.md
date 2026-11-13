# DB 스키마 대시보드 — DESIGN

정답 소스는 `tokens.css`(일반 CSS 변수, 번들러 없음). 색·대비·크기 표 전체는 `DESIGN_TOKENS.md`(design-preview가 tokens.css에서 생성), 미리보기는 `preview.html`.

## 1. 브리프
- 대상: 로컬에서 공용 모듈(nomad_core)과 제품 5개의 스키마를 훑어보는 개발자·기획자. 읽기 전용.
- 주된 일: 제품별 테이블(소유·RLS·사용처·동기화·기존→새 이름) 확인, 구조(기존/단일/테넌트/모노레포) 비교, RLS 없는 테이블 찾기.
- 분위기: 차분함 · 정돈됨 · 밀도 높음. 피할 것: 장식, 외부 CDN·웹폰트 로딩, 색만으로 상태 구분(배지에 글자를 함께 표기).

## 2. 화면 구성
상단(제목·검색·테마 system/light/dark) · 좌측 내비(공용 모듈 / 제품 5 / 비교; 모바일은 상단 가로 스크롤 줄) · 본문.
- 공용 모듈: 영역 카드 5개(계정·조직 / 플랜·기능·한도 / 구독·이용권·크레딧 / 인증·소셜 로그인 / API 키) → 테이블 행 + 함수 배지.
- 제품: 탭 [기존 | 단일 | 테넌트 | 모노레포 | 로컬 저장소]. 행 = 이름 · 소유 · RLS · 사용처 · 동기화 · 기존→새 이름. 행을 펼치면 컬럼·정책·출처.
- 비교: 제품 × 구조 테이블 수 매트릭스. 필터: 스키마·소유·사용처·RLS 없음, 검색은 테이블·컬럼명.
- 라우팅: `#core` · `#product/<slug>/<탭>` · `#compare`.

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
- 레이아웃: 모바일 내비 상단 줄 / 태블릿 좌측 내비(204px 상당) / 데스크톱 `--size-nav` 240px + 제품 카드 2열(공용 모듈).

## 4. 테마
- 라이트 `:root`, 다크 `:root[data-theme="dark"]` + (저장값 없음 & OS 다크) `prefers-color-scheme`. 저장 키 `nomad.theme`(system·light·dark, system은 키 삭제). `?theme=dark`는 스크린샷용 임시 지정(저장 안 함).
- 대비 검사 `design-preview tokens.css --check` 전부 통과(본문 4.5:1, 입력 경계 3:1).

## 5. 접근성·검사 메모
- 키보드: 건너뛰기 링크, 내비·탭·행(details/summary) 모두 Tab·Enter·Space, 가로 스크롤 표는 `tabindex=0` 영역. 포커스 링 `--focus-width`. `prefers-reduced-motion` 시 전환 없음.
- `design-preview --scan`의 px 4건은 `@media (width >= 768px/1200px)` 구간 경계뿐(CSS 변수를 미디어 쿼리에 쓸 수 없음). 그 외 hex·px 직접 사용 0건.
- 데이터는 DOM `textContent`로만 삽입(innerHTML 미사용).

## 6. 사람이 확정할 것
브랜드색 `--color-primary`(#2f5bea / 다크 #7f9bff), 반경 8/12px, 밀도(행 높이·카드 간격), 배지 색 의미(소유=파랑, RLS 없음=빨강, 동기화=주황).
