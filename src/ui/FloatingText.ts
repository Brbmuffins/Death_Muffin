import * as THREE from 'three';
import { settings } from '../app/settings';

export type NumKind = 'hit' | 'crit' | 'dot' | 'thrall' | 'hurt' | 'gold' | 'shard' | 'xp' | 'info' | 'big' | 'spear' | 'skill' | 'heal' | 'ward';

interface Entry {
  el: HTMLDivElement;
  pos: THREE.Vector3;
  t: number;
  life: number;
  drift: number;
  /** Extra screen-y lift so call-outs spawned on the same spot stack instead of overprinting. */
  lift: number;
  group: boolean;
  wx: number;
  wz: number;
}

const MAX = 56;

/** Pooled DOM combat text projected from world space every frame. */
export class FloatingText {
  private pool: HTMLDivElement[] = [];
  private live: Entry[] = [];
  private v = new THREE.Vector3();

  constructor(private root: HTMLElement) {}

  /** `color` tints `skill` numbers with the skill's colour (gatheringRules SKILLS). */
  spawn(x: number, y: number, z: number, text: string, kind: NumKind, color?: string) {
    if (!settings.damageNumbers && (kind === 'hit' || kind === 'dot' || kind === 'thrall' || kind === 'spear')) return;
    if (this.live.length >= MAX) {
      const old = this.live.shift()!;
      old.el.remove();
      this.pool.push(old.el);
    }
    const el = this.pool.pop() ?? document.createElement('div');
    el.className = `cw-num ${kind === 'spear' ? 'hit' : kind}`;
    el.textContent = text;
    el.style.color = color ?? '';
    this.root.appendChild(el);
    // Call-outs (heals, chain tiers, gold, notices) that land on the same spot within a moment stack upwards
    // instead of printing over each other; hit numbers keep their scatter.
    const group = kind !== 'hit' && kind !== 'crit' && kind !== 'dot' && kind !== 'thrall' && kind !== 'hurt' && kind !== 'spear' && kind !== 'xp';
    const stacked = group ? this.live.filter((o) => o.group && o.t < 0.9 && Math.abs(o.wx - x) < 1 && Math.abs(o.wz - z) < 1).length : 0;
    this.live.push({
      el,
      pos: new THREE.Vector3(x + (Math.random() - 0.5) * 0.5, y, z + (Math.random() - 0.5) * 0.3),
      lift: stacked * 26,
      group,
      wx: x,
      wz: z,
      t: 0,
      life: kind === 'big' || kind === 'info' || kind === 'heal' || kind === 'ward' ? 1.6 : kind === 'crit' ? 1.1 : 0.85,
      drift: (Math.random() - 0.5) * 30,
    });
  }

  update(dt: number, camera: THREE.Camera) {
    const w = window.innerWidth;
    const h = window.innerHeight;
    for (let i = this.live.length - 1; i >= 0; i--) {
      const e = this.live[i];
      e.t += dt;
      if (e.t >= e.life) {
        e.el.remove();
        this.pool.push(e.el);
        this.live.splice(i, 1);
        continue;
      }
      this.v.copy(e.pos).project(camera);
      const k = e.t / e.life;
      const sx = ((this.v.x + 1) / 2) * w + e.drift * k;
      const sy = ((1 - this.v.y) / 2) * h - 34 - k * 46 - e.lift;
      const pop = k < 0.12 ? 0.7 + (k / 0.12) * 0.5 : 1.2 - Math.min(0.2, (k - 0.12) * 0.6);
      e.el.style.transform = `translate3d(${sx.toFixed(1)}px, ${sy.toFixed(1)}px, 0) translate(-50%, -50%) scale(${pop.toFixed(3)})`;
      e.el.style.opacity = k > 0.65 ? String(1 - (k - 0.65) / 0.35) : '1';
    }
  }

  clear() {
    for (const e of this.live) e.el.remove();
    this.live = [];
  }
}
