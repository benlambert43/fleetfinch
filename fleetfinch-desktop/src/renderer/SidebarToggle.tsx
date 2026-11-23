export function SidebarToggle({
  expanded,
  onExpandedChange,
}: {
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
}) {
  const label = expanded ? "Collapse sidebar" : "Expand sidebar";
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={() => {
        onExpandedChange(!expanded);
      }}
      className="flex size-8 shrink-0 items-center justify-center rounded-md
        text-foreground transition-colors [app-region:no-drag]
        hover:bg-border/50 focus-visible:outline-2
        focus-visible:outline-offset-2 focus-visible:outline-foreground
        active:bg-border/80"
    >
      <svg
        viewBox="0 0 24 24"
        aria-hidden="true"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.25"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="size-5"
      >
        <rect x="3" y="4" width="18" height="16" rx="2" />
        <path d="M9 4v16" />
        <path d={expanded ? "m16 15-3-3 3-3" : "m13 9 3 3-3 3"} />
      </svg>
    </button>
  );
}
