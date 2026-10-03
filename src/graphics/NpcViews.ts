import * as THREE from 'three';
import { settings } from '../app/settings';
import { NPCS, NPC_IDS, NPC_LOOKS, NPC_LOOK_RANGE, type NpcId } from '../content/npcs';
import { Creature } from './Creature';
import { assets } from './AssetCache';
import { CREATURE_MODELS, PROP_URL } from './modelPaths';

/**
 * The people of the Covenant standing in their halls: an idle figure, a nameplate, a turn toward you when you come close, and
 * a gold "!" with a soft glow on the ground while they have something new to say. Everything about how one looks comes from
 * content/npcs.ts (NPC_LOOKS), so swapping a stand-in for the real model is a one-line change there. Models load the first
 * time the player is anywhere near (nothing is fetched while you are in the far halls); a clip a stand-in lacks is skipped.
 */
const LOAD_RANGE = 70;
const PLATE_RANGE = 20;
const TURN_RATE = 4;
const HELD_SLIDE = -0.3;
/** Same grip the Grave Laborers use for their spade (LaborerViews GRIP): the tool's +Y rides straight up from the hand. */
const HELD_GRIP = new THREE.Vector3(0, 1, 0.1);
const DISPLAY_FONT = () => {
  try {
    const f = getComputedStyle(document.documentElement).getPropertyValue('--cw-font-display').trim();
    return f || 'Georgia, serif';
  } catch {
    return 'Georgia, serif';
  }
};

const hex = (n: number) => `#${n.toString(16).padStart(6, '0')}`;

function plateTexture(name: string, title: string, accent: number): { tex: THREE.CanvasTexture; w: number; h: number } {
  const font = DISPLAY_FONT();
  const cv = document.createElement('canvas');
  const g = cv.getContext('2d')!;
  const nameFont = `700 34px ${font}`;
  const titleFont = `400 21px ${font}`;
  g.font = nameFont;
  const w = Math.ceil(Math.max(g.measureText(name.toUpperCase()).width, (g.font = titleFont, g.measureText(title).width)) + 36);
  cv.width = w;
  cv.height = 78;
  g.fillStyle = 'rgba(8,6,12,0.62)';
  g.fillRect(0, 0, w, 78);
  g.strokeStyle = hex(accent);
  g.globalAlpha = 0.5;
  g.strokeRect(1, 1, w - 2, 76);
  g.globalAlpha = 1;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillStyle = '#f0e9dc';
  g.font = nameFont;
  g.fillText(name.toUpperCase(), w / 2, 29);
  g.fillStyle = '#d8cfbd';
  g.font = titleFont;
  g.fillText(title, w / 2, 58);
  const tex = new THREE.CanvasTexture(cv);
  tex.colorSpace = THREE.SRGBColorSpace;
  return { tex, w, h: 78 };
}

let BANG: THREE.Texture | null = null;
function bangTexture(): THREE.Texture {
  if (BANG) return BANG;
  const cv = document.createElement('canvas');
  cv.width = cv.height = 64;
  const g = cv.getContext('2d')!;
  g.fillStyle = '#2a1d0e';
  g.beginPath();
  g.arc(32, 32, 28, 0, Math.PI * 2);
  g.fill();
  g.lineWidth = 4;
  g.strokeStyle = '#e8c15a';
  g.stroke();
  g.fillStyle = '#f5dd8f';
  g.font = `800 44px ${DISPLAY_FONT()}`;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.fillText('!', 32, 35);
  BANG = new THREE.CanvasTexture(cv);
  BANG.colorSpace = THREE.SRGBColorSpace;
  return BANG;
}

let GLOW: THREE.Texture | null = null;
function glowTexture(): THREE.Texture {
  if (GLOW) return GLOW;
  const cv = document.createElement('canvas');
  cv.width = cv.height = 128;
  const g = cv.getContext('2d')!;
  const grad = g.createRadialGradient(64, 64, 6, 64, 64, 62);
  grad.addColorStop(0, 'rgba(255,255,255,0.95)');
  grad.addColorStop(0.5, 'rgba(255,255,255,0.4)');
  grad.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 128, 128);
  GLOW = new THREE.CanvasTexture(cv);
  GLOW.colorSpace = THREE.SRGBColorSpace;
  return GLOW;
}

interface Npc {
  id: NpcId;
  c: Creature | null;
  root: THREE.Group;
  plate: THREE.Sprite;
  bang: THREE.Sprite;
  glow: THREE.Mesh;
  yaw: number;
  headY: number;
  talking: boolean;
  isNew: boolean;
  /** Seconds until the next emphatic gesture while talking (models with a `talk2` clip only). */
  gestureT: number;
  /** Seconds of animation time not yet handed to the mixer (distance LOD). */
  animDt: number;
}

/** Figures nearer than this animate every frame; up to NPC_LOD_FAR ~24 Hz; beyond that ~10 Hz. */
const NPC_LOD_NEAR = 12;
const NPC_LOD_FAR = 24;

export class NpcViews {
  readonly group = new THREE.Group();
  private npcs = new Map<NpcId, Npc>();
  private clock = 0;
  private hover: NpcId | null = null;

  constructor(scene: THREE.Scene) {
    scene.add(this.group);
    for (const id of NPC_IDS) {
      const def = NPCS[id];
      const look = NPC_LOOKS[id];
      const headY = CREATURE_MODELS[look.slug].height * look.scale + 0.35;
      const root = new THREE.Group();
      root.position.set(def.x, 0, def.z);
      root.rotation.y = def.rest;
      root.visible = false;
      const plateTex = plateTexture(def.name, def.title, def.accent);
      const plate = new THREE.Sprite(new THREE.SpriteMaterial({ map: plateTex.tex, transparent: true, depthWrite: false, depthTest: false }));
      const ph = 0.46;
      plate.scale.set((plateTex.w / plateTex.h) * ph, ph, 1);
      plate.position.y = headY + 0.15;
      plate.renderOrder = 7;
      const bang = new THREE.Sprite(new THREE.SpriteMaterial({ map: bangTexture(), transparent: true, depthWrite: false, depthTest: false }));
      bang.scale.setScalar(0.52);
      bang.renderOrder = 8;
      bang.visible = false;
      const glow = new THREE.Mesh(
        new THREE.PlaneGeometry(4.2, 4.2).rotateX(-Math.PI / 2),
        new THREE.MeshBasicMaterial({ map: glowTexture(), color: def.accent, transparent: true, opacity: 0, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      glow.position.y = 0.06;
      glow.renderOrder = 3;
      root.add(plate, bang, glow);
      this.group.add(root);
      this.npcs.set(id, { id, c: null, root, plate, bang, glow, yaw: def.rest, headY, talking: false, isNew: false, gestureT: 6, animDt: 0 });
    }
  }

  private load(n: Npc) {
    const look = NPC_LOOKS[n.id];
    const c = new Creature(look.slug, { scale: look.scale, tint: look.tint, emissive: look.emissive, emissiveIntensity: look.glow, fallback: look.fallback });
    n.c = c;
    n.root.add(c.root);
    if (look.held) {
      const { prop, length } = look.held;
      void c.ready
        .then(() => assets.model(PROP_URL(prop), length))
        .then((template) => {
          if (!template || n.c !== c) return;
          const obj = template.scene.clone(true);
          const size = new THREE.Box3().setFromObject(template.scene).getSize(new THREE.Vector3());
          obj.scale.setScalar(length / Math.max(0.001, size.x, size.y, size.z));
          // Like the gathering avatar's spade (Avatars.ts): authored lying along X, so stand it up and slide it so the hand
          // holds the handle, not the middle.
          if (size.x > size.y * 1.5) obj.rotation.z = -Math.PI / 2;
          obj.position.y = HELD_SLIDE * length;
          const holder = new THREE.Group();
          holder.add(obj);
          c.attach('R_Hand', holder, HELD_GRIP, 0.9);
        });
    }
  }

  setHover(id: NpcId | null) {
    this.hover = id;
  }

  /** Who is talking to the player right now (they keep their eyes on you and use a `talk` clip if the model has one). */
  setTalking(id: NpcId | null) {
    for (const n of this.npcs.values()) {
      const t = n.id === id;
      if (t === n.talking) continue;
      n.talking = t;
      n.gestureT = 5 + Math.random() * 4;
      if (n.c?.loaded && n.c.has('talk')) n.c.setLoop(t ? 'talk' : 'idle', 1);
    }
  }

  /** Has the figure's model finished loading? (QA) */
  loaded(id: NpcId) {
    return !!this.npcs.get(id)?.c?.loaded;
  }

  distanceTo(id: NpcId, px: number, pz: number) {
    const d = NPCS[id];
    return Math.hypot(d.x - px, d.z - pz);
  }

  update(dt: number, px: number, pz: number, isNew: (id: NpcId) => boolean) {
    this.clock += dt;
    const calm = settings.reducedMotion;
    for (const n of this.npcs.values()) {
      const def = NPCS[n.id];
      const dist = Math.hypot(def.x - px, def.z - pz);
      const near = dist < LOAD_RANGE;
      if (near && !n.c) this.load(n);
      n.root.visible = near;
      if (!near) continue;
      if (n.talking && n.c?.loaded && n.c.has('talk2') && (n.gestureT -= dt) <= 0) {
        n.gestureT = 9 + Math.random() * 6;
        n.c.playOnce('talk2');
      }
      if (n.c?.loaded) n.c.setLoop(n.talking && n.c.has('talk') ? 'talk' : 'idle', 1);
      // Animation LOD: a figure across the yard animates at ~24 Hz, a distant one at ~10 Hz (skipped time accumulates).
      n.animDt += dt;
      const every = n.talking || dist < NPC_LOD_NEAR ? 0 : dist < NPC_LOD_FAR ? 1 / 24 : 1 / 10;
      if (n.animDt >= every) {
        if (n.c) n.c.steadyEvery = every === 0 ? 1 : 2;
        n.c?.update(n.animDt);
        n.animDt = 0;
      }
      // Turn toward the player when close (or while talking), back to rest otherwise.
      const want = n.talking || dist < NPC_LOOK_RANGE ? Math.atan2(px - def.x, pz - def.z) : def.rest;
      let diff = want - n.yaw;
      diff = Math.atan2(Math.sin(diff), Math.cos(diff));
      n.yaw += diff * Math.min(1, dt * TURN_RATE);
      if (n.c) n.c.root.rotation.y = n.yaw;
      if (n.c) n.c.flash = this.hover === n.id ? 0.2 : 0;
      n.plate.visible = dist < PLATE_RANGE || this.hover === n.id;
      const fresh = isNew(n.id) && !n.talking;
      n.isNew = fresh;
      n.bang.visible = fresh;
      if (fresh) {
        const bob = calm ? 0 : Math.sin(this.clock * 2.4 + def.x) * 0.07;
        n.bang.position.y = n.headY + 0.75 + bob;
      }
      const pulse = calm ? 0.5 : 0.5 + 0.5 * Math.sin(this.clock * 1.8 + def.z);
      (n.glow.material as THREE.MeshBasicMaterial).opacity = fresh ? 0.5 + 0.3 * pulse : 0;
      n.glow.visible = fresh;
    }
  }

  /** QA: where the figure is and what shows. */
  debug() {
    return [...this.npcs.values()].map((n) => ({ id: n.id, model: n.c?.slug ?? null, hasTalk: !!n.c?.loaded && n.c.has('talk'), hasTalk2: !!n.c?.loaded && n.c.has('talk2'), talking: n.talking, loaded: !!n.c?.loaded, visible: n.root.visible, yaw: +n.yaw.toFixed(2), bang: n.bang.visible, plate: n.plate.visible, x: n.root.position.x, z: n.root.position.z }));
  }

  dispose() {
    for (const n of this.npcs.values()) {
      n.c?.dispose();
      (n.plate.material as THREE.SpriteMaterial).map?.dispose();
      (n.plate.material as THREE.SpriteMaterial).dispose();
      (n.bang.material as THREE.SpriteMaterial).dispose();
      (n.glow.material as THREE.MeshBasicMaterial).dispose();
      n.glow.geometry.dispose();
    }
    this.npcs.clear();
    this.group.removeFromParent();
  }
}
