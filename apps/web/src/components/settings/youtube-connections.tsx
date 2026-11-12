import { btnClass, btnPrimaryClass } from "@/components/studio/step-actions";
import { type BannerTone, InlineBanner } from "@/components/feedback";
import { DisconnectButton } from "./disconnect-button";

/*
 * 다중 계정 탭의 YouTube 연결·재연결·해제 버튼(task-022a, 최소 화면). 계정 카드·채널 화면은 022b.
 * 폼 POST → /api/oauth/youtube/* (서버가 소유·state·PKCE 를 검사). 토큰은 화면에 오지 않는다.
 */

export type YoutubeAccountRow = {
  id: string;
  channel_name: string;
  status: "connected" | "reconnect_required" | string;
};

const RESULT_TEXT: Record<string, { tone: BannerTone; text: string }> = {
  connected: { tone: "success", text: "YouTube 채널을 연결했습니다." },
  disconnected: { tone: "success", text: "연결을 해제했습니다. Google 권한도 폐기했습니다." },
  config_missing: { tone: "warning", text: "YouTube 연결 설정이 필요합니다. 관리자에게 Google OAuth 설정을 요청하세요." },
  not_allowed: { tone: "error", text: "이 계정은 연결할 수 없습니다." },
  invalid_state: { tone: "error", text: "연결 요청이 만료됐거나 올바르지 않습니다. 다시 시도하세요." },
  denied: { tone: "warning", text: "Google 동의가 취소됐습니다." },
  scope_missing: { tone: "error", text: "업로드·채널 조회·분석 권한 3개를 모두 허용해야 연결됩니다." },
  no_channel: { tone: "error", text: "이 Google 계정에 YouTube 채널이 없습니다." },
  channel_mismatch: { tone: "error", text: "이 계정에 연결했던 채널과 다른 채널입니다. 같은 채널로 다시 연결하세요." },
  channel_taken: { tone: "error", text: "이미 다른 계정에 연결된 채널입니다." },
  no_refresh_token: { tone: "error", text: "Google이 갱신 권한을 주지 않았습니다. 다시 연결하세요." },
  too_many: { tone: "warning", text: "연결 요청이 너무 많습니다. 잠시 후 다시 시도하세요." },
  revoke_failed: { tone: "error", text: "Google 권한 폐기에 실패했습니다. 잠시 후 다시 시도하세요." },
  failed: { tone: "error", text: "연결 처리 중 문제가 생겼습니다. 다시 시도하세요." },
};

export function YoutubeConnections({
  accounts,
  configured,
  result,
}: {
  accounts: YoutubeAccountRow[];
  configured: boolean;
  result: string | null;
}) {
  const banner = result ? RESULT_TEXT[result] : undefined;
  return (
    <section className="flex flex-col gap-4 rounded-card border border-line bg-white p-6 shadow-card">
      <h2 className="text-base font-bold">YouTube 연결</h2>
      {banner ? <InlineBanner tone={banner.tone}>{banner.text}</InlineBanner> : null}
      {!configured ? (
        <InlineBanner tone="warning">
          설정 필요: 서버에 Google OAuth 값(GOOGLE_OAUTH_CLIENT_ID · GOOGLE_OAUTH_CLIENT_SECRET · OAUTH_REDIRECT_BASE_URL)이
          없어 연결할 수 없습니다.
        </InlineBanner>
      ) : null}
      {accounts.length === 0 ? (
        <p className="text-sm text-muted">YouTube 계정이 없습니다.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-line">
          {accounts.map((a) => {
            const connected = a.status === "connected";
            return (
              <li key={a.id} className="flex flex-col gap-2 py-3 md:flex-row md:items-center md:justify-between">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold">{a.channel_name}</p>
                  <p className="text-xs text-muted">{connected ? "연결됨" : "재연결 필요"}</p>
                </div>
                <div className="flex flex-wrap gap-2">
                  {configured ? (
                    <form method="post" action="/api/oauth/youtube/start">
                      <input type="hidden" name="accountId" value={a.id} />
                      <button type="submit" className={connected ? btnClass : `${btnClass} ${btnPrimaryClass}`}>
                        {connected ? "재연결" : "연결"}
                      </button>
                    </form>
                  ) : (
                    <button type="button" disabled className={btnClass}>
                      설정 필요
                    </button>
                  )}
                  {connected ? <DisconnectButton accountId={a.id} /> : null}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
