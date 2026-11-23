import type { ReactNode } from "react";

export function Accordion({
  summary,
  className = "",
  children,
}: {
  summary: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <details
      className={`group rounded-xl border border-border text-left
        [interpolate-size:allow-keywords] details-content:h-0
        details-content:overflow-clip
        details-content:transition-[height,content-visibility]
        details-content:transition-discrete details-content:duration-200
        open:details-content:h-auto
        motion-reduce:details-content:transition-none ${className}`}
    >
      <summary
        className="flex cursor-pointer list-none items-center justify-between
          gap-4 rounded-[11px] p-4 text-lg font-semibold
          group-open:rounded-b-none hover:bg-foreground/5
          focus-visible:outline-2 focus-visible:outline-offset-2
          focus-visible:outline-foreground active:bg-foreground/10
          [&::-webkit-details-marker]:hidden"
      >
        {summary}
        <svg
          viewBox="0 0 24 24"
          aria-hidden="true"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          className="size-5 shrink-0 text-muted transition-transform
            duration-200 group-open:rotate-180 motion-reduce:transition-none"
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </summary>
      {children}
    </details>
  );
}
