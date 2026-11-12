import { ChatFab } from "@/components/chat-fab";
import { Gnb } from "@/components/gnb";

export default function DashboardLayout({ children }: Readonly<{ children: React.ReactNode }>) {
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
