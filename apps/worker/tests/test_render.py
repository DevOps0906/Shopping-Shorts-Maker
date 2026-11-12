"""task-020 render 처리기: 합성 원본(ffmpeg testsrc2)·합성 음성으로 MP4 생성(1080x1920 · target ±0.1초 · 영상/음성 차 ≤ 0.05초
· 음성 트랙 · 출처 표기), 편집 입력에 없는(미확인·격리) 원본 컷 거부, 서명 URL 검사, 컷 계획 규칙. 워커 이미지(ffmpeg LGPL·openh264)에서 돌린다."""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pytest

from tests.test_jobs import FakeRepo
from tests.test_voice import RATE, speech_pcm
from worker.jobs import JobContext, Message, PermanentError, Stopped, process_message
from worker.render import ffmpeg
from worker.render.fetch import MSG_TIMEOUT, FetchError, download, download_url, upload_target
from worker.render.plan import Cut, PlanError, boundaries, build_cuts, credits_text, default_assignment
from worker.render.render import run_render
from worker.voice.tts import to_wav

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg 필요(워커 이미지)")

USER, PROJECT = "00000000-0000-4000-a000-000000000001", "00000000-0000-4000-a000-000000000002"
SRC_A, SRC_B, SRC_C = ("00000000-0000-4000-b000-00000000000" + c for c in "abc")
OBJECT = f"{USER}/{PROJECT}/render-1.mp4"
LINES = ["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!", "지금 바로 확인해 보세요."]
BASE = "http://127.0.0.1:8000"


def _future(minutes: int = 30) -> str:
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()


def make_source(path: Path, size: str, seconds: float) -> None:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", f"testsrc2=size={size}:rate=30:duration={seconds}",
                    "-c:v", "libopenh264", "-b:v", "2M", "-pix_fmt", "yuv420p", str(path)], check=True)


def make_voice(path: Path, segments: list[float], gap: float = 0.4, lead: float = 0.1) -> tuple[float, list[dict[str, Any]]]:
    path.write_bytes(to_wav(speech_pcm(segments, gap, lead), RATE))
    t, sentences = lead, []
    for i, sec in enumerate(segments):
        sentences.append({"i": i, "text": LINES[i % len(LINES)], "start": round(t, 3), "end": round(t + sec, 3)})
        t += sec + (gap if i < len(segments) - 1 else lead)
    return round(t, 3), sentences


@pytest.fixture(scope="module")
def media(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Path]:
    d = tmp_path_factory.mktemp("media")
    make_source(d / "a.mp4", "1280x720", 8)  # 가로 → 9:16 크롭
    make_source(d / "b.mp4", "720x1280", 2)  # 컷보다 짧음 → 정지 화면 채움
    (d / "bad.mp4").write_bytes(b"\x00\x00\x00\x18ftypisom" + b"garbage" * 100)
    return {"a": d / "a.mp4", "b": d / "b.mp4", "bad": d / "bad.mp4", "dir": d}


@pytest.fixture(autouse=True)
def storage_base(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("WORKER_STORAGE_URL", "http://api-gw:8000")


class FakeRenderRepo:
    def __init__(self, take: dict[str, Any], target: int = 15, sources: list[dict[str, Any]] | None = None) -> None:
        self.take, self.target = take, target
        self.sources = sources if sources is not None else [
            {"id": SRC_A, "platform": "tiktok", "author": "maker_a", "url": "https://www.tiktok.com/@maker_a/video/1",
             "collected_at": "2026-11-12T00:00:00+00:00", "file_path": f"{USER}/{PROJECT}/a.mp4",
             "duration_sec": 8, "score": 90, "rights_basis": "attribution_notice"},
            {"id": SRC_B, "platform": "xiaohongshu", "author": "@maker_b", "file_path": f"{USER}/{PROJECT}/b.mp4",
             "duration_sec": 2, "score": 80, "rights_basis": "own"},
        ]
        self.saved: list[dict[str, Any]] = []

    def context(self, job_id: str) -> dict[str, Any]:
        return {"project_id": PROJECT, "user_id": USER, "target_sec": self.target, "lines": LINES,
                "take": self.take, "sources": self.sources}

    def save(self, job_id: str, mp4_path: str, duration_sec: float, cut_map: dict[str, Any]) -> dict[str, Any]:
        self.saved.append({"path": mp4_path, "duration": duration_sec, "cut_map": cut_map})
        return {"id": "render-1", "version": 1}


class Files:
    """가짜 Storage: 객체 경로 → 로컬 파일. 업로드는 결과 파일로 저장."""

    def __init__(self, mapping: dict[str, Path], out: Path) -> None:
        self.mapping, self.out = mapping, out
        self.downloads: list[str] = []
        self.uploads: list[tuple[str, str]] = []

    def download(self, url: str, dest: Path, max_bytes: int, timeout: float, **kw: Any) -> int:
        assert "deadline" in kw and callable(kw["check"])  # 작업 마감·취소 검사를 넘긴다
        assert url.startswith("http://api-gw:8000/storage/v1/object/sign/")  # 접속지는 WORKER_STORAGE_URL
        key = url.split("?")[0].split("/storage/v1/object/sign/", 1)[1]
        self.downloads.append(key)
        shutil.copyfile(self.mapping[key], dest)
        return dest.stat().st_size

    def upload(self, target: Any, data: bytes, content_type: str, timeout: float) -> None:
        self.uploads.append((target.object_path, content_type))
        self.out.write_bytes(data)


def _payload(cuts: list[str], take_id: str = "take-1", **over: Any) -> dict[str, Any]:
    p: dict[str, Any] = {
        "cuts": cuts, "take_id": take_id,
        "voice_url": f"{BASE}/storage/v1/object/sign/voices/{USER}/{PROJECT}/tts-1.wav?token=v",
        "source_urls": {sid: f"{BASE}/storage/v1/object/sign/sources/{USER}/{PROJECT}/{n}.mp4?token=s{n}"
                        for sid, n in ((SRC_A, "a"), (SRC_B, "b"), (SRC_C, "c"))},
        "upload_url": f"{BASE}/storage/v1/object/upload/sign/renders/{OBJECT}?token=u",
        "upload_expires_at": _future(),
    }
    p.update(over)
    return p


def _ctx(payload: dict[str, Any]) -> JobContext:
    return JobContext(job_id="job-1", type="render", step=5, attempts=1, payload=payload,
                      deadline=time.monotonic() + 600)


def _setup(media: dict[str, Path], tmp_path: Path, segments: list[float]) -> tuple[dict[str, Any], Files]:
    voice_sec, sentences = make_voice(tmp_path / "voice.wav", segments)
    take = {"id": "take-1", "source": "tts", "audio_path": f"{USER}/{PROJECT}/tts-1.wav",
            "duration_sec": voice_sec, "sentences": sentences, "words": []}
    files = Files({f"voices/{USER}/{PROJECT}/tts-1.wav": tmp_path / "voice.wav",
                   f"sources/{USER}/{PROJECT}/a.mp4": media["a"], f"sources/{USER}/{PROJECT}/b.mp4": media["b"],
                   f"sources/{USER}/{PROJECT}/c.mp4": media["bad"]}, tmp_path / "result.mp4")
    return take, files


def ffprobe(path: Path) -> dict[str, Any]:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "format=duration,bit_rate:stream=codec_type,codec_name,width,height,duration",
                          "-of", "json", str(path)], check=True, capture_output=True).stdout
    return json.loads(out)


# ── 합성 원본·음성으로 MP4 생성 ─────────────────────────────────────

@pytest.mark.parametrize("target,segments", [(15, [3.0, 4.0, 3.5]), (20, [4.0, 5.0, 4.5]), (15, [5.0, 5.5, 5.4])])
def test_render_mp4_meets_targets(media: dict[str, Path], tmp_path: Path, target: int, segments: list[float],
                                  capsys: pytest.CaptureFixture[str]) -> None:
    take, files = _setup(media, tmp_path, segments)
    repo = FakeRenderRepo(take, target)
    logs: list[str] = []
    started = time.monotonic()
    result = run_render(_ctx(_payload([SRC_A, SRC_B, SRC_A])), repo, files.download, files.upload, log=logs.append)
    elapsed = time.monotonic() - started

    # 결과 파일 재검사(테스트 쪽 ffprobe): 1080x1920 · H.264 + AAC · 길이 · 영상/음성 차
    info = ffprobe(files.out)
    video = [s for s in info["streams"] if s["codec_type"] == "video"]
    audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
    assert (video[0]["width"], video[0]["height"]) == (1080, 1920)
    assert video[0]["codec_name"] == "h264" and audio and audio[0]["codec_name"] == "aac"
    duration = float(info["format"]["duration"])
    assert abs(duration - target) <= 0.1
    assert abs(float(video[0]["duration"]) - float(audio[0]["duration"])) <= 0.05

    assert files.uploads == [(OBJECT, "video/mp4")]
    assert sorted(set(files.downloads)) == sorted({f"voices/{USER}/{PROJECT}/tts-1.wav",
                                                   f"sources/{USER}/{PROJECT}/a.mp4", f"sources/{USER}/{PROJECT}/b.mp4"})
    saved = repo.saved[0]
    assert saved["path"] == OBJECT and abs(saved["duration"] - target) <= 0.1
    cut_map = saved["cut_map"]
    cuts = cut_map["cuts"]
    assert [c["no"] for c in cuts] == [1, 2, 3] and cuts[-1]["out_end"] == target
    assert [c["source_id"] for c in cuts] == [SRC_A, SRC_B, SRC_A]
    # 같은 원본 A는 앞 컷 구간 뒤부터 이어 쓴다(남은 길이가 모자라면 처음부터)
    a_len = cuts[0]["out_end"] - cuts[0]["out_start"]
    assert cuts[2]["src_start"] in (round(a_len, 3), 0.0)
    # 출처 표기: 설명란 문구 + 화면 우하단 문구 파일
    assert cut_map["credits"] == "영상 출처: @maker_a(TikTok), @maker_b(小红书)"
    assert cut_map["encoder"] == "libopenh264"
    # 원본 스냅샷(URL·작성자·플랫폼·수집 시각) — DB 쪽 save_render 가 같은 값으로 덮어쓴다
    assert cuts[0]["source_url"] == "https://www.tiktok.com/@maker_a/video/1"
    assert cuts[0]["collected_at"] == "2026-11-12T00:00:00+00:00" and cuts[1]["platform"] == "xiaohongshu"
    print(f"\n[metric] target={target}s duration={duration:.3f}s bitrate={cut_map['bit_rate']}bps "
          f"encode_sec={cut_map['encode_sec']} total_sec={elapsed:.2f} tempo={cut_map['tempo']}")
    assert result["output"].width == 1080
    assert logs and "token" not in logs[0] and "http" not in logs[0]  # URL 로그 금지


def test_credit_overlay_in_filter(tmp_path: Path) -> None:
    cuts = [Cut(1, "첫 줄 %{localtime}", SRC_A, 0, 0, 7.5), Cut(2, "둘째", SRC_B, 0, 7.5, 15)]
    inputs = [ffmpeg.CutInput(c, "mp4", tmp_path / f"{i}.mp4") for i, c in enumerate(cuts)]
    args, files = ffmpeg.build_args(inputs, tmp_path / "v.wav", 1.0, 15, ["@maker_a", ""], "out.mp4")
    graph = args[args.index("-filter_complex") + 1]
    assert files["credit_1.txt"] == "@maker_a" and "credit_2.txt" not in files
    assert "textfile=credit_1.txt" in graph and "x=w-text_w-40:y=h*0.9" in graph
    assert graph.count("expansion=none") == 3  # 사용자 문구의 %{...} 확장 차단
    assert "%{localtime}" not in graph  # 문구는 파일로만
    assert args.count("-protocol_whitelist") == 3 and "libopenh264" in args
    assert "crop=1080:1920" in graph and "tpad=stop_mode=clone" in graph


# ── 미확인·격리 원본은 매칭 후보에 없음 ─────────────────────────────

def test_unconfirmed_source_rejected_with_cut_number(media: dict[str, Path], tmp_path: Path) -> None:
    """context.sources = 편집 입력(권리 근거·격리 아님·고지 확인). 그 밖의 원본 id 가 payload 컷에 있으면 그 컷 번호로 실패."""
    take, files = _setup(media, tmp_path, [3.0, 4.0, 3.5])
    repo = FakeRenderRepo(take)
    with pytest.raises(PermanentError, match=r"컷 2번 원본을 쓸 수 없습니다\(권리 미확인"):
        run_render(_ctx(_payload([SRC_A, SRC_C, SRC_A])), repo, files.download, files.upload, log=lambda _: None)
    assert files.downloads == [] and repo.saved == []


def test_broken_source_reports_cut_numbers(media: dict[str, Path], tmp_path: Path) -> None:
    take, files = _setup(media, tmp_path, [3.0, 4.0, 3.5])
    sources = FakeRenderRepo(take).sources + [
        {"id": SRC_C, "platform": "tiktok", "author": "c", "file_path": f"{USER}/{PROJECT}/c.mp4",
         "duration_sec": 5, "score": 70, "rights_basis": "own"}]
    repo = FakeRenderRepo(take, sources=sources)
    with pytest.raises(PermanentError, match=r"컷 1번·3번 원본을 쓸 수 없습니다"):
        run_render(_ctx(_payload([SRC_C, SRC_A, SRC_C])), repo, files.download, files.upload, log=lambda _: None)
    assert repo.saved == [] and files.uploads == []


def test_voice_mismatch_and_changed_take(media: dict[str, Path], tmp_path: Path) -> None:
    take, files = _setup(media, tmp_path, [3.0, 4.0, 3.5])
    with pytest.raises(PermanentError, match="음성 파일 검사에 실패"):
        run_render(_ctx(_payload([SRC_A, SRC_B, SRC_A])), FakeRenderRepo({**take, "duration_sec": 9.0}),
                   files.download, files.upload, log=lambda _: None)
    with pytest.raises(PermanentError, match="음성이 없거나 바뀌었습니다"):
        run_render(_ctx(_payload([SRC_A, SRC_B, SRC_A], take_id="other")), FakeRenderRepo(take),
                   files.download, files.upload, log=lambda _: None)


def test_process_message_settles(media: dict[str, Path], tmp_path: Path) -> None:
    take, files = _setup(media, tmp_path, [3.0, 4.0, 3.5])
    payload = _payload([SRC_A, SRC_B, SRC_A])

    class RenderJobRepo(FakeRepo):
        def start(self, queue: str, msg: Message) -> dict[str, Any]:
            r = super().start(queue, msg)
            if r.get("action") == "run":
                r["payload"] = payload
            return r

    repo, render_repo = RenderJobRepo("render"), FakeRenderRepo(take)
    handlers = {"render": lambda ctx: run_render(ctx, render_repo, files.download, files.upload, log=lambda _: None)}
    msg = repo.read("render", 60)
    assert msg is not None
    assert process_message(repo, repo, "render", msg, handlers, log=lambda _: None) == "succeeded"
    assert repo.ledger == ["reserve", "settle"] and len(render_repo.saved) == 1


# ── 서명 URL 검사 ─────────────────────────────────────────────────

def test_signed_urls_checked() -> None:
    path = f"{USER}/{PROJECT}/a.mp4"
    url = download_url(f"https://evil.example/storage/v1/object/sign/sources/{path}?token=t", "sources", path)
    assert url.startswith("http://api-gw:8000/storage/v1/object/sign/sources/")  # 접속지 교체
    for raw, bucket in [(f"{BASE}/storage/v1/object/sign/sources/{USER}/{PROJECT}/other.mp4?token=t", "sources"),
                        (f"{BASE}/storage/v1/object/sign/voices/{path}?token=t", "sources"),
                        (f"{BASE}/storage/v1/object/sign/sources/{path}", "sources"),
                        (None, "sources")]:
        with pytest.raises(FetchError):
            download_url(raw, bucket, path)
    target = upload_target(_payload([]), USER, PROJECT)
    assert target.object_path == OBJECT and target.url.startswith("http://api-gw:8000/") and "token=u" in target.url
    assert "token" not in repr(target)
    other = f"{BASE}/storage/v1/object/upload/sign/renders/{USER}/00000000-0000-4000-a000-000000000009/r.mp4?token=u"
    for bad in [{"upload_url": other}, {"upload_expires_at": (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()},
                {"upload_url": OBJECT.replace(".mp4", ".wav")}]:
        with pytest.raises(FetchError):
            upload_target(_payload([], **bad), USER, PROJECT)


# ── 컷 계획(웹 lib/edit/plan.ts 와 같은 규칙) ──────────────────────

def test_plan_rules() -> None:
    sentences = [{"i": 0, "start": 0.1, "end": 3.1}, {"i": 1, "start": 3.5, "end": 7.5}, {"i": 2, "start": 7.9, "end": 11.4}]
    b, tempo, method = boundaries(LINES, sentences, 11.5, 15)
    assert method == "sentences" and tempo == 1.0
    assert b == [0.0, round(3.3 * 30) / 30, round(7.7 * 30) / 30, 15.0]
    # 음성이 목표보다 길면 atempo(최대 1.15)로 줄이고 경계도 같은 비율
    b, tempo, _ = boundaries(LINES, sentences, 16.5, 15)
    assert tempo == pytest.approx(1.1) and b[1] == round(3.3 / 1.1 * 30) / 30
    with pytest.raises(PlanError):
        boundaries(LINES, sentences, 18.0, 15)
    # 문장 타이밍이 없으면(직접 녹음) 글자 수 비율
    b, _, method = boundaries(LINES, [], 10, 15)
    assert method == "char_ratio" and b[0] == 0 and b[-1] == 15 and b[1] < b[2]
    # 기본 매칭: 점수 순으로 돌려 쓴다
    assert default_assignment(5, ["x", "y"]) == ["x", "y", "x", "y", "x"]
    with pytest.raises(PlanError):
        default_assignment(3, [])
    # 같은 원본 이어 쓰기, 길이가 모자라면 처음부터
    cuts = build_cuts(["a", "b", "c"], [0, 5, 10, 15], ["x", "x", "x"], {"x": 12.0})
    assert [c.src_start for c in cuts] == [0, 5, 0]
    assert credits_text(cuts, {"x": {"author": "@kim", "platform": "direct"}}) == "영상 출처: @kim(직접 추가)"


# ── 느린 서버: 작업 마감(절대 시각)을 넘기면 일시 오류가 아니라 실패 ──────────

@pytest.fixture()
def slow_server():
    import http.server
    import threading

    class Slow(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # 0.2초마다 1바이트(소켓 시간 초과는 피하는 조금씩 보내기)
            self.send_response(200)
            self.send_header("Content-Length", "30")
            self.end_headers()
            try:
                for _ in range(30):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    time.sleep(0.2)
            except OSError:
                pass

        def log_message(self, *args: Any) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Slow)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}/x"
    server.shutdown()


def test_slow_download_fails_at_deadline(slow_server: str, tmp_path: Path) -> None:
    started = time.monotonic()
    with pytest.raises(FetchError) as info:
        download(slow_server, tmp_path / "f", 10_000, timeout=5, deadline=time.monotonic() + 1.0)
    assert str(info.value) == MSG_TIMEOUT and info.value.transient is False
    assert time.monotonic() - started < 2.5


def test_slow_download_stops_on_cancel(slow_server: str, tmp_path: Path) -> None:
    ctx = _ctx({})
    threading_timer = __import__("threading").Timer(0.6, lambda: ctx.stop("canceled"))
    threading_timer.start()
    with pytest.raises(Stopped):
        download(slow_server, tmp_path / "f", 10_000, timeout=5, deadline=time.monotonic() + 30, check=ctx.check)


def test_render_download_timeout_is_permanent(media: dict[str, Path], tmp_path: Path) -> None:
    take, files = _setup(media, tmp_path, [3.0, 4.0, 3.5])

    def too_slow(url: str, dest: Path, max_bytes: int, timeout: float, **kw: Any) -> int:
        raise FetchError(MSG_TIMEOUT, transient=False)

    with pytest.raises(PermanentError, match="작업 제한"):
        run_render(_ctx(_payload([SRC_A, SRC_B, SRC_A])), FakeRenderRepo(take), too_slow, files.upload, log=lambda _: None)
