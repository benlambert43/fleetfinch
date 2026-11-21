import type { Metadata } from "next";
import "./globals.css";

import { fontVariables } from "@/app/_lib/fonts.ts";
import { site, siteOpenGraph, siteUrl } from "@/app/_lib/site.ts";

export const metadata: Metadata = {
  metadataBase: siteUrl(),
  title: { default: site.name, template: `%s | ${site.name}` },
  description: site.description,
  openGraph: siteOpenGraph,
  twitter: { card: "summary_large_image" },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${fontVariables} h-full antialiased`}>
      <body className="flex min-h-full flex-col font-sans">{children}</body>
    </html>
  );
}
