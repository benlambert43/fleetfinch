export function ActivityToggle({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const label = open ? "Hide activity" : "Show activity";
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={() => {
        onOpenChange(!open);
      }}
      className="flex size-7 shrink-0 items-center justify-center rounded-md
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
        className="size-4.5"
      >
        <rect x="3" y="4" width="18" height="16" rx="2" />
        <path d={open ? "m10.5 15 3-3-3-3" : "m13.5 9-3 3 3 3"} />
      </svg>
    </button>
  );
}
