"""로컬 일치도 계산: 지각 해시(pHash) + 색 히스토그램. 외부 패키지·LLM 없이 32×32 RGB 바이트만 쓴다."""

from __future__ import annotations

import math

from .media import SIDE

HASH_SIDE = 8  # DCT 저주파 8×8 = 64비트
HIST_LEVELS = 4  # 채널당 4단계 → 64칸
PHASH_WEIGHT = 0.5  # 나머지는 색 히스토그램

_COS = [[math.cos((2 * x + 1) * u * math.pi / (2 * SIDE)) for x in range(SIDE)] for u in range(HASH_SIDE)]


def _gray(rgb: bytes) -> list[float]:
    return [0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2] for i in range(0, len(rgb), 3)]


def phash(rgb: bytes) -> int:
    """32×32 RGB → 64비트 지각 해시(저주파 DCT 계수가 중앙값보다 큰지)."""
    gray = _gray(rgb)
    rows = [[sum(gray[y * SIDE + x] * _COS[u][x] for x in range(SIDE)) for u in range(HASH_SIDE)]
            for y in range(SIDE)]
    coefs = [sum(rows[y][u] * _COS[v][y] for y in range(SIDE)) for v in range(HASH_SIDE) for u in range(HASH_SIDE)]
    median = sorted(coefs[1:])[len(coefs[1:]) // 2]  # DC(밝기 평균) 제외
    bits = 0
    for c in coefs:
        bits = (bits << 1) | (c > median)
    return bits


def color_hist(rgb: bytes) -> list[float]:
    bins = [0] * HIST_LEVELS ** 3
    step = 256 // HIST_LEVELS
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i] // step, rgb[i + 1] // step, rgb[i + 2] // step
        bins[(r * HIST_LEVELS + g) * HIST_LEVELS + b] += 1
    total = len(rgb) // 3 or 1
    return [n / total for n in bins]


def similarity(a: bytes, b: bytes) -> float:
    """0~1. pHash 해밍 유사도와 히스토그램 교집합의 가중 평균."""
    hash_sim = 1 - bin(phash(a) ^ phash(b)).count("1") / (HASH_SIDE * HASH_SIDE)
    hist_sim = sum(min(x, y) for x, y in zip(color_hist(a), color_hist(b)))
    return PHASH_WEIGHT * hash_sim + (1 - PHASH_WEIGHT) * hist_sim


def best_match(product: bytes, candidate_frames: list[bytes]) -> float:
    """후보 프레임 중 제품 이미지와 가장 닮은 값."""
    return max(similarity(product, f) for f in candidate_frames)
