import { AppShell } from "@fleetfinch/ui";
import type { Metadata } from "next";

import { site, siteOpenGraph } from "@/app/_lib/site.ts";

export const metadata: Metadata = {
  alternates: { canonical: "/" },
  openGraph: { ...siteOpenGraph, url: "/" },
};

export default function Home() {
  return <AppShell title={site.name} description={site.description} />;
}
