import type { Metadata } from "next";
import Image from "next/image";

import { InstallChecklist } from "@/app/_components/InstallChecklist.tsx";
import { Prerequisites } from "@/app/_components/Prerequisites.tsx";
import { SupportedDevices } from "@/app/_components/SupportedDevices.tsx";
import { site, siteOpenGraph } from "@/app/_lib/site.ts";
import finch from "@/assets/finch.png";

export const metadata: Metadata = {
  alternates: { canonical: "/" },
  openGraph: { ...siteOpenGraph, url: "/" },
};

export default function Home() {
  return (
    <main className="grow px-6 py-16 text-center">
      <header>
        <Image
          src={finch}
          alt=""
          sizes="(min-width: 48rem) 15rem, 10rem"
          loading="eager"
          className="mx-auto mb-4 h-auto w-40 md:mb-6 md:w-60"
        />
        <h1 className="mb-4 text-4xl font-semibold tracking-tight">
          {site.name}
        </h1>
        <p className="mx-auto max-w-md text-lg text-muted">
          {site.description}
        </p>
      </header>
      <section
        aria-labelledby="installation-steps"
        className="mx-auto max-w-md"
      >
        <h2
          id="installation-steps"
          className="mt-10 mb-5 text-2xl font-semibold"
        >
          Installation Steps
        </h2>
        <div className="text-left">
          <h3 className="mb-1 text-lg font-semibold">
            Installation Prerequisites
          </h3>
          <Prerequisites />
          <h3 className="mt-5 mb-1 text-lg font-semibold">Installation</h3>
          <InstallChecklist />
        </div>
      </section>
      <SupportedDevices />
    </main>
  );
}
