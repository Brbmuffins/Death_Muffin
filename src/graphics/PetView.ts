import * as THREE from 'three';
import type { PetDef } from '../../server/rules/content/cosmetics';
import { Creature } from './Creature';

/**
 * A companion that trails its owner: it keeps a spot behind and to the left, walks (or flies) to catch up, idles when they stop, and
 * snaps to them if it ever falls far behind (a teleport, a class change). Pure looks: it takes no hits and blocks nothing. The model is
 * one of the existing creatures drawn small (and tinted); flyers hover and flap with the shared wing shader.
 */
export class PetView {
  readonly c: Creature;
  private x: number;
  private z: number;
  private facing = 0;
  private t = Math.random() * 10;
  private moving = false;

  constructor(scene: THREE.Scene, private def: PetDef, x: number, z: number) {
    this.c = new Creature(def.model, { scale: def.scale, tint: def.tint, wings: def.fly ? { speed: def.fly.speed, amp: def.fly.amp, body: def.fly.body } : undefined });
    this.c.setCastShadow(false);
    scene.add(this.c.root);
    this.x = x + 1;
    this.z = z + 1;
    this.c.root.position.set(this.x, 0, this.z);
  }

  get id() {
    return this.def.id;
  }

  update(dt: number, ox: number, oz: number, ownerFacing: number) {
    this.t += dt;
    const fly = !!this.def.fly;
    // Home is behind and to the left of the owner (gameplay headings are atan2(dx, dz)).
    const a = ownerFacing + Math.PI + 0.7;
    const r = fly ? 1.1 : 1.35;
    const tx = ox + Math.sin(a) * r;
    const tz = oz + Math.cos(a) * r;
    let dx = tx - this.x;
    let dz = tz - this.z;
    const dist = Math.hypot(dx, dz);
    if (dist > 16) {
      this.x = tx;
      this.z = tz;
      dx = dz = 0;
    } else if (dist > 0.25) {
      const speed = Math.min(dist * 3.2, fly ? 6 : 5.5);
      const step = Math.min(dist, speed * dt);
      this.x += (dx / dist) * step;
      this.z += (dz / dist) * step;
    }
    const wants = dist > 0.45;
    if (wants !== this.moving) {
      this.moving = wants;
      // Models without an idle clip (the rat, the pup) slow their walk to a crawl instead of striding on the spot.
      if (wants) this.c.setLoop('walk', fly ? 1 : 1.4);
      else this.c.setLoop('idle', this.c.has('idle') ? 1 : 0.12);
    }
    if (wants) {
      let d = Math.atan2(dx, dz) - this.facing;
      while (d > Math.PI) d -= Math.PI * 2;
      while (d < -Math.PI) d += Math.PI * 2;
      this.facing += d * Math.min(1, dt * 10);
    } else {
      let d = ownerFacing - this.facing;
      while (d > Math.PI) d -= Math.PI * 2;
      while (d < -Math.PI) d += Math.PI * 2;
      this.facing += d * Math.min(1, dt * 3);
    }
    const y = fly ? this.def.fly!.height + Math.sin(this.t * 3.1) * 0.14 : 0;
    this.c.root.position.set(this.x, y, this.z);
    this.c.root.rotation.y = this.facing;
    this.c.update(dt);
  }

  dispose() {
    this.c.dispose();
  }
}
