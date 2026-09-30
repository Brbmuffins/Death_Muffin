import * as THREE from 'three';
import type { BossState } from '../gameplay/sim/types';
import { assets } from './AssetCache';
import { Creature } from './Creature';
import { PROP_URL, type CreatureSlug } from './modelPaths';
import type { GatherSkill } from '../gameplay/gatheringRules';
import type { Effects } from './Effects';
import { fx } from './fxTextures';
import type { EquipSlot } from '../content/gear';
import { buildCape, buildHelm, buildOffhand, buildWeapon, disposeProp } from './gearProps';
import { capeDef } from '../content/cosmetics';
import { gearTier } from '../content/gear';
import type { GearRegion } from './gearTint';

/** How much a held staff follows the wrist (0 = pinned upright, 1 = fully hand-driven). */
const STAFF_FOLLOW = 0.15;

/** Coffin-oak staff with a skull finial and a violet soul-light. */
function skullStaff(accent: THREE.ColorRepresentation) {
  const g = new THREE.Group();
  const wood = new THREE.MeshStandardMaterial({ color: 0x2b211c, roughness: 0.85 });
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.035, 1.9, 6), wood);
  shaft.position.y = 0.35;
  const bone = new THREE.MeshStandardMaterial({ color: 0xd8cfbd, roughness: 0.7 });
  const skull = new THREE.Mesh(new THREE.SphereGeometry(0.1, 10, 8), bone);
  skull.scale.set(1, 1.1, 1.15);
  skull.position.y = 1.35;
  const cage = new THREE.Mesh(new THREE.TorusGeometry(0.16, 0.012, 5, 16), new THREE.MeshStandardMaterial({ color: 0x5a4a3a, metalness: 0.6, roughness: 0.4 }));
  cage.position.y = 1.36;
  const glow = new THREE.Sprite(
    new THREE.SpriteMaterial({ map: fx.glow(), color: accent, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true }),
  );
  glow.scale.setScalar(0.55);
  glow.position.y = 1.36;
  g.add(shaft, skull, cage, glow);
  g.userData.tip = glow;
  return g;
}

/**
 * The necromancer hero (local or remote). One generated model for every
 * discipline; the discipline colours the staff light and robe glow.
 */
export class NecromancerAvatar {
  readonly c: Creature;
  readonly lantern: THREE.PointLight | null;
  /** The necromancer's staff. Null for families that carry real weapon props. */
  private staff: THREE.Group | null;
  private classGear: THREE.Object3D[] = [];
  /** Which hand each default prop (the staff, class weapons) fills, so an equipped item can replace it. */
  private defaultHand = new Map<THREE.Object3D, 'main_hand' | 'off_hand'>();
  /** Equipped-gear props currently on the model, with the item id each was built from. */
  private worn = new Map<'main_hand' | 'off_hand' | 'head', { obj: THREE.Object3D; key: string }>();
  /** The mastery cape on the back (a cosmetic: content/cosmetics.ts), and how far it has swung. */
  private cape: { obj: THREE.Object3D; id: string } | null = null;
  private swayT = Math.random() * 6;
  private gatheringSkill: GatherSkill | null = null;
  private gatheringTools = new Map<GatherSkill, THREE.Object3D>();
  private loadingTools = new Set<GatherSkill>();
  private disposed = false;
  /** Spell origin when there is no staff (the Knight's sword). */
  private tipObj: THREE.Object3D | null = null;
  private moving = false;
  castLock = 0;

  constructor(scene: THREE.Scene, accent: string, withLight: boolean, slug: CreatureSlug = 'necromancer') {
    // Generated heroes face +X; gameplay headings use +Z.
    this.c = new Creature(slug, { inPlace: true, gearTint: true, modelYaw: -Math.PI / 2, emissive: accent, emissiveIntensity: 0.04, fallback: 'necromancer' });
    if (slug === 'hero_hollow_knight' || slug === 'hero_grave_warden' || slug === 'hero_bell_monk' || slug === 'hero_carrion_witch' || slug === 'hero_veilwalker') {
      // New Blood heroes use their authored gear or bare hands.
      this.staff = null;
      this.attachClassGear(slug);
    } else {
      this.staff = skullStaff(accent);
      // Held upright: the grip sits in the hand, calibrated against the idle pose.
      this.c.attach('R_Hand', this.staff, new THREE.Vector3(0, 1, 0.12), STAFF_FOLLOW);
      this.defaultHand.set(this.staff, 'main_hand');
    }
    scene.add(this.c.root);
    this.lantern = withLight ? new THREE.PointLight(accent, 18, 10, 1.4) : null;
    if (this.lantern) {
      this.lantern.position.set(0, 3.2, 0.6);
      this.c.root.add(this.lantern);
    }
  }

  /**
   * Hollow Knight: sword in the right hand, shield on the left. The heroes are
   * authored T-posed with empty hands, so each prop is attached to its bone with
   * an aim direction and Creature.attach calibrates the grip against the idle
   * pose (the same path as the necromancer staff). Heights are world units.
   */
  private attachClassGear(slug: CreatureSlug) {
    if (slug === 'hero_veilwalker') {
      for (const bone of ['R_Hand', 'L_Hand']) {
        const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: fx.glow(), color: 0x85efff,
          blending: THREE.AdditiveBlending, transparent: true, depthWrite: false, opacity: 0.72 }));
        glow.scale.setScalar(0.28);
        this.c.attach(bone, glow);
        this.classGear.push(glow);
        this.defaultHand.set(glow, bone === 'R_Hand' ? 'main_hand' : 'off_hand');
        if (bone === 'R_Hand') this.tipObj = glow;
      }
      return;
    }
    const grip = (bone: string, id: string, height: number, tip = false, follow?: number) =>
      ({ bone, id, height, dir: new THREE.Vector3(0, 1, 0.1), tip, follow });
    const gear = slug === 'hero_hollow_knight'
      ? [grip('R_Hand', 'gear_knight_sword', 1.05, true, 0.6), grip('L_Hand', 'gear_knight_shield', 0.62, false, 0.5)]
      : slug === 'hero_grave_warden'
        ? [grip('R_Hand', 'gear_warden_flail', 1.1, true, 0.6), grip('L_Hand', 'gear_warden_lantern', 0.7, false, 0.5)]
        : slug === 'hero_bell_monk' ? [grip('R_Hand', 'gear_monk_bell_staff', 1.65, true, STAFF_FOLLOW)]
          : slug === 'hero_carrion_witch' ? [grip('R_Hand', 'gear_witch_hook', 0.9, true, 0.6)] : [];
    for (const g of gear) {
      void assets.model(PROP_URL(g.id), g.height).then((t) => {
        if (!t || this.disposed) return;
        const obj = t.scene.clone(true);
        obj.scale.setScalar(t.scale);
        this.c.attach(g.bone, obj, g.dir, g.follow);
        this.classGear.push(obj);
        this.defaultHand.set(obj, g.bone === 'R_Hand' ? 'main_hand' : 'off_hand');
        if (g.tip) this.tipObj = obj;
        this.applyGearVisibility();
      });
    }
  }

  /** Show the matching hand tool while gathering, then restore class gear. */
  setGatheringTool(skill: GatherSkill | null) {
    if (this.gatheringSkill === skill || this.disposed) return;
    this.gatheringSkill = skill;
    this.applyGearVisibility();
    for (const [id, obj] of this.gatheringTools) obj.visible = id === skill;
    if (!skill || this.gatheringTools.has(skill) || this.loadingTools.has(skill)) return;

    const tool = {
      woodcutting: { id: 'tool_hatchet', length: 0.95 },
      mining: { id: 'tool_pickaxe', length: 1.2 },
      fishing: { id: 'tool_fishing_rod', length: 1.45 },
      gravedigging: { id: 'tool_spade', length: 1.2 },
    }[skill];
    this.loadingTools.add(skill);
    void assets.model(PROP_URL(tool.id), tool.length).then((template) => {
      if (!template || this.disposed) return;
      const obj = template.scene.clone(true);
      // Several tools are authored sideways; their Y height can be tiny.
      // Normalize by the longest axis so a spade never becomes giant in-hand.
      const size = new THREE.Box3().setFromObject(template.scene).getSize(new THREE.Vector3());
      obj.scale.setScalar(tool.length / Math.max(0.001, size.x, size.y, size.z));
      obj.visible = this.gatheringSkill === skill;
      this.c.attach('R_Hand', obj, new THREE.Vector3(0, 1, 0.1));
      this.gatheringTools.set(skill, obj);
    }).finally(() => this.loadingTools.delete(skill));
  }

  /** Default props show unless a gathering tool is out or an equipped item took their hand; worn gear hides while gathering. */
  private applyGearVisibility() {
    const idle = this.gatheringSkill === null;
    const defaults = this.staff ? [this.staff, ...this.classGear] : this.classGear;
    for (const obj of defaults) {
      const hand = this.defaultHand.get(obj);
      obj.visible = idle && !(hand && this.worn.has(hand));
    }
    for (const w of this.worn.values()) w.obj.visible = idle;
    if (this.cape) this.cape.obj.visible = idle;
  }

  /**
   * Show equipped gear on the model: weapon in the right hand, off-hand piece in the left, helm on
   * the head. An equipped weapon or shield replaces the class's default prop for that hand. Only
   * changed slots are rebuilt, so this is cheap to call on every inventory change.
   */
  setEquipment(items: Partial<Record<EquipSlot, { item_id: string; rarity?: string } | undefined>>) {
    if (this.disposed) return;
    const want: [ 'main_hand' | 'off_hand' | 'head', string, { item_id: string; rarity?: string } | undefined][] = [
      ['main_hand', 'R_Hand', items.main_hand],
      ['off_hand', 'L_Hand', items.off_hand],
      ['head', 'Head', items.head],
    ];
    for (const [slot, bone, item] of want) {
      const cur = this.worn.get(slot);
      if (cur?.key === item?.item_id) continue;
      if (cur) {
        this.c.detach(cur.obj);
        disposeProp(cur.obj);
        this.worn.delete(slot);
      }
      if (!item) continue;
      const obj = slot === 'head' ? buildHelm(item.item_id, item.rarity) : slot === 'off_hand' ? buildOffhand(item.item_id, item.rarity) : buildWeapon(item.item_id, item.rarity);
      if (slot === 'head') this.c.attach(bone, obj, new THREE.Vector3(0, 1, 0));
      else this.c.attach(bone, obj, new THREE.Vector3(0, 1, 0.1), slot === 'main_hand' && obj.userData.tip ? STAFF_FOLLOW * 2 : 0.5);
      this.worn.set(slot, { obj, key: item.item_id });
    }
    // Body slots have no prop: they recolour their region of the body by material tier.
    const body: [GearRegion, EquipSlot][] = [['chest', 'chest'], ['legs', 'legs'], ['hands', 'hands'], ['feet', 'feet']];
    for (const [region, slot] of body) {
      const item = items[slot];
      if (!item) this.c.setRegionTint(region, null);
      else {
        const t = gearTier(item.item_id, item.rarity);
        this.c.setRegionTint(region, { color: t.color, glow: t.glow });
      }
    }
    this.applyGearVisibility();
  }

  /** Put a cape on (or take it off with null). Hidden while a gathering tool is out, like the rest of the worn gear. */
  setCape(id: string | null) {
    if (this.disposed || (this.cape?.id ?? null) === id) return;
    if (this.cape) {
      this.c.detach(this.cape.obj);
      disposeProp(this.cape.obj);
      this.cape = null;
    }
    const def = id ? capeDef(id) : undefined;
    if (!def) return;
    const obj = buildCape(def.color, def.trim);
    this.c.attach('Spine02', obj);
    this.cape = { obj, id: def.id };
    obj.visible = this.gatheringSkill === null;
  }

  /** World position of the staff tip (spell origin). */
  tip(out = new THREE.Vector3()): THREE.Vector3 {
    const tip = (this.worn.get('main_hand')?.obj.userData.tip as THREE.Object3D | undefined) ?? (this.staff?.userData.tip as THREE.Object3D | undefined) ?? this.tipObj;
    if (tip && this.c.loaded) return tip.getWorldPosition(out);
    return out.set(this.c.root.position.x, 1.6, this.c.root.position.z);
  }

  update(dt: number, x: number, z: number, facing: number, moving: boolean, speed: number) {
    this.c.root.position.set(x, 0, z);
    let d = facing - this.c.root.rotation.y;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    this.c.root.rotation.y += d * Math.min(1, dt * 14);
    if (moving !== this.moving) {
      this.moving = moving;
      this.c.setLoop(moving ? 'run' : 'idle', moving ? speed / 5.2 : 1);
      if (moving) this.c.releaseGesture();
    }
    this.castLock = Math.max(0, this.castLock - dt);
    this.c.update(dt);
    if (this.cape) {
      // The cloth trails a little behind a moving hero and breathes when still.
      this.swayT += dt * (moving ? 5 : 1.6);
      this.cape.obj.rotation.x = (moving ? 0.17 : 0.05) + Math.sin(this.swayT) * (moving ? 0.05 : 0.02);
    }
  }

  /**
   * Play a one-shot gesture. `attack` is the weapon swing every shipped hero rig
   * carries and the melee kits (Hollow Knight, Grave Warden) use; the necromancer
   * rites all gesture with `cast` or `dig`.
   */
  cast(kind: 'cast' | 'dig' | 'attack', speed = 2, facing?: number, durationSeconds?: number) {
    if (facing !== undefined) {
      this.c.root.rotation.y = facing;
      this.c.root.updateMatrixWorld(true);
    }
    this.c.playOnce(kind, speed, durationSeconds);
  }

  dispose() {
    this.disposed = true;
    for (const w of this.worn.values()) disposeProp(w.obj);
    this.worn.clear();
    if (this.cape) disposeProp(this.cape.obj);
    this.cape = null;
    this.c.dispose();
  }
}

/** Any boss's model (area bosses: one per BossId, created on first summon; the Prelate's is built at load). */
export class BossView {
  readonly c: Creature;
  private light: THREE.PointLight;
  private lastState = '';
  private visible = false;
  private rise = 0;
  private readonly saint: boolean;
  private readonly regent: boolean;
  private readonly mire: boolean;
  /** Mire Mother: 0 standing, 1 fully under the water. */
  private sunk = 0;

  constructor(scene: THREE.Scene, private effects: Effects, slug: CreatureSlug = 'prelate', private color = 0xa26bff) {
    this.saint = slug === 'boss_plague_saint';
    this.regent = slug === 'boss_cinder_regent';
    this.mire = slug === 'boss_mire_mother';
    this.c = new Creature(slug, { emissive: slug === 'prelate' ? 0x3b1d5e : 0x000000, emissiveIntensity: slug === 'prelate' ? 0.05 : 0, fallback: 'prelate' });
    this.c.root.visible = false;
    scene.add(this.c.root);
    this.light = new THREE.PointLight(color, 0, 14, 1.4);
    this.light.position.set(0, 2.6, 0.6);
    this.c.root.add(this.light);
  }

  sync(b: BossState, dt: number) {
    if (b.active && !this.visible) {
      this.visible = true;
      this.rise = 0;
      this.c.root.visible = true;
      this.c.setOpacity(1);
      this.c.root.rotation.z = 0;
    }
    if (!this.visible) return;
    this.rise = Math.min(1, this.rise + dt * 0.6);
    if (this.mire) {
      // She sinks into the marsh (hidden once under) and climbs back out with the same ease.
      this.sunk += ((b.active && b.state === 'sunk' ? 1 : 0) - this.sunk) * Math.min(1, dt * 4);
      this.c.root.visible = this.sunk < 0.97;
      if (b.active && Math.random() < dt * (this.sunk > 0.3 ? 14 : 4)) {
        this.effects.emit({ x: b.x + (Math.random() - 0.5) * 2.4, y: 0.2 + (1 - this.sunk) * Math.random() * 2, z: b.z + (Math.random() - 0.5) * 2.4, count: 1, color: Math.random() < 0.6 ? 0x5fc4b4 : 0x9fe8da, spread: 0.3, speed: 0.3, up: 0.8, life: 0.9, size: 0.16, drag: 0.5 });
      }
    }
    this.c.root.position.set(b.x, -4.6 * (1 - this.rise) * (1 - this.rise) - this.sunk * 4.4, b.z);
    let d = b.facing - this.c.root.rotation.y;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    this.c.root.rotation.y += d * Math.min(1, dt * 3);
    this.c.flash = b.active ? b.flash : 0;
    // The Regent's pale cape and molten plate white out under a close 16-24 light: a warm, low glow instead.
    const glow = this.regent || this.mire ? 4 + b.phase * 2 : 16 + b.phase * 8;
    this.light.intensity = b.active ? glow + Math.sin(performance.now() / 200) * (this.regent || this.mire ? 1 : 4) : Math.max(0, this.light.intensity - dt * 30);
    if (b.state !== this.lastState) {
      this.lastState = b.state;
      if (b.state === 'toll' || b.state === 'rain' || b.state === 'summon') this.c.playOnce('cast', 1.1);
      else if (b.state === 'slam') this.c.playOnce('attack', 1.3);
      else if (b.state === 'move') this.c.setLoop('walk', 0.9 + b.phase * 0.15);
      else if (b.state === 'dead') this.c.playOnce('death', 0.8);
      else this.c.setLoop('idle');
    }
    if (this.saint && b.active) {
      // Her clip set is small (idle/walk/attack/cast), so the blight itself is the tell: she swells and
      // sheds more rot each phase.
      const ph = b.phase;
      this.c.root.scale.setScalar(1 + Math.sin(performance.now() / 1000 * (1.6 + ph * 0.9)) * 0.012 * ph);
      if (Math.random() < dt * (2 + ph * 3)) {
        this.effects.emitSmoke({ x: b.x + (Math.random() - 0.5) * 2, y: 0.3, z: b.z + (Math.random() - 0.5) * 2, count: 1, color: 0x4a5a22, spread: 0.8, speed: 0.3, up: 0.5, life: 1.4, size: 1.2 });
      }
    }
    if (this.regent && b.active) {
      // The Regent burns hotter each phase: embers stream off the crown and pauldrons, soot rolls off the cape.
      const ph = b.phase;
      this.c.root.scale.setScalar(1 + Math.sin(performance.now() / 1000 * (1.4 + ph * 0.8)) * 0.01 * ph);
      if (Math.random() < dt * (10 + ph * 10)) {
        this.effects.emit({ x: b.x + (Math.random() - 0.5) * 1.6, y: 2 + Math.random() * 2.4, z: b.z + (Math.random() - 0.5) * 1.6, count: 1, color: Math.random() < 0.5 ? 0xff7a2a : 0xffc45a, spread: 0.5, speed: 0.4, up: 1.2 + ph * 0.3, life: 1.1, size: 0.14, drag: 0.4 });
      }
      if (Math.random() < dt * (2 + ph * 2)) this.effects.emitSmoke({ x: b.x + (Math.random() - 0.5) * 2, y: 1.2, z: b.z + (Math.random() - 0.5) * 2, count: 1, color: 0x2a1408, spread: 0.7, speed: 0.3, up: 0.7, life: 1.6, size: 1.3, shrink: -0.5 });
    }
    if (b.active && Math.random() < dt * (this.saint ? 8 + b.phase * 8 : 10)) {
      this.effects.emit({ x: b.x, y: 2.5, z: b.z, count: 1, color: this.color === 0xa26bff ? 0x9d6bff : this.color, spread: 1, speed: 0.4, up: 0.8, life: 1.2, size: 0.4 });
    }
    this.c.update(dt);
  }

  /** Fade out after death (or when the fight resets). */
  hide() {
    if (!this.visible) return;
    this.c.flash = 0;
    let t = 0;
    const tick = () => {
      t += 0.05;
      this.c.setOpacity(Math.max(0, 1 - t));
      if (t < 1) setTimeout(tick, 50);
      else {
        this.c.root.visible = false;
        this.visible = false;
      }
    };
    setTimeout(tick, 2500);
  }

  dispose() {
    this.c.dispose();
  }
}

/** The single-boss name, kept for older imports. */
export const PrelateView = BossView;
export type PrelateView = BossView;
