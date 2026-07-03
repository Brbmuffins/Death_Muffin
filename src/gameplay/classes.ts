// Mirrors CLASS_NAMES in /opt/rod-auth/server.js — keep in sync with the server.
// Colors are used for class cards, party HUD, and remote player capsules.
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

// Hero portraits (public/art).
// Brandolf = Cleric, Bo-Gar = Shadowblade (user directives).
// Guardian / Arcanist cropped from concept sheets in Inspiration ART.
export const PORTRAITS: Record<number, string> = {
  1: 'art/hero-guardian.png',
  2: 'art/hero-bogar.png',
  3: 'art/hero-brandolf.png',
  4: 'art/hero-arcanist.png',
};
