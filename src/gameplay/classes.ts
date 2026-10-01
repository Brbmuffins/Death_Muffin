// Mirrors Death Muffin class indices in server/death-muffin/backend/server.js.
// These are the server's legacy class names; the client presents each index as
// a necromantic discipline (content/disciplines.ts), which owns names,
// portraits and tuning.
export const CLASSES = [
  { index: 0, name: 'Engineer', role: '—', color: '#9ca3af' },
  { index: 1, name: 'Guardian', role: 'Tank / frontline', color: '#f59e0b' },
  { index: 2, name: 'Shadowblade', role: 'Burst / rogue', color: '#a78bfa' },
  { index: 3, name: 'Cleric', role: 'Healer / support', color: '#fde68a' },
  { index: 4, name: 'Arcanist', role: 'Ranged magic DPS', color: '#60a5fa' },
  // Release 0.3: these have no legacy name — the server stores them as
  // `discipline_index` only (DISCIPLINE_NAMES in the Death Muffin backend), so
  // the mirror carries the class's own name rather than a stand-in.
  { index: 5, name: 'Grave Warden', role: 'Lantern and flail', color: '#f2b84b' },
  { index: 6, name: 'Bell Monk', role: 'Rhythm melee', color: '#e8d9a0' },
  { index: 7, name: 'Carrion Witch', role: 'Crows and hooks', color: '#9a1b2a' },
  { index: 8, name: 'Hollow Knight', role: 'Tank / frontline', color: '#b8c0cc' },
  { index: 9, name: 'Veilwalker', role: 'Spirit medium', color: '#bff3ff' },
] as const;

export function classByIndex(index: number) {
  return CLASSES.find((c) => c.index === index) ?? CLASSES[0];
}
