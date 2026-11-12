"""렌더 ffmpeg 호출(ADR-0002 보안 조건). task-016 sources.media 안전 호출과 같은 규칙에 출력 파일만 허용한다.

- 하위 프로세스 환경은 PATH·LANG 만(sources.media._child_env), 새 세션(시간 초과 시 프로세스 그룹 종료), rlimit.
- 입력은 모두 `-protocol_whitelist file` + `-f <판별한 형식>` 강제(재생목록·네트워크 demuxer 차단). 파일 경로는 file: 접두.
- 자막·출처 문구는 파일(textfile)로 넘기고 expansion=none(사용자 문구의 %{...} 확장 차단).
- H.264 는 libopenh264(BSD-2, LGPL 빌드라 libx264 없음). 결과는 ffprobe 로 다시 검사한다.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ..sources.media import FORMATS, MediaRejected, _child_env
from .plan import FPS, HEIGHT, WIDTH, Cut, subtitle_size

ENCODER = "libopenh264"
VIDEO_BITRATE = "8M"
AUDIO_BITRATE = "128k"
MAX_OUTPUT_BYTES = 209_715_200  # renders 버킷 상한(200 MiB)
TARGET_TOL_SEC = 0.1  # 팀장 결정: target_sec ±0.1초
AV_TOL_SEC = 0.05  # 팀장 결정: 영상·음성 길이 차 0.05초 이하
# 렌더 1회 자원 상한(POSIX): 주소 공간 3 GiB · CPU 600초(17-5 렌더 10분) · 파일 설명자 128 · 파일 쓰기 200 MiB
RLIMITS = {"RLIMIT_AS": 3 << 30, "RLIMIT_CPU": 600, "RLIMIT_NOFILE": 128, "RLIMIT_FSIZE": MAX_OUTPUT_BYTES}
FONT_FILE = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"


def _limit_child() -> None:  # pragma: no cover - fork 뒤 자식에서 실행
    import resource

    for name, value in RLIMITS.items():
        resource.setrlimit(getattr(resource, name), (value, value))


def run(args: list[str], timeout: float, cwd: Path) -> bytes:
    posix = os.name == "posix"
    proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=str(cwd), env=_child_env(), start_new_session=posix,
                            preexec_fn=_limit_child if posix else None)
    try:
        out, _ = proc.communicate(timeout=max(timeout, 0.1))
    except subprocess.TimeoutExpired as exc:
        if posix:
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        proc.communicate()
        raise MediaRejected("렌더 시간 초과") from exc
    if proc.returncode != 0:
        raise MediaRejected("영상 합치기 실패")  # stderr 에 경로가 섞이므로 남기지 않는다
    return out


@dataclass(frozen=True)
class CutInput:
    cut: Cut
    kind: str  # sources.media.FORMATS 키(mp4·webm)
    path: Path


def font_option() -> str:
    return f"fontfile={FONT_FILE}" if Path(FONT_FILE).is_file() else "font=sans"


def build_args(inputs: list[CutInput], voice: Path, tempo: float, target: float, credits: list[str],
               out_name: str) -> tuple[list[str], dict[str, str]]:
    """ffmpeg 인자와 작업 폴더에 써야 할 문구 파일(이름 → 내용)."""
    args = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
    for x in inputs:
        args += ["-ss", f"{x.cut.src_start:.3f}", "-t", f"{x.cut.dur + 0.5:.3f}", "-threads", "1",
                 "-protocol_whitelist", "file", "-f", FORMATS[x.kind][0], "-i", "file:" + str(x.path)]
    args += ["-protocol_whitelist", "file", "-f", "wav", "-i", "file:" + str(voice)]

    font = font_option()
    files: dict[str, str] = {}
    parts, draws = [], []
    for i, x in enumerate(inputs):
        c = x.cut
        parts.append(f"[{i}:v:0]scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=increase,crop={WIDTH}:{HEIGHT},"
                     f"setsar=1,fps={FPS},tpad=stop_mode=clone:stop_duration={c.dur:.3f},"
                     f"trim=duration={c.dur:.3f},setpts=PTS-STARTPTS[v{i}]")
        enable = f"enable='between(t,{c.out_start:.3f},{c.out_end:.3f})'"
        sub = f"sub_{c.no}.txt"
        files[sub] = " ".join(c.line.split())
        draws.append(f"drawtext={font}:expansion=none:textfile={sub}:fontsize={subtitle_size(files[sub])}:"
                     f"fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=20:x=(w-text_w)/2:y=h*0.75:{enable}")
        if credits[i]:  # 원본 출처 표기(D7): 우하단 작은 글씨, 자막과 겹치지 않게 y=h*0.9
            cred = f"credit_{c.no}.txt"
            files[cred] = credits[i]
            draws.append(f"drawtext={font}:expansion=none:textfile={cred}:fontsize=38:fontcolor=white@0.9:box=1:"
                         f"boxcolor=black@0.4:boxborderw=8:x=w-text_w-40:y=h*0.9:{enable}")
    n = len(inputs)
    parts.append("".join(f"[v{i}]" for i in range(n)) + f"concat=n={n}:v=1:a=0[vc]")
    parts.append("[vc]" + ",".join(draws) + "[vo]")
    tempo_f = f"atempo={tempo:.5f}," if tempo > 1.0 else ""
    parts.append(f"[{n}:a:0]{tempo_f}apad,atrim=end={target:.3f},aresample=48000,"
                 f"aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS[ao]")
    args += ["-filter_complex", ";".join(parts), "-map", "[vo]", "-map", "[ao]",
             "-c:v", ENCODER, "-b:v", VIDEO_BITRATE, "-pix_fmt", "yuv420p", "-r", str(FPS), "-g", str(FPS * 2),
             "-c:a", "aac", "-b:a", AUDIO_BITRATE, "-ar", "48000", "-ac", "2",
             "-t", f"{target:.3f}", "-movflags", "+faststart", "-threads", "2", "-f", "mp4", out_name]
    return args, files


@dataclass(frozen=True)
class OutputInfo:
    duration_sec: float
    video_sec: float
    audio_sec: float
    width: int
    height: int
    bit_rate: int
    size: int


def verify_output(path: Path, target: float, timeout: float) -> OutputInfo:
    """결과 MP4: H.264 1080x1920 + AAC, 길이 target ±0.1초, 영상·음성 길이 차 ≤ 0.05초."""
    size = path.stat().st_size
    if not 0 < size <= MAX_OUTPUT_BYTES:
        raise MediaRejected("결과 파일 크기 범위 밖")
    out = run(["ffprobe", "-v", "error", "-hide_banner", "-protocol_whitelist", "file", "-f", "mov",
               "-i", "file:" + str(path),
               "-show_entries", "format=duration,bit_rate:stream=codec_type,codec_name,width,height,duration",
               "-of", "json"], timeout, path.parent)
    try:
        info: dict[str, Any] = json.loads(out)
        streams = info.get("streams", [])
        video = [s for s in streams if s.get("codec_type") == "video"]
        audio = [s for s in streams if s.get("codec_type") == "audio"]
        duration = float(info["format"]["duration"])
        result = OutputInfo(duration_sec=duration, video_sec=float(video[0]["duration"]),
                            audio_sec=float(audio[0]["duration"]), width=int(video[0]["width"]),
                            height=int(video[0]["height"]), bit_rate=int(info["format"].get("bit_rate") or 0),
                            size=size)
    except (ValueError, KeyError, TypeError, IndexError) as exc:
        raise MediaRejected("결과 파일을 읽을 수 없음") from exc
    if len(video) != 1 or len(audio) != 1 or video[0].get("codec_name") != "h264" or audio[0].get("codec_name") != "aac":
        raise MediaRejected("결과 형식이 다름")
    if (result.width, result.height) != (WIDTH, HEIGHT):
        raise MediaRejected("결과 해상도가 다름")
    if abs(result.duration_sec - target) > TARGET_TOL_SEC:
        raise MediaRejected("결과 길이가 목표와 다름")
    if abs(result.video_sec - result.audio_sec) > AV_TOL_SEC:
        raise MediaRejected("영상·음성 길이가 다름")
    return result
