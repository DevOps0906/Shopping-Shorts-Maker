"""큐 소비 1건 처리 규칙 (ADR-0001, docs/planning.md 17-5).

DB 접근은 `Repo` 프로토콜 뒤에 두어 단위 테스트에서 가짜 저장소로 바꿀 수 있게 한다.
상태 전이·원장 기록·archive 는 전부 DB 함수(private.job_*) 한 번 호출 = 한 트랜잭션이다.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Protocol

QUEUES = ("render", "tts", "analyze")
VT_SECONDS = 12 * 60  # 렌더 상한 10분보다 길게
HEARTBEAT_SECONDS = 60  # 1분마다 vt 연장 + 상태 확인
BACKOFF_BASE_SECONDS = 10
BACKOFF_MAX_SECONDS = 300
# 종류별 실행 상한(가설, 17-5). 스위퍼(private.job_time_limit)와 같은 값
TIME_LIMIT_SECONDS = {"tts": 120, "render": 600, "analyze": 300}


class TransientError(Exception):
    """일시 오류(네트워크·공급자 5xx 등). 지수 백오프로 재시도한다."""


class PermanentError(Exception):
    """입력·권한 오류. 재시도 없이 바로 failed. 메시지는 사용자에게 보여도 되는 문구만."""


# DB 함수가 사용자 문구로 거부하는 SQLSTATE → 재시도하지 않고 그 문구로 failed (task-024b)
PERMANENT_SQLSTATES = {
    "RD001": "보관 기간이 지나 원본/음성 파일이 삭제되어 다시 렌더할 수 없습니다",
}


class Stopped(Exception):
    """취소·시간 초과로 처리기를 중단할 때 처리기가 던진다."""


@dataclass
class Message:
    msg_id: int
    read_ct: int
    job_id: str


class Repo(Protocol):
    def read(self, queue: str, vt: int) -> Message | None: ...
    def start(self, queue: str, msg: Message) -> dict[str, Any]: ...
    def succeed(self, queue: str, msg: Message) -> bool: ...
    def fail(self, queue: str, msg: Message, error: str) -> bool: ...
    def retry(self, queue: str, msg: Message, error: str, delay: int) -> bool: ...
    def heartbeat(self, queue: str, msg: Message, vt: int) -> str | None: ...
    def stop(self, queue: str, msg: Message) -> None: ...


@dataclass
class JobContext:
    """처리기에 넘기는 실행 문맥. 처리기는 오래 걸리는 구간마다 `check()`를 부른다."""

    job_id: str
    type: str
    step: int
    attempts: int
    payload: dict[str, Any]
    deadline: float
    stop_event: threading.Event = field(default_factory=threading.Event)
    stop_reason: str | None = None

    def stop(self, reason: str) -> None:
        if self.stop_reason is None:
            self.stop_reason = reason
        self.stop_event.set()

    def check(self) -> None:
        if time.monotonic() > self.deadline:
            self.stop("timeout")
        if self.stop_event.is_set():
            raise Stopped(self.stop_reason or "stopped")

    def sleep(self, seconds: float) -> None:
        """중단 신호를 받으면 바로 깨는 대기."""
        end = time.monotonic() + seconds
        while True:
            self.check()
            left = end - time.monotonic()
            if left <= 0:
                return
            self.stop_event.wait(min(left, 0.5))


Handler = Callable[[JobContext], None]


def backoff_seconds(attempt: int) -> int:
    """attempt(1부터)번째 실패 뒤 다음 시도까지 대기: 10·20·40… 최대 300초."""
    return min(BACKOFF_BASE_SECONDS * 2 ** max(attempt - 1, 0), BACKOFF_MAX_SECONDS)


class Heartbeat:
    """실행 중 HEARTBEAT_SECONDS마다 vt 연장 + 상태 확인. running이 아니면 처리기를 중단시킨다.

    하트비트는 별도 DB 연결(repo)로 돈다(같은 연결을 두 스레드가 동시에 쓰지 않게).
    """

    def __init__(self, repo: Repo, queue: str, msg: Message, ctx: JobContext,
                 interval: float = HEARTBEAT_SECONDS, log: Callable[[str], None] = print) -> None:
        self._repo, self._queue, self._msg, self._ctx = repo, queue, msg, ctx
        self._interval, self._log = interval, log
        self._done = threading.Event()
        self._thread = threading.Thread(target=self._run, name=f"heartbeat-{msg.msg_id}", daemon=True)

    def __enter__(self) -> "Heartbeat":
        self._thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self._done.set()
        self._thread.join(timeout=5)

    def beat(self) -> None:
        try:
            status = self._repo.heartbeat(self._queue, self._msg, VT_SECONDS)
        except Exception as exc:  # 연장 실패는 다음 주기에 다시 시도(vt 12분 여유)
            self._log(f"heartbeat 실패 job={self._ctx.job_id} err={type(exc).__name__}")
            return
        if status != "running":
            self._ctx.stop(status or "missing")

    def _run(self) -> None:
        while not self._done.wait(self._interval):
            self.beat()
            if self._ctx.stop_event.is_set():
                return


def process_message(repo: Repo, heartbeat_repo: Repo, queue: str, msg: Message,
                    handlers: dict[str, Handler], *, log: Callable[[str], None] = print,
                    heartbeat_interval: float = HEARTBEAT_SECONDS) -> str:
    """메시지 1건 처리. 반환: 최종 동작(succeeded·failed·retry·stopped·skipped)."""
    started = repo.start(queue, msg)
    action = started.get("action")
    if action != "run":
        log(f"skip job={msg.job_id} queue={queue} action={action} status={started.get('status')}")
        return "skipped" if action == "stop" else "failed"

    job_type = started["type"]
    ctx = JobContext(
        job_id=msg.job_id,
        type=job_type,
        step=int(started["step"]),
        attempts=int(started["attempts"]),
        payload=started.get("payload") or {},
        deadline=time.monotonic() + TIME_LIMIT_SECONDS.get(job_type, 600),
    )
    handler = handlers.get(job_type)
    if handler is None:
        repo.fail(queue, msg, f"처리할 수 없는 작업 종류입니다: {job_type}")
        return "failed"

    log(f"run job={msg.job_id} type={job_type} attempt={ctx.attempts}")
    try:
        with Heartbeat(heartbeat_repo, queue, msg, ctx, interval=heartbeat_interval, log=log):
            handler(ctx)
            ctx.check()  # 처리 직후 취소·시간 초과가 들어왔으면 결과를 버린다
    except Stopped:
        if ctx.stop_reason == "timeout":
            repo.fail(queue, msg, "시간 초과")
            log(f"timeout job={msg.job_id}")
            return "failed"
        repo.stop(queue, msg)
        log(f"stopped job={msg.job_id} reason={ctx.stop_reason}")
        return "stopped"
    except PermanentError as exc:
        repo.fail(queue, msg, str(exc))
        log(f"failed job={msg.job_id} err=PermanentError")
        return "failed"
    except Exception as exc:  # TransientError 와 예상하지 못한 오류: 재시도(read_ct 상한은 DB가 판단)
        sqlstate = getattr(exc, "sqlstate", None) or ""
        permanent = PERMANENT_SQLSTATES.get(sqlstate)
        if permanent is not None:
            repo.fail(queue, msg, permanent)
            log(f"failed job={msg.job_id} err=sqlstate {sqlstate}")
            return "failed"
        # 오류 원문에 키·서명 URL이 섞일 수 있어 저장·로그에는 종류만 남긴다
        reason = str(exc) if isinstance(exc, TransientError) else f"일시 오류({type(exc).__name__})"
        delay = backoff_seconds(ctx.attempts)
        if repo.retry(queue, msg, reason, delay):
            log(f"retry job={msg.job_id} attempt={ctx.attempts} delay={delay}s err={type(exc).__name__}")
            return "retry"
        log(f"stopped job={msg.job_id} (재시도 전 상태 변경)")
        return "stopped"

    if repo.succeed(queue, msg):
        log(f"succeeded job={msg.job_id}")
        return "succeeded"
    log(f"discarded job={msg.job_id} (완료 전 취소·시간 초과)")
    return "stopped"


def poll_once(repo: Repo, heartbeat_repo: Repo, handlers: dict[str, Handler],
              queues: tuple[str, ...] = QUEUES, **kwargs: Any) -> int:
    """큐마다 1건씩 읽어 처리. 처리한 건수를 돌려준다."""
    done = 0
    for queue in queues:
        msg = repo.read(queue, VT_SECONDS)
        if msg is None:
            continue
        process_message(repo, heartbeat_repo, queue, msg, handlers, **kwargs)
        done += 1
    return done
