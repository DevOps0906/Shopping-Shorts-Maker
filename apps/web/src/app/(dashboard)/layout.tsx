import { redirect } from "next/navigation";
import { ChatFab } from "@/components/chat-fab";
import { Gnb } from "@/components/gnb";
import { LOGIN_PATH } from "@/lib/supabase/paths";
import { createClient } from "@/lib/supabase/server";

export default async function DashboardLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  // proxy가 1차로 막지만, matcher 누락에 대비해 서버에서 한 번 더 확인한다.
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims) redirect(LOGIN_PATH);

  return (
    <div className="min-h-screen">
      <Gnb />
      <main className="ml-(--gnb-w) min-w-0 px-(--content-px) pt-(--content-pt) pb-(--content-pb)">
        {children}
      </main>
      <ChatFab />
    </div>
  );
}
