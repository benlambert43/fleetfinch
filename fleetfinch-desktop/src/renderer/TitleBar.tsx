import { AppMenu } from "@/renderer/AppMenu.tsx";
import { WindowControls } from "@/renderer/WindowControls.tsx";

export function TitleBar({ title }: { title: string }) {
  return (
    <div
      className="flex h-11.5 shrink-0 items-center gap-2 border-b
        border-foreground/10 bg-chrome px-2 select-none [app-region:drag]"
    >
      <AppMenu />
      <span className="truncate text-sm font-medium text-muted">{title}</span>
      <WindowControls />
    </div>
  );
}
