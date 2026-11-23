import { FolderIcon } from "@heroicons/react/20/solid";

import { EmptyState, PanelBody } from "@/renderer/Panel.tsx";

export function RecentProjects() {
  return (
    <PanelBody>
      <EmptyState
        icon={
          <FolderIcon
            aria-hidden="true"
            className="size-5 shrink-0 text-muted"
          />
        }
        title="No projects yet"
        description="Projects you create or open show up here"
      />
    </PanelBody>
  );
}
