import * as THREE from 'three';
import { mulberry32 } from '../gameplay/rng';

/**
 * Procedural FX sprites drawn once on canvas: white-on-transparent so every
 * effect can tint them. Cached for the app lifetime.
 */
const cache = new Map<string, THREE.Texture>();

function make(key: string, size: number, draw: (ctx: CanvasRenderingContext2D, s: number) => void) {
  let tex = cache.get(key);
  if (tex) return tex;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  draw(ctx, size);
  tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  cache.set(key, tex);
  return tex;
}

export const fx = {
  glow: () =>
    make('glow', 128, (c, s) => {
      const g = c.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,1)');
      g.addColorStop(0.25, 'rgba(255,255,255,0.55)');
      g.addColorStop(0.6, 'rgba(255,255,255,0.12)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.fillRect(0, 0, s, s);
    }),

  ring: () =>
    make('ring', 256, (c, s) => {
      const g = c.createRadialGradient(s / 2, s / 2, s * 0.36, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,0)');
      g.addColorStop(0.55, 'rgba(255,255,255,0.9)');
      g.addColorStop(0.75, 'rgba(255,255,255,0.35)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.fillRect(0, 0, s, s);
    }),

  /** Filled disc with a bright rim — AoE telegraphs. */
  disc: () =>
    make('disc', 256, (c, s) => {
      const g = c.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,0.10)');
      g.addColorStop(0.8, 'rgba(255,255,255,0.22)');
      g.addColorStop(0.94, 'rgba(255,255,255,0.95)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.fillRect(0, 0, s, s);
    }),

  /** Ritual circle: concentric rings, a heptagram and rune ticks. */
  sigil: () =>
    make('sigil', 512, (c, s) => {
      const r = s / 2;
      c.translate(r, r);
      c.strokeStyle = 'rgba(255,255,255,0.95)';
      c.lineCap = 'round';
      const circle = (rad: number, w: number) => {
        c.lineWidth = w;
        c.beginPath();
        c.arc(0, 0, rad, 0, Math.PI * 2);
        c.stroke();
      };
      circle(r * 0.95, 5);
      circle(r * 0.86, 2);
      circle(r * 0.5, 3);
      circle(r * 0.18, 2);
      c.lineWidth = 3;
      c.beginPath();
      for (let i = 0; i <= 7; i++) {
        const a = (i * 3 * Math.PI * 2) / 7 - Math.PI / 2;
        const x = Math.cos(a) * r * 0.86;
        const y = Math.sin(a) * r * 0.86;
        if (i === 0) c.moveTo(x, y);
        else c.lineTo(x, y);
      }
      c.stroke();
      const rand = mulberry32(7);
      c.lineWidth = 2.5;
      for (let i = 0; i < 28; i++) {
        const a = (i / 28) * Math.PI * 2;
        c.save();
        c.rotate(a);
        c.translate(0, -r * 0.905);
        c.beginPath();
        // Crude rune: 2–3 strokes.
        const strokes = 2 + Math.floor(rand() * 2);
        for (let k = 0; k < strokes; k++) {
          c.moveTo((rand() - 0.5) * 12, (rand() - 0.5) * 12);
          c.lineTo((rand() - 0.5) * 12, (rand() - 0.5) * 12);
        }
        c.stroke();
        c.restore();
      }
    }),

  /** 60° sector, bright at the rim — cone telegraphs (apex at bottom-centre). */
  cone: () =>
    make('cone', 256, (c, s) => {
      const half = (30 * Math.PI) / 180;
      const g = c.createRadialGradient(s / 2, s, 0, s / 2, s, s);
      g.addColorStop(0, 'rgba(255,255,255,0.1)');
      g.addColorStop(0.85, 'rgba(255,255,255,0.35)');
      g.addColorStop(0.97, 'rgba(255,255,255,0.95)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.beginPath();
      c.moveTo(s / 2, s);
      c.arc(s / 2, s, s, -Math.PI / 2 - half, -Math.PI / 2 + half);
      c.closePath();
      c.fill();
    }),

  /** Outline of the same 60° sector: both straight sides and the arc, with a soft glow. Cone telegraphs draw it over the fill so the shape reads on any floor. */
  coneEdge: () =>
    make('coneEdge', 256, (c, s) => {
      const half = (30 * Math.PI) / 180;
      c.lineJoin = 'round';
      c.lineCap = 'round';
      for (const [w, a] of [[11, 0.22], [4.5, 0.95]] as const) {
        c.strokeStyle = `rgba(255,255,255,${a})`;
        c.lineWidth = w;
        c.beginPath();
        c.moveTo(s / 2, s - 3);
        c.arc(s / 2, s, s - 6, -Math.PI / 2 - half, -Math.PI / 2 + half);
        c.closePath();
        c.stroke();
      }
    }),

  /** Soft fill with bright side and end edges: line telegraphs (lances, spoke volleys). */
  bar: () =>
    make('bar', 128, (c, s) => {
      c.fillStyle = 'rgba(255,255,255,0.2)';
      c.fillRect(0, 0, s, s);
      for (const [w, a] of [[9, 0.25], [3.5, 0.95]] as const) {
        c.strokeStyle = `rgba(255,255,255,${a})`;
        c.lineWidth = w;
        c.strokeRect(w / 2 + 1, w / 2 + 1, s - w - 2, s - w - 2);
      }
    }),

  smoke: () =>
    make('smoke', 128, (c, s) => {
      const rand = mulberry32(11);
      for (let i = 0; i < 26; i++) {
        const x = s / 2 + (rand() - 0.5) * s * 0.45;
        const y = s / 2 + (rand() - 0.5) * s * 0.45;
        const rr = s * (0.12 + rand() * 0.22);
        const g = c.createRadialGradient(x, y, 0, x, y, rr);
        g.addColorStop(0, 'rgba(255,255,255,0.18)');
        g.addColorStop(1, 'rgba(255,255,255,0)');
        c.fillStyle = g;
        c.fillRect(0, 0, s, s);
      }
    }),

  spark: () =>
    make('spark', 64, (c, s) => {
      const g = c.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,1)');
      g.addColorStop(0.3, 'rgba(255,255,255,0.4)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.fillRect(0, 0, s, s);
      c.strokeStyle = 'rgba(255,255,255,0.8)';
      c.lineWidth = 2;
      c.beginPath();
      c.moveTo(s / 2, 4);
      c.lineTo(s / 2, s - 4);
      c.moveTo(4, s / 2);
      c.lineTo(s - 4, s / 2);
      c.stroke();
    }),

  /** Radiating ground cracks for grave breaches / exhumes. */
  cracks: () =>
    make('cracks', 256, (c, s) => {
      const rand = mulberry32(23);
      c.translate(s / 2, s / 2);
      const g = c.createRadialGradient(0, 0, 0, 0, 0, s * 0.3);
      g.addColorStop(0, 'rgba(255,255,255,0.7)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.beginPath();
      c.arc(0, 0, s * 0.3, 0, Math.PI * 2);
      c.fill();
      c.strokeStyle = 'rgba(255,255,255,0.95)';
      c.lineCap = 'round';
      for (let i = 0; i < 11; i++) {
        let a = rand() * Math.PI * 2;
        let x = 0;
        let y = 0;
        c.lineWidth = 3.5;
        c.beginPath();
        c.moveTo(x, y);
        const len = s * (0.25 + rand() * 0.22);
        for (let d = 0; d < len; d += 8) {
          a += (rand() - 0.5) * 0.7;
          x += Math.cos(a) * 8;
          y += Math.sin(a) * 8;
          c.lineTo(x, y);
          c.lineWidth = Math.max(0.8, 3.5 * (1 - d / len));
        }
        c.stroke();
      }
    }),

  /** Soft warm pool for fake candle light on the floor. */
  lightPool: () =>
    make('lightPool', 128, (c, s) => {
      const g = c.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,0.55)');
      g.addColorStop(0.4, 'rgba(255,255,255,0.2)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      c.fillStyle = g;
      c.fillRect(0, 0, s, s);
    }),
};

/** Flat, tintable material for ground decals / billboards. */
export function additive(map: THREE.Texture, color: THREE.ColorRepresentation, opacity = 1) {
  return new THREE.MeshBasicMaterial({
    map,
    color,
    transparent: true,
    opacity,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
    side: THREE.DoubleSide,
  });
}
