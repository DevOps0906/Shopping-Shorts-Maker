"""voices 객체 재검사. voices 버킷 파일은 신뢰하지 않는 입력으로 다룬다.

서명 업로드 URL은 jobs.payload 로 사용자에게도 보이고, 실제 기한은 Storage 기본값(약 2시간)이다
(payload.upload_expires_at 10분은 워커가 지키는 UX용 기한일 뿐). 그 사이 사용자가 같은 경로에 다른 파일을 올릴 수 있으므로,
음성을 쓰는 쪽(tts 저장 직전, 이후 렌더 task-020)은 이 함수로 형식·길이·타이밍을 다시 확인한다.
ffprobe 호출은 task-016 sources.media 의 안전 호출(환경 변수 차단·rlimit·시간 상한·file 프로토콜만)을 그대로 쓴다.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from ..sources.media import MediaRejected, _run

MAX_WAV_BYTES = 52_428_800  # voices 버킷 상한(50 MiB)
MAX_DURATION_SEC = 600.0
DURATION_TOL_SEC = 0.05


def probe_wav(path: Path, timeout: float) -> float:
    """16bit PCM wav(오디오 스트림 1개)만 통과. 반환: 길이(초)."""
    try:  # 심볼릭 링크는 따라가지 않는다
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        raise MediaRejected("파일을 열 수 없음") from exc
    with os.fdopen(fd, "rb") as f:
        head = f.read(12)
        size = os.fstat(f.fileno()).st_size
    if size > MAX_WAV_BYTES:
        raise MediaRejected("파일이 너무 큼")
    if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
        raise MediaRejected("허용하지 않는 파일 형식")
    out = _run(["ffprobe", "-v", "error", "-hide_banner", "-threads", "1", "-protocol_whitelist", "file",
                "-f", "wav", "-i", "file:" + str(path),
                "-show_entries", "format=format_name,duration:stream=codec_type,codec_name,channels",
                "-of", "json"], timeout)
    try:
        info: dict[str, Any] = json.loads(out)
        names = str(info["format"]["format_name"]).split(",")
        streams = info.get("streams", [])
        duration = float(info["format"]["duration"])
    except (ValueError, KeyError, TypeError) as exc:
        raise MediaRejected("파일을 읽을 수 없음") from exc
    if "wav" not in names or len(streams) != 1 or streams[0].get("codec_type") != "audio":
        raise MediaRejected("허용하지 않는 파일 형식")
    if streams[0].get("codec_name") != "pcm_s16le" or int(streams[0].get("channels") or 0) != 1:
        raise MediaRejected("허용하지 않는 코덱")
    if not 0 < duration <= MAX_DURATION_SEC:
        raise MediaRejected("길이 범위 밖")
    return duration


def verify_take(path: Path, duration_sec: float, sentences: list[dict[str, Any]], words: list[dict[str, Any]],
                timeout: float) -> float:
    """파일 길이가 기록할 duration 과 같고, 문장·단어 타이밍이 파일 길이 안에 있는지. 반환: 실제 길이."""
    actual = probe_wav(path, timeout)
    if abs(actual - duration_sec) > DURATION_TOL_SEC:
        raise MediaRejected("음성 길이가 기록과 다름")
    for t in (*sentences, *words):
        if not (0 <= float(t["start"]) <= float(t["end"]) <= actual + DURATION_TOL_SEC):
            raise MediaRejected("타이밍이 음성 길이 밖")
    return actual
