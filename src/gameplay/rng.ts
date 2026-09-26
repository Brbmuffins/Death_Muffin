/** Small deterministic PRNG (mulberry32) for procedural layout — same seed, same world. */
export function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function pickWeighted<T extends { weight: number }>(items: T[], r: number): T | undefined {
  const total = items.reduce((n, i) => n + i.weight, 0);
  let roll = r * total;
  for (const item of items) {
    if (roll < item.weight) return item;
    roll -= item.weight;
  }
  return items[items.length - 1];
}

export function randRange(rand: () => number, min: number, max: number) {
  return min + rand() * (max - min);
}

export function randInt(rand: () => number, min: number, max: number) {
  return Math.floor(min + rand() * (max - min + 1));
}
