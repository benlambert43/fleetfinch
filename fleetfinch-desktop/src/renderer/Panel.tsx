import { type ReactNode, useId } from "react";

export const primaryButton = `h-9 rounded-lg bg-primary px-3 text-subheadline
  text-primary-foreground hover:opacity-90 focus-visible:outline-2
  focus-visible:outline-offset-2 focus-visible:outline-foreground
  disabled:opacity-60`;

export const secondaryButton = `h-9 rounded-lg bg-secondary px-3
  text-subheadline text-secondary-foreground hover:opacity-90
  focus-visible:outline-2 focus-visible:outline-offset-2
  focus-visible:outline-foreground disabled:opacity-60`;

export function PanelBody({ children }: { children: ReactNode }) {
  return <div className="flex flex-1 flex-col gap-4">{children}</div>;
}

export function StatusList({ children }: { children: ReactNode }) {
  return <dl className="flex flex-col gap-3">{children}</dl>;
}

export function StatusRow({
  icon,
  title,
  state,
  description,
}: {
  icon: ReactNode;
  title: string;
  state?: string;
  description: string;
}) {
  return (
    <div className="flex items-start gap-2">
      {icon}
      <div className="flex min-w-0 flex-wrap items-baseline gap-x-2">
        <dt className="text-subheadline">
          {title}
          {state !== undefined && <span className="sr-only">, {state}</span>}
        </dt>
        <dd className="text-footnote wrap-break-word text-muted">
          {description}
        </dd>
      </div>
    </div>
  );
}

export function EmptyState(row: {
  icon: ReactNode;
  title: string;
  description: string;
}) {
  return (
    <dl className="-mt-3 flex flex-1 flex-col justify-center [&:has(+*)]:-mb-4">
      <StatusRow {...row} />
    </dl>
  );
}

export function PanelSection({
  title,
  divided = false,
  children,
}: {
  title: string;
  divided?: boolean;
  children: ReactNode;
}) {
  const headingId = useId();
  return (
    <section
      aria-labelledby={headingId}
      className={`flex flex-1 flex-col gap-2 ${
        divided ? "border-t border-border pt-4" : ""
      }`}
    >
      <h3 id={headingId} className="text-footnote text-muted">
        {title}
      </h3>
      {children}
    </section>
  );
}

export function SectionEmptyState(row: {
  icon: ReactNode;
  title: string;
  description: string;
}) {
  return (
    <dl className="-mb-2 flex flex-1 flex-col justify-center">
      <StatusRow {...row} />
    </dl>
  );
}

export function PanelActions({ children }: { children: ReactNode }) {
  return (
    <div className="mt-auto flex flex-col items-start gap-4">{children}</div>
  );
}
