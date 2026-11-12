"""워커 1건 처리 규칙 단위 테스트(가짜 저장소). DB 쪽 전이·원장은 supabase/tests/jobs_queue.sql 이 확인한다."""

from __future__ import annotations

import threading
import time
from typing import Any

import pytest

from worker import jobs
from worker.jobs import Message, PermanentError, TransientError, backoff_seconds, poll_once, process_message


class FakeRepo:
    """DB 함수(private.job_*)의 상태 전이를 흉내 낸다. 작업 1건, 최대 3회."""

    def __init__(self, job_type: str = "render", max_attempts: int = 3) -> None:
        self.status = "queued"
        self.type = job_type
        self.max_attempts = max_attempts
        self.attempts = 0
        self.read_ct = 0
        self.visible = True
        self.archived = False
        self.ledger: list[str] = ["reserve"]
        self.calls: list[tuple[Any, ...]] = []
        self.lock = threading.Lock()

    def _release(self) -> None:
        if self.status in ("failed", "canceled") and not ({"settle", "release"} & set(self.ledger)):
            self.ledger.append("release")

    def read(self, queue: str, vt: int) -> Message | None:
        if not self.visible or self.archived:
            return None
        self.read_ct += 1
        self.visible = False
        return Message(msg_id=1, read_ct=self.read_ct, job_id="job-1")

    def start(self, queue: str, msg: Message) -> dict[str, Any]:
        self.calls.append(("start", msg.read_ct))
        if self.status not in ("queued", "running"):
            self._release()
            self.archived = True
            return {"action": "stop", "status": self.status}
        if msg.read_ct > self.max_attempts:
            self.status = "failed"
            self._release()
            self.archived = True
            return {"action": "failed"}
        self.status = "running"
        self.attempts += 1
        return {"action": "run", "type": self.type, "step": 5, "attempts": self.attempts, "payload": {}}

    def succeed(self, queue: str, msg: Message) -> bool:
        with self.lock:
            self.calls.append(("succeed",))
            self.archived = True
            if self.status != "running":
                self._release()
                return False
            self.status = "succeeded"
            self.ledger.append("settle")
            return True

    def fail(self, queue: str, msg: Message, error: str) -> bool:
        self.calls.append(("fail", error))
        changed = self.status == "running"
        if changed:
            self.status = "failed"
        self._release()
        self.archived = True
        return changed

    def retry(self, queue: str, msg: Message, error: str, delay: int) -> bool:
        self.calls.append(("retry", error, delay))
        if self.status != "running":
            self._release()
            self.archived = True
            return False
        self.status = "queued"
        self.visible = True  # 테스트에서는 백오프 대기 없이 바로 다시 보이게
        return True

    def heartbeat(self, queue: str, msg: Message, vt: int) -> str | None:
        with self.lock:
            self.calls.append(("heartbeat", vt))
            return self.status

    def stop(self, queue: str, msg: Message) -> None:
        self.calls.append(("stop",))
        self._release()
        self.archived = True


def run_one(repo: FakeRepo, handler, **kwargs: Any) -> str:
    msg = repo.read(repo.type, jobs.VT_SECONDS)
    assert msg is not None
    return process_message(repo, repo, repo.type, msg, {repo.type: handler}, log=lambda _: None, **kwargs)


def test_success_settles_once_and_archives() -> None:
    repo = FakeRepo()
    assert run_one(repo, lambda ctx: None) == "succeeded"
    assert repo.status == "succeeded"
    assert repo.ledger == ["reserve", "settle"]
    assert repo.archived


def test_permanent_error_fails_immediately_with_release() -> None:
    repo = FakeRepo()

    def handler(ctx):
        raise PermanentError("입력 오류: 지원하지 않는 형식")

    assert run_one(repo, handler) == "failed"
    assert repo.status == "failed"
    assert repo.ledger == ["reserve", "release"]
    assert [c[0] for c in repo.calls].count("retry") == 0


def test_transient_error_retries_with_backoff_then_fails_after_3() -> None:
    repo = FakeRepo()

    def handler(ctx):
        raise TransientError("일시 오류: 공급자 503")

    results = []
    while (msg := repo.read("render", jobs.VT_SECONDS)) is not None:
        results.append(process_message(repo, repo, "render", msg, {"render": handler}, log=lambda _: None))
    assert results == ["retry", "retry", "retry", "failed"]
    assert [c[2] for c in repo.calls if c[0] == "retry"] == [10, 20, 40]
    assert repo.status == "failed"
    assert repo.attempts == 3
    assert repo.ledger == ["reserve", "release"]
    assert repo.archived


def test_unexpected_error_retries_without_leaking_message() -> None:
    repo = FakeRepo()

    def handler(ctx):
        raise RuntimeError("https://storage.example/sign?token=SECRET")

    assert run_one(repo, handler) == "retry"
    error = next(c[1] for c in repo.calls if c[0] == "retry")
    assert "SECRET" not in error and "RuntimeError" in error


def test_cancel_detected_by_heartbeat_stops_and_releases() -> None:
    repo = FakeRepo()
    seen_running = threading.Event()

    def handler(ctx):
        seen_running.set()
        repo.status = "canceled"  # 웹 서버가 실행 중에 취소
        ctx.sleep(5)  # 하트비트가 깨운다

    t0 = time.monotonic()
    assert run_one(repo, handler, heartbeat_interval=0.05) == "stopped"
    assert time.monotonic() - t0 < 2
    assert repo.status == "canceled"
    assert repo.ledger == ["reserve", "release"]
    assert repo.archived
    assert ("succeed",) not in repo.calls
    assert any(c[0] == "heartbeat" and c[1] == jobs.VT_SECONDS for c in repo.calls)


def test_canceled_before_start_is_skipped() -> None:
    repo = FakeRepo()
    repo.status = "canceled"
    called = []
    assert run_one(repo, lambda ctx: called.append(1)) == "skipped"
    assert called == []
    assert repo.ledger == ["reserve", "release"]


def test_cancel_after_handler_finishes_discards_result() -> None:
    repo = FakeRepo()

    def handler(ctx):
        repo.status = "canceled"

    # 하트비트가 돌기 전에 끝나도 succeed 가 running 조건으로 거부 → release
    assert run_one(repo, handler, heartbeat_interval=10) == "stopped"
    assert repo.ledger == ["reserve", "release"]


def test_time_limit_fails_job(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(jobs.TIME_LIMIT_SECONDS, "render", 0.1)
    repo = FakeRepo()
    assert run_one(repo, lambda ctx: ctx.sleep(5)) == "failed"
    assert ("fail", "시간 초과") in repo.calls
    assert repo.ledger == ["reserve", "release"]


def test_unknown_type_fails() -> None:
    repo = FakeRepo(job_type="analyze")
    msg = repo.read("analyze", jobs.VT_SECONDS)
    assert process_message(repo, repo, "analyze", msg, {}, log=lambda _: None) == "failed"
    assert repo.status == "failed"


def test_backoff_is_exponential_and_capped() -> None:
    assert [backoff_seconds(n) for n in (1, 2, 3, 4)] == [10, 20, 40, 80]
    assert backoff_seconds(20) == jobs.BACKOFF_MAX_SECONDS


def test_poll_once_reads_each_queue() -> None:
    repo = FakeRepo()
    assert poll_once(repo, repo, {"render": lambda ctx: None}, queues=("render", "tts"), log=lambda _: None) == 1
    assert poll_once(repo, repo, {"render": lambda ctx: None}, queues=("render",), log=lambda _: None) == 0
