"""문장·단어 타이밍. 근거: poc/agency/run.py silence_gaps·sentence_spans(문장 단위 싱크).

- 한 번에 합성한 음성에서 ffmpeg silencedetect 로 무음 구간을 찾고, 가장 긴 N-1개 무음을 문장 경계로 삼는다.
  무음이 모자라면 글자 수 비율로 나눈다(method = char_ratio).
- 단어 타이밍은 문장 구간 안에서 단어 글자 수 비율로 나눈다(공백 기준 단어, 자막용 추정치).
- 결과 개수는 항상 대본과 같다: 문장 수 = 줄 수, 단어 수 = 줄별 공백 분리 단어 수 합.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from typing import Any

SILENCE_NOISE = "-35dB"
SILENCE_MIN_SEC = 0.12
MERGE_UNDER_SEC = 0.15  # 0.15초 미만 발화(숨소리 등)로 갈라진 무음은 하나로


@dataclass
class Timing:
    method: str
    sentences: list[dict[str, Any]]
    words: list[dict[str, Any]]
    pauses: list[dict[str, float]]


def silence_gaps(path: str, timeout: float) -> list[tuple[float, float]]:
    """(무음 시작, 끝) 목록. 끝이 없는 마지막 무음은 끝을 None 대신 매우 큰 값으로 두고 호출자가 자른다."""
    r = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-nostats", "-i", path,
                        "-af", f"silencedetect=noise={SILENCE_NOISE}:d={SILENCE_MIN_SEC}", "-f", "null", "-"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", r.stderr)]
    ends = [float(x) for x in re.findall(r"silence_end: (-?[\d.]+)", r.stderr)]
    return [(max(s, 0.0), ends[i] if i < len(ends) else float("inf")) for i, s in enumerate(starts)]


def _weight(text: str) -> int:
    return max(1, len(re.sub(r"\s", "", text)))


def sentence_spans(gaps: list[tuple[float, float]], total: float, lines: list[str]) -> tuple[list[tuple[float, float]], str, list[tuple[float, float]]]:
    """문장별 (시작, 끝), 방식, 안쪽 무음 목록."""
    gaps = [(s, min(e, total)) for s, e in gaps if s < total]
    lead, tail = 0.0, total
    if gaps and gaps[0][0] < 0.05:
        lead = gaps.pop(0)[1]
    if gaps and gaps[-1][1] >= total - 0.05:
        tail = gaps.pop()[0]
    merged: list[tuple[float, float]] = []
    for g in gaps:
        if merged and g[0] - merged[-1][1] < MERGE_UNDER_SEC:
            merged[-1] = (merged[-1][0], g[1])
        else:
            merged.append(g)
    n = len(lines)
    if n > 1 and len(merged) >= n - 1:
        pick = sorted(sorted(merged, key=lambda g: g[1] - g[0], reverse=True)[: n - 1])
        starts, ends = [lead] + [e for _, e in pick], [s for s, _ in pick] + [tail]
        return list(zip(starts, ends)), "silencedetect", merged
    w = [_weight(x) for x in lines]
    spans, t = [], lead
    for x in w:
        spans.append((t, t + (tail - lead) * x / sum(w)))
        t = spans[-1][1]
    return spans, ("silencedetect" if n == 1 else "char_ratio"), merged


def build_timing(lines: list[str], gaps: list[tuple[float, float]], total: float) -> Timing:
    spans, method, inner = sentence_spans(gaps, total, lines)
    sentences: list[dict[str, Any]] = []
    words: list[dict[str, Any]] = []
    for i, (line, (start, end)) in enumerate(zip(lines, spans)):
        sentences.append({"i": i, "text": line, "start": round(start, 3), "end": round(end, 3)})
        tokens = line.split()
        weights = [_weight(t) for t in tokens]
        t = start
        for token, wt in zip(tokens, weights):
            w_end = t + (end - start) * wt / sum(weights)
            words.append({"s": i, "w": token, "start": round(t, 3), "end": round(w_end, 3)})
            t = w_end
    pauses = [{"start": round(s, 3), "end": round(e, 3)} for s, e in inner]
    return Timing(method=method, sentences=sentences, words=words, pauses=pauses)
