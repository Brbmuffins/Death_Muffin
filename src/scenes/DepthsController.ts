import type * as THREE from 'three';
import { DEPTHS_STAIR, type Interactable } from '../content/areas';
import { DEPTHS, depthEnemyLevel, depthLootArea, depthsEntryBlock, extraAffixes, hasChest } from '../content/depths';
import { ITEMS } from '../content/items';
import type { DepthsFloor } from '../gameplay/depthsFloor';
import { rollChest, rollFloorClear } from '../gameplay/depthsRewards';
import type { LootDrop } from '../gameplay/loot';
import type { FloorClear } from '../gameplay/killRules';
import type { Nav } from '../gameplay/nav';
import type { DepthsRun, SimEvent } from '../gameplay/sim/types';
import type { WorldSim } from '../gameplay/sim/WorldSim';
import type { Chronicle } from '../gameplay/chronicle';
import type { DropSource } from '../gameplay/affixRules';
import type { Player } from '../gameplay/Player';
import { DepthsView } from '../graphics/DepthsView';
import type { WorldView } from '../graphics/WorldView';
import type { Effects } from '../graphics/Effects';
import type { LootView } from '../graphics/LootView';
import type { CameraRig } from '../graphics/CameraRig';
import type { FloatingText } from '../ui/FloatingText';
import type { HUD } from '../ui/HUD';
import type { TipId } from '../ui/Onboarding';
import { audio } from '../audio/Audio';
import { StairView } from '../graphics/StairView';

/** What the controller needs from the scene (kept narrow so the 5,000-line scene stays the scene). */
export interface DepthsHost {
  scene: THREE.Scene;
  nav: Nav;
  worldView: WorldView;
  player: Player;
  hud: HUD;
  effects: Effects;
  floating: FloatingText;
  loot: LootView;
  rig: CameraRig;
  chronicle: Chronicle;
  sim: () => WorldSim | null;
  selfId: () => string;
  /** Other players in the world right now (a run is solo: a friend appearing mid-run closes the stair). */
  partySize: () => number;
  /** The hero belongs to a party world (not their own solo one). */
  inParty: () => boolean;
  /** Leave the party's world for the descent: this client becomes the keeper of its own, so the run can start. Synchronous. */
  stepOutOfParty: () => void;
  /** The run is over: rejoin the party stepped out of (a no-op if none). */
  stepBackIntoParty: () => void;
  level: () => number;
  /** The hero's discipline: the floor's and the chest's gear lean to its own armour set (loot.ts smart loot). */
  disciplineId?: () => string | undefined;
  /** Ascension rank times the week's Omen: what every kill's gold and XP is multiplied by. */
  rewardMult: () => number;
  teleportTo: (x: number, z: number) => void;
  dropItems: (x: number, z: number, items: LootDrop[], level: number, source: DropSource) => void;
  gainXp: (xp: number, x: number, z: number) => void;
  giveGold: (x: number, z: number, amount: number) => void;
  /** Server authority step 2: tell the server a floor was cleared and/or its chest opened (it pays the bonus out of the ledger and proves the depth). */
  reportFloor: (f: FloorClear) => void;
  tip: (id: TipId, delayMs?: number, opts?: boolean | { kind?: 'urgent' | 'danger' | 'asked' | 'calm'; bump?: boolean }) => void;
}

export type RunEnd = 'left' | 'died' | 'party' | 'recalled';

export interface DepthsHud {
  depth: number;
  kills: number;
  need: number;
  open: boolean;
  chest: boolean;
}

export interface DepthsMapFloor {
  rooms: { x0: number; z0: number; x1: number; z1: number; active: boolean }[];
  doors: { x: number; z: number; wall: 'x' | 'z' }[];
  down: { x: number; z: number; open: boolean };
  up: { x: number; z: number };
  chest: { x: number; z: number } | null;
}

const NEAR_STAIR_TIP = 9;
/** The exit asks twice (a stray click beside the way in must not end a run). */
const LEAVE_CONFIRM_MS = 5000;

/**
 * The Catacomb Depths as the scene sees them: entering by the Warren's stair, the floor's picture, its stairs and chest as things
 * you click, the rewards, the readout, and ending the run. The rules live in the sim (WorldSim.startDepths and friends) and the
 * pure modules (content/depths.ts, gameplay/depthsFloor.ts, gameplay/depthsRewards.ts); this only wires them to the screen.
 */
export class DepthsController {
  private view: DepthsView;
  private warrenStair: StairView;
  /** The run's loose ends that only the screen cares about. */
  private chestOpened = false;
  private leaveArmedUntil = 0;
  private lastStairOpen = false;
  private over = false;
  private endNote: string | null = null;
  private now = 0;
  private nearT = 0;

  constructor(private host: DepthsHost) {
    this.view = new DepthsView(host.scene, host.worldView.lightSources);
    this.warrenStair = new StairView('warren', DEPTHS_STAIR.x, DEPTHS_STAIR.z);
    host.scene.add(this.warrenStair.group);
    host.nav.addObstacle({ kind: 'circle', x: DEPTHS_STAIR.x, z: DEPTHS_STAIR.z, r: 0.9 });
    host.worldView.lightSources.push({ x: DEPTHS_STAIR.x, y: 1.4, z: DEPTHS_STAIR.z, color: 0xffb347, intensity: 8, distance: 10, lit: true, brazier: false });
  }

  // --- State ---------------------------------------------------------------------------------------------------------------------

  get run(): DepthsRun | null {
    return this.host.sim()?.depths ?? null;
  }

  /** A run is on (the hero is on a floor, alive or just fallen). */
  get active(): boolean {
    return this.run !== null;
  }

  get floor(): DepthsFloor | null {
    return this.host.nav.depthsFloor;
  }

  /** Why the stair will not take you down right now, or null if it will. */
  canEnter(): string | null {
    return depthsEntryBlock({ alive: this.host.player.alive });
  }

  /** The hover line for each stair, chest and exit. */
  prompt(it: Interactable): string {
    const run = this.run;
    switch (it.kind) {
      case 'stair': {
        const why = this.canEnter();
        if (why) return why;
        return this.host.inParty() ? 'Descend into the Catacomb Depths (you step out of your party until the run ends)' : 'Descend into the Catacomb Depths';
      }
      case 'depths_down':
        if (!run) return '';
        return run.stairOpen ? `Descend to depth ${run.depth + 1}` : `The stair is sealed: slay ${Math.max(0, run.need - run.kills)} more`;
      case 'depths_up':
        return `Climb out (ends this run at depth ${run?.depth ?? 1})`;
      case 'depths_chest':
        return 'Open the chest';
      default:
        return '';
    }
  }

  /** The stair, the way up and the chest of this floor as things to click. */
  interactables(): Interactable[] {
    const f = this.floor;
    if (!f || !this.run || this.over) return [];
    const out: Interactable[] = [
      { id: 'depths_up', kind: 'depths_up', label: 'The Way Up', x: f.stairUp.x, z: f.stairUp.z },
      { id: 'depths_down', kind: 'depths_down', label: 'The Stair Down', x: f.stairDown.x, z: f.stairDown.z },
    ];
    if (f.chest && !this.chestOpened) out.push({ id: 'depths_chest', kind: 'depths_chest', label: 'A Chest', x: f.chest.x, z: f.chest.z });
    return out;
  }

  hudState(): DepthsHud | null {
    const run = this.run;
    if (!run) return null;
    return { depth: run.depth, kills: Math.min(run.kills, run.need), need: run.need, open: run.stairOpen, chest: !!this.floor?.chest && !this.chestOpened };
  }

  /** What the minimap draws instead of the whole Depths rectangle. */
  mapFloor(): DepthsMapFloor | null {
    const f = this.floor;
    const run = this.run;
    if (!f || !run) return null;
    return {
      rooms: f.rooms.map((r) => ({ ...r.rect, active: r.active })),
      doors: f.doors.map((d) => ({ x: d.x, z: d.z, wall: d.wall })),
      down: { x: f.stairDown.x, z: f.stairDown.z, open: run.stairOpen },
      up: { x: f.stairUp.x, z: f.stairUp.z },
      chest: f.chest && !this.chestOpened ? { x: f.chest.x, z: f.chest.z } : null,
    };
  }

  /** A one-line status for the area line under the minimap. */
  progressLine(): string {
    const run = this.run;
    if (!run) return '';
    const lvl = this.host.sim()?.areaLevel('depths') ?? depthEnemyLevel(run.depth, this.host.level());
    const extras = extraAffixes(run.depth);
    return `Level <b>${lvl}</b> dead${extras ? ` · elites bear <b>${extras + 1}</b> affixes` : ''}`;
  }

  // --- Entering, descending, leaving ----------------------------------------------------------------------------------------------

  /** Click the Warren's stair: start a run on depth 1. */
  enter(seed = (Math.random() * 0x100000000) >>> 0, depth = 1): boolean {
    const why = this.canEnter();
    if (why) {
      this.host.hud.toast(why, 'err');
      audio.play('error');
      return false;
    }
    // A party member goes down alone: step out of the party first (this makes us the keeper of our own world).
    const party = this.host.inParty();
    if (party) {
      this.host.stepOutOfParty();
      this.host.tip('depths_solo', 600, { kind: 'asked' });
    }
    const sim = this.host.sim();
    if (!sim || sim.depths) {
      if (party) this.host.stepBackIntoParty();
      if (!sim) {
        this.host.hud.toast('The stair is dark.', 'err');
        audio.play('error');
      }
      return false;
    }
    this.chestOpened = false;
    this.over = false;
    this.endNote = null;
    this.lastStairOpen = false;
    this.leaveArmedUntil = 0;
    const floor = sim.startDepths(this.host.selfId(), seed, depth);
    this.view.load(floor);
    this.host.chronicle.add('depths.runs');
    this.host.chronicle.max('peak.depth', depth);
    this.arrive(floor, 'You go down');
    this.host.tip('depths_floor', 1800, { kind: 'asked' });
    return true;
  }

  /** The stair down was clicked. */
  descend(): boolean {
    const run = this.run;
    const sim = this.host.sim();
    if (!run || !sim || this.over) return false;
    if (!run.stairOpen) {
      this.host.hud.toast(`The stair is sealed: slay ${Math.max(0, run.need - run.kills)} more of the dead.`, 'err');
      audio.play('error');
      return false;
    }
    const floor = sim.descendDepths();
    if (!floor) return false;
    this.chestOpened = false;
    this.lastStairOpen = false;
    this.view.load(floor);
    this.host.chronicle.max('peak.depth', sim.depths!.depth);
    this.arrive(floor, 'You descend');
    return true;
  }

  /** The exit: asks twice, then ends the run and puts you back at the Warren's stair. */
  leave(): boolean {
    if (!this.run || this.over) return false;
    if (this.now > this.leaveArmedUntil) {
      this.leaveArmedUntil = this.now + LEAVE_CONFIRM_MS;
      this.host.hud.toast(`Climbing out ends this run at depth ${this.run.depth} (what you looted is yours). Click again to leave.`);
      audio.play('click');
      return false;
    }
    this.end('left');
    this.host.teleportTo(DEPTHS_STAIR.x, DEPTHS_STAIR.z + 2.3);
    return true;
  }

  /** Put the hero on a new floor with the legion, face north, say where they are. */
  private arrive(floor: DepthsFloor, verb: string) {
    const run = this.run!;
    const sim = this.host.sim()!;
    this.host.teleportTo(floor.start.x, floor.start.z);
    this.host.player.facing = Math.PI;
    this.host.rig.snap(floor.start.x, floor.start.z);
    this.view.setStairOpen(false);
    this.view.setChestOpened(false);
    const lvl = sim.areaLevel('depths');
    const extras = extraAffixes(run.depth);
    this.host.hud.banner(
      `Depth ${run.depth}`,
      `${verb} · slay ${run.need} · level ${lvl} dead${extras ? ` · elites bear ${extras + 1} affixes` : ''}${floor.chest ? ' · a chest waits' : ''}`,
      DEPTHS.bannerMs,
    );
    audio.play('gate', floor.start.x, floor.start.z);
    this.host.effects.lightFlash(floor.start.x, 3, floor.start.z, 0xffb347, 40, 1.2);
    if (extras > 0) this.host.tip('depths_affix', 2500, { kind: 'asked' });
  }

  // --- Events and frame ------------------------------------------------------------------------------------------------------------

  /** Called with every sim event (the scene's handleEvent). */
  onEvent(ev: SimEvent) {
    if (ev.t === 'depthsClear') this.cleared(ev.depth, ev.x, ev.z);
  }

  /** The floor's quota is met: the stair opens and the floor pays. */
  private cleared(depth: number, x: number, z: number) {
    const sim = this.host.sim();
    if (!sim || this.over || !this.host.player.alive) return;
    this.view.setStairOpen(true);
    this.lastStairOpen = true;
    const level = sim.areaLevel('depths');
    const mult = this.host.rewardMult();
    const win = rollFloorClear(depth, level, Math.random, this.host.disciplineId?.());
    const gold = Math.round(win.gold * mult);
    const xp = Math.round(win.xp * mult);
    this.host.reportFloor({ depth, level, clear: true, chest: false, mult });
    this.host.giveGold(x, z + 1.2, gold);
    this.host.gainXp(xp, x, z);
    if (win.drop) this.host.dropItems(x, z + 1.8, [win.drop], level, 'surge');
    this.host.chronicle.add('depths.floors');
    this.host.hud.banner('The stair opens', `Depth ${depth} cleared · +${gold} gold${win.drop ? ' · something waits on the steps' : ''}`, DEPTHS.bannerMs);
    audio.play('gate', x, z);
    this.host.effects.emit({ x, y: 0.4, z, count: 60, color: 0xffb347, spread: 1.1, speed: 1.2, up: 4, life: 1.4, size: 0.3 });
    this.host.effects.lightFlash(x, 3, z, 0xffb347, 60, 1.4);
    this.host.rig.shake(0.2);
  }

  /** The chest was clicked. */
  openChest(): boolean {
    const run = this.run;
    const f = this.floor;
    const sim = this.host.sim();
    if (!run || !f || !f.chest || !sim || this.over || this.chestOpened) return false;
    this.chestOpened = true;
    this.view.setChestOpened(true);
    const level = sim.areaLevel('depths');
    const loot = rollChest(run.depth, level, Math.random, this.host.disciplineId?.());
    const mult = this.host.rewardMult();
    const gold = Math.round(loot.gold * mult);
    const x = f.chest.x;
    const z = f.chest.z;
    this.host.reportFloor({ depth: run.depth, level, clear: false, chest: true, mult });
    this.host.giveGold(x, z + 1.2, gold);
    this.host.gainXp(Math.round(loot.xp * mult), x, z);
    // Fan the drops out in front of the chest, the gear first.
    loot.drops.forEach((d, i) => {
      const a = Math.PI * (0.25 + (0.5 * i) / Math.max(1, loot.drops.length - 1));
      this.host.dropItems(x + Math.cos(a) * 1.6, z + Math.sin(a) * 1.6 + 0.4, [d], level, 'boss');
    });
    const rune = loot.drops.find((d) => ITEMS[d.item_id]?.type === 'rune');
    this.host.chronicle.add('depths.chests');
    this.host.hud.banner('The chest opens', `+${gold} gold · ${loot.drops.length} finds${rune ? ' · a rune among them' : ''}`, DEPTHS.bannerMs);
    audio.play('levelUp');
    this.host.effects.emit({ x, y: 0.8, z, count: 80, color: 0xf3d27a, spread: 0.8, speed: 1.6, up: 4.5, life: 1.5, size: 0.3 });
    this.host.effects.lightFlash(x, 2, z, 0xf3d27a, 70, 1.3);
    this.host.rig.shake(0.18);
    this.host.tip('depths_chest', 1500, { kind: 'asked' });
    return true;
  }

  /** The kill's loot comes from the ground whose gear matches the depth. */
  lootArea(area: string): ReturnType<typeof depthLootArea> | null {
    return area === 'depths' && this.run ? depthLootArea(this.run.depth) : null;
  }

  /** A kill on the floor: the Chronicle counts it (the area's kill counter and the seals are the hunting grounds' business). */
  recordKill() {
    this.host.chronicle.add('kills');
    this.host.chronicle.add('kills.depths');
  }

  /** The hero fell. The run is over, but the floor stays up behind the death screen until they rise (finishAfterDeath). */
  onPlayerDeath() {
    const run = this.run;
    if (!run || this.over) return;
    this.over = true;
    this.endNote = this.summary(run);
    this.host.chronicle.max('peak.depth', run.peak);
    void this.host.chronicle.flush();
  }

  /** The hero rose in the Chapterhouse: the Depths close behind them. */
  finishAfterDeath() {
    if (!this.run) return;
    const note = this.endNote;
    this.close();
    if (note) this.host.hud.toast(note, 'good');
  }

  /** Per frame. `inDepths` is whether the hero stands on the Depths ground. */
  update(dt: number, now: number, inDepths: boolean) {
    this.now = now;
    this.view.update(dt);
    this.warrenStair.update(dt);
    const run = this.run;
    if (run && !this.over) {
      if (!inDepths) this.end('recalled');
      else if (this.host.partySize() > 0) {
        this.host.hud.toast('A friend appeared on the descent: a run is solo, so the stair closes behind you.', 'err');
        this.end('party');
        this.host.teleportTo(DEPTHS_STAIR.x, DEPTHS_STAIR.z + 2.3);
      } else if (run.stairOpen !== this.lastStairOpen) {
        this.lastStairOpen = run.stairOpen;
        this.view.setStairOpen(run.stairOpen);
      }
    }
    // A calm word the first time the hero walks up to the stair.
    this.nearT -= dt;
    if (this.nearT <= 0) {
      this.nearT = 0.5;
      const p = this.host.player;
      if (!run && p.area === 'warren' && Math.hypot(p.x - DEPTHS_STAIR.x, p.z - DEPTHS_STAIR.z) < NEAR_STAIR_TIP) this.host.tip('depths');
    }
  }

  // --- Ending ----------------------------------------------------------------------------------------------------------------------

  private summary(run: DepthsRun): string {
    return `The descent ends at depth ${run.peak} · ${run.totalKills} slain · ${run.floors} floor${run.floors === 1 ? '' : 's'} cleared. What you looted is yours.`;
  }

  private end(why: RunEnd) {
    const run = this.run;
    if (!run) return;
    const note = this.summary(run);
    this.host.chronicle.max('peak.depth', run.peak);
    void this.host.chronicle.flush();
    this.close();
    if (why !== 'party') this.host.hud.toast(note, 'good');
  }

  /** Tear the run down (sim, nav and picture). */
  private close() {
    const hadRun = this.run !== null;
    this.host.sim()?.endDepths();
    this.view.clear();
    this.over = false;
    this.endNote = null;
    this.chestOpened = false;
    this.leaveArmedUntil = 0;
    this.lastStairOpen = false;
    if (hadRun && !this.disposed) this.host.stepBackIntoParty();
  }

  private disposed = false;

  dispose() {
    this.disposed = true;
    this.close();
    this.view.dispose();
    this.warrenStair.dispose();
  }

  /** Dev/QA: whether a chest is on this floor and whether it has been opened. */
  debug() {
    return { chest: hasChest(this.run?.depth ?? 0), opened: this.chestOpened, over: this.over };
  }
}
