import { AREAS, AREA_ORDER, DOORS, type AreaId } from '../content/areas';
import { MINIMAP_SCALE as SCALE, MINIMAP_SIZE, minimapWalkable, minimapWorldPoint } from './minimapCoordinates';

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
  /** Accepted final movement destination; null when the route ends. */
  destination?: { x: number; z: number } | null;
  /** The people of the Covenant; `fresh` = they have something new to say. */
  npcs?: { x: number; z: number; fresh: boolean }[];
  /** Where the "Next" suggestion points: a pulsing ring when on the map, an edge arrow when beyond it. */
  ping?: { x: number; z: number } | null;
}

/** Circular top-right minimap, north-up, centred on the player. */
export class Minimap {
  readonly canvas = document.createElement('canvas');
  private ctx: CanvasRenderingContext2D;
  /** Scene validates movement state and navigation, returning true when accepted. */
  onNavigate?: (x: number, z: number) => boolean;
  private px = 0;
  private pz = 0;
  private unlocked: ((a: AreaId) => boolean) | null = null;

  constructor() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.canvas.width = this.canvas.height = Math.round(MINIMAP_SIZE * dpr);
    this.ctx = this.canvas.getContext('2d')!;
    this.ctx.scale(this.canvas.width / MINIMAP_SIZE, this.canvas.height / MINIMAP_SIZE);
    this.canvas.setAttribute('role', 'img');
    this.canvas.setAttribute('aria-label', 'Minimap. Click unlocked ground to walk there.');
    this.canvas.title = 'Click unlocked ground to walk there';
    this.canvas.addEventListener('pointerdown', event => {
      event.stopPropagation();
      if (event.button !== 0 || !event.isPrimary || !this.unlocked || !this.onNavigate) return;
      event.preventDefault();
      const point = minimapWorldPoint(event.clientX, event.clientY, this.canvas.getBoundingClientRect(), this.px, this.pz);
      if (!point || !minimapWalkable(point.x, point.z, this.unlocked)) return;
      this.onNavigate(point.x, point.z);
    });
    // Minimap input belongs to the HUD, including clicks that cannot form a route.
    for (const type of ['mousedown', 'click', 'dblclick', 'contextmenu']) this.canvas.addEventListener(type, event => {
      event.preventDefault();
      event.stopPropagation();
    });
    this.canvas.addEventListener('wheel', event => event.stopPropagation(), { passive: true });
  }

  /** The suggestion ping: a soft gold ring where it is, or a small arrow on the rim pointing toward it. */
  private drawPing(c: CanvasRenderingContext2D, dx: number, dz: number, half: number) {
    const pulse = 0.5 + 0.5 * Math.sin(performance.now() / 380);
    const px = dx * SCALE;
    const pz = dz * SCALE;
    const d = Math.hypot(px, pz);
    c.save();
    c.strokeStyle = '#f5dd8f';
    c.fillStyle = '#f5dd8f';
    if (d < half - 10) {
      c.globalAlpha = 0.55 + 0.4 * pulse;
      c.lineWidth = 2;
      c.beginPath();
      c.arc(half + px, half + pz, 6 + 3 * pulse, 0, Math.PI * 2);
      c.stroke();
      c.beginPath();
      c.arc(half + px, half + pz, 2, 0, Math.PI * 2);
      c.fill();
    } else {
      const ang = Math.atan2(pz, px);
      c.translate(half + Math.cos(ang) * (half - 9), half + Math.sin(ang) * (half - 9));
      c.rotate(ang);
      c.globalAlpha = 0.7 + 0.3 * pulse;
      c.strokeStyle = '#07060a';
      c.lineWidth = 1.5;
      c.beginPath();
      c.moveTo(6, 0);
      c.lineTo(-4, -5);
      c.lineTo(-1.5, 0);
      c.lineTo(-4, 5);
      c.closePath();
      c.fill();
      c.stroke();
    }
    c.restore();
  }

  draw(f: MinimapFrame) {
    this.px = f.px;
    this.pz = f.pz;
    this.unlocked = f.unlocked;
    const c = this.ctx;
    const S = MINIMAP_SIZE;
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
    for (const p of f.npcs ?? []) {
      const sx = tx(p.x);
      const sz = tz(p.z);
      if (Math.hypot(sx - half, sz - half) > half - 3) continue;
      c.fillStyle = p.fresh ? '#f5dd8f' : '#c9a85a';
      c.strokeStyle = '#07060a';
      c.lineWidth = 1;
      c.beginPath();
      c.moveTo(sx, sz - 4.5);
      c.lineTo(sx + 3.5, sz);
      c.lineTo(sx, sz + 4.5);
      c.lineTo(sx - 3.5, sz);
      c.closePath();
      c.fill();
      c.stroke();
    }
    for (const k of f.corpses) dot(k.x, k.z, 1.2, 'rgba(216,207,189,0.35)');
    for (const e of f.enemies) dot(e.x, e.z, e.elite ? 3 : 1.8, e.elite ? '#c6a4ff' : '#c9b9a0');
    for (const t of f.thralls) dot(t.x, t.z, 2, '#6fe3c8');
    for (const a of f.allies) dot(a.x, a.z, 3, '#8f9ed1');
    if (f.boss) {
      dot(f.boss.x, f.boss.z, 5, '#7c3aed');
      dot(f.boss.x, f.boss.z, 2.5, '#f0e9dc');
    }

    if (f.destination) {
      // A small fixed world-space marker follows the map's moving centre, not the cursor.
      const x = tx(f.destination.x);
      const z = tz(f.destination.z);
      c.strokeStyle = '#e6cc91';
      c.lineWidth = 1.5;
      c.beginPath();
      c.arc(x, z, 4, 0, Math.PI * 2);
      c.moveTo(x - 6, z); c.lineTo(x + 6, z);
      c.moveTo(x, z - 6); c.lineTo(x, z + 6);
      c.stroke();
    }

    if (f.ping) this.drawPing(c, f.ping.x - f.px, f.ping.z - f.pz, half);

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
