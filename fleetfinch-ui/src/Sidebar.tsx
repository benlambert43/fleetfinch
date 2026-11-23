import type { ComponentType, ReactNode } from "react";

export interface SidebarLink<Href extends string = string> {
  href: Href;
  label: string;
}

export interface SidebarLinkProps<Href extends string = string> {
  href: Href;
  className: string;
  "aria-current": "page" | undefined;
  children: ReactNode;
}

export function Sidebar<Href extends string>({
  links,
  current,
  Link,
}: {
  links: readonly SidebarLink<Href>[];
  current: string;
  Link: ComponentType<SidebarLinkProps<Href>> | "a";
}) {
  return (
    <nav
      aria-label="Main"
      className="shrink-0 border-b border-foreground/10 bg-chrome p-3 md:w-56
        md:border-r md:border-b-0"
    >
      <ul className="flex gap-1 md:sticky md:top-3 md:flex-col">
        {links.map((link) => (
          <li key={link.href}>
            <Link
              href={link.href}
              aria-current={link.href === current ? "page" : undefined}
              className="block rounded-lg px-3 py-2 font-medium text-muted
                hover:bg-foreground/5 hover:text-foreground
                focus-visible:outline-2 focus-visible:-outline-offset-2
                focus-visible:outline-foreground
                aria-[current=page]:bg-foreground/10
                aria-[current=page]:text-foreground"
            >
              {link.label}
            </Link>
          </li>
        ))}
      </ul>
    </nav>
  );
}
