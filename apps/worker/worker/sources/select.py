"""점수표(docs/planning.md 4장)로 정렬해 상위 20편을 고른다. 체크는 하지 않는다(D1: 사용자만 체크)."""

from __future__ import annotations

from dataclasses import dataclass

LIST_LIMIT = 20  # 목록 20편(D8). 다운로드 10편은 사용자가 체크
# 지금 계산하는 항목만: 제품 일치도 40 · 화질 20. 동작 장면·반응·깨끗함(합 40)은 측정 전이라 빼고 60으로 나눠 0~100점
WEIGHTS = {"match": 40, "quality": 20}
OUT_OF_LIST = "일치도 순위 20위 밖"


def quality(width: int, height: int) -> float:
    """짧은 변 기준 0~1: 1080 이상 1, 720 이상 0.7, 그 아래는 비례(최대 0.5)."""
    short = min(width, height)
    if short >= 1080:
        return 1.0
    if short >= 720:
        return 0.7
    return round(0.5 * short / 720, 4)


def score(match: float, width: int, height: int) -> float:
    total = WEIGHTS["match"] * match + WEIGHTS["quality"] * quality(width, height)
    return round(total * 100 / sum(WEIGHTS.values()), 2)


@dataclass(frozen=True)
class Result:
    source_id: str
    score: float | None
    rank: int | None
    exclude_reason: str | None
    checked: bool = False  # D1: 저장 시 체크 기본값은 해제


def rank(scored: dict[str, float], rejected: dict[str, str], limit: int = LIST_LIMIT) -> list[Result]:
    """점수 내림차순(같으면 id 순)으로 순위를 매기고 limit 밖과 거부 후보에 사유를 붙인다."""
    ordered = sorted(scored.items(), key=lambda kv: (-kv[1], kv[0]))
    results = [Result(sid, s, i, None if i <= limit else OUT_OF_LIST) for i, (sid, s) in enumerate(ordered, 1)]
    results += [Result(sid, None, None, reason) for sid, reason in sorted(rejected.items())]
    return results
