import type { ReactNode } from "react";

export function AppShell({
  title,
  children,
}: {
  title: string;
  children?: ReactNode;
}) {
  return (
    <main className="flex flex-1 flex-col gap-6 p-5 sm:p-8">
      <header>
        <h1 className="text-3xl font-light">{title}</h1>
      </header>
      {children}
    </main>
  );
}

export function SectionHeading({ children }: { children: ReactNode }) {
  return <h2 className="text-sm font-medium text-muted">{children}</h2>;
}
