import { VOICES, VOICE_PROVIDER_LABEL } from "@/lib/voice/voices";
import { cn } from "@/lib/utils";

/*
 * S-09 목소리 6종 카드(라디오). 지금은 테스트 공급자 Gemini TTS 목소리라 샘플 듣기·Fish Audio에서 듣기·
 * 전체 목소리 100개 보기는 비활성 안내만 둔다(Fish Audio 연결 후 연다).
 */

type VoicePickerProps = {
  value: string | null;
  onChange: (voiceId: string) => void;
  disabled?: boolean;
};

export function VoicePicker({ value, onChange, disabled = false }: VoicePickerProps) {
  return (
    <fieldset className="flex flex-col gap-3" disabled={disabled}>
      <legend className="mb-1 text-sm font-semibold">
        목소리 선택<span className="text-danger-fg">*</span>
      </legend>
      <div role="radiogroup" aria-label="목소리 6종" className="grid grid-cols-2 gap-2 tablet:grid-cols-3">
        {VOICES.map((voice) => (
          <label
            key={voice.id}
            className={cn(
              "flex min-h-11 cursor-pointer flex-col gap-0.5 rounded-btn border border-line bg-white px-3 py-2 transition-colors hover:border-accent-line hover:bg-sub-hover",
              "has-checked:border-accent has-checked:bg-accent-weak has-focus-visible:outline-2 has-focus-visible:outline-accent",
              disabled && "cursor-not-allowed opacity-60",
            )}
          >
            <input
              type="radio"
              name="voice"
              value={voice.id}
              checked={value === voice.id}
              onChange={() => onChange(voice.id)}
              className="sr-only"
            />
            <span className="text-sm font-semibold">
              {voice.name} <span className="text-xs font-normal text-muted">· {voice.gender}</span>
            </span>
            <span className="text-xs text-muted">{voice.tone}</span>
          </label>
        ))}
      </div>
      <p className="text-xs text-muted">
        {VOICE_PROVIDER_LABEL} 목소리입니다. 샘플 듣기·Fish Audio에서 듣기·전체 목소리 100개 보기는 Fish Audio 연결 후 열립니다.
      </p>
    </fieldset>
  );
}
