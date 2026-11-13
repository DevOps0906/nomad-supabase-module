# task-010 DB 스키마 대시보드 (디자인 먼저 → Docker로 확인)

- 위험도: 낮음(로컬 전용 읽기 도구, 비밀 없음) · 근거: ~/.claude/plans/transient-singing-eich.md "task-010" · 메모리 형식(공용 모듈 + 제품별 기존·단일·테넌트·모노레포, 앱/웹, 로컬 저장소, 라이트/다크)
- 위치: `tools/schema-dashboard/`(정적 웹: index.html · app.js · styles.css · tokens.css · DESIGN.md · sample-data.json) · `tools/schema-dashboard/docker/`(Dockerfile · compose.yml · .dockerignore) · 생성기 `scripts/schema-dashboard.py` → `tools/schema-dashboard/data/schema.json`

## 1단계 디자인 (사용자 확인용)
- 화면: 상단(제목·검색·테마 전환 system/light/dark, `nomad.theme` 로컬 키 즉시 적용) · 좌측 내비(공용 모듈 / 제품 5개 / 비교) · 본문.
  - 공용 모듈: 영역별 카드(계정·조직 / 플랜·기능·한도 / 구독·이용권·크레딧 / 인증·소셜 로그인 / API 키) → 테이블 목록.
  - 제품: 탭 [기존 | 단일 | 테넌트 | 모노레포 | 로컬 저장소]. 테이블 행: 이름 · 소유(user/org/공개/서버) · RLS · 사용처 배지(웹·앱·데스크톱·워커) · 동기화(updated_at·deleted_at) · 기존→새 이름.
  - 테이블 상세(펼침/패널): 컬럼(이름·타입·null·PK·FK) · 정책 · 출처 파일.
  - 비교: 제품 × 구조 매트릭스(테이블 수, 공용 모듈 대체 수).
  - 필터: 스키마·소유·RLS 없음·사용처.
- 반응형 3구간(모바일 ~767 / 태블릿 768~1199 / 데스크톱 1200~), 구간별 폰트 토큰. 라이트/다크 토큰(`prefers-color-scheme` + `[data-theme]`). 외부 CDN 없음(자체 포함). 접근성: 키보드 탐색·대비 AA.
- 데이터는 `sample-data.json`(아래 형식, humscore·lottolab 실제 products/ 파일 기준 일부 + 나머지 자리표시)으로 화면 확인.

## 데이터 형식 schema.json
```
{ generated_at, products:[{slug,name,repo,form:"user|org",clients:["web","app","desktop","worker"],
   variants:{ existing:{tables:[T]}, single:{tables:[T]}, tenant:{tables:[T]}, monorepo:{tables:[T]} },
   local_storage:[{key,platform,content,sync,secret:false,clear_on_logout}] }],
  core:{ areas:[{name,tables:[T],functions:[F]}] } }
T = {schema,name,comment,owner:"user|org|public|server|indirect",rls:bool,policies:[{name,cmd,roles}],
     columns:[{name,type,nullable,pk,fk}],used_by:["web",…],sync:bool,source_file,renamed_from}
F = {schema,name,security_definer:bool,grants:["authenticated",…]}
```

## 2단계 Docker (nomad-docker-module 규칙 준수)
- nginx 비루트 공식 이미지(버전 고정 + digest), 포트 `127.0.0.1:<빈 포트>`만, read_only + tmpfs, `no-new-privileges`, cap_drop ALL 가능하면, 리소스 제한, healthcheck. `data/`는 읽기 전용 볼륨(재생성 시 재빌드 불필요). .dockerignore에 .env·키 제외.
- 실행: `docker compose -f tools/schema-dashboard/docker/compose.yml up -d` → 브라우저 확인.

## 완료 조건
- 1단계: 컨테이너로 띄워 sample-data로 3구간·라이트/다크 스크린샷(`~/.claude/nomad/bin/shot` 있으면 사용) → 사용자 확인
- 2단계(확인 후): 생성기가 5개 레포 기존 migrations + products/ + core를 파싱, 테이블 수가 조사 수치와 맞음

## 2단계 (2026-11-13 사용자: "가장 중요한 건 SQL문") — 실제 데이터 + SQL 보기
- 생성기 `scripts/schema-dashboard.py`(표준 라이브러리만): 파싱 대상 = core(`supabase/migrations/*_nomad_core*.sql`) · products/<slug>/{user,org,app}/*.sql · 각 레포 기존 `supabase/migrations`(경로는 products/<slug>/existing.md 머리 또는 survey 문서) · bundles/(있으면).
- schema.json에 추가: 테이블마다 `sql`(create table 문 + 그 테이블의 alter/index/policy/trigger/grant 문), 함수마다 `sql`(본문 전체). `files:[{structure,path,sql}]`로 구조별 파일 원문.
- 화면: 테이블 펼침에 "SQL" 탭(구문 강조는 CSS만, 복사 버튼) · 제품 화면에 "SQL 파일" 탭(구조 선택 → 파일 목록 → 원문·복사·다운로드) · 공용 모듈 화면도 같은 방식 · 번들이 있으면 "구조별 전체 SQL 다운로드(단일·테넌트·모노레포)".
- 비밀 없음 확인(생성 시 `sk-`·`eyJ`·`service_role` 키 패턴 있으면 실패).
