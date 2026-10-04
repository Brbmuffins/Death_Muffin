// Golden fixtures for godot/rules/core (run: npx vite-node tools/godot/fixtures-core.ts)
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32, pickWeighted, randRange, randInt } from '../../src/gameplay/rng';

const out = 'godot/tests/rules-core/fixtures';
mkdirSync(out, { recursive: true });
const w = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v) + '\n');

// --- rng ---
const seeds = [0, 1, 2, 42, 12345, 0xdeadbeef, 0xffffffff, 4294967296 + 7, -1, 1234567.9, 987654321];
w('rng_mulberry32', seeds.map((seed) => {
  const r = mulberry32(seed);
  // ints (out * 2^32): Godot's JSON float parser is not bit-exact, integers are
  return { seed, u32: Array.from({ length: 1000 }, () => r() * 4294967296) };
}));

const items = [{ id: 'a', weight: 5 }, { id: 'b', weight: 1 }, { id: 'c', weight: 0 }, { id: 'd', weight: 2.5 }];
const pw: unknown[] = [];
for (const r of [0, 0.0001, 0.3, 0.6, 0.62, 0.7, 0.99, 0.999999]) pw.push({ r, id: pickWeighted(items, r)?.id });
const rr = mulberry32(99);
for (let i = 0; i < 200; i++) { const r = rr(); pw.push({ r, id: pickWeighted(items, r)?.id }); }
w('rng_pick_weighted', { items, cases: pw, empty: pickWeighted([], 0.5) === undefined });

const helpers: unknown[] = [];
for (const seed of [3, 77, 2024]) {
  const a = mulberry32(seed), b = mulberry32(seed), c = mulberry32(seed);
  helpers.push({
    seed,
    range: Array.from({ length: 50 }, () => randRange(a, -3.5, 12.25)),
    int: Array.from({ length: 50 }, () => randInt(b, 2, 9)),
    int_neg: Array.from({ length: 50 }, () => randInt(c, -5, 5)),
  });
}
w('rng_helpers', helpers);

// --- math (JS semantics) ---
const vals = [0, 0.5, 1.5, 2.5, -0.5, -1.5, -2.5, 0.49999999999999994, -0.49999999999999994, 1e-9, 3.14159, -3.14159, 123.456, 7, -7, 2.675, 1.005];
w('math_round', vals.map((x) => ({ x, round: Math.round(x), floor: Math.floor(x), ceil: Math.ceil(x), trunc: Math.trunc(x) })));
const dec: unknown[] = [];
for (const x of [1.005, 2.675, 0.1 + 0.2, 123.456, -1.5, 3.14159, 0.5, 1e-7, 99.995]) for (const d of [0, 1, 2, 3]) {
  const m = 10 ** d; dec.push({ x, d, v: Math.round(x * m) / m });
}
w('math_round_dec', dec);
const cl: unknown[] = [];
const cr = mulberry32(5);
for (let i = 0; i < 200; i++) {
  const x = (cr() - 0.5) * 20, lo = (cr() - 0.5) * 10, hi = lo + cr() * 10, t = cr() * 1.4 - 0.2;
  cl.push({ x, lo, hi, t, clamp: Math.min(hi, Math.max(lo, x)), lerp: lo + (hi - lo) * t, clamp01: Math.min(1, Math.max(0, t)), inv: (x - lo) / (hi - lo) });
}
w('math_clamp_lerp', cl);
const ints = [0, 1, -1, 255, 65535, 0x7fffffff, 0x80000000, 0xffffffff, 1e10, -5.7, 5.7];
w('math_int32', ints.map((x) => ({ x, u32: x >>> 0, i32: x | 0, imul3: Math.imul(x, 0x9e3779b1) })));
console.log('fixtures written');
