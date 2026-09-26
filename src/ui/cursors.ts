/** Themed cursors (inline SVG data URIs — no extra requests). */
const url = (svg: string, x: number, y: number, fallback: string) =>
  `url("data:image/svg+xml;utf8,${encodeURIComponent(svg)}") ${x} ${y}, ${fallback}`;

export const CURSOR = {
  default: url(
    `<svg xmlns='http://www.w3.org/2000/svg' width='28' height='28' viewBox='0 0 28 28'><path d='M3 2 L3 22 L8.5 17 L12.5 26 L16 24.5 L12 15.5 L19.5 15.5 Z' fill='#e8dfcc' stroke='#1a1020' stroke-width='1.6' stroke-linejoin='round'/><path d='M5 6 L5 17' stroke='#9b5cff' stroke-width='1.2'/></svg>`,
    3,
    2,
    'default',
  ),
  attack: url(
    `<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32' viewBox='0 0 32 32'><circle cx='16' cy='16' r='9' fill='none' stroke='#c6a4ff' stroke-width='2'/><circle cx='16' cy='16' r='9' fill='none' stroke='#1a1020' stroke-width='0.8' stroke-dasharray='2 3'/><path d='M16 2v8M16 22v8M2 16h8M22 16h8' stroke='#e8dfcc' stroke-width='2' stroke-linecap='round'/><circle cx='16' cy='16' r='1.8' fill='#9b5cff'/></svg>`,
    16,
    16,
    'crosshair',
  ),
  interact: url(
    `<svg xmlns='http://www.w3.org/2000/svg' width='30' height='30' viewBox='0 0 30 30'><circle cx='15' cy='15' r='11' fill='rgba(20,12,28,0.6)' stroke='#c6a4ff' stroke-width='1.6'/><path d='M15 6 L18 15 L15 24 L12 15 Z' fill='#e8dfcc'/><circle cx='15' cy='15' r='2' fill='#9b5cff'/></svg>`,
    15,
    15,
    'pointer',
  ),
};
