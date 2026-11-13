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
    from .jobs import concurrency_from_env, consume

    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())

    def make_repo():
        """스레드마다 자기 DB 연결 2개(작업용 + 하트비트용)."""
        conn, hb_conn = connect(), connect()
        return PgRepo(conn), PgRepo(hb_conn), lambda: (conn.close(), hb_conn.close())

    concurrency = concurrency_from_env(dict(os.environ))
    threads = [
        threading.Thread(
            target=consume, args=(make_repo, queue, HANDLERS, stop),
            kwargs={"idle": IDLE_SECONDS, "reconnect": RECONNECT_SECONDS},
            name=f"consume-{queue}-{n}")
        for queue, count in concurrency.items() for n in range(count)
    ]
    print("worker 시작: " + " ".join(f"{q}x{c}" for q, c in concurrency.items()), flush=True)
    for t in threads:
        t.start()
    for t in threads:  # SIGTERM 후 진행 중 작업은 끝까지 처리(오래 걸리면 컨테이너 종료 시 vt 만료로 넘어간다)
        t.join()
    return 0


if __name__ == "__main__":
    sys.exit(check() if "--check" in sys.argv[1:] else run())
