import * as THREE from 'three';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import type { GameScene } from './SceneManager';
import { getRuntime, type RuntimeView } from '../app/GameRuntime';
import { Scope } from '../app/Scope';
import { ABILITIES, GRIMOIRE, HOTBAR, SIGNATURE_BY_DISCIPLINE, SIGNATURE_LEVEL, SOUL_HARVEST, SPELL_FX, unlockLevel, type AbilityId, type HotbarSlot } from '../content/abilities';
import { assignRite, loadLoadout, saveLoadout } from '../gameplay/loadout';
import { GrimoirePanel } from '../ui/GrimoirePanel';
import { preloadFxImages } from '../graphics/fxImages';
import { AREAS, AREA_ORDER, BOSS_SUMMON_SHARDS, CHAPTERHOUSE_RETURN, DOORS, PLAYER_SPAWN, type AreaId, type Interactable } from '../content/areas';
import { disciplineFor, type Discipline } from '../content/disciplines';
import { AFFIX_TUNING, ELITE_AFFIXES, ENEMIES, WAVE_THEMES, type EliteAffix, type EnemyId } from '../content/enemies';
import { HEALING_FLASKS, itemMeta } from '../content/items';
import { generateLayout, type NodePlacement } from '../content/layout';
import { GatherLoop, Skills } from '../gameplay/Gathering';
import { NODES, SKILLS, nodesForSkill, type SkillId } from '../gameplay/gatheringRules';
import type { LiveNode } from '../gameplay/gatherPlan';
import { STOP_TEXT } from '../gameplay/gatherPlan';
import { NodeViews } from '../graphics/NodeViews';
import { addToSlots } from '../gameplay/loot';
import { WAVE_MILESTONES, damageBonusPct, milestoneActive, waveModifiers } from '../content/upgrades';
import { DIFFICULTIES, type Difficulty } from '../content/difficulty';
import { BOONS, ascensionLevels, ascensionRewardMult, roman } from '../content/ascension';
import { AscensionPanel } from '../ui/AscensionPanel';
import { ClassPanel } from '../ui/ClassPanel';
import { changeDiscipline } from '../net/api';
import { onSettingsChange, settings, updateSettings } from '../app/settings';
import { selectAutoCombatAction } from '../gameplay/autoCombat';
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
import { beginAfkGather, gather, getInventory, getProfessions, OFFLINE, type GatherReply } from '../net/api';
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
import { Onboarding, type TipId } from '../ui/Onboarding';
import { CodexJournal, browserStorage, type CodexIds, type CodexKind } from '../gameplay/codexJournal';
import { deadName } from '../content/codex';
import { CURSOR } from '../ui/cursors';
import { audio } from '../audio/Audio';

const SNAPSHOT_MS = 100;
const MOVE_SEND_MS = 100;
const RESPAWN_MS = 4000;
const RECALL_MS = 1500;
const INTERACT_RANGE = 2.6;
/** Counsel shown the first time each newer kind of dead climbs out near the player. */
const FIRST_SIGHT_TIPS: Partial<Record<EnemyId, TipId>> = {
  censer: 'censer',
  wraith: 'wraith',
  rat: 'swarm',
  golem: 'golem',
};
/** Counsel shown the first time each level-gated Grimoire rite is placed on a key. */
const RITE_TIPS: Partial<Record<AbilityId, TipId>> = {
  wailing_skull: 'rite_skull',
  grave_step: 'rite_step',
  grave_frost: 'rite_frost',
  bone_mantle: 'rite_mantle',
};

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
  | { kind: 'node'; node: NodePlacement }
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
  /** Hotbar: the Grimoire loadout (keys 1–4), Corpse Explosion (slot 5) and this discipline's signature rite (slot 6). */
  private hotbar: AbilityId[] = HOTBAR;
  /** The four rites on keys 1–4 (Grimoire, L); remembered per character in browser storage. */
  private loadout: AbilityId[];
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
  /** Standing Ossuary Walls: their meshes, removed on wallGone. */
  private wallFx = new Map<number, THREE.Object3D>();
  /** The cracked-crypt marker of the running Grave Surge. */
  private surgeFx: Handle | null = null;

  private keys = new Set<string>();
  /** Scene time of the last procession banner (one per band, not one per breach). */
  private lastProcession = -1e9;
  private nextAutoCombatAt = 0;
  private autoTargetId: number | null = null;
  private autoAim: CastTarget | null = null;
  private queuedCast: { slot: HotbarSlot; target: CastTarget; until: number } | null = null;
  private mouse = { x: 0, y: 0, shift: false, aiming: false };
  private groundPoint = new THREE.Vector3();
  private hover: Hover = null;
  private attackTarget: { kind: 'enemy'; id: number } | { kind: 'boss' } | null = null;
  private pendingInteract: Interactable | null = null;
  /** Skilling: levels, the gathering loop and the node props (docs/PROFESSIONS-ROADMAP.md). */
  private skills = new Skills();
  private gathering!: GatherLoop;
  private nodeViews!: NodeViews;
  private gatherProg = 0;
  private lastNodeSync = 0;
  private skillLevels = new Map<SkillId, number>();
  private area: AreaId = 'acre';
  private deadUntil = 0;
  private recallAt = 0;
  private recallFx: Handle | null = null;
  private flaskCdUntil = 0;
  private ready = false;
  private dataReady: Promise<unknown> = Promise.resolve();
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
  private classPanel!: ClassPanel;
  private waystonePanel!: WaystonePanel;
  private codexPanel!: CodexPanel;
  private grimoirePanel!: GrimoirePanel;
  private ascensionPanel!: AscensionPanel;
  private codex!: CodexJournal;
  private onboarding!: Onboarding;
  private lastTipCheck = 0;
  /** Codex discoveries waiting to be announced as one toast (entering an area finds several at once). */
  private codexPending: string[] = [];
  private codexPendingSince = -1;

  constructor(
    private character: Character,
    private onLeave: () => void,
    private onClassChanged: (character: Character) => void,
  ) {
    this.discipline = disciplineFor(character.class_index);
    this.loadout = loadLoadout(browserStorage(), character.id, character.level ?? 1);
    this.hotbar = this.buildHotbar();
    this.progression = new Progression(character);
    this.applyBoons();
    this.inventory = new Inventory(character.id);
  }

  get camera() {
    return this.rig.camera;
  }

  /** At least one level-gated Grimoire rite is learned (the Grimoire is worth opening). */
  private grimoireUnlocked() {
    return GRIMOIRE.some((id) => unlockLevel(id) > 1 && this.character.level >= unlockLevel(id));
  }

  private buildHotbar(): AbilityId[] {
    return [...this.loadout, 'corpse_explosion', SIGNATURE_BY_DISCIPLINE[this.discipline.id]];
  }

  /** Grimoire: put a rite on key `slot + 1` (swapping if it sat on another key) and remember it. */
  private setRite(slot: number, id: AbilityId) {
    if (this.character.level < unlockLevel(id) || this.loadout[slot] === id) return;
    this.loadout = assignRite(this.loadout, slot, id);
    saveLoadout(browserStorage(), this.character.id, this.loadout);
    this.hotbar = this.buildHotbar();
    this.hud.setHotbar(this.hotbar);
    this.queuedCast = null;
    this.grimoirePanel.render();
    audio.play('click');
    const tip = RITE_TIPS[id];
    if (tip) this.onboarding.show(tip);
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
    this.nodeViews = new NodeViews(this.scene, this.layout.nodes);
    this.prelate = new PrelateView(this.scene, this.effects);
    this.loot = new LootView(this.scene, this.effects);

    const stats = deriveStats(this.character, [], this.discipline, this.progression.local.damageTier);
    this.player = new Player(stats, this.nav);
    this.player.soulsMax = Math.max(10, SOUL_HARVEST.souls - this.progression.boons.soulsDiscount);
    this.player.teleport(PLAYER_SPAWN.x, PLAYER_SPAWN.z);
    this.avatar = new NecromancerAvatar(this.scene, this.discipline.color, true, this.discipline.modelSlug);
    this.rig.snap(this.player.x, this.player.z);
    // Readability: a soft pool of discipline light and a thin ring under the hero.
    const follow = () => ({ x: this.player.x, z: this.player.z });
    this.effects.decal({ tex: fx.glow(), color: this.discipline.color, x: 0, z: 0, r: 2.2, duration: 1e9, opacity: 0.32, fadeIn: 0.01, follow });
    this.effects.decal({ tex: fx.ring(), color: this.discipline.color, x: 0, z: 0, r: 0.85, duration: 1e9, opacity: 0.55, fadeIn: 0.01, follow });
    // A small ground reticle follows the mouse independently of the hero ring.
    this.effects.decal({ tex: fx.ring(), color: 0xc6a4ff, x: 0, z: 0, r: 0.35, duration: 1e9, opacity: 0.5, fadeIn: 0.01, follow: () => ({ x: this.groundPoint.x, z: this.groundPoint.z }) });
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
        const h = this.hover?.kind === 'enemy' ? this.hover : this.attackTarget?.kind === 'enemy' ? this.attackTarget : this.autoTargetId !== null ? { id: this.autoTargetId } : null;
        const e = h ? this.enemiesMap().get(h.id) : undefined;
        return e && e.state !== 'rising' ? { x: e.x, z: e.z } : null;
      },
    });

    this.sim = new WorldSim(this.nav);
    this.sim.setCrypts(this.layout.crypts);
    this.sim.setNodes(this.layout.nodes);
    this.sim.waveTier = this.progression.local.waveTierActive;
    this.sim.difficulty = settings.difficulty;
    this.sim.ascension = this.progression.local.ascension;

    this.abilities = new AbilitySystem({
      selfId: this.selfId,
      player: this.player,
      discipline: this.discipline,
      avatar: this.avatar,
      effects: this.effects,
      enemies: () => this.enemiesMap(),
      boss: () => this.bossState(),
      corpses: () => this.corpsesMap(),
      thrallCount: () => [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId).length,
      send: (i) => this.sendIntent(i),
      number: (x, z, amount, kind) => this.floating.spawn(x, 1.6, z, Math.round(amount).toString(), kind === 'crit' ? 'crit' : 'hit'),
      shake: (a) => this.rig.shake(a),
      now: () => this.now,
    });

    this.gathering = new GatherLoop(
      {
        now: () => this.now,
        rand: Math.random,
        nav: this.nav,
        player: this.player,
        nodes: () => this.liveNodes(),
        live: (id) => this.nodeLive(id),
        bagFits: (itemId) => addToSlots(this.inventory.all, { item_id: itemId, quantity: 1 }) !== null,
        sendSuccess: (nodeId) => this.sendIntent({ t: 'gather', by: this.selfId, nodeId, successes: 1 }),
        post: async (nodeType, actions, keepalive, afk) => {
          // Settle the bag first so the server grants onto the same bag the client shows.
          if (!keepalive) await this.inventory.flush();
          return gather(this.character.id, nodeType, actions, keepalive, afk);
        },
        onCycle: (def, success, node) => this.onGatherCycle(def, success, node),
        onReply: (r) => this.onGatherReply(r),
        onStop: (reason, message) => {
          const text = message ?? STOP_TEXT[reason as keyof typeof STOP_TEXT] ?? null;
          if (text) this.floating.spawn(this.player.x, 2.4, this.player.z, text, 'info');
          if (reason === 'bagFull') this.onboarding.show('bag_full');
        },
        onError: (msg) => this.hud.toast(msg, 'err'),
        autoEnabled: () => settings.autoGather,
      },
      this.skills,
    );
    this.scope.add(this.skills.onChange(() => this.onSkillsChanged()));
    this.scope.interval(() => {
      if (this.professionsPanel?.isOpen) this.professionsPanel.refreshStatus();
    }, 1000);

    this.mountUi();
    this.bindInput();
    this.scope.add(this.progression.onChange(() => this.refreshStats()));
    this.scope.add(onSettingsChange((s) => this.onDifficultySetting(s.difficulty)));
    this.scope.add(this.inventory.onChange(() => this.refreshStats()));
    this.scope.on(window, 'pagehide', () => {
      void this.progression.flush(true);
      void this.inventory.flush();
      void this.gathering.flush(true);
    });

    getRuntime().setView(this);
    const inventoryReady = this.loadData();
    // Offline dev tokens are not JWTs: only try co-op there when asked (?offline&coop).
    if (!OFFLINE || new URLSearchParams(location.search).has('coop')) void this.connectRealtime();
    if (import.meta.env.DEV) this.installDebug();

    this.area = 'acre';
    this.hud.banner(AREAS.acre.name, AREAS.acre.subtitle);
    audio.setArea('acre');
    this.codex.discover('area', 'acre');
    // First steps: where you are, then how to move (queued, one card at a time).
    // Server-backed progression when the auth server has it; browser storage otherwise.
    this.scope.add(this.progression.onError((msg) => this.hud.toast(msg, 'err')));
    this.scope.add(this.progression.onSynced(() => this.onProgressSynced()));
    this.dataReady = Promise.all([inventoryReady, this.progression.connect()]);
    this.onboarding.show('welcome', 900);
    this.onboarding.show('move', 1600);
    if (this.character.level >= SIGNATURE_LEVEL) this.onboarding.show('signature', 4000);
    if (this.grimoireUnlocked()) this.onboarding.show('grimoire', 4500);
    this.ready = true;
  }

  private buildScene() {
    preloadFxImages();
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
      for (const r of professions) this.skillLevels.set(r.profession_id as SkillId, r.skill_level);
      this.skills.adopt(professions);
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
      toggleAutoCombat: () => this.toggleAutoCombat(),
      chat: (text) => {
        if (this.realtime.connected) this.realtime.sendChat(text);
        else this.hud.chatLine('(solo) Nobody hears you in the dark.');
      },
    }, this.hotbar, this.discipline);
    this.hud.minimap.onNavigate = (x, z) => this.navigateFromMinimap(x, z);
    this.inventoryPanel = new InventoryPanel(this.root, this.character.id, this.inventory, this.statsLine, (id) => this.drinkFlask(id));
    this.forgePanel = new ForgePanel(this.root, this.character.id, this.inventory, (inv, profs) => {
      this.inventory.replace(inv);
      this.skills.adopt(profs);
      this.hud.toast('Crafted', 'good');
    });
    this.professionsPanel = new ProfessionsPanel(this.root, {
      start: type => this.startAfkGathering(type),
      pause: () => this.gathering.stop('moved'),
      status: () => ({ active: this.gathering.afk, text: this.gathering.status, allowed: this.player.area === 'acre' }),
    });
    this.settingsPanel = new SettingsPanel(
      this.root,
      () => this.onLeave(),
      () => this.realtime.instance,
      () => {
        this.onboarding.reset();
        this.hud.toast('Covenant counsel will guide you again', 'good');
      },
      () => {
        this.closePanels();
        this.player.stop();
        this.classPanel.open();
        this.onboarding.show('change_class');
      },
    );
    this.classPanel = new ClassPanel(this.root, () => this.character.class_index, (index) => this.changeClass(index));
    this.scope.add(() => this.classPanel.dispose());
    this.waystonePanel = new WaystonePanel(
      this.root,
      () => AREA_ORDER.filter((a) => this.progression.isUnlocked(a)),
      (a) => this.travel(a),
    );
    this.codex = new CodexJournal(this.character.id);
    this.codexPanel = new CodexPanel(this.root, this.codex, this.discipline.id);
    this.grimoirePanel = new GrimoirePanel(
      this.root,
      () => ({ loadout: this.loadout, level: this.character.level }),
      (slot, id) => this.setRite(slot, id),
    );
    this.ascensionPanel = new AscensionPanel(
      this.root,
      this.progression,
      () => this.doAscend(),
      (id) => {
        if (!this.progression.buyBoon(id)) return;
        audio.play('shard');
        this.applyBoons();
        this.hud.toast(`${BOONS[id].name} — ${BOONS[id].blurb}`, 'good');
      },
    );
    this.onboarding = new Onboarding(this.root, this.character.id);
    this.onboarding.keyFor = (ability) => {
      const i = this.loadout.indexOf(ability as AbilityId);
      return i >= 0 ? String(i + 1) : null;
    };
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
    this.classPanel?.close();
    this.ascensionPanel?.close();
    this.inventoryPanel.close();
    this.forgePanel.close();
    this.professionsPanel.close();
    this.settingsPanel.close();
    this.waystonePanel.close();
    this.codexPanel.close();
    this.grimoirePanel.close();
  }

  private async changeClass(index: number) {
    if (index === this.character.class_index) return;
    this.ready = false;
    this.player.stop();
    this.attackTarget = null;
    this.pendingInteract = null;
    this.cancelRecall();
    try {
      await this.dataReady;
      await Promise.all([this.progression.saveBeforeClassChange(), this.inventory.saveBeforeClassChange()]);
      const character = await changeDiscipline(this.character.id, index);
      this.onClassChanged(character);
    } catch (err) {
      this.ready = true;
      throw err;
    }
  }

  private togglePanel(p: 'inventory' | 'forge' | 'professions' | 'settings' | 'map' | 'codex' | 'ascension' | 'grimoire') {
    audio.play('click');
    const panel = { inventory: this.inventoryPanel, forge: this.forgePanel, professions: this.professionsPanel, settings: this.settingsPanel, map: this.waystonePanel, codex: this.codexPanel, ascension: this.ascensionPanel, grimoire: this.grimoirePanel }[p];
    const wasOpen = panel.isOpen;
    this.closePanels();
    if (wasOpen) return;
    if (!(p === 'professions' && this.gathering?.afk)) this.gathering?.stop('panel');
    if (p === 'professions') this.professionsPanel.open(this.skills);
    else if (p === 'inventory') this.inventoryPanel.open();
    else if (p === 'forge') void this.forgePanel.open();
    else if (p === 'settings') this.settingsPanel.open();
    else if (p === 'codex') this.codexPanel.open();
    else if (p === 'ascension') this.ascensionPanel.open();
    else if (p === 'grimoire') {
      this.grimoirePanel.open();
      this.onboarding.show('grimoire');
    } else this.waystonePanel.open();
  }

  private applyWaveTier() {
    if (this.sim && this.isAuthority()) this.sim.waveTier = this.progression.local.waveTierActive;
  }

  private toggleAutoCombat() {
    updateSettings({ autoCombat: !settings.autoCombat });
    this.autoTargetId = null;
    this.autoAim = null;
    this.hud.toast(settings.autoCombat ? 'Auto combat on — stand near enemies to fight. Click to move; G turns it off.' : 'Auto combat off — click enemies and use your rites manually.', 'good');
  }

  // -------------------------------------------------------------------------
  // Input
  // -------------------------------------------------------------------------

  private bindInput() {
    this.mouse.x = window.innerWidth / 2;
    this.mouse.y = window.innerHeight / 2;
    this.scope.on(window, 'blur', () => { this.keys.clear(); this.mouse.shift = false; this.mouse.aiming = false; if (!this.gathering.afk) this.player.stop(); });
    this.scope.on<KeyboardEvent>(window, 'keydown', (e) => {
      if (!this.ready) return;
      if (document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement) return;
      const k = e.key.toLowerCase();
      if (/^[1-4]$/.test(k)) this.keys.add(k);
      if (k === 'enter') {
        this.hud.focusChat();
        return;
      }
      if (/^[1-6]$/.test(k) || ['r', 'q', 't', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright', ' '].includes(k)) e.preventDefault();
      if (e.repeat && !['w', 'a', 's', 'd', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright'].includes(k)) return;
      if (k >= '1' && k <= '6') this.castSlot(Number(k) as HotbarSlot);
      else if (k === 'r') this.castSlot(6);
      else if (k === 'q') this.drinkFlask();
      else if (k === 't') this.startRecall();
      else if (k === 'i' || k === 'b') this.togglePanel('inventory');
      else if (k === 'c') this.togglePanel('forge');
      else if (k === 'p') this.togglePanel('professions');
      else if (k === 'm') this.togglePanel('map');
      else if (k === 'k') this.togglePanel('codex');
      else if (k === 'l') this.togglePanel('grimoire');
      else if (k === 'g') this.toggleAutoCombat();
      else if (k === 'escape') this.togglePanel('settings');
      else this.keys.add(k);
      this.mouse.shift = e.shiftKey;
    });
    this.scope.on<KeyboardEvent>(window, 'keyup', (e) => {
      this.keys.delete(e.key.toLowerCase());
      this.mouse.shift = e.shiftKey;
    });
    this.scope.on<PointerEvent>(this.canvas, 'pointermove', (e) => {
      this.mouse.aiming = true;
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.mouse.shift = e.shiftKey;
    });
    this.scope.on(this.canvas, 'pointerleave', () => { this.mouse.aiming = false; });
    // Right-click casts at the mouse; left-click movement stays independent.
    this.scope.on<MouseEvent>(this.canvas, 'mousedown', (e) => {
      if (e.button !== 2) return;
      e.preventDefault();
      this.mouse.aiming = true;
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.castSlot(5);
    });
    this.scope.on<PointerEvent>(this.canvas, 'pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      this.mouse.aiming = true;
      this.mouse.x = e.clientX;
      this.mouse.y = e.clientY;
      this.mouse.shift = e.shiftKey;
      this.onPrimaryClick();
    });
    this.scope.on<WheelEvent>(this.canvas, 'wheel', (e) => this.rig.onWheel(e), { passive: true });
    this.scope.on<MouseEvent>(window, 'contextmenu', (e) => {
      if (!(e.target instanceof HTMLInputElement) && !(e.target instanceof HTMLTextAreaElement)) e.preventDefault();
    });
  }

  private updateCursor() {
    const cam = this.rig.camera;
    const rect = this.canvas.getBoundingClientRect();
    this.ndc.set(((this.mouse.x - rect.left) / rect.width) * 2 - 1, -((this.mouse.y - rect.top) / rect.height) * 2 + 1);
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
    if (!best) {
      bestD = 52;
      for (const n of this.layout.nodes) {
        if (Math.abs(n.x - this.player.x) > 26 || Math.abs(n.z - this.player.z) > 22) continue;
        const kind = NODES[n.type].kind;
        test(n.x, kind === 'tree' ? 1.6 : kind === 'pool' ? 0.1 : 0.5, n.z, { kind: 'node', node: n }, kind === 'tree' ? 14 : 6);
      }
    }
    this.hover = best;
    const picked = this.hover as Hover;
    const hn = picked?.kind === 'node' && !this.panelOpen() ? picked.node : null;
    this.nodeViews.hover(hn, hn ? this.skills.level(NODES[hn.type].skill) >= NODES[hn.type].level : true);
    this.hud.nodeTip(hn ? this.nodeTipText(hn) : null, this.mouse.x, this.mouse.y);
    const h = this.hover as Hover;
    this.views.hoverId = h?.kind === 'enemy' ? h.id : null;
    const cur = h?.kind === 'enemy' || h?.kind === 'boss' ? CURSOR.attack : h?.kind === 'interact' || h?.kind === 'node' ? CURSOR.interact : CURSOR.default;
    if (this.canvas.style.cursor !== cur) this.canvas.style.cursor = cur;
  }

  private panelOpen() {
    return this.classPanel.isOpen || this.settingsPanel.isOpen || this.inventoryPanel.isOpen || this.forgePanel.isOpen || this.professionsPanel.isOpen || this.codexPanel.isOpen || this.grimoirePanel.isOpen || this.ascensionPanel.isOpen || this.waystonePanel.isOpen;
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

  private navigateFromMinimap(x: number, z: number): boolean {
    if (!this.ready || !this.player.alive || this.classPanel.isOpen || this.settingsPanel.isOpen || this.inventoryPanel.isOpen || this.forgePanel.isOpen || this.professionsPanel.isOpen || this.codexPanel.isOpen || this.ascensionPanel.isOpen || this.waystonePanel.isOpen) return false;
    const area = this.nav.areaAt(x, z);
    const corridor = DOORS.some(d => this.nav.isDoorOpen(d) && x >= d.rect.x0 && x <= d.rect.x1 && z >= d.rect.z0 && z <= d.rect.z1);
    if (area ? !this.nav.isUnlocked(area) : !corridor) return false;
    const [tx, tz] = this.nav.resolve(x, z, 0.45);
    this.cancelRecall();
    this.attackTarget = null;
    this.pendingInteract = null;
    this.queuedCast = null;
    this.autoTargetId = null;
    this.autoAim = null;
    if (Math.hypot(tx - this.player.x, tz - this.player.z) > 0.25) this.player.face(tx, tz);
    this.player.moveTo(tx, tz);
    this.onboarding.show('minimap');
    return this.player.hasPath;
  }

  private onPrimaryClick() {
    if (!this.ready || !this.player.alive) return;
    this.updateCursor();
    this.cancelRecall();
    this.queuedCast = null;
    const h = this.hover;
    if (h?.kind === 'node' && !this.mouse.shift) {
      this.attackTarget = null;
      this.pendingInteract = null;
      this.gathering.stop('moved');
      const refusal = this.gathering.start(h.node);
      if (refusal) {
        this.floating.spawn(this.player.x, 2.4, this.player.z, refusal, 'info');
        audio.play('error');
      } else {
        audio.play('click');
        this.onboarding.show('gather');
        if (h.node.rich) this.onboarding.show('rich_node');
      }
      return;
    }
    this.gathering.stop('moved');
    const target = this.cursorTarget();
    if (Math.hypot(target.x - this.player.x, target.z - this.player.z) > 0.25) this.player.face(target.x, target.z);
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
    if (!this.ready || !this.player?.alive) return;
    this.gathering?.stop('moved');
    this.updateCursor();
    this.cancelRecall();
    this.autoTargetId = null;
    this.autoAim = null;
    const id = this.hotbar[slot - 1];
    if (!id) return;
    // Corpse Explosion and Grave Step pick from the exact ground point, not a hovered enemy's position.
    const target = id === 'corpse_explosion' || id === 'grave_step' ? { x: this.groundPoint.x, z: this.groundPoint.z } : this.cursorTarget();
    const res = this.abilities.cast(id, target, this.now);
    if (res === 'busy' || (res === 'cooldown' && this.player.cooldownLeft(id, this.now) <= 220)) {
      this.queuedCast = { slot, target, until: this.now + 220 };
      return;
    }
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

  private tickCombat(now: number) {
    const p = this.player;
    if (!p.alive || this.recallAt) return;
    if (this.classPanel.isOpen || this.settingsPanel.isOpen || this.inventoryPanel.isOpen || this.forgePanel.isOpen || this.professionsPanel.isOpen || this.codexPanel.isOpen || this.grimoirePanel.isOpen || this.ascensionPanel.isOpen || this.waystonePanel.isOpen) {
      this.queuedCast = null;
      this.autoTargetId = null;
      this.autoAim = null;
      return;
    }
    if (this.queuedCast) {
      const queued = this.queuedCast;
      if (now > queued.until) this.queuedCast = null;
      else if (this.abilities.ready(this.hotbar[queued.slot - 1], now)) {
        this.queuedCast = null;
        const id = this.hotbar[queued.slot - 1];
        if (this.abilities.cast(id, queued.target, now) === 'ok') this.hud.slotFlash(queued.slot);
        return;
      }
    }
    // Held number keys repeat only when the selected spell is ready.
    for (let slot = 1; slot <= 4; slot++) {
      if (this.keys.has(String(slot))) {
        if (this.abilities.ready(this.hotbar[slot - 1], now)) this.castSlot(slot as HotbarSlot);
        return;
      }
    }
    // Auto combat never sets paths or competes with deliberate movement/menu use (or gathering).
    if (!settings.autoCombat || p.hasPath || p.moving || this.attackTarget || this.keys.size || this.gathering.active) {
      this.autoTargetId = null;
      this.autoAim = null;
      return;
    }
    if (now < this.nextAutoCombatAt) return;
    this.nextAutoCombatAt = now + 180;
    const thralls = [...this.thrallsMap().values()].filter(t => t.owner === this.selfId).length;
    // Auto combat only reaches for what is on the bar (plus the free Bone Needle).
    const action = selectAutoCombatAction({ player: { x: p.x, z: p.z, essence: p.essence, maxEssence: p.stats.maxEssence, hp: p.hp, maxHp: p.stats.maxHp },
      enemies: this.enemiesMap().values(), corpses: this.corpsesMap().values(), boss: this.bossState(),
      thrallCount: thralls, thrallCap: this.discipline.mods.thrallCap,
      ready: id => (id === 'bone_needle' || this.hotbar.includes(id)) && this.abilities.ready(id, now) });
    const previous = this.autoTargetId === null ? undefined : this.enemiesMap().get(this.autoTargetId);
    this.autoTargetId = action?.target.enemyId ?? (previous && previous.hp > 0 && previous.state !== 'dead' && Math.hypot(previous.x - p.x, previous.z - p.z) <= ABILITIES.bone_needle.range ? previous.id : null);
    if (action) this.autoAim = action.target;
    else if (this.autoTargetId === null && !(this.autoAim?.boss && this.bossState().active && this.bossState().hp > 0)) this.autoAim = null;
    if (action && this.abilities.cast(action.id, action.target, now) === 'ok') {
      this.onboarding.show('auto_combat');
      const slot = this.hotbar.indexOf(action.id) + 1;
      if (slot) this.hud.slotFlash(slot);
    }
  }

  private lastFeedback = 0;
  private feedback(res: CastResult, id: AbilityId) {
    if (res === 'ok' || res === 'range' || res === 'no_target') return;
    const now = this.now;
    if (now - this.lastFeedback < 600) return;
    this.lastFeedback = now;
    const text =
      res === 'essence'
        ? (this.onboarding.show('essence'), 'Not enough Grave Essence')
        : res === 'cooldown'
          ? `${ABILITIES[id].name} is not ready`
          : res === 'no_corpse'
            ? 'No corpse in reach'
            : res === 'locked'
              ? `${ABILITIES[id].name} unlocks at level ${unlockLevel(id)}`
              : res === 'no_thralls'
                ? 'You command no thralls'
                : '';
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
    this.gathering.stop('moved');
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
    this.gathering?.stop('left');
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
      case 'kiln':
      case 'sawpit':
      case 'fire':
        this.gathering.stop('panel');
        this.closePanels();
        audio.play('click');
        this.onboarding.show('station');
        return void this.forgePanel.open(it.kind);
      case 'upgrades':
        // Damage / Wave Speed are bought from the HUD anywhere; the Altar itself is where runs are burned.
        return this.togglePanel('ascension');
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
    sim.setNodes(this.layout.nodes);
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
    sim.ascension = this.progression.local.ascension;
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

  // -------------------------------------------------------------------------
  // Gathering (docs/PROFESSIONS-ROADMAP.md §7)
  // -------------------------------------------------------------------------

  /** Is a node live? Host/solo asks the sim, a guest asks the mirror. */
  private nodeLive(id: string) {
    if (this.sim && this.isAuthority()) return (this.sim.nodes.get(id)?.remaining ?? 0) > 0;
    return !this.mirror?.depleted.has(id);
  }

  private *liveNodes(): Iterable<LiveNode> {
    for (const n of this.layout.nodes) yield { ...n, remaining: this.nodeLive(n.id) ? 1 : 0 };
  }

  private nodeTipText(n: NodePlacement) {
    const def = NODES[n.type];
    const lvl = this.skills.level(def.skill);
    const need = lvl < def.level ? `<div class="req missing">Requires ${SKILLS[def.skill].name} level ${def.level}</div>` : `<div class="req ok">${SKILLS[def.skill].name} ${lvl} / ${def.level}</div>`;
    const spent = this.nodeLive(n.id) ? '' : '<div class="spent">Spent. It will return soon.</div>';
    return `<b>${def.name}</b>${n.rich ? ' <span class="rich">rich</span>' : ''}${need}<div>${def.xp} XP per success · ${itemMeta(def.item).name}</div>${spent}`;
  }

  private onGatherCycle(def: (typeof NODES)[string], success: boolean, node: NodePlacement) {
    const p = this.player;
    audio.play(SKILLS[def.skill].sfx, node.x, node.z);
    if (!success) return;
    const color = SKILLS[def.skill].color;
    this.floating.spawn(p.x, 2.3, p.z, `+${def.xp} ${SKILLS[def.skill].name} XP`, 'skill', color);
    this.floating.spawn(node.x, 0.7, node.z, `+1 ${itemMeta(def.item).name}`, 'info');
    const c = parseInt(color.slice(1), 16);
    this.effects.emit({ x: node.x, y: def.kind === 'tree' ? 1.6 : 0.5, z: node.z, count: 6, color: c, spread: 0.35, speed: 1.4, up: 1, life: 0.5, size: 0.14 });
  }

  private async startAfkGathering(type: string) {
    if (this.player.area !== 'acre') throw new Error('Visit the Sexton’s Acre for safe AFK gathering.');
    const nodes = this.layout.nodes.filter(n => n.area === 'acre' && n.type === type);
    const node = nodes.sort((a, b) => Math.hypot(a.x - this.player.x, a.z - this.player.z) - Math.hypot(b.x - this.player.x, b.z - this.player.z))[0];
    if (!node) throw new Error('Choose a gathering node.');
    this.gathering.stop('moved');
    await this.gathering.flush();
    await this.dataReady;
    await beginAfkGather(this.character.id, type);
    if (this.scope.isDisposed) return;
    this.attackTarget = null;
    this.pendingInteract = null;
    this.cancelRecall();
    this.keys.clear();
    const refusal = this.gathering.startAfk(node);
    if (refusal) throw new Error(refusal);
    this.hud.toast('AFK gathering started — keep the game open. It pauses when your bag fills.', 'good');
  }

  async backgroundUpdate(seconds: number) {
    // The same authoritative sim and gathering loop, with no hidden-tab render.
    // Timers can wake once a minute; preserve earned time in capped batches.
    for (let left = seconds; left > 0 && this.ready && !this.scope.isDisposed && this.gathering.afk && this.player.area === 'acre'; left -= .1) {
      const dt = Math.min(.1, left);
      this.update(dt, this.now + dt * 1000);
    }
    await this.gathering.flush();
  }

  private onGatherReply(r: GatherReply) {
    for (const g of r.items) this.inventory.add({ item_id: g.itemId, quantity: g.qty });
    if (r.gold > 0) {
      this.progression.addGold(r.gold);
      this.floating.spawn(this.player.x, 2.1, this.player.z, `+${r.gold}g`, 'gold');
    }
    if (r.rejected.length) {
      this.hud.toast(`Your bag is full: ${r.rejected.map((g) => `${g.qty}× ${itemMeta(g.itemId).name}`).join(', ')} left behind.`, 'err');
      if (this.gathering.afk) this.gathering.stop('bagFull');
    }
    const rare = r.items.filter((g) => g.itemId !== NODES[r.node]?.item);
    for (const g of rare) this.hud.toast(`Found: ${itemMeta(g.itemId).name}${g.qty > 1 ? ` ×${g.qty}` : ''}`, 'good');
    if (r.items.length) this.inventoryPanel?.render();
  }

  private onSkillsChanged() {
    for (const s of Object.keys(SKILLS) as SkillId[]) {
      const lvl = this.skills.level(s);
      const before = this.skillLevels.get(s) ?? 1;
      this.skillLevels.set(s, lvl);
      if (lvl <= before) continue;
      const opens = s === 'gardening' ? [] : nodesForSkill(s).filter((n) => n.level > before && n.level <= lvl);
      this.hud.banner(`${SKILLS[s].name} ${lvl}`, opens.length ? `You can now work: ${opens.map((n) => n.name).join(', ')}` : SKILLS[s].rite, 3200);
      audio.play('skillUp');
      this.onboarding.show('skill_up');
    }
    this.professions = this.skills.rows();
    if (this.professionsPanel?.isOpen) this.professionsPanel.render(this.skills);
  }

  private onNodeSpent(id: string) {
    const n = this.layout.nodes.find((x) => x.id === id);
    if (n && this.gathering.node?.id === id) this.effects.emit({ x: n.x, y: 0.4, z: n.z, count: 14, color: 0x8a7a60, spread: 0.6, speed: 1.6, up: 1.2, life: 0.7, size: 0.2 });
  }

  /** Gesture per work cycle, the progress arc, and a periodic resync of node looks. */
  private tickGatherVisuals(dt: number) {
    const g = this.gathering;
    const prog = g.progress;
    if (g.working && g.node && (prog < this.gatherProg || this.gatherProg === 0) && prog < 0.5) {
      const def = NODES[g.node.type];
      const cycleS = (def.ticks * 600) / 1000;
      this.avatar.cast(SKILLS[def.skill].gesture, 1, Math.atan2(g.node.x - this.player.x, g.node.z - this.player.z), cycleS * 0.9);
    }
    this.gatherProg = g.working ? prog : 0;
    this.nodeViews.progress(this.player.x, this.player.z, g.working ? Math.max(0.02, prog) : 0, g.node ? SKILLS[NODES[g.node.type].skill].color : '#ffffff');
    this.nodeViews.update(dt);
    if (this.now - this.lastNodeSync > 1000) {
      this.lastNodeSync = this.now;
      for (const n of this.layout.nodes) this.nodeViews.setLive(n.id, this.nodeLive(n.id));
    }
  }

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
      case 'nodeGone':
        this.nodeViews.setLive(ev.id, false);
        this.onNodeSpent(ev.id);
        break;
      case 'nodeBack':
        this.nodeViews.setLive(ev.id, true);
        break;
      case 'telegraph':
        this.telegraph(ev);
        break;
      case 'melee':
        this.effects.emitSmoke({ x: ev.tx, y: 0.3, z: ev.tz, count: 2, color: 0x3a3340, spread: 0.3, speed: 0.8, up: 0.3, life: 0.5, size: 0.6 });
        break;
      case 'thrallHit': {
        audio.play('boneHit', ev.tx, ev.tz);
        const color = ev.kind === 'wraith' ? 0x8f9ed1 : ev.kind === 'bonemage' ? STATUS_FX.hex.amber : 0xd8cfbd;
        if (ev.kind === 'wraith' || ev.kind === 'bonemage') {
          this.effects.projectile({ from: { x: ev.x, y: 1.3, z: ev.z }, to: () => ({ x: ev.tx, y: 1, z: ev.tz }), kind: 'orb', color, speed: ev.kind === 'bonemage' ? 14 : 20 });
        } else if (ev.kind === 'archer') {
          this.effects.projectile({ from: { x: ev.x, y: 1.3, z: ev.z }, to: () => ({ x: ev.tx, y: 1, z: ev.tz }), kind: 'needle', color, speed: 26, arc: 0.6 });
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
      case 'wall':
        this.raiseWall(ev);
        break;
      case 'wallGone': {
        const w = this.wallFx.get(ev.id);
        if (w) {
          const c = w.userData.center as { x: number; z: number };
          this.effects.emitSmoke({ x: c.x, y: 0.6, z: c.z, count: 16, color: SPELL_FX.wall.dust, spread: 2.4, speed: 0.8, up: 0.8, life: 1.4, size: 1.6 });
          w.removeFromParent();
          w.traverse((o) => (o as THREE.Mesh).geometry?.dispose?.());
          this.wallFx.delete(ev.id);
        }
        break;
      }
      case 'rend': {
        const R = SPELL_FX.rend;
        for (const [fx0, fz0, tx, tz] of ev.leaps) {
          this.effects.beam({ x: fx0, y: 0.8, z: fz0 }, () => ({ x: tx, y: 0.8, z: tz }), R.jade, 0.06, 0.35);
          this.effects.emit({ x: tx, y: 0.6, z: tz, count: 10, color: R.bone, spread: 0.5, speed: 3, up: 1.5, life: 0.5, size: 0.14, gravity: 8 });
        }
        this.effects.decal({ tex: fx.ring(), color: R.jade, x: ev.x, z: ev.z, r: 3, duration: 0.5, opacity: 1, growFrom: 0.3 });
        this.effects.lightFlash(ev.x, 1.5, ev.z, R.jade, 40, 0.4);
        audio.play('boneHit', ev.x, ev.z);
        if (ev.by === me) this.rig.shake(0.2);
        break;
      }
      case 'mantle': {
        // Shards follow their caster: our body, or the remote's latest reported position.
        const at = { x: ev.x, z: ev.z };
        const follow = ev.by === me
          ? () => (this.player.alive ? this.player : null)
          : () => {
              const r = this.remotes.get(ev.by);
              if (!r) return null;
              at.x = r.tx;
              at.z = r.tz;
              return at;
            };
        this.abilities.onMantle(ev, ev.by === me, follow);
        if (ev.by === me) this.rig.shake(0.12);
        break;
      }
      case 'heal':
        if (ev.player === me && this.player.alive) {
          this.player.heal(ev.amount);
          this.floating.spawn(this.player.x, 2.2, this.player.z, `+${Math.round(ev.amount)}`, 'info');
        }
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
        if (Math.hypot(ev.tx - this.player.x, ev.tz - this.player.z) < 18) this.onboarding.show('sanctify');
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
          // A procession: one banner for the whole band (each breach reports the wave).
          const theme = ev.theme ? WAVE_THEMES[ev.area]?.find((t) => t.id === ev.theme) : undefined;
          if (theme && this.now - this.lastProcession > 4000) {
            this.lastProcession = this.now;
            this.hud.banner(theme.name, theme.blurb, 2600);
            audio.play('tollSmall', ev.x, ev.z);
            this.onboarding.show('procession', 1500);
          }
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
          const firstSight = FIRST_SIGHT_TIPS[ev.def];
          if (firstSight) this.onboarding.show(firstSight, 600);
          if (ev.elite) this.onboarding.show('elite');
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
    // Kit counsel, as each moment first comes up.
    const mine = [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId).length;
    if (mine >= 1) this.onboarding.show('thrall');
    let corpsesNear = 0;
    let packOnCorpse = false;
    for (const c of this.corpsesMap().values()) {
      if (Math.hypot(c.x - this.player.x, c.z - this.player.z) > 7) continue;
      corpsesNear++;
      if (!packOnCorpse) {
        let n = 0;
        for (const e of this.enemiesMap().values()) if (e.state !== 'dead' && Math.hypot(e.x - c.x, e.z - c.z) < 3) n++;
        packOnCorpse = n >= 3;
      }
    }
    if (mine + corpsesNear >= 4 && this.character.level >= 2) this.onboarding.show('litany');
    if (packOnCorpse && this.progression.local.totalKills >= 15) this.onboarding.show('burst');
    if (this.progression.local.totalKills >= 40) this.onboarding.show('codex');
    if (this.progression.local.shards >= BOSS_SUMMON_SHARDS) this.onboarding.show('prelate');
    if (this.progression.local.ascension > 0 && this.progression.local.ashes > 0 && this.area === 'chapterhouse') this.onboarding.show('boons');
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
      const r = ev.r ?? 1.9;
      this.effects.decal({ tex: fx.disc(), color: SPELL_FX.enemy.slam, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.7, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.4 });
      if (r > 2.2) {
        // A Bone Golem's slam: the wide ring cracks as it lands.
        this.effects.decal({ tex: fx.ring(), color: SPELL_FX.enemy.slam, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.9, fadeOut: 0.05 });
        this.effects.decal({ tex: fx.cracks(), color: SPELL_FX.enemy.slam, x: ev.tx, z: ev.tz, r: r * 0.9, rot: Math.random() * 6, duration: 1.2, opacity: 0.85, growFrom: 0.5, delay: ms });
        this.effects.emitSmoke({ x: ev.tx, y: 0.3, z: ev.tz, count: 6, color: 0x3b3440, spread: r * 0.5, speed: 1.4, up: 0.5, life: 0.9, size: 1.2 });
      }
    } else if (ev.kind === 'scream') {
      // Choir Wraith: pale song-lines run from the singer to a ring that breaks when the hymn does.
      const r = ev.r ?? 2.2;
      const song = 0xb9cbe6;
      this.effects.beam({ x: ev.x, y: 2, z: ev.z }, () => ({ x: ev.tx, y: 0.3, z: ev.tz }), song, 0.03, ms);
      this.effects.decal({ tex: fx.disc(), color: song, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.45, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.2 });
      this.effects.decal({ tex: fx.sigil(), color: song, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.6, spin: -1.5, fadeOut: 0.05 });
      this.effects.decal({ tex: fx.ring(), color: 0xeef4ff, x: ev.tx, z: ev.tz, r: r * 1.15, duration: 0.35, opacity: 1, growFrom: 0.5, delay: ms });
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
    if (z.kind === 'dirge' || z.kind === 'flower') {
      // Signature zones: Dirge = cold-blue bell rings, Plague Bloom = a chartreuse flower sigil.
      const D = SPELL_FX.dirge;
      const B = SPELL_FX.bloom;
      const dirge = z.kind === 'dirge';
      this.zoneFx.set(z.id, [
        this.effects.decal({ tex: fx.disc(), color: dirge ? D.deep : B.rot, x: z.x, z: z.z, r: z.r, duration: dur, opacity: 0.45, growFrom: 0.3, fadeOut: 0.6 }),
        this.effects.decal({ tex: dirge ? fx.ring() : fx.sigil(), color: dirge ? D.frost : B.petal, x: z.x, z: z.z, r: z.r * 0.95, duration: dur, opacity: 0.6, pulse: dirge ? 6 : 2, spin: dirge ? 0 : 0.9, fadeOut: 0.6 }),
      ]);
      this.effects.emit({ x: z.x, y: 0.4, z: z.z, count: dirge ? 30 : 18, color: dirge ? D.pale : B.petal, spread: z.r * 0.5, speed: 0.6, up: dirge ? 2 : 1.2, life: 1, size: 0.22 });
      if (dirge) audio.play('tollSmall', z.x, z.z);
      return;
    }
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
      this.onboarding.show('surge', 1200);
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
    const level = AREAS[ev.area].level + ascensionLevels(this.worldAscension());
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
    const asc = ascensionRewardMult(this.worldAscension());
    reward.gold = Math.round(reward.gold * asc);
    reward.xp = Math.round(reward.xp * asc);
    this.loot.gold(ev.x, ev.z, reward.gold);
    if (reward.shards) this.loot.shard(ev.x, ev.z, reward.shards);
    for (const item of reward.items) this.loot.item(ev.x, ev.z, item);
    this.gainXp(reward.xp, ev.x, ev.z);
    this.progression.recordKill(ev.area, this.bossWaveTier());
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

  /** Server state replaced the local copy: seals, tiers, boons or rank may have moved. */
  private onProgressSynced() {
    if (!this.worldView) return;
    this.nav.setUnlocked(this.progression.local.unlocked);
    for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d));
    if (this.sim && this.isAuthority()) {
      this.sim.ascension = this.progression.local.ascension;
      this.sim.waveTier = this.progression.local.waveTierActive;
    }
    this.applyBoons();
  }

  /** Burn the run at the Altar: reset the local layer, raise the rank, age the world. */
  private doAscend() {
    const earned = this.progression.ascend();
    if (!earned) return;
    const rank = this.progression.local.ascension;
    this.nav.setUnlocked(this.progression.local.unlocked);
    for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d));
    if (this.sim && this.isAuthority()) {
      this.sim.ascension = rank;
      this.sim.waveTier = 0;
      // The younger dead crumble; older ones climb out on the next visit.
      for (const a of AREA_ORDER) if (!AREAS[a].safe) this.sim.clearArea(a);
    }
    this.applyBoons();
    const altar = AREAS.chapterhouse.interactables.find((i) => i.kind === 'upgrades')!;
    this.effects.emit({ x: altar.x, y: 0.4, z: altar.z, count: 120, color: 0xd9a441, spread: 1.2, speed: 1.4, up: 5, life: 1.8, size: 0.34 });
    this.effects.decal({ tex: fx.sigil(), color: 0xd9a441, x: altar.x, z: altar.z, r: 4, duration: 2.4, opacity: 1, growFrom: 0.2, spin: 1.4 });
    this.effects.lightFlash(altar.x, 3, altar.z, 0xd9a441, 90, 1.6);
    this.rig.shake(0.4);
    audio.play('levelUp');
    this.hud.banner(`Ascension ${roman(rank)}`, `The dead rise ${ascensionLevels(rank)} levels older · +${earned} Ashes`, 4200);
    void this.progression.flush();
  }

  /** The Ascension rank the world runs at: yours solo/as host, the host's as a guest. */
  private worldAscension(): number {
    return this.sim?.ascension ?? this.mirror?.ascension ?? this.progression.local.ascension;
  }

  /**
   * Covenant Boons reshape this character: a private copy of the discipline's
   * mods (thrall cap, health, essence) plus the Soul Harvest threshold.
   */
  private applyBoons() {
    const base = disciplineFor(this.character.class_index);
    const fx = this.progression.boons;
    this.discipline = {
      ...base,
      mods: {
        ...base.mods,
        thrallCap: base.mods.thrallCap + fx.extraThralls,
        maxHpMult: base.mods.maxHpMult * fx.maxHpMult,
        essenceRegenMult: base.mods.essenceRegenMult * fx.essenceRegenMult,
      },
    };
    if (this.player) {
      this.player.soulsMax = Math.max(10, SOUL_HARVEST.souls - fx.soulsDiscount);
      this.refreshStats();
    }
  }

  /** The difficulty the world is running at: yours solo/as host, the host's as a guest. */
  private worldDifficulty(): Difficulty {
    return this.sim?.difficulty ?? this.mirror?.difficulty ?? settings.difficulty;
  }

  private onSoulsCharged() {
    this.onboarding.show('souls');
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
      if (this.character.level >= SIGNATURE_LEVEL) this.onboarding.show('signature', 3000);
      const learned = GRIMOIRE.filter((id) => unlockLevel(id) > this.character.level - gained && unlockLevel(id) <= this.character.level);
      if (learned.length) {
        const names = learned.map((id) => ABILITIES[id].name).join(', ');
        this.hud.toast(`${names} ${learned.length > 1 ? 'join' : 'joins'} your Grimoire — press L to place it on a key`, 'good');
        this.grimoirePanel.render();
      }
      if (this.grimoireUnlocked()) this.onboarding.show('grimoire', 3200);
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
      if (this.progression.kills(u.area) >= this.progression.unlockKills(u.kills) && this.progression.unlock(id)) {
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
    if (taken >= 1) this.gathering.stop('hurt');
    if (this.player.hp < this.player.stats.maxHp * 0.5) this.onboarding.show('hurt');
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
    this.gathering.stop('dead');
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
    this.player.teleport(CHAPTERHOUSE_RETURN.x, CHAPTERHOUSE_RETURN.z);
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
          this.progression.recordPrelateKill();
          if (this.progression.canAscend()) this.onboarding.show('ascend', 5000);
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

    // The mouse only aims here. Movement destinations are set by deliberate clicks.

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
      this.gathering.stop('moved');
    }
    const moved = p.update(dt, now, kd.x || kd.z ? kd : null);
    this.gathering.update(dt);
    this.tickGatherVisuals(dt);
    if (moved) this.cancelRecall();
    this.tickCombat(now);
    this.abilities.update(now);
    // Walking follows its path. Once standing, the mouse turns the hero to aim
    // without changing position or replacing the clicked destination.
    if (p.alive && this.mouse.aiming && !p.moving && !p.hasPath && !this.attackTarget && this.autoAim === null && now >= p.castUntil && !this.gathering.active) {
      const target = this.cursorTarget();
      if (Math.hypot(target.x - p.x, target.z - p.z) > 0.25) p.face(target.x, target.z);
    }

    if (this.recallAt && now >= this.recallAt) {
      this.cancelRecall();
      this.teleportTo(CHAPTERHOUSE_RETURN.x, CHAPTERHOUSE_RETURN.z);
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
    if (got.items.length) {
      audio.play('item');
      this.onboarding.show('relic');
    }
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

  /** Ossuary Wall: a fence of fused rib-bones along the wall segment. */
  private raiseWall(ev: Extract<SimEvent, { t: 'wall' }>) {
    const W = SPELL_FX.wall;
    const len = Math.hypot(ev.x1 - ev.x0, ev.z1 - ev.z0);
    const n = Math.max(6, Math.round(len * 2.2));
    const rib = new THREE.ConeGeometry(0.22, 1, 5);
    const mesh = new THREE.InstancedMesh(rib, new THREE.MeshStandardMaterial({ color: W.bone, roughness: 0.8, emissive: W.amber, emissiveIntensity: 0.08 }), n);
    const m = new THREE.Matrix4();
    const q = new THREE.Quaternion();
    const sc = new THREE.Vector3();
    const pos = new THREE.Vector3();
    for (let i = 0; i < n; i++) {
      const t = (i + 0.5) / n;
      const h = 1.4 + ((i * 7919) % 5) * 0.18;
      pos.set(ev.x0 + (ev.x1 - ev.x0) * t, h / 2, ev.z0 + (ev.z1 - ev.z0) * t);
      q.setFromEuler(new THREE.Euler(((i % 3) - 1) * 0.18, i * 1.3, ((i % 2) * 2 - 1) * 0.12));
      sc.set(1, h, 1);
      mesh.setMatrixAt(i, m.compose(pos, q, sc));
    }
    mesh.castShadow = true;
    mesh.userData.center = { x: (ev.x0 + ev.x1) / 2, z: (ev.z0 + ev.z1) / 2 };
    this.scene.add(mesh);
    this.wallFx.set(ev.id, mesh);
    for (let i = 0; i <= 6; i++) {
      const t = i / 6;
      this.effects.emit({ x: ev.x0 + (ev.x1 - ev.x0) * t, y: 0.3, z: ev.z0 + (ev.z1 - ev.z0) * t, count: 6, color: W.bone, spread: 0.3, speed: 1.5, up: 2.5, life: 0.6, size: 0.14, gravity: 9 });
    }
    audio.play('boneHit', mesh.userData.center.x, mesh.userData.center.z);
    this.rig.shake(0.15);
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
    if (area === 'acre') this.onboarding.show('acre', 1200);
    void this.progression.flush();
  }

  private areaProgress(): string {
    const here = this.area;
    if (here === 'acre') return `No dead here. Total skill level <b>${this.skills.total()}</b> (<kbd>P</kbd>)`;
    if (AREAS[here].safe) return 'Sanctuary. The dead cannot follow you here.';
    const next = AREA_ORDER.find((id) => AREAS[id].unlock?.area === here && !this.progression.isUnlocked(id));
    if (next) {
      const need = this.progression.unlockKills(AREAS[next].unlock!.kills);
      return `Slay <b>${Math.min(need, this.progression.kills(here))}/${need}</b> to unseal ${AREAS[next].name}`;
    }
    if (here === 'sanctum') {
      return this.bossState().active
        ? 'The Prelate walks.'
        : `Offer <b>${this.progression.local.shards}/${BOSS_SUMMON_SHARDS}</b> soul shards at the Sundered Bell`;
    }
    return `<b>${this.progression.kills(here)}</b> slain here · Level ${AREAS[here].level + ascensionLevels(this.worldAscension())} dead`;
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
      if ((focusEnemy.chillT ?? 0) > 0) statuses.push({ icon: 'art/status/chilled.png', label: 'Chilled', n: 1 });
      if ((focusEnemy.silenceT ?? 0) > 0) statuses.push({ icon: 'art/status/silenced.png', label: 'Silenced', n: 1 });
      if ((focusEnemy.incenseT ?? 0) > 0) statuses.push({ icon: 'art/status/incensed.png', label: 'Incensed', n: 1 });
      if ((focusEnemy.hexT ?? 0) > 0) statuses.push({ icon: 'art/status/cursed.png', label: 'Bone Hex', n: 1 });
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
      autoCombat: settings.autoCombat,
      hp: p.hp,
      maxHp: p.stats.maxHp,
      barrier: p.barrier,
      essence: p.essence,
      maxEssence: p.stats.maxEssence,
      level: this.character.level,
      xp: this.character.experience,
      xpNext: xpToNext(this.character.level),
      slots: this.hotbar.map((id) => {
        const empowered = this.abilities.empowered(id);
        return {
          left: p.cooldownLeft(id, now),
          total: ABILITIES[id].cooldownMs,
          affordable: empowered || p.essence >= ABILITIES[id].essenceCost,
          empowered,
          locked: this.character.level < unlockLevel(id),
        };
      }),
      souls: p.souls,
      soulsMax: p.soulsMax,
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
        destination: p.destination,
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
          discipline: this.progression.local.ascension ? `${this.discipline.epithet} · Ascension ${roman(this.progression.local.ascension)}` : this.discipline.epithet,
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
      avatar: this.avatar,
      sim: () => this.sim,
      progression: this.progression,
      inventory: this.inventory,
      advance: (seconds: number, render = true) => getRuntime().advance(seconds, 1 / 60, render),
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
      /** Ascension QA: count a Prelate kill for this run, then open the Altar. */
      prelateSlain: () => {
        this.progression.recordPrelateKill();
        return this.progression.ashesOnAscend();
      },
      altar: () => this.togglePanel('ascension'),
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
      souls: (n = this.player.soulsMax) => {
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
      /** Grimoire QA: put rites on keys 1–4, e.g. loadout(['wailing_skull','grave_step','grave_frost','bone_mantle']). */
      loadout: (ids?: AbilityId[]) => {
        ids?.forEach((id, i) => this.setRite(i, id));
        return [...this.loadout];
      },
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
      /** Gathering QA: every node with its live state (optionally one area). */
      nodes: (area?: AreaId) =>
        this.layout.nodes.filter((n) => !area || n.area === area).map((n) => ({ id: n.id, type: n.type, area: n.area, rich: !!n.rich, live: this.nodeLive(n.id), x: n.x, z: n.z })),
      /** Walk to the nearest node of a type in the current area (or anywhere) and start working it. */
      gatherAt: (type: string) => {
        const list = this.layout.nodes.filter((n) => n.type === type);
        const here = list.filter((n) => n.area === this.player.area);
        const pool = here.length ? here : list;
        const n = pool.sort((a, b) => Math.hypot(a.x - this.player.x, a.z - this.player.z) - Math.hypot(b.x - this.player.x, b.z - this.player.z))[0];
        if (!n) return 'no such node';
        return this.gathering.start(n) ?? n.id;
      },
      /** State of the gathering loop. */
      gathering: () => ({ node: this.gathering.node?.id ?? null, afk: this.gathering.afk, status: this.gathering.status, working: this.gathering.working, progress: this.gathering.progress, skills: this.skills.rows() }),
      /** Set a skill level locally (and in the offline mock's db, so its server agrees). */
      skill: (id: SkillId, level: number) => {
        this.skills.adopt([{ profession_id: id, skill_level: level, skill_xp: 0 }]);
        if (OFFLINE) {
          try {
            const db = JSON.parse(localStorage.getItem('cw_offline_db_v1') ?? '{}');
            for (const acc of Object.values(db.accounts ?? {}) as { character?: { id: number }; professions: { profession_id: string; skill_level: number; skill_xp: number }[] }[]) {
              if (acc.character?.id !== this.character.id) continue;
              const row = acc.professions.find((p) => p.profession_id === id);
              if (row) Object.assign(row, { skill_level: level, skill_xp: 0 });
              else acc.professions.push({ profession_id: id, skill_level: level, skill_xp: 0 });
            }
            localStorage.setItem('cw_offline_db_v1', JSON.stringify(db));
          } catch {
            /* storage unavailable */
          }
        }
        return this.skills.rows();
      },
      flushGather: () => this.gathering.flush(),
      /** Open an Acre station as if clicked (kiln / sawpit / fire). */
      station: (kind: 'kiln' | 'sawpit' | 'fire') => {
        const it = AREAS.acre.interactables.find((i) => i.kind === kind);
        if (it) this.interact(it);
      },
      /** Put the mouse over a node (hover card + ring QA). */
      hoverNode: (id: string) => {
        const n = this.layout.nodes.find((x) => x.id === id);
        if (!n) return null;
        const v = new THREE.Vector3(n.x, NODES[n.type].kind === 'tree' ? 1.6 : 0.5, n.z).project(this.rig.camera);
        this.mouse.x = ((v.x + 1) / 2) * window.innerWidth;
        this.mouse.y = ((1 - v.y) / 2) * window.innerHeight;
        this.mouse.aiming = true;
        this.updateCursor();
        return [Math.round(this.mouse.x), Math.round(this.mouse.y)];
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
    this.nodeViews.dispose();
    this.prelate.dispose();
    this.loot.dispose();
    this.avatar.dispose();
    this.effects.dispose();
    this.worldView.dispose();
    this.scene.environment?.dispose();
    this.scene.clear();
  }
}
