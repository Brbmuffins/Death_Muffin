import * as THREE from 'three';
import { itemMeta, RARITY_COLOR } from '../content/items';
import type { LootDrop } from '../gameplay/loot';
import type { Effects, Handle } from './Effects';
import { fx } from './fxTextures';
import { playFx } from './binbun/presets';

type Kind = 'gold' | 'shard' | 'item';

interface Drop {
  kind: Kind;
  obj: THREE.Object3D;
  x: number;
  z: number;
  amount: number;
  item?: LootDrop;
  t: number;
  flying: boolean;
  beam?: THREE.Mesh;
  glow?: Handle;
  /** Binbun ground marker (items) or soul glow (shards). */
  marker?: Handle;
}

const coinGeo = new THREE.CylinderGeometry(0.09, 0.09, 0.025, 10);
const coinMat = new THREE.MeshStandardMaterial({ color: 0xc9a24a, metalness: 0.85, roughness: 0.35, emissive: 0x3a2808, emissiveIntensity: 0.4 });
const shardGeo = new THREE.OctahedronGeometry(0.18).scale(0.6, 1.4, 0.6);
const shardMat = new THREE.MeshStandardMaterial({ color: 0xb58cff, emissive: 0x7c3aed, emissiveIntensity: 2.2, roughness: 0.2, metalness: 0.1 });
const beamGeo = new THREE.CylinderGeometry(0.22, 0.34, 6, 10, 1, true).translate(0, 3, 0);

/**
 * Personal loot on the ground (every party member sees only their own rolls).
 * Gold and shards are magnetised to the player; items wait under a light
 * pillar coloured by rarity until walked over.
 */
export class LootView {
  readonly group = new THREE.Group();
  private drops: Drop[] = [];
  private iconTex = new Map<string, THREE.Texture>();
  private loader = new THREE.TextureLoader();

  constructor(
    scene: THREE.Scene,
    private effects: Effects,
  ) {
    scene.add(this.group);
  }

  private scatter(x: number, z: number, r = 0.9): [number, number] {
    const a = Math.random() * Math.PI * 2;
    const d = 0.3 + Math.random() * r;
    return [x + Math.cos(a) * d, z + Math.sin(a) * d];
  }

  gold(x: number, z: number, amount: number) {
    if (amount <= 0) return;
    const [px, pz] = this.scatter(x, z);
    const pile = new THREE.Group();
    const n = Math.min(9, 2 + Math.floor(amount / 4));
    for (let i = 0; i < n; i++) {
      const c = new THREE.Mesh(coinGeo, coinMat);
      c.position.set((Math.random() - 0.5) * 0.35, 0.02 + i * 0.02, (Math.random() - 0.5) * 0.35);
      c.rotation.set((Math.random() - 0.5) * 0.4, Math.random() * 3, (Math.random() - 0.5) * 0.4);
      pile.add(c);
    }
    pile.position.set(px, 0, pz);
    this.group.add(pile);
    this.drops.push({ kind: 'gold', obj: pile, x: px, z: pz, amount, t: 0, flying: false });
  }

  shard(x: number, z: number, amount: number) {
    for (let i = 0; i < amount; i++) {
      const [px, pz] = this.scatter(x, z, 0.6);
      const m = new THREE.Mesh(shardGeo, shardMat);
      m.position.set(px, 0.5, pz);
      this.group.add(m);
      const marker = playFx(this.effects.binbun, 'soul_orb', { x: px, z: pz, colors: [0xb58cff, 0x7c3aed, 0x160a24], follow: () => (m.parent ? { x: m.position.x, y: m.position.y, z: m.position.z } : null) });
      this.drops.push({ kind: 'shard', obj: m, x: px, z: pz, amount: 1, t: 0, flying: false, marker });
    }
    this.effects.lightFlash(x, 1.2, z, 0xa26bff, 20, 0.6);
  }

  item(x: number, z: number, drop: LootDrop) {
    const [px, pz] = this.scatter(x, z, 0.7);
    const meta = itemMeta(drop.item_id);
    const color = new THREE.Color(RARITY_COLOR[meta.rarity]);
    const url = meta.icon ?? `art/items/${drop.item_id}.png`;
    let tex = this.iconTex.get(url);
    if (!tex) {
      tex = this.loader.load(url);
      tex.colorSpace = THREE.SRGBColorSpace;
      this.iconTex.set(url, tex);
    }
    const icon = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, transparent: true, depthWrite: false }));
    icon.scale.setScalar(0.62);
    icon.position.set(px, 0.7, pz);
    const beam =
      meta.rarity === 'common'
        ? undefined
        : new THREE.Mesh(
            beamGeo,
            new THREE.MeshBasicMaterial({ map: fx.glow(), color, transparent: true, opacity: 0.35, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide }),
          );
    beam?.position.set(px, 0, pz);
    this.group.add(icon);
    if (beam) this.group.add(beam);
    const glow = this.effects.decal({ tex: fx.glow(), color, x: px, z: pz, r: 0.9, duration: 1e9, opacity: 0.7 });
    // Rarity marker from the Binbun loot pack, in the game's rarity colour (the light pillar and glow stay).
    const marker = meta.rarity === 'common' || meta.rarity === 'uncommon' ? undefined : playFx(this.effects.binbun, `loot_${meta.rarity}`, { x: px, z: pz, colors: [RARITY_COLOR[meta.rarity], RARITY_COLOR[meta.rarity], '#1a1620'], scale: 0.55, alpha: 0.85 });
    this.drops.push({ kind: 'item', obj: icon, x: px, z: pz, amount: drop.quantity, item: drop, t: 0, flying: false, beam, glow, marker });
  }

  /**
   * Advance drops; returns what the player collected this frame.
   * `tryTakeItem` returns false when the bag is full (the item stays).
   */
  update(dt: number, px: number, pz: number, tryTakeItem: (d: LootDrop) => boolean) {
    let gold = 0;
    let shards = 0;
    const items: LootDrop[] = [];
    for (let i = this.drops.length - 1; i >= 0; i--) {
      const d = this.drops[i];
      d.t += dt;
      const dist = Math.hypot(px - d.x, pz - d.z);
      if (d.kind === 'item') {
        d.obj.position.y = 0.7 + Math.sin(d.t * 2.5) * 0.08;
        if (d.beam) (d.beam.material as THREE.MeshBasicMaterial).opacity = 0.28 + Math.sin(d.t * 3) * 0.06;
        if (dist < 1.3 && d.t > 0.35) {
          if (tryTakeItem(d.item!)) {
            items.push(d.item!);
            this.remove(i);
          }
        }
        continue;
      }
      if (d.kind === 'shard') {
        d.obj.rotation.y += dt * 2;
        if (!d.flying) d.obj.position.y = 0.5 + Math.sin(d.t * 3) * 0.1;
      }
      if (!d.flying && dist < 3.8 && d.t > 0.45) d.flying = true;
      if (d.flying) {
        const k = Math.min(1, dt * (8 + d.t * 4));
        d.x += (px - d.x) * k;
        d.z += (pz - d.z) * k;
        d.obj.position.x = d.x;
        d.obj.position.z = d.z;
        d.obj.position.y += (1 - d.obj.position.y) * k;
        if (dist < 0.5) {
          if (d.kind === 'gold') gold += d.amount;
          else shards += d.amount;
          this.effects.emit({ x: px, y: 1, z: pz, count: 4, color: d.kind === 'gold' ? 0xe2c98f : 0xb58cff, spread: 0.2, speed: 1.2, up: 1, life: 0.4, size: 0.2 });
          this.remove(i);
        }
      }
    }
    return { gold, shards, items };
  }

  private remove(i: number) {
    const d = this.drops[i];
    d.glow?.kill();
    d.marker?.kill();
    this.group.remove(d.obj);
    if (d.beam) {
      this.group.remove(d.beam);
      (d.beam.material as THREE.Material).dispose();
    }
    if (d.kind === 'item') ((d.obj as THREE.Sprite).material as THREE.Material).dispose();
    this.drops.splice(i, 1);
  }

  get count() {
    return this.drops.length;
  }

  dispose() {
    this.group.removeFromParent();
    this.iconTex.forEach((t) => t.dispose());
  }
}
