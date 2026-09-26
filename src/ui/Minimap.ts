import { AREAS, AREA_ORDER, DOORS, type AreaId } from '../content/areas';

export interface MinimapFrame {
  px: number;
  pz: number;
  facing: number;
  unlocked: (a: AreaId) => boolean;
  enemies: Iterable<{ x: number; z: number; elite: boolean }>;
  thralls: Iterable<{ x: number; z: number }>;
  allies: { x: number; z: number }[];
  corpses: Iterable<{ x: number; z: number }>;
  boss: { x: number; z: number } | null;
  waystones: { x: number; z: number }[];
}

const SCALE = 2.1; // px per world unit (at 190px canvas)

/** Circular top-right minimap, north-up, centred on the player. */
export class Minimap {
  readonly canvas = document.createElement('canvas');
  private ctx: CanvasRenderingContext2D;

  constructor() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.canvas.width = this.canvas.height = Math.round(190 * dpr);
    this.ctx = this.canvas.getContext('2d')!;
    this.ctx.scale(dpr, dpr);
    this.canvas.setAttribute('role', 'img');
    this.canvas.setAttribute('aria-label', 'Minimap');
  }

  draw(f: MinimapFrame) {
    const c = this.ctx;
    const S = 190;
    const half = S / 2;
    const tx = (x: number) => half + (x - f.px) * SCALE;
    const tz = (z: number) => half + (z - f.pz) * SCALE;
    c.clearRect(0, 0, S, S);
    c.fillStyle = '#07060a';
    c.fillRect(0, 0, S, S);

    // Areas + doors.
    for (const id of AREA_ORDER) {
      const r = AREAS[id].rect;
      const open = f.unlocked(id);
      c.fillStyle = open ? (AREAS[id].safe ? '#2a2233' : '#231d2b') : '#110e15';
      c.strokeStyle = open ? 'rgba(216,207,189,0.45)' : 'rgba(216,207,189,0.12)';
      c.lineWidth = 1;
      c.fillRect(tx(r.x0), tz(r.z0), (r.x1 - r.x0) * SCALE, (r.z1 - r.z0) * SCALE);
      c.strokeRect(tx(r.x0) + 0.5, tz(r.z0) + 0.5, (r.x1 - r.x0) * SCALE, (r.z1 - r.z0) * SCALE);
      if (!open) {
        // Hatch sealed areas.
        c.save();
        c.beginPath();
        c.rect(tx(r.x0), tz(r.z0), (r.x1 - r.x0) * SCALE, (r.z1 - r.z0) * SCALE);
        c.clip();
        c.strokeStyle = 'rgba(155,92,255,0.12)';
        for (let k = -400; k < 400; k += 8) {
          c.beginPath();
          c.moveTo(tx(r.x0) + k, tz(r.z0));
          c.lineTo(tx(r.x0) + k + 200, tz(r.z0) + 200);
          c.stroke();
        }
        c.restore();
      }
    }
    for (const d of DOORS) {
      const open = f.unlocked(d.a) && f.unlocked(d.b);
      c.fillStyle = open ? '#2a2233' : '#3b1d5e';
      c.fillRect(tx(d.rect.x0), tz(d.rect.z0), (d.rect.x1 - d.rect.x0) * SCALE, (d.rect.z1 - d.rect.z0) * SCALE);
    }

    const dot = (x: number, z: number, r: number, color: string) => {
      const sx = tx(x);
      const sz = tz(z);
      if (sx < -4 || sz < -4 || sx > S + 4 || sz > S + 4) return;
      c.fillStyle = color;
      c.beginPath();
      c.arc(sx, sz, r, 0, Math.PI * 2);
      c.fill();
    };
    for (const w of f.waystones) {
      c.fillStyle = '#9b5cff';
      c.fillRect(tx(w.x) - 2, tz(w.z) - 3, 4, 6);
    }
    for (const k of f.corpses) dot(k.x, k.z, 1.2, 'rgba(216,207,189,0.35)');
    for (const e of f.enemies) dot(e.x, e.z, e.elite ? 3 : 1.8, e.elite ? '#c6a4ff' : '#c9b9a0');
    for (const t of f.thralls) dot(t.x, t.z, 2, '#6fe3c8');
    for (const a of f.allies) dot(a.x, a.z, 3, '#8f9ed1');
    if (f.boss) {
      dot(f.boss.x, f.boss.z, 5, '#7c3aed');
      dot(f.boss.x, f.boss.z, 2.5, '#f0e9dc');
    }

    // Player arrow.
    c.save();
    c.translate(half, half);
    c.rotate(-f.facing + Math.PI);
    c.fillStyle = '#c6a4ff';
    c.strokeStyle = '#07060a';
    c.beginPath();
    c.moveTo(0, -7);
    c.lineTo(5, 5);
    c.lineTo(0, 2.5);
    c.lineTo(-5, 5);
    c.closePath();
    c.fill();
    c.stroke();
    c.restore();

    // Vignette edge.
    const g = c.createRadialGradient(half, half, half * 0.72, half, half, half);
    g.addColorStop(0, 'rgba(7,6,10,0)');
    g.addColorStop(1, 'rgba(7,6,10,0.9)');
    c.fillStyle = g;
    c.fillRect(0, 0, S, S);
  }
}
