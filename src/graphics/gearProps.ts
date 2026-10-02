import * as THREE from 'three';
import { gearTier, offhandKind, weaponKind, type GearTier } from '../content/gear';
import { ARMOR_BY_ID } from '../content/armorSets';
import { fx } from './fxTextures';
import { assets } from './AssetCache';
import { PROP_URL } from './modelPaths';
import { NECRO_MODEL, NECRO_WEAPON_BY_ID, type NecroKind } from '../content/necroWeapons';
import type { GripFit } from './Creature';

/**
 * Code-built props for equipped gear (no art budget): every prop's +Y is its long axis with the
 * grip / seat at the origin, in world units, so Creature.attach can aim and scale it like the other
 * hand props. Weapons expose `userData.tip` (spell origin). Tier tint comes from content/gear.ts.
 */

function metalMat(t: GearTier) {
  return new THREE.MeshStandardMaterial({ color: t.color, metalness: t.metal, roughness: t.rough, emissive: t.glow ?? 0x000000, emissiveIntensity: t.glow ? 0.5 : 0 });
}

const leather = () => new THREE.MeshStandardMaterial({ color: 0x2b211c, roughness: 0.9 });

function tipAt(g: THREE.Group, y: number) {
  const tip = new THREE.Object3D();
  tip.position.y = y;
  g.add(tip);
  g.userData.tip = tip;
}

function sword(t: GearTier, length: number, width: number) {
  const g = new THREE.Group();
  const metal = metalMat(t);
  const blade = new THREE.Mesh(new THREE.BoxGeometry(width, length, 0.02), metal);
  blade.position.y = 0.12 + length / 2;
  const guard = new THREE.Mesh(new THREE.BoxGeometry(width * 3.6, 0.045, 0.05), metal);
  guard.position.y = 0.1;
  const grip = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.02, 0.2, 6), leather());
  grip.position.y = 0;
  const pommel = new THREE.Mesh(new THREE.SphereGeometry(0.03, 8, 6), metal);
  pommel.position.y = -0.11;
  g.add(blade, guard, grip, pommel);
  tipAt(g, 0.12 + length);
  return g;
}

function staff(t: GearTier) {
  const g = new THREE.Group();
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.035, 1.8, 6), new THREE.MeshStandardMaterial({ color: 0x3a2b20, roughness: 0.85 }));
  shaft.position.y = 0.4;
  const cap = new THREE.Mesh(new THREE.SphereGeometry(0.075, 10, 8), metalMat(t));
  cap.position.y = 1.32;
  const gem = new THREE.Sprite(new THREE.SpriteMaterial({ map: fx.glow(), color: t.glow ?? 0xb6a9c8, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true, opacity: 0.7 }));
  gem.scale.setScalar(0.4);
  gem.position.y = 1.36;
  g.add(shaft, cap, gem);
  g.userData.tip = gem;
  return g;
}

function bow(t: GearTier) {
  const g = new THREE.Group();
  const limb = new THREE.Mesh(new THREE.TorusGeometry(0.45, 0.025, 5, 16, Math.PI * 0.85), new THREE.MeshStandardMaterial({ color: t.color, roughness: 0.7, metalness: t.metal * 0.3 }));
  limb.rotation.z = Math.PI / 2 + Math.PI * 0.075;
  const string = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.006, 0.8, 3), new THREE.MeshBasicMaterial({ color: 0x9a8a70 }));
  string.position.x = -0.1;
  g.add(limb, string);
  tipAt(g, 0.4);
  return g;
}

function mace(t: GearTier) {
  const g = new THREE.Group();
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.03, 0.85, 6), leather());
  shaft.position.y = 0.25;
  const metal = metalMat(t);
  const head = new THREE.Mesh(new THREE.SphereGeometry(0.11, 10, 8), metal);
  head.position.y = 0.72;
  g.add(shaft, head);
  for (let i = 0; i < 6; i++) {
    const spike = new THREE.Mesh(new THREE.ConeGeometry(0.03, 0.09, 5), metal);
    const a = (i / 6) * Math.PI * 2;
    spike.position.set(Math.cos(a) * 0.11, 0.72, Math.sin(a) * 0.11);
    spike.rotation.z = -Math.cos(a) * Math.PI / 2;
    spike.rotation.x = Math.sin(a) * Math.PI / 2;
    g.add(spike);
  }
  tipAt(g, 0.78);
  return g;
}

function tome(t: GearTier) {
  const g = new THREE.Group();
  const cover = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.34, 0.07), new THREE.MeshStandardMaterial({ color: 0x3a2432, roughness: 0.8 }));
  cover.position.y = 0.18;
  const clasp = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.08, 0.085), metalMat(t));
  clasp.position.set(0.13, 0.18, 0);
  g.add(cover, clasp);
  tipAt(g, 0.36);
  return g;
}

// --- Necromancer weapon line: procedural stand-ins (used while the GLB loads, or if it fails) ---------------------------

function extrudeFlat(shape: THREE.Shape, depth: number, mat: THREE.Material) {
  const geo = new THREE.ExtrudeGeometry(shape, { depth, bevelEnabled: true, bevelSize: 0.004, bevelThickness: 0.004, bevelSegments: 1, curveSegments: 10 });
  geo.translate(0, 0, -depth / 2);
  return new THREE.Mesh(geo, mat);
}

/** Crescent blade in the XY plane: root at the origin, sweeping out along +X and curling back down to the point. */
function crescent(len: number, bulge: number, thick: number) {
  const sh = new THREE.Shape();
  sh.moveTo(0, 0);
  sh.bezierCurveTo(len * 0.25, bulge, len * 0.75, bulge * 0.7, len, -bulge * 1.5);
  sh.bezierCurveTo(len * 0.7, bulge * 0.1, len * 0.3, bulge * 0.05 - thick, 0, -thick);
  sh.closePath();
  return sh;
}

function necroScythe(t: GearTier) {
  const g = new THREE.Group();
  const metal = metalMat(t);
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.022, 0.028, 1.95, 7), new THREE.MeshStandardMaterial({ color: 0x2a211b, roughness: 0.85 }));
  shaft.position.y = 0.36;
  const blade = extrudeFlat(crescent(0.72, 0.16, 0.07), 0.018, metal);
  blade.position.set(0.01, 1.28, 0);
  blade.rotation.y = Math.PI / 2;
  const collar = new THREE.Mesh(new THREE.SphereGeometry(0.05, 10, 8), metal);
  collar.position.y = 1.29;
  g.add(shaft, blade, collar);
  tipAt(g, 1.3);
  return g;
}

function necroWand(t: GearTier) {
  const g = new THREE.Group();
  const metal = metalMat(t);
  const handle = new THREE.Mesh(new THREE.CylinderGeometry(0.014, 0.02, 0.24, 7), leather());
  handle.position.y = 0;
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.008, 0.014, 0.26, 7), metal);
  shaft.position.y = 0.19;
  const shard = new THREE.Mesh(new THREE.OctahedronGeometry(0.035), metal);
  shard.scale.set(0.8, 1.7, 0.8);
  shard.position.y = 0.36;
  const guard = new THREE.Mesh(new THREE.TorusGeometry(0.03, 0.006, 5, 10), metal);
  guard.rotation.x = Math.PI / 2;
  guard.position.y = 0.07;
  g.add(handle, shaft, shard, guard);
  tipAt(g, 0.4);
  return g;
}

function necroSickle(t: GearTier) {
  const g = new THREE.Group();
  const metal = metalMat(t);
  const grip = new THREE.Mesh(new THREE.CylinderGeometry(0.018, 0.022, 0.26, 7), leather());
  grip.position.y = -0.02;
  const blade = extrudeFlat(crescent(0.3, 0.1, 0.05), 0.012, metal);
  blade.position.set(0, 0.22, 0);
  blade.rotation.set(0, Math.PI / 2, Math.PI / 2);
  blade.scale.set(1, 1, 1);
  const pommel = new THREE.Mesh(new THREE.TorusGeometry(0.022, 0.006, 5, 10), metal);
  pommel.position.y = -0.17;
  g.add(grip, blade, pommel);
  tipAt(g, 0.42);
  return g;
}

function necroSkull(t: GearTier) {
  const g = new THREE.Group();
  const bone = new THREE.MeshStandardMaterial({ color: t.color, metalness: t.metal * 0.4, roughness: Math.max(0.45, t.rough), emissive: t.glow ?? 0x000000, emissiveIntensity: t.glow ? 0.4 : 0 });
  const cranium = new THREE.Mesh(new THREE.SphereGeometry(0.11, 14, 10), bone);
  cranium.scale.set(1, 1.05, 1.1);
  cranium.position.y = 0.26;
  const jaw = new THREE.Mesh(new THREE.BoxGeometry(0.11, 0.05, 0.12), bone);
  jaw.position.set(0, 0.155, 0.02);
  const dark = new THREE.MeshBasicMaterial({ color: 0x0b0810 });
  for (const x of [-0.04, 0.04]) {
    const eye = new THREE.Mesh(new THREE.SphereGeometry(0.026, 8, 6), dark);
    eye.position.set(x, 0.27, 0.09);
    g.add(eye);
  }
  const spine = new THREE.Mesh(new THREE.CylinderGeometry(0.018, 0.024, 0.2, 7), leather());
  spine.position.y = 0.05;
  g.add(cranium, jaw, spine);
  tipAt(g, 0.3);
  return g;
}

function necroBell(t: GearTier) {
  const g = new THREE.Group();
  const metal = metalMat(t);
  const pts = [[0.0, 0], [0.05, -0.01], [0.075, -0.06], [0.085, -0.15], [0.12, -0.26], [0.135, -0.3], [0.125, -0.315], [0.0, -0.28]].map(([x, y]) => new THREE.Vector2(x, y));
  const body = new THREE.Mesh(new THREE.LatheGeometry(pts, 18), metal);
  body.material = metal;
  (body.material as THREE.MeshStandardMaterial).side = THREE.DoubleSide;
  const handle = new THREE.Mesh(new THREE.CylinderGeometry(0.014, 0.018, 0.1, 6), leather());
  handle.position.y = 0.04;
  const clapper = new THREE.Mesh(new THREE.SphereGeometry(0.026, 8, 6), metal);
  clapper.position.y = -0.3;
  g.add(body, handle, clapper);
  tipAt(g, -0.12);
  return g;
}

function necroFallback(kind: NecroKind, t: GearTier): THREE.Group {
  switch (kind) {
    case 'staff': return staff(t);
    case 'scythe': return necroScythe(t);
    case 'wand': return necroWand(t);
    case 'sickle': return necroSickle(t);
    case 'skull_focus': return necroSkull(t);
    case 'mourning_bell': return necroBell(t);
    default: return tome(t);
  }
}

/**
 * Tint one shared mesh five ways: the model's pale relief keeps its detail while the tier's colour, metal, roughness and glow
 * replace the material factors. Materials are cloned per prop (the geometry and textures stay shared).
 */
function tintModel(root: THREE.Object3D, t: GearTier) {
  const base = new THREE.Color(t.color);
  // The raw relief texture is a mid pale grey: lift the tint so dark tiers (iron, hell) do not go black.
  const lift = 1.55;
  const tint = new THREE.Color(Math.min(1, base.r * lift), Math.min(1, base.g * lift), Math.min(1, base.b * lift));
  root.traverse((o) => {
    const m = o as THREE.Mesh;
    if (!m.isMesh) return;
    m.userData.sharedGeo = true;
    m.castShadow = true;
    const mat = (m.material as THREE.MeshStandardMaterial).clone();
    mat.color.copy(tint);
    mat.metalness = Math.min(1, t.metal * 0.85);
    mat.roughness = Math.max(0.25, t.rough);
    if (t.glow) {
      mat.emissive = new THREE.Color(t.glow);
      mat.emissiveMap = mat.map ?? null;
      mat.emissiveIntensity = 0.4;
    } else mat.emissive = new THREE.Color(0x000000);
    m.material = mat;
  });
}

/** Swap a code-built stand-in for its baked GLB once loaded (the group, its attachment and calibration stay as they are). */
function upgradeToModel(g: THREE.Group, kind: NecroKind, t: GearTier) {
  const cfg = NECRO_MODEL[kind];
  void assets.model(PROP_URL(`gear_${kind}`), cfg.length).then((tpl) => {
    if (!tpl || g.userData.disposed) return;
    const model = tpl.scene.clone(true);
    model.scale.setScalar(tpl.scale);
    tintModel(model, t);
    for (const c of [...g.children]) {
      g.remove(c);
      disposeProp(c);
    }
    g.add(model);
    const tip = new THREE.Object3D();
    tip.position.y = (cfg.tip - cfg.grip) * cfg.length;
    g.add(tip);
    g.userData.tip = tip;
    g.userData.model = true;
    // A soft light at the spell origin for the staff, wand and skull: the same tell the primitive staff carries.
    if (kind === 'staff' || kind === 'wand' || kind === 'skull_focus') {
      const glow = new THREE.Sprite(new THREE.SpriteMaterial({ map: fx.glow(), color: t.glow ?? 0xb6a9c8, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true, opacity: t.glow ? 0.65 : 0.35 }));
      glow.scale.setScalar(kind === 'staff' ? 0.42 : 0.28);
      tip.add(glow);
    }
  });
}

/** A main-hand weapon for the given item id. */
export function buildWeapon(itemId: string, rarity?: string): THREE.Group {
  const t = gearTier(itemId, rarity);
  const necro = NECRO_WEAPON_BY_ID[itemId];
  if (necro) {
    const g = necroFallback(necro.kind, t);
    upgradeToModel(g, necro.kind, t);
    return g;
  }
  switch (weaponKind(itemId)) {
    case 'staff': return staff(t);
    case 'bow': return bow(t);
    case 'mace': return mace(t);
    case 'tome': return tome(t);
    case 'dagger': return sword(t, 0.42, 0.045);
    default: return sword(t, 0.95, 0.08);
  }
}

/** An off-hand piece: a round shield (disc axis along X, like the thrall shield) or a tome. */
export function buildOffhand(itemId: string, rarity?: string): THREE.Group {
  const t = gearTier(itemId, rarity);
  const necro = NECRO_WEAPON_BY_ID[itemId];
  if (necro) {
    const g = necroFallback(necro.kind, t);
    upgradeToModel(g, necro.kind, t);
    return g;
  }
  if (offhandKind(itemId) === 'tome') return tome(t);
  const g = new THREE.Group();
  const r = 0.27;
  const disc = new THREE.Mesh(new THREE.CylinderGeometry(r, r, 0.05, 20), metalMat(t));
  disc.rotation.z = Math.PI / 2;
  const rim = new THREE.Mesh(new THREE.TorusGeometry(r, 0.02, 6, 24), metalMat(t));
  rim.rotation.y = Math.PI / 2;
  const boss = new THREE.Mesh(new THREE.SphereGeometry(r * 0.24, 10, 8), metalMat({ ...t, color: 0x3a2f55, glow: t.glow ?? 0x7c3aed }));
  boss.position.x = 0.05;
  g.add(disc, rim, boss);
  return g;
}

/** A helm that sits on the Head bone: dome, brim and (for the noble tiers) a crest. */
export function buildHelm(itemId: string, rarity?: string): THREE.Group {
  const t = gearTier(itemId, rarity);
  const set = ARMOR_BY_ID[itemId];
  const g = new THREE.Group();
  const metal = metalMat(t);
  const dome = new THREE.Mesh(new THREE.SphereGeometry(0.15, 14, 10, 0, Math.PI * 2, 0, Math.PI * 0.62), metal);
  const brim = new THREE.Mesh(new THREE.TorusGeometry(0.15, 0.015, 6, 20), metal);
  brim.rotation.x = Math.PI / 2;
  brim.position.y = -0.02;
  const seat = new THREE.Group();
  seat.position.y = 0.04; // lift inside the scaled parent so it stays in world units
  g.add(seat);
  seat.add(dome, brim);
  if (set) {
    const accent = new THREE.MeshStandardMaterial({ color: set.accent, metalness: 0.65, roughness: 0.35, emissive: set.rarity === 'epic' ? set.accent : 0x000000, emissiveIntensity: 0.32 });
    const jewel = new THREE.Mesh(new THREE.OctahedronGeometry(0.04), accent);
    jewel.position.set(0, 0.08, 0.145);
    seat.add(jewel);
    if (set.disciplineId === 'witch' || set.disciplineId === 'rotweaver') {
      for (const x of [-0.105, 0.105]) {
        const thorn = new THREE.Mesh(new THREE.ConeGeometry(0.025, 0.18, 5), accent);
        thorn.position.set(x, 0.14, 0);
        thorn.rotation.z = x > 0 ? -0.28 : 0.28;
        seat.add(thorn);
      }
    } else if (set.disciplineId === 'knight' || set.disciplineId === 'warden') {
      const visor = new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.055, 0.025), accent);
      visor.position.set(0, 0.035, 0.145);
      seat.add(visor);
      const crest = new THREE.Mesh(new THREE.BoxGeometry(0.035, 0.11, 0.19), accent);
      crest.position.y = 0.18;
      seat.add(crest);
    } else if (set.disciplineId === 'monk' || set.disciplineId === 'mourner' || set.disciplineId === 'veil') {
      const halo = new THREE.Mesh(new THREE.TorusGeometry(0.17, 0.012, 5, 20), accent);
      halo.rotation.x = Math.PI / 2;
      halo.position.y = 0.13;
      seat.add(halo);
    } else {
      const crown = new THREE.Mesh(new THREE.ConeGeometry(0.055, 0.15, 5), accent);
      crown.position.y = 0.19;
      seat.add(crown);
    }
    if (set.collection === 2) {
      const upperRim = new THREE.Mesh(new THREE.TorusGeometry(0.165, 0.014, 6, 24), accent);
      upperRim.rotation.x = Math.PI / 2;
      upperRim.position.y = 0.16;
      seat.add(upperRim);
      for (const x of [-0.12, 0.12]) {
        const fin = new THREE.Mesh(new THREE.ConeGeometry(0.024, 0.12, 5), accent);
        fin.position.set(x, 0.2, -0.02);
        seat.add(fin);
      }
    }
  }
  if (t.glow) {
    const crest = new THREE.Mesh(new THREE.BoxGeometry(0.025, 0.07, 0.22), metal);
    crest.position.y = 0.15;
    seat.add(crest);
  }
  return g;
}

/** Free a prop's private geometry and materials (props are code-built and never shared). */
export function disposeProp(obj: THREE.Object3D) {
  obj.userData.disposed = true;
  obj.traverse((o) => {
    const m = o as THREE.Mesh;
    if (m.isMesh || (o as THREE.Sprite).isSprite) {
      if (!m.userData.sharedGeo) m.geometry?.dispose();
      const mat = m.material as THREE.Material | THREE.Material[];
      (Array.isArray(mat) ? mat : [mat]).forEach((x) => x.dispose());
    }
  });
}


/**
 * A mastery cape hung from the shoulders. Built for the hero skeleton's Spine02 bone, whose local Y is up and local +Z is the back, so
 * no calibration is needed: the cloth is an open cylinder arc centred behind the spine and flaring to the hem, with a trim strip, a
 * clasp and a faint emblem glow. The returned group pivots at the shoulders (`userData.sway` swings it a little as the hero moves).
 */
export function buildCape(color: number, trim: number): THREE.Group {
  const g = new THREE.Group();
  g.position.set(0, 0.16, 0);
  // The cloth hangs behind the spine: the bone's +Z is the hero's back. The robe's back surface sits 0.23-0.33 from the spine
  // (measured on the skinned mesh), so the shoulders clear it at 0.27 and the hem at 0.42.
  const back = new THREE.Group();
  g.add(back);
  const cloth = new THREE.MeshStandardMaterial({ color, roughness: 0.92, metalness: 0.02, side: THREE.DoubleSide });
  const edge = new THREE.MeshStandardMaterial({ color: trim, roughness: 0.5, metalness: 0.35, emissive: trim, emissiveIntensity: 0.18, side: THREE.DoubleSide });
  const arc = 1.7;
  const start = -arc / 2;
  const height = 0.92;
  const top = 0.27;
  const bottom = 0.42;
  const body = new THREE.Mesh(new THREE.CylinderGeometry(top, bottom, height, 16, 4, true, start, arc), cloth);
  body.position.set(0, -height / 2, 0);
  const hem = new THREE.Mesh(new THREE.CylinderGeometry(bottom - 0.002, bottom + 0.004, 0.045, 16, 1, true, start, arc), edge);
  hem.position.set(0, -height + 0.022, 0);
  const collar = new THREE.Mesh(new THREE.CylinderGeometry(top + 0.002, top + 0.002, 0.035, 16, 1, true, start, arc), edge);
  collar.position.set(0, -0.018, 0);
  const clasp = new THREE.Mesh(new THREE.SphereGeometry(0.032, 8, 6), edge);
  clasp.position.set(0, -0.02, -top + 0.005);
  const emblem = new THREE.Sprite(new THREE.SpriteMaterial({ map: fx.glow(), color: trim, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true, opacity: 0.5 }));
  emblem.scale.setScalar(0.2);
  emblem.position.set(0, -0.3, top + 0.06);
  back.add(body, hem, collar, clasp, emblem);
  return g;
}


// --- Grips: how each kind of prop sits in the hand ---------------------------------------------------------------------

/**
 * Per-kind grip. `lean` tilts the prop's long axis away from the body ([outward, forward], tangent of the angle);
 * `offset` shifts it in the character's frame ([outward, up, forward] metres, mirrored for the right hand); `roll` turns
 * it about its own axis; `follow` is how much it rides the wrist (0 = held upright whatever the arm does, 1 = hand-driven).
 * Tuned against src/graphics/__tests__/prop-clipping.test.ts, which measures vertices buried in or resting on the robe.
 */
export interface GripSpec {
  lean: [number, number];
  offset?: [number, number, number];
  roll?: number;
  follow: number;
}

const BASE_GRIP: GripSpec = { lean: [0, 0.1], follow: 0.5 };

export const GRIPS: Record<string, GripSpec> = {
  // main hand
  staff: { lean: [0.06, 0.1], follow: 0.3 },
  scythe: { lean: [0.06, 0.1], follow: 0.3 },
  wand: { lean: [0.35, 0.3], follow: 0.3 },
  sickle: { lean: [0.35, 0.3], follow: 0.3 },
  // off hand
  skull_focus: { lean: [0.25, 0.1], follow: 0.5 },
  grimoire: { lean: [0.45, 0.15], offset: [0.04, 0.02, 0.06], follow: 0.5 },
  mourning_bell: { lean: [-0.5, 0.2], offset: [0.05, 0, 0.06], follow: 0.5 },
};

export interface Grip {
  dir: THREE.Vector3;
  follow: number;
  fit: GripFit;
}

/** The grip for an equipped main-hand or off-hand item. The right hand is the character's -X side, the left +X. */
export function gripFor(slot: 'main_hand' | 'off_hand', itemId: string, hasTip: boolean): Grip {
  const side = slot === 'main_hand' ? -1 : 1;
  const kind = NECRO_WEAPON_BY_ID[itemId]?.kind ?? (slot === 'main_hand' ? weaponKind(itemId) : offhandKind(itemId));
  const spec = GRIPS[kind] ?? { ...BASE_GRIP, follow: slot === 'main_hand' && hasTip ? 0.3 : BASE_GRIP.follow };
  return {
    dir: new THREE.Vector3(side * spec.lean[0], 1, spec.lean[1]),
    follow: spec.follow,
    fit: { roll: spec.roll, offset: spec.offset ? new THREE.Vector3(side * spec.offset[0], spec.offset[1], spec.offset[2]) : undefined },
  };
}
