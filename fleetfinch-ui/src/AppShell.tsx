import type { ReactNode } from "react";

export function AppShell({
  title,
  lead,
  children,
}: {
  title: string;
  lead?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <main className="flex flex-1 flex-col gap-6 p-5 sm:p-8">
      <header className="flex flex-col items-start gap-2">
        {lead}
        <h1 className="text-3xl font-light">{title}</h1>
      </header>
      {children}
    </main>
  );
}

export function SectionHeading({ children }: { children: ReactNode }) {
  return <h2 className="text-headline text-muted">{children}</h2>;
}
