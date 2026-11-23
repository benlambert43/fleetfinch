import type { ReactNode } from "react";

export function AppShell({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children?: ReactNode;
}) {
  return (
    <main className="flex flex-1 flex-col gap-6 p-5 sm:p-8">
      <header className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold tracking-tight">{title}</h1>
        {description !== undefined && (
          <p className="max-w-md text-muted">{description}</p>
        )}
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
