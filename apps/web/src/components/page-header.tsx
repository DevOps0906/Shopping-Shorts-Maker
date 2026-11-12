type PageHeaderProps = {
  eyebrow: string;
  title: string;
};

/** 상단 바의 eyebrow·제목 자리. 채널 선택·AI 상태·크레딧은 데이터 연동 작업에서 붙인다. */
export function PageHeader({ eyebrow, title }: PageHeaderProps) {
  return (
    <header className="flex flex-col gap-1">
      <p className="text-xs font-semibold tracking-widest text-muted">{eyebrow}</p>
      <h1 className="text-app font-bold">{title}</h1>
    </header>
  );
}
