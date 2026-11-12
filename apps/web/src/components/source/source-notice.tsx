import { InlineBanner } from "@/components/feedback";

/*
 * D7 출처 표기 고지 — docs/planning.md 3장 02 문구, docs/ui-feedback.md 2장 #14(사라지지 않는 인라인 고지 + 확인 체크).
 * 체크는 사용자 클릭만 받는다(AI 대신 누를 수 없음). 오버레이·토스트로 처리하지 않는다.
 */

const TIPS = [
  "먼저 해당 영상을 비공개로 바꿉니다. 분쟁이 커지는 것을 막는 가장 빠른 방법입니다.",
  "보낸 사람이 실제 원작자인지 확인합니다. 메일 속 링크·첨부 파일은 열지 말고, 원작자 공식 계정(DM)으로 사실을 확인하세요(사칭·피싱 주의).",
  "요구 사항을 확인합니다: 삭제 / 출처 수정 / 사용료. 프로젝트의 출처 기록(URL·작성자·수집 시각)으로 어떤 원본을 썼는지 찾습니다.",
  "48시간 안에 정중히 회신합니다: 사과 → 조치 내용(삭제 완료 또는 허락 요청) → 재발 방지. 회신은 캡처해 보관합니다.",
  "삭제를 요구하면 지체 없이 삭제하고, 같은 원작자의 원본을 다른 프로젝트에서도 뺍니다.",
  "YouTube 저작권 경고가 이미 왔다면 반박하지 말고 원작자에게 신고 철회를 요청하세요. 권리가 없는데 이의 제기를 하면 더 불리해집니다.",
  "사용료·손해배상 요구나 내용증명이 오면 회신 전에 전문가(변호사·한국저작권위원회 상담)와 상의합니다.",
];

type SourceNoticeProps = {
  checked: boolean;
  disabled: boolean;
  onChange: (checked: boolean) => void;
};

export function SourceNotice({ checked, disabled, onChange }: SourceNoticeProps) {
  return (
    <InlineBanner tone="warning">
      <p>
        <strong>고지</strong> · 틱톡·샤오홍슈 원본은 원작자 허락 없이 출처만 표기해 사용합니다. 출처 표기는 사용 허락이 아니므로,
        원작자가 문제를 제기하거나 플랫폼에 신고하면 영상이 삭제되고 채널이 저작권 경고를 받을 수 있습니다(경고 3회 누적 시 채널 해지
        가능). 판매자 제공·자체 촬영 원본을 함께 쓰면 위험이 줄어듭니다.
      </p>
      <label className="mt-3 flex min-h-11 cursor-pointer items-start gap-2 font-semibold">
        <input
          type="checkbox"
          checked={checked}
          disabled={disabled}
          onChange={(event) => onChange(event.target.checked)}
          className="mt-1 size-4 shrink-0 accent-current"
        />
        <span>위 고지를 확인했고, 출처를 표기해 사용하며 원작자 요청이 오면 바로 내리겠습니다 (확인해야 승인할 수 있습니다)</span>
      </label>
      <details className="mt-2">
        <summary className="cursor-pointer font-semibold">팁 · 원작자에게 경고 메일을 받았다면</summary>
        <ol className="mt-2 list-decimal space-y-1 pl-5">
          {TIPS.map((tip) => (
            <li key={tip}>{tip}</li>
          ))}
        </ol>
      </details>
    </InlineBanner>
  );
}
