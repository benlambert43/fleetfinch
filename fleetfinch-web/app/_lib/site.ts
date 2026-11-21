import "server-only";

import type { Metadata } from "next";

export const site = {
  name: "FleetFinch",
  description:
    "A software suite designed to bring modern functionality to iOS 9.3.5 and iOS 9.3.6 devices",
};

export const siteOpenGraph = {
  type: "website",
  siteName: site.name,
} satisfies Metadata["openGraph"];

export function siteUrl(): URL {
  const url = process.env.SITE_URL;
  if (!url) {
    throw new Error("SITE_URL is not set");
  }
  return new URL(url);
}
