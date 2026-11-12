"""종류별 처리기. 지금은 스텁: 실제 TTS(task-019)·렌더(task-020)·분석은 이후 작업에서 채운다.

처리기 규칙
- 오래 걸리는 구간마다 `ctx.check()`(또는 `ctx.sleep()`)를 불러 취소·시간 초과를 받는다.
- 입력·권한 오류는 PermanentError, 일시 오류는 TransientError 로 던진다.
- 결과 기록(renders·voice_takes)은 이후 작업에서 정한다. 로그에 키·서명 URL·payload 원문을 남기지 않는다.
"""

from __future__ import annotations

import os

from .jobs import Handler, JobContext

STUB_SECONDS = float(os.environ.get("WORKER_STUB_SECONDS", "1"))


def _stub(ctx: JobContext) -> None:
    ctx.sleep(STUB_SECONDS)


HANDLERS: dict[str, Handler] = {
    "render": _stub,
    "tts": _stub,
    "analyze": _stub,
}
