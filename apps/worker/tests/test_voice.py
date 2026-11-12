"""task-019 tts 처리기: 공급자 목(mock) 성공 → settle, 오류 → release + 사용자 문구, 문장·단어 타이밍 수 = 대본,
서명 업로드 URL 검사. 음성 픽스처는 문장마다 톤 + 0.4초 무음으로 만든 합성 PCM(ffmpeg silencedetect 필요)."""

from __future__ import annotations

import math
import struct
import time
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Any

import pytest

from tests.test_jobs import FakeRepo
from worker.jobs import JobContext, Message, PermanentError, TransientError, process_message
from worker.voice import providers, storage
from worker.voice.providers import GeminiTTS, ProviderError, Speech
from worker.voice.timing import build_timing
from worker.sources.media import MediaRejected
from worker.voice.media import probe_wav, verify_take
from worker.voice.tts import MSG_BAD_VOICE, MSG_NO_SCRIPT, MSG_SAVE_FAILED, Timing, cache_path, run_tts, to_wav

USER, PROJECT = "00000000-0000-4000-a000-000000000001", "00000000-0000-4000-a000-000000000002"
OBJECT = f"{USER}/{PROJECT}/tts-1.wav"
LINES = ["좁은 틈에도 쏙 들어가요.", "이거 하나면 정리 끝!", "지금 바로 확인해 보세요."]
RATE = 24000


def _future(minutes: int = 10) -> str:
    return (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()


def _payload(**over: Any) -> dict[str, Any]:
    p = {"voice_id": "Leda",
         "upload_url": f"http://127.0.0.1:8000/storage/v1/object/upload/sign/voices/{OBJECT}?token=t0k",
         "upload_expires_at": _future()}
    p.update(over)
    return p


def speech_pcm(segments: list[float], gap: float = 0.4, lead: float = 0.1) -> bytes:
    """문장 길이(초) 목록 → 톤 구간 사이에 무음을 둔 16bit 모노 PCM."""
    out = bytearray(b"\x00\x00" * int(lead * RATE))
    for i, sec in enumerate(segments):
        n = int(sec * RATE)
        out += b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 220 * k / RATE))) for k in range(n))
        out += b"\x00\x00" * int((gap if i < len(segments) - 1 else lead) * RATE)
    return bytes(out)


class FakeProvider:
    name = "mock"

    def __init__(self, result: Speech | Exception) -> None:
        self.result = result
        self.calls: list[tuple[str, str]] = []

    def synthesize(self, text: str, voice_id: str, timeout: float) -> Speech:
        self.calls.append((text, voice_id))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class FakeTtsRepo:
    def __init__(self, lines: list[str] = LINES) -> None:
        self.lines = lines
        self.saved: list[dict[str, Any]] = []

    def context(self, job_id: str) -> dict[str, Any]:
        return {"project_id": PROJECT, "user_id": USER, "lines": self.lines}

    def save(self, job_id: str, voice_id: str, audio_path: str, duration_sec: float, timing: Timing) -> str:
        self.saved.append({"voice_id": voice_id, "audio_path": audio_path, "duration": duration_sec, "timing": timing})
        return "take-1"


class Uploads:
    def __init__(self) -> None:
        self.calls: list[tuple[str, int, str]] = []

    def __call__(self, target: storage.UploadTarget, data: bytes, content_type: str, timeout: float) -> None:
        self.calls.append((target.object_path, len(data), content_type))


@pytest.fixture(autouse=True)
def storage_base(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("WORKER_STORAGE_URL", "http://api-gw:8000")
    monkeypatch.setenv("WORKER_TTS_CACHE", str(tmp_path / "cache"))


def _ctx(payload: dict[str, Any]) -> JobContext:
    return JobContext(job_id="job-1", type="tts", step=4, attempts=1, payload=payload, deadline=time.monotonic() + 120)


class TtsJobRepo(FakeRepo):
    def __init__(self, payload: dict[str, Any]) -> None:
        super().__init__("tts")
        self.payload = payload

    def start(self, queue: str, msg: Message) -> dict[str, Any]:
        r = super().start(queue, msg)
        if r.get("action") == "run":
            r.update(step=4, payload=self.payload)
        return r


def _process(provider: FakeProvider, payload: dict[str, Any] | None = None, tts_repo: FakeTtsRepo | None = None):
    repo = TtsJobRepo(payload or _payload())
    tts_repo = tts_repo or FakeTtsRepo()
    uploads = Uploads()
    handlers = {"tts": lambda ctx: run_tts(ctx, tts_repo, provider, uploads, log=lambda _: None)}
    msg = repo.read("tts", 60)
    assert msg is not None
    action = process_message(repo, repo, "tts", msg, handlers, log=lambda _: None)
    return action, repo, tts_repo, uploads


# ── 공급자 목: 성공 → settle, 오류 → release + 사용자 문구 ─────────────

def test_success_settles_and_saves_timing() -> None:
    provider = FakeProvider(Speech(speech_pcm([1.2, 1.0, 1.3]), RATE, {"input_tokens": 20, "output_tokens": 90}, "m"))
    action, repo, tts_repo, uploads = _process(provider)
    assert action == "succeeded"
    assert repo.ledger == ["reserve", "settle"]
    assert provider.calls == [("\n".join(LINES), "Leda")]
    assert uploads.calls == [(OBJECT, uploads.calls[0][1], "audio/wav")]
    saved = tts_repo.saved[0]
    timing: Timing = saved["timing"]
    assert saved["audio_path"] == OBJECT
    assert timing.method == "silencedetect"
    assert len(timing.sentences) == len(LINES)
    assert len(timing.words) == sum(len(l.split()) for l in LINES)
    # 문장 경계 ≈ 무음 위치(0.1 + 1.2 = 1.3초, 1.3 + 0.4 + 1.0 = 2.7초)
    assert abs(timing.sentences[0]["end"] - 1.3) < 0.05
    assert abs(timing.sentences[1]["start"] - 1.7) < 0.05
    assert abs(timing.sentences[1]["end"] - 2.7) < 0.05
    assert abs(saved["duration"] - (0.1 + 1.2 + 0.4 + 1.0 + 0.4 + 1.3 + 0.1)) < 0.01


@pytest.mark.parametrize("error, action, ledger", [
    (ProviderError(providers.MSG_BAD_INPUT, transient=False), "failed", ["reserve", "release"]),
    (ProviderError(providers.MSG_AUTH, transient=False), "failed", ["reserve", "release"]),
    (ProviderError(providers.MSG_BUSY, transient=True), "retry", ["reserve"]),
])
def test_provider_error_user_message(error: ProviderError, action: str, ledger: list[str]) -> None:
    result, repo, tts_repo, uploads = _process(FakeProvider(error))
    assert result == action
    assert repo.ledger == ledger
    assert tts_repo.saved == [] and uploads.calls == []
    recorded = [c for c in repo.calls if c[0] in ("fail", "retry")][0]
    assert recorded[1] == str(error)  # 저장되는 오류는 사용자 문구 그대로


def test_missing_key_fails_with_message_and_release(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    result, repo, _, _ = _process(GeminiTTS(post=lambda *a: pytest.fail("키 없이 호출")))  # type: ignore[arg-type]
    assert result == "failed"
    assert repo.ledger == ["reserve", "release"]
    assert ("fail", providers.MSG_NO_KEY) in repo.calls


def test_bad_voice_and_empty_script() -> None:
    provider = FakeProvider(Speech(speech_pcm([1.0]), RATE))
    result, repo, _, _ = _process(provider, _payload(voice_id="EvilVoice"))
    assert result == "failed" and ("fail", MSG_BAD_VOICE) in repo.calls
    result, repo, _, _ = _process(provider, tts_repo=FakeTtsRepo([]))
    assert result == "failed" and ("fail", MSG_NO_SCRIPT) in repo.calls
    assert provider.calls == []


# ── Gemini 응답 → 사용자 문구 ─────────────────────────────────────

@pytest.mark.parametrize("code, transient, message", [
    (400, False, providers.MSG_BAD_INPUT), (403, False, providers.MSG_AUTH),
    (429, True, providers.MSG_BUSY), (503, True, providers.MSG_DOWN),
])
def test_status_mapping(code: int, transient: bool, message: str) -> None:
    err = providers.error_for_status(code)
    assert (err.transient, str(err)) == (transient, message)


def test_gemini_parses_audio_and_blocked() -> None:
    import base64

    pcm = speech_pcm([0.2])
    ok = {"candidates": [{"content": {"parts": [{"inlineData": {"mimeType": "audio/L16;codec=pcm;rate=24000",
                                                               "data": base64.b64encode(pcm).decode()}}]}}],
          "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 30, "totalTokenCount": 42}}
    seen: dict[str, Any] = {}

    def post(url: str, body: dict[str, Any], headers: dict[str, str], timeout: float) -> dict[str, Any]:
        seen.update(url=url, body=body)
        return ok

    speech = GeminiTTS(api_key="k", model="m-tts", post=post).synthesize("문장", "Kore", 10)
    assert speech.rate == 24000 and speech.pcm == pcm and speech.usage["total_tokens"] == 42
    assert seen["body"]["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]["voiceName"] == "Kore"
    assert "k" not in seen["url"]  # 키는 헤더로만
    with pytest.raises(ProviderError) as blocked:
        GeminiTTS(api_key="k", post=lambda *a: {"promptFeedback": {"blockReason": "SAFETY"}}).synthesize("x", "Leda", 10)
    assert str(blocked.value) == providers.MSG_BLOCKED and not blocked.value.transient


def test_fish_audio_slot_is_not_ready() -> None:
    with pytest.raises(ProviderError) as e:
        providers.FishAudioTTS().synthesize("x", "v", 10)
    assert str(e.value) == providers.MSG_NOT_READY


# ── 타이밍 수 = 대본 ──────────────────────────────────────────────

@pytest.mark.parametrize("gaps", [[], [(1.0, 1.2)], [(0.0, 0.1), (1.0, 1.3), (2.0, 2.2), (2.5, 2.6), (3.9, 4.0)]])
def test_timing_counts_match_script(gaps: list[tuple[float, float]]) -> None:
    lines = ["하나 둘 셋", "넷", "다섯 여섯"]
    t = build_timing(lines, gaps, 4.0)
    assert len(t.sentences) == 3
    assert [w["w"] for w in t.words] == "하나 둘 셋 넷 다섯 여섯".split()
    assert all(w["start"] <= w["end"] for w in t.words)
    assert t.words[-1]["end"] <= 4.0 + 1e-6
    # 단어는 자기 문장 구간 안
    for w in t.words:
        s = t.sentences[w["s"]]
        assert s["start"] - 1e-6 <= w["start"] and w["end"] <= s["end"] + 1e-6


# ── 서명 업로드 URL ───────────────────────────────────────────────

def test_upload_target_rewrites_origin_and_hides_token() -> None:
    target = storage.parse_target(_payload(upload_url=f"https://evil.example/storage/v1/object/upload/sign/voices/{OBJECT}?token=abc"))
    assert target.url.startswith("http://api-gw:8000/storage/v1/object/upload/sign/voices/")
    assert target.object_path == OBJECT
    assert "abc" not in repr(target)


@pytest.mark.parametrize("over, message", [
    ({"upload_expires_at": (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()}, storage.MSG_EXPIRED),
    ({"upload_url": f"http://x/storage/v1/object/upload/sign/sources/{OBJECT}?token=a"}, storage.MSG_BAD_TARGET),
    ({"upload_url": f"http://x/storage/v1/object/upload/sign/voices/{USER}/../x.wav?token=a"}, storage.MSG_BAD_TARGET),
    ({"upload_url": f"http://x/storage/v1/object/upload/sign/voices/{OBJECT}"}, storage.MSG_BAD_TARGET),
    ({"upload_url": None}, storage.MSG_BAD_TARGET),
])
def test_upload_target_rejects(over: dict[str, Any], message: str) -> None:
    with pytest.raises(ProviderError) as e:
        storage.parse_target(_payload(**over))
    assert str(e.value) == message and not e.value.transient


def test_other_project_path_rejected() -> None:
    other = f"{USER}/00000000-0000-4000-a000-000000000009/tts-1.wav"
    ctx = _ctx(_payload(upload_url=f"http://x/storage/v1/object/upload/sign/voices/{other}?token=a"))
    provider = FakeProvider(Speech(speech_pcm([1.0]), RATE))
    with pytest.raises(PermanentError):
        run_tts(ctx, FakeTtsRepo(), provider, Uploads(), log=lambda _: None)
    assert provider.calls == []


def test_transient_upload_error_retries_with_cached_audio() -> None:
    """재시도 중복 과금 방지: 업로드 일시 오류 뒤 재시도는 캐시를 써서 공급자를 다시 부르지 않는다."""
    def failing(*_: Any) -> None:
        raise ProviderError(storage.MSG_UPLOAD_DOWN, transient=True)

    provider = FakeProvider(Speech(speech_pcm([1.0, 1.0, 1.0]), RATE))
    with pytest.raises(TransientError):
        run_tts(_ctx(_payload()), FakeTtsRepo(), provider, failing, log=lambda _: None)
    assert cache_path("job-1").is_file()
    uploads, repo = Uploads(), FakeTtsRepo()
    result = run_tts(_ctx(_payload()), repo, provider, uploads, log=lambda _: None)
    assert len(provider.calls) == 1 and result["model"] == "cache"
    assert len(repo.saved) == 1 and len(uploads.calls) == 1
    assert not cache_path("job-1").exists()  # 성공하면 지운다


def test_unexpected_error_after_synthesis_is_permanent() -> None:
    class Broken(FakeTtsRepo):
        def save(self, *a: Any) -> str:
            raise RuntimeError("db gone")

    provider = FakeProvider(Speech(speech_pcm([1.0, 1.0, 1.0]), RATE))
    with pytest.raises(PermanentError) as e:
        run_tts(_ctx(_payload()), Broken(), provider, Uploads(), log=lambda _: None)
    assert str(e.value) == MSG_SAVE_FAILED
    assert not cache_path("job-1").exists()


# ── voices 객체 재검사(ffprobe) ───────────────────────────────────

def test_verify_take(tmp_path: Path) -> None:
    good = tmp_path / "a.wav"
    good.write_bytes(to_wav(speech_pcm([1.0]), RATE))
    d = probe_wav(good, 10)
    assert abs(d - 1.2) < 0.01
    assert verify_take(good, d, [{"start": 0, "end": d}], [], 10) == pytest.approx(d)
    with pytest.raises(MediaRejected):  # 기록 길이와 다름(다른 파일로 바꿔치기)
        verify_take(good, d + 1.0, [], [], 10)
    with pytest.raises(MediaRejected):  # 타이밍이 길이 밖
        verify_take(good, d, [{"start": 0, "end": d + 2}], [], 10)
    fake = tmp_path / "b.wav"
    fake.write_bytes(b"RIFF\x00\x00\x00\x00WAVEjunkjunkjunk")
    with pytest.raises(MediaRejected):
        probe_wav(fake, 10)
    png = tmp_path / "c.wav"
    png.write_bytes(bytes([0x89]) + b"PNG" + bytes([13, 10, 0x1A, 10]) + bytes(64))
    with pytest.raises(MediaRejected):
        probe_wav(png, 10)
