import * as THREE from 'three';
import type { BossState } from '../gameplay/sim/types';
import { assets } from './AssetCache';
import { Creature } from './Creature';
import { PROP_URL, type CreatureSlug } from './modelPaths';
import type { Effects } from './Effects';
import { fx } from './fxTextures';

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
  /** Spell origin when there is no staff (the Knight's sword). */
  private tipObj: THREE.Object3D | null = null;
  private moving = false;
  castLock = 0;

  constructor(scene: THREE.Scene, accent: string, withLight: boolean, slug: CreatureSlug = 'necromancer') {
    // Generated heroes face +X; gameplay headings use +Z.
    this.c = new Creature(slug, { inPlace: true, modelYaw: -Math.PI / 2, emissive: accent, emissiveIntensity: 0.04, fallback: 'necromancer' });
    if (slug === 'hero_hollow_knight') {
      // The Knight carries authored props, not a code-built staff.
      this.staff = null;
      this.attachKnightGear();
    } else {
      this.staff = skullStaff(accent);
      // Held upright: the grip sits in the hand, calibrated against the idle pose.
      this.c.attach('R_Hand', this.staff, new THREE.Vector3(0, 1, 0.12));
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
  private attachKnightGear() {
    const gear: { bone: string; id: string; height: number; dir: THREE.Vector3; tip?: boolean }[] = [
      { bone: 'R_Hand', id: 'gear_knight_sword', height: 1.05, dir: new THREE.Vector3(0, 1, 0.1), tip: true },
      { bone: 'L_Hand', id: 'gear_knight_shield', height: 0.62, dir: new THREE.Vector3(0, 0, 1) },
    ];
    for (const g of gear) {
      void assets.model(PROP_URL(g.id), g.height).then((t) => {
        if (!t) return;
        const obj = t.scene.clone(true);
        obj.scale.setScalar(t.scale);
        this.c.attach(g.bone, obj, g.dir);
        if (g.tip) this.tipObj = obj;
      });
    }
  }

  /** World position of the staff tip (spell origin). */
  tip(out = new THREE.Vector3()): THREE.Vector3 {
    const tip = (this.staff?.userData.tip as THREE.Object3D | undefined) ?? this.tipObj;
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
  }

  /**
   * Play a one-shot gesture. `attack` is the weapon swing every shipped hero rig
   * carries but only the Hollow Knight's kit uses; the necromancer rites all
   * gesture with `cast` or `dig`.
   */
  cast(kind: 'cast' | 'dig' | 'attack', speed = 2, facing?: number, durationSeconds?: number) {
    if (facing !== undefined) {
      this.c.root.rotation.y = facing;
      this.c.root.updateMatrixWorld(true);
    }
    this.c.playOnce(kind, speed, durationSeconds);
  }

  dispose() {
    this.c.dispose();
  }
}

/** The Bell-Sworn Prelate's body and its bell-light. */
export class PrelateView {
  readonly c: Creature;
  private light: THREE.PointLight;
  private lastState = '';
  private visible = false;
  private rise = 0;

  constructor(scene: THREE.Scene, private effects: Effects) {
    this.c = new Creature('prelate', { emissive: 0x3b1d5e, emissiveIntensity: 0.05 });
    this.c.root.visible = false;
    scene.add(this.c.root);
    this.light = new THREE.PointLight(0xa26bff, 0, 14, 1.4);
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
    this.c.root.position.set(b.x, -4.6 * (1 - this.rise) * (1 - this.rise), b.z);
    let d = b.facing - this.c.root.rotation.y;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    this.c.root.rotation.y += d * Math.min(1, dt * 3);
    this.c.flash = b.flash;
    this.light.intensity = b.active ? 16 + b.phase * 8 + Math.sin(performance.now() / 200) * 4 : Math.max(0, this.light.intensity - dt * 30);
    if (b.state !== this.lastState) {
      this.lastState = b.state;
      if (b.state === 'toll' || b.state === 'rain') this.c.playOnce('cast', 1.1);
      else if (b.state === 'slam') this.c.playOnce('attack', 1.3);
      else if (b.state === 'move') this.c.setLoop('walk', 0.9 + b.phase * 0.15);
      else if (b.state === 'dead') this.c.playOnce('death', 0.8);
      else this.c.setLoop('idle');
    }
    if (b.active && Math.random() < dt * 10) {
      this.effects.emit({ x: b.x, y: 2.5, z: b.z, count: 1, color: 0x9d6bff, spread: 1, speed: 0.4, up: 0.8, life: 1.2, size: 0.4 });
    }
    this.c.update(dt);
  }

  /** Fade out after death (or when the fight resets). */
  hide() {
    if (!this.visible) return;
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
