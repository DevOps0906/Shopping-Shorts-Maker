"""신뢰할 수 없는 원본 파일에서 대표 프레임을 꺼낸다 (ADR-0002 보안 조건).

- 파일 앞부분 서명으로 형식을 먼저 판별하고 확장자와 맞지 않으면 거부(확장자 위장·재생목록 차단).
- ffprobe·ffmpeg 모두 `-protocol_whitelist file` + `-f <판별한 형식>` 강제(HLS·concat 재생목록 demuxer를 쓰지 않음).
- ffprobe 결과의 형식·코덱·크기를 다시 확인하고, 하위 프로세스마다 벽시계 시간 상한을 둔다.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path

# 형식 → (ffmpeg demuxer, 허용 확장자, ffprobe format_name 에 있어야 할 이름, 허용 코덱)
FORMATS: dict[str, tuple[str, frozenset[str], str, frozenset[str]]] = {
    "mp4": ("mov", frozenset({".mp4", ".mov", ".m4v"}), "mp4",
            frozenset({"h264", "hevc", "av1", "vp9", "mpeg4"})),
    "webm": ("matroska", frozenset({".webm"}), "webm", frozenset({"vp8", "vp9", "av1"})),
    "png": ("png_pipe", frozenset({".png"}), "png_pipe", frozenset({"png"})),
    "jpeg": ("jpeg_pipe", frozenset({".jpg", ".jpeg"}), "jpeg_pipe", frozenset({"mjpeg"})),
    "webp": ("webp_pipe", frozenset({".webp"}), "webp_pipe", frozenset({"webp"})),
}
IMAGE_KINDS = frozenset({"png", "jpeg", "webp"})

MAX_FILE_BYTES = 524_288_000  # sources 버킷 상한(500 MiB)과 같다
MAX_SIDE = 8192  # 압축 폭탄 방지
MAX_DURATION_SEC = 600.0
PROC_TIMEOUT_SEC = 30.0  # 하위 프로세스 1회 상한
# 파서 1회 자원 상한(POSIX): 주소 공간 1 GiB · CPU 30초 · 파일 설명자 64 · 파일 쓰기 1 MiB(출력은 파이프만)
RLIMITS = {"RLIMIT_AS": 1 << 30, "RLIMIT_CPU": 30, "RLIMIT_NOFILE": 64, "RLIMIT_FSIZE": 1 << 20}
# TODO(ADR-0002): ffmpeg·ffprobe 를 네트워크 없는(network_mode: none) 별도 샌드박스 컨테이너로 분리(compose 범위)

SIDE = 32  # 대표 프레임 크기(정사각 32×32 RGB)
FRAME_BYTES = SIDE * SIDE * 3
MAX_FRAMES = 4  # 첫 2초 안에서 0.5초 간격(planning 4장 "첫 1~2초 프레임")


class MediaRejected(Exception):
    """형식 위반·손상 파일. 메시지는 사용자에게 보여도 되는 사유만."""


@dataclass(frozen=True)
class Probe:
    kind: str
    width: int
    height: int
    duration_sec: float | None


def sniff(path: Path) -> str:
    """파일 앞 16바이트 서명으로 형식을 판별한다. 확장자와 다르면 거부."""
    try:  # 심볼릭 링크는 따라가지 않는다
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        raise MediaRejected("파일을 열 수 없음") from exc
    with os.fdopen(fd, "rb") as f:
        head = f.read(16)
    if head[4:8] == b"ftyp":
        kind = "mp4"
    elif head[:4] == b"\x1a\x45\xdf\xa3":
        kind = "webm"
    elif head[:8] == b"\x89PNG\r\n\x1a\n":
        kind = "png"
    elif head[:3] == b"\xff\xd8\xff":
        kind = "jpeg"
    elif head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        kind = "webp"
    else:
        raise MediaRejected("허용하지 않는 파일 형식")
    if path.suffix.lower() not in FORMATS[kind][1]:
        raise MediaRejected("확장자와 실제 형식이 다름")
    return kind


def _child_env() -> dict[str, str]:
    """하위 프로세스 환경은 PATH·LANG 만(DB 비밀번호 등 워커 환경 변수 상속 차단)."""
    return {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"), "LANG": "C.UTF-8"}


def _limit_child() -> None:  # pragma: no cover - fork 뒤 자식에서 실행
    import resource

    for name, value in RLIMITS.items():
        resource.setrlimit(getattr(resource, name), (value, value))


def _run(args: list[str], timeout: float) -> bytes:
    posix = os.name == "posix"
    proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=_child_env(), start_new_session=posix,
                            preexec_fn=_limit_child if posix else None)
    try:
        out, _ = proc.communicate(timeout=max(timeout, 0.1))
    except subprocess.TimeoutExpired as exc:
        if posix:
            os.killpg(proc.pid, signal.SIGKILL)  # 프로세스 그룹 전체 종료
        else:
            proc.kill()
        proc.communicate()
        raise MediaRejected("분석 시간 초과") from exc
    if proc.returncode != 0:
        # stderr 에 경로가 섞이므로 저장·로그에 남기지 않는다
        raise MediaRejected("파일을 읽을 수 없음")
    return out


def _input_args(kind: str, path: Path) -> list[str]:
    return ["-threads", "1", "-protocol_whitelist", "file", "-f", FORMATS[kind][0], "-i", "file:" + str(path)]


def probe(path: Path, timeout: float = PROC_TIMEOUT_SEC) -> Probe:
    if not path.is_file():
        raise MediaRejected("파일 없음")
    if path.stat().st_size > MAX_FILE_BYTES:
        raise MediaRejected("파일이 너무 큼")
    kind = sniff(path)
    out = _run(["ffprobe", "-v", "error", "-hide_banner", *_input_args(kind, path),
                "-show_entries", "format=format_name,duration:stream=codec_type,codec_name,width,height",
                "-of", "json"], timeout)
    try:
        info = json.loads(out)
        names = str(info["format"]["format_name"]).split(",")
        video = [s for s in info.get("streams", []) if s.get("codec_type") == "video"]
    except (ValueError, KeyError, TypeError) as exc:
        raise MediaRejected("파일을 읽을 수 없음") from exc
    if FORMATS[kind][2] not in names or not video:
        raise MediaRejected("허용하지 않는 파일 형식")
    stream = video[0]
    if stream.get("codec_name") not in FORMATS[kind][3]:
        raise MediaRejected("허용하지 않는 코덱")
    width, height = int(stream.get("width") or 0), int(stream.get("height") or 0)
    if not (0 < width <= MAX_SIDE and 0 < height <= MAX_SIDE):
        raise MediaRejected("해상도 범위 밖")
    duration = None
    if kind not in IMAGE_KINDS:
        try:
            duration = float(info["format"]["duration"])
        except (KeyError, TypeError, ValueError) as exc:
            raise MediaRejected("길이를 읽을 수 없음") from exc
        if not 0 < duration <= MAX_DURATION_SEC:
            raise MediaRejected("길이 범위 밖")
    return Probe(kind=kind, width=width, height=height, duration_sec=duration)


def frames(path: Path, info: Probe, timeout: float = PROC_TIMEOUT_SEC) -> list[bytes]:
    """가운데 정사각 영역을 32×32 RGB로 줄인 프레임들. 영상은 첫 2초에서 0.5초 간격 최대 4장."""
    square = f"crop='min(iw,ih)':'min(iw,ih)',scale={SIDE}:{SIDE}:flags=area"
    if info.kind in IMAGE_KINDS:
        vf, limit = square, 1
    else:
        vf, limit = f"fps=2,{square}", MAX_FRAMES
    pre = [] if info.kind in IMAGE_KINDS else ["-t", "2"]
    out = _run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", *pre, *_input_args(info.kind, path),
                "-map", "0:v:0", "-an", "-sn", "-dn", "-vf", vf, "-frames:v", str(limit),
                "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], timeout)
    count = min(len(out) // FRAME_BYTES, limit)
    if count == 0:
        raise MediaRejected("프레임을 꺼낼 수 없음")
    return [out[i * FRAME_BYTES:(i + 1) * FRAME_BYTES] for i in range(count)]
