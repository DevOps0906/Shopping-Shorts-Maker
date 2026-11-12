"""컷 계획: 대본 문장 ↔ 편집 입력 원본 매칭과 컷 길이(웹 apps/web/src/lib/edit/plan.ts 와 같은 규칙).

- 컷 = 대본 한 줄. 컷 경계는 음성 문장 사이 쉼의 가운데(문장 타이밍이 없으면 글자 수 비율), 프레임(1/30초) 단위.
- 마지막 컷은 목표 길이(target_sec)까지 → 영상 길이 = target_sec. 음성이 목표보다 길면 atempo 로 최대 1.15배까지 줄인다.
- 기본 매칭은 점수 순 원본을 차례로 돌려 쓴다(컷 i → 순위 i % 원본 수). 교체는 화면에서 "다음 순위 원본"으로 바꿔 payload 로 온다.
- 같은 원본을 여러 컷이 쓰면 앞 컷이 쓴 구간 뒤부터 이어 쓴다(남은 길이가 모자라면 처음부터, 그래도 짧으면 정지 화면으로 채움).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

FPS = 30
WIDTH, HEIGHT = 1080, 1920
MAX_TEMPO = 1.15
MIN_CUT_SEC = 0.5

PLATFORM_LABEL = {"tiktok": "TikTok", "xiaohongshu": "小红书", "direct": "직접 추가"}


class PlanError(Exception):
    """컷을 나눌 수 없음. 메시지는 사용자에게 보여도 되는 문구."""


@dataclass(frozen=True)
class Cut:
    no: int
    line: str
    source_id: str
    src_start: float
    out_start: float
    out_end: float

    @property
    def dur(self) -> float:
        return round(self.out_end - self.out_start, 3)


def to_frame(sec: float) -> float:
    return round(sec * FPS) / FPS


def _char_ratio(lines: list[str], target: float) -> list[float]:
    weights = [max(1, len(re.sub(r"\s", "", x))) for x in lines]
    total, acc, out = sum(weights), 0, [0.0]
    for w in weights[:-1]:
        acc += w
        out.append(to_frame(target * acc / total))
    return out + [float(target)]


def boundaries(lines: list[str], sentences: list[dict[str, Any]], voice_sec: float,
               target: float) -> tuple[list[float], float, str]:
    """컷 경계(len = 줄 수 + 1, 0 → target)·atempo·방식."""
    if not lines:
        raise PlanError("승인된 대본이 없습니다.")
    tempo = 1.0 if voice_sec <= target else voice_sec / target
    if tempo > MAX_TEMPO:
        raise PlanError(f"음성({voice_sec:.1f}초)이 목표 길이 {target:g}초보다 너무 깁니다. 04 목소리에서 다시 만들어 주세요.")
    n = len(lines)
    ordered = sorted(sentences, key=lambda s: int(s["i"]))
    if len(ordered) == n:
        b = [0.0] + [to_frame((float(ordered[i - 1]["end"]) + float(ordered[i]["start"])) / 2 / tempo)
                     for i in range(1, n)] + [float(target)]
        if all(b[i + 1] - b[i] >= MIN_CUT_SEC for i in range(n)):
            return b, tempo, "sentences"
    b = _char_ratio(lines, target)
    if any(b[i + 1] - b[i] < MIN_CUT_SEC for i in range(n)):
        raise PlanError("대사 줄이 너무 많아 컷을 나눌 수 없습니다. 03 대본을 줄여 주세요.")
    return b, tempo, "char_ratio"


def default_assignment(n: int, ranked_ids: list[str]) -> list[str]:
    if not ranked_ids:
        raise PlanError("편집에 쓸 수 있는 원본이 없습니다. 02 소스에서 권리 근거를 확인한 원본을 고르세요.")
    return [ranked_ids[i % len(ranked_ids)] for i in range(n)]


def build_cuts(lines: list[str], bounds: list[float], source_ids: list[str],
               source_sec: dict[str, float | None]) -> list[Cut]:
    used: dict[str, float] = {}
    cuts = []
    for i, (line, sid) in enumerate(zip(lines, source_ids)):
        a, b = bounds[i], bounds[i + 1]
        dur = b - a
        start = used.get(sid, 0.0)
        length = source_sec.get(sid)
        if length is not None and start + dur > length:
            start = 0.0
        used[sid] = round(start + dur, 3)
        cuts.append(Cut(no=i + 1, line=line, source_id=sid, src_start=round(start, 3),
                        out_start=round(a, 3), out_end=round(b, 3)))
    return cuts


def credit_label(author: str) -> str:
    a = str(author or "").strip().lstrip("@")
    return f"@{a}" if a else ""


def credits_text(cuts: list[Cut], sources: dict[str, dict[str, Any]]) -> str:
    """설명란용 출처 목록: '영상 출처: @a(TikTok), @b(小红书)' (중복 제거, 컷 순서)."""
    seen: list[str] = []
    for c in cuts:
        src = sources[c.source_id]
        label = credit_label(src.get("author", ""))
        if not label:
            continue
        pf = str(src.get("platform") or "")
        item = f"{label}({PLATFORM_LABEL.get(pf, pf)})" if pf else label
        if item not in seen:
            seen.append(item)
    return ("영상 출처: " + ", ".join(seen)) if seen else ""


def subtitle_size(line: str) -> int:
    """한 줄 자막 글자 크기(px): 1080 폭 안에 들어가게 줄 길이로 줄인다(최대 64, 최소 28)."""
    return max(28, min(64, int(1000 / max(1, len(line)))))
