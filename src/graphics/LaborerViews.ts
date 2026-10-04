import * as THREE from 'three';
import { audio } from '../audio/Audio';
import { settings } from '../app/settings';
import { AREAS } from '../content/areas';
import type { NodePlacement, WorldLayout } from '../content/layout';
import { laborActions } from '../gameplay/laborRules';
import { NODES, SKILLS, type GatherSkill } from '../gameplay/gatheringRules';
import { gatherSfx } from '../audio/gatherSfx';
import type { LaborSlot, LaborView } from '../net/api';
import { assets } from './AssetCache';
import { Creature } from './Creature';
import type { Effects } from './Effects';
import { LABORER_MODELS, LABORER_TOOLS, laborerSpot, laborerTip, postNode, workFor, type LaborerWork, type Spot, type SpotWorld } from './laborerLayout';
import { PROP_URL } from './modelPaths';

/**
 * Visible Grave Laborers. While the player is in the Sexton's Acre, each assigned laborer (H panel, up to four) stands beside
 * a node of its post and works it: chop strokes for wood and ore, digging for graves, standing at the pond with a rod to fish.
 * Everything here is idle outside the Acre: models are created on the first Acre visit, nothing updates or fetches elsewhere.
 * The laborer state is the same view the H panel reads (getLabor); it is refreshed on entering, when the panel changes it,
 * and every REFRESH_S. WorldScene only forwards a few hooks (setActive / apply / update / pick / tip / click).
 */

const REFRESH_S = 60;
/** Laborers further than this from the player are left frozen (the Acre is ~40 wide). */
const ANIMATE_RANGE = 48;
/** Impact puffs and the quiet beat only play within these distances of the player. */
const PUFF_RANGE = 16;
const SOUND_RANGE = 11;
/** Seconds between any two laborer sounds. */
const SOUND_GAP = 1.1;
const SOUND_LEVEL = 0.18;
/** The hero's tool grip direction; a rod points up and forward instead. */
const GRIP = new THREE.Vector3(0, 1, 0.1);
const ROD_GRIP = new THREE.Vector3(0, 1, 1.1);
const LOOKS = [
  { emissive: 0x1f8f86, glow: 0.18 },
  { emissive: 0x6a3fc0, glow: 0.16 },
  { emissive: 0x6b4a1f, glow: 0.12 },
  { emissive: 0x5a6a18, glow: 0.16 },
];
/** Impact debris per skill: colour and speed. */
const DEBRIS: Record<string, { color: number; up: number; count: number }> = {
  woodcutting: { color: 0xb9925a, up: 1.3, count: 5 },
  mining: { color: 0xffd78a, up: 1.6, count: 5 },
  gravedigging: { color: 0x5b4733, up: 1.1, count: 5 },
};

interface Laborer {
  slot: number;
  c: Creature;
  /** Node type it works, and the placed node. */
  nodeType: string;
  node: NodePlacement;
  spot: Spot;
  skill: GatherSkill;
  work: LaborerWork;
  tools: Map<string, THREE.Object3D>;
  loadingTool: string | null;
  /** Idle seconds left so a freshly attached tool can calibrate its grip before work starts. */
  hold: number;
  mode: 'hold' | 'work' | 'rest' | '';
  ready: boolean;
  full: boolean;
  marker: THREE.Sprite;
  lastHead: number;
  beatT: number;
  seen: boolean;
  picked: boolean;
  slotView: LaborSlot | null;
}

let MARKER_TEX: THREE.Texture | null = null;
/** One shared "work is ready" badge: a gold coin with a check, drawn once. */
function markerTexture(): THREE.Texture {
  if (MARKER_TEX) return MARKER_TEX;
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
  g.lineWidth = 6;
  g.lineCap = 'round';
  g.lineJoin = 'round';
  g.strokeStyle = '#f5dd8f';
  g.beginPath();
  g.moveTo(19, 33);
  g.lineTo(28, 42);
  g.lineTo(46, 22);
  g.stroke();
  MARKER_TEX = new THREE.CanvasTexture(cv);
  MARKER_TEX.colorSpace = THREE.SRGBColorSpace;
  return MARKER_TEX;
}

export interface LaborerHooks {
  fetch: () => Promise<LaborView>;
  /** The first time a working laborer is close enough to watch (counsel tip). */
  onSeen: () => void;
}

export class LaborerViews {
  readonly group = new THREE.Group();
  private world: SpotWorld;
  private acreNodes: NodePlacement[];
  private byslot = new Map<number, Laborer>();
  /** Same laborers as `byslot`, iterated every frame without allocating an iterator. */
  private list: Laborer[] = [];
  private view: LaborView | null = null;
  private viewAt = 0;
  private active = false;
  private fetching = false;
  private refreshT = 0;
  private soundT = 0;
  private hoverSlot = -1;
  private clock = 0;
  private seenFired = false;
  /** Stable list the world picker reads: loaded, visible laborers only. */
  readonly pickList: { slot: number; x: number; z: number }[] = [];

  constructor(scene: THREE.Scene, private effects: Effects, layout: WorldLayout, private hooks: LaborerHooks) {
    this.acreNodes = layout.nodes.filter((n) => n.area === 'acre');
    this.world = {
      rect: AREAS.acre.rect,
      nodes: this.acreNodes,
      ponds: layout.ponds,
      blockers: layout.props.filter((p) => p.area === 'acre').map((p) => ({ x: p.x, z: p.z, r: 0.7 })),
    };
    this.group.visible = false;
    scene.add(this.group);
  }

  /** True while the player is in the Acre. Entering fetches the laborers (and builds their models the first time). */
  setActive(on: boolean) {
    if (on === this.active) return;
    this.active = on;
    this.group.visible = on;
    if (!on) {
      this.hoverSlot = -1;
      return;
    }
    this.refreshT = REFRESH_S;
    if (this.view) this.sync();
    this.refresh();
  }

  /** Re-read the labor view (after the panel assigned or collected, on a timer). Quiet on failure. */
  refresh() {
    if (!this.active || this.fetching) return;
    this.fetching = true;
    this.hooks.fetch().then((v) => this.apply(v)).catch(() => undefined).finally(() => { this.fetching = false; });
  }

  /** Take a labor view someone else already fetched (the panel, the arrival check). */
  apply(v: LaborView) {
    this.view = v;
    this.viewAt = Date.now();
    if (this.active) this.sync();
  }

  private now() {
    return this.view ? this.view.now + (Date.now() - this.viewAt) : Date.now();
  }

  private workedMs(l: Laborer) {
    const s = l.slotView;
    return s && this.view ? Math.max(0, Math.min(this.now() - s.startedAt, this.view.capMs)) : 0;
  }

  /** Match the laborers on screen to the view: create, move, retool or hide each slot. */
  private sync() {
    const v = this.view;
    if (!v) return;
    const taken: Spot[] = [];
    for (const s of v.slots) {
      const def = s.unlocked && s.nodeType ? NODES[s.nodeType] : null;
      const node = def && s.nodeType ? postNode(this.acreNodes, s.nodeType, s.slot) : null;
      let l = this.byslot.get(s.slot);
      if (!def || !node || def.skill === 'gardening') {
        if (l) {
          l.c.root.visible = false;
          l.marker.visible = false;
        }
        continue;
      }
      if (!l) {
        l = this.create(s.slot);
        this.byslot.set(s.slot, l);
        this.list.push(l);
      }
      if (l.nodeType !== s.nodeType || l.node !== node || !l.c.root.visible) {
        l.nodeType = s.nodeType!;
        l.node = node;
        l.skill = def.skill as GatherSkill;
        l.work = workFor(def.skill);
        l.spot = laborerSpot(node, s.slot, this.world, taken);
        l.c.root.position.set(l.spot.x, 0, l.spot.z);
        l.c.root.rotation.y = l.spot.facing;
        l.mode = '';
        l.hold = 0;
        this.ensureTool(l);
      }
      taken.push(l.spot);
      l.c.root.visible = true;
      l.slotView = s;
      l.full = s.capped;
      l.ready = laborActions(def, this.workedMs(l)) >= 1;
    }
    this.rebuildPicks();
  }

  private create(slot: number): Laborer {
    const look = LOOKS[slot % LOOKS.length];
    const c = new Creature(LABORER_MODELS[slot % LABORER_MODELS.length], { tint: 0xf4ecff, emissive: look.emissive, emissiveIntensity: look.glow });
    c.root.visible = false;
    this.group.add(c.root);
    const marker = new THREE.Sprite(new THREE.SpriteMaterial({ map: markerTexture(), transparent: true, depthWrite: false }));
    marker.scale.setScalar(0.5);
    marker.position.y = 2.3;
    marker.visible = false;
    marker.renderOrder = 6;
    c.root.add(marker);
    return {
      slot, c, nodeType: '', node: this.acreNodes[0], spot: { x: 0, z: 0, facing: 0 }, skill: 'woodcutting', work: workFor(null),
      tools: new Map(), loadingTool: null, hold: 0, mode: '', ready: false, full: false, marker, lastHead: 0, beatT: 0, seen: false, picked: false, slotView: null,
    };
  }

  /** Make sure the matching hand tool is in the laborer's hand (loaded once, hidden when the post changes). */
  private ensureTool(l: Laborer) {
    const spec = LABORER_TOOLS[l.skill];
    for (const [id, obj] of l.tools) obj.visible = id === spec?.id;
    if (!spec || l.tools.has(spec.id) || l.loadingTool === spec.id) return;
    l.loadingTool = spec.id;
    const want = spec.id;
    void l.c.ready
      .then(() => assets.model(PROP_URL(spec.id), spec.length))
      .then((template) => {
        if (!template) return;
        const obj = template.scene.clone(true);
        const size = new THREE.Box3().setFromObject(template.scene).getSize(new THREE.Vector3());
        obj.scale.setScalar(spec.length / Math.max(0.001, size.x, size.y, size.z));
        obj.visible = LABORER_TOOLS[l.skill]?.id === want;
        l.c.attach('R_Hand', obj, l.skill === 'fishing' ? ROD_GRIP : GRIP);
        l.tools.set(want, obj);
        // Let the grip calibrate in idle before the work clip takes over.
        l.hold = 0.9;
        l.mode = '';
      })
      .finally(() => { if (l.loadingTool === want) l.loadingTool = null; });
  }

  private rebuildPicks() {
    this.pickList.length = 0;
    for (const l of this.byslot.values()) {
      l.picked = l.c.root.visible && l.c.loaded;
      if (l.picked) this.pickList.push({ slot: l.slot, x: l.spot.x, z: l.spot.z });
    }
  }

  /** Hover: the slot under the cursor (or -1). Brightens that laborer. */
  setHover(slot: number) {
    this.hoverSlot = slot;
  }

  /** Hover card HTML for a laborer slot, or null. */
  tip(slot: number): string | null {
    const l = this.byslot.get(slot);
    if (!l || !l.slotView) return null;
    const def = NODES[l.nodeType];
    const line = laborerTip(SKILLS[def.skill].name, this.workedMs(l), l.ready, l.full);
    return `<b>${line}</b><div>${def.name} · click to open the Laborers (H)</div>`;
  }

  private setMode(l: Laborer, mode: 'hold' | 'work' | 'rest') {
    if (l.mode === mode) return;
    l.mode = mode;
    if (mode === 'work' && l.work.anim === 'chop' && l.work.range) l.c.loopRange('chop', l.work.range[0], l.work.range[1], 1);
    else if (mode === 'work' && l.work.anim === 'dig') l.c.setLoop('dig', 1);
    else l.c.setLoop('idle', 1);
    l.lastHead = 0;
  }

  update(dt: number, px: number, pz: number) {
    if (!this.active || !this.view) return;
    this.clock += dt;
    this.soundT -= dt;
    if ((this.refreshT -= dt) <= 0) {
      this.refreshT = REFRESH_S;
      this.refresh();
    }
    const calm = settings.reducedMotion;
    for (let i = 0; i < this.list.length; i++) {
      const l = this.list[i];
      if (!l.c.root.visible) continue;
      const dist = Math.hypot(l.spot.x - px, l.spot.z - pz);
      if (dist > ANIMATE_RANGE) continue;
      if (l.hold > 0) l.hold -= dt;
      const mode = l.hold > 0 ? 'hold' : l.full ? 'rest' : 'work';
      this.setMode(l, mode);
      l.c.update(dt);
      if (l.c.loaded && !l.picked) this.rebuildPicks();
      // Fishers sway very gently at the water; the rod rides the hand.
      l.c.root.rotation.z = l.skill === 'fishing' && l.mode === 'work' && !calm ? Math.sin(this.clock * 1.3 + l.slot) * 0.02 : 0;
      l.c.flash = this.hoverSlot === l.slot ? 0.2 : 0;
      const showMarker = l.ready && l.c.loaded;
      if (l.marker.visible !== showMarker) l.marker.visible = showMarker;
      if (showMarker) l.marker.position.y = 2.3 + (calm ? 0 : Math.sin(this.clock * 2.2 + l.slot) * 0.06);
      if (mode === 'work' && l.c.loaded) {
        this.beats(l, dt, dist);
        if (!l.seen && dist < PUFF_RANGE && l.hold <= 0) {
          l.seen = true;
          if (!this.seenFired) {
            this.seenFired = true;
            this.hooks.onSeen();
          }
        }
      }
    }
  }

  /** Impact puff + (very quiet, throttled) sound on each stroke, only near the player. */
  private beats(l: Laborer, dt: number, dist: number) {
    let beat = false;
    if (l.work.impact !== null) {
      const head = l.c.playhead();
      beat = l.lastHead < l.work.impact && head >= l.work.impact;
      l.lastHead = head;
    } else if (l.work.beatEvery > 0) {
      l.beatT += dt;
      if (l.beatT >= l.work.beatEvery) {
        l.beatT -= l.work.beatEvery;
        beat = true;
      }
    }
    if (!beat || dist > PUFF_RANGE) return;
    const d = DEBRIS[l.skill];
    if (d && !settings.reducedMotion) {
      const k = l.skill === 'gravedigging' ? 0.55 : 0.8;
      const x = l.spot.x + (l.node.x - l.spot.x) * k;
      const z = l.spot.z + (l.node.z - l.spot.z) * k;
      this.effects.emit({ x, y: l.skill === 'gravedigging' ? 0.15 : 0.7, z, count: d.count, color: d.color, spread: 0.25, speed: 1.1, up: d.up, life: 0.5, size: 0.14, gravity: 5 });
    }
    // The one laborer sound call site: the skill's own gather sound, quiet, one at a time.
    if (dist < SOUND_RANGE && this.soundT <= 0 && l.skill !== 'fishing') {
      this.soundT = SOUND_GAP;
      audio.play(gatherSfx(l.skill, NODES[l.node.id]?.kind), l.node.x, l.node.z, SOUND_LEVEL);
    }
  }

  /** QA: what is where, in what mode. */
  debug() {
    return [...this.byslot.values()].map((l) => ({
      slot: l.slot, model: l.c.slug, node: l.node.id, type: l.nodeType, x: +l.spot.x.toFixed(2), z: +l.spot.z.toFixed(2), nodeX: l.node.x, nodeZ: l.node.z,
      visible: l.c.root.visible, loaded: l.c.loaded, mode: l.mode, ready: l.ready, full: l.full, tools: [...l.tools.keys()], head: +l.c.playhead().toFixed(2),
    }));
  }

  dispose() {
    for (const l of this.byslot.values()) {
      l.c.dispose();
      (l.marker.material as THREE.SpriteMaterial).dispose();
    }
    this.byslot.clear();
    this.list.length = 0;
    this.group.removeFromParent();
  }
}
