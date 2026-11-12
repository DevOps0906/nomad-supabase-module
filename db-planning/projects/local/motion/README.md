# Motion Studio · LTX Flow Studio · 로컬

- 계정·조직이 없는 개인 도구 · Supabase 불필요
- README 기준으로 정리한 구성

| 항목 | 값 |
|---|---|
| slug | `motion` |
| 유형 | `local` |
| DB | 없음 |

## 구성

```mermaid
flowchart LR
  pf["<b>프로젝트 폴더 (내 PC)</b><br/>project.json · 설정<br/>scenes/ · 장면 파일<br/>assets/ · 이미지·음원<br/>output/ · 결과 영상"]
  ms["<b>Motion Studio</b><br/>유튜브 인트로·영상<br/>3D 워크스루<br/>웹사이트 제작<br/>로컬 우선 실행"]
  dk["<b>Docker 렌더 (선택)</b><br/>원격 제작이 필요할 때<br/>컨테이너로 렌더<br/>영상·3D 검증은 남음"]
  lx["<b>LTX Flow Studio</b><br/>로컬 GPU 숏폼 생성<br/>대시보드 화면<br/>jobs·prompts · SQLite<br/>영상 파일 · 디스크"]
  sq["<b>SQLite 파일</b><br/>jobs · 작업 목록<br/>prompts · 프롬프트<br/>outputs · 결과 경로"]
  wk["<b>생성 워커 (미연결)</b><br/>README 기준<br/>실제 생성 워커 연동은 별도"]
  pf -->|열기| ms
  ms -->|렌더 필요 시| dk
  lx -->|저장| sq
  sq -->|연동 예정| wk
```

## 운영 방식

- 내 PC 폴더와 SQLite 파일로 동작 · 로그인과 조직이 필요 없음
- 판매·구독 서비스로 바뀌면 SceneFlow(조직형) DB와 연결하는 방안을 검토

> 이 문서는 제안 초안입니다. 실제 레포 스키마와 대조 후 확정하세요.
