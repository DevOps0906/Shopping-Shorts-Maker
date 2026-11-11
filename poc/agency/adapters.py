"""TTS·LLM 어댑터 인터페이스. 기본은 dry-run(실제 API 호출 없음, 과금 0원).

키는 환경 변수 이름만 참조한다(.env.example). 값은 읽어도 출력·로그에 남기지 않는다.
"""
from __future__ import annotations

import math
import os
from dataclasses import dataclass, field


@dataclass
class Usage:
    provider: str
    item: str
    units: dict[str, int] = field(default_factory=dict)  # 예: {"input_tokens": 120}
    dry_run: bool = True


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

    def complete(self, prompt):
        if self.dry_run:
            out = prompt  # dry-run은 입력을 그대로 돌려준다(출력 길이 ≈ 입력 길이로 추정)
            units = {"input_tokens": self.estimate_tokens(prompt), "output_tokens": self.estimate_tokens(out)}
            return out, Usage(self.provider, "llm", units, True)
        if not os.environ.get(self.key_env):
            raise RuntimeError(f"{self.key_env} 환경 변수가 없습니다")
        raise NotImplementedError("Claude 실제 호출은 아직 구현하지 않음(task-003 후속)")
