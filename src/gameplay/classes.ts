// Mirrors CLASS_NAMES in /opt/rod-auth/server.js — keep in sync with the server.
// These are the server's legacy class names; the client presents each index as
// a necromantic discipline (content/disciplines.ts), which owns names,
// portraits and tuning.
export const CLASSES = [
  { index: 0, name: 'Engineer', role: '—', color: '#9ca3af' },
  { index: 1, name: 'Guardian', role: 'Tank / frontline', color: '#f59e0b' },
  { index: 2, name: 'Shadowblade', role: 'Burst / rogue', color: '#a78bfa' },
  { index: 3, name: 'Cleric', role: 'Healer / support', color: '#fde68a' },
  { index: 4, name: 'Arcanist', role: 'Ranged magic DPS', color: '#60a5fa' },
] as const;

export function classByIndex(index: number) {
  return CLASSES.find((c) => c.index === index) ?? CLASSES[0];
}
