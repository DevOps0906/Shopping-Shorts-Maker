"""render 작업 처리기(05 편집, render 큐). 시간 상한 10분(jobs.TIME_LIMIT_SECONDS['render'] · private.job_time_limit).

입력: job payload {cuts: [원본 id(대본 줄마다)], take_id, voice_url, source_urls{id: url}, upload_url, upload_expires_at}.
대본·음성·편집 입력 원본은 payload 가 아니라 DB(private.render_job_context)에서 읽고, payload 의 컷 원본이 편집 입력
(권리 근거 있음·격리 아님·고지 확인)에 없으면 그 컷 번호로 실패한다(다음 순위 원본으로 교체 안내).
순서: 음성 내려받기 → verify_take 재검사 → 원본 내려받기·probe → 컷 계획 → ffmpeg 1회(크롭·정지 화면 채움·자막·출처·음성)
→ ffprobe 결과 검사(1080x1920 · target ±0.1초 · 영상/음성 차 ≤ 0.05초) → 서명 URL 업로드 → renders 기록(+ render_succeeded).
성공·실패 처리(settle·release)는 jobs.process_message 가 한다.
"""

from __future__ import annotations

import shutil
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Protocol

from ..jobs import JobContext, PermanentError, Stopped, TransientError
from ..sources.media import IMAGE_KINDS, MAX_FILE_BYTES, MediaRejected, probe
from ..voice.media import MAX_WAV_BYTES, verify_take
from ..voice.providers import ProviderError
from ..voice.storage import UploadTarget, upload
from . import ffmpeg
from .fetch import MSG_TIMEOUT, FetchError, download, download_url, upload_target
from .plan import PlanError, boundaries, build_cuts, credit_label, credits_text

STEP_TIMEOUT_MAX = 60.0
EXTS = {".mp4", ".mov", ".m4v", ".webm"}

MSG_BAD_CUTS = "컷 구성이 대본과 맞지 않습니다. 화면을 새로 고친 뒤 다시 만들어 주세요."
MSG_NO_TAKE = "04 목소리의 음성이 없거나 바뀌었습니다. 화면을 새로 고친 뒤 다시 만들어 주세요."
MSG_VOICE_BAD = "음성 파일 검사에 실패했습니다. 04 목소리에서 음성을 다시 만들어 주세요(직접 녹음은 WAV 16bit 모노만 편집에 쓸 수 있습니다)."
MSG_RENDER_FAILED = "영상 합치기에 실패했습니다. 다시 시도해 주세요."
MSG_SAVE_FAILED = "만든 영상을 저장하지 못했습니다. 다시 만들어 주세요."


class RenderRepo(Protocol):
    def context(self, job_id: str) -> dict[str, Any]: ...
    def save(self, job_id: str, mp4_path: str, duration_sec: float, cut_map: dict[str, Any]) -> dict[str, Any]: ...


Downloader = Callable[..., int]  # (url, dest, max_bytes, timeout, *, deadline, check) → 바이트 수
Uploader = Callable[[UploadTarget, bytes, str, float], None]


def cut_error(nos: list[int], reason: str) -> PermanentError:
    """실패한 컷 번호 안내(17-6). 화면은 '컷 N번'을 읽어 해당 컷을 표시한다."""
    joined = "·".join(f"{n}번" for n in nos)
    return PermanentError(f"컷 {joined} 원본을 쓸 수 없습니다({reason}). 다음 순위 원본으로 바꿔 다시 만들어 주세요.")


def _left(ctx: JobContext, cap: float) -> float:
    ctx.check()
    return max(1.0, min(cap, ctx.deadline - time.monotonic() - 1.0))


def _suffix(file_path: str) -> str:
    suffix = Path(file_path).suffix.lower()
    return suffix if suffix in EXTS else ".mp4"


def run_render(ctx: JobContext, repo: RenderRepo, downloader: Downloader = download, uploader: Uploader = upload,
               log: Callable[[str], None] = print) -> dict[str, Any]:
    started = time.monotonic()
    payload = ctx.payload
    info = repo.context(ctx.job_id)
    lines = [str(x).strip() for x in info.get("lines") or [] if str(x).strip()]
    target = float(info.get("target_sec") or 0)
    sources: dict[str, dict[str, Any]] = {str(s["id"]): s for s in info.get("sources") or []}
    take = info.get("take") or None

    chosen = payload.get("cuts")
    if not lines or not isinstance(chosen, list) or len(chosen) != len(lines) or target <= 0:
        raise PermanentError(MSG_BAD_CUTS)
    bad = [i + 1 for i, sid in enumerate(chosen) if not isinstance(sid, str) or sid not in sources]
    if bad:
        raise cut_error(bad, "권리 미확인·격리·삭제된 원본")
    if not take or not take.get("audio_path") or payload.get("take_id") != str(take.get("id")):
        raise PermanentError(MSG_NO_TAKE)

    work = Path(tempfile.mkdtemp(prefix="render-"))
    try:
        try:
            target_up = upload_target(payload, str(info["user_id"]), str(info["project_id"]))
            # 음성: voices 객체는 신뢰하지 않는 입력 → verify_take 로 형식·길이·타이밍 재검사
            voice = work / "voice.wav"
            downloader(download_url(payload.get("voice_url"), "voices", str(take["audio_path"])), voice,
                       MAX_WAV_BYTES, _left(ctx, STEP_TIMEOUT_MAX), deadline=ctx.deadline, check=ctx.check)
            sentences = list(take.get("sentences") or [])
            try:
                voice_sec = verify_take(voice, round(float(take["duration_sec"]), 3), sentences,
                                        list(take.get("words") or []), _left(ctx, STEP_TIMEOUT_MAX))
            except (MediaRejected, TypeError, ValueError, KeyError):
                raise PermanentError(MSG_VOICE_BAD) from None

            # 원본: 컷에 쓰인 원본만, 처음 쓰인 순서대로 한 번씩
            urls = payload.get("source_urls") if isinstance(payload.get("source_urls"), dict) else {}
            local: dict[str, tuple[str, Path]] = {}
            lengths: dict[str, float | None] = {}
            for sid in dict.fromkeys(chosen):
                nos = [i + 1 for i, x in enumerate(chosen) if x == sid]
                src = sources[sid]
                path = work / f"src-{len(local) + 1}{_suffix(str(src['file_path']))}"
                try:
                    url = download_url(urls.get(sid), "sources", str(src["file_path"]))
                    downloader(url, path, MAX_FILE_BYTES, _left(ctx, STEP_TIMEOUT_MAX),
                               deadline=ctx.deadline, check=ctx.check)
                except FetchError as exc:
                    if exc.transient or str(exc) == MSG_TIMEOUT:
                        raise
                    raise cut_error(nos, "파일 링크 만료·없음") from None
                try:
                    probed = probe(path, _left(ctx, STEP_TIMEOUT_MAX))
                except MediaRejected as exc:
                    raise cut_error(nos, str(exc)) from None
                if probed.kind in IMAGE_KINDS:
                    raise cut_error(nos, "영상이 아닌 파일")
                local[sid] = (probed.kind, path)
                lengths[sid] = probed.duration_sec

            try:
                bounds, tempo, method = boundaries(lines, sentences, voice_sec, target)
            except PlanError as exc:
                raise PermanentError(str(exc)) from None
            cuts = build_cuts(lines, bounds, chosen, lengths)
            inputs = [ffmpeg.CutInput(cut=c, kind=local[c.source_id][0], path=local[c.source_id][1]) for c in cuts]
            labels = [credit_label(sources[c.source_id].get("author", "")) for c in cuts]
            args, files = ffmpeg.build_args(inputs, voice, tempo, target, labels, "out.mp4")
            for name, text in files.items():
                (work / name).write_text(text, encoding="utf-8")

            encode_started = time.monotonic()
            try:
                ffmpeg.run(args, _left(ctx, ffmpeg.RLIMITS["RLIMIT_CPU"]), work)
                out = ffmpeg.verify_output(work / "out.mp4", target, _left(ctx, STEP_TIMEOUT_MAX))
            except MediaRejected:
                ctx.check()  # 시간 초과·취소면 그 사유로
                raise PermanentError(MSG_RENDER_FAILED) from None
            encode_sec = time.monotonic() - encode_started

            uploader(target_up, (work / "out.mp4").read_bytes(), "video/mp4", _left(ctx, STEP_TIMEOUT_MAX))
            ctx.check()
            cut_map = {
                "cuts": [{"no": c.no, "line": c.line, "source_id": c.source_id,
                          # 원본 스냅샷(설명란 출처 근거). save_render 가 DB 값으로 다시 덮어쓴다
                          "author": str(sources[c.source_id].get("author") or ""),
                          "platform": str(sources[c.source_id].get("platform") or ""),
                          "source_url": str(sources[c.source_id].get("url") or ""),
                          "collected_at": sources[c.source_id].get("collected_at"),
                          "src_start": c.src_start, "src_end": round(c.src_start + c.dur, 3),
                          "out_start": c.out_start, "out_end": c.out_end} for c in cuts],
                "credits": credits_text(cuts, sources),
                "method": method, "tempo": round(tempo, 4), "encoder": ffmpeg.ENCODER,
                "bit_rate": out.bit_rate, "encode_sec": round(encode_sec, 2),
            }
            try:
                saved = repo.save(ctx.job_id, target_up.object_path, round(out.duration_sec, 3), cut_map)
            except Exception:
                raise PermanentError(MSG_SAVE_FAILED) from None
        except FetchError as exc:
            raise (TransientError if exc.transient else PermanentError)(str(exc)) from None
        except ProviderError as exc:  # 업로드 오류(voice.storage.upload)
            raise (TransientError if exc.transient else PermanentError)(str(exc)) from None
    except (Stopped, PermanentError, TransientError):
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)

    log(f"render job={ctx.job_id} cuts={len(cuts)} sources={len(local)} target={target:g} "
        f"duration={out.duration_sec:.3f} av_diff={abs(out.video_sec - out.audio_sec):.3f} "
        f"bitrate={out.bit_rate} size={out.size} encode_sec={encode_sec:.2f} total_sec={time.monotonic() - started:.2f}")
    return {"render": saved, "cut_map": cut_map, "output": out}


class PgRenderRepo:
    """worker_role 은 sources·renders 등을 직접 읽거나 쓰지 못한다. 실행 중 render 작업 범위로 묶인 함수만 부른다."""

    def __init__(self, conn: Any) -> None:
        self.conn = conn

    def context(self, job_id: str) -> dict[str, Any]:
        row = self.conn.execute("select private.render_job_context(%s) as ctx", (job_id,)).fetchone()
        return row["ctx"]

    def save(self, job_id: str, mp4_path: str, duration_sec: float, cut_map: dict[str, Any]) -> dict[str, Any]:
        from psycopg.types.json import Jsonb

        row = self.conn.execute("select private.save_render(%s, %s, %s, %s) as r",
                                (job_id, mp4_path, duration_sec, Jsonb(cut_map))).fetchone()
        return row["r"]


def handle(ctx: JobContext) -> None:
    from ..db import connect

    with connect() as conn:
        run_render(ctx, PgRenderRepo(conn))
