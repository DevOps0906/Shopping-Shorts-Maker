"""최소 진입점: 실행하면 종료 신호까지 대기, `--check`는 헬스체크(FFmpeg LGPL 빌드 확인)."""

import signal
import subprocess
import sys
import threading

FORBIDDEN_FLAGS = ("--enable-gpl", "--enable-nonfree")


def check() -> int:
    for tool in ("ffmpeg", "ffprobe"):
        result = subprocess.run([tool, "-hide_banner", "-buildconf"], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            print(f"{tool} 실행 실패", file=sys.stderr)
            return 1
        found = [flag for flag in FORBIDDEN_FLAGS if flag in result.stdout]
        if found:
            print(f"{tool}가 LGPL 빌드가 아님: {found}", file=sys.stderr)
            return 1
    return 0


def run() -> int:
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    print("worker 대기 중 (큐 소비 미구현)", flush=True)
    stop.wait()
    return 0


if __name__ == "__main__":
    sys.exit(check() if "--check" in sys.argv[1:] else run())
