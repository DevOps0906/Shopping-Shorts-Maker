"""task-016 일치도·순위·20편 상한·체크 해제·악성 입력 거부. 픽스처는 ffmpeg lavfi 로 만든 합성 이미지·영상."""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path
from typing import Any

import pytest

from worker.jobs import JobContext, PermanentError, Stopped
from worker.sources import media
from worker.sources.analyze import analyze, resolve
from worker.sources.select import LIST_LIMIT, OUT_OF_LIST, rank

USER, PROJECT = "00000000-0000-4000-a000-000000000001", "00000000-0000-4000-a000-000000000002"
PREFIX = f"{USER}/{PROJECT}/"

# 제품 A: 흰 바탕 빨간 사각 + 가운데 파란 사각(정사각 기준 50%·25%)
PRODUCT_A = "drawbox=x=iw/4:y=ih/2-iw/4:w=iw/2:h=iw/2:color=red:t=fill," \
            "drawbox=x=iw*3/8:y=ih/2-iw/8:w=iw/4:h=iw/4:color=blue:t=fill"
# 제품 B: 초록 가로 막대 두 줄 / 제품 C: 검정 바탕 흰 격자
PRODUCT_B = "drawbox=x=0:y=ih*0.3:w=iw:h=ih*0.1:color=green:t=fill," \
            "drawbox=x=0:y=ih*0.6:w=iw:h=ih*0.1:color=yellow:t=fill"
PRODUCT_C = "drawgrid=w=iw/8:h=ih/8:t=4:c=white"


def _make(out: Path, size: str, vf: str, bg: str = "white", seconds: float | None = None) -> None:
    src = f"color=c={bg}:s={size}" + (f":d={seconds}" if seconds else "")
    args = ["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", src, "-vf", vf]
    if seconds:
        args += ["-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-r", "10"]
    else:
        args += ["-frames:v", "1"]
    subprocess.run([*args, str(out)], check=True, timeout=60)


@pytest.fixture(scope="module")
def root(tmp_path_factory: pytest.TempPathFactory) -> Path:
    base = tmp_path_factory.mktemp("media")
    d = base / USER / PROJECT
    d.mkdir(parents=True)
    _make(d / "product.png", "400x400", PRODUCT_A)
    _make(d / "a_same.mp4", "720x1280", PRODUCT_A, seconds=3)
    _make(d / "a_thumb.jpg", "1080x1920", PRODUCT_A)
    _make(d / "b_other.mp4", "720x1280", PRODUCT_B, seconds=3)
    _make(d / "c_other.mp4", "1080x1920", PRODUCT_C, bg="black", seconds=3)
    # 악성 입력: 확장자 위장(PNG를 .mp4로), HLS 재생목록·concat 스크립트를 .mp4로
    (d / "fake.mp4").write_bytes((d / "product.png").read_bytes())
    (d / "playlist.mp4").write_text("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nfile:/etc/passwd\n")
    (d / "concat.mp4").write_text("ffconcat version 1.0\nfile '/etc/passwd'\n")
    (d / "list.m3u8").write_text("#EXTM3U\n")
    return base


class FakeRepo:
    def __init__(self, sources: list[dict[str, Any]]) -> None:
        self.sources = sources
        self.saved: list[Any] = []

    def context(self, job_id: str) -> dict[str, Any]:
        return {"user_id": USER, "project_id": PROJECT, "sources": self.sources}

    def save(self, job_id: str, results: list[Any]) -> int:
        self.saved = results
        return len(results)


def _ctx(seconds: float = 300) -> JobContext:
    return JobContext(job_id="job-1", type="select_sources", step=2, attempts=1,
                      payload={"product_image_path": PREFIX + "product.png"},
                      deadline=time.monotonic() + seconds)


def _src(i: int, name: str | None) -> dict[str, Any]:
    return {"id": f"s{i:03d}", "file_path": None if name is None else PREFIX + name}


def test_same_product_ranks_above_other_products_and_limit_20(root: Path) -> None:
    sources = [_src(1, "a_same.mp4"), _src(2, "a_thumb.jpg")]
    sources += [_src(10 + i, "b_other.mp4" if i % 2 else "c_other.mp4") for i in range(22)]
    sources += [_src(90, "fake.mp4"), _src(91, "playlist.mp4"), _src(92, "concat.mp4"),
                _src(93, "list.m3u8"), _src(94, None)]
    repo = FakeRepo(sources)
    results = analyze(_ctx(), repo, root)
    by_id = {r.source_id: r for r in results}

    assert repo.saved == results
    assert {by_id["s001"].rank, by_id["s002"].rank} == {1, 2}
    others = [r.score for r in results if r.source_id not in ("s001", "s002") and r.score is not None]
    assert min(by_id["s001"].score, by_id["s002"].score) > max(others)

    listed = [r for r in results if r.rank is not None and r.exclude_reason is None]
    assert len(listed) == LIST_LIMIT
    assert all(r.exclude_reason == OUT_OF_LIST for r in results if r.rank is not None and r.rank > LIST_LIMIT)
    assert all(r.checked is False for r in results)
    # 파일 없는 목록 전용 행(D8)은 건드리지 않는다
    assert "s094" not in by_id


def test_malicious_inputs_rejected(root: Path) -> None:
    repo = FakeRepo([_src(90, "fake.mp4"), _src(91, "playlist.mp4"), _src(92, "concat.mp4"),
                     _src(93, "list.m3u8"), {"id": "s095", "file_path": "../../etc/passwd"},
                     {"id": "s096", "file_path": f"{USER}/other-project/a_same.mp4"}])
    results = {r.source_id: r for r in analyze(_ctx(), repo, root)}
    assert results["s090"].exclude_reason == "확장자와 실제 형식이 다름"
    assert results["s091"].exclude_reason == "허용하지 않는 파일 형식"
    assert results["s092"].exclude_reason == "허용하지 않는 파일 형식"
    assert results["s093"].exclude_reason == "허용하지 않는 파일 형식"
    assert results["s095"].exclude_reason == "파일 경로가 올바르지 않음"
    assert results["s096"].exclude_reason == "파일 경로가 올바르지 않음"
    assert all(r.score is None and r.rank is None and r.checked is False for r in results.values())


def test_probe_reads_real_format(root: Path) -> None:
    info = media.probe(root / PREFIX / "a_same.mp4")
    assert (info.kind, info.width, info.height) == ("mp4", 720, 1280)
    assert info.duration_sec is not None and 2.5 < info.duration_sec <= 3.5
    assert len(media.frames(root / PREFIX / "a_same.mp4", info)) == media.MAX_FRAMES


def test_resolve_stays_inside_root(tmp_path: Path) -> None:
    for bad in ("", "/etc/passwd", PREFIX + "../x.mp4", PREFIX + "a\\b.mp4", None, 3):
        with pytest.raises(media.MediaRejected):
            resolve(tmp_path, bad, PREFIX)
    assert resolve(tmp_path, PREFIX + "x.mp4", PREFIX) == (tmp_path / PREFIX / "x.mp4").resolve()


def test_bad_product_image_is_permanent(root: Path) -> None:
    ctx = _ctx()
    ctx.payload = {"product_image_path": PREFIX + "playlist.mp4"}
    with pytest.raises(PermanentError):
        analyze(ctx, FakeRepo([]), root)
    ctx.payload = {"product_image_path": PREFIX + "a_same.mp4"}  # 영상은 제품 이미지로 받지 않는다
    with pytest.raises(PermanentError):
        analyze(ctx, FakeRepo([]), root)


def test_deadline_stops_before_save(root: Path) -> None:
    repo = FakeRepo([_src(1, "a_same.mp4")])
    with pytest.raises(Stopped):
        analyze(_ctx(seconds=-1), repo, root)
    assert repo.saved == []


def test_rank_is_deterministic_and_idempotent() -> None:
    scored = {f"s{i:02d}": float(i % 7) for i in range(30)}
    first, second = rank(scored, {"x": "허용하지 않는 파일 형식"}), rank(dict(reversed(scored.items())), {"x": "허용하지 않는 파일 형식"})
    assert first == second
    assert [r.rank for r in first if r.rank] == list(range(1, 31))
    assert sum(1 for r in first if r.rank and r.exclude_reason is None) == LIST_LIMIT


def test_handlers_mapping() -> None:
    from worker.handlers import HANDLERS, _stub
    from worker.sources.analyze import handle

    assert HANDLERS["select_sources"] is handle
    assert HANDLERS["analyze"] is _stub  # 03 대본용 분석은 아직 스텁


posix_only = pytest.mark.skipif(os.name != "posix", reason="자원 상한·프로세스 그룹은 POSIX 전용")


@posix_only
def test_child_env_and_limits(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("WORKER_DB_PASSWORD", "fake-secret-016")
    code = ("import os, json, resource; r = resource.getrlimit; "
            "print(json.dumps({'env': dict(os.environ), 'as': r(resource.RLIMIT_AS)[0], "
            "'cpu': r(resource.RLIMIT_CPU)[0], 'nofile': r(resource.RLIMIT_NOFILE)[0], "
            "'fsize': r(resource.RLIMIT_FSIZE)[0], 'sid': os.getsid(0) == os.getpid()}))")
    info = json.loads(media._run([sys.executable, "-c", code], 10))
    assert "WORKER_DB_PASSWORD" not in info["env"]
    assert "fake-secret-016" not in json.dumps(info["env"])
    assert set(info["env"]) <= {"PATH", "LANG", "LC_CTYPE"}
    assert (info["as"], info["cpu"], info["nofile"], info["fsize"]) == (1 << 30, 30, 64, 1 << 20)
    assert info["sid"] is True  # 새 세션(프로세스 그룹 리더)


@posix_only
def test_timeout_kills_process_group() -> None:
    started = time.monotonic()
    with pytest.raises(media.MediaRejected, match="분석 시간 초과"):
        media._run(["sh", "-c", "sleep 30 & sleep 30"], 0.5)  # 자식의 자식까지 죽어야 파이프가 닫힌다
    assert time.monotonic() - started < 5


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def test_huge_resolution_header_rejected_without_oom(tmp_path: Path) -> None:
    # IHDR 30000×30000 RGBA(디코딩하면 3.6 GB) + 아주 작은 IDAT
    ihdr = struct.pack(">IIBBBBB", 30000, 30000, 8, 6, 0, 0, 0)
    png = (bytes.fromhex("89504e470d0a1a0a") + _png_chunk(b"IHDR", ihdr)
           + _png_chunk(b"IDAT", zlib.compress(bytes(64))) + _png_chunk(b"IEND", b""))
    bomb = tmp_path / "bomb.png"
    bomb.write_bytes(png)
    started = time.monotonic()
    with pytest.raises(media.MediaRejected):
        info = media.probe(bomb)
        media.frames(bomb, info)
    assert time.monotonic() - started < 20


@posix_only
def test_symlinks_rejected(root: Path) -> None:
    other = root / USER / "00000000-0000-4000-a000-0000000000ff"
    other.mkdir(exist_ok=True)
    (other / "secret.mp4").write_bytes((root / PREFIX / "a_same.mp4").read_bytes())
    project = root / PREFIX
    (project / "link.mp4").symlink_to(other / "secret.mp4")
    (project / "inside.mp4").symlink_to(project / "a_same.mp4")  # 같은 프로젝트 안이라도 링크는 거부
    (project / "dirlink").symlink_to(other, target_is_directory=True)
    for name in ("link.mp4", "inside.mp4", "dirlink/secret.mp4"):
        with pytest.raises(media.MediaRejected, match="파일 경로가 올바르지 않음"):
            resolve(root, PREFIX + name, PREFIX)
    # 프로젝트 디렉터리 자체가 다른 곳을 가리키는 링크여도 거부
    alias_prefix = f"{USER}/alias/"
    (root / USER / "alias").symlink_to(project, target_is_directory=True)
    with pytest.raises(media.MediaRejected):
        resolve(root, alias_prefix + "a_same.mp4", alias_prefix)
