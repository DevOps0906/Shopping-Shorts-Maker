"""tts 작업 처리기(04 목소리, tts 큐). 시간 상한 2분(jobs.TIME_LIMIT_SECONDS['tts'] · private.job_time_limit).

입력: job payload {voice_id, upload_url, upload_expires_at}. 대본은 payload 가 아니라 DB 승인 대본(private.tts_job_context).
순서: 승인 대본 → 공급자 합성(한 번에, tmp/<job_id>.wav 캐시) → silencedetect 문장 경계 → 단어 타이밍
→ ffprobe 재검사(형식·길이·타이밍) → 서명 URL 업로드 → voice_takes 기록.
서명 URL의 실제 기한은 Storage 기본값(약 2시간)이고 payload.upload_expires_at(10분)은 워커가 지키는 UX용 기한이다.
성공·실패 처리(settle·release)는 jobs.process_message 가 한다. 여기서는 오류를 PermanentError·TransientError 로만 바꾼다.
"""

from __future__ import annotations

import io
import os
import re
import tempfile
import time
import wave
from pathlib import Path
from typing import Any, Callable, Protocol

from ..jobs import JobContext, PermanentError, Stopped, TransientError
from ..sources.media import MediaRejected
from .media import probe_wav, verify_take
from .providers import ProviderError, TTSProvider, get_provider
from .storage import UploadTarget, parse_target, upload
from .timing import Timing, build_timing, silence_gaps
from .voices import VOICE_IDS

PROVIDER_TIMEOUT_MAX = 90.0
STEP_TIMEOUT_MAX = 30.0

MSG_BAD_VOICE = "목소리를 다시 골라 주세요."
MSG_NO_SCRIPT = "승인된 대본이 없습니다. 03 대본을 승인한 뒤 다시 시도해 주세요."
MSG_CHECK_FAILED = "만든 음성 파일 검사에 실패했습니다. 다시 생성해 주세요."
MSG_SAVE_FAILED = "음성을 저장하지 못했습니다. 다시 생성해 주세요."


class TtsRepo(Protocol):
    def context(self, job_id: str) -> dict[str, Any]: ...
    def save(self, job_id: str, voice_id: str, audio_path: str, duration_sec: float, timing: Timing) -> str: ...


Uploader = Callable[[UploadTarget, bytes, str, float], None]


def _left(ctx: JobContext, cap: float) -> float:
    ctx.check()
    return max(1.0, min(cap, ctx.deadline - time.monotonic() - 1.0))


def to_wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:  # 16bit 모노 PCM → wav
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def cache_path(job_id: str) -> Path:
    """합성 결과 캐시(tmpfs). 재시도 때 공급자를 다시 부르지 않으려고 작업마다 1개."""
    safe = re.sub(r"[^0-9A-Za-z-]", "", job_id)[:64] or "job"
    return Path(os.environ.get("WORKER_TTS_CACHE") or Path(tempfile.gettempdir()) / "tts-cache") / f"{safe}.wav"


def _synthesize_cached(ctx: JobContext, provider: TTSProvider, text: str, voice_id: str,
                       path: Path) -> tuple[bytes, float, dict[str, int], str]:
    """캐시가 있고 검사를 통과하면 재사용(과금 0), 아니면 합성 후 캐시에 쓴다."""
    if path.is_file():
        try:
            duration = probe_wav(path, _left(ctx, STEP_TIMEOUT_MAX))
            return path.read_bytes(), duration, {}, "cache"
        except MediaRejected:
            path.unlink(missing_ok=True)
    speech = provider.synthesize(text, voice_id, _left(ctx, PROVIDER_TIMEOUT_MAX))
    data = to_wav(speech.pcm, speech.rate)
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(".part")
    part.write_bytes(data)
    part.replace(path)
    return data, len(speech.pcm) / 2 / speech.rate, speech.usage, speech.model


def run_tts(ctx: JobContext, repo: TtsRepo, provider: TTSProvider, uploader: Uploader = upload,
            log: Callable[[str], None] = print) -> dict[str, Any]:
    cached = cache_path(ctx.job_id)
    keep_cache = False
    try:
        voice_id = ctx.payload.get("voice_id")
        if not isinstance(voice_id, str) or voice_id not in VOICE_IDS:
            raise PermanentError(MSG_BAD_VOICE)
        target = parse_target(ctx.payload)

        info = repo.context(ctx.job_id)
        lines = [str(x).strip() for x in info.get("lines") or [] if str(x).strip()]
        if not lines:
            raise PermanentError(MSG_NO_SCRIPT)
        if not target.object_path.startswith(f"{info['user_id']}/{info['project_id']}/"):
            raise ProviderError("음성 저장 위치가 올바르지 않습니다. 다시 생성해 주세요.", transient=False)

        data, duration, usage, model = _synthesize_cached(ctx, provider, "\n".join(lines), voice_id, cached)
        try:
            # 합성 이후 단계: 공급자를 다시 부르는 재시도가 과금을 늘리므로, 예상 못한 오류는 영구 실패로
            gaps = silence_gaps(str(cached), _left(ctx, STEP_TIMEOUT_MAX))
            timing = build_timing(lines, gaps, duration)
            verify_take(cached, round(duration, 3), timing.sentences, timing.words, _left(ctx, STEP_TIMEOUT_MAX))
            uploader(target, data, "audio/wav", _left(ctx, STEP_TIMEOUT_MAX))
            ctx.check()
            take_id = repo.save(ctx.job_id, voice_id, target.object_path, round(duration, 3), timing)
        except (Stopped, PermanentError, TransientError, ProviderError):
            raise
        except MediaRejected:
            raise PermanentError(MSG_CHECK_FAILED) from None
        except Exception:
            raise PermanentError(MSG_SAVE_FAILED) from None
    except ProviderError as exc:
        if exc.transient:
            keep_cache = True  # 업로드 일시 오류 등: 다음 시도에서 캐시 재사용
            raise TransientError(str(exc)) from None
        raise PermanentError(str(exc)) from None
    except TransientError:
        keep_cache = True
        raise
    finally:
        if not keep_cache:
            cached.unlink(missing_ok=True)

    log(f"tts job={ctx.job_id} provider={provider.name} model={model} voice={voice_id} "
        f"in_tokens={usage.get('input_tokens', 0)} out_tokens={usage.get('output_tokens', 0)} "
        f"audio_ms={int(duration * 1000)} sentences={len(timing.sentences)} words={len(timing.words)} method={timing.method}")
    return {"take_id": take_id, "duration_sec": duration, "timing": timing, "usage": usage, "model": model}


class PgTtsRepo:
    """worker_role 은 scripts·voice_takes 를 직접 읽거나 쓰지 못한다. 실행 중 tts 작업 범위로 묶인 함수만 부른다."""

    def __init__(self, conn: Any) -> None:
        self.conn = conn

    def context(self, job_id: str) -> dict[str, Any]:
        row = self.conn.execute("select private.tts_job_context(%s) as ctx", (job_id,)).fetchone()
        return row["ctx"]

    def save(self, job_id: str, voice_id: str, audio_path: str, duration_sec: float, timing: Timing) -> str:
        from psycopg.types.json import Jsonb

        row = self.conn.execute(
            "select private.save_voice_take(%s, %s, %s, %s, %s, %s, %s) as id",
            (job_id, voice_id, audio_path, duration_sec,
             Jsonb(timing.sentences), Jsonb(timing.words), Jsonb(timing.pauses))).fetchone()
        return str(row["id"])


def handle(ctx: JobContext) -> None:
    from ..db import connect

    with connect() as conn:
        run_tts(ctx, PgTtsRepo(conn), get_provider())
