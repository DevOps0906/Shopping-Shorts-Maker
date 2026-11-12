"""한국어 목소리 6종(웹 src/lib/voice/voices.ts 와 같은 ID). 지금은 테스트 공급자 Gemini TTS의 기본 목소리다.

Fish Audio 키·목소리 ID가 정해지면 provider 를 바꾸고 ID 를 Fish Audio reference_id 로 바꾼다(어댑터: providers.FishAudioTTS).
"""

from __future__ import annotations

VOICE_IDS: frozenset[str] = frozenset({"Leda", "Zephyr", "Kore", "Sadachbia", "Puck", "Charon"})
