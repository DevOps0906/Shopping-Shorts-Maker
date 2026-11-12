"""진입점: 큐 소비 루프. `--check`는 헬스체크(FFmpeg LGPL 빌드 확인)."""

import os
import signal
import subprocess
import sys
import threading

FORBIDDEN_FLAGS = ("--enable-gpl", "--enable-nonfree")
IDLE_SECONDS = 2.0
RECONNECT_SECONDS = 5.0


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


REQUIRED_ENV = ("WORKER_DB_HOST", "WORKER_DB_NAME", "WORKER_DB_PASSWORD")


def run() -> int:
    missing = [name for name in REQUIRED_ENV if not os.environ.get(name)]
    if missing:
        # 값은 출력하지 않고 이름만
        print(f"설정 누락으로 종료: {', '.join(missing)} (루트 .env 확인)", file=sys.stderr, flush=True)
        return 2

    from .db import PgRepo, connect
    from .handlers import HANDLERS
    from .jobs import poll_once

    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())

    print("worker 시작: 큐 render·tts·analyze 소비", flush=True)
    while not stop.is_set():
        try:
            with connect() as conn, connect() as hb_conn:
                repo, hb_repo = PgRepo(conn), PgRepo(hb_conn)
                while not stop.is_set():
                    if poll_once(repo, hb_repo, HANDLERS) == 0:
                        stop.wait(IDLE_SECONDS)
        except Exception as exc:  # DB 끊김 등: 오류 종류만 남기고 다시 접속(접속 정보·비밀번호 출력 금지)
            print(f"DB 오류로 재접속 대기: {type(exc).__name__}", file=sys.stderr, flush=True)
            stop.wait(RECONNECT_SECONDS)
    return 0


if __name__ == "__main__":
    sys.exit(check() if "--check" in sys.argv[1:] else run())
