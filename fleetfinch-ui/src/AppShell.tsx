import type { ReactNode } from "react";

export function AppShell({
  title,
  description,
  children,
}: {
  title: string;
  description: string;
  children?: ReactNode;
}) {
  return (
    <main
      className="flex flex-1 flex-col items-center gap-10 px-6 py-16
        text-center"
    >
      <header className="flex flex-col items-center gap-4">
        <h1 className="text-4xl font-semibold tracking-tight">{title}</h1>
        <p className="max-w-md text-lg text-muted">{description}</p>
      </header>
      {children}
    </main>
  );
}

export function SectionHeading({ children }: { children: ReactNode }) {
  return (
    <h2 className="text-sm font-semibold tracking-wide text-muted uppercase">
      {children}
    </h2>
  );
}
