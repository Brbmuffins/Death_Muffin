import * as THREE from 'three';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import type { GameScene } from './SceneManager';
import { getRuntime, type RuntimeView } from '../app/GameRuntime';
import { Scope } from '../app/Scope';
import { ABILITIES, HOTBAR, SOUL_HARVEST, SPELL_FX, type AbilityId, type HotbarSlot } from '../content/abilities';
import { AREAS, AREA_ORDER, BOSS_SUMMON_SHARDS, DOORS, PLAYER_SPAWN, type AreaId, type Interactable } from '../content/areas';
import { disciplineFor, type Discipline } from '../content/disciplines';
import { AFFIX_TUNING, ELITE_AFFIXES, ENEMIES, type EliteAffix } from '../content/enemies';
import { HEALING_FLASKS, itemMeta } from '../content/items';
import { generateLayout } from '../content/layout';
import { WAVE_MILESTONES, damageBonusPct, milestoneActive, waveModifiers } from '../content/upgrades';
import { DIFFICULTIES, type Difficulty } from '../content/difficulty';
import { onSettingsChange, settings } from '../app/settings';
import { STATUS_FX } from '../content/statuses';
import { AbilitySystem, type CastResult, type CastTarget } from '../gameplay/AbilitySystem';
import { deriveStats, xpToNext } from '../gameplay/characterStats';
import { Inventory, rollBoss, rollItem, rollKill } from '../gameplay/loot';
import { Nav } from '../gameplay/nav';
import { Player } from '../gameplay/Player';
import { Progression } from '../gameplay/progression';
import { BOSS_ARENA } from '../gameplay/sim/BossBrain';
import { makeSnapshot, WorldMirror } from '../gameplay/sim/snapshot';
import type { BossState, Corpse, Enemy, Intent, SimEvent, Thrall, Zone } from '../gameplay/sim/types';
import { WorldSim } from '../gameplay/sim/WorldSim';
import { computeStats, STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { NecromancerAvatar, PrelateView } from '../graphics/Avatars';
import { CameraRig } from '../graphics/CameraRig';
import { Effects, type Handle } from '../graphics/Effects';
import { EntityViews } from '../graphics/EntityViews';
import { fx } from '../graphics/fxTextures';
import { LootView } from '../graphics/LootView';
import { WorldView } from '../graphics/WorldView';
import { updateOcclusion } from '../graphics/occlusion';
import { getInventory, getProfessions, OFFLINE } from '../net/api';
import type { RemotePlayer, WorldSnapshot } from '../net/contracts';
import { RealtimeClient } from '../net/realtime';
import type { Character, Profession } from '../net/types';
import { FloatingText } from '../ui/FloatingText';
import { ForgePanel } from '../ui/ForgePanel';
import { HUD, type HudFrame } from '../ui/HUD';
import { InventoryPanel } from '../ui/InventoryPanel';
import { SettingsPanel, WaystonePanel } from '../ui/MiscPanels';
import { ProfessionsPanel } from '../ui/ProfessionsPanel';
import { CodexPanel } from '../ui/CodexPanel';
import { Onboarding } from '../ui/Onboarding';
import { CodexJournal, type CodexIds, type CodexKind } from '../gameplay/codexJournal';
import { deadName } from '../content/codex';
import { CURSOR } from '../ui/cursors';
import { audio } from '../audio/Audio';

/** Chill has no generated icon yet: a cold-blue frost sigil drawn inline. */
const CHILL_ICON = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='4' fill='%23121a2e'/><g stroke='%239fc4ff' stroke-width='2.4' stroke-linecap='round'><path d='M16 5v22M6.5 10.5l19 11M6.5 21.5l19-11'/><path d='M13 7l3 3 3-3M13 25l3-3 3 3' fill='none'/></g></svg>";

const SNAPSHOT_MS = 100;
const MOVE_SEND_MS = 100;
const RESPAWN_MS = 4000;
const RECALL_MS = 1500;
const INTERACT_RANGE = 2.6;

interface Remote {
  info: RemotePlayer;
  avatar: NecromancerAvatar;
  tx: number;
  tz: number;
  facing: number;
  moving: boolean;
  hpFrac: number;
}

type Hover =
  | { kind: 'enemy'; id: number }
  | { kind: 'boss' }
  | { kind: 'interact'; it: Interactable }
  | null;

/**
 * The one connected world: Chapterhouse, Hollow Graves, Marrow Ossuary,
 * Drowned Nave and Bell Sanctum. Replaces the old Hub/Arena/Boss scenes —
 * there is no extraction; you farm, upgrade, unlock and push deeper.
 */
export class WorldScene implements GameScene, RuntimeView {
  readonly scene = new THREE.Scene();
  readonly bloom = { strength: 0.9, radius: 0.55, threshold: 0.8 };
  private rig = new CameraRig();
  private scope = new Scope();
  private root = document.getElementById('ui-root')!;
  private canvas = document.getElementById('scene') as HTMLCanvasElement;

  private discipline: Discipline;
  private progression: Progression;
  private inventory: Inventory;
  private professions: Profession[] = [];
  private nav = new Nav();
  private layout = generateLayout();
  private effects!: Effects;
  private worldView!: WorldView;
  private views!: EntityViews;
  private prelate!: PrelateView;
  private loot!: LootView;
  private avatar!: NecromancerAvatar;
  private player!: Player;
  private abilities!: AbilitySystem;
  private hud!: HUD;
  private floating!: FloatingText;
  private moon!: THREE.DirectionalLight;
  private hemi!: THREE.HemisphereLight;

  private sim: WorldSim | null = null;
  private mirror: WorldMirror | null = null;
  private realtime = new RealtimeClient();
  private selfId = 'self';
  private remotes = new Map<string, Remote>();
  private lastSnapshot = 0;
  /** World wave tier last frame (milestone banners) and the Nightfall light blend 0..1. */
  private seenWaveTier = -1;
  private nightK = 0;
  private snapshotCount = 0;
  private lastMoveSent = 0;
  private lastPrune = 0;
  private lineupTicks: ((dt: number) => void)[] = [];
  private stepT = 0;
  private rippleT = 0;
  private rippleCursor = 0;
  private zoneFx = new Map<number, Handle[]>();
  /** The cracked-crypt marker of the running Grave Surge. */
  private surgeFx: Handle | null = null;

  private keys = new Set<string>();
  private mouse = { x: 0, y: 0, down: false, shift: false };
  private groundPoint = new THREE.Vector3();
  private hover: Hover = null;
  private attackTarget: { kind: 'enemy'; id: number } | { kind: 'boss' } | null = null;
  private pendingInteract: Interactable | null = null;
  private area: AreaId = 'chapterhouse';
  private deadUntil = 0;
  private recallAt = 0;
  private recallFx: Handle | null = null;
  private flaskCdUntil = 0;
  private ready = false;
  /** Scene clock in ms (runtime-provided; see GameRuntime.advance). */
  private now = 0;
  private raycaster = new THREE.Raycaster();
  private ndc = new THREE.Vector2();
  private groundPlane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
  private occlusionFocus = new THREE.Vector3();

  private inventoryPanel!: InventoryPanel;
  private forgePanel!: ForgePanel;
  private professionsPanel!: ProfessionsPanel;
  private settingsPanel!: SettingsPanel;
  private waystonePanel!: WaystonePanel;
  private codexPanel!: CodexPanel;
  private codex!: CodexJournal;
  private onboarding!: Onboarding;
  private lastTipCheck = 0;
  /** Codex discoveries waiting to be announced as one toast (entering an area finds several at once). */
  private codexPending: string[] = [];
  private codexPendingSince = -1;

  constructor(
    private character: Character,
    private onLeave: () => void,
  ) {
    this.discipline = disciplineFor(character.class_index);
    this.progression = new Progression(character);
    this.inventory = new Inventory(character.id);
  }

  get camera() {
    return this.rig.camera;
  }

  // -------------------------------------------------------------------------
  // Mount
  // -------------------------------------------------------------------------

  mount() {
    this.buildScene();
    this.nav.setUnlocked(this.progression.local.unlocked);
    this.worldView = new WorldView(this.scene, this.layout, this.nav, this.effects);
    for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d), true);
    this.views = new EntityViews(this.scene, this.effects);
    this.prelate = new PrelateView(this.scene, this.effects);
    this.loot = new LootView(this.scene, this.effects);

    const stats = deriveStats(this.character, [], this.discipline, this.progression.local.damageTier);
    this.player = new Player(stats, this.nav);
    this.player.teleport(PLAYER_SPAWN.x, PLAYER_SPAWN.z);
    this.avatar = new NecromancerAvatar(this.scene, this.discipline.color, true, this.discipline.modelSlug);
    this.rig.snap(this.player.x, this.player.z);
    // Readability: a soft pool of discipline light and a thin ring under the hero.
    const follow = () => ({ x: this.player.x, z: this.player.z });
    this.effects.decal({ tex: fx.glow(), color: this.discipline.color, x: 0, z: 0, r: 2.2, duration: 1e9, opacity: 0.32, fadeIn: 0.01, follow });
    this.effects.decal({ tex: fx.ring(), color: this.discipline.color, x: 0, z: 0, r: 0.85, duration: 1e9, opacity: 0.55, fadeIn: 0.01, follow });
    // Soul Harvest charged: a jade halo until the empowered spell is spent.
    this.effects.decal({
      tex: fx.ring(),
      color: SPELL_FX.souls.jade,
      x: 0,
      z: 0,
      r: 1.25,
      duration: 1e9,
      opacity: 0.75,
      fadeIn: 0.01,
      pulse: 5,
      follow: () => (this.player.soulsCharged && this.player.alive ? follow() : null),
    });
    // Target ring: bone-white under whatever the cursor (or auto-attack) is on.
    this.effects.decal({
      tex: fx.ring(),
      color: 0xf0e9dc,
      x: 0,
      z: 0,
      r: 1,
      duration: 1e9,
      opacity: 0.85,
      fadeIn: 0.01,
      pulse: 6,
      follow: () => {
        const h = this.hover?.kind === 'enemy' ? this.hover : this.attackTarget?.kind === 'enemy' ? this.attackTarget : null;
        const e = h ? this.enemiesMap().get(h.id) : undefined;
        return e && e.state !== 'rising' ? { x: e.x, z: e.z } : null;
      },
    });

    this.sim = new WorldSim(this.nav);
    this.sim.setCrypts(this.layout.crypts);
    this.sim.waveTier = this.progression.local.waveTierActive;
    this.sim.difficulty = settings.difficulty;

    this.abilities = new AbilitySystem({
      selfId: this.selfId,
      player: this.player,
      discipline: this.discipline,
      avatar: this.avatar,
      effects: this.effects,
      enemies: () => this.enemiesMap(),
      boss: () => this.bossState(),
      corpses: () => this.corpsesMap(),
      send: (i) => this.sendIntent(i),
      number: (x, z, amount, kind) => this.floating.spawn(x, 1.6, z, Math.round(amount).toString(), kind === 'crit' ? 'crit' : 'hit'),
      shake: (a) => this.rig.shake(a),
      now: () => this.now,
    });

    this.mountUi();
    this.bindInput();
    this.scope.add(this.progression.onChange(() => this.refreshStats()));
    this.scope.add(onSettingsChange((s) => this.onDifficultySetting(s.difficulty)));
    this.scope.add(this.inventory.onChange(() => this.refreshStats()));
    this.scope.on(window, 'pagehide', () => {
      void this.progression.flush(true);
      void this.inventory.flush();
    });

    getRuntime().setView(this);
    void this.loadData();
    // Offline dev tokens are not JWTs: only try co-op there when asked (?offline&coop).
    if (!OFFLINE || new URLSearchParams(location.search).has('coop')) void this.connectRealtime();
    if (import.meta.env.DEV) this.installDebug();

    this.area = 'chapterhouse';
    this.hud.banner(AREAS.chapterhouse.name, AREAS.chapterhouse.subtitle);
    audio.setArea('chapterhouse');
    this.codex.discover('area', 'chapterhouse');
    this.onboarding.show('move', 1500);
    this.ready = true;
  }

  private buildScene() {
    const s = this.scene;
    s.background = new THREE.Color(0x07060a);
    s.fog = new THREE.FogExp2(0x0b0810, 0.014);
    const pmrem = new THREE.PMREMGenerator(getRuntime().renderer);
    s.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
    s.environmentIntensity = 0.18;
    pmrem.dispose();

    this.hemi = new THREE.HemisphereLight(0x4a3866, 0x0a0710, 0.95);
    s.add(this.hemi);
    const moon = new THREE.DirectionalLight(0x9aa6d4, 2.4);
    moon.position.set(-14, 30, 12);
    moon.castShadow = true;
    moon.shadow.mapSize.set(2048, 2048);
    moon.shadow.camera.left = -30;
    moon.shadow.camera.right = 30;
    moon.shadow.camera.top = 30;
    moon.shadow.camera.bottom = -30;
    moon.shadow.camera.near = 1;
    moon.shadow.camera.far = 90;
    moon.shadow.bias = -0.0006;
    moon.shadow.normalBias = 0.02;
    s.add(moon, moon.target);
    this.moon = moon;
    const rim = new THREE.DirectionalLight(0x7a5cd6, 1.6);
    rim.position.set(6, 10, -24);
    s.add(rim);
    this.effects = new Effects(s);
  }

  private async loadData() {
    try {
      const [slots, professions] = await Promise.all([getInventory(this.character.id), getProfessions(this.character.id)]);
      this.inventory.replace(slots);
      this.professions = professions;
      this.refreshStats();
    } catch (err) {
      this.hud.toast(err instanceof Error ? err.message : 'Failed to load your reliquary', 'err');
    }
  }

  private refreshStats() {
    if (!this.player) return;
    const stats = deriveStats(this.character, this.inventory.all, this.discipline, this.progression.local.damageTier);
    this.player.setStats(stats);
    if (this.sim && (this.isAuthority())) this.sim.waveTier = this.progression.local.waveTierActive;
    this.inventoryPanel?.render();
  }

  private statsLine = () => {
    const { total, bonus } = computeStats(this.character, this.inventory.all);
    const s = this.player.stats;
    const parts = STAT_KEYS.map((k) => `<span>${STAT_LABELS[k]} <b>${total[k]}</b>${bonus[k] ? `<span class="plus">+${bonus[k]}</span>` : ''}</span>`);
    return `${parts.join('')}<span>Health <b>${s.maxHp}</b></span><span>Spell <b>${Math.round(s.spellPower)}</b></span>`;
  };

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  private mountUi() {
    this.floating = new FloatingText(this.root);
    this.hud = new HUD(this.root, {
      cast: (slot) => this.castSlot(slot),
      buyDamage: () => {
        if (this.progression.buyDamage()) {
          audio.play('buy');
          this.hud.toast(`Damage empowered: +${damageBonusPct(this.progression.local.damageTier)}%`, 'good');
          this.effects.emit({ x: this.player.x, y: 1, z: this.player.z, count: 40, color: 0xc6a4ff, spread: 0.6, speed: 2, up: 2.5, life: 1, size: 0.3 });
        }
      },
      buyWave: () => {
        if (this.progression.buyWave()) {
          audio.play('buy');
          this.applyWaveTier();
          this.hud.toast(`Waves quickened — tier ${this.progression.local.waveTierOwned}`, 'good');
        }
      },
      dialWave: (d) => {
        this.progression.setActiveWaveTier(this.progression.local.waveTierActive + d);
        this.applyWaveTier();
      },
      open: (p) => this.togglePanel(p),
      chat: (text) => {
        if (this.realtime.connected) this.realtime.sendChat(text);
        else this.hud.chatLine('(solo) Nobody hears you in the dark.');
      },
    });
    this.inventoryPanel = new InventoryPanel(this.root, this.character.id, this.inventory, this.statsLine, (id) => this.drinkFlask(id));
    this.forgePanel = new ForgePanel(this.root, this.character.id, this.inventory, (inv, prof) => {
      this.inventory.replace(inv);
      this.professions = this.professions.map((p) => (p.profession_id === prof.profession_id ? prof : p));
      this.hud.toast('Crafted', 'good');
    });
    this.professionsPanel = new ProfessionsPanel(this.root);
    this.settingsPanel = new SettingsPanel(
      this.root,
      () => this.onLeave(),
      () => this.realtime.instance,
    );
    this.waystonePanel = new WaystonePanel(
      this.root,
      () => AREA_ORDER.filter((a) => this.progression.isUnlocked(a)),
      (a) => this.travel(a),
    );
    this.codex = new CodexJournal(this.character.id);
    this.codexPanel = new CodexPanel(this.root, this.codex, this.discipline.id);
    this.onboarding = new Onboarding(this.root, this.character.id);
    this.scope.add(() => {
      this.codexPanel.dispose();
      this.onboarding.dispose();
    });
    const rmb = 'Right-click a corpse: Corpse Explosion';
    this.hud.hint(OFFLINE ? `OFFLINE DEV MODE — progress stays in this browser · ${rmb}` : rmb);
    this.scope.add(() => {
      this.closePanels();
      this.hud.dispose();
      this.floating.clear();
    });
  }

  private closePanels() {
    this.inventoryPanel.close();
    this.forgePanel.close();
    this.professionsPanel.close();
    this.settingsPanel.close();
    this.waystonePanel.close();
    this.codexPanel.close();
  }

  private togglePanel(p: 'inventory' | 'forge' | 'professions' | 'settings' | 'map' | 'codex') {
    audio.play('click');
    const panel = { inventory: this.inventoryPanel, forge: this.forgePanel, professions: this.professionsPanel, settings: this.settingsPanel, map: this.waystonePanel, codex: this.codexPanel }[p];
    const wasOpen = panel.isOpen;
    this.closePanels();
    if (wasOpen) return;
    if (p === 'professions') this.professionsPanel.open(this.professions);
    else if (p === 'inventory') this.inventoryPanel.open();
    else if (p === 'forge') void this.forgePanel.open();
    else if (p === 'settings') this.settingsPanel.open();
    else if (p === 'codex') this.codexPanel.open();
    else this.waystonePanel.open();
  }

  private applyWaveTier() {
    if (this.sim && this.isAuthority()) this.sim.waveTier = this.progression.local.waveTierActive;
  }

  // -------------------------------------------------------------------------
  // Input
  // -------------------------------------------------------------------------

  private bindInput() {
    this.scope.on<KeyboardEvent>(window, 'keydown', (e) => {
      if (document.activeElement instanceof HTMLInputElement) return;
      const k = e.key.toLowerCase();
      if (k === 'enter') {
        this.hud.focusChat();
        return;
      }
      if (k >= '1' && k <= '5') this.castSlot(Number(k) as HotbarSlot);
      else if (k === 'q') this.drinkFlask();
      else if (k === 't') this.startRecall();
      else if (k === 'i' || k === 'b') this.togglePanel('inventory');
      else if (k === 'c') this.togglePanel('forge');
      else if (k === 'p') this.togglePanel('professions');
      else if (k === 'm') this.togglePanel('map');
      else if (k === 'k') this.togglePanel('codex');
      else if (k === 'escape') this.togglePanel('settings');
      else this.keys.add(k);
      this.mouse.shift = e.shiftKey;
    });
    this.scope.on<KeyboardEvent>(window, 'keyup', (e) => {
      this.keys.delete(e.key.toLowerCase());
      this.mouse.shift = e.shiftKey;
    });
    this.scope.on<PointerEvent>(this.canvas, 'pointermove', (e) => {
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.mouse.shift = e.shiftKey;
    });
    // Right-click: Corpse Explosion on the corpse nearest the cursor. Bound on
    // mousedown (not pointerdown) so it still fires while the left button is
    // held to steer — chorded presses don't produce a second pointerdown.
    this.scope.on<MouseEvent>(this.canvas, 'mousedown', (e) => {
      if (e.button !== 2) return;
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.castSlot(5);
    });
    this.scope.on<PointerEvent>(this.canvas, 'pointerdown', (e) => {
      if (e.button !== 0) return;
      this.mouse.down = true;
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.mouse.shift = e.shiftKey;
      this.onPrimaryClick();
    });
    // Only the left button steers; releasing a chorded right-click must not stop it.
    this.scope.on<MouseEvent>(window, 'mouseup', (e) => {
      if (e.button === 0) this.mouse.down = false;
    });
    this.scope.on<PointerEvent>(window, 'pointercancel', () => (this.mouse.down = false));
    this.scope.on<WheelEvent>(this.canvas, 'wheel', (e) => this.rig.onWheel(e), { passive: true });
    this.scope.on<MouseEvent>(this.canvas, 'contextmenu', (e) => e.preventDefault());
  }

  private updateCursor() {
    const cam = this.rig.camera;
    this.ndc.set((this.mouse.x / window.innerWidth) * 2 - 1, -(this.mouse.y / window.innerHeight) * 2 + 1);
    this.raycaster.setFromCamera(this.ndc, cam);
    this.raycaster.ray.intersectPlane(this.groundPlane, this.groundPoint);

    // Screen-space picking: nearest enemy/boss/interactable to the cursor.
    const v = new THREE.Vector3();
    let best: Hover = null;
    let bestD = 46;
    const test = (x: number, y: number, z: number, h: Hover, radiusPx = 0) => {
      v.set(x, y, z).project(cam);
      const sx = ((v.x + 1) / 2) * window.innerWidth;
      const sy = ((1 - v.y) / 2) * window.innerHeight;
      const d = Math.hypot(sx - this.mouse.x, sy - this.mouse.y) - radiusPx;
      if (d < bestD) {
        bestD = d;
        best = h;
      }
    };
    for (const e of this.enemiesMap().values()) {
      if (e.state === 'dead' || e.state === 'rising') continue;
      test(e.x, 0.9 * e.scale, e.z, { kind: 'enemy', id: e.id }, e.elite ? 10 : 0);
    }
    const b = this.bossState();
    if (b.active) test(b.x, 2.4, b.z, { kind: 'boss' }, 40);
    if (!best) {
      bestD = 60;
      for (const it of this.interactablesNear()) test(it.x, 1.2, it.z, { kind: 'interact', it });
    }
    this.hover = best;
    const h = this.hover as Hover;
    this.views.hoverId = h?.kind === 'enemy' ? h.id : null;
    const cur = h?.kind === 'enemy' || h?.kind === 'boss' ? CURSOR.attack : h?.kind === 'interact' ? CURSOR.interact : CURSOR.default;
    if (this.canvas.style.cursor !== cur) this.canvas.style.cursor = cur;
  }

  private interactablesNear(): Interactable[] {
    const out: Interactable[] = [];
    for (const id of AREA_ORDER) {
      for (const it of AREAS[id].interactables) {
        if (Math.abs(it.x - this.player.x) < 26 && Math.abs(it.z - this.player.z) < 22) out.push(it);
      }
    }
    return out;
  }

  private onPrimaryClick() {
    if (!this.player.alive) return;
    this.updateCursor();
    this.cancelRecall();
    const h = this.hover;
    if (this.mouse.shift) {
      // Stand and cast at whatever is under the cursor.
      if (h && (h.kind === 'enemy' || h.kind === 'boss')) this.attackTarget = h;
      this.player.stop();
      return;
    }
    if (h?.kind === 'enemy' || h?.kind === 'boss') {
      this.attackTarget = h;
      this.pendingInteract = null;
      this.player.stop();
      return;
    }
    this.attackTarget = null;
    if (h?.kind === 'interact') {
      this.pendingInteract = h.it;
      this.player.moveTo(h.it.x, h.it.z + 1.4);
      return;
    }
    this.pendingInteract = null;
    this.player.moveTo(this.groundPoint.x, this.groundPoint.z);
    this.effects.decal({ tex: fx.ring(), color: 0xc6a4ff, x: this.groundPoint.x, z: this.groundPoint.z, r: 0.45, duration: 0.35, opacity: 0.8, growFrom: 1.6 });
  }

  private castSlot(slot: HotbarSlot) {
    if (!this.player?.alive) return;
    this.updateCursor();
    this.cancelRecall();
    const id = HOTBAR[slot - 1];
    if (!id) return;
    // Corpse Explosion picks from the exact ground point, not a hovered enemy's position.
    const target = id === 'corpse_explosion' ? { x: this.groundPoint.x, z: this.groundPoint.z } : this.cursorTarget();
    const res = this.abilities.cast(id, target, this.now);
    this.feedback(res, id);
    if (res === 'ok') this.hud.slotFlash(slot);
  }

  private cursorTarget(): CastTarget {
    const h = this.hover;
    if (h?.kind === 'enemy') {
      const e = this.enemiesMap().get(h.id);
      if (e) return { x: e.x, z: e.z, enemyId: e.id };
    }
    if (h?.kind === 'boss') {
      const b = this.bossState();
      return { x: b.x, z: b.z, boss: true };
    }
    return { x: this.groundPoint.x, z: this.groundPoint.z };
  }

  private lastFeedback = 0;
  private feedback(res: CastResult, id: AbilityId) {
    if (res === 'ok' || res === 'range' || res === 'no_target') return;
    const now = this.now;
    if (now - this.lastFeedback < 600) return;
    this.lastFeedback = now;
    const text =
      res === 'essence' ? 'Not enough Grave Essence' : res === 'cooldown' ? `${ABILITIES[id].name} is not ready` : res === 'no_corpse' ? 'No corpse in reach' : '';
    if (text) {
      this.floating.spawn(this.player.x, 2.4, this.player.z, text, 'info');
      audio.play('error');
    }
  }

  private drinkFlask(prefer?: string) {
    const now = this.now;
    if (!this.player.alive || now < this.flaskCdUntil) return;
    const id = prefer && prefer in HEALING_FLASKS ? prefer : ['flask_hp_major', 'flask_hp_minor'].find((f) => this.inventory.count(f) > 0);
    if (!id || !this.inventory.consume(id)) {
      this.floating.spawn(this.player.x, 2.4, this.player.z, 'No healing flasks', 'info');
      return;
    }
    this.flaskCdUntil = now + 1500;
    const amount = this.player.stats.maxHp * HEALING_FLASKS[id];
    this.player.heal(amount);
    this.floating.spawn(this.player.x, 2.2, this.player.z, `+${Math.round(amount)}`, 'gold');
    this.effects.emit({ x: this.player.x, y: 0.5, z: this.player.z, count: 26, color: 0xc85a8a, spread: 0.5, speed: 0.6, up: 2.2, life: 0.9, size: 0.3 });
  }

  private startRecall() {
    if (!this.player.alive || this.recallAt) return;
    if (this.area === 'chapterhouse') {
      this.floating.spawn(this.player.x, 2.4, this.player.z, 'Already in the Chapterhouse', 'info');
      return;
    }
    this.player.stop();
    this.recallAt = this.now + RECALL_MS;
    this.recallFx = this.effects.decal({ tex: fx.sigil(), color: 0x8f9ed1, x: this.player.x, z: this.player.z, r: 1.4, duration: RECALL_MS / 1000, opacity: 0.9, growFrom: 0.2, spin: 3 });
    this.avatar.cast('cast', 1);
  }

  private cancelRecall() {
    if (!this.recallAt) return;
    this.recallAt = 0;
    this.recallFx?.kill();
    this.recallFx = null;
  }

  private travel(area: AreaId) {
    const nearStone = AREA_ORDER.some((a) =>
      AREAS[a].interactables.some((it) => it.kind === 'waystone' && Math.hypot(it.x - this.player.x, it.z - this.player.z) < 5),
    );
    if (!nearStone && this.area !== 'chapterhouse') {
      this.hud.toast('Stand beside a waystone to travel (or press T to return home)', 'err');
      return;
    }
    const stone = AREAS[area].interactables.find((it) => it.kind === 'waystone');
    if (!stone) return;
    this.teleportTo(stone.x, stone.z + 1.6);
  }

  private teleportTo(x: number, z: number) {
    this.effects.emit({ x: this.player.x, y: 1, z: this.player.z, count: 50, color: 0x8f9ed1, spread: 0.6, speed: 1.5, up: 2.5, life: 1, size: 0.35 });
    this.player.teleport(x, z);
    this.attackTarget = null;
    this.pendingInteract = null;
    this.rig.snap(x, z);
    this.sendIntent({ t: 'recallThralls', by: this.selfId, x, z });
    this.effects.emit({ x, y: 1, z, count: 50, color: 0x8f9ed1, spread: 0.6, speed: 1.5, up: 2.5, life: 1, size: 0.35 });
  }

  private interact(it: Interactable) {
    this.pendingInteract = null;
    this.player.stop();
    switch (it.kind) {
      case 'inventory':
        return this.togglePanel('inventory');
      case 'forge':
        return this.togglePanel('forge');
      case 'professions':
        return this.togglePanel('professions');
      case 'waystone':
        return this.togglePanel('map');
      case 'upgrades':
        this.hud.toast('The Altar hears you anywhere: empower Damage and quicken Waves at the lower right.', 'good');
        return;
      case 'boss': {
        const b = this.bossState();
        if (b.active) return;
        if (!this.progression.spendShards(BOSS_SUMMON_SHARDS)) {
          this.hud.toast(`The Sundered Bell demands ${BOSS_SUMMON_SHARDS} soul shards (you have ${this.progression.local.shards}). Elites carry them.`, 'err');
          return;
        }
        this.sendIntent({ t: 'summonBoss', by: this.selfId });
      }
    }
  }

  // -------------------------------------------------------------------------
  // Authority & networking
  // -------------------------------------------------------------------------

  private isAuthority() {
    return !this.realtime.connected || this.realtime.isHost;
  }

  private enemiesMap(): Map<number, Enemy> {
    return this.mirror?.enemies ?? this.sim!.enemies;
  }

  private thrallsMap(): Map<number, Thrall> {
    return this.mirror?.thralls ?? this.sim!.thralls;
  }

  private corpsesMap(): Map<number, Corpse> {
    return this.mirror?.corpses ?? this.sim!.corpses;
  }

  private bossState(): BossState {
    return (this.mirror ? this.mirror.bossState : null) ?? this.sim?.bossState ?? ({ active: false } as BossState);
  }

  private sendIntent(intent: Intent) {
    if (this.sim && this.isAuthority()) this.sim.apply(intent);
    else this.realtime.sendIntent(intent);
  }

  private async connectRealtime() {
    try {
      const res = await this.realtime.connect(
        {
          characterId: this.character.id,
          classIndex: this.character.class_index,
          x: this.player.x,
          z: this.player.z,
          facing: this.player.facing,
        },
        {
          onPlayerJoin: (p) => {
            this.addRemote(p);
            this.hud.chatLine(`${p.name} entered the world`);
          },
          onPlayerLeave: (id) => {
            const r = this.remotes.get(id);
            if (!r) return;
            this.hud.chatLine(`${r.info.name} left`);
            r.avatar.dispose();
            this.remotes.delete(id);
            this.sim?.removePlayer(id);
          },
          onPlayerMove: (u) => {
            const r = this.remotes.get(u.id);
            if (!r) return;
            r.tx = u.x;
            r.tz = u.z;
            r.facing = u.facing;
            r.moving = u.moving;
            r.hpFrac = u.hpFrac;
          },
          onChat: (m) => this.hud.chatLine(`${m.name}: ${m.text}`),
          onDisconnect: () => {
            for (const r of this.remotes.values()) r.avatar.dispose();
            this.remotes.clear();
            this.becomeAuthority(null);
            this.hud.toast('Lost the co-op link — the world continues solo', 'err');
          },
          onIntent: (env) => {
            if (!this.sim || !this.isAuthority()) return;
            // Never trust the claimed caster; the server stamps `from`.
            this.sim.apply({ ...env.intent, by: env.from } as Intent);
          },
          onSnapshot: (s) => this.mirror?.applySnapshot(s),
          onEvents: (batch) => {
            if (!this.mirror) return;
            this.mirror.applyEvents(batch);
            for (const ev of batch) this.handleEvent(ev);
          },
          onHostChange: (hostId, snapshot) => {
            if (hostId === this.realtime.selfId) this.becomeAuthority(snapshot);
          },
        },
      );
      const oldSelf = this.selfId;
      this.selfId = this.realtime.selfId ?? 'self';
      this.retagSelf(oldSelf);
      for (const p of res.players) if (p.id !== this.selfId) this.addRemote(p);
      if (!this.realtime.isHost) {
        // Someone else owns the world: drop our local sim, mirror theirs.
        this.mirror = new WorldMirror();
        if (res.snapshot) this.mirror.applySnapshot(res.snapshot);
        this.sim = null;
      }
      this.hud.chatLine(`Joined world ${res.instance}${this.realtime.isHost ? ' (you keep the world)' : ''}`);
    } catch (err) {
      // Solo — realtime is additive, never blocking.
      if (!(err instanceof Error && /not configured/.test(err.message))) {
        this.hud.chatLine(err instanceof Error ? err.message : 'Co-op unavailable — playing solo');
      }
    }
  }

  /** Our socket id replaces the provisional 'self' id on sim-owned entities. */
  private retagSelf(old: string) {
    this.abilities.setSelf(this.selfId);
    if (!this.sim) return;
    this.sim.removePlayer(old);
    for (const t of this.sim.thralls.values()) if (t.owner === old) t.owner = this.selfId;
  }

  private becomeAuthority(snapshot: WorldSnapshot | null) {
    if (this.sim && !this.mirror) return;
    const sim = new WorldSim(this.nav);
    sim.setCrypts(this.layout.crypts);
    sim.waveTier = this.progression.local.waveTierActive;
    // Prefer our own mirror (it has every event applied); the server's stored
    // snapshot is only the fallback when we never mirrored anything.
    const mirror = this.mirror ?? new WorldMirror();
    if (snapshot && !this.mirror) mirror.applySnapshot(snapshot);
    mirror.seed(sim);
    // Areas that already hold enemies are not "first visits" — no bonus wave.
    for (const e of sim.enemies.values()) sim.markVisited(e.area);
    // The new keeper's difficulty runs the world from here on (new spawns).
    sim.difficulty = settings.difficulty;
    this.sim = sim;
    this.mirror = null;
    this.hud.chatLine(`You now keep the world (${DIFFICULTIES[sim.difficulty].name})`);
  }

  private addRemote(p: RemotePlayer) {
    if (this.remotes.has(p.id) || p.id === this.selfId) return;
    const d = disciplineFor(p.classIndex);
    const avatar = new NecromancerAvatar(this.scene, d.color, false, d.modelSlug);
    this.remotes.set(p.id, { info: p, avatar, tx: p.x, tz: p.z, facing: p.facing, moving: false, hpFrac: p.hpFrac ?? 1 });
  }

  // -------------------------------------------------------------------------
  // Events → visuals, rewards, damage
  // -------------------------------------------------------------------------

  private handleEvent(ev: SimEvent) {
    this.views.onEvent(ev);
    const me = this.selfId;
    switch (ev.t) {
      case 'death':
        audio.play(ev.elite ? 'eliteDeath' : 'enemyDeath', ev.x, ev.z);
        this.worldView.addRipple(ev.x, ev.z, ev.elite ? 2 : 1.4);
        this.onKill(ev);
        break;
      case 'hurt':
        if (ev.player === me) this.onHurt(ev.dmg, ev.from, ev.x, ev.z);
        break;
      case 'telegraph':
        this.telegraph(ev);
        break;
      case 'melee':
        this.effects.emitSmoke({ x: ev.tx, y: 0.3, z: ev.tz, count: 2, color: 0x3a3340, spread: 0.3, speed: 0.8, up: 0.3, life: 0.5, size: 0.6 });
        break;
      case 'thrallHit': {
        audio.play('boneHit', ev.tx, ev.tz);
        const color = ev.kind === 'wraith' ? 0x8f9ed1 : 0xd8cfbd;
        if (ev.kind === 'wraith') {
          this.effects.projectile({ from: { x: ev.x, y: 1.3, z: ev.z }, to: () => ({ x: ev.tx, y: 1, z: ev.tz }), kind: 'orb', color, speed: 20 });
        } else this.effects.emit({ x: ev.tx, y: 1, z: ev.tz, count: 3, color, spread: 0.2, speed: 2, up: 0.8, life: 0.3, size: 0.15, gravity: 5 });
        if (ev.dmg > 0) this.floating.spawn(ev.tx, 1.4, ev.tz, String(ev.dmg), 'thrall');
        break;
      }
      case 'zone':
        this.zoneVisual(ev.zone);
        break;
      case 'zoneGone':
        this.zoneFx.get(ev.id)?.forEach((h) => h.kill());
        this.zoneFx.delete(ev.id);
        break;
      case 'burst':
        audio.play('burst', ev.x, ev.z);
        this.effects.decal({ tex: fx.ring(), color: ev.kind === 'toxic' ? 0x8fa05a : 0xb58cff, x: ev.x, z: ev.z, r: ev.r, duration: 0.5, growFrom: 0.2, opacity: 1 });
        this.effects.emit({ x: ev.x, y: 0.6, z: ev.z, count: 30, color: ev.kind === 'toxic' ? 0x8fa05a : 0xb58cff, spread: ev.r * 0.5, speed: 3, up: 1.5, life: 0.8, size: 0.35 });
        this.effects.emitSmoke({ x: ev.x, y: 0.4, z: ev.z, count: 8, color: ev.kind === 'toxic' ? 0x3d4a22 : 0x3a2d55, spread: ev.r * 0.4, speed: 1.2, up: 0.8, life: 1.4, size: 1.6, shrink: -1 });
        break;
      case 'exhumed':
        if (ev.by === me) {
          if (!ev.ok) {
            // Someone else claimed it first: refund.
            this.player.essence = Math.min(this.player.stats.maxEssence, this.player.essence + ABILITIES.exhume.essenceCost);
            this.player.cooldowns.delete('exhume');
            this.floating.spawn(this.player.x, 2.4, this.player.z, 'The corpse is gone', 'info');
          } else if (this.discipline.mods.corpseHeal) {
            const amt = this.player.stats.maxHp * this.discipline.mods.corpseHeal;
            this.player.heal(amt);
            this.floating.spawn(this.player.x, 2.2, this.player.z, `+${Math.round(amt)}`, 'gold');
          }
        }
        break;
      case 'litanyResult':
        this.abilities.onLitany(ev, ev.by === me);
        break;
      case 'detonated':
        if (ev.ok) this.abilities.onDetonated(ev, ev.by === me);
        else if (ev.by === me) {
          // The corpse was claimed first: refund like Exhume does.
          this.player.essence = Math.min(this.player.stats.maxEssence, this.player.essence + ABILITIES.corpse_explosion.essenceCost);
          this.player.cooldowns.delete('corpse_explosion');
          this.floating.spawn(this.player.x, 2.4, this.player.z, 'The corpse is gone', 'info');
        }
        break;
      case 'sanctify': {
        // Pale gold thread from the Deacon; a halo settles on the blessed.
        const G = STATUS_FX.sanctified;
        this.effects.beam({ x: ev.x, y: 1.9, z: ev.z }, () => ({ x: ev.tx, y: 1.6, z: ev.tz }), G.gold, 0.04, 0.5);
        this.effects.decal({ tex: fx.ring(), color: G.gold, x: ev.tx, z: ev.tz, r: 1.1, duration: 0.8, opacity: 0.8, growFrom: 1.8 });
        this.effects.emit({ x: ev.tx, y: 1.8, z: ev.tz, count: 10, color: G.pale, spread: 0.4, speed: 0.6, up: 0.8, life: 0.6, size: 0.18 });
        break;
      }
      case 'affix':
        if (ev.affix === 'hungering' && ev.amount) this.floating.spawn(ev.x, 2.4, ev.z, `+${ev.amount}`, 'dot');
        break;
      case 'surge':
        this.onSurge(ev);
        break;
      case 'surgeCleared':
        this.onSurgeCleared(ev);
        break;
      case 'surgeFailed':
        this.surgeFx?.kill();
        this.surgeFx = null;
        if (ev.area === this.area) this.hud.banner('The Surge Recedes', 'The crypt seals itself — its offering lost', 2600);
        break;
      case 'wave':
        if (ev.area === this.area) {
          audio.play('wave', ev.x, ev.z);
          this.effects.decal({ tex: fx.cracks(), color: 0x9b5cff, x: ev.x, z: ev.z, r: 3, duration: 1.8, opacity: 0.9, growFrom: 0.3 });
          this.effects.lightFlash(ev.x, 1, ev.z, 0x7c3aed, 30, 0.8);
        }
        break;
      case 'dmg':
        if (ev.kind === 'dot') this.floating.spawn(ev.x, 1.2, ev.z, String(ev.amount), 'dot');
        else if (ev.kind === 'litany' && ev.by === me) this.floating.spawn(ev.x, 2.6, ev.z, `${ev.amount.toLocaleString()}`, 'big');
        break;
      case 'boss':
        this.onBossEvent(ev);
        break;
      case 'spawn':
        // Codex + onboarding: only what this player actually encounters.
        if (Math.hypot(ev.x - this.player.x, ev.z - this.player.z) < 40) {
          this.codexDiscover('dead', ev.def);
          if (ev.def === 'deacon') this.onboarding.show('deacon');
        }
        break;
      case 'corpse':
        if (Math.hypot(ev.corpse.x - this.player.x, ev.corpse.z - this.player.z) < 12) this.onboarding.show('exhume');
        break;
    }
  }

  /** Records a Codex discovery; toasts only the first time. */
  private codexDiscover<K extends CodexKind>(kind: K, id: CodexIds[K]) {
    if (!this.codex.discover(kind, id)) return;
    const name = kind === 'area' ? AREAS[id as AreaId].name : deadName(id as CodexIds['dead']);
    this.codexPending.push(name);
  }

  /** Announces batched discoveries half a second after the first one lands. */
  private flushCodexToasts(now: number) {
    if (!this.codexPending.length) return;
    if (this.codexPendingSince < 0) this.codexPendingSince = now;
    if (now - this.codexPendingSince < 500) return;
    const names = this.codexPending;
    const list = names.length > 3 ? `${names.slice(0, 2).join(', ')} +${names.length - 2} more` : names.join(', ');
    this.hud.toast(`Codex updated: ${list}`, 'good');
    this.codexPending = [];
    this.codexPendingSince = -1;
  }

  /** Throttled onboarding triggers that depend on state rather than events. */
  private tickOnboarding(now: number) {
    this.flushCodexToasts(now);
    if (now - this.lastTipCheck < 400 || !this.player.alive) return;
    this.lastTipCheck = now;
    const cost = this.progression.waveCost();
    if (cost !== null && (this.character.gold ?? 0) >= cost) this.onboarding.show('wave');
    const { x, z } = this.player;
    for (const d of DOORS) {
      if (this.nav.isDoorOpen(d)) continue;
      const dx = Math.max(d.rect.x0 - x, 0, x - d.rect.x1);
      const dz = Math.max(d.rect.z0 - z, 0, z - d.rect.z1);
      if (Math.hypot(dx, dz) < 6) {
        this.onboarding.show('gate');
        break;
      }
    }
  }

  private telegraph(ev: Extract<SimEvent, { t: 'telegraph' }>) {
    const ms = ev.ms / 1000;
    audio.play(ev.kind === 'cone' || ev.kind === 'toll' ? 'tollSmall' : ev.kind === 'raise' ? 'raise' : ev.kind === 'curse' ? 'curse' : 'boneHit', ev.x, ev.z);
    if (ev.kind === 'toll') {
      // Bell-Tolled elite: a bronze ring fills in; step out before it sounds.
      const r = ev.r ?? AFFIX_TUNING.bellTolled.r;
      const bell = SPELL_FX.affix.bell;
      this.effects.decal({ tex: fx.disc(), color: bell, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.7, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.2 });
      this.effects.decal({ tex: fx.ring(), color: bell, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.9, fadeOut: 0.05 });
    } else if (ev.kind === 'cone') {
      const rot = Math.atan2(ev.tx - ev.x, ev.tz - ev.z);
      // Cone texture apex sits at the plane's bottom edge; shift so it starts at the caster.
      const E = SPELL_FX.enemy;
      this.effects.decal({ tex: fx.cone(), color: E.toll, x: ev.x, z: ev.z, r: ENEMIES.penitent.attackRange / 2, sz: 1, anchor: 1, rot: rot + Math.PI, duration: ms, opacity: 0.5, fadeIn: ms * 0.6, fadeOut: 0.05 });
      for (let k = 0; k < 3; k++) {
        this.effects.decal({ tex: fx.ring(), color: E.toll, x: ev.x, z: ev.z, r: ENEMIES.penitent.attackRange * (0.45 + k * 0.28), duration: 0.45, opacity: 0.8 - k * 0.2, growFrom: 0.2, delay: ms + k * 0.08 });
      }
    } else if (ev.kind === 'slam') {
      this.effects.decal({ tex: fx.disc(), color: SPELL_FX.enemy.slam, x: ev.tx, z: ev.tz, r: 1.9, duration: ms, opacity: 0.7, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.4 });
    } else if (ev.kind === 'raise') {
      const from = { x: ev.x, y: 1.8, z: ev.z };
      this.effects.beam(from, () => ({ x: ev.tx, y: 0.3, z: ev.tz }), SPELL_FX.enemy.rot, 0.05, ms);
      this.effects.decal({ tex: fx.sigil(), color: SPELL_FX.enemy.rot, x: ev.tx, z: ev.tz, r: 1, duration: ms, opacity: 0.8, spin: 3 });
    } else if (ev.kind === 'curse') {
      this.effects.decal({ tex: fx.ring(), color: SPELL_FX.enemy.curse, x: ev.tx, z: ev.tz, r: 1.2, duration: ms, opacity: 0.85, growFrom: 2 });
      this.effects.decal({ tex: fx.glow(), color: SPELL_FX.enemy.curse, x: ev.tx, z: ev.tz, r: 1.4, duration: 0.3, opacity: 0.9, delay: ms });
    }
  }

  private zoneVisual(z: Zone) {
    const dur = Math.max(0.1, z.until - (this.sim?.time ?? this.mirror?.time ?? 0));
    const color = z.kind === 'toxic' ? SPELL_FX.enemy.toxic : SPELL_FX.miasma.deep;
    // Toxic (hostile) and rot (a detonated sac, now yours) pools are cracked ground; miasma is a sigil.
    const pool = z.kind === 'toxic' || z.kind === 'rot';
    const handles = [
      this.effects.decal({ tex: fx.disc(), color, x: z.x, z: z.z, r: z.r, duration: dur, opacity: z.kind === 'toxic' ? 0.5 : 0.66, growFrom: 0.3, fadeOut: 0.6 }),
      this.effects.decal({ tex: pool ? fx.cracks() : fx.sigil(), color: z.kind === 'toxic' ? SPELL_FX.enemy.rot : SPELL_FX.miasma.rot, x: z.x, z: z.z, r: z.r * 0.95, duration: dur, opacity: 0.22, spin: pool ? 0 : 0.6, fadeOut: 0.6 }),
    ];
    this.zoneFx.set(z.id, handles);
  }

  // --- Grave Surges ---

  private onSurge(ev: Extract<SimEvent, { t: 'surge' }>) {
    const S = SPELL_FX.surge;
    const ms = ev.durationMs / 1000;
    this.surgeFx?.kill();
    // The cracked crypt stays marked for the surge's whole life.
    this.surgeFx = this.effects.decal({ tex: fx.cracks(), color: S.crack, x: ev.x, z: ev.z, r: 3.6, duration: ms, opacity: 0.85, growFrom: 0.2, pulse: 2 });
    this.effects.decal({ tex: fx.ring(), color: S.glow, x: ev.x, z: ev.z, r: 5, duration: 1.2, opacity: 1, growFrom: 0.1 });
    this.effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 60, color: S.glow, spread: 1.2, speed: 3, up: 3, life: 1.2, size: 0.32 });
    this.effects.lightFlash(ev.x, 2, ev.z, S.glow, 60, 1.2);
    if (ev.crypt) {
      // The tomb's seal gives: grave-dust billows and bone chips scatter from its door.
      this.effects.emitSmoke({ x: ev.x, y: 0.6, z: ev.z, count: 18, color: 0x4a4250, spread: 1.4, speed: 1.2, up: 1.4, life: 2.2, size: 2.2, shrink: -0.8 });
      this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 30, color: SPELL_FX.detonate.bone, spread: 0.8, speed: 4, up: 3, life: 0.9, size: 0.14, gravity: 9 });
    }
    audio.play('gate', ev.x, ev.z);
    if (ev.area === this.area) {
      this.hud.banner('Grave Surge', `A crypt cracks open in ${AREAS[ev.area].name} — hold it back for its offering`, 3400);
      this.rig.shake(0.35);
    } else this.hud.toast(`A Grave Surge erupts in ${AREAS[ev.area].name}`, 'err');
  }

  private onSurgeCleared(ev: Extract<SimEvent, { t: 'surgeCleared' }>) {
    this.surgeFx?.kill();
    this.surgeFx = null;
    const near = this.area === ev.area || Math.hypot(ev.x - this.player.x, ev.z - this.player.z) < 38;
    if (!this.player.alive || !near) return;
    this.hud.banner('Surge Quelled', 'The crypt yields its offering', 3200);
    audio.play('levelUp');
    // Personal reward: a guaranteed item from the area's table plus bonus gold.
    const level = AREAS[ev.area].level;
    const gold = Math.round((24 + 10 * level) * waveModifiers(this.bossWaveTier()).rewardMult * DIFFICULTIES[this.worldDifficulty()].rewardMult);
    this.loot.item(ev.x, ev.z, rollItem(ev.area));
    this.loot.gold(ev.x, ev.z, gold);
    this.effects.emit({ x: ev.x, y: 0.4, z: ev.z, count: 70, color: SPELL_FX.surge.glow, spread: 1, speed: 1.2, up: 4, life: 1.4, size: 0.34 });
    this.effects.lightFlash(ev.x, 2, ev.z, SPELL_FX.surge.glow, 70, 1.2);
  }

  private onKill(ev: Extract<SimEvent, { t: 'death' }>) {
    // Soul Harvest: kills credited to you (thralls and DoTs credit their owner).
    if (ev.killer === this.selfId && this.player.alive && this.player.addSouls(1)) this.onSoulsCharged();
    // Personal rewards for kills in (or right next to) your area.
    const near = Math.hypot(ev.x - this.player.x, ev.z - this.player.z) < 38;
    if (!this.player.alive || !near) return;
    const reward = rollKill(ev.def, ev.area, ev.level, ev.elite, this.bossWaveTier(), Math.random, this.worldDifficulty());
    this.loot.gold(ev.x, ev.z, reward.gold);
    if (reward.shards) this.loot.shard(ev.x, ev.z, reward.shards);
    for (const item of reward.items) this.loot.item(ev.x, ev.z, item);
    this.gainXp(reward.xp, ev.x, ev.z);
    this.progression.recordKill(ev.area);
    this.checkUnlocks();
  }

  private bossWaveTier() {
    return this.sim?.waveTier ?? this.mirror?.waveTier ?? 0;
  }

  private onDifficultySetting(d: Difficulty) {
    if (this.sim && this.isAuthority()) {
      if (this.sim.difficulty === d) return;
      this.sim.difficulty = d;
      this.hud.toast(`Difficulty: ${DIFFICULTIES[d].name} — the next dead to rise feel it`, 'good');
    } else if (this.mirror && this.mirror.difficulty !== d) {
      this.hud.toast(`The world keeper's difficulty applies (${DIFFICULTIES[this.mirror.difficulty].name})`);
    }
  }

  /** The difficulty the world is running at: yours solo/as host, the host's as a guest. */
  private worldDifficulty(): Difficulty {
    return this.sim?.difficulty ?? this.mirror?.difficulty ?? settings.difficulty;
  }

  private onSoulsCharged() {
    const p = this.player;
    const S = SPELL_FX.souls;
    this.floating.spawn(p.x, 2.6, p.z, 'Soul Harvest', 'info');
    this.hud.toast('Soul Harvest — your next Marrow Spear, Miasma or Black Litany is free and 50% larger', 'good');
    audio.play('shard');
    this.effects.emit({ x: p.x, y: 0.3, z: p.z, count: 50, color: S.jade, spread: 1.2, speed: 1.4, up: 3, life: 1, size: 0.3, inward: true });
    this.effects.lightFlash(p.x, 1.5, p.z, S.jade, 30, 0.6);
  }

  private gainXp(xp: number, x: number, z: number) {
    const gained = this.progression.addXp(xp);
    if (Math.random() < 0.35) this.floating.spawn(x, 2, z, `+${xp} xp`, 'xp');
    if (gained > 0) {
      this.refreshStats();
      this.player.hp = this.player.stats.maxHp;
      this.player.essence = this.player.stats.maxEssence;
      this.hud.banner(`Level ${this.character.level}`, 'The dead answer you more readily', 2600);
      audio.play('levelUp');
      this.effects.emit({ x: this.player.x, y: 0.2, z: this.player.z, count: 90, color: 0xf1d9a8, spread: 0.8, speed: 0.8, up: 5, life: 1.5, size: 0.35 });
      this.effects.decal({ tex: fx.sigil(), color: 0xe2c98f, x: this.player.x, z: this.player.z, r: 2.4, duration: 1.8, opacity: 1, growFrom: 0.2, spin: 1.2 });
      this.effects.lightFlash(this.player.x, 2, this.player.z, 0xf1d9a8, 50, 1);
    }
  }

  private checkUnlocks() {
    for (const id of AREA_ORDER) {
      const u = AREAS[id].unlock;
      if (!u || this.progression.isUnlocked(id)) continue;
      if (this.progression.kills(u.area) >= u.kills && this.progression.unlock(id)) {
        this.nav.setUnlocked(this.progression.local.unlocked);
        for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d));
        this.hud.banner('A seal breaks', `${AREAS[id].name} lies open`, 3800);
        const door = DOORS.find((d) => d.b === id);
        if (door) audio.play('gate', (door.rect.x0 + door.rect.x1) / 2, (door.rect.z0 + door.rect.z1) / 2);
        this.rig.shake(0.3);
        void this.progression.flush();
      }
    }
  }

  private onHurt(raw: number, from: string, x: number, z: number) {
    if (!this.player.alive) return;
    const myThralls = [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId).length;
    const ward = this.discipline.mods.wardPerThrall * myThralls;
    const now = this.now;
    const taken = this.player.takeDamage(raw, ward, now);
    this.cancelRecall();
    if (taken >= 1) this.floating.spawn(this.player.x, 2, this.player.z, `-${Math.round(taken)}`, 'hurt');
    this.hud.hitFlash();
    audio.play('hurt');
    this.rig.shake(from === 'boss' ? 0.35 : 0.12);
    if (Math.random() < 0.35) this.avatar.c.playOnce('hurt', 1.6);
    if (from === 'cone' || from === 'boss') {
      this.effects.emit({ x: this.player.x, y: 1, z: this.player.z, count: 10, color: SPELL_FX.enemy.curse, spread: 0.3, speed: 2, up: 1, life: 0.4, size: 0.25 });
    }
    if (from === 'toll' && this.player.alive) {
      // Bell-Tolled ring: a brief stun.
      this.player.rootedUntil = Math.max(this.player.rootedUntil, now + AFFIX_TUNING.bellTolled.stunMs);
      this.floating.spawn(this.player.x, 2.5, this.player.z, 'Stunned', 'info');
      this.effects.emit({ x: this.player.x, y: 1.8, z: this.player.z, count: 12, color: SPELL_FX.affix.bell, spread: 0.3, speed: 1.2, up: 0.4, life: 0.5, size: 0.2 });
    }
    if (!this.player.alive) this.onDeath();
  }

  private onDeath() {
    this.deadUntil = this.now + RESPAWN_MS;
    this.attackTarget = null;
    this.avatar.c.playOnce('death', 1);
    audio.play('playerDeath');
    this.hud.death(true, 'The Chapterhouse will call you back…');
    this.closePanels();
  }

  private respawn() {
    this.deadUntil = 0;
    this.player.revive();
    this.player.teleport(PLAYER_SPAWN.x, PLAYER_SPAWN.z);
    this.rig.snap(this.player.x, this.player.z);
    this.avatar.c.setLoop('idle');
    this.avatar.c.playOnce('dig', 1.2);
    this.hud.death(false);
    this.hud.toast('You rise again in the Chapterhouse. Nothing was lost.', 'good');
  }

  private onBossEvent(ev: Extract<SimEvent, { t: 'boss' }>) {
    const ms = (ev.ms ?? 0) / 1000;
    switch (ev.kind) {
      case 'awaken':
        this.codexDiscover('dead', 'prelate');
        audio.play('bossAwaken', ev.x, ev.z);
        this.hud.banner('The Bell-Sworn Prelate', 'The Sundered Bell tolls for you', 3500);
        this.effects.lightFlash(ev.x, 3, ev.z, 0xa26bff, 90, 1.6);
        this.effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 160, color: 0xb58cff, spread: 3, speed: 4, up: 4, life: 1.6, size: 0.5 });
        this.rig.shake(0.6);
        for (const g of ['west', 'east', 'north']) this.worldView.setCandleGroup(g, true);
        break;
      case 'phase':
        this.hud.banner(ev.phase === 2 ? 'The Procession' : 'The Bell Breaks', ev.phase === 2 ? 'Penitents file in from the aisles' : 'The Prelate is enraged', 2600);
        this.worldView.setCandleGroup(ev.phase === 2 ? 'west' : 'east', false);
        this.rig.shake(0.5);
        break;
      case 'toll':
        if (ms === 0) audio.play('bossToll', ev.x, ev.z);
        if (ms > 0) this.effects.decal({ tex: fx.disc(), color: SPELL_FX.boss.bronze, x: ev.x, z: ev.z, r: ev.r ?? 6.5, duration: ms, opacity: 0.75, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.15 });
        else {
          for (let k = 0; k < 3; k++) this.effects.decal({ tex: fx.ring(), color: SPELL_FX.boss.bronze, x: ev.x, z: ev.z, r: (ev.r ?? 6.5) * (0.8 + k * 0.25), duration: 0.6, opacity: 1 - k * 0.25, growFrom: 0.1, delay: k * 0.07 });
          this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 70, color: SPELL_FX.boss.bronze, spread: 2, speed: 7, up: 1, life: 0.7, size: 0.35 });
          this.effects.lightFlash(ev.x, 3, ev.z, SPELL_FX.boss.bronze, 60, 0.6);
          this.rig.shake(0.4);
        }
        break;
      case 'slam':
      case 'rain': {
        const circles = ev.targets ?? [[ev.x, ev.z]];
        for (const [x, z] of circles) {
          if (ms > 0) this.effects.decal({ tex: fx.disc(), color: SPELL_FX.boss.bronze, x, z, r: ev.r ?? 2.3, duration: ms, opacity: 0.8, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.3 });
          else {
            this.effects.emit({ x, y: 0.5, z, count: 24, color: SPELL_FX.boss.shard, spread: 0.6, speed: 3, up: 2, life: 0.6, size: 0.25, gravity: 6 });
            this.effects.flash({ x, y: 0.6, z, color: SPELL_FX.boss.bronze, size: 2.2, duration: 0.25 });
            this.effects.emitSmoke({ x, y: 0.3, z, count: 5, color: 0x3a3340, spread: 0.8, speed: 1.4, up: 0.6, life: 1, size: 1.4 });
            this.effects.spikeLine(x - 0.5, z, 1, 0, 1.2, 1.2);
          }
        }
        if (ms === 0) {
          this.rig.shake(0.25);
          audio.play('bossSlam', ev.x, ev.z);
        }
        break;
      }
      case 'summon':
        for (const [x, z] of ev.targets ?? []) {
          this.effects.decal({ tex: fx.cracks(), color: SPELL_FX.boss.spirit, x, z, r: 2.4, duration: 2, opacity: 0.9, growFrom: 0.3 });
          this.effects.emit({ x, y: 0.4, z, count: 30, color: SPELL_FX.boss.spirit, spread: 0.8, speed: 0.6, up: 2.5, life: 1.2, size: 0.3 });
        }
        break;
      case 'defeated':
        audio.play('bossDefeat', ev.x, ev.z);
        this.prelate.hide();
        for (const g of ['west', 'east', 'north']) this.worldView.setCandleGroup(g, true);
        if (ev.killer) {
          this.hud.banner('The Bell Falls Silent', 'The Prelate is unmade — for now', 4200);
          this.progression.local.bossKills++;
          this.progression.saveLocal();
          const reward = rollBoss(this.bossWaveTier(), Math.random, this.worldDifficulty());
          this.loot.gold(ev.x, ev.z, reward.gold);
          this.loot.shard(ev.x, ev.z, reward.shards);
          for (const item of reward.items) this.loot.item(ev.x, ev.z, item);
          this.gainXp(reward.xp, ev.x, ev.z);
          this.effects.lightFlash(ev.x, 3, ev.z, 0xc6a4ff, 100, 2);
          this.rig.shake(0.7);
        }
        break;
    }
  }

  // -------------------------------------------------------------------------
  // Frame
  // -------------------------------------------------------------------------

  update(dt: number, now: number) {
    if (!this.ready) return;
    this.now = now;
    const p = this.player;

    // Death / respawn.
    if (!p.alive && this.deadUntil && now >= this.deadUntil) this.respawn();

    this.updateCursor();

    // Hold-to-steer: dragging the mouse keeps re-targeting the ground.
    if (this.mouse.down && p.alive && !this.attackTarget && !this.mouse.shift && !this.pendingInteract) {
      p.moveTo(this.groundPoint.x, this.groundPoint.z);
    }

    // Auto-attack: chase into range, then Bone Needle.
    if (this.attackTarget && p.alive) {
      const tgt = this.attackTargetPos();
      if (!tgt) this.attackTarget = null;
      else {
        const t: CastTarget = this.attackTarget.kind === 'boss' ? { ...tgt, boss: true } : { ...tgt, enemyId: this.attackTarget.id };
        const short = this.abilities.shortfall('bone_needle', t);
        if (short > 0 && !this.mouse.shift) p.moveTo(tgt.x, tgt.z);
        else {
          p.stop();
          if (this.abilities.ready('bone_needle', now)) this.abilities.cast('bone_needle', t, now);
        }
      }
    }

    // Keyboard fallback movement.
    const kd = {
      x: (this.keys.has('d') || this.keys.has('arrowright') ? 1 : 0) - (this.keys.has('a') || this.keys.has('arrowleft') ? 1 : 0),
      z: (this.keys.has('s') || this.keys.has('arrowdown') ? 1 : 0) - (this.keys.has('w') || this.keys.has('arrowup') ? 1 : 0),
    };
    if (kd.x || kd.z) {
      this.attackTarget = null;
      this.pendingInteract = null;
      this.cancelRecall();
    }
    const moved = p.update(dt, now, kd.x || kd.z ? kd : null);
    if (moved) this.cancelRecall();

    if (this.recallAt && now >= this.recallAt) {
      this.cancelRecall();
      this.teleportTo(PLAYER_SPAWN.x, PLAYER_SPAWN.z);
    }

    // Reached an interactable?
    if (this.pendingInteract && Math.hypot(this.pendingInteract.x - p.x, this.pendingInteract.z - p.z) < INTERACT_RANGE) {
      this.interact(this.pendingInteract);
    }

    // Area transitions.
    const area = p.area ?? this.area;
    if (area !== this.area) this.enterArea(area);

    // Authoritative world (host/solo) or mirror (guest).
    if (this.sim && this.isAuthority()) {
      this.sim.setPlayer({ id: this.selfId, x: p.x, z: p.z, alive: p.alive, area: p.alive ? p.area : null });
      for (const [id, r] of this.remotes) {
        this.sim.setPlayer({ id, x: r.tx, z: r.tz, alive: r.hpFrac > 0, area: this.nav.areaAt(r.tx, r.tz) });
      }
      const events = this.sim.step(dt);
      for (const ev of events) this.handleEvent(ev);
      if (this.realtime.connected) {
        this.realtime.sendEvents(events);
        if (now - this.lastSnapshot >= SNAPSHOT_MS) {
          this.lastSnapshot = now;
          this.snapshotCount++;
          this.realtime.sendSnapshot(makeSnapshot(this.sim, this.snapshotCount % 20 === 0));
        }
      }
    } else this.mirror?.update(dt);

    if (this.realtime.connected && now - this.lastMoveSent >= MOVE_SEND_MS) {
      this.lastMoveSent = now;
      this.realtime.sendMove({ x: p.x, z: p.z, facing: p.facing, moving: p.moving, hpFrac: p.hp / p.stats.maxHp });
    }

    // Loot pickup.
    const got = this.loot.update(dt, p.x, p.z, (d) => {
      if (!this.inventory.add(d)) {
        this.floating.spawn(p.x, 2.4, p.z, 'Reliquary full', 'info');
        return false;
      }
      return true;
    });
    if (got.gold) {
      audio.play('coin');
      this.progression.addGold(got.gold);
      this.floating.spawn(p.x, 2.1, p.z, `+${got.gold}g`, 'gold');
    }
    if (got.shards) {
      audio.play('shard');
      this.progression.addShards(got.shards);
      this.floating.spawn(p.x, 2.3, p.z, `+${got.shards} soul shard${got.shards > 1 ? 's' : ''}`, 'shard');
    }
    if (got.items.length) audio.play('item');
    for (const item of got.items) this.hud.toast(`${itemMeta(item.item_id).name}${item.quantity > 1 ? ` ×${item.quantity}` : ''}`, 'good');

    // Visuals.
    this.avatar.update(dt, p.x, p.z, p.facing, p.moving, p.stats.moveSpeed);
    for (const tick of this.lineupTicks) tick(dt);
    for (const r of this.remotes.values()) {
      const k = Math.min(1, dt * 10);
      const x = r.avatar.c.root.position.x + (r.tx - r.avatar.c.root.position.x) * k;
      const z = r.avatar.c.root.position.z + (r.tz - r.avatar.c.root.position.z) * k;
      r.avatar.update(dt, x, z, r.facing, r.moving, 5.4);
    }
    this.views.sync(this.enemiesMap(), this.thrallsMap(), dt, p.x, p.z);
    if (now - this.lastPrune > 2000) {
      this.lastPrune = now;
      this.views.pruneCorpses(this.corpsesMap());
    }
    this.zoneAmbience(dt);
    this.wadeRipples(dt);
    this.prelate.sync(this.bossState(), dt);
    this.rig.update(dt, p.x, p.z);
    audio.setListener(p.x, p.z);
    if (p.moving) {
      this.stepT -= dt * p.stats.moveSpeed;
      if (this.stepT <= 0) {
        this.stepT = 1.6;
        audio.play('step', p.x, p.z, this.area === 'graves' ? 0.8 : 1.2);
      }
    }
    this.rig.camera.updateMatrixWorld();
    this.occlusionFocus.set(p.x, 1.1, p.z);
    updateOcclusion(this.rig.camera, this.occlusionFocus);
    this.moon.position.set(p.x - 14, 30, p.z + 12);
    this.moon.target.position.set(p.x, 0, p.z);
    this.tickMilestones(dt);
    const vh = window.innerHeight * getRuntime().renderer.getPixelRatio();
    this.worldView.update(dt, p.x, p.z, this.rig.camera, vh);
    this.effects.update(dt, this.rig.camera, vh);
    this.floating.update(dt, this.rig.camera);
    this.tickOnboarding(now);
    this.updateHud(now);
  }

  /** Milestone banners when the world's Wave Speed crosses one, and Nightfall's darker moon. */
  private tickMilestones(dt: number) {
    const tier = this.bossWaveTier();
    if (tier !== this.seenWaveTier) {
      if (this.seenWaveTier >= 0) {
        for (const m of WAVE_MILESTONES) {
          if (tier >= m.tier && this.seenWaveTier < m.tier) this.hud.banner(m.name, m.blurb, 3200);
          else if (tier < m.tier && this.seenWaveTier >= m.tier) this.hud.toast(`${m.name} fades`);
        }
      }
      this.seenWaveTier = tier;
    }
    const target = milestoneActive('nightfall', tier) ? 1 : 0;
    this.nightK += (target - this.nightK) * Math.min(1, dt * 0.8);
    // Intensity only (never toggle light visibility — that recompiles shaders).
    this.moon.intensity = 2.4 * (1 - 0.6 * this.nightK);
    this.hemi.intensity = 0.95 * (1 - 0.3 * this.nightK);
  }

  /** Bodies wading through the nave's flood and the graveyard puddles ring the water. */
  private wadeRipples(dt: number) {
    this.rippleT -= dt;
    if (this.rippleT > 0) return;
    this.rippleT = 0.15;
    this.rippleCursor++;
    const p = this.player;
    if (p.moving && this.rippleCursor % 2 === 0) this.worldView.addRipple(p.x, p.z, 0.9);
    for (const r of this.remotes.values()) if (r.moving && this.rippleCursor % 3 === 0) this.worldView.addRipple(r.tx, r.tz, 0.8);
    // One other wader per tick, round-robin, so a horde can't flood the 16 ripple slots.
    const near = (b: { x: number; z: number; moving: boolean }) =>
      b.moving && Math.abs(b.x - p.x) < 24 && Math.abs(b.z - p.z) < 20 && this.worldView.isWet(b.x, b.z);
    let n = 0;
    for (const e of this.enemiesMap().values()) if (near(e)) n++;
    for (const t of this.thrallsMap().values()) if (near(t)) n++;
    if (!n) return;
    let pick = this.rippleCursor % n;
    for (const b of [this.enemiesMap(), this.thrallsMap()]) {
      for (const e of b.values()) {
        if (!near(e)) continue;
        if (pick-- === 0) return this.worldView.addRipple(e.x, e.z, 0.7);
      }
    }
  }

  /** Living zones churn: miasma sheds spores, toxic pools bubble. */
  private zoneAmbience(dt: number) {
    const zones = this.mirror?.zones ?? this.sim?.zones;
    if (!zones) return;
    for (const z of zones.values()) {
      if (Math.abs(z.x - this.player.x) > 30 || Math.abs(z.z - this.player.z) > 26) continue;
      const rate = z.r * z.r * 1.2;
      if (Math.random() < dt * rate) {
        const a = Math.random() * Math.PI * 2;
        const d = Math.sqrt(Math.random()) * z.r;
        const x = z.x + Math.cos(a) * d;
        const zz = z.z + Math.sin(a) * d;
        if (z.kind === 'miasma' || z.kind === 'rot') {
          this.effects.emit({ x, y: 0.2, z: zz, count: 1, color: SPELL_FX.miasma.rot, spread: 0.2, speed: 0.15, up: 0.9, life: 1.4, size: 0.22, drag: 0.5 });
          if (Math.random() < 0.6) this.effects.emitSmoke({ x, y: 0.3, z: zz, count: 1, color: 0x56662a, spread: 0.3, speed: 0.2, up: 0.3, life: 2, size: 1.6, shrink: -0.8, drag: 0.5 });
        } else if (z.kind === 'toxic') {
          this.effects.emit({ x, y: 0.1, z: zz, count: 1, color: SPELL_FX.enemy.toxic, spread: 0.1, speed: 0.05, up: 0.6, life: 0.8, size: 0.28 });
        }
      }
    }
  }

  private attackTargetPos(): { x: number; z: number } | null {
    const t = this.attackTarget;
    if (!t) return null;
    if (t.kind === 'boss') {
      const b = this.bossState();
      return b.active ? { x: b.x, z: b.z } : null;
    }
    const e = this.enemiesMap().get(t.id);
    return e && e.state !== 'dead' ? { x: e.x, z: e.z } : null;
  }

  private enterArea(area: AreaId) {
    this.area = area;
    audio.setArea(area);
    const def = AREAS[area];
    this.hud.banner(def.name, def.subtitle);
    this.codexDiscover('area', area);
    (this.scene.fog as THREE.FogExp2).color.set(def.ambient.fog);
    this.hemi.color.set(def.ambient.hemiSky);
    this.hemi.groundColor.set(def.ambient.hemiGround);
    this.moon.color.set(def.ambient.moon);
    void this.progression.flush();
  }

  private areaProgress(): string {
    const here = this.area;
    if (AREAS[here].safe) return 'Sanctuary. The dead cannot follow you here.';
    const next = AREA_ORDER.find((id) => AREAS[id].unlock?.area === here && !this.progression.isUnlocked(id));
    if (next) {
      const u = AREAS[next].unlock!;
      return `Slay <b>${Math.min(u.kills, this.progression.kills(here))}/${u.kills}</b> to unseal ${AREAS[next].name}`;
    }
    if (here === 'sanctum') {
      return this.bossState().active
        ? 'The Prelate walks.'
        : `Offer <b>${this.progression.local.shards}/${BOSS_SUMMON_SHARDS}</b> soul shards at the Sundered Bell`;
    }
    return `<b>${this.progression.kills(here)}</b> slain here · Level ${AREAS[here].level} dead`;
  }

  private lastMapDraw = 0;
  private updateHud(now: number) {
    const p = this.player;
    const loc = this.progression.local;
    const hover = this.hover;
    let target: HudFrame['target'] = null;
    const focusEnemy =
      hover?.kind === 'enemy' ? this.enemiesMap().get(hover.id) : this.attackTarget?.kind === 'enemy' ? this.enemiesMap().get(this.attackTarget.id) : undefined;
    if (focusEnemy) {
      const d = ENEMIES[focusEnemy.def];
      const statuses: { icon: string; label: string; n: number }[] = [];
      if (focusEnemy.fracture) statuses.push({ icon: 'art/status/fracture.png', label: 'Fracture', n: focusEnemy.fracture });
      if (focusEnemy.withered) statuses.push({ icon: 'art/status/withered.png', label: 'Withered', n: focusEnemy.withered });
      if (focusEnemy.slowT > 0) statuses.push({ icon: 'art/status/void-rot.png', label: 'Miasma', n: 1 });
      if ((focusEnemy.bleedT ?? 0) > 0) statuses.push({ icon: 'art/status/hemorrhage.png', label: 'Hemorrhage', n: 1 });
      if ((focusEnemy.chillT ?? 0) > 0) statuses.push({ icon: CHILL_ICON, label: 'Chilled', n: 1 });
      if ((focusEnemy.sanctT ?? 0) > 0) statuses.push({ icon: 'art/status/sanctified.png', label: 'Sanctified', n: 1 });
      const affix = focusEnemy.affix ? ELITE_AFFIXES[focusEnemy.affix] : null;
      target = {
        name: d.name,
        elite: focusEnemy.elite,
        affix: focusEnemy.affix && affix ? { id: focusEnemy.affix, name: affix.name } : null,
        hp: focusEnemy.hp,
        maxHp: focusEnemy.maxHp,
        statuses,
        // The affix is the actionable read on an elite; the lore line otherwise.
        blurb: affix ? affix.blurb : d.blurb,
      };
    } else if (hover?.kind === 'interact') {
      this.hud.prompt(`<kbd>Click</kbd>${hover.it.label}`);
    }
    if (hover?.kind !== 'interact') this.hud.prompt(null);
    const b = this.bossState();
    const myThralls = [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId);
    const saveText =
      this.progression.state === 'retrying' || this.inventory.state === 'retrying'
        ? { text: 'Save failed — retrying…', warn: true }
        : this.progression.state === 'saving' || this.inventory.state === 'saving'
          ? { text: 'Saving…', warn: false }
          : { text: OFFLINE ? 'Offline save ✓' : 'Saved ✓', warn: false };

    this.hud.update({
      hp: p.hp,
      maxHp: p.stats.maxHp,
      barrier: p.barrier,
      essence: p.essence,
      maxEssence: p.stats.maxEssence,
      level: this.character.level,
      xp: this.character.experience,
      xpNext: xpToNext(this.character.level),
      slots: HOTBAR.map((id) => {
        const empowered = this.abilities.empowered(id);
        return {
          left: p.cooldownLeft(id, now),
          total: ABILITIES[id].cooldownMs,
          affordable: empowered || p.essence >= ABILITIES[id].essenceCost,
          empowered,
        };
      }),
      souls: p.souls,
      soulsMax: SOUL_HARVEST.souls,
      thralls: myThralls.length,
      thrallCap: this.discipline.mods.thrallCap,
      gold: Math.floor(this.character.gold ?? 0),
      shards: loc.shards,
      damageTier: loc.damageTier,
      damagePct: damageBonusPct(loc.damageTier),
      damageCost: this.progression.damageCost(),
      waveOwned: loc.waveTierOwned,
      waveActive: loc.waveTierActive,
      wavePct: waveModifiers(loc.waveTierActive).speedPct,
      waveCost: this.progression.waveCost(),
      areaName: AREAS[this.area].name,
      areaProgress: this.areaProgress(),
      save: saveText,
      target,
      boss: b.active ? { name: 'The Bell-Sworn Prelate', phase: b.phase, hp: b.hp, maxHp: b.maxHp } : null,
    });

    if (now - this.lastMapDraw > 100) {
      this.lastMapDraw = now;
      this.hud.drawMap({
        px: p.x,
        pz: p.z,
        facing: p.facing,
        unlocked: (a) => this.progression.isUnlocked(a),
        enemies: this.enemiesMap().values(),
        thralls: this.thrallsMap().values(),
        allies: [...this.remotes.values()].map((r) => ({ x: r.tx, z: r.tz })),
        corpses: this.corpsesMap().values(),
        boss: b.active ? { x: b.x, z: b.z } : null,
        waystones: AREA_ORDER.flatMap((a) => AREAS[a].interactables.filter((i) => i.kind === 'waystone')),
      });
      this.hud.party([
        {
          id: this.selfId,
          name: `${this.character.class_name ? this.discipline.name : 'You'} (you)`,
          discipline: this.discipline.epithet,
          portrait: `art/portraits/${this.discipline.id}.webp`,
          hpFrac: p.hp / p.stats.maxHp,
        },
        ...[...this.remotes.values()].map((r) => {
          const d = disciplineFor(r.info.classIndex);
          return { id: r.info.id, name: r.info.name, discipline: d.name, portrait: `art/portraits/${d.id}.webp`, hpFrac: r.hpFrac };
        }),
      ]);
    }
  }

  // -------------------------------------------------------------------------
  // Debug (DEV only) — numeric QA hook (preview screenshots are unreliable here)
  // -------------------------------------------------------------------------

  private installDebug() {
    const dbg = {
      scene: this.scene,
      camera: this.rig.camera,
      player: this.player,
      sim: () => this.sim,
      progression: this.progression,
      inventory: this.inventory,
      advance: (seconds: number) => getRuntime().advance(seconds),
      net: () => ({ id: this.realtime.selfId, ...this.realtime.stats, connected: this.realtime.connected, host: this.realtime.isHost, instance: this.realtime.instance, mirror: this.mirror ? { enemies: this.mirror.enemies.size, corpses: this.mirror.corpses.size } : null }),
      zoom: (z: number) => this.rig.setZoom(z),
      clear: () => {
        const a = this.player.area;
        if (a) this.sim?.clearArea(a);
        this.sim?.corpses.clear();
      },
      ring: (def: keyof typeof ENEMIES, n: number, r: number, elite = false) => {
        const a = this.player.area ?? 'graves';
        const ids: number[] = [];
        for (let i = 0; i < n; i++) {
          const ang = (i / n) * Math.PI * 2;
          const e = this.sim?.spawnEnemy(def, a, this.player.x + Math.cos(ang) * r, this.player.z + Math.sin(ang) * r, elite, false);
          if (e) ids.push(e.id);
        }
        return ids;
      },
      freeze: (on = true) => {
        for (const e of this.sim?.enemies.values() ?? []) e.speed = on ? 0 : 2.5;
      },
      counts: () => ({ ...this.views.counts(), loot: this.loot.count, remotes: this.remotes.size, frameMs: getRuntime().frameMs }),
      teleport: (x: number, z: number) => this.teleportTo(x, z),
      /** Perf snapshot: one direct render's draw calls/triangles, scene census, and CPU update cost. */
      perf: (benchFrames = 120) => {
        const r = getRuntime().renderer;
        r.info.autoReset = false;
        r.info.reset();
        r.render(this.scene, this.rig.camera);
        const render = { calls: r.info.render.calls, triangles: r.info.render.triangles, points: r.info.render.points };
        r.info.autoReset = true;
        let skinned = 0;
        let meshes = 0;
        let instanced = 0;
        let lights = 0;
        const types: Record<string, number> = {};
        let sceneTris = 0;
        let casters = 0;
        let casterTris = 0;
        this.scene.traverse((o) => {
          if (!o.visible) return;
          types[o.type] = (types[o.type] ?? 0) + 1;
          const g = (o as THREE.Mesh).geometry as THREE.BufferGeometry | undefined;
          if ((o as THREE.Mesh).isMesh && g) {
            const n = (g.index ? g.index.count : g.attributes.position.count) / 3;
            sceneTris += n * ((o as THREE.InstancedMesh).isInstancedMesh ? (o as THREE.InstancedMesh).count : 1);
          }
          if ((o as THREE.Mesh).isMesh && o.castShadow && g) {
            casters++;
            casterTris += ((g.index ? g.index.count : g.attributes.position.count) / 3) * ((o as THREE.InstancedMesh).isInstancedMesh ? (o as THREE.InstancedMesh).count : 1);
          }
          if ((o as THREE.SkinnedMesh).isSkinnedMesh) skinned++;
          else if ((o as THREE.InstancedMesh).isInstancedMesh) instanced++;
          else if ((o as THREE.Mesh).isMesh) meshes++;
          if ((o as THREE.Light).isLight) lights++;
        });
        // CPU: game update only (sim + views + effects), no rendering.
        let now = this.now + 1;
        const t0 = performance.now();
        for (let i = 0; i < benchFrames; i++) this.update(1 / 60, (now += 1000 / 60));
        const updateMs = (performance.now() - t0) / benchFrames;
        let simMs = 0;
        if (this.sim) {
          const s0 = performance.now();
          for (let i = 0; i < benchFrames; i++) this.sim.step(1 / 60);
          simMs = (performance.now() - s0) / benchFrames;
        }
        return { ...render, sceneTris: Math.round(sceneTris), casters, casterTris: Math.round(casterTris), types, skinned, meshes, instanced, lights, programs: r.info.programs?.length ?? 0, geometries: r.info.memory.geometries, textures: r.info.memory.textures, updateMs, simMs, ...this.views.counts() };
      },
      goto: (a: AreaId) => {
        const r = AREAS[a].rect;
        this.teleportTo((r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2 + 4);
      },
      unlockAll: () => {
        for (const a of AREA_ORDER) this.progression.unlock(a);
        this.nav.setUnlocked(this.progression.local.unlocked);
        for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d));
      },
      gold: (n: number) => this.progression.addGold(n),
      shards: (n: number) => this.progression.addShards(n),
      xp: (n: number) => this.gainXp(n, this.player.x, this.player.z),
      spawn: (def: keyof typeof ENEMIES, elite = false, affix?: EliteAffix) => {
        const a = this.player.area ?? 'graves';
        return this.sim?.spawnEnemy(def, a, this.player.x + 3, this.player.z - 3, elite, false, affix).id;
      },
      /** Open a Grave Surge in the current area right now. */
      surge: () => {
        const a = this.player.area;
        if (a) this.sim?.startSurge(a);
        return this.sim?.surge ? { area: this.sim.surge.area, x: this.sim.surge.x, z: this.sim.surge.z } : null;
      },
      souls: (n = SOUL_HARVEST.souls) => {
        if (this.player.addSouls(n)) this.onSoulsCharged();
        return this.player.souls;
      },
      /** Drop a corpse at the cursor's ground point (Corpse Explosion QA). */
      corpse: (kind: 'normal' | 'resonant' | 'toxic' = 'normal', elite = false) => {
        const a = this.player.area ?? 'graves';
        const enemy = kind === 'resonant' ? 'penitent' : kind === 'toxic' ? 'sac' : 'robber';
        this.sim?.addCorpse(this.groundPoint.x, this.groundPoint.z, kind, enemy, elite, 0, 1, a);
      },
      boss: () => {
        this.teleportTo(BOSS_ARENA.x, BOSS_ARENA.z + 8);
        this.sendIntent({ t: 'summonBoss', by: this.selfId });
      },
      god: (on = true) => (this.player.god = on),
      /** README shot: the four discipline heroes standing in a row beside the player. */
      lineup: () => {
        const ids = ['ossuary', 'gravecaller', 'mourner', 'rotweaver'] as const;
        return ids.map((id, i) => {
          const d = disciplineFor([1, 2, 3, 4][i]);
          const a = new NecromancerAvatar(this.scene, d.color, false, d.modelSlug);
          const x = this.player.x - 3 + i * 2;
          this.scope.add(() => a.dispose());
          const tick = (dt: number) => a.update(dt, x, this.player.z + 1.8, 0, false, 5);
          this.lineupTicks.push(tick);
          return id;
        });
      },
      cast: (slot: HotbarSlot) => this.castSlot(slot),
      attackNearest: () => {
        let best: Enemy | null = null;
        for (const e of this.enemiesMap().values()) if (!best || Math.hypot(e.x - this.player.x, e.z - this.player.z) < Math.hypot(best.x - this.player.x, best.z - this.player.z)) best = e;
        if (best) this.attackTarget = { kind: 'enemy', id: best.id };
        return best?.id;
      },
      aimAtNearest: () => {
        let best: Enemy | null = null;
        for (const e of this.enemiesMap().values()) if (!best || Math.hypot(e.x - this.player.x, e.z - this.player.z) < Math.hypot(best.x - this.player.x, best.z - this.player.z)) best = e;
        if (!best) return null;
        const v = new THREE.Vector3(best.x, 0.9, best.z).project(this.rig.camera);
        this.mouse.x = ((v.x + 1) / 2) * window.innerWidth;
        this.mouse.y = ((1 - v.y) / 2) * window.innerHeight;
        return [best.id, Math.round(this.mouse.x), Math.round(this.mouse.y)];
      },
      mouse: (x: number, y: number) => {
        this.mouse.x = x;
        this.mouse.y = y;
      },
    };
    (window as unknown as { __cwDebug: typeof dbg }).__cwDebug = dbg;
    this.scope.add(() => delete (window as unknown as { __cwDebug?: unknown }).__cwDebug);
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  unmount() {
    this.ready = false;
    getRuntime().setView(null);
    this.realtime.disconnect();
    this.progression.dispose();
    this.inventory.dispose();
    this.scope.dispose();
    this.canvas.style.cursor = '';
    for (const r of this.remotes.values()) r.avatar.dispose();
    this.remotes.clear();
    this.views.dispose();
    this.prelate.dispose();
    this.loot.dispose();
    this.avatar.dispose();
    this.effects.dispose();
    this.worldView.dispose();
    this.scene.environment?.dispose();
    this.scene.clear();
  }
}

