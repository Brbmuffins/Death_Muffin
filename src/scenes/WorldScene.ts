import * as THREE from 'three';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import type { GameScene } from './SceneManager';
import { getRuntime, type RuntimeView } from '../app/GameRuntime';
import { Scope } from '../app/Scope';
import { ABILITIES, PRIMARIES, BULWARK, SIGNATURE_LEVEL, SOUL_HARVEST, SPELL_FX, unlockLevel, type AbilityId, type HotbarSlot } from '../content/abilities';
import { CAST_FLOW } from '../content/combatFlow';
import { kitFor, type Kit } from '../content/kits';
import { assignableRites, assignRite, LOADOUT_SLOTS, loadRites, loadSeen, saveRites, saveSeen, unseenRites } from '../gameplay/loadout';
import { devAccess, devPreference, isDevAccount, riteLevel, setDevPreference, tokenUsername } from '../gameplay/devAccess';
import { GrimoirePanel } from '../ui/GrimoirePanel';
import { preloadFxImages } from '../graphics/fxImages';
import { ARMOR_BY_ID } from '../content/armorSets';
import { AREAS, AREA_ORDER, BOSS_SUMMON_SHARDS, CHAPTERHOUSE_RETURN, DOORS, PLAYER_SPAWN, type AreaId, type DoorDef, type Interactable } from '../content/areas';
import { disciplineFor, type Discipline } from '../content/disciplines';
import { AFFIX_TUNING, ELITE_AFFIXES, ENEMIES, WAVE_THEMES, type EliteAffix, type EnemyId } from '../content/enemies';
import { HEALING_FLASKS, itemMeta } from '../content/items';
import { REAGENT_ITEMS } from '../content/reagents';
import { BREWS, BREW_KEYS, BREW_SLOTS, applyBrew, brewEffectsText, brewWard, lifestealHeal, slotName, type BrewSlot } from '../content/brews';
import { MEALS } from '../content/processing';
import { generateLayout, PROPS, type NodePlacement } from '../content/layout';
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
import { changeDiscipline, getCosmetics, getGarden, getLabor, type ContractDelivery, type CosmeticsView, type GardenResult, type LaborResult } from '../net/api';
import { canUseAutoCombat, onSettingsChange, setActiveCharacter, settings, updateSettings } from '../app/settings';
import { selectAutoCombatAction, selectAutoCombatMovement, type AutoMoveMemory } from '../gameplay/autoCombat';
import { STATUS_FX } from '../content/statuses';
import { AbilitySystem, veilTarget, type CastResult, type CastTarget } from '../gameplay/AbilitySystem';
import { deriveStats, xpToNext } from '../gameplay/characterStats';
import { BAG_SIZE, Inventory, rollBoss, rollFirstKillItem, rollItem, rollKill } from '../gameplay/loot';
import { Nav } from '../gameplay/nav';
import { Player } from '../gameplay/Player';
import { resourceRulesFor, type ResourceRules } from '../gameplay/resources';
import { Progression } from '../gameplay/progression';
import { CHAIN, KillChain } from '../gameplay/killChain';
import { newlyReached } from '../gameplay/milestones';
import { omenFor, omenLeft, type Omen } from '../content/omens';
import { BOSS_ARENA } from '../gameplay/sim/BossBrain';
import { makeSnapshot, WorldMirror } from '../gameplay/sim/snapshot';
import type { BossState, Corpse, Enemy, Intent, SimEvent, Thrall, Zone } from '../gameplay/sim/types';
import { WorldSim } from '../gameplay/sim/WorldSim';
import { computeStats, STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { BossView, NecromancerAvatar } from '../graphics/Avatars';
import { prewarmCreature } from '../graphics/prewarmCreature';
import { BOSSES, CONGREGATION, GRAVEDIGGER, MIRE, REGENT, SAINT, bossForSummon, type BossId } from '../content/bosses';
import { FEN_FLOOD_SCALE, HAG_HEX, SEXTON_HOOK, bogMult } from '../content/fen';
import { fxImage } from '../graphics/fxImages';
import { CameraRig } from '../graphics/CameraRig';
import { Effects, type Handle } from '../graphics/Effects';
import { preloadBinbun, type BinbunSpawn } from '../graphics/binbun/BinbunFX';
import { isBinbunImpact, type BinbunId } from '../graphics/binbun/catalog';
import type { Gallery } from '../graphics/binbun/gallery';
import { playFx } from '../graphics/binbun/presets';
import type { BinbunHandle } from '../graphics/binbun/BinbunFX';
import { EntityViews } from '../graphics/EntityViews';
import { fx } from '../graphics/fxTextures';
import { LootView } from '../graphics/LootView';
import { WorldView } from '../graphics/WorldView';
import { updateOcclusion } from '../graphics/occlusion';
import { equippedBySlot, gearFromIds } from '../content/gear';
import { abilityCooldownMs, abilityRange, resolveWeaponLoadout } from '../gameplay/weaponLine';
import { Chronicle } from '../gameplay/chronicle';
import { GatherSession, crossedMilestones, loadBests, saveBests } from '../gameplay/gatherReport';
import { GatherReportPanel } from '../ui/GatherReportPanel';
import { ContractsPanel } from '../ui/ContractsPanel';
import { VaultPanel } from '../ui/VaultPanel';
import { SalvagePanel, runSalvage } from '../ui/SalvagePanel';
import { ItemLocks } from '../gameplay/itemLocks';
import { GardenPanel } from '../ui/GardenPanel';
import { LaborPanel } from '../ui/LaborPanel';
import { CosmeticsPanel } from '../ui/CosmeticsPanel';
import { PetView } from '../graphics/PetView';
import { petDef, petForCharm } from '../content/cosmetics';
import { isCape, isPet } from '../gameplay/cosmeticRules';
import { beginAfkGather, gather, getInventory, getProfessions, getToken, OFFLINE, type GatherReply, type SalvageReply } from '../net/api';
import type { RemotePlayer, WorldSnapshot } from '../net/contracts';
import { RealtimeClient } from '../net/realtime';
import type { Character, Profession } from '../net/types';
import { FloatingText } from '../ui/FloatingText';
import { ForgePanel } from '../ui/ForgePanel';
import { HUD, type HudFrame } from '../ui/HUD';
import { InventoryPanel } from '../ui/InventoryPanel';
import { CharacterSheetPanel } from '../ui/CharacterSheet';
import type { StatContext } from '../gameplay/gearStats';
import { SettingsPanel, WaystonePanel } from '../ui/MiscPanels';
import { ProfessionsPanel } from '../ui/ProfessionsPanel';
import { CodexPanel } from '../ui/CodexPanel';
import { Onboarding, type TipId } from '../ui/Onboarding';
import { CodexJournal, browserStorage, type CodexIds, type CodexKind } from '../gameplay/codexJournal';
import { CURSOR } from '../ui/cursors';
import { audio } from '../audio/Audio';

const SNAPSHOT_MS = 100;
const MOVE_SEND_MS = 100;
const RESPAWN_MS = 4000;
const RECALL_MS = 1500;
const GROUND_FX_PRELOAD = [
  'toxic_puddle', 'grave_hands_pulse', 'dirge_area', 'plague_bloom_area',
  'enemy_breach_rim', 'crypt_mist', 'bell_toll_ring', 'miasma_cloud',
  'grave_frost_mist', 'surge_eruption',
] as const;
const INTERACT_RANGE = 2.6;
/** Only enemies with a distinct counter need a first-sight card; the Codex covers the rest. */
const FIRST_SIGHT_TIPS: Partial<Record<EnemyId, TipId>> = {
  censer: 'censer',
  wraith: 'wraith',
  rat: 'swarm',
  golem: 'golem',
  gargoyle: 'gargoyle',
  moth: 'moth',
  bat: 'bats',
  seraph: 'seraph',
  ghoul: 'ghoul',
  acolyte: 'acolyte',
  templar: 'templar',
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
/** Counsel shown the first time each level-gated Grimoire rite is placed on a key. */
const RITE_TIPS: Partial<Record<AbilityId, TipId>> = {
  wailing_skull: 'rite_skull',
  grave_step: 'rite_step',
  grave_frost: 'rite_frost',
  soul_siphon: 'rite_siphon',
  bone_prison: 'rite_prison',
  grave_hands: 'rite_hands',
  bone_storm: 'rite_storm',
  bone_mantle: 'rite_mantle',
  bone_fan: 'rite_fan',
  rot_lance: 'rite_lance',
  grave_offering: 'rite_offering',
  ivory_cleave: 'rite_cleave',
  veil_step: 'rite_veil',
  rally_dead: 'rite_rally',
  carrion_seed: 'rite_seed',
};

interface Remote {
  info: RemotePlayer;
  avatar: NecromancerAvatar;
  /** Their companion, if they have called one. */
  pet?: PetView | null;
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
/** Where a newly opened door sits in the hall it leaves, so the banner tells the player which way to walk. */
function doorDirection(d: DoorDef): string {
  const from = AREAS[d.a].rect;
  const dx = (d.rect.x0 + d.rect.x1) / 2 - (from.x0 + from.x1) / 2;
  const dz = (d.rect.z0 + d.rect.z1) / 2 - (from.z0 + from.z1) / 2;
  const side = Math.abs(dx) >= Math.abs(dz) ? (dx > 0 ? 'east' : 'west') : (dz > 0 ? 'south' : 'north');
  return `the ${side} door of ${AREAS[d.a].name}`;
}

export class WorldScene implements GameScene, RuntimeView {
  readonly scene = new THREE.Scene();
  readonly bloom = { strength: 0.75, radius: 0.55, threshold: 0.85 };
  private rig = new CameraRig();
  private scope = new Scope();
  private root = document.getElementById('ui-root')!;
  private canvas = document.getElementById('scene') as HTMLCanvasElement;

  private discipline: Discipline;
  /** Skull Focus (gold and above): extra thrall cap from the worn off-hand. */
  private weaponThrallBonus = 0;
  /** Resource rules for the active discipline's family (HUD orb label/colour). */
  private resourceRules: ResourceRules;
  /** The active family's kit: which rites this class plays. */
  private kit: Kit;
  /** This account may use the dev overlay (gm_enabled or DEV_ACCOUNTS); the overlay itself is devAccess.active. */
  private devAccount = false;
  /** Hotbar: five Grimoire sockets (slot 5 also casts on right-click) and the signature on R. */
  private hotbar: AbilityId[] = kitFor('necromancer').hotbar;
  /** The five rites on keys 1–5 (Grimoire, L); remembered per character in browser storage. */
  private loadout: AbilityId[];
  /** The left-click primary (Grimoire LMB socket). */
  private primary: AbilityId = 'bone_needle';
  /** Rites seen in the Grimoire (a learned rite outside this set wears NEW). */
  private seen = new Set<AbilityId>();
  private progression: Progression;
  private inventory: Inventory;
  private professions: Profession[] = [];
  private nav = new Nav();
  private layout = generateLayout();
  private effects!: Effects;
  private worldView!: WorldView;
  private views!: EntityViews;
  /** One view per boss (the Prelate's built at load, area bosses on first summon). */
  private bossViews = new Map<BossId, BossView>();
  /** Open graves (Gravedigger P3) until the fight ends. */
  private pitFx: Handle[] = [];
  private chronicle!: Chronicle;
  /** Kill Chain (GRIND-LOOP §3 #8) and the milestone claims that ride on it (§3 #9). */
  private chain = new KillChain();
  private chainTold = false;
  /** This week's Omen (content/omens.ts): same for everyone, so a party sees one sky. */
  private omen: Omen = omenFor();
  private omenTold = false;
  private gatherSession: GatherSession | null = null;
  private gatherReportPanel!: GatherReportPanel;
  private contractsPanel!: ContractsPanel;
  private vaultPanel!: VaultPanel;
  private salvagePanel!: SalvagePanel;
  private locks!: ItemLocks;
  private gardenPanel!: GardenPanel;
  private laborPanel!: LaborPanel;
  private cosmeticsPanel!: CosmeticsPanel;
  private sheetPanel!: CharacterSheetPanel;
  private myCosmetics: { cape: string | null; pet: string | null } = { cape: null, pet: null };
  private petView: PetView | null = null;
  private laborCapNoted = new Set<number>();
  private gardenReady = -1;
  private saintBlessTold = false;
  private saintRainTold = false;
  private saintLinkTold = false;
  private saintFeedAt = 0;
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
  /** DEV: the BinbunVFX review grid, if open. */
  private vfxGallery: Gallery | null = null;
  private stepT = 0;
  private rippleT = 0;
  private rippleCursor = 0;
  private zoneFx = new Map<number, Handle[]>();
  private echoFx = new Map<number, Handle>();
  /** Standing Ossuary Walls: their meshes, removed on wallGone. */
  private wallFx = new Map<number, THREE.Object3D>();
  /** The cracked-crypt marker of the running Grave Surge. */
  private surgeFx: Handle | null = null;

  private keys = new Set<string>();
  /** Theme introduction is shown once per area; later themed waves keep their sound and VFX. */
  private announcedProcessions = new Set<AreaId>();
  private announcedAreas = new Set<AreaId>();
  /** The character's display name: the account name the session token carries. */
  private selfName = tokenUsername(getToken()) ?? 'You';
  private nextAutoCombatAt = 0;
  /** Easy auto movement memory: sticky target, closing hysteresis, committed dodges, smoothed turns. */
  private autoMoveMem: AutoMoveMemory = {};
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
  /** Belt quick-slots: the brew chosen for Z (elixir) and X (tonic); persisted per character. */
  private belt: Record<BrewSlot, string | null> = { elixir: null, tonic: null };
  private ready = false;
  private dataReady: Promise<unknown> = Promise.resolve();
  /** Scene clock in ms (runtime-provided; see GameRuntime.advance). */
  private now = 0;
  private lastMonkBeat = -1;
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

  constructor(
    private character: Character,
    private onLeave: () => void,
    private onClassChanged: (character: Character) => void,
  ) {
    this.discipline = disciplineFor(character.class_index);
    this.resourceRules = resourceRulesFor(this.discipline.family);
    this.kit = kitFor(this.discipline.family);
    // Dev access (runtime overlay, never saved): must be set before the loadout is sanitised.
    this.devAccount = isDevAccount(character, getToken());
    devAccess.active = this.devAccount && devPreference(browserStorage(), character.id);
    const rites = loadRites(browserStorage(), character.id, riteLevel(character.level ?? 1), this.kit);
    this.loadout = rites.keys;
    this.primary = rites.primary;
    this.seen = loadSeen(browserStorage(), character.id, rites, this.kit);
    this.hotbar = this.buildHotbar();
    this.progression = new Progression(character);
    this.applyBoons();
    this.inventory = new Inventory(character.id);
    this.locks = new ItemLocks(character.id);
    this.chronicle = new Chronicle(character.id);
    this.progression.chronicle = this.chronicle;
    void this.chronicle.load();
    this.chronicle.max('peak.level', character.level ?? 1);
    this.scope.add(() => this.chronicle.dispose());
  }

  get camera() {
    return this.rig.camera;
  }

  /** At least one level-gated Grimoire rite is learned (the Grimoire is worth opening). */
  private grimoireUnlocked() {
    return this.kit.grimoire.some((id) => unlockLevel(id) > 1 && riteLevel(this.character.level) >= unlockLevel(id));
  }

  /** Grimoire LMB socket: equip a primary (left-click attack; auto combat uses it too). */
  private setPrimary(id: AbilityId) {
    if (riteLevel(this.character.level) < unlockLevel(id) || this.primary === id) return;
    this.primary = id;
    saveRites(browserStorage(), this.character.id, { primary: this.primary, keys: this.loadout });
    this.markSeen([id]);
    this.hud.setPrimary(id);
    this.grimoirePanel.render();
    audio.play('click');
    const tip = RITE_TIPS[id];
    if (tip) this.onboarding.show(tip);
  }

  private markSeen(ids: AbilityId[]) {
    let changed = false;
    for (const id of ids) if (!this.seen.has(id)) (this.seen.add(id), (changed = true));
    if (changed) saveSeen(browserStorage(), this.character.id, this.seen);
    this.hud?.setGrimoireNew(unseenRites(this.seen, riteLevel(this.character.level), this.kit).length > 0);
  }

  private openGrimoire(select?: number | 'primary') {
    audio.play('click');
    this.closePanels();
    this.gathering?.stop('panel');
    this.grimoirePanel.open(select);
    this.onboarding.show('grimoire');
  }

  /** Areas the nav may walk: the saved seals, or everything under dev access. */
  private openAreas(): AreaId[] {
    return devAccess.active ? [...AREA_ORDER] : this.progression.local.unlocked;
  }

  private buildHotbar(): AbilityId[] {
    return [...this.loadout, this.kit.signatures[this.discipline.id]!];
  }

  /** Grimoire: put a rite on a slot, swapping if it sat on another, and remember it. */
  private setRite(slot: number, id: AbilityId) {
    if (slot < 0 || slot >= LOADOUT_SLOTS || !assignableRites(this.kit).includes(id)
      || riteLevel(this.character.level) < unlockLevel(id) || this.loadout[slot] === id) return;
    this.loadout = assignRite(this.loadout, slot, id);
    saveRites(browserStorage(), this.character.id, { primary: this.primary, keys: this.loadout });
    this.markSeen([id]);
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
    setActiveCharacter(this.character.id, this.character.auto_combat_allowed === true);
    this.buildScene();
    this.nav.setUnlocked(this.openAreas());
    this.worldView = new WorldView(this.scene, this.layout, this.nav, this.effects);
    this.dressWaystones();
    for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d), true);
    this.views = new EntityViews(this.scene, this.effects, (owner) => {
      if (owner === this.selfId) return this.discipline.id;
      const remote = this.remotes.get(owner);
      return remote ? disciplineFor(remote.info.classIndex).id : null;
    });
    this.nodeViews = new NodeViews(this.scene, this.layout.nodes);
    const prelate = new BossView(this.scene, this.effects);
    this.bossViews.set('prelate', prelate);
    this.scope.add(prewarmCreature(prelate.c, getRuntime().renderer, this.rig.camera, this.scene));
    this.loot = new LootView(this.scene, this.effects);

    const stats = deriveStats(this.character, [], this.discipline, this.progression.local.damageTier);
    this.player = new Player(stats, this.nav, this.discipline.family);
    this.player.soulsMax = Math.max(10, SOUL_HARVEST.souls - this.progression.boons.soulsDiscount);
    this.player.teleport(PLAYER_SPAWN.x, PLAYER_SPAWN.z);
    this.avatar = new NecromancerAvatar(this.scene, this.discipline.color, true, this.discipline.modelSlug);
    // Worn gear shows on the hero: weapon, off-hand and helm follow the equipped rows.
    const syncGear = () => {
      const worn = equippedBySlot(this.inventory.all);
      this.avatar.setEquipment(worn);
      this.broadcastGear(worn);
    };
    this.scope.add(this.inventory.onChange(syncGear));
    syncGear();
    this.rig.snap(this.player.x, this.player.z);
    // A quiet discipline glow and a warm bone ring keep the hero readable on violet and dark stone.
    const follow = () => ({ x: this.player.x, z: this.player.z });
    this.effects.decal({ tex: fx.glow(), color: this.discipline.color, x: 0, z: 0, r: 2.2, duration: 1e9, opacity: 0.13, fadeIn: 0.01, follow });
    this.effects.decal({ tex: fx.ring(), color: 0xc8bea8, x: 0, z: 0, r: 0.85, duration: 1e9, opacity: 0.46, fadeIn: 0.01, follow });
    // A small ground reticle follows the mouse independently of the hero ring.
    this.effects.decal({ tex: fx.ring(), color: 0xb6a9c8, x: 0, z: 0, r: 0.35, duration: 1e9, opacity: 0.36, fadeIn: 0.01, follow: () => ({ x: this.groundPoint.x, z: this.groundPoint.z }) });
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
        return e && (e.state !== 'rising' && e.state !== 'burrow') ? { x: e.x, z: e.z } : null;
      },
    });

    this.sim = new WorldSim(this.nav);
    this.sim.omen = this.omen;
    this.sim.setCrypts(this.layout.crypts);
    this.sim.setCover(this.pewCover());
    this.sim.setNodes(this.layout.nodes);
    this.sim.waveTier = this.progression.local.waveTierActive;
    this.sim.difficulty = settings.difficulty;
    this.sim.ascension = this.progression.local.ascension;

    const scene = this;
    this.abilities = new AbilitySystem({
      selfId: this.selfId,
      player: this.player,
      // A getter: Covenant boons and a Skull Focus swap replace this.discipline, and the abilities must see the current cap.
      get discipline() { return scene.discipline; },
      avatar: this.avatar,
      effects: this.effects,
      enemies: () => this.enemiesMap(),
      boss: () => this.bossState(),
      corpses: () => this.corpsesMap(),
      thrallCount: () => [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId).length,
      send: (i) => this.sendIntent(i),
      number: (x, z, amount, kind) => this.floating.spawn(x, 1.6, z, Math.round(amount).toString(), kind === 'crit' ? 'crit' : 'hit'),
      shake: (a) => this.rig.shake(a),
      note: (text, kind) => this.floating.spawn(this.player.x, 2.4, this.player.z, text, kind),
      now: () => this.now,
      thralls: () => this.thrallsMap(),
      dash: (tx, tz) => this.dashTarget(tx, tz),
      aim: () => ({ x: this.groundPoint.x, z: this.groundPoint.z }),
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
          this.avatar.setGatheringTool(null);
          this.avatar.c.releaseGesture();
          this.nodeViews.selected(null);
          const text = message ?? STOP_TEXT[reason as keyof typeof STOP_TEXT] ?? null;
          if (text) this.floating.spawn(this.player.x, 2.4, this.player.z, text, 'info');
          if (reason === 'bagFull') this.onboarding.show('bag_full');
          this.endGatherSession(reason);
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
    this.hud.setDev(devAccess.active);
    this.markSeen([]);
    this.bindInput();
    this.scope.add(this.progression.onChange(() => this.refreshStats()));
    this.scope.add(onSettingsChange((s) => this.onDifficultySetting(s.difficulty)));
    // The Binbun layer is extra polish: High quality only, so Low stays light and calm.
    this.effects.binbun.enabled = settings.quality === 'high';
    if (this.effects.binbun.enabled) preloadBinbun(GROUND_FX_PRELOAD);
    this.scope.add(onSettingsChange((s) => {
      this.effects.binbun.enabled = s.quality === 'high';
      if (this.effects.binbun.enabled) preloadBinbun(GROUND_FX_PRELOAD);
    }));
    this.scope.add(this.inventory.onChange(() => this.refreshStats()));
    this.scope.on(window, 'pagehide', () => {
      void this.progression.flush(true);
      void this.inventory.flush();
      void this.gathering.flush(true);
    });

    getRuntime().setView(this);
    const inventoryReady = this.loadData();
    // Offline dev tokens are not JWTs: only try co-op there when asked (?offline&coop).
    if (!OFFLINE || (import.meta.env.DEV && new URLSearchParams(location.search).has('coop'))) void this.connectRealtime();
    if (import.meta.env.DEV) this.installDebug();

    this.enterArea('acre');
    // First steps: where you are, then how to move (queued, one card at a time).
    // Server-backed progression when the auth server has it; browser storage otherwise.
    this.scope.add(this.progression.onError((msg) => this.hud.toast(msg, 'err')));
    this.scope.add(this.progression.onSynced(() => this.onProgressSynced()));
    this.dataReady = Promise.all([inventoryReady, this.progression.connect()]);
    // The garden grows on the server's clock: say what is waiting on arrival, and as plots come ready.
    void this.dataReady.then(() => window.setTimeout(() => void this.checkGarden(true), 4000));
    this.scope.interval(() => void this.checkGarden(false), 60_000);
    void this.dataReady.then(() => window.setTimeout(() => void this.checkLabor(true), 6000));
    void this.dataReady.then(() => getCosmetics(this.character.id)).then((v) => this.applyCosmetics(v.selected)).catch(() => {});
    this.scope.interval(() => void this.checkLabor(false), 5 * 60_000);
    this.onboarding.show('welcome', 900);
    this.onboarding.show('move', 1600);
    // First time in the world as a Knight: Rage works nothing like essence.
    if (this.discipline.family === 'knight') this.onboarding.show('knight_rage', 2600);
    if (this.discipline.family === 'warden') this.onboarding.show('warden_oil', 2600);
    if (this.discipline.family === 'monk') this.onboarding.show('monk_beat', 2600);
    if (this.discipline.family === 'witch') this.onboarding.show('witch_offal', 2600);
    if (this.discipline.family === 'veil') this.onboarding.show('veil_forms', 2600);
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
    moon.shadow.mapSize.set(1024, 1024);
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
      this.locks.prune(slots);
      // From here on every bag change lets lapsed locks go and watches for a filling bag (counsel tip).
      this.inventory.onChange((bag) => {
        this.locks.prune(bag);
        if (bag.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE).length >= Math.ceil(BAG_SIZE * 0.8)) this.onboarding.show('bag_filling');
      });
      this.professions = professions;
      for (const r of professions) this.skillLevels.set(r.profession_id as SkillId, r.skill_level);
      this.skills.adopt(professions);
      this.refreshStats();
    } catch (err) {
      this.hud.toast(err instanceof Error ? err.message : 'Failed to load your reliquary', 'err');
    }
  }

  /** The left click's reach with the worn weapon (a scythe's arc is short, a staff's needle long). */
  private primaryRange() {
    return abilityRange(this.primary, ABILITIES[this.primary].range, this.player.loadout);
  }

  private refreshStats() {
    if (!this.player) return;
    const stats = deriveStats(this.character, this.inventory.all, this.discipline, this.progression.local.damageTier);
    this.player.setStats(stats);
    // Necro weapon line: the worn weapon/off-hand change the left click and add a passive (gameplay/weaponLine.ts).
    const loadout = resolveWeaponLoadout(equippedBySlot(this.inventory.all), this.discipline.id);
    const was = this.player.loadout;
    this.player.loadout = loadout;
    if (loadout.main !== was.main && loadout.main && loadout.main !== 'staff') this.onboarding.show('necroWeapon');
    if (loadout.thrallBonus !== this.weaponThrallBonus) {
      this.weaponThrallBonus = loadout.thrallBonus;
      this.applyBoons();
      return;
    }
    if (this.sim && (this.isAuthority())) this.sim.waveTier = this.progression.local.waveTierActive;
    this.inventoryPanel?.render();
    this.sheetPanel?.render();
  }

  /** Who the gear text is for; null until the player exists. The discipline already carries boons and a skull-focus swap. */
  private statContext = (): StatContext | null =>
    this.player ? { character: this.character, slots: this.inventory.all, discipline: this.discipline, damageTier: this.progression.local.damageTier } : null;

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
      openGrimoire: (select) => this.openGrimoire(select),
    }, this.hotbar, this.discipline, this.primary);
    this.hud.minimap.onNavigate = (x, z) => this.navigateFromMinimap(x, z);
    this.loadBelt();
    this.inventoryPanel = new InventoryPanel(this.root, this.character.id, this.inventory, this.statsLine, (id) => this.drinkFlask(id), (id) => this.setBelt(id), (gold, name, n) => {
      this.progression.addGold(gold);
      audio.play('coin');
      this.floating.spawn(this.player.x, 2.4, this.player.z, `+${gold.toLocaleString()}g`, 'gold');
      this.chronicle.add('sold', n);
      this.hud.toast(`Sold ${n > 1 && !/junk item/.test(name) ? `${n}× ` : ''}${name} for ${gold.toLocaleString()} gold`, 'good');
    }, this.locks, {
      near: () => this.nearGrinder(),
      salvage: async (slots) => this.onSalvaged(await runSalvage(this.inventory, this.character.id, slots)),
    });
    // Gear you can read: stat lines and compare blocks speak for this character, and J opens the sheet.
    this.inventoryPanel.statContext = this.statContext;
    this.inventoryPanel.onSheet = () => this.togglePanel('sheet');
    this.inventoryPanel.onEquipped = () => this.onboarding.show('gearEquip');
    this.sheetPanel = new CharacterSheetPanel(this.root, this.statContext, () => this.onboarding.show('statSheet'));
    this.forgePanel = new ForgePanel(this.root, this.character.id, this.inventory, (inv, profs) => {
      this.inventory.replace(inv);
      this.skills.adopt(profs);
      this.chronicle.add('crafted');
      this.hud.toast('Crafted', 'good');
    });
    this.professionsPanel = new ProfessionsPanel(this.root, {
      start: type => this.startAfkGathering(type),
      pause: () => this.gathering.stop('moved'),
      status: () => ({ active: this.gathering.afk, text: this.gathering.status, allowed: this.player.area === 'acre' }),
    }, () => this.inventory.all.map((s) => s.item_id), () => this.togglePanel('contracts'), () => this.togglePanel('garden'), () => this.togglePanel('labor'), () => this.togglePanel('cosmetics'));
    this.cosmeticsPanel = new CosmeticsPanel(this.root, this.character.id, this.inventory, (v) => this.applyCosmetics(v.selected));
    this.laborPanel = new LaborPanel(this.root, this.character.id, this.inventory, (skill) => this.skills.level(skill), (r) => this.onLaborCollected(r));
    this.gardenPanel = new GardenPanel(this.root, this.character.id, this.inventory, (kind, r) => this.onGardenResult(kind, r));
    this.contractsPanel = new ContractsPanel(this.root, this.character.id, this.inventory, (d) => this.onContractDelivered(d));
    this.vaultPanel = new VaultPanel(this.root, this.character.id, this.inventory, this.locks, () => this.onboarding.show('vault'));
    this.salvagePanel = new SalvagePanel(this.root, this.character.id, this.inventory, this.locks, this.skills, (r) => this.onSalvaged(r), () => this.onboarding.show('salvage'));
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
      this.devAccount ? { get: () => devAccess.active, set: (on) => this.setDevAccess(on) } : undefined,
      {
        primary: ABILITIES[this.kit.defaultPrimary].name,
        rites: this.kit.defaultLoadout.map((id) => ABILITIES[id].name),
        corpseAction: ABILITIES[this.kit.rmb].name,
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
    this.gatherReportPanel = new GatherReportPanel(this.root, () => this.togglePanel('inventory'));
    this.codexPanel = new CodexPanel(this.root, this.codex, this.discipline.id, this.chronicle);
    this.grimoirePanel = new GrimoirePanel(
      this.root,
      () => ({ rites: { primary: this.primary, keys: this.loadout }, level: riteLevel(this.character.level), unseen: unseenRites(this.seen, riteLevel(this.character.level), this.kit), kit: this.kit }),
      (slot, id) => this.setRite(slot, id),
      (id) => this.setPrimary(id),
      (ids) => this.markSeen(ids),
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
    const rmb = 'Right-click or press 5 for your fifth equipped rite · click swap below its icon to change it';
    this.hud.hint(OFFLINE ? `OFFLINE EDITION — progress stays on this device · ${rmb}` : rmb);
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
    this.gatherReportPanel?.close();
    this.contractsPanel?.close();
    this.vaultPanel?.close();
    this.salvagePanel?.close();
    this.gardenPanel?.close();
    this.laborPanel?.close();
    this.cosmeticsPanel?.close();
    this.sheetPanel?.close();
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

  /** A laborer came home: credit gold and the skill, count the finds, and show what they brought in the Ledger. */
  private onLaborCollected(r: LaborResult) {
    const c = r.collected;
    if (!c) return;
    this.celebrateCharms(c.items);
    const skill = c.skill as SkillId;
    const before = this.skills.level(skill);
    const total = c.items.reduce((n, g) => n + g.qty, 0);
    const lifeBefore = this.chronicle.view().life[`gathered.${skill}`] ?? 0;
    if (c.gold > 0) this.progression.addGold(c.gold);
    this.chronicle.add(`gathered.${skill}`, total);
    audio.play('coin');
    void getProfessions(this.character.id).then((rows) => {
      this.skills.adopt(rows);
      const items = c.items.map((g) => {
        const m = itemMeta(g.itemId);
        return { itemId: g.itemId, name: m.name, rarity: m.rarity, qty: g.qty, value: m.sell * g.qty };
      }).sort((a, b) => b.value - a.value);
      const rank = { common: 0, uncommon: 1, rare: 2, epic: 3 } as const;
      const best = [...items].sort((a, b) => rank[b.rarity] - rank[a.rarity] || b.value - a.value)[0];
      const after = this.skills.level(skill);
      const milestones = crossedMilestones(lifeBefore, lifeBefore + total).map((m) => `${m.toLocaleString()} ${SKILLS[skill].name} finds`);
      if (after > before) milestones.push(`${SKILLS[skill].name} level ${after}`);
      this.closePanels();
      this.gatherReportPanel.show({
        seconds: Math.round(c.hours * 3600), reason: 'labor', items, totalItems: total, goldValue: items.reduce((n, i) => n + i.value, 0), gold: c.gold,
        skills: [{ skill, name: SKILLS[skill].name, xp: c.xp, fromLevel: before, toLevel: after, items: total }],
        best: best && rank[best.rarity] > 0 ? best : null, milestones, records: [],
      });
    }).catch(() => this.hud.toast(`Your laborers brought ${total.toLocaleString()} finds`, 'good'));
  }

  /** Tell the player when their laborers have work waiting: on arrival, and once when a laborer is full. */
  private async checkLabor(arrival: boolean) {
    try {
      const v = await getLabor(this.character.id);
      const waiting = v.slots.filter((s) => s.nodeType && s.elapsedMs >= 30 * 60_000);
      const items = waiting.reduce((n, s) => n + s.estItems, 0);
      const full = v.slots.filter((s) => s.capped && !this.laborCapNoted.has(s.slot));
      for (const s of full) this.laborCapNoted.add(s.slot);
      for (const s of v.slots) if (!s.capped) this.laborCapNoted.delete(s.slot);
      if (arrival && waiting.length) this.hud.toast(`Your laborers have gathered about ${items.toLocaleString()} finds (H)`, 'good');
      else if (full.length) this.hud.toast(`A laborer has filled up: collect what they gathered (H)`, 'good');
    } catch {
      /* a nicety: try again next time */
    }
  }

  /** Plant / harvest finished: credit the skill, count the crop, and tell the player. */
  private onGardenResult(kind: 'plant' | 'harvest', r: GardenResult) {
    audio.play(kind === 'harvest' ? 'coin' : 'click');
    void getProfessions(this.character.id).then((rows) => this.skills.adopt(rows)).catch(() => {});
    if (kind === 'harvest' && r.items?.length) {
      this.celebrateCharms(r.items);
      const crop = r.items[0];
      this.chronicle.add('gathered.gardening', crop.qty);
      const seedBack = r.items[1];
      this.hud.toast(`Harvested ${crop.qty}× ${itemMeta(crop.itemId).name}${seedBack ? ' (and a seed to replant)' : ''}`, 'good');
    }
    if (r.leveledUp) this.hud.banner(`Grave Gardening ${r.level}`, 'The beds answer you more readily', 2600);
    this.gardenReady = r.plots.filter((p) => p.state === 'ready').length;
  }

  /** Tell the player when the garden has something waiting: on arrival, and as plots come ready while they play. */
  private async checkGarden(arrival: boolean) {
    try {
      const v = await getGarden(this.character.id);
      const ready = v.plots.filter((p) => p.state === 'ready').length;
      const growing = v.plots.filter((p) => p.state === 'growing').length;
      if (ready > 0 && (arrival || ready > this.gardenReady)) {
        this.hud.toast(`${ready} plot${ready === 1 ? ' is' : 's are'} ready in your garden (U)`, 'good');
      } else if (arrival && growing > 0) {
        this.hud.toast(`${growing} plot${growing === 1 ? ' is' : 's are'} still growing in your garden (U)`);
      }
      this.gardenReady = ready;
    } catch {
      /* the garden is a nicety: a failed check just tries again next minute */
    }
  }

  /** Close enough to the Bone Grinder for the Reliquary's Salvage button. */
  private nearGrinder() {
    const g = AREAS.acre.interactables.find((i) => i.kind === 'grinder');
    return !!g && this.area === 'acre' && Math.hypot(g.x - this.player.x, g.z - this.player.z) < INTERACT_RANGE + 2;
  }

  private onSalvaged(r: SalvageReply) {
    this.skills.adopt([{ profession_id: 'salvaging', skill_level: r.level, skill_xp: r.skillXp }], 'salvaging');
    audio.play('click');
    this.floating.spawn(this.player.x, 2.3, this.player.z, `+${r.xp} Salvaging XP`, 'skill', SKILLS.salvaging.color);
    this.hud.toast(`Ground ${r.salvaged.length} piece${r.salvaged.length === 1 ? '' : 's'}: ${r.gained.map((g) => `${g.quantity}× ${itemMeta(g.item_id).name}`).join(', ')}`, 'good');
    this.onboarding.show('salvage');
  }

  private onContractDelivered(d: ContractDelivery) {
    if (d.gold > 0) {
      this.progression.addGold(d.gold);
      audio.play('coin');
      this.floating.spawn(this.player.x, 2.4, this.player.z, `+${d.gold.toLocaleString()}g`, 'gold');
    }
    this.chronicle.add('contracts');
    this.hud.toast(d.paidBonus ? `Order filled, and the day’s bonus is yours: +${d.paidBonus.gold.toLocaleString()}g` : 'Order filled', 'good');
  }

  private togglePanel(p: 'inventory' | 'forge' | 'professions' | 'settings' | 'map' | 'codex' | 'ascension' | 'grimoire' | 'contracts' | 'garden' | 'labor' | 'cosmetics' | 'vault' | 'salvage' | 'sheet') {
    audio.play('click');
    const panel = { inventory: this.inventoryPanel, forge: this.forgePanel, professions: this.professionsPanel, settings: this.settingsPanel, map: this.waystonePanel, codex: this.codexPanel, ascension: this.ascensionPanel, grimoire: this.grimoirePanel, contracts: this.contractsPanel, garden: this.gardenPanel, labor: this.laborPanel, cosmetics: this.cosmeticsPanel, vault: this.vaultPanel, salvage: this.salvagePanel, sheet: this.sheetPanel }[p];
    const wasOpen = panel.isOpen;
    this.closePanels();
    if (wasOpen) return;
    if (!(p === 'professions' && this.gathering?.afk)) this.gathering?.stop('panel');
    if (p === 'professions') this.professionsPanel.open(this.skills);
    else if (p === 'inventory') this.inventoryPanel.open();
    else if (p === 'forge') void this.forgePanel.open();
    else if (p === 'settings') this.settingsPanel.open();
    else if (p === 'codex') this.codexPanel.open();
    else if (p === 'contracts') void this.contractsPanel.open();
    else if (p === 'vault') {
      if (!AREAS[this.area].safe) {
        this.hud.toast('The Vault is in the Chapterhouse', 'err');
        return;
      }
      void this.vaultPanel.open();
    } else if (p === 'salvage') this.salvagePanel.open();
    else if (p === 'garden') void this.gardenPanel.open();
    else if (p === 'labor') void this.laborPanel.open();
    else if (p === 'cosmetics') void this.cosmeticsPanel.open();
    else if (p === 'sheet') this.sheetPanel.open();
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
    if (!canUseAutoCombat()) return;
    if (settings.difficulty !== 'easy') {
      this.hud.toast('Auto combat is available on Easy difficulty. Change it in Settings.');
      return;
    }
    updateSettings({ autoCombat: !settings.autoCombat });
    this.autoTargetId = null;
    this.autoAim = null;
    this.hud.toast(settings.autoCombat ? 'Auto combat on — your hero engages nearby enemies. Click or use keys to take control; G turns it off.' : 'Auto combat off — click enemies and use your rites manually.', 'good');
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
      else if (k === BREW_KEYS.elixir) this.drinkBelt('elixir');
      else if (k === BREW_KEYS.tonic) this.drinkBelt('tonic');
      else if (k === 't') this.startRecall();
      else if (k === 'i' || k === 'b') this.togglePanel('inventory');
      else if (k === 'j') this.togglePanel('sheet');
      else if (k === 'c') this.togglePanel('forge');
      else if (k === 'p') this.togglePanel('professions');
      else if (k === 'o') this.togglePanel('contracts');
      else if (k === 'u') this.togglePanel('garden');
      else if (k === 'h') this.togglePanel('labor');
      else if (k === 'n') this.togglePanel('cosmetics');
      else if (k === 'v') this.togglePanel('vault');
      else if (k === 'm') this.togglePanel('map');
      else if (k === 'k') this.togglePanel('codex');
      else if (k === 'l') this.togglePanel('grimoire');
      else if (k === 'g') this.toggleAutoCombat();
      // Escape closes whatever panel is open first; with nothing open it opens Settings.
      else if (k === 'escape') {
        if (this.panelOpen() && !this.settingsPanel.isOpen) this.closePanels();
        else this.togglePanel('settings');
      }
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
      if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow')) continue;
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
    this.nodeViews.hover(hn, hn ? this.skills.gateLevel(NODES[hn.type].skill) >= NODES[hn.type].level : true);
    this.hud.nodeTip(hn ? this.nodeTipText(hn) : null, this.mouse.x, this.mouse.y);
    const h = this.hover as Hover;
    this.views.hoverId = h?.kind === 'enemy' ? h.id : null;
    const cur = h?.kind === 'enemy' || h?.kind === 'boss' ? CURSOR.attack : h?.kind === 'interact' || h?.kind === 'node' ? CURSOR.interact : CURSOR.default;
    if (this.canvas.style.cursor !== cur) this.canvas.style.cursor = cur;
  }

  private panelOpen() {
    return this.classPanel.isOpen || this.settingsPanel.isOpen || this.inventoryPanel.isOpen || this.forgePanel.isOpen || this.professionsPanel.isOpen || this.codexPanel.isOpen || this.grimoirePanel.isOpen || this.ascensionPanel.isOpen || this.waystonePanel.isOpen || !!this.gatherReportPanel?.isOpen || !!this.contractsPanel?.isOpen || !!this.vaultPanel?.isOpen || !!this.salvagePanel?.isOpen || !!this.gardenPanel?.isOpen || !!this.laborPanel?.isOpen || !!this.cosmeticsPanel?.isOpen || !!this.sheetPanel?.isOpen;
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
    this.effects.decal({ tex: fx.ring(), color: 0xb6a9c8, x: this.groundPoint.x, z: this.groundPoint.z, r: 0.45, duration: 0.35, opacity: 0.62, growFrom: 1.6 });
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
    for (let slot = 1; slot <= 5; slot++) {
      if (this.keys.has(String(slot))) {
        if (this.abilities.ready(this.hotbar[slot - 1], now)) this.castSlot(slot as HotbarSlot);
        return;
      }
    }
    // Easy auto yields to deliberate movement, menus, gathering and manual targets.
    if (!canUseAutoCombat() || !settings.autoCombat || p.hasPath || this.attackTarget || this.keys.size || this.gathering.active) {
      this.autoTargetId = null;
      this.autoAim = null;
      return;
    }
    if (now < this.nextAutoCombatAt) return;
    this.nextAutoCombatAt = now + 180;
    const thralls = [...this.thrallsMap().values()].filter(t => t.owner === this.selfId).length;
    if (p.hp < p.stats.maxHp * 0.42 && now >= this.flaskCdUntil &&
        (this.inventory.count('flask_hp_grand') || this.inventory.count('flask_hp_major') || this.inventory.count('flask_hp_minor'))) this.drinkFlask();
    const action = selectAutoCombatAction({ player: { x: p.x, z: p.z, area: p.area, essence: p.essence, maxEssence: p.resource.max,
      hp: p.hp, maxHp: p.stats.maxHp, veilForm: p.veilForm, bulwarkUntil: p.bulwarkUntil,
      betweenUntil: p.betweenUntil, unbreakableUntil: p.unbreakableUntil },
      enemies: this.enemiesMap().values(), corpses: this.corpsesMap().values(), boss: this.bossState(),
      thrallCount: thralls, thrallCap: this.discipline.mods.thrallCap,
      ready: id => (id === this.primary || this.hotbar.includes(id)) && this.abilities.ready(id, now),
      primary: this.primary, primaryRange: this.primaryRange(), selfId: this.selfId, family: this.discipline.family, signature: this.hotbar[5], now });
    const previous = this.autoTargetId === null ? undefined : this.enemiesMap().get(this.autoTargetId);
    this.autoTargetId = action?.target.enemyId ?? (previous && previous.hp > 0 && previous.state !== 'dead' && Math.hypot(previous.x - p.x, previous.z - p.z) <= this.primaryRange() ? previous.id : null);
    if (action) this.autoAim = action.target;
    else if (this.autoTargetId === null && !(this.autoAim?.boss && this.bossState().active && this.bossState().hp > 0)) this.autoAim = null;
    // Walk toward what we are shooting at, so movement and aim never pull in two directions.
    if (action?.target.enemyId !== undefined) this.autoMoveMem.targetId = action.target.enemyId;
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

  /** A meal heals over time (content/processing.ts MEALS); one at a time, and it stacks with a flask. */
  private mealUntil = 0;
  private mealRate = 0;
  private eatMeal(id: string) {
    const meal = MEALS[id];
    const now = this.now;
    if (!meal || !this.player.alive) return;
    if (now < this.mealUntil) {
      this.floating.spawn(this.player.x, 2.4, this.player.z, 'Still eating', 'info');
      return;
    }
    if (!this.inventory.consume(id)) return;
    this.mealUntil = now + meal.seconds * 1000;
    this.mealRate = (this.player.stats.maxHp * meal.healFrac) / meal.seconds;
    this.floating.spawn(this.player.x, 2.2, this.player.z, `Well fed · +${Math.round(meal.healFrac * 100)}% over ${meal.seconds}s`, 'gold');
    this.effects.emit({ x: this.player.x, y: 0.8, z: this.player.z, count: 14, color: 0xe9c98f, spread: 0.4, speed: 0.4, up: 1.2, life: 0.8, size: 0.22 });
    this.onboarding.show('meal');
  }

  private drinkBuff(id: string) {
    const b = BREWS[id];
    if (!b || !this.player.alive || !this.inventory.count(id)) return;
    const before = this.player.brews[b.slot];
    const prev = before && this.now < before.until ? BREWS[before.id] : null;
    if (!this.inventory.consume(id)) return;
    const r = applyBrew(this.player.brews, id, this.now);
    const text = r.replaced && prev ? `${b.label} replaces ${prev.label}` : r.extended ? `${b.label} extended · ${Math.round((r.until - this.now) / 1000)}s` : `${b.label} · ${b.seconds}s`;
    this.floating.spawn(this.player.x, 2.2, this.player.z, text, 'gold');
    this.effects.emit({ x: this.player.x, y: 0.8, z: this.player.z, count: 18, color: b.color, spread: 0.4, speed: 0.6, up: 1.8, life: 0.8, size: 0.24 });
    audio.play('shard');
    this.onboarding.show('brew');
  }

  /** The brew a belt key drinks: the chosen one while the bag has it, else the first brew of that slot you carry. */
  private beltBrew(slot: BrewSlot): string | null {
    const pick = this.belt[slot];
    if (pick && this.inventory.count(pick)) return pick;
    return Object.keys(BREWS).find((id) => BREWS[id].slot === slot && this.inventory.count(id) > 0) ?? null;
  }

  private drinkBelt(slot: BrewSlot) {
    const id = this.beltBrew(slot);
    if (!id) {
      if (this.player.alive) this.floating.spawn(this.player.x, 2.4, this.player.z, `No ${slot} on your belt`, 'info');
      return;
    }
    this.drinkBuff(id);
  }

  private beltKey() {
    return `${import.meta.env.VITE_OFFLINE_BUILD === '1' ? 'dm_offline_' : ''}dm_belt_${this.character.id}`;
  }

  private loadBelt() {
    try {
      const raw = JSON.parse(localStorage.getItem(this.beltKey()) ?? '{}') as Partial<Record<BrewSlot, string>>;
      for (const slot of BREW_SLOTS) this.belt[slot] = raw[slot] && BREWS[raw[slot]!]?.slot === slot ? raw[slot]! : null;
    } catch { /* storage unavailable: the belt auto-fills */ }
  }

  private setBelt(id: string) {
    const b = BREWS[id];
    if (!b) return;
    this.belt[b.slot] = id;
    try { localStorage.setItem(this.beltKey(), JSON.stringify(this.belt)); } catch { /* ignore */ }
    this.hud.toast(`${b.label} is on your belt: press ${BREW_KEYS[b.slot].toUpperCase()} to drink it`, 'good');
  }

  /** HUD tray rows: one per slot, the active brew (countdown) or the belted one waiting. Null when there is nothing to show. */
  private brewTray() {
    const now = this.now;
    return BREW_SLOTS.map((slot) => {
      const act = this.player.brews[slot];
      const live = act && now < act.until ? act : null;
      const beltId = this.beltBrew(slot);
      const shown = live ? live.id : beltId;
      if (!shown) return null;
      const def = BREWS[shown];
      const left = live ? Math.ceil((live.until - now) / 1000) : 0;
      return {
        slot, key: BREW_KEYS[slot].toUpperCase(), label: def.label, glyph: def.glyph, color: def.color, active: !!live, left,
        frac: live ? Math.min(1, (live.until - now) / (def.seconds * 1000)) : 0,
        count: beltId ? this.inventory.count(beltId) : 0,
        tip: live
          ? `${slotName(slot)}: ${def.label} · ${brewEffectsText(def)} · ${left}s left. ${beltId ? `Press ${BREW_KEYS[slot].toUpperCase()} for another (${this.inventory.count(beltId)} on your belt).` : ''}`
          : `${slotName(slot)} on your belt: ${def.label} · ${brewEffectsText(def)} for ${def.seconds}s. Press ${BREW_KEYS[slot].toUpperCase()} to drink (${this.inventory.count(shown)} left).`,
      };
    });
  }

  private drinkFlask(prefer?: string) {
    if (prefer && prefer in MEALS) return this.eatMeal(prefer);
    if (prefer && prefer in BREWS) return this.drinkBuff(prefer);
    const now = this.now;
    if (!this.player.alive || now < this.flaskCdUntil) return;
    const id = prefer && prefer in HEALING_FLASKS ? prefer : ['flask_hp_grand', 'flask_hp_major', 'flask_hp_minor'].find((f) => this.inventory.count(f) > 0);
    if (!id || !this.inventory.consume(id)) {
      this.floating.spawn(this.player.x, 2.4, this.player.z, 'No healing flasks', 'info');
      return;
    }
    this.flaskCdUntil = now + 1500;
    const amount = this.player.stats.maxHp * HEALING_FLASKS[id];
    this.player.heal(amount);
    this.floating.spawn(this.player.x, 2.2, this.player.z, `+${Math.round(amount)}`, 'heal');
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
      case 'vault':
        this.gathering.stop('panel');
        return this.togglePanel('vault');
      case 'grinder':
        this.gathering.stop('panel');
        return this.togglePanel('salvage');
      case 'lectern':
        // The Covenant Lectern by the Acre spawn: the Codex (First Rites will live here too).
        this.onboarding.show('codex');
        return this.togglePanel('codex');
      case 'boss': {
        // One awake boss per world (area bosses brief §2.3).
        const id = bossForSummon(it.id) ?? 'prelate';
        const def = BOSSES[id];
        const b = this.bossState();
        if (b.active) {
          const awake = BOSSES[b.id ?? 'prelate'];
          if (awake.id !== id) this.hud.toast(`${awake.name} already stirs in ${AREAS[awake.area].name}.`, 'err');
          return;
        }
        if (!(id === 'prelate' ? this.progression.spendShards(def.shards) : this.progression.spendBossShards(id))) {
          this.hud.toast(`${def.summonLabel} demands ${def.shards} soul shards (you have ${this.progression.local.shards}). Elites carry them.`, 'err');
          return;
        }
        this.sendIntent({ t: 'summonBoss', by: this.selfId, boss: id });
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
    // Lifesteal (elixir): every direct hit the player lands goes through here, so this is the one place it applies.
    if (intent.t === 'hit' && intent.by === this.selfId && this.player.alive) {
      const ls = this.player.brewValue('lifesteal', this.now);
      if (ls > 0) {
        const heal = lifestealHeal(intent.dmg, intent.ids.length + (intent.boss ? 1 : 0), ls, this.player.stats.maxHp);
        if (heal >= 1) this.player.heal(heal);
      }
    }
    if (this.sim && this.isAuthority()) this.sim.apply(intent);
    else this.realtime.sendIntent(intent);
  }

  private async connectRealtime() {
    try {
      const res = await this.realtime.connect(
        {
          characterId: this.character.id,
          classIndex: this.character.class_index,
          level: this.character.level,
          x: this.player.x,
          z: this.player.z,
          facing: this.player.facing,
          gear: this.currentGearIds(),
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
            r.pet?.dispose();
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
          onPlayerGear: (u) => {
            const r = this.remotes.get(u.id);
            if (!r) return;
            r.avatar.setEquipment(gearFromIds(u.gear));
            this.dressRemote(r, u.gear);
          },
          onChat: (m) => this.hud.chatLine(`${m.name}: ${m.text}`),
          onDisconnect: () => {
            for (const r of this.remotes.values()) { r.avatar.dispose(); r.pet?.dispose(); }
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
    sim.setCover(this.pewCover());
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

  private currentGearIds() {
    const gear: Record<string, string> = {};
    for (const [slot, it] of Object.entries(equippedBySlot(this.inventory.all))) if (it) gear[slot] = it.item_id;
    if (this.myCosmetics.cape) gear.cape = this.myCosmetics.cape;
    if (this.myCosmetics.pet) gear.pet = this.myCosmetics.pet;
    return gear;
  }

  /** Dress the hero: the cape on the back and the companion at their heel. Called with the server's saved choice. */
  private applyCosmetics(sel: { cape: string | null; pet: string | null }) {
    this.myCosmetics = { cape: sel.cape, pet: sel.pet };
    this.avatar.setCape(sel.cape);
    const def = sel.pet ? petDef(sel.pet) : undefined;
    if ((this.petView?.id ?? null) !== (def?.id ?? null)) {
      this.petView?.dispose();
      this.petView = def ? new PetView(this.scene, def, this.player.x, this.player.z) : null;
    }
    this.broadcastGear(equippedBySlot(this.inventory.all), true);
  }

  /** Another player's cape and companion, from the ids they broadcast (checked against the catalogue). */
  private dressRemote(r: Remote, gear: Record<string, string> | undefined) {
    r.avatar.setCape(isCape(gear?.cape) ? gear!.cape : null);
    const pet = isPet(gear?.pet) ? petDef(gear!.pet) : undefined;
    if ((r.pet?.id ?? null) !== (pet?.id ?? null)) {
      r.pet?.dispose();
      r.pet = pet ? new PetView(this.scene, pet, r.tx, r.tz) : null;
    }
  }

  /** A charm turned up: a rare moment worth a banner (gathering, laborers and the garden all funnel through here). */
  private celebrateCharms(items: { itemId: string }[]) {
    for (const g of items) {
      const pet = petForCharm(g.itemId);
      if (!pet) continue;
      this.hud.banner('A rare find!', `${itemMeta(g.itemId).name}: adopt it in Capes & Pets (N)`, 4200);
      audio.play('skillUp');
    }
  }

  /** Tell the world what we're wearing (item ids only), when it changes and once after joining. */
  private lastGearSent = '';
  private broadcastGear(worn: ReturnType<typeof equippedBySlot>, force = false) {
    const gear: Record<string, string> = {};
    for (const [slot, it] of Object.entries(worn)) if (it) gear[slot] = it.item_id;
    if (this.myCosmetics.cape) gear.cape = this.myCosmetics.cape;
    if (this.myCosmetics.pet) gear.pet = this.myCosmetics.pet;
    const key = JSON.stringify(gear);
    if (!force && key === this.lastGearSent) return;
    this.lastGearSent = key;
    if (this.realtime.connected) this.realtime.sendGear(gear);
  }

  private addRemote(p: RemotePlayer) {
    if (this.remotes.has(p.id) || p.id === this.selfId) return;
    const d = disciplineFor(p.classIndex);
    const avatar = new NecromancerAvatar(this.scene, d.color, false, d.modelSlug);
    avatar.setEquipment(gearFromIds(p.gear));
    const remote: Remote = { info: p, avatar, tx: p.x, tz: p.z, facing: p.facing, moving: false, hpFrac: p.hpFrac ?? 1 };
    this.remotes.set(p.id, remote);
    this.dressRemote(remote, p.gear);
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
    const lvl = this.skills.gateLevel(def.skill);
    const need = lvl < def.level ? `<div class="req missing">Requires ${SKILLS[def.skill].name} level ${def.level} · use ${SKILLS[def.skill].name === 'Woodcutting' ? 'Coffin-Oak near the entrance' : 'a beginner node near the entrance'}</div>` : `<div class="req ok">${SKILLS[def.skill].name} · level ${def.level}${def.level === 1 ? ' · Beginner' : ''}</div>`;
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
    this.gatherSession = new GatherSession(
      performance.now(),
      (id) => { const m = itemMeta(id); return { name: m.name, rarity: m.rarity, sell: m.sell }; },
      (skill) => this.skills.level(skill),
      (skill) => this.chronicle.view().life[`gathered.${skill}`] ?? 0,
    );
  }

  /** Work stopped: wait for the last batch to be saved, then show what the session brought back. */
  private endGatherSession(reason: string) {
    const session = this.gatherSession;
    if (!session) return;
    void Promise.resolve()
      .then(() => this.gathering.flush())
      .then(() => {
        if (this.gatherSession !== session || this.scope.isDisposed) return;
        this.gatherSession = null;
        const bests = loadBests(browserStorage(), this.character.id);
        const out = session.finish(performance.now(), reason, bests);
        if (!out) return;
        saveBests(browserStorage(), this.character.id, out.bests);
        this.closePanels();
        this.gatherReportPanel.show(out.report);
        audio.play(out.report.milestones.length ? 'skillUp' : 'coin');
      });
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
    this.gatherSession?.record(r);
    this.celebrateCharms(r.items);
    for (const g of r.items) this.inventory.add({ item_id: g.itemId, quantity: g.qty });
    this.chronicle.add(`gathered.${r.skill}`, r.items.reduce((n, g) => n + g.qty, 0));
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
      const opens = s === 'gardening' || s === 'alchemy' || s === 'salvaging' ? [] : nodesForSkill(s).filter((n) => n.level > before && n.level <= lvl);
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
    const skill = g.node ? NODES[g.node.type].skill : null;
    this.avatar.setGatheringTool(skill);
    this.nodeViews.selected(g.node);
    if (g.working && g.node && (prog < this.gatherProg || this.gatherProg === 0) && prog < 0.5) {
      const def = NODES[g.node.type];
      const cycleS = (def.ticks * 600) / 1000;
      const gesture = (skill === 'woodcutting' || skill === 'mining') && this.avatar.c.has('attack')
        ? 'attack' : SKILLS[def.skill].gesture;
      const gestureS = skill === 'fishing' ? Math.min(1.6, cycleS * 0.85) : Math.min(1.15, cycleS * 0.7);
      this.avatar.cast(gesture, 1, Math.atan2(g.node.x - this.player.x, g.node.z - this.player.z), gestureS);
    }
    this.gatherProg = g.working ? prog : 0;
    this.nodeViews.progress(this.player.x, this.player.z, g.working ? Math.max(0.02, prog) : 0, g.node ? SKILLS[NODES[g.node.type].skill].color : '#ffffff');
    this.nodeViews.update(dt);
    if (this.now - this.lastNodeSync > 1000) {
      this.lastNodeSync = this.now;
      for (const n of this.layout.nodes) this.nodeViews.setLive(n.id, this.nodeLive(n.id));
    }
  }

  /** Our body, or a remote caster's latest reported position (for effects that follow a caster). */
  private casterFollow(by: string, x: number, z: number) {
    const at = { x, z };
    return by === this.selfId
      ? () => (this.player.alive ? this.player : null)
      : () => {
          const r = this.remotes.get(by);
          if (!r) return null;
          at.x = r.tx;
          at.z = r.tz;
          return at;
        };
  }

  /** Veil Step: the furthest walkable point toward the goal in the current hall. */
  private dashTarget(tx: number, tz: number) {
    return veilTarget(this.nav, this.player.x, this.player.z, tx, tz);
  }

  /** Layer a Binbun effect through its preset (graphics/binbun/presets.ts). Never throws or waits. */
  /**
   * Waystones must read as "click me" from across the room (they used to blend into the stonework): a pulsing
   * teal ring on every quality level, the Binbun portal on High, and rising motes when you are near (update()).
   */
  private waystoneSpots: { x: number; z: number }[] = [];
  private dressWaystones() {
    this.waystoneSpots = AREA_ORDER.flatMap((a) => AREAS[a].interactables.filter((i) => i.kind === 'waystone'));
    for (const w of this.waystoneSpots) {
      this.effects.decal({ tex: fx.ring(), color: 0x6fe3c8, x: w.x, z: w.z, r: 1.7, duration: 1e9, opacity: 0.85, pulse: 1.2, persistent: true });
      this.effects.decal({ tex: fx.glow(), color: 0x1f8f86, x: w.x, z: w.z, r: 2.2, duration: 1e9, opacity: 0.5, persistent: true });
      this.bb('waystone_portal', w.x, w.z);
    }
  }

  private waystoneMotes(dt: number) {
    for (const w of this.waystoneSpots) {
      if (Math.abs(w.x - this.player.x) > 22 || Math.abs(w.z - this.player.z) > 22 || Math.random() > dt * 6) continue;
      const a = Math.random() * Math.PI * 2;
      this.effects.emit({ x: w.x + Math.sin(a) * 0.9, y: 0.2, z: w.z + Math.cos(a) * 0.9, count: 1, color: 0x9ff5e0, spread: 0.1, speed: 0.1, up: 1.6, life: 1.6, size: 0.22 });
    }
  }

  /** A camera jolt for a fire burst, fading with distance from the hero (so far-off pools never shake the screen). */
  private emberShake(x: number, z: number, amount: number) {
    const d = Math.hypot(x - this.player.x, z - this.player.z);
    if (d < 14) this.rig.shake(amount * (1 - d / 14));
  }

  /** The Cinder Pyre's dead go out in fire: a flare, sparks and soot (the Husk's pool burst is its own event). */
  private fireDeath(ev: Extract<SimEvent, { t: 'death' }>) {
    if (ev.def !== 'cinder_husk' && ev.def !== 'pyre_priest' && ev.def !== 'cinderhound' && ev.def !== 'slag_brute') return;
    const E = SPELL_FX.enemy;
    const big = ev.def === 'slag_brute';
    this.effects.emit({ x: ev.x, y: 0.9, z: ev.z, count: big ? 40 : 18, color: E.emberCore, spread: big ? 0.9 : 0.4, speed: big ? 4.5 : 3, up: big ? 3.4 : 2.4, life: 0.9, size: 0.13, gravity: 7 });
    this.effects.emitSmoke({ x: ev.x, y: 0.8, z: ev.z, count: big ? 6 : 3, color: E.emberDeep, spread: big ? 0.8 : 0.4, speed: 0.9, up: 0.9, life: 1.3, size: big ? 1.6 : 1, shrink: -0.6 });
    if (big) {
      this.bb('surge_eruption', ev.x, ev.z, { scale: 0.9, colors: [E.ember, E.emberCore, E.emberDeep] });
      this.effects.decal({ tex: fx.ring(), color: E.ember, x: ev.x, z: ev.z, r: 3.2, duration: 0.6, opacity: 0.9, growFrom: 0.2 });
      this.emberShake(ev.x, ev.z, 0.14);
    }
  }

  private bb(id: BinbunId, x: number, z: number, o: Omit<BinbunSpawn, 'x' | 'z'> = {}) {
    return playFx(this.effects.binbun, id, { x, z, ...o });
  }

  /** Effects that must land after a telegraph (processed in update, so QA stepping stays deterministic). */
  private fxLater: { at: number; run: () => void }[] = [];
  /** Looping auras tied to an entity (censer incense by enemy id, toxic stink by corpse id). */
  private auraFx = new Map<string, BinbunHandle>();

  /** Rite events that carry their caster: a remote necromancer makes the same weapon gesture we would (castClips.ts). */
  private static readonly REMOTE_GESTURE: Partial<Record<SimEvent['t'], AbilityId>> = {
    exhumed: 'exhume',
    litanyResult: 'black_litany',
    detonated: 'corpse_explosion',
    mantle: 'bone_mantle',
    offering: 'grave_offering',
    rend: 'command_rend',
    rally: 'rally_dead',
    seeded: 'carrion_seed',
  };

  private remoteGesture(ev: SimEvent) {
    const id = WorldScene.REMOTE_GESTURE[ev.t];
    const by = id && 'by' in ev ? ev.by : undefined;
    if (!id || !by || by === this.selfId) return;
    const r = this.remotes.get(by);
    if (!r) return;
    r.avatar.cast(id === 'exhume' || id === 'carrion_seed' ? 'dig' : 'cast', 2, r.facing, CAST_FLOW[id].gestureSeconds, id);
  }

  private handleEvent(ev: SimEvent) {
    this.views.onEvent(ev);
    this.remoteGesture(ev);
    const me = this.selfId;
    switch (ev.t) {
      case 'death':
        this.auraFx.get(`e${ev.id}`)?.kill();
        this.auraFx.delete(`e${ev.id}`);
        audio.play(ev.elite ? 'eliteDeath' : 'enemyDeath', ev.x, ev.z);
        this.worldView.addRipple(ev.x, ev.z, ev.elite ? 2 : 1.4);
        this.fireDeath(ev);
        this.onKill(ev);
        break;
      case 'hurt':
        if (ev.player === me) this.onHurt(ev.dmg, ev.from, ev.x, ev.z, ev.chillMs, ev.pull);
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
      case 'melee': {
        this.effects.emitSmoke({ x: ev.tx, y: 0.3, z: ev.tz, count: 2, color: 0x3a3340, spread: 0.3, speed: 0.8, up: 0.3, life: 0.5, size: 0.6 });
        // The Pyre's dead strike in a shower of sparks.
        const def = this.enemiesMap().get(ev.id)?.def;
        if (def === 'cinder_husk' || def === 'cinderhound' || def === 'slag_brute') {
          this.effects.emit({ x: ev.tx, y: 0.9, z: ev.tz, count: def === 'slag_brute' ? 12 : 7, color: SPELL_FX.enemy.emberCore, spread: 0.3, speed: 3, up: 1.6, life: 0.4, size: 0.1, gravity: 8 });
        }
        break;
      }
      case 'thrallHit': {
        audio.play('boneHit', ev.tx, ev.tz);
        const color = ev.kind === 'wraith' ? 0x8f9ed1 : ev.kind === 'bonemage' ? STATUS_FX.hex.amber : 0xd8cfbd;
        if (ev.kind === 'wraith' || ev.kind === 'bonemage') {
          this.effects.projectile({ from: { x: ev.x, y: 1.3, z: ev.z }, to: () => ({ x: ev.tx, y: 1, z: ev.tz }), kind: 'orb', color, speed: ev.kind === 'bonemage' ? 14 : 20 });
        } else if (ev.kind === 'archer') {
          this.effects.projectile({ from: { x: ev.x, y: 1.3, z: ev.z }, to: () => ({ x: ev.tx, y: 1, z: ev.tz }), kind: 'needle', color, speed: 26, arc: 0.6 });
        } else this.effects.emit({ x: ev.tx, y: 1, z: ev.tz, count: 3, color, spread: 0.2, speed: 2, up: 0.8, life: 0.3, size: 0.15, gravity: 5 });
        if (ev.kind === 'archer') this.bb('archer_flash', ev.x, ev.z);
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
          this.bb('rend_impact', tx, tz);
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
      case 'offering':
        this.abilities.onOffering(ev, ev.by === me, this.casterFollow(ev.by, ev.x, ev.z));
        if (ev.by === me && !ev.ok) this.floating.spawn(this.player.x, 2.4, this.player.z, 'The corpse is gone', 'info');
        break;
      case 'newBlood':
        if (ev.kind === 'heal' && ev.player === me && ev.amount) this.player.heal(this.player.stats.maxHp * ev.amount);
        this.abilities.onNewBlood(ev, ev.by === me);
        if (ev.by === me && !ev.ok) this.floating.spawn(this.player.x, 2.4, this.player.z, 'The target is gone', 'info');
        break;
      case 'rally':
        this.abilities.onRally(ev, this.casterFollow(ev.by, ev.x, ev.z));
        break;
      case 'seeded':
        this.abilities.onSeeded(ev);
        break;
      case 'seedGone':
        this.abilities.onSeedGone(ev.corpseId);
        break;
      case 'seedBurst':
        this.abilities.onSeedBurst(ev);
        break;
      case 'corpseGone':
        this.abilities.onSeedGone(ev.id);
        this.auraFx.get(`c${ev.id}`)?.kill();
        this.auraFx.delete(`c${ev.id}`);
        break;
      case 'thrall':
        if (Math.hypot(ev.x - this.player.x, ev.z - this.player.z) < 40) this.bb('thrall_rise', ev.x, ev.z);
        break;
      case 'heal':
        if (ev.player === me && this.player.alive) {
          const amount = ev.frac ? this.player.stats.maxHp * ev.frac : ev.amount;
          this.player.heal(amount);
          this.floating.spawn(this.player.x, 2.2, this.player.z, `+${Math.round(amount)}`, 'heal');
        }
        break;
      case 'burst':
        if (ev.kind !== 'ember') audio.play('burst', ev.x, ev.z);
        if (ev.kind === 'ember') {
          // A Cinder Husk's last embers (enemy fire, never the player's Miasma green or Corpse Explosion violet).
          const E = SPELL_FX.enemy;
          audio.play('emberBurst', ev.x, ev.z);
          this.bb('vengeful_burst', ev.x, ev.z, { scale: ev.r / 1.4, colors: [E.ember, E.emberCore, E.emberDeep] });
          this.emberShake(ev.x, ev.z, 0.05);
          this.effects.decal({ tex: fx.ring(), color: E.ember, x: ev.x, z: ev.z, r: ev.r, duration: 0.5, growFrom: 0.2, opacity: 1 });
          this.effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 26, color: E.emberCore, spread: ev.r * 0.5, speed: 3.2, up: 2.4, life: 0.9, size: 0.2, gravity: 5 });
          this.effects.emitSmoke({ x: ev.x, y: 0.4, z: ev.z, count: 6, color: E.emberDeep, spread: ev.r * 0.4, speed: 1.2, up: 0.9, life: 1.4, size: 1.5, shrink: -1 });
          break;
        }
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
            this.floating.spawn(this.player.x, 2.2, this.player.z, `+${Math.round(amt)}`, 'heal');
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
      case 'bossBusy':
        // The host refused our summon (another boss woke first): refund the shards we spent.
        if (ev.by === this.selfId) {
          if (ev.boss === 'prelate') this.progression.addShards(BOSSES.prelate.shards);
          else this.progression.refundBossShards(ev.boss);
          this.hud.toast(`${BOSSES[ev.awake].name} already stirs in ${AREAS[BOSSES[ev.awake].area].name}. Your shards are returned.`, 'err');
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
        else if (ev.affix === 'bellTolled') this.bb('bell_toll_ring', ev.x, ev.z, { scale: (ev.r ?? 3) / 3 });
        else if (ev.affix === 'vengeful') this.bb('vengeful_burst', ev.x, ev.z);
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
          this.bb('enemy_breach_rim', ev.x, ev.z);
          // Introduce a themed wave once per area. At high Wave Speed, repeated
          // processions otherwise cover combat with the same banner every few seconds.
          const theme = ev.theme ? WAVE_THEMES[ev.area]?.find((t) => t.id === ev.theme) : undefined;
          if (theme && !this.announcedProcessions.has(ev.area)) {
            this.announcedProcessions.add(ev.area);
            this.hud.banner(theme.name, theme.blurb, 2600);
            audio.play('tollSmall', ev.x, ev.z);
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
        if (ev.def === 'censer') {
          const id = ev.id;
          const follow = () => {
            const e = this.enemiesMap().get(id);
            return e && e.state !== 'dead' ? { x: e.x, z: e.z } : null;
          };
          this.auraFx.set(`e${id}`, this.bb('censer_incense', ev.x, ev.z, { follow }));
        }
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
        if (ev.corpse.kind === 'toxic') this.auraFx.set(`c${ev.corpse.id}`, this.bb('toxic_stink', ev.corpse.x, ev.corpse.z));
        break;
    }
  }

  /** Records a Codex discovery without a second alert over combat. */
  private codexDiscover<K extends CodexKind>(kind: K, id: CodexIds[K]) {
    this.codex.discover(kind, id);
  }

  /** Throttled onboarding triggers that depend on state rather than events. */
  private tickOnboarding(now: number) {
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
    if (this.discipline.family === 'necromancer' && mine + corpsesNear >= 4 && this.character.level >= 2) this.onboarding.show('litany');
    if (this.discipline.family === 'necromancer' && packOnCorpse && this.progression.local.totalKills >= 15) this.onboarding.show('burst');
    if (this.progression.local.totalKills >= 40) this.onboarding.show('codex');
    if (this.inventory.all.some((s) => s.item_id.startsWith('tool_'))) this.onboarding.show('tool');
    if (this.progression.local.shards >= BOSS_SUMMON_SHARDS) this.onboarding.show('prelate');
    // Area bosses: counsel the first time a summon object is within 12 m.
    for (const id of ['gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire'] as BossId[]) {
      const it = AREAS[BOSSES[id].area].interactables.find((i) => i.id === BOSSES[id].summonId);
      if (it && this.player.area === BOSSES[id].area && Math.hypot(it.x - this.player.x, it.z - this.player.z) < 12) this.onboarding.show(`boss_${id}` as TipId);
    }
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
    } else if (ev.kind === 'slam' && this.enemiesMap().get(ev.id)?.def === 'slag_brute') {
      // Slag Brute: a molten ring fills as the fist rises; it lands with a shockwave, a heat flash and a heavy shake.
      const r = ev.r ?? 2.7;
      const E = SPELL_FX.enemy;
      this.effects.decal({ tex: fx.disc(), color: E.emberDeep, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.7, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.4 });
      this.effects.decal({ tex: fx.ring(), color: E.ember, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.95, fadeOut: 0.05 });
      this.effects.decal({ tex: fx.cracks(), color: E.emberCore, x: ev.tx, z: ev.tz, r: r * 0.9, rot: Math.random() * 6, duration: ms, opacity: 0.6, fadeIn: ms * 0.8, fadeOut: 0.05 });
      this.fxLater.push({ at: this.now + ev.ms, run: () => {
        this.effects.decal({ tex: fx.ring(), color: E.emberCore, x: ev.tx, z: ev.tz, r: r * 1.35, duration: 0.5, opacity: 1, growFrom: 0.3 });
        this.effects.decal({ tex: fx.cracks(), color: E.ember, x: ev.tx, z: ev.tz, r: r * 0.95, rot: Math.random() * 6, duration: 1.6, opacity: 0.85, growFrom: 0.5 });
        this.bb('surge_eruption', ev.tx, ev.tz, { scale: r / 2, colors: [E.ember, E.emberCore, E.emberDeep] });
        this.effects.emit({ x: ev.tx, y: 0.3, z: ev.tz, count: 34, color: E.emberCore, spread: r * 0.5, speed: 4.5, up: 3.2, life: 0.8, size: 0.14, gravity: 9 });
        this.effects.emitSmoke({ x: ev.tx, y: 0.3, z: ev.tz, count: 6, color: E.emberDeep, spread: r * 0.5, speed: 1.6, up: 0.7, life: 1.1, size: 1.4 });
        audio.play('slagSlam', ev.tx, ev.tz);
        this.emberShake(ev.tx, ev.tz, 0.2);
      } });
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
      this.fxLater.push({ at: this.now + ev.ms, run: () => this.bb('choir_scream', ev.tx, ev.tz, { scale: r / 2.2 }) });
    } else if (ev.kind === 'dive') {
      // Belfry Gargoyle: a bronze mark fills in under the target; the stone lands when it's full.
      const r = ev.r ?? 2;
      const E = SPELL_FX.enemy;
      // Kept low: the bronze disc is additive and blooms hard; the ring carries the read.
      this.effects.decal({ tex: fx.disc(), color: E.dive, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.22, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.3 });
      this.effects.decal({ tex: fx.ring(), color: E.dive, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.7, fadeOut: 0.05 });
      this.effects.decal({ tex: fx.cracks(), color: E.slam, x: ev.tx, z: ev.tz, r: r * 0.95, rot: Math.random() * 6, duration: 1.4, opacity: 0.8, growFrom: 0.5, delay: ms });
      this.fxLater.push({ at: this.now + ev.ms, run: () => {
        this.effects.emitSmoke({ x: ev.tx, y: 0.3, z: ev.tz, count: 5, color: 0x3b3440, spread: r * 0.45, speed: 1.3, up: 0.5, life: 0.8, size: 1.1 });
        this.effects.emit({ x: ev.tx, y: 0.3, z: ev.tz, count: 14, color: 0x8a8378, spread: r * 0.4, speed: 2.4, up: 2, life: 0.6, size: 0.14, gravity: 9 });
        audio.play('boneHit', ev.tx, ev.tz);
        this.rig.shake(0.08);
      } });
    } else if (ev.kind === 'erupt') {
      // Barrow Ghoul: the ground cracks open in a dirt-brown ring; it breaks out when the ring fills.
      const r = ev.r ?? 1.8;
      const dirt = SPELL_FX.enemy.dirt;
      this.effects.decal({ tex: fx.disc(), color: dirt, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.45, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.2 });
      this.effects.decal({ tex: fx.ring(), color: 0xa07a50, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.85, fadeOut: 0.05 });
      this.effects.decal({ tex: fx.cracks(), color: dirt, x: ev.tx, z: ev.tz, r: r * 0.9, rot: Math.random() * 6, duration: ms, opacity: 0.7, growFrom: 0.2, fadeOut: 0.05 });
    } else if (ev.kind === 'flask') {
      // Plague Doctor: a rot-green ring where the flask will land (enemy rot, never the player's Miasma).
      const r = ev.r ?? 1.8;
      const rot = SPELL_FX.enemy.toxic;
      this.effects.decal({ tex: fx.disc(), color: rot, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.45, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.25 });
      this.effects.decal({ tex: fx.ring(), color: SPELL_FX.enemy.rot, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.9, fadeOut: 0.05 });
      this.effects.projectile({ from: { x: ev.x, y: 1.6, z: ev.z }, to: () => ({ x: ev.tx, y: 0.3, z: ev.tz }), kind: 'orb', color: rot, speed: Math.max(4, Math.hypot(ev.tx - ev.x, ev.tz - ev.z) / Math.max(0.2, ms)), arc: 30 });
    } else if (ev.kind === 'ember') {
      // Pyre Priest: an ember-orange ring where the coal will land.
      const r = ev.r ?? 1.7;
      const E = SPELL_FX.enemy;
      this.effects.decal({ tex: fx.disc(), color: E.ember, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.45, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.25 });
      this.effects.decal({ tex: fx.ring(), color: E.emberCore, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.9, fadeOut: 0.05 });
      this.effects.projectile({ from: { x: ev.x, y: 1.6, z: ev.z }, to: () => ({ x: ev.tx, y: 0.3, z: ev.tz }), kind: 'orb', color: E.ember, speed: Math.max(4, Math.hypot(ev.tx - ev.x, ev.tz - ev.z) / Math.max(0.2, ms)), arc: 30 });
      audio.play('emberThrow', ev.x, ev.z);
      // The coal lands as the windup ends: a flare, a burst of sparks and a jolt if you are near.
      this.fxLater.push({ at: this.now + ev.ms, run: () => {
        this.bb('vengeful_burst', ev.tx, ev.tz, { scale: r / 1.4, colors: [E.ember, E.emberCore, E.emberDeep] });
        this.effects.emit({ x: ev.tx, y: 0.4, z: ev.tz, count: 16, color: E.emberCore, spread: r * 0.4, speed: 3, up: 2.6, life: 0.7, size: 0.13, gravity: 8 });
        audio.play('emberBurst', ev.tx, ev.tz);
        this.emberShake(ev.tx, ev.tz, 0.06);
      } });
    } else if (ev.kind === 'dust') {
      // Shroud Moth: dust sifts down from the wings onto a ring; the cloud (a zone) follows the burst.
      const r = ev.r ?? 2;
      const E = SPELL_FX.enemy;
      this.effects.decal({ tex: fx.disc(), color: E.dust, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.4, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.25 });
      this.effects.decal({ tex: fx.ring(), color: E.dust, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.85, fadeOut: 0.05 });
      this.effects.emit({ x: ev.x, y: 1.4, z: ev.z, count: 10, color: E.dust, spread: 0.6, speed: 0.4, up: -0.6, life: ms, size: 0.16, drag: 0.6 });
    } else if (ev.kind === 'raise') {
      const from = { x: ev.x, y: 1.8, z: ev.z };
      this.effects.beam(from, () => ({ x: ev.tx, y: 0.3, z: ev.tz }), SPELL_FX.enemy.rot, 0.05, ms);
      this.effects.decal({ tex: fx.sigil(), color: SPELL_FX.enemy.rot, x: ev.tx, z: ev.tz, r: 1, duration: ms, opacity: 0.8, spin: 3 });
    } else if (ev.kind === 'hex') {
      // Bog Hag: a sickly magenta ring on the knot of thralls she will curse, and a thread from her to it.
      const r = ev.r ?? HAG_HEX.radius;
      const H = SPELL_FX.enemy.hex;
      this.effects.decal({ tex: fx.disc(), color: H, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.38, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.3 });
      this.effects.decal({ tex: fx.ring(), color: H, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.95, fadeOut: 0.05, pulse: 3 });
      this.effects.decal({ tex: fx.sigil(), color: H, x: ev.tx, z: ev.tz, r: r * 0.8, duration: ms, opacity: 0.7, spin: 1.8, fadeOut: 0.05 });
      this.effects.beam({ x: ev.x, y: 1.9, z: ev.z }, () => ({ x: ev.tx, y: 0.5, z: ev.tz }), H, 0.04, ms);
      this.fxLater.push({ at: this.now + ev.ms, run: () => {
        this.effects.decal({ tex: fx.ring(), color: H, x: ev.tx, z: ev.tz, r: r * 1.25, duration: 0.5, opacity: 1, growFrom: 0.3 });
        this.effects.emit({ x: ev.tx, y: 0.8, z: ev.tz, count: 26, color: H, spread: r * 0.45, speed: 1.4, up: 2.2, life: 0.9, size: 0.2 });
        audio.play('curse', ev.tx, ev.tz);
      } });
    } else if (ev.kind === 'pulse') {
      // Fen Wisp: a cold teal ring where you stand, ripples spreading on the water.
      const r = ev.r ?? 2.3;
      const W = 0x7fe0d0;
      this.effects.decal({ tex: fx.disc(), color: W, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.3, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.3 });
      this.effects.decal({ tex: fx.ring(), color: W, x: ev.tx, z: ev.tz, r, duration: ms, opacity: 0.9, fadeOut: 0.05, pulse: 4 });
      this.fxLater.push({ at: this.now + ev.ms, run: () => {
        this.effects.decal({ tex: fx.ring(), color: 0xeaffff, x: ev.tx, z: ev.tz, r: r * 1.2, duration: 0.45, opacity: 1, growFrom: 0.3 });
        this.effects.emit({ x: ev.tx, y: 0.4, z: ev.tz, count: 18, color: W, spread: r * 0.4, speed: 1.6, up: 1.8, life: 0.8, size: 0.16 });
        this.worldView.addRipple(ev.tx, ev.tz, 2);
      } });
    } else if (ev.kind === 'hook') {
      // Drowned Sexton: a rust-brown line along the chain's path, to its full reach.
      const dx = ev.tx - ev.x;
      const dz = ev.tz - ev.z;
      const dir = Math.atan2(dx, dz);
      const len = ev.r ?? SEXTON_HOOK.range;
      const hx = ev.x + Math.sin(dir) * len * 0.5;
      const hz = ev.z + Math.cos(dir) * len * 0.5;
      this.effects.decal({ tex: fx.disc(), color: 0xa8743a, x: hx, z: hz, r: len / 2, sz: 1, sx: (SEXTON_HOOK.halfWidth * 2) / len, rot: dir + Math.PI, duration: ms, opacity: 0.55, fadeIn: ms * 0.7, fadeOut: 0.05 });
      this.effects.decal({ tex: fx.ring(), color: 0xe0a458, x: ev.x + Math.sin(dir) * len, z: ev.z + Math.cos(dir) * len, r: 0.9, duration: ms, opacity: 0.8, fadeOut: 0.05 });
      audio.play('boneHit', ev.x, ev.z);
    } else if (ev.kind === 'curse') {
      this.effects.decal({ tex: fx.ring(), color: SPELL_FX.enemy.curse, x: ev.tx, z: ev.tz, r: 1.2, duration: ms, opacity: 0.85, growFrom: 2 });
      this.effects.decal({ tex: fx.glow(), color: SPELL_FX.enemy.curse, x: ev.tx, z: ev.tz, r: 1.4, duration: 0.3, opacity: 0.9, delay: ms });
    }
  }

  private zoneVisual(z: Zone) {
    this.zoneFx.get(z.id)?.forEach((h) => h.kill());
    const dur = Math.max(0.1, z.until - (this.sim?.time ?? this.mirror?.time ?? 0));
    if (z.kind === 'warden_fire' || z.kind === 'warden_ward' || z.kind === 'witch_crows' || z.kind === 'witch_charm' || z.kind === 'veil_rift') {
      const color = z.kind === 'warden_fire' ? 0xff822d : z.kind === 'warden_ward' ? SPELL_FX.warden.gold
        : z.kind === 'witch_crows' ? SPELL_FX.witch.blood : z.kind === 'witch_charm' ? 0xcc4499 : SPELL_FX.veilwalker.cyan;
      const glyph = z.kind === 'warden_fire' ? fx.cracks() : z.kind === 'witch_charm' ? fx.glow() : fx.sigil();
      this.zoneFx.set(z.id, [
        this.effects.decal({ tex: fx.disc(), color, x: z.x, z: z.z, r: z.r, duration: dur, opacity: z.kind === 'witch_charm' ? 0.32 : 0.4, growFrom: 0.3, fadeOut: 0.35 }),
        this.effects.decal({ tex: glyph, color, x: z.x, z: z.z, r: z.r, duration: dur, opacity: 0.72, pulse: z.kind === 'warden_fire' ? 4 : 2, fadeOut: 0.35 }),
      ]);
      return;
    }
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
      this.bb(dirge ? 'dirge_area' : 'plague_bloom_area', z.x, z.z, { scale: dirge ? z.r / 6 : z.r / 2.4 });
      return;
    }
    if (z.kind === 'dust') {
      // Shroud Moth cloud: a low ochre haze, a few slow puffs (cheap: two decals + one burst of smoke).
      const E = SPELL_FX.enemy;
      this.zoneFx.set(z.id, [
        this.effects.decal({ tex: fx.disc(), color: E.dustDeep, x: z.x, z: z.z, r: z.r, duration: dur, opacity: 0.55, growFrom: 0.4, fadeOut: 0.6 }),
        this.effects.decal({ tex: fx.glow(), color: E.dust, x: z.x, z: z.z, r: z.r * 1.05, duration: dur, opacity: 0.35, pulse: 1.5, fadeOut: 0.6 }),
      ]);
      this.effects.emitSmoke({ x: z.x, y: 0.5, z: z.z, count: 6, color: E.dust, spread: z.r * 0.5, speed: 0.4, up: 0.35, life: Math.min(dur, 3), size: 1.5, shrink: -0.6 });
      return;
    }
    if (z.kind === 'ember') {
      // Burning ground: an orange disc over glowing cracks, with sparks rising off it (see the ambient pass below).
      const E = SPELL_FX.enemy;
      this.zoneFx.set(z.id, [
        this.effects.decal({ tex: fx.disc(), color: E.emberDeep, x: z.x, z: z.z, r: z.r, duration: dur, opacity: 0.6, growFrom: 0.3, fadeOut: 0.6 }),
        this.effects.decal({ tex: fx.cracks(), color: E.ember, x: z.x, z: z.z, r: z.r * 0.95, duration: dur, opacity: 0.75, pulse: 2.5, fadeOut: 0.6 }),
        this.effects.decal({ tex: fx.glow(), color: E.ember, x: z.x, z: z.z, r: z.r * 1.05, duration: dur, opacity: 0.3, pulse: 1.5, fadeOut: 0.6 }),
        this.bb('bonfire', z.x, z.z, { scale: z.r / 2.2, duration: dur, alpha: 0.85 }),
      ]);
      return;
    }
    const color = z.kind === 'toxic' ? SPELL_FX.enemy.toxic : SPELL_FX.miasma.deep;
    // Toxic (hostile) and rot (a detonated sac, now yours) pools are cracked ground; miasma is a sigil.
    const pool = z.kind === 'toxic' || z.kind === 'rot';
    const handles = [
      this.effects.decal({ tex: fx.disc(), color, x: z.x, z: z.z, r: z.r, duration: dur, opacity: z.kind === 'toxic' ? 0.5 : 0.66, growFrom: 0.3, fadeOut: 0.6 }),
      this.effects.decal({ tex: pool ? fx.cracks() : fx.sigil(), color: z.kind === 'toxic' ? SPELL_FX.enemy.rot : SPELL_FX.miasma.rot, x: z.x, z: z.z, r: z.r * 0.95, duration: dur, opacity: 0.22, spin: pool ? 0 : 0.6, fadeOut: 0.6 }),
    ];
    if (pool) handles.push(this.bb('toxic_puddle', z.x, z.z, { scale: z.r / 2.6, duration: dur, colors: z.kind === 'toxic' ? [SPELL_FX.enemy.toxic, SPELL_FX.enemy.rot, 0x1a2010] : undefined }));
    this.zoneFx.set(z.id, handles);
  }

  private syncEchoVisuals() {
    const visible = this.discipline.family === 'veil' && (this.player.veilForm || this.now < this.player.betweenUntil);
    const corpses = this.sim?.corpses ?? this.mirror?.corpses;
    for (const [id, handle] of this.echoFx) {
      if (visible && corpses?.get(id)?.echoOwner) continue;
      handle.kill(); this.echoFx.delete(id);
    }
    if (!visible || !corpses) return;
    for (const c of corpses.values()) {
      if (!c.echoOwner || this.echoFx.has(c.id)) continue;
      this.echoFx.set(c.id, this.effects.decal({ tex: fx.sigil(), color: SPELL_FX.veilwalker.cyan,
        x: c.x, z: c.z, r: 0.8, duration: Math.max(0.1, c.expiresAt - (this.sim?.time ?? this.mirror?.time ?? 0)),
        opacity: 0.8, pulse: 3, fadeOut: 0.2 }));
    }
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
    this.bb('surge_eruption', ev.x, ev.z);
    this.bb('crypt_mist', ev.x, ev.z, { duration: Math.min(ms, 20) });
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
    // A boss's skull niche is part of the fight, not a kill: no souls, loot, XP or area progress.
    if (ENEMIES[ev.def].inert) return;
    // Soul Harvest: kills credited to you (thralls and DoTs credit their owner).
    if (ev.killer === this.selfId && this.player.alive && this.player.addSouls(1 + this.abilities.reapedSouls(ev.id))) this.onSoulsCharged();
    // Personal rewards for kills in (or right next to) your area.
    const near = Math.hypot(ev.x - this.player.x, ev.z - this.player.z) < 38;
    if (!this.player.alive || !near) return;
    const reward = rollKill(ev.def, ev.area, ev.level, ev.elite, this.bossWaveTier(), Math.random, this.worldDifficulty(), 1 + this.player.brewValue('fortune', this.now));
    // The chain: your own kills (thralls and DoTs credit their owner) in unsafe ground, each within the window of the last.
    let chainMult = 1;
    if (ev.killer === this.selfId && !AREAS[ev.area].safe) {
      const up = this.chain.hit(this.now);
      chainMult = this.chain.mult;
      this.hud.pulseChain();
      if (up) this.onChainTier(up.name, up.bonus, ev.x, ev.z);
    }
    // The week's Omen pays a little extra on every kill, and doubles or more the shards elites drop.
    const combatArea = !AREAS[ev.area].safe;
    const asc = ascensionRewardMult(this.worldAscension()) * chainMult * (combatArea ? this.omen.rewardMult : 1);
    if (reward.shards && combatArea) reward.shards = Math.ceil(reward.shards * this.omen.shardMult);
    reward.gold = Math.round(reward.gold * asc);
    // Tonic of wisdom: a share more experience from every kill.
    reward.xp = Math.round(reward.xp * asc * (1 + this.player.brewValue('wisdom', this.now)));
    this.loot.gold(ev.x, ev.z, reward.gold);
    if (reward.shards) this.loot.shard(ev.x, ev.z, reward.shards);
    for (const item of reward.items) this.loot.item(ev.x, ev.z, item);
    this.gainXp(reward.xp, ev.x, ev.z);
    this.progression.recordKill(ev.area, this.bossWaveTier());
    this.checkUnlocks();
    this.checkMilestones();
  }

  /** A new chain tier: a floating call-out, a chime that climbs with the tier, and a flash of the tier colour. */
  private onChainTier(name: string, bonus: number, x: number, z: number) {
    const idx = CHAIN.tiers.findIndex((t) => t.name === name);
    audio.play('chainTier', this.player.x, this.player.z, 1);
    this.floating.spawn(this.player.x, 3, this.player.z, `${name.toUpperCase()}  +${Math.round(bonus * 100)}%`, 'big');
    const col = [0xe6d3a0, 0xf0b25a, 0xf08a3a, 0xee5a2a, 0xff3a3a][Math.max(0, idx)];
    this.effects.emit({ x: this.player.x, y: 1, z: this.player.z, count: 20 + idx * 8, color: col, spread: 0.5, speed: 3 + idx * 0.6, up: 2.4, life: 0.8, size: 0.16, gravity: 3 });
    this.effects.decal({ tex: fx.ring(), color: col, x: this.player.x, z: this.player.z, r: 2 + idx * 0.5, duration: 0.5, opacity: 0.9, growFrom: 0.3 });
    if (idx >= 2) this.rig.shake(0.08 + idx * 0.02);
    if (!this.chainTold) {
      this.chainTold = true;
      this.onboarding.show('chain', 400);
    }
    void x;
    void z;
  }

  private static readonly CHAIN_BEST_KEY = 'dm_chain_best_';
  private static readonly MILESTONE_KEY = 'dm_milestones_';

  /** Pays any newly reached milestone once per character (claims live in this browser). */
  private checkMilestones() {
    const store = browserStorage();
    let claimed = new Set<string>();
    let bestStored = 0;
    try {
      claimed = new Set<string>(JSON.parse(store?.getItem(WorldScene.MILESTONE_KEY + this.character.id) ?? '[]'));
      bestStored = Number(store?.getItem(WorldScene.CHAIN_BEST_KEY + this.character.id) ?? 0) || 0;
    } catch { /* unreadable storage: nothing is claimed this session */ }
    const bestChain = Math.max(bestStored, this.chain.best);
    const hit = newlyReached({ totalKills: this.progression.local.totalKills, areaKills: this.progression.local.areaKills, bestChain }, claimed);
    try {
      if (bestChain > bestStored) store?.setItem(WorldScene.CHAIN_BEST_KEY + this.character.id, String(bestChain));
    } catch { /* ignore */ }
    if (!hit.length) return;
    for (const m of hit) {
      claimed.add(m.id);
      this.loot.gold(this.player.x, this.player.z, m.gold);
      this.hud.toast(`Milestone: ${m.title}. ${m.text} (+${m.gold} gold)`, 'good');
      audio.play('skillUp');
    }
    try {
      store?.setItem(WorldScene.MILESTONE_KEY + this.character.id, JSON.stringify([...claimed]));
    } catch { /* ignore */ }
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
    this.nav.setUnlocked(this.openAreas());
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
    this.nav.setUnlocked(this.openAreas());
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
        thrallCap: base.mods.thrallCap + fx.extraThralls + this.weaponThrallBonus,
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
      this.chronicle.max('peak.level', this.character.level);
      this.refreshStats();
      this.player.hp = this.player.stats.maxHp;
      this.player.resource.value = this.player.resource.max;
      this.hud.banner(`Level ${this.character.level}`, 'The dead answer you more readily', 2600);
      if (this.character.level >= SIGNATURE_LEVEL) this.onboarding.show('signature', 3000);
      const learned = [...this.kit.primaries, ...this.kit.grimoire].filter((id) => unlockLevel(id) > this.character.level - gained && unlockLevel(id) <= this.character.level);
      if (learned.length) {
        const shown = learned.slice(0, 3).map((id) => ABILITIES[id].name);
        const names = learned.length > 3 ? `${shown.join(', ')} and ${learned.length - 3} more` : shown.join(', ');
        this.hud.toast(`${names} ${learned.length > 1 ? 'join' : 'joins'} your Grimoire. Click here, press L or use the Grimoire button to place it.`, 'good', () => this.openGrimoire());
        this.grimoirePanel.render();
        this.markSeen([]);
        this.hud.pulseGrimoire();
      }
      if (this.grimoireUnlocked()) this.onboarding.show('grimoire', 3200);
      audio.play('levelUp');
      this.effects.emit({ x: this.player.x, y: 0.2, z: this.player.z, count: 90, color: 0xf1d9a8, spread: 0.8, speed: 0.8, up: 5, life: 1.5, size: 0.35 });
      this.effects.decal({ tex: fx.sigil(), color: 0xe2c98f, x: this.player.x, z: this.player.z, r: 2.4, duration: 1.8, opacity: 1, growFrom: 0.2, spin: 1.2 });
      this.effects.lightFlash(this.player.x, 2, this.player.z, 0xf1d9a8, 50, 1);
      this.bb('levelup_pillar', this.player.x, this.player.z);
    }
  }

  private checkUnlocks() {
    for (const id of AREA_ORDER) {
      const u = AREAS[id].unlock;
      if (!u || this.progression.isUnlocked(id)) continue;
      if (this.progression.kills(u.area) >= this.progression.unlockKills(u.kills) && this.progression.unlock(id)) {
        this.nav.setUnlocked(this.openAreas());
        for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d));
        const door = DOORS.find((d) => d.b === id);
        this.hud.banner('A seal breaks', `${AREAS[id].name} lies open${door ? ` · ${doorDirection(door)}` : ''}`, 4800);
        if (door) audio.play('gate', (door.rect.x0 + door.rect.x1) / 2, (door.rect.z0 + door.rect.z1) / 2);
        this.rig.shake(0.3);
        void this.progression.flush();
      }
    }
  }

  private onHurt(raw: number, from: string, x: number, z: number, chillMs?: number, pull?: { x: number; z: number; m: number; rootMs: number }) {
    if (!this.player.alive) return;
    const myThralls = [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId).length;
    const lanternWard = [...(this.sim?.zones ?? this.mirror?.zones ?? new Map()).values()].some((zone) => zone.kind === 'warden_ward' && Math.hypot(zone.x - this.player.x, zone.z - this.player.z) <= zone.r) ? 0.2 : 0;
    // Easy auto softens hits between the Knight's blocks and the Veilwalker's phases.
    const autoGuard = canUseAutoCombat() && settings.autoCombat && (this.discipline.family === 'knight' || this.discipline.family === 'veil') ? 0.3 : 0;
    // Elixir wards and fire/rot resists (brews); Player.takeDamage caps the whole sum at 60%.
    const flaskWard = brewWard(this.player.brews, from, this.now);
    const ward = this.discipline.mods.wardPerThrall * myThralls + lanternWard + autoGuard + flaskWard;
    const now = this.now;
    // The blow's origin lets Bulwark decide whether it covered this one.
    const taken = this.player.takeDamage(raw, ward, now, { x, z }, from);
    if (chillMs && taken > 0 && this.player.alive) {
      this.player.chilledUntil = Math.max(this.player.chilledUntil, now + chillMs);
      this.floating.spawn(this.player.x, 2.5, this.player.z, 'Chilled', 'info');
    }
    if (pull && taken > 0 && this.player.alive) this.dragPlayer(pull);
    if (this.player.lastBlock !== 'none') this.onBulwarkBlock(raw, x, z);
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
    if (from === 'ember' || from === 'burn') {
      // Scorched: sparks spray off the hero and the hit thumps a little harder than plain damage.
      const E = SPELL_FX.enemy;
      this.effects.emit({ x: this.player.x, y: 1, z: this.player.z, count: 14, color: E.emberCore, spread: 0.35, speed: 2.6, up: 1.8, life: 0.5, size: 0.12, gravity: 7 });
      this.effects.emit({ x: this.player.x, y: 1.2, z: this.player.z, count: 4, color: E.ember, spread: 0.3, speed: 1, up: 1.4, life: 0.7, size: 0.22 });
      this.rig.shake(0.16);
    }
    if (from === 'toll' && this.player.alive) {
      // Bell-Tolled ring: a brief stun.
      this.player.rootedUntil = Math.max(this.player.rootedUntil, now + AFFIX_TUNING.bellTolled.stunMs);
      this.floating.spawn(this.player.x, 2.5, this.player.z, 'Stunned', 'info');
      this.effects.emit({ x: this.player.x, y: 1.8, z: this.player.z, count: 12, color: SPELL_FX.affix.bell, spread: 0.3, speed: 1.2, up: 0.4, life: 0.5, size: 0.2 });
    }
    if (!this.player.alive) this.onDeath();
  }

  /** The Drowned Sexton's chain: drag the hero `m` metres toward the hook (never into him), a chain of splashes along the way. */
  private dragPlayer(pull: { x: number; z: number; m: number; rootMs: number }) {
    const p = this.player;
    const d = Math.hypot(pull.x - p.x, pull.z - p.z);
    const m = Math.min(pull.m, Math.max(0, d - 1.6));
    if (m <= 0.05) return;
    const from = { x: p.x, z: p.z };
    const [nx, nz] = this.nav.resolve(p.x + ((pull.x - p.x) / d) * m, p.z + ((pull.z - p.z) / d) * m, 0.45);
    p.x = nx;
    p.z = nz;
    p.stop();
    p.rootedUntil = Math.max(p.rootedUntil, this.now + pull.rootMs);
    this.effects.beam({ x: pull.x, y: 1.3, z: pull.z }, () => ({ x: p.x, y: 1.1, z: p.z }), 0x7a6a58, 0.05, 0.35);
    for (let k = 0; k <= 4; k++) this.worldView.addRipple(from.x + (nx - from.x) * (k / 4), from.z + (nz - from.z) * (k / 4), 1.2);
    this.floating.spawn(p.x, 2.5, p.z, 'Dragged!', 'info');
    this.rig.shake(0.2);
  }

  /**
   * Bulwark answered a blow. A perfect block (inside the opening window) reflects
   * half of the raw damage at whatever struck — the Rage is paid in takeDamage.
   */
  private onBulwarkBlock(raw: number, x: number, z: number) {
    const perfect = this.player.lastBlock === 'perfect';
    this.floating.spawn(this.player.x, 2.5, this.player.z, perfect ? 'Perfect block' : 'Blocked', 'info');
    this.effects.decal({ tex: fx.ring(), color: SPELL_FX.knight.steel, x: this.player.x, z: this.player.z, r: perfect ? 1.5 : 1.1, duration: 0.3, opacity: perfect ? 1 : 0.6, growFrom: 0.5 });
    if (!perfect) return;
    this.effects.lightFlash(this.player.x, 1.2, this.player.z, SPELL_FX.knight.pale, 16, 0.2);
    audio.play('shard', this.player.x, this.player.z, 1.4);
    // Reflect at the nearest body to the blow's origin; a cone or toll with no
    // single owner simply reflects nothing.
    let best: { id: number; d: number } | null = null;
    for (const e of this.enemiesMap().values()) {
      if (e.state === 'dead') continue;
      const d = Math.hypot(e.x - x, e.z - z);
      if (d <= 1.5 + e.radius && (!best || d < best.d)) best = { id: e.id, d };
    }
    if (best) this.sendIntent({ t: 'hit', by: this.selfId, ids: [best.id], dmg: raw * BULWARK.reflect });
  }

  private onDeath() {
    this.chain.reset();
    this.gathering.stop('dead');
    this.deadUntil = this.now + RESPAWN_MS;
    this.attackTarget = null;
    this.avatar.c.playOnce('death', 1);
    audio.play('playerDeath');
    this.chronicle.add('deaths');
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

  /** The nave pews' boxes: the Drowned Congregation's Flood Hymn can't reach behind them. Same maths as WorldView's colliders. */
  private pewCover() {
    return this.layout.props
      .filter((p) => p.prop === 'church_pew' && p.area === 'nave')
      .map((p) => {
        const c = PROPS.church_pew.collider as { hw: number; hd: number };
        const cos = Math.abs(Math.cos(p.rot));
        const sin = Math.abs(Math.sin(p.rot));
        const hw = (c.hw * cos + c.hd * sin) * p.scale;
        const hd = (c.hw * sin + c.hd * cos) * p.scale;
        return { x0: p.x - hw, z0: p.z - hd, x1: p.x + hw, z1: p.z + hd };
      });
  }

  private bossView(id: BossId): BossView {
    let v = this.bossViews.get(id);
    if (!v) {
      v = new BossView(this.scene, this.effects, BOSSES[id].modelSlug, BOSSES[id].color);
      this.bossViews.set(id, v);
    }
    return v;
  }

  /** First kill of an area boss by this character? Recorded in browser storage (no new server fields). */
  private claimTrophy(id: BossId): boolean {
    const key = `${import.meta.env.VITE_OFFLINE_BUILD === '1' ? 'dm_offline_' : ''}dm_boss_trophies_v1:${this.character.id}`;
    try {
      const got: string[] = JSON.parse(localStorage.getItem(key) ?? '[]');
      if (got.includes(id)) return false;
      localStorage.setItem(key, JSON.stringify([...got, id]));
      return true;
    } catch {
      return false;
    }
  }

  /** Area-boss telegraphs (ms > 0) and impacts (ms = 0). Enemy colour language only. */
  private areaBossEvent(ev: Extract<SimEvent, { t: 'boss' }>, ms: number) {
    const def = BOSSES[ev.boss ?? 'prelate'];
    const dirt = SPELL_FX.enemy.dirt;
    const curse = SPELL_FX.enemy.curse;
    const tide = 0x5f8f8a;
    const cone = (r: number, dir: number, halfDeg: number, color: number, dur: number, delay = 0) =>
      this.effects.decal({ tex: fx.cone(), color, x: ev.x, z: ev.z, r: r / 2, sz: 1, sx: Math.tan((halfDeg * Math.PI) / 180) / Math.tan(Math.PI / 6), anchor: 1, rot: dir + Math.PI, duration: dur, opacity: 0.5, fadeIn: dur * 0.6, fadeOut: 0.05, delay });
    const line = (x: number, z: number, len: number, dir: number, halfWidth: number, color: number, dur: number) =>
      this.effects.decal({ tex: fx.disc(), color, x, z, r: len / 2, sz: 1, sx: (halfWidth * 2) / len, anchor: 1, rot: dir + Math.PI, duration: dur, opacity: 0.6, fadeIn: dur * 0.7, fadeOut: 0.05 });
    const mine = ev.players?.includes(this.selfId);
    if ((ev.kind === 'bury' || ev.kind === 'hands' || (ev.kind === 'grasp' && def.id === 'congregation')) && ms === 0 && mine && ev.root) {
      // Buried / grasped: root yourself (players are client-simulated); casting stays allowed.
      this.player.rootedUntil = Math.max(this.player.rootedUntil, this.now + ev.root * 1000);
      this.floating.spawn(this.player.x, 2.4, this.player.z, ev.kind === 'bury' ? 'Buried!' : 'Grasped!', 'info');
    }
    switch (ev.kind) {
      case 'sweep':
      case 'maul':
        if (ms > 0) cone(ev.r ?? 4, ev.dir ?? 0, ev.kind === 'sweep' ? GRAVEDIGGER.sweep.halfDeg : CONGREGATION.melee.halfDeg, def.id === 'gravedigger' ? dirt : tide, ms);
        else {
          this.effects.emit({ x: ev.x + Math.sin(ev.dir ?? 0) * 2, y: 0.4, z: ev.z + Math.cos(ev.dir ?? 0) * 2, count: 20, color: def.id === 'gravedigger' ? dirt : tide, spread: 1.2, speed: 3, up: 1.5, life: 0.6, size: 0.2, gravity: 9 });
          audio.play('bossSlam', ev.x, ev.z);
          this.rig.shake(0.2);
        }
        break;
      case 'bury':
        for (const [x, z] of ev.targets ?? [[ev.x, ev.z]]) {
          if (ms > 0) this.effects.decal({ tex: fxImage('graveOutline'), color: 0xe0a458, x, z, r: GRAVEDIGGER.burial.hd, sx: GRAVEDIGGER.burial.hw / GRAVEDIGGER.burial.hd, duration: ms, opacity: 0.9, fadeIn: ms * 0.5, fadeOut: 0.05 });
          else {
            this.effects.emit({ x, y: 0.3, z, count: 18, color: dirt, spread: 0.8, speed: 1.8, up: 2, life: 0.6, size: 0.2, gravity: 9 });
            this.effects.decal({ tex: fx.cracks(), color: dirt, x, z, r: 1.4, rot: Math.random() * 6, duration: 1.2, opacity: 0.8, fadeOut: 0.4 });
          }
        }
        if (ms === 0) audio.play('boneHit', ev.x, ev.z);
        break;
      case 'pits':
        for (const [x, z] of ev.targets ?? []) {
          this.pitFx.push(this.effects.decal({ tex: fx.disc(), color: 0x120c08, x, z, r: ev.r ?? 1.2, duration: 1e9, opacity: 0.95, growFrom: 0.2 }));
          this.pitFx.push(this.effects.decal({ tex: fxImage('graveOutline'), color: 0xe0a458, x, z, r: (ev.r ?? 1.2) * 1.3, sx: 0.55, duration: 1e9, opacity: 0.7, pulse: 1.5 }));
        }
        this.hud.toast('Every grave is open: stay out of the pits.', 'err');
        break;
      case 'lance':
        if (ms > 0) line(ev.x, ev.z, ev.r ?? 11, ev.dir ?? 0, 0.8, curse, ms);
        else {
          this.effects.spikeLine(ev.x, ev.z, Math.sin(ev.dir ?? 0), Math.cos(ev.dir ?? 0), ev.r ?? 11, 1);
          audio.play('boneHit', ev.x, ev.z);
        }
        break;
      case 'chorus':
        for (let i = 0; i < 8; i++) {
          const d = (ev.dir ?? 0) + (i * Math.PI) / 4;
          if (ms > 0) line(ev.x, ev.z, ev.r ?? 9, d, 0.7, SPELL_FX.boss.shard, ms);
          else this.effects.spikeLine(ev.x, ev.z, Math.sin(d), Math.cos(d), ev.r ?? 9, 0.9);
        }
        if (ms === 0) {
          audio.play('bossSlam', ev.x, ev.z);
          this.rig.shake(0.25);
        }
        break;
      case 'grasp':
        if (def.id === 'abbess') {
          if (ms > 0) cone(ev.r ?? 3.5, ev.dir ?? 0, 55, SPELL_FX.boss.shard, ms);
          break;
        }
        for (const [x, z] of ev.targets ?? []) {
          if (ms > 0) {
            this.effects.decal({ tex: fx.disc(), color: tide, x, z, r: ev.r ?? 1.4, duration: ms, opacity: 0.5, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.3 });
            this.effects.decal({ tex: fxImage('drownedHand'), color: 0x8fb4c8, x, z, r: (ev.r ?? 1.4) * 0.9, duration: ms, opacity: 0.8, growFrom: 0.2, fadeOut: 0.05 });
          } else this.effects.emit({ x, y: 0.3, z, count: 16, color: 0x8fb4c8, spread: 0.6, speed: 1.2, up: 2.4, life: 0.7, size: 0.22 });
        }
        break;
      case 'hymn':
        if (ms > 0) {
          cone(ev.r ?? 15, ev.dir ?? 0, CONGREGATION.hymn.halfDeg, tide, ms);
          // Tide crests march outward across the arc: find a pew before they reach you.
          for (let k = 1; k <= 5; k++) {
            const rr = ((ev.r ?? 15) * k) / 5.5;
            for (const off of [-0.6, 0, 0.6]) {
              const d = (ev.dir ?? 0) + off;
              this.effects.decal({ tex: fxImage('tideCrest'), color: 0x8fb4c8, x: ev.x + Math.sin(d) * rr, z: ev.z + Math.cos(d) * rr, r: 1.1, rot: d + Math.PI, duration: 0.6, opacity: 0.85, fadeOut: 0.3, delay: (ms / 1000) * (k / 6) });
            }
          }
          this.hud.toast('Flood Hymn: put a pew between you and her!', 'err');
        } else {
          for (let k = 0; k < 6; k++) {
            const d = (ev.dir ?? 0) + (k - 2.5) * 0.35;
            this.effects.emitSmoke({ x: ev.x + Math.sin(d) * 7, y: 0.4, z: ev.z + Math.cos(d) * 7, count: 3, color: 0x2a3a40, spread: 1.5, speed: 2.5, up: 0.8, life: 0.9, size: 1.4 });
          }
          audio.play('bossSlam', ev.x, ev.z);
          this.rig.shake(0.3);
        }
        break;
      case 'communion':
        if (ms > 0) {
          for (const [x, z] of ev.targets ?? []) this.effects.beam({ x, y: 0.3, z }, () => ({ x: ev.x, y: 1.5, z: ev.z }), curse, 0.05, ms);
          this.effects.decal({ tex: fx.sigil(), color: curse, x: ev.x, z: ev.z, r: 2.4, duration: ms, opacity: 0.8, spin: 1.5 });
          this.hud.toast('Bone Communion: spend the corpses before they reach her!', 'err');
        } else if ((ev.r ?? 0) > 0) this.floating.spawn(ev.x, 3, ev.z, `+${Math.round((ev.r ?? 0))} corpses devoured`, 'info');
        break;
      case 'rotRain':
        if (ms > 0 && !this.saintRainTold) {
          this.saintRainTold = true;
          this.hud.toast('Rot Rain: leave the circles! The pools they leave behind heal her.', 'err');
        }
        for (const [x, z] of ev.targets ?? []) {
          if (ms > 0) this.effects.decal({ tex: fx.disc(), color: SPELL_FX.enemy.toxic, x, z, r: ev.r ?? 2, duration: ms, opacity: 0.55, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.2 });
          else this.effects.emitSmoke({ x, y: 0.3, z, count: 3, color: 0x4a5a22, spread: 1, speed: 1.2, up: 1, life: 1, size: 1.1 });
        }
        if (ms > 0) this.hud.toast('Rot Rain: step out of the green, then keep her out of it.', 'err');
        else audio.play('boneHit', ev.x, ev.z);
        break;
      case 'swing':
        if (ms > 0) cone(ev.r ?? 4.5, ev.dir ?? 0, SAINT.swing.halfDeg, SPELL_FX.enemy.rot, ms);
        else {
          this.effects.emitSmoke({ x: ev.x + Math.sin(ev.dir ?? 0) * 2, y: 0.8, z: ev.z + Math.cos(ev.dir ?? 0) * 2, count: 4, color: 0x5a6a2a, spread: 1.4, speed: 2, up: 0.6, life: 0.8, size: 1 });
          audio.play('bossSlam', ev.x, ev.z);
          this.rig.shake(0.2);
        }
        break;
      case 'link':
        // Plague Doctors feeding her: a green tether from each, so "kill the doctors" is visible.
        for (const [x, z] of ev.targets ?? []) {
          this.effects.beam({ x, y: 1.6, z }, () => ({ x: ev.x, y: 2.2, z: ev.z }), 0x9cc43a, 0.07, 900);
          this.effects.emit({ x, y: 1.4, z, count: 4, color: 0x9cc43a, spread: 0.3, speed: 0.5, up: 1.4, life: 0.7, size: 0.18 });
        }
        if ((ev.targets?.length ?? 0) > 0 && !this.saintLinkTold) {
          this.saintLinkTold = true;
          this.hud.toast('The Plague Doctors are feeding her: cut them down first!', 'err');
        }
        break;
      case 'blessed':
        this.effects.emit({ x: ev.x, y: 0.4, z: ev.z, count: 10, color: 0x9cc43a, spread: 0.8, speed: 0.6, up: 2.2, life: 0.9, size: 0.2 });
        // A pulse ring under her every beat she feeds, so "she is healing right now" reads at a glance.
        this.effects.decal({ tex: fx.ring(), color: 0x9cc43a, x: ev.x, z: ev.z, r: 3.2, duration: 0.7, opacity: 0.85, growFrom: 0.4, fadeOut: 0.4 });
        if (performance.now() - this.saintFeedAt > 3500) {
          this.saintFeedAt = performance.now();
          this.floating.spawn(ev.x, 3.5, ev.z, 'She feeds on the rot!', 'info');
          if (!this.saintBlessTold) {
            this.saintBlessTold = true;
            this.hud.toast('She heals while standing in rot pools: lure her onto clean ground!', 'err');
          }
        }
        break;
      case 'coals': {
        const E = SPELL_FX.enemy;
        for (const [x, z] of ev.targets ?? []) {
          if (ms > 0) {
            this.effects.decal({ tex: fx.disc(), color: E.ember, x, z, r: ev.r ?? 1.8, duration: ms, opacity: 0.55, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.2 });
            this.effects.decal({ tex: fx.ring(), color: E.emberCore, x, z, r: ev.r ?? 1.8, duration: ms, opacity: 0.9, fadeOut: 0.05 });
            this.effects.projectile({ from: { x: ev.x, y: 3.4, z: ev.z }, to: () => ({ x, y: 0.3, z }), kind: 'orb', color: E.ember, speed: Math.max(5, Math.hypot(x - ev.x, z - ev.z) / Math.max(0.3, ms)), arc: 45 });
          } else {
            this.bb('vengeful_burst', x, z, { scale: (ev.r ?? 1.8) / 1.4, colors: [E.ember, E.emberCore, E.emberDeep] });
            this.effects.emit({ x, y: 0.4, z, count: 14, color: E.emberCore, spread: 0.7, speed: 3, up: 2.6, life: 0.7, size: 0.13, gravity: 8 });
          }
        }
        if (ms > 0) audio.play('emberThrow', ev.x, ev.z);
        else audio.play('emberBurst', ev.x, ev.z);
        break;
      }
      case 'cleave':
        if (ms > 0) cone(ev.r ?? 5.2, ev.dir ?? 0, REGENT.cleave.halfDeg, SPELL_FX.enemy.ember, ms);
        else {
          const E = SPELL_FX.enemy;
          for (const d of REGENT.cleave.trail) {
            const x = ev.x + Math.sin(ev.dir ?? 0) * d;
            const z = ev.z + Math.cos(ev.dir ?? 0) * d;
            this.effects.emit({ x, y: 0.5, z, count: 12, color: E.emberCore, spread: 0.5, speed: 3.4, up: 2.4, life: 0.6, size: 0.12, gravity: 8 });
          }
          this.effects.emitSmoke({ x: ev.x + Math.sin(ev.dir ?? 0) * 2.5, y: 0.8, z: ev.z + Math.cos(ev.dir ?? 0) * 2.5, count: 4, color: E.emberDeep, spread: 1.4, speed: 2, up: 0.6, life: 0.8, size: 1 });
          audio.play('slagSlam', ev.x, ev.z);
          this.rig.shake(0.25);
        }
        break;
      case 'conflagration': {
        // The signature: the whole arena reddens over the windup while the ash circles glow pale. When it lands the
        // floor erupts everywhere else.
        const E = SPELL_FX.enemy;
        const r = ev.r ?? 11;
        if (ms > 0) {
          this.effects.decal({ tex: fx.disc(), color: E.ember, x: ev.x, z: ev.z, r, duration: ms, opacity: 0.5, fadeIn: ms * 0.9, fadeOut: 0.05, growFrom: 0.9 });
          this.effects.decal({ tex: fx.ring(), color: E.emberCore, x: ev.x, z: ev.z, r, duration: ms, opacity: 0.9, pulse: 6, fadeOut: 0.05 });
          for (const [x, z] of ev.targets ?? []) {
            this.effects.decal({ tex: fx.disc(), color: 0xd8d4c8, x, z, r: REGENT.conflagration.safeR, duration: ms, opacity: 0.6, fadeOut: 0.05 });
            this.effects.decal({ tex: fx.ring(), color: 0xffffff, x, z, r: REGENT.conflagration.safeR, duration: ms, opacity: 0.95, pulse: 3, fadeOut: 0.05 });
            this.effects.emit({ x, y: 0.3, z, count: 6, color: 0xd8d4c8, spread: REGENT.conflagration.safeR * 0.6, speed: 0.3, up: 1.2, life: ms, size: 0.16, drag: 0.5 });
          }
          audio.play('bossAwaken', ev.x, ev.z);
          this.hud.toast('Conflagration! Run to a grey ash circle and stand on it!', 'err');
        } else {
          for (let k = 0; k < 4; k++) this.effects.decal({ tex: fx.ring(), color: k % 2 ? E.emberCore : E.ember, x: ev.x, z: ev.z, r: r * (0.4 + k * 0.3), duration: 0.7, opacity: 1 - k * 0.2, growFrom: 0.1, delay: k * 0.08 });
          this.effects.emit({ x: ev.x, y: 0.6, z: ev.z, count: 160, color: E.emberCore, spread: r * 0.55, speed: 5, up: 4, life: 1.1, size: 0.16, gravity: 6 });
          this.effects.lightFlash(ev.x, 3, ev.z, E.ember, 110, 0.9);
          this.bb('surge_eruption', ev.x, ev.z, { scale: r / 4, colors: [E.ember, E.emberCore, E.emberDeep] });
          audio.play('slagSlam', ev.x, ev.z);
          this.rig.shake(0.55);
        }
        break;
      }
      case 'surface': {
        // Mire Mother: ripple rings converge on a hummock for the whole windup; when they meet, she bursts out under it.
        const T = 0x5fc4b4;
        if (ms > 0) {
          this.effects.decal({ tex: fx.disc(), color: T, x: ev.x, z: ev.z, r: ev.r ?? 3.7, duration: ms, opacity: 0.4, fadeIn: ms * 0.9, fadeOut: 0.05, growFrom: 0.3 });
          this.effects.decal({ tex: fx.ring(), color: 0xc8fff4, x: ev.x, z: ev.z, r: ev.r ?? 3.7, duration: ms, opacity: 0.95, pulse: 4, fadeOut: 0.05 });
          for (let k = 0; k < 3; k++) this.effects.decal({ tex: fx.ring(), color: T, x: ev.x, z: ev.z, r: (ev.r ?? 3.7) * 1.8, duration: Math.max(0.3, ms / 3), opacity: 0.8, growFrom: 1, delay: (ms / 3) * k });
          for (let k = 0; k < 6; k++) this.worldView.addRipple(ev.x, ev.z, 1.4);
          this.hud.toast('The Mire Mother sinks: leave the ringed hummock before she surfaces!', 'err');
        } else {
          for (let k = 0; k < 3; k++) this.effects.decal({ tex: fx.ring(), color: T, x: ev.x, z: ev.z, r: (ev.r ?? 3.7) * (0.6 + k * 0.35), duration: 0.6, opacity: 1 - k * 0.25, growFrom: 0.2, delay: k * 0.08 });
          this.effects.emit({ x: ev.x, y: 0.4, z: ev.z, count: 80, color: 0x9fe8da, spread: 1.6, speed: 4.5, up: 4, life: 1, size: 0.3, gravity: 7 });
          this.effects.emitSmoke({ x: ev.x, y: 0.4, z: ev.z, count: 6, color: 0x1c3a38, spread: 1.4, speed: 1.4, up: 0.9, life: 1.2, size: 1.6 });
          this.worldView.addRipple(ev.x, ev.z, 3);
          this.effects.lightFlash(ev.x, 2, ev.z, T, 60, 0.6);
          audio.play('bossSlam', ev.x, ev.z);
          this.rig.shake(0.4);
          this.floating.spawn(ev.x, 3.6, ev.z, 'Winded!', 'info');
        }
        break;
      }
      case 'hands': {
        const T = 0x7fb4a8;
        for (const [x, z] of ev.targets ?? []) {
          if (ms > 0) {
            this.effects.decal({ tex: fx.disc(), color: T, x, z, r: ev.r ?? 1.5, duration: ms, opacity: 0.5, fadeIn: ms * 0.7, fadeOut: 0.05, growFrom: 0.3 });
            this.effects.decal({ tex: fxImage('drownedHand'), color: 0x8fb4c8, x, z, r: (ev.r ?? 1.5) * 0.9, duration: ms, opacity: 0.85, growFrom: 0.2, fadeOut: 0.05 });
          } else {
            this.effects.emit({ x, y: 0.3, z, count: 14, color: T, spread: 0.6, speed: 1.2, up: 2.4, life: 0.7, size: 0.22 });
            this.worldView.addRipple(x, z, 1.6);
          }
        }
        if (ms > 0) this.hud.toast('Drowned hands rise under anyone wading the open water: get onto dry ground!', 'err');
        break;
      }
      case 'rite': {
        const T = 0x5fc4b4;
        if (ms > 0) {
          for (const [x, z] of ev.targets ?? []) {
            this.effects.beam({ x, y: 0.3, z }, () => ({ x: ev.x, y: 2.2, z: ev.z }), T, 0.05, ms);
            this.effects.decal({ tex: fx.sigil(), color: T, x, z, r: 1.1, duration: ms, opacity: 0.85, spin: 3, fadeOut: 0.05 });
          }
          this.effects.decal({ tex: fx.sigil(), color: T, x: ev.x, z: ev.z, r: 3, duration: ms, opacity: 0.8, spin: 1.5, fadeOut: 0.05 });
          this.hud.toast('The Drowned Rite: she raises every corpse in the Fen. Spend them now!', 'err');
        } else if ((ev.targets?.length ?? 0) === 0) {
          this.floating.spawn(ev.x, 3.6, ev.z, 'The rite finds no dead', 'info');
          this.effects.emit({ x: ev.x, y: 1.6, z: ev.z, count: 30, color: 0x9fb4b0, spread: 1, speed: 1.4, up: 1.2, life: 0.9, size: 0.25 });
          this.hud.toast('The rite failed: no corpses left. She reels!', 'good');
        } else {
          for (const [x, z] of ev.targets ?? []) {
            this.effects.emit({ x, y: 0.3, z, count: 26, color: T, spread: 0.5, speed: 0.6, up: 3, life: 1, size: 0.3, gravity: -0.4 });
            this.effects.decal({ tex: fx.ring(), color: T, x, z, r: 1.6, duration: 0.6, opacity: 0.9, growFrom: 0.2 });
          }
          audio.play('raise', ev.x, ev.z);
        }
        break;
      }
      case 'flood': {
        // The arena floods: rings race outward, the hummocks sink to their new size (WorldView eases them).
        const T = 0x5fc4b4;
        for (let k = 0; k < 4; k++) this.effects.decal({ tex: fx.ring(), color: T, x: ev.x, z: ev.z, r: 6 + k * 3, duration: 1, opacity: 1 - k * 0.2, growFrom: 0.1, delay: k * 0.1 });
        for (const [x, z] of ev.targets ?? []) this.effects.emit({ x, y: 0.3, z, count: 24, color: 0x7fe0d0, spread: 0.6, speed: 0.8, up: 2.4, life: 1, size: 0.25 });
        this.effects.lightFlash(ev.x, 3, ev.z, T, 70, 0.9);
        this.rig.shake(0.5);
        break;
      }
      case 'nicheBreak':
        this.effects.emit({ x: ev.x, y: 1.6, z: ev.z, count: 40, color: 0xe0d6c2, spread: 1, speed: 3.5, up: 2.5, life: 0.9, size: 0.25, gravity: 8 });
        this.effects.lightFlash(ev.x, 2, ev.z, SPELL_FX.boss.shard, 40, 0.5);
        audio.play('bossSlam', ev.x, ev.z);
        break;
    }
  }

  private onBossEvent(ev: Extract<SimEvent, { t: 'boss' }>) {
    const ms = (ev.ms ?? 0) / 1000;
    switch (ev.kind) {
      case 'awaken': {
        const def = BOSSES[ev.boss ?? 'prelate'];
        this.codexDiscover('dead', def.id);
        audio.play('bossAwaken', ev.x, ev.z);
        if (def.id === 'regent') this.hud.toast('The Cinder Regent: when Conflagration begins, run to a grey ash circle. Kill the Pyre Priests early.', 'err');
        if (def.id === 'mire') this.hud.toast('The Mire Mother: she sinks and resurfaces. Leave the ringed hummock, punish her while she is winded, and spend your corpses before she raises them.', 'err');
        if (def.id === 'saint') {
          this.saintBlessTold = false;
          this.saintRainTold = false;
          this.saintLinkTold = false;
        }
        this.hud.banner(def.name, def.awaken, 3500);
        this.effects.lightFlash(ev.x, 3, ev.z, def.color, 90, 1.6);
        this.effects.emit({ x: ev.x, y: 0.5, z: ev.z, count: 160, color: def.id === 'prelate' ? 0xb58cff : def.color, spread: 3, speed: 4, up: 4, life: 1.6, size: 0.5 });
        this.rig.shake(0.6);
        if (def.id === 'prelate') for (const g of ['west', 'east', 'north']) this.worldView.setCandleGroup(g, true);
        break;
      }
      case 'phase':
        if ((ev.boss ?? 'prelate') === 'prelate') {
          this.hud.banner(ev.phase === 2 ? 'The Procession' : 'The Bell Breaks', ev.phase === 2 ? 'Penitents file in from the aisles' : 'The Prelate is enraged', 2600);
          this.worldView.setCandleGroup(ev.phase === 2 ? 'west' : 'east', false);
        } else {
          this.hud.banner(BOSSES[ev.boss!].phases[ev.phase - 1], BOSSES[ev.boss!].name, 2600);
          if (ev.boss === 'regent') {
            const E = SPELL_FX.enemy;
            for (let k = 0; k < 3; k++) this.effects.decal({ tex: fx.ring(), color: E.ember, x: ev.x, z: ev.z, r: 5 + k * 3, duration: 0.9, opacity: 1 - k * 0.25, growFrom: 0.1, delay: k * 0.12 });
            this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 90, color: E.emberCore, spread: 2.5, speed: 6, up: 2.5, life: 0.9, size: 0.2, gravity: 4 });
            this.effects.lightFlash(ev.x, 3, ev.z, E.ember, 70, 0.9);
            this.rig.shake(0.5);
            this.hud.toast(ev.phase === 2 ? 'The pyre feeds: Husks and Pyre Priests join. Kill the Priests before their coals cover the ash.' : 'The pyre burns down: fewer ash circles, and hounds hunt in packs.', 'err');
          }
          if (ev.boss === 'mire') this.hud.toast(ev.phase === 2 ? 'The marsh floods: the hummocks shrink and the water drags harder. Leeches climb out.' : 'The drowned rise: spend your corpses before she raises them. Hags will hex your thralls.', 'err');
          if (ev.boss === 'saint') {
            if (ev.phase === 3) {
              // The swarm: a rot nova so the phase change feels like an event.
              for (let k = 0; k < 3; k++) this.effects.decal({ tex: fx.ring(), color: 0x9cc43a, x: ev.x, z: ev.z, r: 6 + k * 3, duration: 0.9, opacity: 1 - k * 0.25, growFrom: 0.1, delay: k * 0.12 });
              this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 90, color: 0x9cc43a, spread: 2.5, speed: 6, up: 1.5, life: 0.9, size: 0.35 });
              this.effects.lightFlash(ev.x, 3, ev.z, 0x9cc43a, 70, 0.9);
              this.rig.shake(0.5);
            }
            this.hud.toast(ev.phase === 2 ? 'Her flock gathers: Plague Doctors feed her through a green link. Cut them down first, then keep her out of the rot.' : 'The swarm: the rain falls heavier and the pools last longer. Keep her out of them.', 'err');
          }
        }
        this.rig.shake(0.5);
        break;
      case 'sweep':
      case 'maul':
      case 'grasp':
      case 'hymn':
      case 'bury':
      case 'pits':
      case 'lance':
      case 'chorus':
      case 'communion':
      case 'nicheBreak':
      case 'rotRain':
      case 'swing':
      case 'blessed':
      case 'link':
      case 'coals':
      case 'cleave':
      case 'conflagration':
      case 'surface':
      case 'hands':
      case 'rite':
      case 'flood':
        this.areaBossEvent(ev, ms);
        break;
      case 'toll':
        if (ms === 0) audio.play('bossToll', ev.x, ev.z);
        if (ms > 0) this.effects.decal({ tex: fx.disc(), color: SPELL_FX.boss.bronze, x: ev.x, z: ev.z, r: ev.r ?? 6.5, duration: ms, opacity: 0.75, fadeIn: ms * 0.8, fadeOut: 0.05, growFrom: 0.15 });
        else {
          for (let k = 0; k < 3; k++) this.effects.decal({ tex: fx.ring(), color: SPELL_FX.boss.bronze, x: ev.x, z: ev.z, r: (ev.r ?? 6.5) * (0.8 + k * 0.25), duration: 0.6, opacity: 1 - k * 0.25, growFrom: 0.1, delay: k * 0.07 });
          this.effects.emit({ x: ev.x, y: 1, z: ev.z, count: 70, color: SPELL_FX.boss.bronze, spread: 2, speed: 7, up: 1, life: 0.7, size: 0.35 });
          this.effects.lightFlash(ev.x, 3, ev.z, SPELL_FX.boss.bronze, 60, 0.6);
          this.bb('bell_toll_ring', ev.x, ev.z, { scale: (ev.r ?? 6.5) / 3 });
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
            this.bb(ev.kind === 'slam' ? 'prelate_impact' : 'boss_rain_orb', x, z, { scale: (ev.r ?? 2.3) / 2.3 });
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
        this.bossView(ev.boss ?? 'prelate').hide();
        const def = BOSSES[ev.boss ?? 'prelate'];
        this.pitFx.forEach((h) => h.kill());
        this.pitFx = [];
        if (def.id === 'prelate') for (const g of ['west', 'east', 'north']) this.worldView.setCandleGroup(g, true);
        if (ev.killer) {
          audio.play('bossDefeat', ev.x, ev.z);
          this.chronicle.add(`boss.${def.id}`);
          this.hud.banner(def.defeated[0], def.defeated[1], 4200);
          if (def.id === 'prelate') {
            this.progression.recordPrelateKill();
            if (this.progression.canAscend()) this.onboarding.show('ascend', 5000);
          }
          const reward = rollBoss(this.bossWaveTier(), Math.random, this.worldDifficulty(), def.area, def.shards, def.id);
          // First kill per character: two more shards and a guaranteed rare-or-better (browser trophy record).
          if (def.id !== 'prelate' && this.claimTrophy(def.id)) {
            reward.shards += 2;
            reward.items.push(rollFirstKillItem(def.area));
            this.hud.toast(`First kill: ${def.name}. A trophy for the Codex, two more shards and a rare relic.`, 'good');
          }
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
    this.chronicle.time(dt, !!this.gathering?.afk);
    if (this.fxLater.length) {
      const due = this.fxLater.filter((f) => f.at <= now);
      this.fxLater = this.fxLater.filter((f) => f.at > now);
      for (const f of due) f.run();
    }
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
        const short = this.abilities.shortfall(this.primary, t);
        if (short > 0 && !this.mouse.shift) p.moveTo(tgt.x, tgt.z);
        else {
          p.stop();
          if (this.abilities.ready(this.primary, now)) this.abilities.cast(this.primary, t, now);
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
    const autoMove = canUseAutoCombat() && settings.autoCombat && p.alive && !this.panelOpen() && !this.recallAt && !p.hasPath &&
      !this.attackTarget && !this.pendingInteract && !this.gathering.active && !this.keys.size
      ? selectAutoCombatMovement({ player: { x: p.x, z: p.z, area: p.area, essence: p.essence, maxEssence: p.resource.max,
          hp: p.hp, maxHp: p.stats.maxHp },
        enemies: this.enemiesMap().values(), primary: this.primary, primaryRange: this.primaryRange(), family: this.discipline.family, nav: this.nav }, this.autoMoveMem, now, dt) : null;
    if (!autoMove) this.autoMoveMem.dir = null;
    // Drowned Congregation: the water rises each phase; wading outside her dais is slower.
    {
      const b = this.bossState();
      const C = CONGREGATION.water;
      const arena = BOSSES.congregation.arena;
      const wading = b.active && b.id === 'congregation' && b.phase >= 2 && p.area === 'nave'
        && Math.hypot(p.x - arena.x, p.z - arena.z) <= arena.r && Math.hypot(p.x - arena.x, p.z - arena.z) > C.dais;
      // The Mourning Fen: wading the bog is slow, dry hummocks are not; the Mire Mother's flood shrinks them and deepens the slow.
      const mire = b.active && b.id === 'mire' ? b.phase : 0;
      const bog = p.area === 'fen' ? bogMult(p.x, p.z, mire) : 1;
      this.worldView.setFenFlood(mire ? FEN_FLOOD_SCALE[mire] : 1);
      p.moveMult = (wading ? (b.phase >= 3 ? C.slowP3 : C.slowP2) : 1) * bog * (1 + p.brewValue('speed', now));
    }
    const moved = p.update(dt, now, kd.x || kd.z ? kd : autoMove);
    if (canUseAutoCombat() && settings.autoCombat && p.alive && now - p.lastHurtAt < 5000) p.heal(p.stats.maxHp * 0.02 * dt);
    if (now < this.mealUntil && p.alive) p.heal(this.mealRate * dt);
    this.gathering.update(dt);
    this.tickGatherVisuals(dt);
    this.waystoneMotes(dt);
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
      this.sim.setPlayer({ id: this.selfId, x: p.x, z: p.z, alive: p.alive, area: p.alive ? p.area : null, family: this.discipline.family, level: this.character.level });
      for (const [id, r] of this.remotes) {
        this.sim.setPlayer({ id, x: r.tx, z: r.tz, alive: r.hpFrac > 0, area: this.nav.areaAt(r.tx, r.tz), family: disciplineFor(r.info.classIndex).family, level: r.info.level ?? 1 });
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
    if (got.items.some((item) => ARMOR_BY_ID[item.item_id])) this.onboarding.show('armor');
    if (got.items.some((item) => item.item_id in REAGENT_ITEMS)) this.onboarding.show('reagent', 0, true);
    for (const item of got.items) this.hud.toast(`${itemMeta(item.item_id).name}${item.quantity > 1 ? ` ×${item.quantity}` : ''}`, 'good');

    // Visuals.
    this.avatar.update(dt, p.x, p.z, p.facing, p.moving, p.stats.moveSpeed);
    this.petView?.update(dt, p.x, p.z, p.facing);
    for (const tick of this.lineupTicks) tick(dt);
    this.vfxGallery?.update(dt);
    for (const r of this.remotes.values()) {
      const k = Math.min(1, dt * 10);
      const x = r.avatar.c.root.position.x + (r.tx - r.avatar.c.root.position.x) * k;
      const z = r.avatar.c.root.position.z + (r.tz - r.avatar.c.root.position.z) * k;
      r.avatar.update(dt, x, z, r.facing, r.moving, 5.4);
      r.pet?.update(dt, x, z, r.facing);
    }
    this.views.sync(this.enemiesMap(), this.thrallsMap(), dt, p.x, p.z);
    if (now - this.lastPrune > 2000) {
      this.lastPrune = now;
      this.views.pruneCorpses(this.corpsesMap());
    }
    this.zoneAmbience(dt);
    this.wadeRipples(dt);
    {
      const b = this.bossState();
      this.bossView(b.id ?? 'prelate').sync(b, dt);
    }
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
    this.syncEchoVisuals();
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
    const acre = this.area === 'acre';
    const night = acre ? 0 : this.nightK;
    this.moon.intensity = (acre ? 2.65 : 2.4) * (1 - 0.6 * night);
    this.hemi.intensity = (acre ? 1.12 : 0.95) * (1 - 0.3 * night);
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
      const rate = z.r * z.r * 0.8;
      if (Math.random() < dt * rate) {
        const a = Math.random() * Math.PI * 2;
        const d = Math.sqrt(Math.random()) * z.r;
        const x = z.x + Math.cos(a) * d;
        const zz = z.z + Math.sin(a) * d;
        if (z.kind === 'miasma' || z.kind === 'rot') {
          this.effects.emit({ x, y: 0.2, z: zz, count: 1, color: SPELL_FX.miasma.rot, spread: 0.2, speed: 0.15, up: 0.9, life: 1.4, size: 0.22, drag: 0.5 });
          if (Math.random() < 0.4) this.effects.emitSmoke({ x, y: 0.3, z: zz, count: 1, color: 0x56662a, spread: 0.3, speed: 0.2, up: 0.3, life: 2, size: 1.6, shrink: -0.8, drag: 0.5 });
        } else if (z.kind === 'ember') {
          this.effects.emit({ x, y: 0.15, z: zz, count: 1, color: SPELL_FX.enemy.emberCore, spread: 0.1, speed: 0.3, up: 1.6, life: 0.9, size: 0.14, drag: 0.4 });
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
    if (!this.announcedAreas.has(area)) {
      this.announcedAreas.add(area);
      this.hud.banner(def.name, def.subtitle);
      if (area === 'cloister') this.onboarding.show('cloister', 1200);
      if (area === 'pyre') this.onboarding.show('pyre', 1200);
      if (area === 'fen') this.onboarding.show('fen', 1200);
      if (area === 'warren') this.onboarding.show('warren', 1200);
      if (area === 'coliseum') this.onboarding.show('coliseum', 1200);
    }
    this.codexDiscover('area', area);
    (this.scene.fog as THREE.FogExp2).color.set(def.ambient.fog);
    this.hemi.color.set(def.ambient.hemiSky);
    this.hemi.groundColor.set(def.ambient.hemiGround);
    // The Omen tints the sky over every area's own palette (half-way, so each place stays itself).
    this.moon.color.set(def.ambient.moon).lerp(new THREE.Color(this.omen.sky.moon), 0.5);
    const fog = this.scene.fog as THREE.FogExp2;
    fog.density = 0.014 * (def.safe ? 1 : this.omen.sky.fogMult) * (def.ambient.fogMult ?? 1);
    if (!this.omenTold) {
      this.omenTold = true;
      this.hud.setOmen({ name: this.omen.name, icon: this.omen.icon, blurb: `${this.omen.blurb} Changes in ${omenLeft()}.` });
      this.onboarding.show('omen', 2600);
    }
    if (area === 'acre') this.onboarding.show('acre', 1200);
    void this.progression.flush();
  }

  /** Settings toggle: dev access on, or preview the game as a normal player. Nothing is saved but the preference. */
  private setDevAccess(on: boolean) {
    if (!this.devAccount) return;
    setDevPreference(browserStorage(), this.character.id, on);
    devAccess.active = on;
    const rites = loadRites(browserStorage(), this.character.id, riteLevel(this.character.level), this.kit);
    this.loadout = rites.keys;
    this.primary = rites.primary;
    this.hud.setPrimary(this.primary);
    this.markSeen([]);
    this.hotbar = this.buildHotbar();
    this.hud.setHotbar(this.hotbar);
    this.hud.setDev(on);
    this.nav.setUnlocked(this.openAreas());
    for (const d of DOORS) this.worldView.setDoorOpen(d.id, this.nav.isDoorOpen(d));
    this.grimoirePanel.render();
    this.hud.toast(on ? 'Dev access on: every rite, area and gathering tier is open (nothing is saved).' : 'Dev access off: previewing as a normal player.', 'good');
  }

  private wardReadout() {
    const perThrall = this.discipline.mods.wardPerThrall;
    const thralls = [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId).length;
    return { pct: Math.round(Math.min(0.6, perThrall * thralls) * 100), thralls, perThrall };
  }

  private areaProgress(): string {
    const here = this.area;
    if (here === 'acre') return 'Click a glowing node to gather · Walk east to the Chapterhouse for combat';
    if (here === 'chapterhouse') return 'Walk north to the Hollow Graves · Click an enemy to attack';
    if (AREAS[here].safe) return 'Sanctuary. The dead cannot follow you here.';
    // Every pending seal off this hall (the Graves hold two: the Warren and the Ossuary), nearest first.
    const pending = AREA_ORDER.filter((id) => AREAS[id].unlock?.area === here && !this.progression.isUnlocked(id))
      .map((id) => ({ id, need: this.progression.unlockKills(AREAS[id].unlock!.kills) }))
      .sort((a, b) => a.need - b.need);
    if (pending.length) {
      const kills = this.progression.kills(here);
      return pending.map(({ id, need }) => {
        // A seal may open a door in another hall (the Fen's is the Nave's west wall): say where.
        const door = DOORS.find((d) => d.b === id && d.a !== here);
        return `Slay <b>${Math.min(need, kills)}/${need}</b> to unseal ${AREAS[id].name}${door ? ` (${doorDirection(door)})` : ''}`;
      }).join('<br>');
    }
    if (here === 'sanctum') {
      return this.bossState().active
        ? 'The Prelate walks.'
        : `Offer <b>${this.progression.local.shards}/${BOSS_SUMMON_SHARDS}</b> soul shards at the Sundered Bell`;
    }
    return `<b>${this.progression.kills(here)}</b> slain here · Level ${AREAS[here].level + ascensionLevels(this.worldAscension())} dead`;
  }

  private interactPrompt(it: Interactable): string {
    switch (it.kind) {
      case 'inventory': return 'Open the Reliquary';
      case 'forge': return 'Open the Workbench';
      case 'professions': return 'Open Skills and AFK gathering';
      case 'waystone': return 'Travel by Waystone';
      case 'kiln': return 'Open Bone Kiln recipes';
      case 'sawpit': return 'Open Sawpit recipes';
      case 'fire': return 'Open Cooking Fire recipes';
      case 'upgrades': return 'Open Ascension';
      case 'lectern': return 'Open the Codex';
      case 'vault': return 'Open the Ossuary Vault (V)';
      case 'grinder': return 'Salvage gear at the Bone Grinder'; 
      case 'boss': {
        const boss = BOSSES[bossForSummon(it.id) ?? 'prelate'];
        return `Summon ${boss.name} · ${boss.shards} shards`;
      }
    }
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
    }
    this.hud.prompt(hover?.kind === 'interact' ? `<kbd>Click</kbd> ${this.interactPrompt(hover.it)}` : null);
    const b = this.bossState();
    const myThralls = [...this.thrallsMap().values()].filter((t) => t.owner === this.selfId);
    const saveText =
      this.progression.state === 'retrying' || this.inventory.state === 'retrying'
        ? { text: 'Save failed — retrying…', warn: true }
        : this.progression.state === 'saving' || this.inventory.state === 'saving'
          ? { text: 'Saving…', warn: false }
          : { text: OFFLINE ? 'Offline save ✓' : 'Saved ✓', warn: false };

    if (this.discipline.family === 'monk' && p.alive) {
      const beat = Math.floor(now / 1200);
      if (beat !== this.lastMonkBeat) {
        this.lastMonkBeat = beat;
        audio.play('tollSmall', p.x, p.z, 0.18);
      }
    }

    // Kill Chain readout; a long chain that breaks is remembered with a low thud.
    const broke = this.chain.tick(now);
    if (broke >= CHAIN.reportAt) {
      audio.play('chainBreak');
      this.floating.spawn(this.player.x, 2.6, this.player.z, `Chain broken: ${broke}`, 'info');
    }
    const chainTier = this.chain.tier;
    this.hud.setChain(this.chain.active && p.alive
      ? { count: this.chain.count, name: chainTier?.name ?? 'Chain', bonus: chainTier?.bonus ?? 0, frac: this.chain.frac(now), tier: chainTier ? CHAIN.tiers.indexOf(chainTier) + 1 : 0 }
      : null);

    this.hud.update({
      autoCombat: settings.autoCombat,
      autoCombatAvailable: canUseAutoCombat() && settings.difficulty === 'easy',
      autoCombatVisible: canUseAutoCombat(),
      hp: p.hp,
      maxHp: p.stats.maxHp,
      barrier: p.barrier,
      essence: p.resource.value,
      maxEssence: p.resource.max,
      resourceLabel: this.resourceRules.label,
      resourceColor: this.resourceRules.color,
      beatPulse: this.discipline.family === 'monk' && Math.min(now % 1200, 1200 - now % 1200) <= 150,
      level: this.character.level,
      xp: this.character.experience,
      xpNext: xpToNext(this.character.level),
      slots: this.hotbar.map((id) => {
        const empowered = this.abilities.empowered(id);
        return {
          left: p.cooldownLeft(id, now),
          total: abilityCooldownMs(id, ABILITIES[id].cooldownMs, p.loadout, PRIMARIES.includes(id)),
          affordable: empowered || p.essence >= ABILITIES[id].essenceCost,
          empowered,
          locked: riteLevel(this.character.level) < unlockLevel(id),
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
      ward: this.discipline.mods.wardPerThrall > 0 ? this.wardReadout() : null,
      brews: this.brewTray(),
      save: saveText,
      target,
      boss: b.active ? { name: BOSSES[b.id ?? 'prelate'].name, phase: b.phase, hp: b.hp, maxHp: b.maxHp, phases: BOSSES[b.id ?? 'prelate'].phases } : null,
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
          // Your character's name (one character per account: the account name), class and level beneath it.
          name: this.selfName,
          discipline: `${this.discipline.name} · Level ${this.character.level}${this.progression.local.ascension ? ` · Ascension ${roman(this.progression.local.ascension)}` : ''}`,
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
      /** QA: this client's body id (kills credited to it feed the Kill Chain) and the chain itself. */
      self: () => this.selfId,
      chain: () => this.chain,
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
        this.nav.setUnlocked(this.openAreas());
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
      /** Summon a boss (default the Prelate) and stand at the edge of its arena. */
      boss: (id: BossId = 'prelate') => {
        const a = BOSSES[id].arena;
        if (id === 'prelate') this.teleportTo(BOSS_ARENA.x, BOSS_ARENA.z + 8);
        else this.teleportTo(a.x, a.z + a.r * 0.7);
        this.sendIntent(id === 'prelate' ? { t: 'summonBoss', by: this.selfId } : { t: 'summonBoss', by: this.selfId, boss: id });
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
      /** BinbunVFX QA: play one converted effect at the player, e.g. vfx('bone_fan_hit', [0xe8dcc0]). */
      vfx: (id: BinbunId, colors?: THREE.ColorRepresentation[], o: Partial<BinbunSpawn> = {}) => {
        const h = this.effects.binbun.spawn(id, { x: this.player.x, y: 0.05, z: this.player.z, colors, once: isBinbunImpact(id), ...o });
        return h.alive;
      },
      vfxCount: () => this.effects.binbun.count,
      /** BinbunVFX review grid (16 per page) around the player; call vfxGallery(-1) to close. */
      vfxGallery: async (page = 0, colors?: THREE.ColorRepresentation[]) => {
        this.vfxGallery?.dispose();
        this.vfxGallery = null;
        if (page < 0) return [];
        const { openGallery } = await import('../graphics/binbun/gallery');
        this.vfxGallery = openGallery(this.effects.binbun, this.rig.camera, document.body, this.player, page, 16, colors);
        return this.vfxGallery.ids;
      },
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
            const db = JSON.parse(localStorage.getItem('dm_offline_db_v1') ?? '{}');
            for (const acc of Object.values(db.accounts ?? {}) as { character?: { id: number }; professions: { profession_id: string; skill_level: number; skill_xp: number }[] }[]) {
              if (acc.character?.id !== this.character.id) continue;
              const row = acc.professions.find((p) => p.profession_id === id);
              if (row) Object.assign(row, { skill_level: level, skill_xp: 0 });
              else acc.professions.push({ profession_id: id, skill_level: level, skill_xp: 0 });
            }
            localStorage.setItem('dm_offline_db_v1', JSON.stringify(db));
          } catch {
            /* storage unavailable */
          }
        }
        return this.skills.rows();
      },
      flushGather: () => this.gathering.flush(),
      /** The Mourning Fen's eased flood scale (1 calm, 0.72 / 0.5 in the Mire Mother's phases 2 / 3). */
      fenFlood: () => this.worldView.fenFlood(),
      /** Open an Acre station as if clicked (kiln / sawpit / fire). */
      station: (kind: 'kiln' | 'sawpit' | 'fire' | 'grinder') => {
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
    this.scope.add(() => this.vfxGallery?.dispose());
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  unmount() {
    setActiveCharacter(null);
    devAccess.active = false;
    this.ready = false;
    audio.stopArea();
    getRuntime().setView(null);
    this.realtime.disconnect();
    this.progression.dispose();
    this.inventory.dispose();
    this.scope.dispose();
    this.canvas.style.cursor = '';
    for (const r of this.remotes.values()) { r.avatar.dispose(); r.pet?.dispose(); }
    this.petView?.dispose();
    this.remotes.clear();
    this.views.dispose();
    this.nodeViews.dispose();
    for (const v of this.bossViews.values()) v.dispose();
    this.loot.dispose();
    this.avatar.dispose();
    this.effects.dispose();
    this.worldView.dispose();
    this.scene.environment?.dispose();
    this.scene.clear();
  }
}
