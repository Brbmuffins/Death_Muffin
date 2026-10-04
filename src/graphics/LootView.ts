import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { itemMeta, RARITY_COLOR } from '../content/items';
import type { LootDrop } from '../gameplay/loot';
import type { Effects, Handle } from './Effects';
import { fx } from './fxTextures';
import { playFx } from './binbun/presets';
import { effectiveRarity } from '../gameplay/affixRules';
import { warmObjects } from './warmModel';

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
  /** Item that does not fit the bag: it stays where it lies (never drifts after the hero) until the bag changes (unpark). */
  parked?: boolean;
}

const coinGeo = new THREE.CylinderGeometry(0.09, 0.09, 0.025, 10);
const coinMat = new THREE.MeshStandardMaterial({ color: 0xc9a24a, metalness: 0.85, roughness: 0.35, emissive: 0x3a2808, emissiveIntensity: 0.4 });
/** A pile of n coins as one merged geometry (one draw call per pile, not one per coin), built once per size. */
const pileGeos = new Map<number, THREE.BufferGeometry>();
function pileGeometry(n: number) {
  let g = pileGeos.get(n);
  if (!g) {
    const m = new THREE.Matrix4();
    const coins: THREE.BufferGeometry[] = [];
    for (let i = 0; i < n; i++) {
      m.compose(
        new THREE.Vector3((Math.random() - 0.5) * 0.35, 0.02 + i * 0.02, (Math.random() - 0.5) * 0.35),
        new THREE.Quaternion().setFromEuler(new THREE.Euler((Math.random() - 0.5) * 0.4, Math.random() * 3, (Math.random() - 0.5) * 0.4)),
        new THREE.Vector3(1, 1, 1),
      );
      coins.push(coinGeo.clone().applyMatrix4(m));
    }
    g = mergeGeometries(coins)!;
    for (const c of coins) c.dispose();
    pileGeos.set(n, g);
  }
  return g;
}
const shardGeo = new THREE.OctahedronGeometry(0.18).scale(0.6, 1.4, 0.6);
const shardMat = new THREE.MeshStandardMaterial({ color: 0xb58cff, emissive: 0x7c3aed, emissiveIntensity: 2.2, roughness: 0.2, metalness: 0.1 });
/**
 * Ground clutter control (perf pass, 2026-10-03): drops never expired, so a long hunt left hundreds of sprites, light pillars, glow
 * decals and soul markers lying in the area. Anything left alone drifts to the hero and is collected (loot is never lost), and past
 * ITEM_CAP items on the ground the oldest are called in at once. An item that does not fit the bag is never called in: it is parked
 * where it lies (surplus ones lose their pillar and glow) until the bag changes. Calling it in anyway made a full bag's drops trail
 * the hero forever: they arrived, were refused, and were called in again.
 */
export const LOOT_VACUUM_S = { gold: 30, shard: 30, item: 75 } as const;
export const LOOT_ITEM_CAP = 60;

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
  /** One sprite material per icon, shared by every drop of that item (a new material per drop meant a new program lookup + upload each time). */
  private iconMat = new Map<string, THREE.SpriteMaterial>();
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
    const pile = new THREE.Mesh(pileGeometry(Math.min(9, 2 + Math.floor(amount / 4))), coinMat);
    pile.rotation.y = Math.random() * Math.PI * 2;
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

  private materialFor(url: string): THREE.SpriteMaterial {
    let mat = this.iconMat.get(url);
    if (!mat) {
      let tex = this.iconTex.get(url);
      if (!tex) {
        tex = this.loader.load(url);
        tex.colorSpace = THREE.SRGBColorSpace;
        this.iconTex.set(url, tex);
      }
      mat = new THREE.SpriteMaterial({ map: tex, transparent: true, depthWrite: false });
      this.iconMat.set(url, mat);
    }
    return mat;
  }

  /**
   * Cold-path warm (idle, at area entry): loads and uploads the icons this area can drop, and compiles the programs the
   * first drop would otherwise build mid-fight (sprite, rarity beam, coin pile, shard). Returns the tasks to run one per idle turn.
   */
  warmTasks(itemIds: string[]): (() => Promise<unknown>)[] {
    const tasks: (() => Promise<unknown>)[] = [];
    const kit = new THREE.Group();
    const sample = this.materialFor('art/items/bone_meal.webp');
    kit.add(new THREE.Sprite(sample));
    kit.add(new THREE.Mesh(beamGeo, new THREE.MeshBasicMaterial({ map: fx.glow(), transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide })));
    kit.add(new THREE.Mesh(pileGeometry(4), coinMat));
    kit.add(new THREE.Mesh(shardGeo, shardMat));
    tasks.push(() => warmObjects([kit], [fx.glow()]));
    for (const id of itemIds) {
      const url = itemMeta(id).icon ?? `art/items/${id}.webp`;
      if (this.iconMat.has(url)) continue;
      tasks.push(async () => {
        const tex = this.materialFor(url).map!;
        // Upload only once the image has decoded; before that a texture would upload empty and re-upload at first draw.
        for (let i = 0; i < 60 && !(tex.image as HTMLImageElement | undefined)?.complete; i++) await new Promise((r) => setTimeout(r, 50));
        await warmObjects([], [tex]);
      });
    }
    return tasks;
  }

  /** QA: where every drop lies, so a script can walk the hero over it and use the real pickup path. */
  debugDrops() {
    return this.drops.map((d) => ({ kind: d.kind, id: d.item?.item_id ?? null, x: d.x, z: d.z }));
  }

  /** Set by the scene: a rarity-keyed clatter when a gear piece lands (kept out of here so the view stays free of the audio engine). */
  dropSound: ((id: 'lootDrop' | 'lootDropRare' | 'lootDropEpic' | 'lootDropLegendary', x: number, z: number) => void) | null = null;

  item(x: number, z: number, drop: LootDrop) {
    const [px, pz] = this.scatter(x, z, 0.7);
    const meta = itemMeta(drop.item_id);
    // A rolled piece glows in the colour of its affix count (green, blue, purple), so a three-affix drop reads from across the room.
    const rarity = (drop.instance ? effectiveRarity(meta.rarity, drop.instance.affixes.length) : meta.rarity) as typeof meta.rarity;
    const color = new THREE.Color(RARITY_COLOR[rarity]);
    this.dropSound?.(rarity === 'legendary' ? 'lootDropLegendary' : rarity === 'epic' ? 'lootDropEpic' : rarity === 'rare' ? 'lootDropRare' : 'lootDrop', px, pz);
    const url = meta.icon ?? `art/items/${drop.item_id}.webp`;
    const icon = new THREE.Sprite(this.materialFor(url));
    icon.scale.setScalar(0.62);
    icon.position.set(px, 0.7, pz);
    const beam =
      rarity === 'common'
        ? undefined
        : new THREE.Mesh(
            beamGeo,
            new THREE.MeshBasicMaterial({ map: fx.glow(), color, transparent: true, opacity: rarity === 'legendary' ? 0.5 : 0.35, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide }),
          );
    beam?.position.set(px, 0, pz);
    this.group.add(icon);
    if (beam) this.group.add(beam);
    const glow = this.effects.decal({ tex: fx.glow(), color, x: px, z: pz, r: 0.9, duration: 1e9, opacity: 0.7 });
    // Rarity marker from the Binbun loot pack, in the game's rarity colour (the light pillar and glow stay).
    const marker = rarity === 'common' || rarity === 'uncommon' ? undefined : playFx(this.effects.binbun, rarity === 'legendary' ? 'loot_epic' : `loot_${rarity}`, { x: px, z: pz, colors: [RARITY_COLOR[rarity], RARITY_COLOR[rarity], '#1a1620'], scale: rarity === 'legendary' ? 0.8 : 0.55, alpha: 0.85 });
    this.drops.push({ kind: 'item', obj: icon, x: px, z: pz, amount: drop.quantity, item: drop, t: 0, flying: false, beam, glow, marker });
  }

  /**
   * Advance drops; returns what the player collected this frame.
   * `tryTakeItem` returns false when the bag is full (the item stays).
   */
  update(dt: number, px: number, pz: number, tryTakeItem: (d: LootDrop) => boolean, canFit: (d: LootDrop) => boolean = () => true) {
    // Called in only if the bag can take it; otherwise parked where it lies (checked once, not per frame).
    const tryCallIn = (d: Drop, surplus: boolean) => {
      if (!d.parked && canFit(d.item!)) return this.callIn(d);
      d.parked = true;
      if (surplus) this.bare(d);
    };
    let gold = 0;
    let shards = 0;
    const items: LootDrop[] = [];
    // Oldest item drops first (the array is in drop order): when too many lie around, the surplus is called in now.
    let surplus = -LOOT_ITEM_CAP;
    for (const d of this.drops) if (d.kind === 'item') surplus++;
    for (let i = 0; i < this.drops.length; i++) {
      const d = this.drops[i];
      if (surplus > 0 && d.kind === 'item') {
        surplus--;
        if (!d.flying && d.t > 0.35) tryCallIn(d, true);
      }
    }
    for (let i = this.drops.length - 1; i >= 0; i--) {
      const d = this.drops[i];
      d.t += dt;
      const dist = Math.hypot(px - d.x, pz - d.z);
      if (d.kind === 'item') {
        if (!d.flying) {
          d.obj.position.y = 0.7 + Math.sin(d.t * 2.5) * 0.08;
          if (d.beam) (d.beam.material as THREE.MeshBasicMaterial).opacity = 0.28 + Math.sin(d.t * 3) * 0.06;
          if (dist < 1.3 && d.t > 0.35) {
            if (tryTakeItem(d.item!)) {
              items.push(d.item!);
              this.remove(i);
            }
            continue;
          }
          if (d.t > LOOT_VACUUM_S.item && !d.parked) tryCallIn(d, false);
          if (!d.flying) continue;
        }
        // Called in: drifts to the hero; if the bag filled up meanwhile it is parked where it is.
        const k = Math.min(1, dt * (6 + d.t * 0.2));
        d.x += (px - d.x) * k;
        d.z += (pz - d.z) * k;
        d.obj.position.set(d.x, d.obj.position.y + (1 - d.obj.position.y) * k, d.z);
        if (dist < 0.6) {
          if (tryTakeItem(d.item!)) {
            items.push(d.item!);
            this.remove(i);
          } else {
            d.flying = false;
            d.t = 0;
            d.parked = true;
          }
        }
        continue;
      }
      if (d.kind === 'shard') {
        d.obj.rotation.y += dt * 2;
        if (!d.flying) d.obj.position.y = 0.5 + Math.sin(d.t * 3) * 0.1;
      }
      if (!d.flying && ((dist < 3.8 && d.t > 0.45) || d.t > LOOT_VACUUM_S[d.kind])) d.flying = true;
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

  /** The bag changed (sold, stored, used something): parked items may fit now and get called in again when due. */
  unpark() {
    for (const d of this.drops) d.parked = false;
  }

  /** Start an item drifting to the hero: its pillar, glow and marker go now (they cost a draw each and mean "lying here"). */
  private callIn(d: Drop) {
    d.flying = true;
    d.t = Math.max(d.t, 1);
    this.bare(d);
  }

  private bare(d: Drop) {
    d.glow?.kill();
    d.marker?.kill();
    d.glow = d.marker = undefined;
    if (d.beam) {
      this.group.remove(d.beam);
      (d.beam.material as THREE.Material).dispose();
      d.beam = undefined;
    }
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
    this.drops.splice(i, 1);
  }

  get count() {
    return this.drops.length;
  }

  dispose() {
    this.group.removeFromParent();
    this.iconMat.forEach((m) => m.dispose());
    this.iconTex.forEach((t) => t.dispose());
  }
}
