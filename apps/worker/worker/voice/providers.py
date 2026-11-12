"""TTS 공급자 어댑터. 근거: poc/agency/adapters.py GeminiTTS.

- 키는 워커 환경 변수(GEMINI_API_KEY)에서만 읽고 출력·로그·오류 문구에 넣지 않는다.
- 공급자 오류는 ProviderError(사용자 문구, 일시 여부)로 바꾼다. 원문 응답은 저장하지 않는다(키·내부 정보 노출 방지).
"""

from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Protocol

GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"
DEFAULT_GEMINI_TTS_MODEL = "gemini-3.8-flash-lite-tts"  # poc/agency/config.json gemini.tts_model


class ProviderError(Exception):
    """사용자에게 보여도 되는 문구만 담는다. transient=True 면 재시도(백오프), False 면 바로 실패."""

    def __init__(self, message: str, *, transient: bool) -> None:
        super().__init__(message)
        self.transient = transient


MSG_NO_KEY = "음성 공급자 설정이 없어 음성을 만들 수 없습니다. 관리자에게 문의해 주세요."
MSG_AUTH = "음성 공급자 인증에 실패했습니다. 관리자에게 문의해 주세요."
MSG_BAD_INPUT = "대본을 음성으로 바꾸지 못했습니다. 문장을 고치거나 다른 목소리로 다시 시도해 주세요."
MSG_BLOCKED = "음성 공급자가 이 대본을 처리하지 않았습니다. 문장을 고치거나 다른 목소리로 다시 시도해 주세요."
MSG_BUSY = "음성 공급자 사용량이 많아 잠시 뒤 다시 시도합니다."
MSG_DOWN = "음성 공급자에 일시적인 문제가 있어 잠시 뒤 다시 시도합니다."
MSG_SLOW = "음성 공급자 응답이 늦어 잠시 뒤 다시 시도합니다."
MSG_NOT_READY = "이 목소리 공급자는 아직 연결되지 않았습니다. 다른 목소리를 고르거나 직접 녹음해 주세요."


def error_for_status(code: int) -> ProviderError:
    """HTTP 상태 → 사용자 문구. 429·5xx 는 일시 오류(재시도), 나머지는 입력·권한 오류."""
    if code in (401, 403):
        return ProviderError(MSG_AUTH, transient=False)
    if code == 429:
        return ProviderError(MSG_BUSY, transient=True)
    if code >= 500:
        return ProviderError(MSG_DOWN, transient=True)
    return ProviderError(MSG_BAD_INPUT, transient=False)


@dataclass
class Speech:
    pcm: bytes  # 16bit 모노 PCM
    rate: int
    usage: dict[str, int] = field(default_factory=dict)
    model: str = ""


class TTSProvider(Protocol):
    name: str

    def synthesize(self, text: str, voice_id: str, timeout: float) -> Speech: ...


Post = Callable[[str, dict[str, Any], dict[str, str], float], dict[str, Any]]


def _http_post(url: str, body: dict[str, Any], headers: dict[str, str], timeout: float) -> dict[str, Any]:
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise error_for_status(e.code) from None
    except (TimeoutError, urllib.error.URLError):
        raise ProviderError(MSG_SLOW, transient=True) from None
    except ValueError:  # JSON 아님
        raise ProviderError(MSG_DOWN, transient=True) from None


class GeminiTTS:
    """테스트 공급자: generateContent(AUDIO) → PCM. 대본만 보낸다(말투 지시문을 붙이면 낭독해 버리는 문제, poc run.py)."""

    name = "gemini"

    def __init__(self, api_key: str | None = None, model: str | None = None, post: Post = _http_post) -> None:
        self.api_key = api_key if api_key is not None else os.environ.get("GEMINI_API_KEY", "")
        self.model = model or os.environ.get("GEMINI_TTS_MODEL") or DEFAULT_GEMINI_TTS_MODEL
        self._post = post

    def synthesize(self, text: str, voice_id: str, timeout: float) -> Speech:
        if not self.api_key:
            raise ProviderError(MSG_NO_KEY, transient=False)
        body = {"contents": [{"parts": [{"text": text}]}],
                "generationConfig": {"responseModalities": ["AUDIO"],
                                     "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice_id}}}}}
        headers = {"x-goog-api-key": self.api_key, "Content-Type": "application/json"}
        d = self._post(f"{GEMINI_BASE}/models/{self.model}:generateContent", body, headers, timeout)
        try:
            inline = next(p["inlineData"] for p in d["candidates"][0]["content"]["parts"] if "inlineData" in p)
            pcm = base64.b64decode(inline["data"])
        except (KeyError, IndexError, StopIteration, TypeError, ValueError):
            raise ProviderError(MSG_BLOCKED, transient=False) from None
        if len(pcm) < 2:
            raise ProviderError(MSG_BLOCKED, transient=False)
        rate = 24000
        for part in str(inline.get("mimeType", "")).split(";"):
            part = part.strip()
            if part.startswith("rate=") and part[5:].isdigit():
                rate = int(part[5:])
        um = d.get("usageMetadata", {}) or {}
        usage = {"input_tokens": int(um.get("promptTokenCount", 0)),
                 "output_tokens": int(um.get("candidatesTokenCount", 0)),
                 "total_tokens": int(um.get("totalTokenCount", 0))}
        return Speech(pcm=pcm[: len(pcm) // 2 * 2], rate=rate, usage=usage, model=self.model)


class FishAudioTTS:
    """정식 공급자 자리(planning 7장). 키(FISH_AUDIO_API_KEY)·목소리 reference_id 가 정해지면 구현한다."""

    name = "fish_audio"

    def synthesize(self, text: str, voice_id: str, timeout: float) -> Speech:
        raise ProviderError(MSG_NOT_READY, transient=False)


def get_provider() -> TTSProvider:
    """WORKER_TTS_PROVIDER(기본 gemini)로 고른다."""
    name = os.environ.get("WORKER_TTS_PROVIDER", "gemini")
    return FishAudioTTS() if name == "fish_audio" else GeminiTTS()
