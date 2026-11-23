import { AppMenu } from "@/renderer/AppMenu.tsx";
import { SidebarToggle } from "@/renderer/SidebarToggle.tsx";
import { WindowControls } from "@/renderer/WindowControls.tsx";

export function TitleBar({
  title,
  sidebarExpanded,
  onSidebarExpandedChange,
}: {
  title: string;
  sidebarExpanded: boolean;
  onSidebarExpandedChange: (expanded: boolean) => void;
}) {
  return (
    <div
      className="flex h-11.5 shrink-0 items-center gap-2 border-b
        border-foreground/10 bg-chrome px-2 select-none [app-region:drag]"
    >
      <AppMenu />
      <SidebarToggle
        expanded={sidebarExpanded}
        onExpandedChange={onSidebarExpandedChange}
      />
      <span className="truncate text-[17px] font-medium">{title}</span>
      <WindowControls />
    </div>
  );
}
