"""TTS·LLM 어댑터 인터페이스. 기본은 dry-run(실제 API 호출 없음, 과금 0원).

키는 환경 변수 이름만 참조한다(.env.example). 값은 읽어도 출력·로그에 남기지 않는다.
"""
from __future__ import annotations

import base64
import json
import math
import os
import time
import wave
import urllib.error
import urllib.request
from pathlib import Path
from dataclasses import dataclass, field


@dataclass
class Usage:
    provider: str
    item: str
    units: dict[str, int] = field(default_factory=dict)  # 예: {"input_tokens": 120}
    dry_run: bool = True
    note: str = ""


class TTSAdapter:
    provider = "base"

    def synthesize(self, text: str, voice_id: str, out_path: str) -> tuple[str | None, Usage]:
        """음성 파일 경로(없으면 None)와 사용량을 돌려준다."""
        raise NotImplementedError


class LLMAdapter:
    provider = "base"

    def complete(self, prompt: str) -> tuple[str, Usage]:
        raise NotImplementedError


class FishAudioTTS(TTSAdapter):
    provider = "fish_audio"
    key_env = "FISH_AUDIO_API_KEY"

    def __init__(self, dry_run: bool = True):
        self.dry_run = dry_run

    def synthesize(self, text, voice_id, out_path):
        units = {"chars": len(text), "utf8_bytes": len(text.encode("utf-8"))}
        if self.dry_run:
            return None, Usage(self.provider, "tts", units, True)
        if not os.environ.get(self.key_env):
            raise RuntimeError(f"{self.key_env} 환경 변수가 없습니다")
        raise NotImplementedError("Fish Audio 실제 호출은 아직 구현하지 않음(task-003 후속)")


class ClaudeLLM(LLMAdapter):
    provider = "claude"
    key_env = "ANTHROPIC_API_KEY"

    def __init__(self, dry_run: bool = True):
        self.dry_run = dry_run

    @staticmethod
    def estimate_tokens(text: str) -> int:
        # 추정치: UTF-8 3바이트당 1토큰. 실제 호출 시 응답의 usage 값으로 대체한다.
        return math.ceil(len(text.encode("utf-8")) / 3)

    @staticmethod
    def estimate_image_tokens(w: int, h: int) -> int:
        # 추정치: 긴 변 1568px 초과 시 비율 유지 축소 후 ceil(w*h/750)
        if max(w, h) > 1568:
            s = 1568 / max(w, h)
            w, h = round(w * s), round(h * s)
        return math.ceil(w * h / 750)

    def describe_frames(self, sizes: list[tuple[int, int]]) -> Usage:
        """대본 초안 전 원본 컷 프레임을 비전 입력으로 보내는 비용(dry-run 추정만)."""
        if not self.dry_run:
            raise NotImplementedError("Claude 비전 실제 호출은 아직 구현하지 않음(task-003 후속)")
        tokens = sum(self.estimate_image_tokens(w, h) for w, h in sizes)
        return Usage(self.provider, "vision", {"images": len(sizes), "input_tokens": tokens}, True)

    def complete(self, prompt):
        if self.dry_run:
            out = prompt  # dry-run은 입력을 그대로 돌려준다(출력 길이 ≈ 입력 길이로 추정)
            units = {"input_tokens": self.estimate_tokens(prompt), "output_tokens": self.estimate_tokens(out)}
            return out, Usage(self.provider, "llm", units, True)
        if not os.environ.get(self.key_env):
            raise RuntimeError(f"{self.key_env} 환경 변수가 없습니다")
        raise NotImplementedError("Claude 실제 호출은 아직 구현하지 않음(task-003 후속)")


GEMINI_KEY_NAMES = ("GEMINI_API_KEY", "GOOGLE_API_KEY")
ENV_FILE = Path(__file__).resolve().parents[2] / ".env.local"
GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"
MAX_INLINE_BYTES = 20 * 1024 * 1024


def load_gemini_key() -> str:
    """환경 변수 또는 저장소 루트 .env.local에서 Gemini 키 한 개만 읽는다(값은 출력하지 않음)."""
    for name in GEMINI_KEY_NAMES:
        if os.environ.get(name):
            return os.environ[name]
    found: dict[str, str] = {}
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            k, sep, v = line.strip().partition("=")
            k = k.removeprefix("export ").strip()
            if sep and k in GEMINI_KEY_NAMES:
                found[k] = v.strip().strip("\"'")
    for name in GEMINI_KEY_NAMES:
        if found.get(name):
            return found[name]
    raise RuntimeError(f"Gemini 키 없음: 저장소 루트 .env.local에 {GEMINI_KEY_NAMES[0]}(또는 {GEMINI_KEY_NAMES[1]})를 두세요")


def gemini_request(path: str, body: dict | None, timeout: int = 120) -> dict:
    """Gemini REST 호출. 타임아웃·429·5xx는 1회 재시도, 실패 사유는 키 없이 RuntimeError로."""
    req = urllib.request.Request(
        f"{GEMINI_BASE}/{path}", data=None if body is None else json.dumps(body).encode("utf-8"),
        headers={"x-goog-api-key": load_gemini_key(), "Content-Type": "application/json"})
    last, is_get = "", body is None
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            last = f"HTTP {e.code} {detail}"
            # POST는 429(미처리 확실)만 재시도. 5xx는 처리 여부 불명 → 중복 과금 방지로 재시도 안 함.
            if not (e.code == 429 or (is_get and e.code in (500, 503))):
                break
        except (TimeoutError, urllib.error.URLError) as e:
            last = f"네트워크/타임아웃: {type(e).__name__}"
            if not is_get:
                last += "(결과 불명, 중복 과금 방지로 자동 재시도 안 함)"
                break
        if attempt == 1:
            print(f"  Gemini 호출 실패({last}) → 5초 후 1회 재시도")
            time.sleep(5)
    raise RuntimeError(f"Gemini 호출 실패: {last}")


def gemini_list_models() -> list[str]:
    """generateContent를 지원하는 모델 ID 목록."""
    out, token = [], ""
    while True:
        d = gemini_request("models?pageSize=100" + (f"&pageToken={token}" if token else ""), None, 30)
        out += [m["name"].removeprefix("models/") for m in d.get("models", [])
                if "generateContent" in m.get("supportedGenerationMethods", [])]
        token = d.get("nextPageToken", "")
        if not token:
            return out


class GeminiVideo:
    """Gemini 영상 분석 어댑터. dry-run은 토큰 추정(ceil(초)×(프레임당+오디오)), live는 실제 호출."""
    provider = "gemini"
    key_env = "GEMINI_API_KEY"
    AUDIO_TOKENS_PER_SEC = 32

    def __init__(self, dry_run: bool = True, tokens_per_frame: int = 70, model: str = ""):
        self.dry_run = dry_run
        self.tokens_per_frame = tokens_per_frame
        self.model = model

    def analyze(self, seconds: float, sources: int = 1) -> Usage:
        if not self.dry_run:
            raise NotImplementedError("live는 analyze_script()를 쓴다")
        secs = math.ceil(seconds) * sources
        tokens = secs * (self.tokens_per_frame + self.AUDIO_TOKENS_PER_SEC)
        return Usage(self.provider, "video", {"sources": sources, "seconds": secs, "input_tokens": tokens}, True)

    def analyze_script(self, video_path: str, prompt: str) -> tuple[str, Usage]:
        """영상(inline base64, 20MB 미만)과 프롬프트를 보내 분석+대본 초안을 받고 실제 usageMetadata를 돌려준다."""
        if self.dry_run:
            raise RuntimeError("dry-run에서는 Gemini를 호출하지 않습니다")
        if not self.model:
            raise RuntimeError("config.json gemini.model 이 비어 있습니다")
        data = Path(video_path).read_bytes()
        body = {"contents": [{"parts": [
            {"inline_data": {"mime_type": "video/mp4", "data": base64.b64encode(data).decode("ascii")}},
            {"text": prompt}]}]}
        size = len(json.dumps(body).encode("utf-8"))
        if size >= MAX_INLINE_BYTES:
            raise RuntimeError(f"요청 본문 {size}바이트 ≥ 20MB: inline 전송 불가")
        d = gemini_request(f"models/{self.model}:generateContent", body)
        try:
            text = "".join(p.get("text", "") for p in d["candidates"][0]["content"]["parts"])
        except (KeyError, IndexError):
            raise RuntimeError(f"Gemini 응답에 후보 없음: {str(d.get('promptFeedback', ''))[:200]}")
        um = d.get("usageMetadata", {})
        units = {"input_tokens": int(um.get("promptTokenCount", 0)),
                 "output_tokens": int(um.get("candidatesTokenCount", 0)),
                 "thinking_tokens": int(um.get("thoughtsTokenCount", 0)),
                 "total_tokens": int(um.get("totalTokenCount", 0))}
        return text, Usage(self.provider, "video_script", units, False, self.model)


class GeminiTTS(TTSAdapter):
    """테스트용 Gemini TTS. dry-run은 호출 없음, live는 generateContent(AUDIO)로 PCM을 받아 wav로 저장한다."""
    provider = "gemini_tts"
    AUDIO_TOKENS_PER_SEC = 25  # 공식 문서 기준 오디오 출력 토큰 환산(추정용)

    def __init__(self, dry_run: bool = True, model: str = "", voice: str = "", style: str = "", style_mode: str = "system"):
        self.dry_run = dry_run
        self.model = model
        self.voice = voice
        self.style_mode = style_mode  # system: systemInstruction으로 분리 / prefix: 본문 앞에 붙임
        self.style = style  # 말투 지시(예: "밝고 활기찬 ... 말해 주세요:"). 비면 대본만 보낸다

    def synthesize(self, text, voice_id, out_path):
        if self.dry_run:
            return None, Usage(self.provider, "tts", {"chars": len(text), "utf8_bytes": len(text.encode("utf-8"))}, True)
        if not self.model or not self.voice:
            raise RuntimeError("config.json gemini.tts_model / gemini.tts_voice 가 비어 있습니다")
        body = {"contents": [{"parts": [{"text": f"{self.style}\n{text}" if self.style else text}]}],
                "generationConfig": {"responseModalities": ["AUDIO"],
                                     "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": self.voice}}}}}
        if self.style and self.style_mode == "system":
            body["systemInstruction"] = {"parts": [{"text": self.style}]}
        d = gemini_request(f"models/{self.model}:generateContent", body)
        try:
            inline = next(p["inlineData"] for p in d["candidates"][0]["content"]["parts"] if "inlineData" in p)
            pcm = base64.b64decode(inline["data"])
        except (KeyError, IndexError, StopIteration):
            raise RuntimeError(f"Gemini TTS 응답에 오디오 없음: {str(d.get('promptFeedback', ''))[:200]}")
        rate = 24000
        for part in inline.get("mimeType", "").split(";"):
            if part.strip().startswith("rate="):
                rate = int(part.strip()[5:])
        with wave.open(out_path, "wb") as w:  # 16bit 모노 PCM → wav
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(pcm)
        um = d.get("usageMetadata", {})
        units = {"input_tokens": int(um.get("promptTokenCount", 0)),
                 "output_tokens": int(um.get("candidatesTokenCount", 0)),
                 "total_tokens": int(um.get("totalTokenCount", 0)),
                 "audio_ms": int(len(pcm) / 2 / rate * 1000)}
        return out_path, Usage(self.provider, "tts", units, False, f"{self.model}/{self.voice}")
