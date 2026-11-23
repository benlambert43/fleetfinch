import { ActivityToggle } from "@/renderer/ActivityToggle.tsx";
import { AppMenu } from "@/renderer/AppMenu.tsx";
import { SidebarToggle } from "@/renderer/SidebarToggle.tsx";
import { WindowControls } from "@/renderer/WindowControls.tsx";

export function TitleBar({
  title,
  sidebarExpanded,
  onSidebarExpandedChange,
  activityOpen,
  onActivityOpenChange,
}: {
  title: string;
  sidebarExpanded: boolean;
  onSidebarExpandedChange: (expanded: boolean) => void;
  activityOpen: boolean;
  onActivityOpenChange: (open: boolean) => void;
}) {
  return (
    <div
      className="flex shrink-0 flex-col border-b border-foreground/10 bg-chrome
        px-2 pb-2 select-none [app-region:drag]"
    >
      <div className="flex h-11.5 items-center gap-2">
        <AppMenu />
        <SidebarToggle
          expanded={sidebarExpanded}
          onExpandedChange={onSidebarExpandedChange}
        />
        <span className="truncate text-headline">{title}</span>
        <WindowControls />
      </div>
      <div className="flex h-7 items-center gap-1 px-0.5">
        <ActivityToggle
          open={activityOpen}
          onOpenChange={onActivityOpenChange}
        />
      </div>
    </div>
  );
}
