"""psycopg 3 저장소. worker_login(= worker_role 권한)으로 접속하고, 상태 전이는 private.job_* 함수만 부른다."""

from __future__ import annotations

import os
import uuid
from typing import Any

import psycopg
from psycopg.rows import dict_row

from .jobs import Message


def connect() -> psycopg.Connection[dict[str, Any]]:
    """환경 변수로 접속. 비밀번호는 로그·예외 메시지에 넣지 않는다."""
    return psycopg.connect(
        host=os.environ["WORKER_DB_HOST"],
        port=int(os.environ.get("WORKER_DB_PORT", "5432")),
        dbname=os.environ["WORKER_DB_NAME"],
        user=os.environ.get("WORKER_DB_USER", "worker_login"),
        password=os.environ["WORKER_DB_PASSWORD"],
        application_name="shorts-worker",
        connect_timeout=10,
        autocommit=True,  # 함수 호출 1번 = 트랜잭션 1개
        row_factory=dict_row,
    )


class PgRepo:
    def __init__(self, conn: psycopg.Connection[dict[str, Any]]) -> None:
        self.conn = conn

    def _one(self, sql: str, params: tuple[Any, ...]) -> Any:
        row = self.conn.execute(sql, params).fetchone()
        return None if row is None else next(iter(row.values()))

    def read(self, queue: str, vt: int) -> Message | None:
        row = self.conn.execute(
            "select msg_id, read_ct, message from pgmq.read(%s, %s, 1)", (queue, vt)
        ).fetchone()
        if row is None:
            return None
        job_id = (row["message"] or {}).get("job_id")
        try:
            uuid.UUID(str(job_id))
        except ValueError:
            # 작업 생성 함수만 send 하므로 정상 경로에서는 없다. 처리할 수 없으니 치운다.
            self.conn.execute("select pgmq.archive(%s, %s)", (queue, row["msg_id"]))
            print(f"bad message archived queue={queue} msg_id={row['msg_id']}", flush=True)
            return None
        return Message(msg_id=row["msg_id"], read_ct=row["read_ct"], job_id=str(job_id))

    def start(self, queue: str, msg: Message) -> dict[str, Any]:
        return self._one("select private.job_start(%s, %s, %s, %s)",
                         (queue, msg.msg_id, msg.job_id, msg.read_ct))

    def succeed(self, queue: str, msg: Message) -> bool:
        return bool(self._one("select private.job_succeed(%s, %s, %s)", (queue, msg.msg_id, msg.job_id)))

    def fail(self, queue: str, msg: Message, error: str) -> bool:
        return bool(self._one("select private.job_fail(%s, %s, %s, %s)", (queue, msg.msg_id, msg.job_id, error)))

    def retry(self, queue: str, msg: Message, error: str, delay: int) -> bool:
        return bool(self._one("select private.job_retry(%s, %s, %s, %s, %s)",
                              (queue, msg.msg_id, msg.job_id, error, delay)))

    def heartbeat(self, queue: str, msg: Message, vt: int) -> str | None:
        return self._one("select private.job_heartbeat(%s, %s, %s, %s)", (queue, msg.msg_id, msg.job_id, vt))

    def stop(self, queue: str, msg: Message) -> None:
        self.conn.execute("select private.job_stop(%s, %s, %s)", (queue, msg.msg_id, msg.job_id))
