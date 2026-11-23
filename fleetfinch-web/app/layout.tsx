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
      className={`${fontVariables} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="flex min-h-full flex-col font-sans">
        <header className="absolute top-3 right-3">
          <StoredThemeToggle />
        </header>
        {children}
      </body>
    </html>
  );
}
