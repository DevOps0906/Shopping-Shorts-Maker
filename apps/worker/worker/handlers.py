"""종류별 처리기. 지금은 스텁: 실제 TTS(task-019)·렌더(task-020)·분석은 이후 작업에서 채운다.

처리기 규칙
- 오래 걸리는 구간마다 `ctx.check()`(또는 `ctx.sleep()`)를 불러 취소·시간 초과를 받는다.
- 입력·권한 오류는 PermanentError, 일시 오류는 TransientError 로 던진다.
- 결과 기록(renders·voice_takes)은 이후 작업에서 정한다. 로그에 키·서명 URL·payload 원문을 남기지 않는다.
"""

from __future__ import annotations

import os

from .jobs import Handler, JobContext
from .render.render import handle as render
from .sources.analyze import handle as select_sources
from .voice.tts import handle as tts

STUB_SECONDS = float(os.environ.get("WORKER_STUB_SECONDS", "1"))


def _stub(ctx: JobContext) -> None:
    ctx.sleep(STUB_SECONDS)


HANDLERS: dict[str, Handler] = {
    "render": render,  # task-020: 05 편집 컷 매칭·9:16 크롭·자막·출처 표기 MP4(서명 URL 입출력)
    "tts": tts,  # task-019: 04 목소리 TTS·문장/단어 타이밍·서명 URL 업로드
    "analyze": _stub,
    "select_sources": select_sources,  # task-016: 02 소스 후보 일치도·점수·상위 20편(analyze 큐 공유)
}
