/**
 * Procedural stand-ins for the Godot textures the converter leaves as definitions
 * (the shared noise / gradient `.tres` library, BINBUN-VFX-PORT §3 "Textures"). Pure
 * (no DOM, no three) so it is unit-tested; BinbunFX uploads the bytes as DataTextures.
 *
 * Noise is a tileable gradient-noise fBm (or Worley for cellular) at the definition's
 * frequency, normalised to 0–1 like Godot's `normalize = true`. It approximates
 * FastNoiseLite rather than matching it bit for bit, and every mask the shaders read
 * scrolls/tiles, so seamlessness matters more than the exact pattern.
 */
import type { GradientStop, TextureRef } from './godot';

export interface Baked {
  width: number;
  height: number;
  /** RGBA8, row 0 = Godot's top row (UV.y = 0). */
  data: Uint8Array<ArrayBuffer>;
}

/** Largest side we generate; Godot's 512² noise is resampled so the feature size stays the same. */
const NOISE_SIZE = 128;

function hash(x: number, y: number, seed: number) {
  let h = (x * 374761393 + y * 668265263 + seed * 1442695041) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

/** Periodic 2D gradient noise in [-1, 1]; (x, y) in cells, period p cells. */
function gradientNoise(x: number, y: number, p: number, seed: number) {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const fx = x - x0;
  const fy = y - y0;
  const g = (ix: number, iy: number, dx: number, dy: number) => {
    const a = hash(((ix % p) + p) % p, ((iy % p) + p) % p, seed) * Math.PI * 2;
    return Math.cos(a) * dx + Math.sin(a) * dy;
  };
  const s = (t: number) => t * t * t * (t * (t * 6 - 15) + 10);
  const u = s(fx);
  const v = s(fy);
  const n00 = g(x0, y0, fx, fy);
  const n10 = g(x0 + 1, y0, fx - 1, fy);
  const n01 = g(x0, y0 + 1, fx, fy - 1);
  const n11 = g(x0 + 1, y0 + 1, fx - 1, fy - 1);
  return (n00 + (n10 - n00) * u + (n01 - n00) * v + (n00 - n10 - n01 + n11) * u * v) * 1.414;
}

/** Periodic Worley F1 distance (jitter 1), in cell units. */
function cellular(x: number, y: number, p: number, seed: number) {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  let best = 9;
  for (let j = -1; j <= 1; j++) {
    for (let i = -1; i <= 1; i++) {
      const cx = x0 + i;
      const cy = y0 + j;
      const wx = ((cx % p) + p) % p;
      const wy = ((cy % p) + p) % p;
      const px = cx + hash(wx, wy, seed);
      const py = cy + hash(wy, wx, seed + 17);
      best = Math.min(best, Math.hypot(px - x, py - y));
    }
  }
  return best;
}

export function rampAt(stops: GradientStop[], t: number, constant = false): number[] {
  if (!stops.length) return [t, t, t, 1];
  const sorted = stops.length > 1 && stops.some((s, i) => i && s.t < stops[i - 1].t) ? [...stops].sort((a, b) => a.t - b.t) : stops;
  if (t <= sorted[0].t) return sorted[0].c;
  for (let i = 1; i < sorted.length; i++) {
    const b = sorted[i];
    if (t <= b.t) {
      const a = sorted[i - 1];
      if (constant) return a.c;
      const k = (t - a.t) / Math.max(1e-6, b.t - a.t);
      return a.c.map((v, j) => v + ((b.c[j] ?? v) - v) * k);
    }
  }
  return sorted[sorted.length - 1].c;
}

function bakeNoise(ref: Extract<TextureRef, { kind: 'noise' }>): Baked {
  const w = Math.min(NOISE_SIZE, Math.max(8, ref.size[0]));
  const h = Math.min(NOISE_SIZE, Math.max(8, ref.size[1]));
  // Frequency is per Godot pixel; keep the same number of features across the tile (a whole number, so it tiles).
  const period = Math.max(1, Math.round(ref.frequency * ref.size[0]));
  const values = new Float32Array(w * h);
  let lo = Infinity;
  let hi = -Infinity;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const u = x / w;
      const v = y / h;
      let n: number;
      if (ref.cellular) n = cellular(u * period, v * period, period, ref.seed);
      else {
        n = 0;
        let amp = 1;
        let p = period;
        for (let o = 0; o < Math.max(1, Math.min(6, ref.octaves)); o++) {
          let s = gradientNoise(u * p, v * p, p, ref.seed + o * 31);
          if (ref.fractal === 2) s = 1 - Math.abs(s);
          else if (ref.fractal === 3) s = Math.abs(s);
          n += s * amp;
          amp *= ref.gain;
          p *= 2;
        }
      }
      values[y * w + x] = n;
      lo = Math.min(lo, n);
      hi = Math.max(hi, n);
    }
  }
  const data = new Uint8Array(w * h * 4);
  const span = hi - lo || 1;
  for (let i = 0; i < w * h; i++) {
    let t = (values[i] - lo) / span;
    if (ref.invert) t = 1 - t;
    const c = ref.ramp ? rampAt(ref.ramp, t) : [t, t, t, 1];
    data[i * 4] = Math.round(Math.max(0, Math.min(1, c[0])) * 255);
    data[i * 4 + 1] = Math.round(Math.max(0, Math.min(1, c[1])) * 255);
    data[i * 4 + 2] = Math.round(Math.max(0, Math.min(1, c[2])) * 255);
    data[i * 4 + 3] = Math.round(Math.max(0, Math.min(1, c[3] ?? 1)) * 255);
  }
  return { width: w, height: h, data };
}

function bakeGradient(ref: Extract<TextureRef, { kind: 'gradient' }>): Baked {
  const w = Math.min(256, Math.max(1, ref.size[0]));
  const h = ref.oneD ? 1 : Math.min(256, Math.max(1, ref.size[1]));
  const data = new Uint8Array(w * h * 4);
  const [fx, fy] = ref.from;
  const dx = ref.to[0] - fx;
  const dy = ref.to[1] - fy;
  const len2 = dx * dx + dy * dy || 1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const u = (x + 0.5) / w;
      const v = (y + 0.5) / h;
      let t: number;
      if (ref.oneD) t = u;
      else if (ref.fill === 1) t = Math.hypot(u - fx, v - fy) / Math.sqrt(len2);
      else if (ref.fill === 2) t = Math.max(Math.abs(u - fx), Math.abs(v - fy)) / Math.max(1e-6, Math.max(Math.abs(dx), Math.abs(dy)));
      else t = ((u - fx) * dx + (v - fy) * dy) / len2;
      if (ref.repeat === 1) t -= Math.floor(t);
      else if (ref.repeat === 2) t = 1 - Math.abs((((t % 2) + 2) % 2) - 1);
      const c = rampAt(ref.stops, Math.max(0, Math.min(1, t)), ref.constant);
      const o = (y * w + x) * 4;
      for (let k = 0; k < 4; k++) data[o + k] = Math.round(Math.max(0, Math.min(1, c[k] ?? 1)) * 255);
    }
  }
  return { width: w, height: h, data };
}

export function bakeTexture(ref: TextureRef): Baked | null {
  if (ref.kind === 'noise') return bakeNoise(ref);
  if (ref.kind === 'gradient') return bakeGradient(ref);
  return null;
}
