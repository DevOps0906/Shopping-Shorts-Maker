"""select_sources 작업 처리기(02 단계, analyze 큐 공유): 후보 대표 프레임 ↔ 승인 제품 이미지 일치도 → 점수 → 상위 20편 저장.

- 입력: job payload `product_image_path`(sources 버킷 객체 경로 `<user_id>/<project_id>/<파일>`).
- 후보: 그 작업 프로젝트의 sources 중 file_path 가 있는 행(목록만 수집한 행은 건너뜀, D8).
- 파일은 WORKER_MEDIA_DIR 아래 같은 객체 경로에서 읽는다(Storage 내려받기는 이후 작업).
- 멱등: 같은 입력이면 같은 결과를 덮어쓴다. 시간 상한: ctx.deadline 을 하위 프로세스 timeout 에 반영.
"""

from __future__ import annotations

import os
import time
from pathlib import Path, PurePosixPath
from typing import Any, Protocol

from ..jobs import JobContext, PermanentError
from . import match, media
from .select import Result, rank, score

MEDIA_DIR = os.environ.get("WORKER_MEDIA_DIR", "/tmp/media")
TIME_LIMIT_SECONDS = 300  # 스위퍼 private.job_time_limit('select_sources')와 같다
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


def analyze(ctx: JobContext, repo: SourcesRepo, root: Path) -> list[Result]:
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

    candidates = [s for s in info.get("sources", []) if s.get("file_path")][:MAX_CANDIDATES]
    scored: dict[str, float] = {}
    rejected: dict[str, str] = {}
    for src in candidates:
        ctx.check()
        sid = str(src["id"])
        try:
            path = resolve(root, src["file_path"], prefix)
            probed = media.probe(path, _left(ctx))
            frames = media.frames(path, probed, _left(ctx))
        except media.MediaRejected as exc:
            ctx.check()
            rejected[sid] = str(exc)
            continue
        scored[sid] = score(match.best_match(product, frames), probed.width, probed.height)

    results = rank(scored, rejected)
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

        payload = [{"id": r.source_id, "score": r.score, "rank": r.rank, "exclude_reason": r.exclude_reason}
                   for r in results]
        row = self.conn.execute("select private.save_source_scores(%s, %s) as n",
                                (job_id, Jsonb(payload))).fetchone()
        return int(row["n"])


def handle(ctx: JobContext) -> None:
    from ..db import connect

    # jobs.TIME_LIMIT_SECONDS 에 없는 종류라 기본 600초가 잡히므로 여기서 스위퍼 상한으로 줄인다
    ctx.deadline = min(ctx.deadline, time.monotonic() + TIME_LIMIT_SECONDS)
    with connect() as conn:
        analyze(ctx, PgSourcesRepo(conn), Path(MEDIA_DIR))
