# task-006 스키마·RLS 표(권리 근거·확인자·삭제 예정일)

| 항목 | 내용 |
|---|---|
| 웨이브 | W1 |
| 선행 | task-004 |
| 위험도 | 높음 |
| 보안 영향 | 민감 데이터, 키·권한(RLS) |
| 담당 | planner |
| 근거 | `docs/planning.md#6`, `docs/planning.md#12`, `docs/planning.md#17-4`, `docs/planning.md#17-8`, `docs/planning.md#17-2`(D1·D5) |
| 쓰기 허용 | `docs/05_DATA_MODEL.md` |

## 할 것
- 테이블 표(테이블당 12줄 이내): 컬럼·소유자·RLS 정책(읽기·쓰기 주체)
- 원본 행에 URL·작성자·수집 시각 + 권리 근거·확인자·확인 시각·삭제 예정일(발행 30일 후) 컬럼
- trend_items·categories 읽기 전용, link_clicks 서버 쓰기 전용 명시

## 하지 않을 것
- SQL 마이그레이션 작성(task-010·011 몫)
- ERD 손 작성(마이그레이션 후 `sql2erd`)

## 완료 조건 (실행 가능한 확인)
- [ ] 17-4의 모든 테이블이 표에 있고 RLS 칸이 빈 행 0
- [ ] reviewer(mode=security) 🔴 0
