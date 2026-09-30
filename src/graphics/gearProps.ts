import * as THREE from 'three';
import { gearTier, offhandKind, weaponKind, type GearTier } from '../content/gear';
import { fx } from './fxTextures';

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

/** A main-hand weapon for the given item id. */
export function buildWeapon(itemId: string, rarity?: string): THREE.Group {
  const t = gearTier(itemId, rarity);
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
  if (t.glow) {
    const crest = new THREE.Mesh(new THREE.BoxGeometry(0.025, 0.07, 0.22), metal);
    crest.position.y = 0.15;
    seat.add(crest);
  }
  return g;
}

/** Free a prop's private geometry and materials (props are code-built and never shared). */
export function disposeProp(obj: THREE.Object3D) {
  obj.traverse((o) => {
    const m = o as THREE.Mesh;
    if (m.isMesh || (o as THREE.Sprite).isSprite) {
      m.geometry?.dispose();
      const mat = m.material as THREE.Material | THREE.Material[];
      (Array.isArray(mat) ? mat : [mat]).forEach((x) => x.dispose());
    }
  });
}
