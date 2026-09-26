/** Inline SVG glyphs (currentColor) for HUD chrome — no emoji in the necromancer UI. */
const svg = (body: string, vb = '0 0 24 24') =>
  `<svg viewBox="${vb}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

export const ICON = {
  skull: svg('<path d="M12 3c-4.4 0-7.5 3-7.5 7 0 2.2 1 3.8 2.5 4.8V18h2v2h1.5v-2h3v2H15v-2h2v-3.2c1.5-1 2.5-2.6 2.5-4.8 0-4-3.1-7-7.5-7z"/><circle cx="9" cy="10.5" r="1.6" fill="currentColor"/><circle cx="15" cy="10.5" r="1.6" fill="currentColor"/><path d="M11 14h2"/>'),
  crown: svg('<path d="M4 17l1.5-9 4 4L12 6l2.5 6 4-4L20 17z"/><path d="M4 20h16"/>'),
  bag: svg('<path d="M6 8h12l-1 12H7z"/><path d="M9 8V6a3 3 0 016 0v2"/><path d="M10 13h4"/>'),
  anvil: svg('<path d="M4 8h12c0 2.2 1.8 4 4 4v1H9l-2 3h8v3H6"/><path d="M7 16l-1 3"/>'),
  candle: svg('<path d="M12 3c1.2 1.4 1.4 2.6 0 4-1.4-1.4-1.2-2.6 0-4z"/><path d="M9 9h6v11H9z"/><path d="M6 20h12"/>'),
  gear: svg('<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>'),
  stone: svg('<path d="M9 21l1-16 2-2 2 2 1 16z"/><path d="M11 9l2 2-2 2 2 2"/><path d="M6 21h12"/>'),
  map: svg('<path d="M3 6l6-2 6 2 6-2v14l-6 2-6-2-6 2z"/><path d="M9 4v14M15 6v14"/>'),
};
