import { cn } from "@/lib/utils";
import { PLATFORM_LABEL, RIGHTS_BASES, RIGHTS_LABEL, type RightsBasis, type SourceView } from "@/lib/sources/rules";

/*
 * 원본 카드 — docs/planning.md 3장 02 결과 카드(번호·플랫폼·제목·해상도·길이·출처·체크), 15-4 ①(URL·작성자·수집 시각).
 * 다운로드 체크(D8 10편)와 사용 체크(5편)는 사용자 클릭만. 사용하려면 권리 근거를 고른다(D1·D7).
 */

const PLATFORM_CLASS = {
  tiktok: "bg-pt-tt-bg text-pt-tt-fg",
  xiaohongshu: "bg-pt-xhs-bg text-pt-xhs-fg",
  direct: "bg-accent-weak text-nav-on-ink",
} as const;

const timeFormat = new Intl.DateTimeFormat("ko-KR", {
  timeZone: "Asia/Seoul",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

export function formatTime(iso: string | null) {
  if (!iso) return "-";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "-" : timeFormat.format(date);
}

function formatDuration(sec: number | null) {
  if (sec === null) return "길이 미확인";
  const s = Math.round(sec);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

type SourceCardProps = {
  no: number;
  source: SourceView;
  recommended: boolean;
  basis: RightsBasis | null;
  editable: boolean;
  checkLimitReached: boolean;
  onToggleCheck: () => void;
  onToggleUse: () => void;
  onBasisChange: (basis: RightsBasis | null) => void;
};

export function SourceCard({
  no,
  source,
  recommended,
  basis,
  editable,
  checkLimitReached,
  onToggleCheck,
  onToggleUse,
  onBasisChange,
}: SourceCardProps) {
  const author = `@${source.author.replace(/^@/, "")}`;
  const resolution = source.width && source.height ? `${source.width}×${source.height}` : "해상도 미확인";
  const confirmed = source.used && source.rightsBasis !== null;
  const ids = { check: `src-check-${source.id}`, use: `src-use-${source.id}`, basis: `src-basis-${source.id}` };

  return (
    <article
      className={cn(
        "flex min-w-0 flex-col gap-3 rounded-card border bg-white p-4 shadow-card",
        source.used ? "border-accent" : "border-line",
      )}
    >
      <div className="flex flex-wrap items-center gap-2">
        <span className="rounded-pill bg-count-bg px-2 py-0.5 text-xs font-bold">{no}</span>
        <span className={cn("rounded-pill px-2 py-0.5 text-xs font-bold", PLATFORM_CLASS[source.platform])}>
          {PLATFORM_LABEL[source.platform]}
        </span>
        {recommended ? <span className="rounded-pill bg-hot-bg px-2 py-0.5 text-xs font-bold text-hot-fg">AI 추천</span> : null}
        <span
          className={cn(
            "ml-auto rounded-pill px-2 py-0.5 text-xs font-semibold",
            source.downloaded ? "bg-success-bg text-success-fg" : "bg-sub-hover text-muted",
          )}
        >
          {source.downloaded ? "다운로드됨" : "목록만"}
        </span>
      </div>

      <div className="min-w-0">
        <p className="truncate text-sm font-bold">{source.title ?? "제목 없음"}</p>
        <p className="text-xs text-muted">
          {resolution} · {formatDuration(source.durationSec)}
          {source.score !== null ? ` · 점수 ${Math.round(source.score)}` : ""}
        </p>
        <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 text-xs">
          <dt className="text-muted">출처</dt>
          <dd className="min-w-0 truncate font-semibold">
            {author} ({PLATFORM_LABEL[source.platform]})
          </dd>
          <dt className="text-muted">URL</dt>
          <dd className="min-w-0 truncate">
            <a href={source.url} target="_blank" rel="noopener noreferrer" className="text-accent underline">
              {source.url}
            </a>
          </dd>
          <dt className="text-muted">수집</dt>
          <dd>{formatTime(source.collectedAt)}</dd>
          <dt className="text-muted">권리</dt>
          <dd className={cn("font-semibold", confirmed ? "text-success-fg" : "text-warning-fg")}>
            {confirmed && source.rightsBasis
              ? `${RIGHTS_LABEL[source.rightsBasis]} · 확인 ${formatTime(source.rightsConfirmedAt)}`
              : "권리 미확인 · 참고용"}
          </dd>
        </dl>
      </div>

      <div className="flex flex-col gap-2 border-t border-line pt-3 text-sm">
        <label htmlFor={ids.check} className="flex min-h-11 items-center gap-2">
          <input
            id={ids.check}
            type="checkbox"
            checked={source.checked}
            disabled={!editable || (!source.checked && checkLimitReached)}
            onChange={onToggleCheck}
            className="size-4"
          />
          <span>다운로드 체크</span>
        </label>
        {source.downloaded ? (
          <>
            <label htmlFor={ids.basis} className="flex flex-col gap-1">
              <span className="text-xs text-muted">권리 근거</span>
              <select
                id={ids.basis}
                value={basis ?? ""}
                disabled={!editable}
                onChange={(event) => onBasisChange((event.target.value || null) as RightsBasis | null)}
                className="min-h-11 rounded-btn border border-line bg-white px-3 text-sm text-ink disabled:bg-sub-hover"
              >
                <option value="">권리 근거 선택</option>
                {RIGHTS_BASES.map((b) => (
                  <option key={b} value={b}>
                    {RIGHTS_LABEL[b]}
                  </option>
                ))}
              </select>
            </label>
            <label htmlFor={ids.use} className="flex min-h-11 items-center gap-2 font-semibold">
              <input
                id={ids.use}
                type="checkbox"
                checked={source.used}
                disabled={!editable || (!source.used && basis === null)}
                onChange={onToggleUse}
                className="size-4"
              />
              <span>편집에 사용</span>
            </label>
          </>
        ) : (
          <p className="text-xs text-muted">내려받은 뒤 화질·장면을 보고 사용 여부를 고릅니다.</p>
        )}
      </div>
    </article>
  );
}
