# task-020 05 편집: 컷 매칭·크롭 렌더·CutTimeline·버전(스케일업·제거 비활성)

| 항목 | 내용 |
|---|---|
| 웨이브 | W3 |
| 선행 | task-017, task-019 |
| 위험도 | 높음 |
| 보안 영향 | 민감 데이터(원본·렌더), 의존성(FFmpeg) |
| 담당 | builder |
| 근거 | spec S-10, `docs/planning.md#3`(05 편집), `docs/planning.md#9`(MVP 범위), `docs/planning.md#17-6` |
| 쓰기 허용 | `apps/web/src/app/(dashboard)/studio/[projectId]/[step]/edit/**`, `apps/web/src/components/edit/**`, `apps/worker/src/render/**` |

## 할 것
- 대본 문장 ↔ 권리 확인 원본 컷 매칭, 크롭만 지원하는 MP4 렌더(renders job, 가설 10분 제한)
- CutTimeline: 컷 교체(다음 순위 원본), 실패 컷 번호 안내, 버전 목록
- 스케일업·워터마크 제거 버튼은 비활성 표시만
- render_succeeded 이벤트 기록

## 하지 않을 것
- 스케일업·제거 구현(3단계 유료 후보)
- 권리 미확인 원본 입력

## 완료 조건 (실행 가능한 확인)
- [x] 샘플 원본으로 MP4 생성 테스트(길이가 target_sec에 맞는지, 허용 오차 팀장 결정 필요)
- [x] 테스트: 미확인 원본이 매칭 후보에 없음
- [x] `FFmpeg` 라이선스 빌드 구성 `secscan license` 통과, `spec S-10` 렌더 테스트
