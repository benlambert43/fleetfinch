import {
  Barlow,
  Besley,
  Inter,
  Noto_Sans_Mono,
  Saira_Extra_Condensed,
  Spectral,
  Tangerine,
} from "next/font/google";

const barlow = Barlow({
  weight: "700",
  variable: "--font-barlow",
  preload: false,
});
const sairaExtraCondensed = Saira_Extra_Condensed({
  weight: "700",
  variable: "--font-saira-extra-condensed",
  preload: false,
});
const inter = Inter({
  style: ["normal", "italic"],
  variable: "--font-inter",
  subsets: ["latin"],
});
const spectral = Spectral({
  weight: ["400", "700"],
  style: ["normal", "italic"],
  variable: "--font-spectral",
  preload: false,
});
const notoSansMono = Noto_Sans_Mono({
  variable: "--font-noto-sans-mono",
  preload: false,
});
const tangerine = Tangerine({
  weight: "400",
  variable: "--font-tangerine",
  preload: false,
});
const besley = Besley({
  style: ["normal", "italic"],
  variable: "--font-besley",
  preload: false,
});

export const fontVariables = [
  barlow,
  sairaExtraCondensed,
  inter,
  spectral,
  notoSansMono,
  tangerine,
  besley,
]
  .map((font) => font.variable)
  .join(" ");
