import * as THREE from 'three';
import { LEGEND } from '../gameplay/legendary';
import { BURROW, CENSER, ENEMIES, UNBIND, type EliteAffix, type EnemyId } from '../content/enemies';
import type { DisciplineId, ThrallKind } from '../content/disciplines';
import type { Corpse, Enemy, SimEvent, Thrall } from '../gameplay/sim/types';
import { Creature } from './Creature';
import type { Effects, Handle } from './Effects';
import { fx } from './fxTextures';
import * as nf from './necroFx';
import { SPELL_FX } from '../content/abilities';
import { audio } from '../audio/Audio';
import type { CreatureSlug } from './modelPaths';
import { AREAS, type AreaId } from '../content/areas';
import { BOSSES } from '../content/bosses';
import { runIdleSequence } from './warmModel';
import { STATUS_FX } from '../content/statuses';
import { wingClock, type WingOpts } from './wingFlap';
import { smoothSpeed, stepSpeed, turnToward } from './locomotion';
import { separateBodies, type CrowdBody } from './crowdSeparation';
import { hitstop } from './hitstop';
import { disposeProp, upgradeThrallProp } from './gearProps';
import { gearTier } from '../content/gear';
import { knockActive, knockImpulse, settleDepth, stepKnock, type Knock } from './knockback';

const ENEMY_SLUG: Record<EnemyId, CreatureSlug> = {
  robber: 'grave_robber',
  hound: 'bone_hound',
  penitent: 'penitent',
  sac: 'carrion_sac',
  deacon: 'deacon',
  risen: 'skeleton_thrall',
  censer: 'censer_bearer',
  wraith: 'choir_wraith',
  rat: 'skull_rat',
  golem: 'bone_golem',
  gargoyle: 'belfry_gargoyle',
  moth: 'shroud_moth',
  bat: 'tithe_bat',
  seraph: 'weeping_seraph',
  ghoul: 'barrow_ghoul',
  acolyte: 'lich_acolyte',
  templar: 'bell_templar',
  niche: 'skull_niche',
  plague_doctor: 'plague_doctor',
  flagellant: 'flagellant',
  cinder_husk: 'cinder_husk',
  pyre_priest: 'pyre_priest',
  cinderhound: 'cinderhound',
  slag_brute: 'slag_brute',
  bog_hag: 'bog_hag',
  mire_leech: 'mire_leech',
  fen_wisp: 'fen_wisp',
  drowned_sexton: 'drowned_sexton',
};

/** Shipped models to fall back on if a newer GLB is missing (older deploys, failed builds). */
const ENEMY_FALLBACK: Partial<Record<EnemyId, CreatureSlug>> = {
  censer: 'deacon',
  wraith: 'penitent',
  rat: 'bone_hound',
  golem: 'skeleton_thrall',
  gargoyle: 'bone_hound',
  moth: 'choir_wraith',
  bat: 'skull_rat',
  seraph: 'deacon',
  ghoul: 'grave_robber',
  acolyte: 'deacon',
  templar: 'grave_robber',
  plague_doctor: 'deacon',
  flagellant: 'grave_robber',
  cinder_husk: 'grave_robber',
  pyre_priest: 'deacon',
  cinderhound: 'bone_hound',
  slag_brute: 'bone_golem',
  bog_hag: 'deacon',
  mire_leech: 'skull_rat',
  fen_wisp: 'choir_wraith',
  drowned_sexton: 'bone_golem',
};
/** Enemies that cast (play 'cast' rather than 'attack' on the windup). */
const CASTERS = new Set<EnemyId>(['penitent', 'deacon', 'wraith', 'censer', 'moth', 'seraph', 'acolyte', 'plague_doctor', 'pyre_priest', 'bog_hag', 'fen_wisp']);
/** The Cinder Pyre's dead: they shed embers and spray sparks when struck (see the per-enemy effect pass). */
const FIRE_DEAD = new Set<EnemyId>(['cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute']);
/** The Mourning Fen's own dead (see fenDead). */
const FEN_DEAD = new Set<EnemyId>(['fen_wisp', 'bog_hag', 'drowned_sexton', 'mire_leech']);
/** Choir Wraiths float: a hover height and a slow bob. */
const HOVER = { wraith: 0.45 } as Partial<Record<EnemyId, number>>;
/** Flying pack wingbeats: heavy stone, dusty moth, frantic bat, slow grieving seraph. */
const WINGS: Partial<Record<EnemyId, WingOpts>> = {
  // gargoyle: its wings are bones now (rigfix + tools/blender/recipes/belfry_gargoyle.json), so no shader flap.
  moth: { speed: 8, amp: 0.55, body: 0.16 },
  bat: { speed: 17, amp: 0.75, body: 0.22 },
  seraph: { speed: 3.2, amp: 0.22, body: 0.3 },
};

/** Each necromancer's own dead. Bespoke textures carry the colour, so the tint is neutral and the glow faint. */
const LEGION: Record<string, { slug: CreatureSlug; tint?: number; emissive?: number; glow?: number; armed?: boolean }> = {
  ossuary: { slug: 'thrall_sentinel', tint: 0xffffff, emissive: 0x6b4a1f, glow: 0.12, armed: true },
  gravecaller: { slug: 'thrall_legionnaire', tint: 0xffffff, emissive: 0x6a3fc0, glow: 0.16, armed: true },
  rotweaver: { slug: 'thrall_plague', tint: 0xffffff, emissive: 0x5a6a18, glow: 0.16 },
  mourner: { slug: 'wraith_thrall' },
};

const THRALL_SLUG: Record<ThrallKind, CreatureSlug> = {
  warrior: 'skeleton_thrall',
  shieldbearer: 'skeleton_thrall',
  hound: 'bone_hound',
  wraith: 'skeleton_thrall',
  archer: 'skeleton_thrall',
  bonemage: 'skeleton_thrall',
  plaguebearer: 'carrion_sac',
  colossus: 'bone_colossus',
};

/** Tint / glow per thrall kind (colour language: bone ivory-amber, rot olive, spirit cold blue). */
const THRALL_LOOK: Partial<Record<ThrallKind, { tint: number; emissive: number; glow: number; scale?: number; ring?: number }>> = {
  archer: { tint: 0xf2e6cc, emissive: 0x6b4a1f, glow: 0.25 },
  bonemage: { tint: 0xe6dccb, emissive: 0xb07a2a, glow: 0.35 },
  plaguebearer: { tint: 0xb9c48a, emissive: 0x5a6a18, glow: 0.35, scale: 0.8, ring: 0.7 },
  // Bone Colossus rune: the Tripo giant is left in its own bone-and-cloth colours (a jade glow and rim read it as yours); a wide ring under it.
  colossus: { tint: 0xffffff, emissive: 0x1f8f86, glow: 0.1, ring: 1.7 },
};

/** What the legion's kit looks like on a thrall (gameplay/legionKit.ts decides the pieces; this only dresses the model). */
export interface ThrallKitLook {
  weapon?: { itemId: string; rarity?: string };
  armor?: { itemId: string; rarity?: string };
}
/** Kinds with the humanoid thrall skeleton: the only ones that wear body tint and carry the kit's bow, staff or blade. */
const KIT_BODIES = new Set<ThrallKind>(['warrior', 'shieldbearer', 'archer', 'bonemage']);
/** How much of the kit armour's colour washes over the chest and hands: enough to read as plate or leather, far short of a recolour. */
const KIT_ARMOR_STRENGTH = 0.32;

interface View {
  c: Creature;
  x: number;
  z: number;
  facing: number;
  lastState: string;
  def?: EnemyId;
  kind?: ThrallKind;
  ring?: Handle;
  /** A Bog Hag's hex on this thrall: a magenta sigil ring under it while `cursedT` lasts. */
  hexFx?: Handle;
  eliteAura?: Handle;
  /** Censer Bearer's incense ring. */
  auraFx?: Handle;
  affix?: EliteAffix;
  /** Persistent affix tells (rings / cracks that follow the elite). */
  affixFx?: Handle[];
  /** Shrouded elites fade toward this opacity (1 inside Miasma). */
  shroud?: number;
  /** Set by a Corpse Explosion: the body shatters instead of sinking with rot. */
  shattered?: boolean;
  dieT?: number;
  sinkT?: number;
  animSkip: number;
  animDt: number;
  float?: boolean;
  /** Barrow Ghoul underground (burrowed, or winding up its eruption): the model hides, a dirt mound slides instead. */
  under?: boolean;
  mound?: THREE.Mesh;
  /** Hit flinch: last seen hit flash and when the next flinch may play (ms). */
  lastFlash?: number;
  flinchAt?: number;
  /** Smoothed ground speed (units/s) measured from the body's real movement; drives the walk / run playback. */
  gs?: number;
  /** Eased slide of the drawn body off its sim position, so a pack does not stack (crowdSeparation.ts). */
  ox?: number;
  oz?: number;
  /** Visual knockback spring (knockback.ts): the drawn body is shoved and eases back; the sim position is untouched. */
  kn?: Knock;
  /** Last seen hp, to size a hit. */
  lastHp?: number;
  /** Death settle: seconds since the body landed (undefined = not landed yet), its resting y, and whether it is skipped. */
  settleT?: number;
  settleY?: number;
}

/** One shared low-poly mound for every burrowed ghoul (grave-dirt brown, never a player colour). */
let MOUND_GEO: THREE.BufferGeometry | null = null;
let MOUND_MAT: THREE.MeshStandardMaterial | null = null;
function makeMound() {
  MOUND_GEO ??= new THREE.SphereGeometry(0.55, 14, 5, 0, Math.PI * 2, 0, Math.PI / 2).scale(1, 0.4, 1.3);
  // Darker than the dirt particles: under warm torchlight the mound otherwise reads orange.
  MOUND_MAT ??= new THREE.MeshStandardMaterial({ color: 0x33251a, roughness: 1, metalness: 0, flatShading: true });
  const m = new THREE.Mesh(MOUND_GEO, MOUND_MAT);
  m.castShadow = false;
  return m;
}

const A = SPELL_FX.affix;
const D = SPELL_FX.detonate;

/** Rough mouth/head height per rig, for drool and sparks. */
/** Common enemies nearest the camera focus that keep their moon shadow. */
const SHADOW_CASTERS = 12;
/** Fastest a body swings round to a new heading (rad/s): an about-face reads as a turn, not a snap. */
const ENEMY_TURN_RATE = 9;
/** Most bodies near the camera the view-layer separation will relax in one frame (it is O(n^2) in this number). */
const MAX_CROWD = 140;
/** How fast a drawn body eases to its separated spot (1/s), and the footprint it is drawn with (share of the sim radius). */
const CROWD_EASE = 9;
const CROWD_FOOTPRINT = 1.12;
const CROWDED_SHADOW_CASTERS = 8;
/** A hit that takes this share of max hp (elites: the lower one) and leaves the target standing freezes the picture for a few frames. */
const HEAVY_HIT = 0.22;
const HEAVY_HIT_ELITE = 0.12;
/** Heavy hits farther than this from the hero do not freeze the screen. */
const HITSTOP_RANGE = 16;
/** How far a landed body eases down into the ground (world units, before its scale). */
const SETTLE_DEPTH = 0.06;
/** settleT of a corpse laid down at once (late join, sacrificed thrall): it never plays the landing. */
const NO_SETTLE = -1;
/** Seconds a corpse keeps animating: the longest death clip is 5.6 s and its fall lands near 4 s (it used to freeze at 3 s, mid-fall). */
const CORPSE_ANIM_S = 6;
/** Most faint corpse rings alive at once (draw-call budget). */
const CORPSE_MARKS_MAX = 8;
/** Fresnel rim strength on thralls: own legion / a co-op ally's legion (see friendRim.ts). */
const THRALL_RIM_OWN = 0.9;
const THRALL_RIM_ALLY = 0.6;
const HEAD_Y = { humanoid: 1.3, robed: 1.35, quadruped: 0.75, bloat: 1.05 } as const;

function killAffixFx(v: View) {
  v.affixFx?.forEach((h) => h.kill());
  v.affixFx = undefined;
}

function boneSword(color = 0x6f6a74) {
  const g = new THREE.Group();
  const metal = new THREE.MeshStandardMaterial({ color, metalness: 0.7, roughness: 0.45 });
  const blade = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.95, 0.02), metal);
  blade.position.y = 0.55;
  const guard = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.05, 0.05), metal);
  guard.position.y = 0.08;
  g.add(blade, guard);
  return g;
}

/** A recurve of fused rib bone with a sinew string (code-built; no asset). */
function boneBow() {
  const g = new THREE.Group();
  const bone = new THREE.MeshStandardMaterial({ color: 0xd8cfbd, roughness: 0.7 });
  const limb = new THREE.Mesh(new THREE.TorusGeometry(0.42, 0.025, 5, 14, Math.PI * 0.85), bone);
  limb.rotation.z = Math.PI / 2 + Math.PI * 0.075;
  const string = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.006, 0.76, 3), new THREE.MeshBasicMaterial({ color: 0x9a8a70 }));
  string.position.x = -0.1;
  g.add(limb, string);
  return g;
}

/** A femur staff crowned with an amber ember. */
function boneStaff() {
  const g = new THREE.Group();
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.025, 0.035, 1.3, 6), new THREE.MeshStandardMaterial({ color: 0xcfc3ad, roughness: 0.75 }));
  shaft.position.y = 0.45;
  const orb = new THREE.Mesh(new THREE.SphereGeometry(0.08, 10, 8), new THREE.MeshStandardMaterial({ color: 0x5a3a14, emissive: 0xd9a66b, emissiveIntensity: 1.2 }));
  orb.position.y = 1.15;
  g.add(shaft, orb);
  return g;
}

function roundShield(r: number) {
  const g = new THREE.Group();
  const disc = new THREE.Mesh(
    new THREE.CylinderGeometry(r, r, 0.06, 18),
    new THREE.MeshStandardMaterial({ color: 0x4d4033, metalness: 0.5, roughness: 0.55 }),
  );
  disc.rotation.z = Math.PI / 2;
  const boss = new THREE.Mesh(
    new THREE.SphereGeometry(r * 0.22, 10, 8),
    new THREE.MeshStandardMaterial({ color: 0x3a2f55, emissive: 0x7c3aed, emissiveIntensity: 0.9 }),
  );
  boss.position.x = 0.05;
  g.add(disc, boss);
  return g;
}

/**
 * Maps simulation entities onto animated Creatures: enemies climb out of the
 * ground, die into corpses that stay where they fell, and are consumed or
 * sink away; thralls get weapons, a violet summon ring and a lilac glow.
 */
/** Every affix an elite bears: its first, then the extras the Catacomb Depths add. */
const affixesOf = (e: Enemy): EliteAffix[] => (e.affix ? [e.affix, ...(e.extra?.map((x) => x.affix) ?? [])] : []);

export class EntityViews {
  readonly group = new THREE.Group();
  private enemies = new Map<number, View>();
  private thralls = new Map<number, View>();
  private corpses = new Map<number, View>();
  /** Resonant corpses' ground rings, so they end with the corpse instead of lingering out their full timer. */
  private corpseRings = new Map<number, Handle>();
  private dying: View[] = [];
  private fading: View[] = [];
  private frame = 0;
  private crowd: CrowdBody[] = [];
  private crowdViews: View[] = [];
  private crowdSeen = new Set<View>();
  private crowdOut = new Float32Array(2 * (MAX_CROWD + 1));
  /** Enemy under the cursor — gets a faint lilac highlight. */
  hoverId: number | null = null;

  constructor(
    scene: THREE.Scene,
    private effects: Effects,
    /** The discipline that raised a thrall (its owner's), so each necromancer's legion looks like its own. */
    private legionOf?: (owner: string) => DisciplineId | null,
    /** Is this thrall's owner the local player? Allies' legions get a slightly softer friendly rim. */
    private isOwn?: (owner: string) => boolean,
    /** The kit a thrall's owner has given the legion, or null (only your own legion wears yours). Read when a thrall is raised. */
    private kitOf?: (owner: string) => ThrallKitLook | null,
  ) {
    scene.add(this.group);
  }

  private makeEnemy(e: Enemy): View {
    const slug = ENEMY_SLUG[e.def];
    const risen = e.def === 'risen';
    const wraith = e.def === 'wraith';
    // Risen raised by the Mire Mother's rite are drowned: teal-tinged.
    const drowned = risen && e.area === 'fen';
    const c = new Creature(slug, {
      // Hostile skeletons read darker and sickly so they never look like your thralls.
      tint: risen ? (drowned ? 0x7ab0a8 : 0x8a8078) : 0xffffff,
      emissive: e.elite ? 0x4a1f8a : risen ? (drowned ? 0x1f8f86 : 0x2a3a18) : wraith ? 0x9fb6d8 : e.def === 'fen_wisp' ? 0x7fe0d0 : 0x000000,
      emissiveIntensity: e.elite ? 0.14 : risen ? (drowned ? 0.4 : 0.3) : wraith ? 0.35 : e.def === 'fen_wisp' ? 0.9 : 0,
      // The choir is half-there: translucent, pale, no shadow.
      spectral: wraith,
      fallback: ENEMY_FALLBACK[e.def],
      wings: WINGS[e.def],
    });
    c.root.scale.setScalar(e.scale / (e.def === 'risen' ? 1 : 1));
    this.group.add(c.root);
    const v: View = { c, x: e.x, z: e.z, facing: e.facing, lastState: '', def: e.def, animSkip: 0, animDt: 0 };
    if (e.elite) {
      v.eliteAura = this.effects.decal({
        tex: fx.ring(),
        color: 0x9b5cff,
        x: e.x,
        z: e.z,
        r: 1.1 * e.scale,
        duration: 1e9,
        opacity: 0.8,
        pulse: 4,
        follow: () => ({ x: v.x + (v.ox ?? 0), z: v.z + (v.oz ?? 0) }),
      });
    }
    if (e.affix) this.dressAffix(v, e);
    return v;
  }

  /** A readable, persistent tell for each elite affix. */
  private dressAffix(v: View, e: Enemy) {
    v.affix = e.affix;
    const follow = () => ({ x: v.x, z: v.z });
    const fxs: Handle[] = [];
    // The Catacomb Depths dress an elite in every affix it bears (a second, a third), each with its own tell.
    for (const affix of affixesOf(e)) switch (affix) {
      case 'bellTolled':
        // Bronze bell-ring pulse around the feet.
        fxs.push(this.effects.decal({ tex: fx.ring(), color: A.bell, x: e.x, z: e.z, r: 1.55 * e.scale, duration: 1e9, opacity: 0.6, pulse: 2.5, follow }));
        break;
      case 'hungering':
        // Olive slick where it slavers.
        fxs.push(this.effects.decal({ tex: fx.glow(), color: A.drool, x: e.x, z: e.z, r: 1.2 * e.scale, duration: 1e9, opacity: 0.45, follow }));
        break;
      case 'shrouded':
        // Grave-dusk pall; the body itself is dimmed in sync().
        fxs.push(this.effects.decal({ tex: fx.glow(), color: A.shroud, x: e.x, z: e.z, r: 1.5 * e.scale, duration: 1e9, opacity: 0.7, blending: THREE.NormalBlending, follow }));
        v.shroud = 1;
        break;
      case 'vengeful':
        // Ember cracks spreading under it.
        fxs.push(this.effects.decal({ tex: fx.cracks(), color: A.vengeful, x: e.x, z: e.z, r: 1.3 * e.scale, duration: 1e9, opacity: 0.75, pulse: 3, spin: 0.2, follow }));
        break;
    }
    v.affixFx = fxs;
  }

  /** Per-frame affix particles / shroud fade. */
  private tickAffix(v: View, e: Enemy, dt: number, nearFx: boolean) {
    const headY = HEAD_Y[ENEMIES[e.def].rig] * e.scale;
    for (const affix of affixesOf(e)) switch (affix) {
      case 'hungering':
        if (nearFx && Math.random() < dt * 4) {
          const f = v.facing;
          this.effects.emit({ x: e.x + Math.sin(f) * 0.3 * e.scale, y: headY, z: e.z + Math.cos(f) * 0.3 * e.scale, count: 1, color: A.drool, spread: 0.06, speed: 0.1, up: -0.3, life: 0.7, size: 0.13, gravity: 7 });
        }
        break;
      case 'vengeful':
        if (nearFx && Math.random() < dt * 3) {
          this.effects.emit({ x: e.x, y: 0.3 + Math.random() * headY, z: e.z, count: 1, color: A.vengeful, spread: 0.35 * e.scale, speed: 0.2, up: 1.1, life: 0.7, size: 0.12 });
        }
        break;
      case 'shrouded': {
        // Revealed (opaque) only while it stands in a player's Miasma — the slow flag rides the snapshot.
        const target = e.slowT > 0 ? 1 : 0.38;
        v.shroud = (v.shroud ?? 1) + (target - (v.shroud ?? 1)) * Math.min(1, dt * 6);
        v.c.setOpacity(v.shroud);
        if (nearFx && target < 1 && Math.random() < dt * 2) {
          this.effects.emitSmoke({ x: e.x, y: 0.4 + Math.random() * headY, z: e.z, count: 1, color: A.shroud, spread: 0.4 * e.scale, speed: 0.15, up: 0.4, life: 1.2, size: 0.9, shrink: -0.6 });
        }
        break;
      }
    }
  }

  private makeThrall(t: Thrall): View {
    const wraith = t.kind === 'wraith';
    const kindLook = THRALL_LOOK[t.kind];
    // Discipline legions have their own meshes; thralls raised from corpses (archers, mages, hounds, bearers) keep theirs.
    const legion = kindLook ? null : LEGION[t.kind === 'wraith' ? 'mourner' : (this.legionOf?.(t.owner) ?? '')];
    const look = kindLook;
    // The Legion kit dresses thralls raised from now on, the same ones that carry its stats.
    const kit = KIT_BODIES.has(t.kind) ? (this.kitOf?.(t.owner) ?? null) : null;
    // A kind this build does not know (a newer host's) is drawn as a plain skeleton rather than breaking the room.
    const c = new Creature(legion?.slug ?? THRALL_SLUG[t.kind] ?? 'skeleton_thrall', {
      gearTint: !!kit?.armor,
      tint: look?.tint ?? legion?.tint ?? (wraith ? 0xb9c4ff : 0xf4ecff),
      emissive: look?.emissive ?? legion?.emissive ?? (wraith ? 0x8f9ed1 : 0x1f8f86),
      emissiveIntensity: (wraith ? 1.1 : (look?.glow ?? legion?.glow ?? 0.18) + (t.empowered ? 0.22 : 0)) + (t.champion ? 0.35 : 0),
      spectral: wraith,
      scale: (kindLook?.scale ?? (t.kind === 'shieldbearer' ? 1.1 : 1)) * (t.champion ? LEGEND.championScale : 1),
      // Every thrall wears the friendly jade rim (your own a bit stronger than a co-op ally's); enemies never do.
      // A Legion Champion wears a gold rim instead of the jade one.
      rim: { color: t.champion ? 0xd9a441 : SPELL_FX.exhume.spirit, strength: t.champion ? 1.4 : this.isOwn?.(t.owner) === false ? THRALL_RIM_ALLY : THRALL_RIM_OWN },
    });
    // The kit weapon's metal colours the warriors' blade; the archer's bow and the bone mage's staff become the baked GLB props.
    const weapon = kit?.weapon ? gearTier(kit.weapon.itemId, kit.weapon.rarity) : null;
    const own = (prop: THREE.Group) => {
      // Props are private to one thrall: free them with it (Creature.dispose only knows its own body).
      const dispose = c.dispose.bind(c);
      c.dispose = () => { dispose(); disposeProp(prop); };
      return prop;
    };
    if ((t.kind === 'warrior' || t.kind === 'shieldbearer') && (!legion || legion.armed)) {
      // Blade carried up and forward; `follow` keeps it from whipping around with the wrist while walking.
      c.attach('R_Hand', weapon ? own(boneSword(weapon.color)) : boneSword(), new THREE.Vector3(0, 1, 0.55), 0.6);
      c.attach('L_Hand', roundShield(t.kind === 'shieldbearer' ? 0.5 : 0.32), new THREE.Vector3(0, 1, 0), 0.5);
    } else if (t.kind === 'archer') {
      const bow = boneBow();
      c.attach('L_Hand', kit?.weapon ? own(upgradeThrallProp(bow, 'bow', kit.weapon.itemId, kit.weapon.rarity)) : bow, new THREE.Vector3(0, 1, 0), 0.5);
    } else if (t.kind === 'bonemage') {
      const staff = boneStaff();
      c.attach('R_Hand', kit?.weapon ? own(upgradeThrallProp(staff, 'staff', kit.weapon.itemId, kit.weapon.rarity)) : staff, new THREE.Vector3(0, 1, 0.12), 0.15);
    }
    // Kit armour tints the torso and hands in the piece's metal colour, lightly (the thrall stays bone).
    if (kit?.armor) {
      const tier = gearTier(kit.armor.itemId, kit.armor.rarity);
      for (const region of ['chest', 'hands'] as const) c.setRegionTint(region, { color: tier.color, glow: tier.glow, strength: KIT_ARMOR_STRENGTH });
    }
    this.group.add(c.root);
    const v: View = { c, x: t.x, z: t.z, facing: t.facing, lastState: '', kind: t.kind, animSkip: 0, animDt: 0, float: wraith };
    v.ring = this.effects.decal({
      tex: fx.ring(),
      color: t.champion ? 0xd9a441 : wraith ? 0x8fb4ff : SPELL_FX.exhume.spirit,
      x: t.x,
      z: t.z,
      // Small on purpose: a big horde of thralls otherwise paints the whole floor.
      r: (kindLook?.ring ?? (t.kind === 'hound' ? 0.6 : 0.5)) * (t.champion ? 1.3 : 1),
      duration: 1e9,
      opacity: t.empowered ? 1 : 0.7,
      follow: () => ({ x: v.x + (v.ox ?? 0), z: v.z + (v.oz ?? 0) }),
    });
    return v;
  }

  /** Ember shedding and hit sparks for the Cinder Pyre's dead (cheap: a few particles per second, near the camera only). */
  private fireDead(e: Enemy, v: { x: number; z: number }, dt: number, struck: boolean) {
    const F = SPELL_FX.enemy;
    const s = e.scale;
    if (struck) {
      // Struck: sparks fly off the body and a puff of soot follows.
      const heavy = e.def === 'slag_brute';
      this.effects.emit({ x: e.x, y: 1.1 * s, z: e.z, count: heavy ? 14 : 9, color: F.emberCore, spread: 0.25, speed: heavy ? 4.2 : 3.2, up: 2, life: 0.55, size: 0.11, gravity: 9 });
      this.effects.emit({ x: e.x, y: 1.1 * s, z: e.z, count: 4, color: F.ember, spread: 0.3, speed: 1.6, up: 1.2, life: 0.7, size: 0.2, gravity: 4 });
      if (heavy) this.effects.emitSmoke({ x: e.x, y: 1.4, z: e.z, count: 2, color: F.emberDeep, spread: 0.4, speed: 0.6, up: 0.5, life: 0.8, size: 0.9, shrink: -0.5 });
    }
    switch (e.def) {
      case 'cinder_husk':
        // Embers lifting off the charred shoulders and ribs.
        if (Math.random() < dt * 7) this.effects.emit({ x: e.x, y: 0.9 + Math.random() * 0.9, z: e.z, count: 1, color: Math.random() < 0.6 ? F.ember : F.emberCore, spread: 0.3, speed: 0.15, up: 1.1, life: 0.9, size: 0.1, drag: 0.5 });
        break;
      case 'pyre_priest':
        // The censer at the hip smoulders; ash sifts from the sleeves. It flares while a coal is winding up.
        if (Math.random() < dt * (e.state === 'windup' ? 22 : 5)) this.effects.emit({ x: e.x, y: 0.9 * s, z: e.z, count: 1, color: F.emberCore, spread: 0.2, speed: 0.2, up: 1.2, life: 0.7, size: e.state === 'windup' ? 0.18 : 0.11, drag: 0.4 });
        if (Math.random() < dt * 2) this.effects.emitSmoke({ x: e.x, y: 1.5, z: e.z, count: 1, color: 0x8a8680, spread: 0.3, speed: 0.15, up: 0.3, life: 1.6, size: 0.7, shrink: -0.4 });
        break;
      case 'cinderhound':
        // A trail of sparks and a wisp of smoke behind a running hound.
        if (e.moving && Math.random() < dt * 14) this.effects.emit({ x: e.x, y: 0.35, z: e.z, count: 1, color: Math.random() < 0.5 ? F.ember : F.emberCore, spread: 0.15, speed: 0.4, up: 0.8, life: 0.55, size: 0.09, gravity: 2 });
        if (e.moving && Math.random() < dt * 4) this.effects.emitSmoke({ x: e.x, y: 0.5, z: e.z, count: 1, color: F.emberDeep, spread: 0.2, speed: 0.2, up: 0.3, life: 0.8, size: 0.6, shrink: -0.5 });
        break;
      case 'slag_brute':
        // Heat off the molten seams: big slow embers, heavy dark smoke.
        if (Math.random() < dt * 6) this.effects.emit({ x: e.x, y: 1 + Math.random() * 1.6, z: e.z, count: 1, color: F.ember, spread: 0.6, speed: 0.15, up: 1, life: 1.1, size: 0.16, drag: 0.5 });
        if (Math.random() < dt * 2.5) this.effects.emitSmoke({ x: e.x, y: 2.2, z: e.z, count: 1, color: F.emberDeep, spread: 0.4, speed: 0.2, up: 0.6, life: 1.6, size: 1.1, shrink: -0.4 });
        break;
    }
    void v;
  }

  /** The Fen's dead (cheap: a few particles a second, near the camera only): the wisp's marsh-light, the hag's drips, the sexton's water. */
  private fenDead(e: Enemy, dt: number, lift: number, id: number, v: View) {
    const T = 0x7fe0d0;
    switch (e.def) {
      case 'fen_wisp':
        if (Math.random() < dt * 9) this.effects.emit({ x: e.x, y: lift + 0.2 + Math.random() * 0.6, z: e.z, count: 1, color: Math.random() < 0.6 ? T : 0xeaffff, spread: 0.25, speed: 0.15, up: -0.2, life: 0.8, size: 0.12, drag: 0.6 });
        break;
      case 'bog_hag':
        if (Math.random() < dt * (e.state === 'windup' ? 20 : 3)) this.effects.emit({ x: e.x, y: 1 + Math.random() * 0.8, z: e.z, count: 1, color: e.state === 'windup' ? SPELL_FX.enemy.hex : 0x6fb4a8, spread: 0.3, speed: 0.2, up: e.state === 'windup' ? 1.2 : -0.4, life: 0.8, size: 0.14, gravity: e.state === 'windup' ? -0.3 : 5 });
        break;
      case 'drowned_sexton':
        if (Math.random() < dt * 6) this.effects.emit({ x: e.x + (Math.random() - 0.5) * 0.8, y: 1.6 * e.scale, z: e.z + (Math.random() - 0.5) * 0.8, count: 1, color: 0x3a5a54, spread: 0.1, speed: 0.1, up: -0.3, life: 0.6, size: 0.1, gravity: 9 });
        break;
      case 'mire_leech': {
        // Slither: a squirming squash-and-stretch on the static mesh (only while it moves).
        const w = Math.sin(performance.now() / 85 + id * 1.7) * (e.moving ? 1 : 0.25);
        const k = e.scale;
        v.c.root.scale.set(k * (1 + 0.12 * w), k * (1 - 0.09 * w), k * (1 + 0.1 * w));
        v.c.root.rotation.z = 0.12 * w;
        break;
      }
    }
  }

  onEvent(ev: SimEvent, lookupCorpseFacing?: (c: Corpse) => number) {
    switch (ev.t) {
      case 'spawn':
        this.effects.emitSmoke({ x: ev.x, y: 0.2, z: ev.z, count: 10, color: 0x2a2230, spread: 0.7, speed: 1, up: 0.9, life: 1.3, size: 1.2, shrink: -1 });
        this.effects.emit({ x: ev.x, y: 0.1, z: ev.z, count: 4, color: 0x5b2bb0, spread: 0.5, speed: 0.6, up: 1.4, life: 0.8, size: 0.24 });
        this.effects.decal({ tex: fx.cracks(), color: 0x7c3aed, x: ev.x, z: ev.z, r: ev.elite ? 1.6 : 1.1, rot: Math.random() * 6, duration: 2.2, opacity: 0.8, growFrom: 0.3 });
        break;
      case 'erupt': {
        // Barrow Ghoul surfaces: dirt and bone flung out of its ring.
        const dirt = SPELL_FX.enemy.dirt;
        this.effects.emit({ x: ev.x, y: 0.3, z: ev.z, count: 22, color: dirt, spread: ev.r * 0.5, speed: 3.2, up: 3, life: 0.7, size: 0.2, gravity: 10 });
        this.effects.emit({ x: ev.x, y: 0.4, z: ev.z, count: 8, color: 0xe0d6c2, spread: ev.r * 0.4, speed: 2.4, up: 2.6, life: 0.6, size: 0.12, gravity: 10 });
        this.effects.emitSmoke({ x: ev.x, y: 0.3, z: ev.z, count: 5, color: 0x2a1a10, spread: ev.r * 0.4, speed: 1, up: 0.6, life: 1, size: 1.1 });
        this.effects.decal({ tex: fx.cracks(), color: dirt, x: ev.x, z: ev.z, r: ev.r, rot: Math.random() * 6, duration: 1.6, opacity: 0.8, growFrom: 0.6, fadeOut: 0.5 });
        audio.play('burst', ev.x, ev.z);
        break;
      }
      case 'digIn': {
        const v = this.enemies.get(ev.id);
        v?.c.playOnce('dig', 1, BURROW.digS);
        this.effects.emitSmoke({ x: ev.x, y: 0.2, z: ev.z, count: 4, color: SPELL_FX.enemy.dirt, spread: 0.5, speed: 0.6, up: 0.4, life: 1, size: 0.9 });
        break;
      }
      case 'unbind': {
        // Lich Acolyte reaches for your fallen thrall: a curse-crimson tether and a sigil where it will rise.
        const curse = SPELL_FX.enemy.curse;
        this.effects.beam({ x: ev.x, y: 1.6, z: ev.z }, () => ({ x: ev.tx, y: 0.3, z: ev.tz }), curse, 0.06, UNBIND.delayS);
        this.effects.decal({ tex: fx.sigil(), color: curse, x: ev.tx, z: ev.tz, r: 1, duration: UNBIND.delayS + 0.3, opacity: 0.85, spin: 2.5, fadeOut: 0.3 });
        audio.play('raise', ev.tx, ev.tz);
        break;
      }
      case 'shieldBlock': {
        // Bell Templar: a bronze spark off the shield and a small toll.
        const v = this.enemies.get(ev.id);
        const f = v ? v.facing : 0;
        this.effects.emit({ x: ev.x + Math.sin(f) * 0.6, y: 1.1, z: ev.z + Math.cos(f) * 0.6, count: 8, color: SPELL_FX.enemy.toll, spread: 0.15, speed: 2.6, up: 0.8, life: 0.3, size: 0.12, gravity: 6 });
        audio.play('tollSmall', ev.x, ev.z);
        break;
      }
      case 'death': {
        const v = this.enemies.get(ev.id);
        if (!v) break;
        this.enemies.delete(ev.id);
        // The final blow sets a pale hit flash. This view becomes the corpse,
        // so it no longer receives enemy flash updates after leaving the map.
        v.c.flash = 0;
        if (v.mound) (v.mound.removeFromParent(), (v.mound = undefined), (v.c.root.visible = true));
        v.eliteAura?.kill();
        v.auraFx?.kill();
        killAffixFx(v);
        if (v.shroud !== undefined && v.shroud < 1) v.c.setOpacity(1);
        if (ev.def === 'wraith') {
          // A wraith leaves no body: it thins to mist and sinks away.
          this.effects.emit({ x: ev.x, y: 1.4, z: ev.z, count: 22, color: 0xb9cbe6, spread: 0.6, speed: 0.9, up: 1.2, life: 1.1, size: 0.3, drag: 1 });
          v.sinkT = 0;
          this.fading.push(v);
          break;
        }
        v.dieT = 0;
        if (!v.c.playOnce('death')) v.c.toppled = 0.0001;
        this.dying.push(v);
        this.effects.emitSmoke({ x: ev.x, y: 0.3, z: ev.z, count: 6, color: 0x3b3440, spread: 0.6, speed: 0.8, up: 0.4, life: 1, size: 1 });
        if (ev.elite) {
          this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 40, color: 0xb58cff, spread: 0.8, speed: 3, up: 2, life: 1.1, size: 0.35 });
          this.effects.lightFlash(ev.x, 1.5, ev.z, 0xa26bff, 25, 0.5);
        }
        break;
      }
      case 'corpse': {
        const c = ev.corpse;
        if (c.echoOwner) break;
        let best = -1;
        let bestD = 1.2;
        this.dying.forEach((v, i) => {
          const d = Math.hypot(v.x - c.x, v.z - c.z);
          if (v.def === c.enemy && d < bestD) {
            bestD = d;
            best = i;
          }
        });
        if (best >= 0) {
          const v = this.dying.splice(best, 1)[0];
          v.c.setCastShadow(false);
          this.corpses.set(c.id, v);
        } else {
          // Corpse without a dying body (a sacrificed thrall, or a late join): lay one down.
          const slug = ENEMY_SLUG[c.enemy];
          const cr = new Creature(slug, { tint: c.enemy === 'risen' ? 0x8a8078 : 0xffffff, castShadow: false });
          cr.root.position.set(c.x, 0, c.z);
          cr.root.rotation.y = lookupCorpseFacing?.(c) ?? c.facing;
          cr.root.scale.setScalar(c.scale);
          this.group.add(cr.root);
          const v: View = { c: cr, x: c.x, z: c.z, facing: c.facing, lastState: 'corpse', animSkip: 0, animDt: 0, dieT: 5, settleT: NO_SETTLE };
          const tryHold = () => {
            if (!cr.loaded) return void setTimeout(tryHold, 150);
            if (!cr.holdLastFrame('death')) cr.toppled = 1;
          };
          tryHold();
          v.c.setCastShadow(false);
          this.corpses.set(c.id, v);
        }
        if (c.kind === 'toxic') {
          this.effects.decal({ tex: fx.disc(), color: 0x6f8f3a, x: c.x, z: c.z, r: 2.4 * c.scale, duration: 5, opacity: 0.35, pulse: 6, growFrom: 0.6 });
        }
        if (c.kind !== 'resonant' && !this.corpseRings.get(c.id)?.alive) {
          // Every fresh corpse is a necromancer's resource, and a toppled body is dark on dark ground: a faint pale ring marks it
          // for the 26 s it lasts. Capped so a wipe of 40 bodies does not add 40 draw calls (resonant ones keep their own, brighter ring).
          let live = 0;
          for (const h of this.corpseRings.values()) if (h.alive) live++;
          // On the Fen's teal water the pale lilac ring vanished: there it is warm bone-ivory (the one hue the marsh does not have),
          // bigger and brighter, since the body sinks below the surface.
          const marsh = c.area === 'fen';
          if (live < CORPSE_MARKS_MAX) this.corpseRings.set(c.id, this.effects.decal({ tex: fx.ring(), color: marsh ? 0xffe6b0 : 0xd8cdf2, x: c.x, z: c.z, r: (marsh ? 1.1 : 0.8) * Math.max(1, c.scale), duration: 26, opacity: marsh ? 0.85 : 0.4, fadeIn: 0.8, pulse: 2 }));
        }
        if (c.kind === 'resonant') {
          if (!this.corpseRings.get(c.id)?.alive) {
            this.corpseRings.set(c.id, this.effects.decal({ tex: fx.ring(), color: 0xc6a4ff, x: c.x, z: c.z, r: 1.2, duration: 26, opacity: 0.6, pulse: 3 }));
          }
        }
        break;
      }
      case 'corpseGone': {
        this.corpseRings.get(ev.id)?.kill();
        this.corpseRings.delete(ev.id);
        const v = this.corpses.get(ev.id);
        if (!v) break;
        this.corpses.delete(ev.id);
        v.sinkT = 0;
        this.fading.push(v);
        if (ev.reason === 'consumed') {
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 22, color: SPELL_FX.exhume.spirit, spread: 0.6, speed: 0.8, up: 2.6, life: 0.9, size: 0.35 });
        } else if (ev.reason === 'litany') {
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 18, color: SPELL_FX.litany.core, spread: 0.6, speed: 0.8, up: 2.2, life: 0.8, size: 0.35 });
        } else if (ev.reason === 'raised') {
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 18, color: SPELL_FX.enemy.rot, spread: 0.6, speed: 0.8, up: 2, life: 1, size: 0.35 });
        } else if (ev.reason === 'devoured') {
          // Torn apart and swallowed: olive gore, no spirit left to rise.
          this.effects.emit({ x: v.x, y: 0.4, z: v.z, count: 22, color: A.drool, spread: 0.5, speed: 1.6, up: 1.4, life: 0.7, size: 0.26, gravity: 5 });
          this.effects.emitSmoke({ x: v.x, y: 0.3, z: v.z, count: 3, color: 0x2b3317, spread: 0.4, speed: 0.6, up: 0.4, life: 1, size: 1 });
        } else if (ev.reason === 'burst' && v.shattered) {
          // Corpse Explosion: the body is blown apart (the blast VFX plays from the 'detonated' event).
          v.c.setOpacity(0);
          v.sinkT = 0.8;
        } else if (ev.reason === 'burst') {
          this.effects.emit({ x: v.x, y: 0.5, z: v.z, count: 20, color: SPELL_FX.miasma.rot, spread: 0.6, speed: 2.5, up: 1.5, life: 0.7, size: 0.3 });
        }
        break;
      }
      case 'detonated': {
        if (!ev.ok) break;
        const v = this.corpses.get(ev.corpseId);
        if (v) v.shattered = true;
        break;
      }
      case 'affix':
        this.affixMoment(ev);
        break;
      case 'thrallGone': {
        const v = this.thralls.get(ev.id);
        if (!v) break;
        this.thralls.delete(ev.id);
        v.hexFx?.kill();
        v.ring?.kill();
        v.sinkT = 0;
        this.fading.push(v);
        this.effects.emit({ x: ev.x, y: 0.8, z: ev.z, count: ev.reason === 'sacrificed' ? 30 : 14, color: 0xd8cfbd, spread: 0.5, speed: 2, up: 1.2, life: 0.8, size: 0.25, gravity: 3 });
        // A thrall that falls comes apart: bone chips and a pale soul-light that lets go (quiet; thralls die constantly).
        if (ev.reason !== 'sacrificed') {
          nf.boneSplinters(this.effects, ev.x, 0.7, ev.z, { n: 4, origin: 'thrall' });
          nf.soulMotes(this.effects, ev.x, ev.z, 0xd8cfbd, { r: 0.3, n: 3, y: 0.6, up: 1.2, origin: 'thrall' });
        }
        break;
      }
      case 'thrall': {
        audio.play('thrallRise', ev.x, ev.z);
        const X = SPELL_FX.exhume;
        this.effects.decal({ tex: fx.sigil(), color: X.spirit, x: ev.x, z: ev.z, r: 1.4, duration: 1.3, opacity: 0.9, growFrom: 0.2, spin: 2 });
        this.effects.emit({ x: ev.x, y: 0.2, z: ev.z, count: 40, color: X.spirit, spread: 0.5, speed: 0.6, up: 3.6, life: 1, size: 0.36, gravity: -0.6 });
        this.effects.emit({ x: ev.x, y: 0.2, z: ev.z, count: 16, color: X.beam, spread: 0.3, speed: 0.3, up: 5, life: 0.7, size: 0.22 });
        this.effects.emitSmoke({ x: ev.x, y: 0.2, z: ev.z, count: 6, color: 0x1c2a2a, spread: 0.6, speed: 0.8, up: 0.8, life: 1.2, size: 1.2 });
        // Risen from the grave: soil breaks and settles. (The caster's Exhume already drew the hands and soul-light.)
        nf.graveDirt(this.effects, ev.x, ev.z, { r: 0.5, n: 6, up: 2.6, origin: 'thrall' });
        this.effects.lightFlash(ev.x, 1.2, ev.z, X.spirit, 22, 0.6);
        break;
      }
        break;
    }
  }

  /** One-off affix beats reported by the host. */
  private affixMoment(ev: Extract<SimEvent, { t: 'affix' }>) {
    const { x, z } = ev;
    switch (ev.affix) {
      case 'bellTolled': {
        const r = ev.r ?? 3;
        audio.play('toll', x, z);
        for (let k = 0; k < 3; k++) {
          this.effects.decal({ tex: fx.ring(), color: A.bell, x, z, r: r * (0.75 + k * 0.2), duration: 0.5, opacity: 1 - k * 0.25, growFrom: 0.15, delay: k * 0.07 });
        }
        this.effects.emit({ x, y: 0.8, z, count: 36, color: A.bell, spread: r * 0.3, speed: 5, up: 0.8, life: 0.5, size: 0.28 });
        this.effects.lightFlash(x, 1.5, z, A.bell, 30, 0.4);
        break;
      }
      case 'hungering': {
        const tx = ev.tx ?? x;
        const tz = ev.tz ?? z;
        audio.play('raise', tx, tz);
        this.effects.beam({ x: tx, y: 0.3, z: tz }, () => ({ x, y: 1.1, z }), A.drool, 0.07, 0.45);
        this.effects.emit({ x, y: 1.1, z, count: 14, color: A.drool, spread: 0.3, speed: 0.8, up: 0.4, life: 0.8, size: 0.2, gravity: 4 });
        break;
      }
      case 'vengeful': {
        const r = ev.r ?? 1.8;
        audio.play('burst', x, z);
        this.effects.decal({ tex: fx.cracks(), color: A.vengeful, x, z, r: r * 1.4, rot: Math.random() * 6, duration: 2, opacity: 0.9, growFrom: 0.3 });
        this.effects.decal({ tex: fx.ring(), color: D.ember, x, z, r, duration: 0.5, opacity: 1, growFrom: 0.2 });
        this.effects.emit({ x, y: 0.6, z, count: 40, color: A.vengeful, spread: 0.5, speed: 3.5, up: 2.2, life: 0.8, size: 0.3 });
        this.effects.emitSmoke({ x, y: 0.4, z, count: 6, color: D.smoke, spread: 0.8, speed: 1, up: 0.8, life: 1.2, size: 1.3 });
        this.effects.lightFlash(x, 1.2, z, A.vengeful, 32, 0.5);
        break;
      }
    }
  }

  private focusX = 0;
  private focusZ = 0;

  /**
   * React to hp lost since the last frame: a visual shove away from the hero (bigger for harder hits, smaller for heavy
   * bodies and for an enemy mid-swing) and, for a heavy blow that leaves the target standing, a hitstop request.
   */
  private onHit(v: View, e: Enemy, fx: number, fz: number, near: boolean) {
    const prev = v.lastHp ?? e.hp;
    v.lastHp = e.hp;
    const drop = prev - e.hp;
    if (drop <= 0 || !near || v.under || e.hp <= 0 || ENEMIES[e.def].inert) return;
    const frac = drop / Math.max(1, e.maxHp);
    const committed = e.state === 'windup' || e.state === 'channel';
    const imp = knockImpulse(frac * (committed ? 0.4 : 1), e.scale * e.scale, e.x - fx, e.z - fz);
    const k = (v.kn ??= { x: 0, z: 0, vx: 0, vz: 0 });
    k.vx += imp.vx;
    k.vz += imp.vz;
    if (frac >= (e.elite ? HEAVY_HIT_ELITE : HEAVY_HIT) && Math.hypot(e.x - fx, e.z - fz) < HITSTOP_RANGE) hitstop.request(Math.min(1, frac * 1.6));
  }

  /** Dust puff where a body lands. */
  private landingDust(v: View) {
    if (Math.abs(v.x - this.focusX) > 24 || Math.abs(v.z - this.focusZ) > 20) return;
    const k = v.c.root.scale.x;
    this.effects.emitSmoke({ x: v.x, y: 0.1, z: v.z, count: 3, color: 0x5d544a, spread: 0.45 * k, speed: 0.7, up: 0.25, life: 0.8, size: 0.9 * k });
    this.effects.emit({ x: v.x, y: 0.1, z: v.z, count: 5, color: 0x7a6f60, spread: 0.4 * k, speed: 1.1, up: 0.7, life: 0.4, size: 0.1, gravity: 8 });
  }

  /** Death settle: once the fall has mostly played the body lands (dust) and eases a little way into the ground. */
  private settle(v: View, dt: number) {
    if (v.settleT === undefined) {
      if (!v.c.hasLanded()) return;
      v.settleT = 0;
      v.settleY = v.c.toppled ? 0 : v.c.root.position.y;
      this.landingDust(v);
    }
    v.settleT += dt;
    const base = v.c.toppled ? v.c.root.position.y : (v.settleY ?? 0);
    v.c.root.position.y = base - settleDepth(v.settleT, SETTLE_DEPTH * v.c.root.scale.x);
  }

  private syncFacing(v: View, target: number, dt: number) {
    v.facing = turnToward(v.facing, target, dt, 10, ENEMY_TURN_RATE);
  }

  /**
   * Slide drawn bodies apart where the sim leaves them overlapping. Positions are the sim's; the offsets are eased and
   * capped, applied to the model roots only (decals follow via ox/oz), and never fed back into the sim.
   */
  private separateCrowd(enemies: Map<number, Enemy>, thralls: Map<number, Thrall>, dt: number, fx0: number, fz0: number) {
    const bodies = this.crowd;
    const views = this.crowdViews;
    let n = 0;
    views.length = 0;
    const add = (v: View, x: number, z: number, r: number, w: number) => {
      const b = (bodies[n] ??= { x: 0, z: 0, r: 0, w: 0 });
      b.x = x;
      b.z = z;
      b.r = r;
      b.w = w;
      n++;
      views.push(v);
    };
    // Body 0 is the hero: an obstacle that never yields.
    const hero = (bodies[0] ??= { x: 0, z: 0, r: 0, w: 0 });
    hero.x = fx0;
    hero.z = fz0;
    hero.r = 0.45;
    hero.w = 0;
    n = 1;
    const near = (x: number, z: number) => Math.abs(x - fx0) < 22 && Math.abs(z - fz0) < 18;
    for (const [id, e] of enemies) {
      const v = this.enemies.get(id);
      if (!v || v.under || e.state === 'rising' || e.state === 'burrow' || e.state === 'dead' || !near(e.x, e.z)) continue;
      if (n > MAX_CROWD) break;
      add(v, e.x, e.z, e.radius * CROWD_FOOTPRINT, ENEMIES[e.def].inert ? 0 : 1);
    }
    for (const [id, t] of thralls) {
      const v = this.thralls.get(id);
      if (!v || t.state === 'rising' || !near(t.x, t.z)) continue;
      if (n > MAX_CROWD) break;
      add(v, t.x, t.z, 0.4 * CROWD_FOOTPRINT * (THRALL_LOOK[t.kind]?.scale ?? (t.kind === 'shieldbearer' ? 1.1 : 1)), 0.8);
    }
    const out = this.crowdOut;
    separateBodies(bodies, out, { iterations: 2, maxOffset: 0.55 }, n);
    const k = Math.min(1, dt * CROWD_EASE);
    const seen = this.crowdSeen;
    seen.clear();
    for (let i = 1; i < n; i++) {
      const v = views[i - 1];
      seen.add(v);
      v.ox = (v.ox ?? 0) + (out[i * 2] - (v.ox ?? 0)) * k;
      v.oz = (v.oz ?? 0) + (out[i * 2 + 1] - (v.oz ?? 0)) * k;
      v.c.root.position.x += v.ox;
      v.c.root.position.z += v.oz;
    }
    // Bodies that left the crowd (far away, burrowed, rising) ease back to their sim spot.
    for (const map of [this.enemies, this.thralls]) {
      for (const v of map.values()) {
        if (seen.has(v) || (!v.ox && !v.oz)) continue;
        v.ox = (v.ox ?? 0) * (1 - k);
        v.oz = (v.oz ?? 0) * (1 - k);
        if (Math.abs(v.ox) < 1e-3 && Math.abs(v.oz) < 1e-3) v.ox = v.oz = 0;
        v.c.root.position.x += v.ox;
        v.c.root.position.z += v.oz;
      }
    }
  }

  /** Track a body's real ground speed (smoothed) from how far it moved this frame, for its stride playback. */
  private measureSpeed(v: View, x: number, z: number, dt: number) {
    const inst = stepSpeed(x - v.x, z - v.z, dt);
    v.gs = smoothSpeed(v.gs ?? inst, inst, dt, 0.18);
  }

  /** LOD: far creatures animate at a lower rate. */
  /** Shadow LOD: keep a bounded number of nearby enemy shadows, including elites. */
  private shadowLod(enemies: Map<number, Enemy>, fx0: number, fz0: number) {
    const ranked: { v: View; d: number }[] = [];
    for (const [id, e] of enemies) {
      const v = this.enemies.get(id);
      if (!v) continue;
      ranked.push({ v, d: (e.x - fx0) ** 2 + (e.z - fz0) ** 2 });
    }
    ranked.sort((a, b) => a.d - b.d);
    const budget = enemies.size >= 32 ? CROWDED_SHADOW_CASTERS : SHADOW_CASTERS;
    ranked.forEach((r, i) => r.v.c.setCastShadow(i < budget));
  }

  private tickAnim(v: View, dt: number, fx0: number, fz0: number, crowded: boolean) {
    // Keep nearby attacks fluid; distant bodies can share a lower animation rate
    // when a high Wave Speed tier has filled the room.
    const far = Math.abs(v.x - fx0) > 26 || Math.abs(v.z - fz0) > 22
      || (crowded && (Math.abs(v.x - fx0) > 14 || Math.abs(v.z - fz0) > 12));
    v.animDt += dt;
    if (far) {
      v.animSkip = (v.animSkip + 1) % 3;
      if (v.animSkip !== 0) return;
    }
    v.c.update(v.animDt);
    v.animDt = 0;
  }

  sync(
    enemies: Map<number, Enemy>,
    thralls: Map<number, Thrall>,
    dt: number,
    focusX: number,
    focusZ: number,
  ) {
    this.frame++;
    const crowded = enemies.size + thralls.size >= 32;
    wingClock.value = performance.now() / 1000;
    if (this.frame % 10 === 0) this.shadowLod(enemies, focusX, focusZ);
    for (const [id, e] of enemies) {
      let v = this.enemies.get(id);
      if (!v) {
        v = this.makeEnemy(e);
        this.enemies.set(id, v);
      }
      this.measureSpeed(v, e.x, e.z, dt);
      v.x = e.x;
      v.z = e.z;
      this.syncFacing(v, e.facing, dt);
      const rise = e.state === 'rising' ? Math.min(1, e.stateT / 1.1) : 1;
      const def = ENEMIES[e.def];
      const hover = def.flying ?? HOVER[e.def];
      let lift = hover ? hover + Math.sin(performance.now() / 520 + id) * (def.flying ? 0.18 : 0.12) : 0;
      if (def.dive && e.diving) {
        // Belfry Gargoyle dive: climb over the mark for the first half, then drop onto it.
        const k = Math.min(1, e.stateT / ((def.windupMs / 1000) * (e.elite ? 0.85 : 1)));
        lift = k < 0.5 ? hover! + k * 3 : (hover! + 1.5) * (1 - (k - 0.5) * 2) ** 2;
      } else if (def.dive && e.state === 'recover') lift = 0.05; // grounded in the rubble
      v.c.root.position.set(e.x, -1.7 * (1 - rise) * (1 - rise) + lift, e.z);
      v.c.root.rotation.y = v.facing;
      v.c.flash = e.flash;
      const key = e.diving ? 'dive' : e.state === 'windup' || e.state === 'channel' ? e.state : e.moving ? 'walk' : 'idle';
      if (key !== v.lastState) {
        if (key === 'dive') v.c.playOnce('dive', 1, (def.windupMs / 1000) * 1.2);
        else if (key === 'windup' || key === 'channel') {
          const cast = CASTERS.has(e.def);
          // The sim lands the blow when the wind-up ends: time the swing's impact frame to it.
          if (key === 'windup') v.c.playStrike(cast ? 'cast' : 'attack', (def.windupMs / 1000) * (e.elite ? 0.85 : 1));
          else v.c.playOnce(cast ? 'cast' : 'attack', cast ? 1.3 : 1.6);
        } else if (key === 'walk') {
          v.gs = e.speed; // start the legs at the pace the sim is about to move the body
          v.c.setGroundSpeed(e.speed);
        } else v.c.setLoop('idle');
        v.lastState = key;
      } else if (key === 'walk') v.c.setGroundSpeed(v.gs ?? e.speed);
      const nearFx = Math.abs(e.x - focusX) < 24 && Math.abs(e.z - focusZ) < 20;
      // A fresh hit makes the body flinch: a short additive hit-react laid over the running animation, so a
      // flinch never cuts a stride or a swing. Throttled per enemy, near the camera only.
      const fresh = e.flash > 0.9 && (v.lastFlash ?? 0) < 0.5;
      v.lastFlash = e.flash;
      this.onHit(v, e, focusX, focusZ, nearFx);
      if (fresh && nearFx && !v.under && performance.now() >= (v.flinchAt ?? 0) && v.c.has('hurt')) {
        v.flinchAt = performance.now() + 700;
        v.c.flinch();
      }
      this.tickAnim(v, dt, focusX, focusZ, crowded);
      if (nearFx && FIRE_DEAD.has(e.def)) this.fireDead(e, v, dt, fresh);
      if (nearFx && FEN_DEAD.has(e.def)) this.fenDead(e, dt, lift, id, v);
      if (nearFx && e.withered > 0 && Math.random() < dt * (1 + e.withered * 0.75)) {
        this.effects.emit({ x: e.x, y: 0.8 + Math.random() * 0.8, z: e.z, count: 1, color: SPELL_FX.miasma.rot, spread: 0.4, speed: 0.2, up: 0.7, life: 0.9, size: 0.2 });
      }
      if (nearFx && e.fracture > 0 && Math.random() < dt * 1.5 * e.fracture) {
        this.effects.emit({ x: e.x, y: 1.2, z: e.z, count: 1, color: SPELL_FX.needle.dust, spread: 0.3, speed: 0.6, up: 0.4, life: 0.5, size: 0.1, gravity: 5 });
      }
      // Status tells: marrow drips, frost motes, a priest-gold glint.
      if (nearFx && (e.bleedT ?? 0) > 0 && Math.random() < dt * 4) {
        this.effects.emit({ x: e.x, y: 0.7 + Math.random() * 0.6, z: e.z, count: 1, color: Math.random() < 0.7 ? STATUS_FX.hemorrhage.crimson : STATUS_FX.hemorrhage.ember, spread: 0.3, speed: 0.1, up: -0.2, life: 0.6, size: 0.12, gravity: 8 });
      }
      if (nearFx && (e.chillT ?? 0) > 0 && Math.random() < dt * 3) {
        this.effects.emit({ x: e.x, y: 0.3 + Math.random() * 1.2, z: e.z, count: 1, color: STATUS_FX.chill.frost, spread: 0.45, speed: 0.15, up: 0.2, life: 0.8, size: 0.14, drag: 0.5 });
      }
      if (nearFx && (e.sanctT ?? 0) > 0 && Math.random() < dt * 2) {
        this.effects.emit({ x: e.x, y: 1.9 * e.scale, z: e.z, count: 1, color: STATUS_FX.sanctified.gold, spread: 0.35, speed: 0.1, up: 0.5, life: 0.7, size: 0.16 });
      }
      // A frenzied Flagellant sheds blood motes (hp below half; mirrors see the same hp).
      if (nearFx && ENEMIES[e.def].frenzy && e.hp < e.maxHp * 0.5 && Math.random() < dt * 5) {
        this.effects.emit({ x: e.x, y: 1.1, z: e.z, count: 1, color: 0x9a1b2a, spread: 0.3, speed: 0.4, up: 0.4, life: 0.5, size: 0.14, gravity: 6 });
      }
      // Incensed (a Censer Bearer's aura): bronze motes drifting off the shoulders.
      if (nearFx && (e.incenseT ?? 0) > 0 && Math.random() < dt * 3) {
        this.effects.emit({ x: e.x, y: 1.2 * e.scale, z: e.z, count: 1, color: STATUS_FX.incensed.bronze, spread: 0.4, speed: 0.2, up: 0.6, life: 0.8, size: 0.14 });
      }
      // The Censer Bearer itself trails incense smoke and wears its aura on the ground.
      if (ENEMIES[e.def].aura) {
        if (!v.auraFx) v.auraFx = this.effects.decal({ tex: fx.ring(), color: STATUS_FX.incensed.bronze, x: e.x, z: e.z, r: CENSER.radius, duration: 1e9, opacity: 0.22, pulse: 2.5, follow: () => ({ x: v!.x + (v!.ox ?? 0), z: v!.z + (v!.oz ?? 0) }) });
        if (nearFx && Math.random() < dt * 2) this.effects.emitSmoke({ x: e.x, y: 1.1, z: e.z, count: 1, color: STATUS_FX.incensed.smoke, spread: 0.3, speed: 0.3, up: 0.5, life: 1.4, size: 0.9, shrink: -0.5 });
      }
      if (nearFx && hover && Math.random() < dt * 4) {
        this.effects.emit({ x: e.x, y: lift + 0.2, z: e.z, count: 1, color: 0xb9cbe6, spread: 0.35, speed: 0.1, up: -0.3, life: 0.7, size: 0.18 });
      }
      // Barrow Ghoul: underground from 'burrow' until its eruption windup ends (the mirror sees only states).
      if (e.state === 'burrow') v.under = true;
      else if (v.under && e.state !== 'windup') v.under = false;
      if (v.under) {
        if (!v.mound) this.group.add((v.mound = makeMound()));
        v.mound.position.set(e.x, 0, e.z);
        v.mound.rotation.y = v.facing;
        v.c.root.visible = false;
        if (nearFx && e.moving && Math.random() < dt * 7) {
          this.effects.emit({ x: e.x, y: 0.15, z: e.z, count: 2, color: SPELL_FX.enemy.dirt, spread: 0.35, speed: 0.9, up: 1.2, life: 0.4, size: 0.12, gravity: 9 });
        }
      } else if (v.mound) {
        v.mound.removeFromParent();
        v.mound = undefined;
        v.c.root.visible = true;
      }
      // Lich Acolyte: its crimson reach shows only while one of your thralls stands inside it.
      if (ENEMIES[e.def].unbind) {
        let near = false;
        for (const t of thralls.values()) if (Math.abs(t.x - e.x) < UNBIND.range && Math.hypot(t.x - e.x, t.z - e.z) <= UNBIND.range) { near = true; break; }
        if (near && !v.auraFx) v.auraFx = this.effects.decal({ tex: fx.ring(), color: SPELL_FX.enemy.curse, x: e.x, z: e.z, r: UNBIND.range, duration: 1e9, opacity: 0.15, pulse: 1.5, follow: () => ({ x: v!.x + (v!.ox ?? 0), z: v!.z + (v!.oz ?? 0) }) });
        else if (!near && v.auraFx) (v.auraFx.kill(), (v.auraFx = undefined));
      }
      if (nearFx && e.state === 'rising' && Math.random() < dt * 8) {
        this.effects.emitSmoke({ x: e.x, y: 0.1, z: e.z, count: 1, color: 0x2a2230, spread: 0.5, speed: 0.5, up: 0.6, life: 1, size: 0.9 });
      }
      // A mirror may learn the affix after the view exists (late snapshot field).
      if (e.affix && !v.affix) this.dressAffix(v, e);
      if (v.affix) this.tickAffix(v, e, dt, nearFx);
    }
    // Enemies that vanished without a death event (mirror resync, area clear).
    for (const [id, v] of this.enemies) {
      if (!enemies.has(id)) {
        this.enemies.delete(id);
        if (v.mound) (v.mound.removeFromParent(), (v.mound = undefined));
        v.eliteAura?.kill();
        v.auraFx?.kill();
        killAffixFx(v);
        v.sinkT = 0;
        this.fading.push(v);
      }
    }

    for (const [id, t] of thralls) {
      let v = this.thralls.get(id);
      if (!v) {
        v = this.makeThrall(t);
        this.thralls.set(id, v);
      }
      this.measureSpeed(v, t.x, t.z, dt);
      v.x = t.x;
      v.z = t.z;
      this.syncFacing(v, t.facing, dt);
      const rise = t.state === 'rising' ? Math.min(1, t.stateT / 0.9) : 1;
      const hover = v.float ? 0.25 + Math.sin(performance.now() / 400 + id) * 0.1 : 0;
      v.c.root.position.set(t.x, -1.8 * (1 - rise) * (1 - rise) + hover, t.z);
      v.c.root.rotation.y = v.facing;
      v.c.flash = t.flash;
      const key = t.state === 'attack' && t.stateT < 0.1 ? 'attack' : t.moving ? 'move' : 'idle';
      // A thrall's hit applies the instant its attack starts: open the swing just before its impact frame.
      if (key === 'attack' && v.lastState !== 'attack') v.c.playStrike('attack', 0.12);
      else if (key === 'move' && v.lastState !== 'move') {
        v.gs = t.speed;
        v.c.setGroundSpeed(t.speed);
      } else if (key === 'move') v.c.setGroundSpeed(v.gs ?? t.speed);
      else if (key === 'idle' && v.lastState !== 'idle') v.c.setLoop('idle');
      v.lastState = key;
      // A Bog Hag's hex: a magenta sigil ring follows the thrall and sickly motes drip off it while it lasts.
      if ((t.cursedT ?? 0) > 0) {
        if (!v.hexFx?.alive) v.hexFx = this.effects.decal({ tex: fx.sigil(), color: SPELL_FX.enemy.hex, x: t.x, z: t.z, r: 0.95, duration: 1e9, opacity: 0.9, spin: 2, follow: () => ({ x: v!.x + (v!.ox ?? 0), z: v!.z + (v!.oz ?? 0) }) });
        if (Math.abs(t.x - focusX) < 24 && Math.abs(t.z - focusZ) < 20 && Math.random() < dt * 5) this.effects.emit({ x: t.x, y: 0.9 + Math.random() * 0.8, z: t.z, count: 1, color: SPELL_FX.enemy.hex, spread: 0.25, speed: 0.15, up: -0.5, life: 0.7, size: 0.12, gravity: 4 });
      } else if (v.hexFx) {
        v.hexFx.kill();
        v.hexFx = undefined;
      }
      this.tickAnim(v, dt, focusX, focusZ, crowded);
    }
    for (const [id, v] of this.thralls) {
      if (!thralls.has(id)) {
        this.thralls.delete(id);
        v.hexFx?.kill();
        v.ring?.kill();
        v.sinkT = 0;
        this.fading.push(v);
      }
    }

    this.separateCrowd(enemies, thralls, dt, focusX, focusZ);
    this.focusX = focusX;
    this.focusZ = focusZ;
    // Knockback springs ride on top of the crowd offset (drawn position only), frozen along with everything else in a hitstop.
    for (const v of this.enemies.values()) {
      if (!v.kn || !knockActive(v.kn)) continue;
      stepKnock(v.kn, dt * hitstop.scale);
      v.c.root.position.x += v.kn.x;
      v.c.root.position.z += v.kn.z;
    }

    for (let i = this.dying.length - 1; i >= 0; i--) {
      const v = this.dying[i];
      v.dieT! += dt;
      v.c.update(dt);
      this.topple(v, dt);
      this.settle(v, dt);
      // No corpse arrived (corpse kind "none"): crumble away.
      if (v.dieT! > 1.4) {
        this.dying.splice(i, 1);
        v.sinkT = 0;
        this.fading.push(v);
      }
    }
    for (const v of this.corpses.values()) {
      if ((v.dieT = (v.dieT ?? 0) + dt) < CORPSE_ANIM_S) v.c.update(dt);
      this.topple(v, dt);
      if (v.settleT !== NO_SETTLE) this.settle(v, dt);
    }
    for (let i = this.fading.length - 1; i >= 0; i--) {
      const v = this.fading[i];
      v.sinkT! += dt;
      v.c.root.position.y -= dt * 1.3;
      v.c.setOpacity(Math.max(0, 1 - v.sinkT! / 0.9));
      if (v.sinkT! > 0.9) {
        v.c.dispose();
        this.fading.splice(i, 1);
      }
    }
  }

  /** Drop corpse bodies the authority no longer has (resync after migration / drift). */
  pruneCorpses(valid: Map<number, unknown>) {
    for (const [id, v] of this.corpses) {
      if (valid.has(id)) continue;
      this.corpses.delete(id);
      v.sinkT = 0;
      this.fading.push(v);
    }
  }

  /** Models without a death clip tip over onto their side. */
  private topple(v: View, dt: number) {
    if (!v.c.toppled) return;
    v.c.toppled = Math.min(1, v.c.toppled + dt * 3);
    v.c.root.rotation.z = (Math.PI / 2) * v.c.toppled;
    v.c.root.position.y = 0.2 * v.c.toppled;
  }

  /** Screen-space enemy picking helper: world positions of live enemies. */
  enemyAnchor(id: number): THREE.Vector3 | null {
    const v = this.enemies.get(id);
    return v ? new THREE.Vector3(v.x, 1, v.z) : null;
  }

  counts() {
    return { enemies: this.enemies.size, thralls: this.thralls.size, corpses: this.corpses.size, dying: this.dying.length, fading: this.fading.length };
  }

  dispose() {
    for (const h of this.corpseRings.values()) h.kill();
    this.corpseRings.clear();
    for (const map of [this.enemies, this.thralls, this.corpses]) for (const v of map.values()) v.c.dispose();
    for (const v of [...this.dying, ...this.fading]) v.c.dispose();
    this.group.removeFromParent();
  }
}

/** Loads and warms one body (clone, shader programs, textures) with the variant flags the real spawn uses, then frees the clone. */
async function warmBody(slug: CreatureSlug, opts: ConstructorParameters<typeof Creature>[1]) {
  const c = new Creature(slug, opts);
  await c.ready;
  c.dispose();
}

const preloaded = new Set<string>();

/**
 * Background-warms the models an area will spawn (its roster, its boss, and the player's legion) so the first wave's
 * first draw of each type is already cheap. One body at a time, when the browser is idle; each type once per session.
 * Returns a cancel function.
 */
export function preloadAreaModels(area: AreaId, legion?: DisciplineId | null): () => void {
  const tasks: (() => Promise<void>)[] = [];
  const add = (key: string, slug: CreatureSlug, opts: ConstructorParameters<typeof Creature>[1]) => {
    if (preloaded.has(key)) return;
    preloaded.add(key);
    tasks.push(() => warmBody(slug, opts));
  };
  for (const { id } of AREAS[area].enemies) {
    add(`enemy:${id}`, ENEMY_SLUG[id], { spectral: id === 'wraith', fallback: ENEMY_FALLBACK[id], wings: WINGS[id] });
  }
  for (const b of Object.values(BOSSES)) if (b.area === area) add(`boss:${b.modelSlug}`, b.modelSlug, { fallback: 'prelate' });
  // Thralls wear the jade rim; the discipline's own legion body, then the plain skeleton it shares with raised dead.
  const rim = { color: SPELL_FX.exhume.spirit, strength: THRALL_RIM_OWN };
  const legionSlug = legion ? LEGION[legion]?.slug : undefined;
  if (legionSlug) add(`thrall:${legionSlug}`, legionSlug, { rim });
  add('thrall:skeleton_thrall', 'skeleton_thrall', { rim });
  return runIdleSequence(tasks);
}
