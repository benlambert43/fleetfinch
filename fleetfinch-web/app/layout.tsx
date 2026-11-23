import type { Metadata } from "next";
import "./globals.css";

import { StoredThemeToggle } from "@/app/_components/StoredThemeToggle.tsx";
import { fontVariables } from "@/app/_lib/fonts.ts";
import { site, siteOpenGraph, siteUrl } from "@/app/_lib/site.ts";
import { themeScript } from "@/app/_lib/theme.ts";

export const metadata: Metadata = {
  metadataBase: siteUrl(),
  title: { default: site.name, template: `%s | ${site.name}` },
  description: site.description,
  openGraph: siteOpenGraph,
  twitter: { card: "summary_large_image" },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${fontVariables} h-full scrollbar-gutter-both antialiased`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="relative flex min-h-full min-w-75 flex-col font-sans">
        <header className="absolute top-2 right-2 noscript:hidden">
          <StoredThemeToggle />
        </header>
        {children}
      </body>
    </html>
  );
}
