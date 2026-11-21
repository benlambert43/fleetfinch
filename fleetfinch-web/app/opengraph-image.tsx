import { ImageResponse } from "next/og";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

import { site } from "@/app/_lib/site.ts";

export const alt = site.name;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const inter = await readFile(
  join(process.cwd(), "assets/inter-latin-400-normal.woff"),
);

export default function Image() {
  return new ImageResponse(
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 32,
        padding: 96,
        fontFamily: "Inter",
        background: "#0a0a0a",
        color: "#ededed",
        textAlign: "center",
      }}
    >
      <div style={{ fontSize: 112 }}>{site.name}</div>
      <div style={{ fontSize: 44, color: "#a1a1aa" }}>{site.description}</div>
    </div>,
    {
      ...size,
      fonts: [{ name: "Inter", data: inter, style: "normal", weight: 400 }],
    },
  );
}
