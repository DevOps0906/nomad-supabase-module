# 폴더 구조 규칙 (확장 규칙)

프로젝트가 계속 쌓이므로 **위치만 보고 유형을 알 수 있게** 한다.

```
projects/
├─ _template/              뼈대. 직접 수정하지 말고 new-project.sh가 복사
├─ org/<slug>/             조직형
├─ user/<slug>/            개인형
├─ isolated/<slug>/        격리형
└─ local/<slug>/           로컬·DB 불필요
```

## 프로젝트 폴더 내부 (고정)
```
<slug>/
├─ project.yaml            메타데이터 (유형, 스키마, 소유 컬럼, 상태)
├─ README.md               개요 + Mermaid ER 다이어그램 + 접근 규칙
├─ schema.draft.sql        테이블·RLS 초안 (local은 없음)
└─ migrations/             확정된 마이그레이션 (확정 후 생성)
```

## 규칙
1. 폴더명 = 스키마명 = `project.yaml`의 `slug`.
2. 유형이 바뀌면 폴더를 이동(`git mv`)하고 `registry/projects.yaml`의 `type`을 수정한다.
3. 하나의 프로젝트가 여러 레포를 쓰면 `project.yaml`의 `repos:`에 나열한다.
4. 보관 처리는 삭제하지 않고 `status: archived`로 표시한다.
5. 다른 계정(예: theBestTrade) 프로젝트도 같은 폴더에 쌓되 `project.yaml`의 `account:`로 구분한다.
