"""워커 1건 처리 규칙 단위 테스트(가짜 저장소). DB 쪽 전이·원장은 supabase/tests/jobs_queue.sql 이 확인한다."""

from __future__ import annotations

import threading
import time
from typing import Any

import pytest

from worker import jobs
from worker.jobs import JobContext, Message, PermanentError, TransientError, backoff_seconds, concurrency_from_env, consume, poll_queue, process_message


class FakeRepo:
    """DB 함수(nomad_shorts_private.job_*)의 상태 전이를 흉내 낸다. 작업 1건, 최대 3회."""

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


def test_retention_deleted_sqlstate_fails_permanently_with_user_message() -> None:
    repo = FakeRepo()

    class FakeDbError(Exception):
        sqlstate = "RD001"

    def handler(ctx):
        raise FakeDbError("ERROR: 내부 원문")

    assert run_one(repo, handler) == "failed"
    assert repo.status == "failed"
    assert [c[0] for c in repo.calls].count("retry") == 0
    error = next(c[1] for c in repo.calls if c[0] == "fail")
    assert error == "보관 기간이 지나 원본/음성 파일이 삭제되어 다시 렌더할 수 없습니다"
    assert repo.ledger == ["reserve", "release"]


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


def test_poll_queue_reads_one_message() -> None:
    repo = FakeRepo()
    assert poll_queue(repo, repo, "render", {"render": lambda ctx: None}, log=lambda _: None) == 1
    assert poll_queue(repo, repo, "render", {"render": lambda ctx: None}, log=lambda _: None) == 0


class QueueRepo:
    """큐 여러 건 + deferred 를 흉내 내는 가짜 저장소. 스레드 공유."""

    def __init__(self, messages: dict[str, list[str]], deferred: set[str] = frozenset()) -> None:  # type: ignore[assignment]
        self.messages = {q: list(ids) for q, ids in messages.items()}
        self.deferred = set(deferred)
        self.started: list[str] = []
        self.succeeded: list[str] = []
        self.lock = threading.Lock()

    def read(self, queue: str, vt: int) -> Message | None:
        with self.lock:
            if not self.messages.get(queue):
                return None
            job_id = self.messages[queue].pop(0)
            return Message(msg_id=hash(job_id) % 1000, read_ct=1, job_id=job_id)

    def start(self, queue: str, msg: Message) -> dict[str, Any]:
        if msg.job_id in self.deferred:
            return {"action": "deferred", "delay": 20}
        with self.lock:
            self.started.append(msg.job_id)
        return {"action": "run", "type": queue, "step": 5, "attempts": 1, "payload": {}}

    def succeed(self, queue: str, msg: Message) -> bool:
        with self.lock:
            self.succeeded.append(msg.job_id)
        return True

    def heartbeat(self, queue: str, msg: Message, vt: int) -> str | None:
        return "running"

    def fail(self, *a: Any) -> bool:
        raise AssertionError("fail 호출 안 됨")

    retry = stop = fail


def test_deferred_message_is_skipped_and_next_is_read() -> None:
    repo = QueueRepo({"render": ["busy-user-job", "other-user-job"]}, deferred={"busy-user-job"})
    ran: list[str] = []
    assert poll_queue(repo, repo, "render", {"render": lambda ctx: ran.append(ctx.job_id)}, log=lambda _: None) == 1
    assert ran == ["other-user-job"]
    assert repo.succeeded == ["other-user-job"]


def test_stop_after_deferred_reads_no_more() -> None:
    repo = QueueRepo({"render": ["busy-user-job", "other-user-job"]}, deferred={"busy-user-job"})
    stop = threading.Event()
    read = repo.read

    def read_then_stop(*a: Any) -> Any:
        msg = read(*a)
        stop.set()  # 첫 메시지(deferred)를 읽은 직후 종료 신호
        return msg

    repo.read = read_then_stop  # type: ignore[method-assign]
    ran: list[str] = []
    assert poll_queue(repo, repo, "render", {"render": lambda ctx: ran.append(ctx.job_id)}, stop, log=lambda _: None) == 0
    assert ran == []


def test_only_deferred_messages_count_as_idle() -> None:
    repo = QueueRepo({"render": ["j1", "j2"]}, deferred={"j1", "j2"})
    assert poll_queue(repo, repo, "render", {"render": lambda ctx: None}, log=lambda _: None) == 0
    assert repo.started == []


def test_tts_is_processed_while_render_is_running() -> None:
    repo = QueueRepo({"render": ["r1"], "tts": ["t1"]})
    render_started, tts_done = threading.Event(), threading.Event()
    stop = threading.Event()

    def render(ctx: JobContext) -> None:
        render_started.set()
        assert tts_done.wait(5), "렌더가 끝나기 전에 tts 가 처리되지 않음(큐별 스레드가 아님)"

    def tts(ctx: JobContext) -> None:
        assert render_started.wait(5)
        tts_done.set()

    handlers = {"render": render, "tts": tts}
    make = lambda: (repo, repo, lambda: None)  # noqa: E731
    threads = [threading.Thread(target=consume, args=(make, q, handlers, stop),
                                kwargs={"idle": 0.01, "log": lambda _: None}) for q in ("render", "tts")]
    for t in threads:
        t.start()
    assert tts_done.wait(5)
    deadline = time.monotonic() + 5
    while len(repo.succeeded) < 2 and time.monotonic() < deadline:
        time.sleep(0.01)
    stop.set()
    for t in threads:
        t.join(5)
    assert sorted(repo.succeeded) == ["r1", "t1"]


def test_concurrency_from_env_defaults_and_overrides() -> None:
    assert concurrency_from_env({}) == {"render": 1, "tts": 2, "analyze": 2}
    assert concurrency_from_env({"WORKER_CONCURRENCY_RENDER": "2", "WORKER_CONCURRENCY_TTS": "x",
                                 "WORKER_CONCURRENCY_ANALYZE": "0"}) == {"render": 2, "tts": 2, "analyze": 1}
