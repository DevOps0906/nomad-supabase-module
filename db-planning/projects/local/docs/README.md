# 문서 · 공통 모듈 · 참조 레포

- DB 없이 GitHub 저장소와 로컬 폴더로 관리
- 제품 레포가 필요할 때 가져다 쓰는 자산

| 항목 | 값 |
|---|---|
| slug | `docs` |
| 유형 | `local` |
| DB | 없음 |

## 구성

```mermaid
flowchart LR
  pd["<b>platform-docs</b><br/>기획 정본<br/>공통 설계·SQL<br/>제품별 폴더"]
  pc["<b>PDF_Collections</b><br/>platform-docs의 PDF 사본<br/>인쇄·공유용"]
  rf["<b>참조·학습 레포</b><br/>블록체인 실습 · 27개<br/>웹·모바일·AI 학습 · 39개<br/>합계 66개, DB 설계 제외"]
  ag["<b>nomad-agent-os</b><br/>AI 개발팀 설정<br/>프로젝트 설치 도구"]
  md["<b>nomad-*-module</b><br/>blueprints · 기획 청사진<br/>design · 디자인·모션<br/>docker · 실행 템플릿<br/>secure-pack · 보안 모듈"]
  pr["<b>DB가 필요한 제품 레포</b><br/>조직형 서비스 · 7<br/>개인형 서비스 · 4<br/>별도 프로젝트 · 2"]
  pd -->|PDF 변환| pc
  ag -->|설치| md
  md -->|가져다 사용| pr
```

## 운영 방식

- 독립 배포나 DB가 필요한 앱인지는 용도별로 판단
- 학습 레포 66개는 DB 설계 대상에서 제외

> 이 문서는 제안 초안입니다. 실제 레포 스키마와 대조 후 확정하세요.
