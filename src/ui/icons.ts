/** Inline SVG glyphs (currentColor) for HUD chrome — no emoji in the necromancer UI. */
const svg = (body: string, vb = '0 0 24 24') =>
  `<svg viewBox="${vb}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

export const ICON = {
  skull: svg('<path d="M12 3c-4.4 0-7.5 3-7.5 7 0 2.2 1 3.8 2.5 4.8V18h2v2h1.5v-2h3v2H15v-2h2v-3.2c1.5-1 2.5-2.6 2.5-4.8 0-4-3.1-7-7.5-7z"/><circle cx="9" cy="10.5" r="1.6" fill="currentColor"/><circle cx="15" cy="10.5" r="1.6" fill="currentColor"/><path d="M11 14h2"/>'),
  flask: svg('<path d="M10 3h4M10.5 3v5L6 16.5A3 3 0 008.7 21h6.6a3 3 0 002.7-4.5L13.5 8V3"/><path d="M7.6 14h8.8"/>'),
  expand: svg('<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>'),
  crown: svg('<path d="M4 17l1.5-9 4 4L12 6l2.5 6 4-4L20 17z"/><path d="M4 20h16"/>'),
  bag: svg('<path d="M8 6a4 4 0 018 0"/><path d="M6 9a2 2 0 012-2h8a2 2 0 012 2v10a2 2 0 01-2 2H8a2 2 0 01-2-2z"/><path d="M9 14h6v4H9z"/><path d="M9 11h6"/>'),
  anvil: svg('<path d="M3 15h11c0 2 1.5 3 3 3H7c1.5 0 2.5-1 2.5-3"/><path d="M3 15c0-2 1.5-3 3-3h12v1.5c-1.5 1-3 1.5-4 1.5"/><path d="M5 21h12"/><path d="M15 3l4 4-2 2-4-4z"/><path d="M14 6l-4 4"/>'),
  candle: svg('<path d="M12 3c1.2 1.4 1.4 2.6 0 4-1.4-1.4-1.2-2.6 0-4z"/><path d="M9 9h6v11H9z"/><path d="M6 20h12"/>'),
  gear: svg('<circle cx="12" cy="12" r="3"/><path d="M10.4 3h3.2l.5 2.4 1.7.9 2.3-.9 1.6 2.8-1.8 1.7v1.9l1.8 1.7-1.6 2.8-2.3-.9-1.7.9-.5 2.4h-3.2l-.5-2.4-1.7-.9-2.3.9-1.6-2.8 1.8-1.7v-1.9L4.3 7.2l1.6-2.8 2.3.9 1.7-.9z"/>'),
  stone: svg('<path d="M3 7l6-2 6 2 6-2v12l-6 2-6-2-6 2z"/><path d="M9 5v12M15 7v12"/>'),
  map: svg('<path d="M3 6l6-2 6 2 6-2v14l-6 2-6-2-6 2z"/><path d="M9 4v14M15 6v14"/>'),
  /** Gathering skills: pickaxe crossed with a hatchet. */
  skills: svg('<path d="M4 8c3-4 9-4 12-1M10 5.5L18 21M7 5l1.6 3.4"/><path d="M14 9l5-1 2 2-1 5-3-1z"/><path d="M13 12L5 21"/>'),
  /** Waystones: map with a pin. */
  waymap: svg('<path d="M3 7l6-2 6 2 6-2v12l-6 2-6-2-6 2z"/><path d="M9 5v12M15 7v12"/><path d="M12 4a3 3 0 013 3c0 2-3 5-3 5s-3-3-3-5a3 3 0 013-3z" fill="currentColor"/>'),
  /** Character sheet: a figure. */
  person: svg('<circle cx="12" cy="7" r="3.2"/><path d="M5 21v-3a5 5 0 015-5h4a5 5 0 015 5v3"/>'),
  /** Legion: skull in front of a shield. */
  legion: svg('<path d="M12 2l8 3v7c0 5-3.5 8.5-8 10-4.5-1.5-8-5-8-10V5z"/><circle cx="9.7" cy="10" r="1.3" fill="currentColor"/><circle cx="14.3" cy="10" r="1.3" fill="currentColor"/><path d="M9.5 15h5M11 13.2v1.8M13 13.2v1.8"/>'),
  /** Contracts: a rolled scroll with a seal. */
  contract: svg('<path d="M6 3h11a2 2 0 012 2v12H8V5a2 2 0 00-2-2z"/><path d="M6 3a2 2 0 00-2 2v1h4"/><path d="M8 17v1a3 3 0 003 3h8a2 2 0 002-2v-2z"/><path d="M11 8h5M11 11h5"/>'),
  /** Garden: a sprout. */
  sprout: svg('<path d="M12 21v-9"/><path d="M12 13C12 8 8 6 4 6c0 5 3 7 8 7z"/><path d="M12 11c0-4 3-6 8-6 0 4-3 6-8 6z"/><path d="M8 21h8"/>'),
  /** Laborers: a shovel. */
  shovel: svg('<path d="M14 3l3 3-4 4"/><path d="M15.5 4.5L9 11"/><path d="M9 11l-5 5a2 2 0 000 2.8l1.2 1.2a2 2 0 002.8 0l5-5z"/>'),
  /** Capes & Pets: a cape on a hanger. */
  cape: svg('<path d="M12 3a2 2 0 011.4 3.4L12 8"/><path d="M12 8L3 14h18z"/><path d="M5 14l-1 7h16l-1-7"/>'),
  /** Vault: strongbox. */
  chest: svg('<path d="M4 11a8 8 0 0116 0v9H4z"/><path d="M4 12h16"/><rect x="10" y="10" width="4" height="4" rx=".6" fill="currentColor"/><path d="M4 20h16"/>'),
  menu: svg('<path d="M4 7h16M4 12h16M4 17h16"/>'),
  close: svg('<path d="M6 6l12 12M18 6L6 18"/>'),
  /** Closed book (the Codex): cover, page block, a bone cross on the boards. */
  book: svg('<path d="M5 5a2 2 0 012-2h12v14H7a2 2 0 00-2 2z"/><path d="M5 19a2 2 0 002 2h12v-4"/><path d="M10.6 8.3a1.6 1.6 0 113 .6c-.3.8-1.6 1-1.6 2.2"/><path d="M12 13.2v.1"/>'),
  /** Open grimoire (the rite loadout): two pages with a sigil ring. */
  grimoire: svg('<path d="M3 5.5c3-1 6-1 9 1 3-2 6-2 9-1V19c-3-1-6-1-9 1-3-2-6-2-9-1z"/><path d="M12 6.5V20"/><circle cx="7.5" cy="11.5" r="2"/><path d="M15 10h3.5M15 13h3.5"/>'),
  /** Wax seal with ribbon tails (sealed Codex entries). */
  seal: svg('<circle cx="12" cy="10" r="6"/><circle cx="12" cy="10" r="2.4"/><path d="M9 15.2L7.5 21l4.5-2.4 4.5 2.4-1.5-5.8"/>'),
};
