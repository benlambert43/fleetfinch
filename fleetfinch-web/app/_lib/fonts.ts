import {
  Amiri_Quran,
  Barlow,
  Besley,
  Inter,
  Katibeh,
  Noto_Naskh_Arabic,
  Noto_Sans_Arabic,
  Noto_Sans_Hebrew,
  Noto_Sans_KR,
  Noto_Sans_Mono,
  Noto_Sans_Thai_Looped,
  Saira_Extra_Condensed,
  Spectral,
  Tangerine,
  Vazirmatn,
} from "next/font/google";

const notoNaskhArabic = Noto_Naskh_Arabic({
  variable: "--font-noto-naskh-arabic",
  preload: false,
});
const notoSansKr = Noto_Sans_KR({
  variable: "--font-noto-sans-kr",
  preload: false,
});
const notoSansHebrew = Noto_Sans_Hebrew({
  variable: "--font-noto-sans-hebrew",
  preload: false,
});
const notoSansArabic = Noto_Sans_Arabic({
  variable: "--font-noto-sans-arabic",
  preload: false,
});
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
const amiriQuran = Amiri_Quran({
  weight: "400",
  variable: "--font-amiri-quran",
  preload: false,
});
const katibeh = Katibeh({
  weight: "400",
  variable: "--font-katibeh",
  preload: false,
});
const vazirmatn = Vazirmatn({ variable: "--font-vazirmatn", preload: false });
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
const notoSansThaiLooped = Noto_Sans_Thai_Looped({
  variable: "--font-noto-sans-thai-looped",
  preload: false,
});

export const fontVariables = [
  notoNaskhArabic,
  notoSansKr,
  notoSansHebrew,
  notoSansArabic,
  barlow,
  sairaExtraCondensed,
  amiriQuran,
  katibeh,
  vazirmatn,
  inter,
  spectral,
  notoSansMono,
  tangerine,
  besley,
  notoSansThaiLooped,
]
  .map((font) => font.variable)
  .join(" ");
