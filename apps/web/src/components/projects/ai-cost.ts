/*
 * 제작 전 AI 예상 비용(영상 1편, 모델 조합별) — docs/planning.md 17-2 D9, 3장 첫머리 규칙.
 * 금액은 design/prototype/Main.dc.html .costbox 값(2026-11-12 공식 단가 기준)을 상수로 둔다.
 * 실제 계산(사용량 × 모델 API 키 설정의 단가)은 이후 작업에서 바꾼다. 금액은 정수(원).
 */

export type AiCostRow = {
  combo: string;
  scriptModel: string;
  analysisModel: string;
  won: number;
  emphasis: boolean;
};

export const AI_COST_ROWS: readonly AiCostRow[] = [
  { combo: "최저", scriptModel: "Gemini Flash", analysisModel: "Gemini Flash (영상 직접 입력)", won: 27, emphasis: true },
  { combo: "추천", scriptModel: "Claude Sonnet", analysisModel: "Gemini Flash (영상 직접 입력)", won: 102, emphasis: true },
  { combo: "Claude만", scriptModel: "Claude Sonnet", analysisModel: "Claude Sonnet (프레임 이미지)", won: 653, emphasis: false },
];

export const AI_COST_NOTE =
  "공통 별도: 음성(Fish Audio, 약 300자) 단가 입력 전 · 렌더링(서버 FFmpeg) 0원 · 스케일업·제거는 실행할 때만. 2026-11-12 공식 단가 기준이며 W0 원가 실측 후 바뀝니다. 실제 계산은 모델 API 키 설정에서 고른 모델로 합니다.";

export function formatWon(won: number) {
  return `약 ${won.toLocaleString("ko-KR")}원`;
}

/** 트렌드 선택 바 한 줄 요약: "편당 최저 약 27원 · … (음성 별도) × N편" */
export function costSummary(count: number) {
  const parts = AI_COST_ROWS.map((row) => `${row.combo} ${formatWon(row.won)}`).join(" · ");
  return `AI 예상 비용 · 편당 ${parts} (음성 별도) × ${count}편`;
}
