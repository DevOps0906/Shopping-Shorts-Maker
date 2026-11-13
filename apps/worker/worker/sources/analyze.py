"""select_sources 작업 처리기(02 단계, analyze 큐 공유): 후보 대표 프레임 ↔ 승인 제품 이미지 일치도 → 점수 → 상위 20편 저장.

- 입력: job payload `product_image_path`(sources 버킷 객체 경로 `<user_id>/<project_id>/<파일>`).
- 후보: 그 작업 프로젝트의 sources. file_path 가 있으면 원본 파일, 없으면 thumbnail_path 로 점수(일치도 40·화질 20 고정 0.7).
- 원본은 WORKER_MEDIA_DIR, 썸네일은 WORKER_THUMB_DIR 아래 같은 객체 경로에서 읽는다(Storage 내려받기는 이후 작업).
- 썸네일: jpeg·webp, 512KiB, 한 변 4096 이하. 위장 형식·경로 오류만 격리, 없음·삭제·시간·크기 초과는 격리 없이 사유만.
- 멱등: 같은 입력이면 같은 결과를 덮어쓴다. 시간 상한: ctx.deadline 을 하위 프로세스 timeout 에 반영.
"""

from __future__ import annotations

import os
import time
from pathlib import Path, PurePosixPath
from typing import Any, Protocol

from ..jobs import JobContext, PermanentError
from . import match, media
from .select import Result, rank, score, thumbnail_score

MEDIA_DIR = os.environ.get("WORKER_MEDIA_DIR", "/tmp/media")
TIME_LIMIT_SECONDS = 300  # 스위퍼 private.job_time_limit('select_sources')와 같다
THUMB_DIR = os.environ.get("WORKER_THUMB_DIR", "/tmp/thumbs")
THUMB_KINDS = frozenset({"jpeg", "webp"})
THUMB_MAX_BYTES = 524_288  # thumbnails 버킷 상한(512 KiB)
THUMB_MAX_SIDE = 4096
# 격리하지 않는 거부 사유(위장·손상이 아니라 없음·시간·용량 문제). 그 밖의 거부는 모두 격리(true)
SOFT_REASONS = frozenset({"썸네일 없음", "썸네일이 너무 큼", "분석 시간 초과", "후보 상한 밖"})
MAX_CANDIDATES = 120  # 회차당 후보 60편 안팎(planning 4장)의 두 배


class SourcesRepo(Protocol):
    def context(self, job_id: str) -> dict[str, Any]: ...
    def save(self, job_id: str, results: list[Result]) -> int: ...


def resolve(root: Path, object_path: Any, owner_prefix: str) -> Path:
    """객체 경로를 root/<user>/<project>/ 아래 실제 경로로. 다른 사용자·프로젝트 경로, 절대 경로, '..',
    심볼릭 링크(경로 중간 포함)는 거부."""
    if not isinstance(object_path, str) or not object_path or "\\" in object_path or "\x00" in object_path:
        raise media.MediaRejected("파일 경로가 올바르지 않음")
    pure = PurePosixPath(object_path)
    if pure.is_absolute() or ".." in pure.parts or not object_path.startswith(owner_prefix):
        raise media.MediaRejected("파일 경로가 올바르지 않음")
    base = root.resolve()
    owner_dir = (base / owner_prefix).resolve()
    current = base
    for part in pure.parts:
        current = current / part
        if current.is_symlink():
            raise media.MediaRejected("파일 경로가 올바르지 않음")
    path = (base / pure).resolve()
    if owner_dir not in path.parents or base not in owner_dir.parents:
        raise media.MediaRejected("파일 경로가 올바르지 않음")
    return path


def _left(ctx: JobContext) -> float:
    return min(media.PROC_TIMEOUT_SEC, ctx.deadline - time.monotonic())


def _thumb_frames(ctx: JobContext, thumb_root: Path, object_path: Any, prefix: str) -> tuple[bytes, ...]:
    path = resolve(thumb_root, object_path, prefix)
    if not path.is_file():
        raise media.MediaRejected("썸네일 없음")
    if media.sniff(path) not in THUMB_KINDS:  # 형식(서명·확장자)을 먼저 거른다
        raise media.MediaRejected("허용하지 않는 파일 형식")
    if path.stat().st_size > THUMB_MAX_BYTES:
        raise media.MediaRejected("썸네일이 너무 큼")
    probed = media.probe(path, _left(ctx))
    if max(probed.width, probed.height) > THUMB_MAX_SIDE:
        raise media.MediaRejected("썸네일 해상도 범위 밖")
    return tuple(media.frames(path, probed, _left(ctx)))


def analyze(ctx: JobContext, repo: SourcesRepo, root: Path, thumb_root: Path | None = None) -> list[Result]:
    info = repo.context(ctx.job_id)
    prefix = f"{info['user_id']}/{info['project_id']}/"
    try:
        product_path = resolve(root, ctx.payload.get("product_image_path"), prefix)
        product_probe = media.probe(product_path, _left(ctx))
        if product_probe.kind not in media.IMAGE_KINDS:
            raise media.MediaRejected("제품 이미지는 png·jpg·webp만")
        product = media.frames(product_path, product_probe, _left(ctx))[0]
    except media.MediaRejected as exc:
        ctx.check()  # 시간 상한 때문이면 Stopped(timeout)
        raise PermanentError(f"승인 제품 이미지 확인 실패: {exc}") from exc

    thumb_root = thumb_root or Path(THUMB_DIR)
    sources = info.get("sources", [])
    with_media = [s for s in sources if s.get("file_path") or s.get("thumbnail_path")]
    candidates = with_media[:MAX_CANDIDATES]
    scored: dict[str, float] = {}
    rejected: dict[str, str] = {}
    soft: set[str] = set()
    for src in sources:  # 파일도 썸네일(없거나 삭제됨)도 없는 후보: 점수 없이 사유만, 격리하지 않음
        if not src.get("file_path") and not src.get("thumbnail_path"):
            rejected[str(src["id"])] = "썸네일 없음"
            soft.add(str(src["id"]))
    for src in with_media[MAX_CANDIDATES:]:  # 상한 밖은 조용히 빼지 않고 사유를 남긴다
        rejected[str(src["id"])] = "후보 상한 밖"
        soft.add(str(src["id"]))
    for src in candidates:
        ctx.check()
        sid = str(src["id"])
        if not src.get("file_path"):
            try:
                frames = _thumb_frames(ctx, thumb_root, src["thumbnail_path"], prefix)
            except media.MediaRejected as exc:
                ctx.check()
                rejected[sid] = str(exc)
                if str(exc) in SOFT_REASONS:
                    soft.add(sid)
                continue
            scored[sid] = thumbnail_score(match.best_match(product, list(frames)))
            continue
        try:
            path = resolve(root, src["file_path"], prefix)
            probed = media.probe(path, _left(ctx))
            frames = media.frames(path, probed, _left(ctx))
        except media.MediaRejected as exc:
            ctx.check()
            rejected[sid] = str(exc)
            if str(exc) in SOFT_REASONS:
                soft.add(sid)
            continue
        scored[sid] = score(match.best_match(product, frames), probed.width, probed.height)

    results = rank(scored, rejected, soft=frozenset(soft))
    ctx.check()
    repo.save(ctx.job_id, results)
    return results


class PgSourcesRepo:
    """worker_role 은 sources 를 직접 읽거나 쓰지 못한다. 실행 중 select_sources 작업 범위로 묶인 함수만 부른다."""

    def __init__(self, conn: Any) -> None:
        self.conn = conn

    def context(self, job_id: str) -> dict[str, Any]:
        row = self.conn.execute("select private.analyze_sources_context(%s) as ctx", (job_id,)).fetchone()
        return row["ctx"]

    def save(self, job_id: str, results: list[Result]) -> int:
        from psycopg.types.json import Jsonb

        payload = [{"id": r.source_id, "score": r.score, "rank": r.rank, "exclude_reason": r.exclude_reason,
                    "quarantined": r.quarantined} for r in results]
        row = self.conn.execute("select private.save_source_scores(%s, %s) as n",
                                (job_id, Jsonb(payload))).fetchone()
        return int(row["n"])


def handle(ctx: JobContext) -> None:
    from ..db import connect

    # jobs.TIME_LIMIT_SECONDS 에 없는 종류라 기본 600초가 잡히므로 여기서 스위퍼 상한으로 줄인다
    ctx.deadline = min(ctx.deadline, time.monotonic() + TIME_LIMIT_SECONDS)
    with connect() as conn:
        analyze(ctx, PgSourcesRepo(conn), Path(MEDIA_DIR))
