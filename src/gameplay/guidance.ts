import { AREAS, AREA_ORDER, type AreaId } from '../content/areas';
import { BOSSES, BOSS_IDS, type BossId } from '../content/bosses';
import { NPCS, npcInteractableId, type NpcId } from '../content/npcs';
import type { ContractBoard, LaborView } from '../net/api';
import { browserStorage, type StorageLike } from './codexJournal';

/**
 * Gentle guidance: pure selectors over a plain snapshot of the character. Nothing here touches the scene or the DOM, so every
 * rule is unit-tested (gameplay/__tests__/guidance.test.ts). The same Suggestion list feeds three things: the optional "Next"
 * line on the HUD, the minimap ping, and what the Prior, the Sexton and the Apothecary say when asked "where next?".
 * There are no quests: nothing here can be failed, forced or missed, and the numbers shown are always the real ones.
 */

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

export interface GuidanceState {
  level: number;
  area: AreaId;
  /** Ascension rank. */
  ascension: number;
  canAscend: boolean;
  ashesOnAscend: number;
  /** Boss soul shards in the purse. */
  shards: number;
  /** Seals really broken (not the dev overlay). Always-open areas need not be listed. */
  unlocked: AreaId[];
  areaKills: Partial<Record<AreaId, number>>;
  /** The Swift Seals boon multiplier on every seal's kill count. */
  unlockMult: number;
  /** Area bosses with a first-kill trophy. */
  bossesBeaten: BossId[];
  /** The Prelate falls once per run (it is what unlocks Ascension). */
  prelateThisRun: boolean;
  totalKills: number;
  /** Gathering / crafting skill levels (missing = 1). */
  skills: Partial<Record<string, number>>;
  bagUsed: number;
  bagSize: number;
  /** Grave Dust in the bag. */
  dust: number;
  /** Laborers and contracts load asynchronously; null = not known (yet), which never produces a suggestion. */
  labor: LaborSummary | null;
  contracts: ContractSummary | null;
}

export interface LaborSummary {
  unlocked: number;
  assigned: number;
  /** Posts with half an hour or more of work waiting (or full). */
  ready: number;
}
export interface ContractSummary {
  open: number;
  total: number;
}

export const LABOR_READY_MS = 30 * 60_000;
export const BAG_FULL_FRACTION = 0.85;
export const GRAVE_DUST_FOR_TONIC = 4;

export function summarizeLabor(v: LaborView): LaborSummary {
  const unlocked = v.slots.filter((s) => s.unlocked);
  const assigned = unlocked.filter((s) => !!s.nodeType);
  return { unlocked: unlocked.length, assigned: assigned.length, ready: assigned.filter((s) => s.capped || s.elapsedMs >= LABOR_READY_MS).length };
}

export function summarizeContracts(b: ContractBoard): ContractSummary {
  return { open: b.contracts.filter((c) => !c.done).length, total: b.contracts.length };
}

export const baseState = (over: Partial<GuidanceState> = {}): GuidanceState => ({
  level: 1, area: 'chapterhouse', ascension: 0, canAscend: false, ashesOnAscend: 0, shards: 0, unlocked: [], areaKills: {}, unlockMult: 1,
  bossesBeaten: [], prelateThisRun: false, totalKills: 0, skills: {}, bagUsed: 0, bagSize: 48, dust: 0, labor: null, contracts: null, ...over,
});

// ---------------------------------------------------------------------------
// Seals and bosses
// ---------------------------------------------------------------------------

/** Side halls: optional, so they never take the place of the main road in the tracker. */
export const SIDE_AREAS: AreaId[] = ['warren', 'coliseum'];

export const isOpen = (s: GuidanceState, a: AreaId) => !AREAS[a].unlock || s.unlocked.includes(a);
export const killsIn = (s: GuidanceState, a: AreaId) => s.areaKills[a] ?? 0;
export const sealNeed = (s: GuidanceState, a: AreaId) => Math.max(1, Math.round((AREAS[a].unlock?.kills ?? 0) * s.unlockMult));

export interface SealStatus {
  /** The sealed hall. */
  area: AreaId;
  /** Where the kills count. */
  from: AreaId;
  kills: number;
  need: number;
  side: boolean;
}

/** Every seal you can already work on (its feeding hall is open), main road first. */
export function pendingSeals(s: GuidanceState): SealStatus[] {
  const out: SealStatus[] = [];
  for (const a of AREA_ORDER) {
    const u = AREAS[a].unlock;
    if (!u || isOpen(s, a) || !isOpen(s, u.area)) continue;
    out.push({ area: a, from: u.area, kills: Math.min(killsIn(s, u.area), sealNeed(s, a)), need: sealNeed(s, a), side: SIDE_AREAS.includes(a) });
  }
  return out.sort((a, b) => Number(a.side) - Number(b.side));
}

export const bossBeaten = (s: GuidanceState, id: BossId) => (id === 'prelate' ? s.prelateThisRun : s.bossesBeaten.includes(id));

/** Bosses whose hall is open and who have not fallen (for this character, or this run for the Prelate), in the road's order. */
export function bossesWaiting(s: GuidanceState): BossId[] {
  return BOSS_IDS.filter((id) => isOpen(s, BOSSES[id].area) && !bossBeaten(s, id));
}

export const lowerThe = (name: string) => name.replace(/^The /, 'the ');

function spot(id: string): { x: number; z: number } | undefined {
  for (const a of AREA_ORDER) {
    const it = AREAS[a].interactables.find((i) => i.id === id);
    if (it) return { x: it.x, z: it.z };
  }
  return undefined;
}
export function areaCentre(a: AreaId): { x: number; z: number } {
  const r = AREAS[a].rect;
  return { x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2 };
}

// ---------------------------------------------------------------------------
// Suggestions
// ---------------------------------------------------------------------------

export type SuggestionKind =
  | 'first-steps' | 'seal' | 'boss-ready' | 'boss-short' | 'ascend' | 'hunt'
  | 'bag-full' | 'labor-ready' | 'labor-idle' | 'contracts' | 'gather-intro'
  | 'brew-dust' | 'brew-first';

/** Which person the suggestion belongs to (who talks about it when asked). */
export type Topic = 'route' | 'acre' | 'brew';
export const TOPIC_OF: Record<NpcId, Topic> = { prior: 'route', sexton: 'acre', apothecary: 'brew' };

export interface Suggestion {
  /** Stable while the situation is the same (the counts in `text` change; the id does not), so a dismissal sticks. */
  id: string;
  kind: SuggestionKind;
  topic: Topic;
  priority: number;
  /** Plain text for the HUD line. */
  text: string;
  /** The place (for "go there" wording). */
  place?: AreaId;
  /** World point for the minimap ping. */
  target?: { x: number; z: number };
  /** Ping even when standing in `place` (an object inside the hall, not the hall itself). */
  pingInPlace?: boolean;
  /** Only said by the NPCs, never shown on the HUD. */
  quiet?: boolean;
  /** Numbers and names the dialogue can quote. */
  data: Record<string, string | number>;
}

export function suggestions(s: GuidanceState): Suggestion[] {
  const out: Suggestion[] = [];
  const add = (x: Omit<Suggestion, 'data'> & { data?: Suggestion['data'] }) => out.push({ data: {}, ...x });

  // --- The road (the Prior) ---
  if (s.totalKills < 10 && s.ascension === 0 && s.area !== 'graves') {
    add({ id: 'first-steps', kind: 'first-steps', topic: 'route', priority: 95, text: 'Walk north into the Hollow Graves and fight your first dead', place: 'graves', target: areaCentre('graves'), data: { area: AREAS.graves.name } });
  }
  if (s.canAscend) {
    add({ id: 'ascend', kind: 'ascend', topic: 'route', priority: 72, text: `The Altar of Ascension is ready: +${s.ashesOnAscend} Ashes when you choose`, place: 'chapterhouse', target: spot('altar'), pingInPlace: true, data: { ashes: s.ashesOnAscend } });
  }
  const waiting = bossesWaiting(s);
  const ready = waiting.find((id) => s.shards >= BOSSES[id].shards);
  if (ready) {
    const b = BOSSES[ready];
    add({ id: `boss-ready:${ready}`, kind: 'boss-ready', topic: 'route', priority: 86, text: `${b.name} waits at ${lowerThe(b.summonLabel)} — ${b.shards} soul shards`, place: b.area, target: spot(b.summonId), pingInPlace: true, data: { boss: b.name, at: lowerThe(b.summonLabel), shards: b.shards, area: lowerThe(AREAS[b.area].name) } });
  }
  const seals = pendingSeals(s);
  const main = seals.find((x) => !x.side);
  if (main) {
    add({ id: `seal:${main.area}`, kind: 'seal', topic: 'route', priority: 60, text: `${AREAS[main.from].name.replace(/^The /, '')}: ${main.kills} / ${main.need} to open ${lowerThe(AREAS[main.area].name)}`, place: main.from, target: areaCentre(main.from), data: { from: lowerThe(AREAS[main.from].name), to: lowerThe(AREAS[main.area].name), kills: main.kills, need: main.need, level: AREAS[main.area].level } });
  }
  const short = waiting.find((id) => s.shards < BOSSES[id].shards);
  if (short) {
    const b = BOSSES[short];
    add({ id: `boss-short:${short}`, kind: 'boss-short', topic: 'route', priority: 50, text: `Soul shards for ${b.name}: ${s.shards} / ${b.shards} (elites carry them)`, place: b.area, data: { boss: b.name, at: lowerThe(b.summonLabel), shards: b.shards, have: s.shards, area: lowerThe(AREAS[b.area].name) } });
  }
  const hunt = [...AREA_ORDER].reverse().find((a) => !AREAS[a].safe && isOpen(s, a) && !SIDE_AREAS.includes(a));
  if (hunt && !main) {
    const clear = !waiting.length;
    add({ id: 'hunt', kind: 'hunt', topic: 'route', priority: 10, text: `${clear ? 'Every seal is broken and every king buried. ' : ''}Hunt in ${lowerThe(AREAS[hunt].name)}: level ${AREAS[hunt].level}${AREAS[hunt].scaling ? '+' : ''} dead`, place: hunt, target: areaCentre(hunt), data: { area: lowerThe(AREAS[hunt].name), level: AREAS[hunt].level, clear: clear ? 1 : 0 } });
  }

  // --- The Acre (the Sexton) ---
  if (s.bagSize > 0 && s.bagUsed / s.bagSize >= BAG_FULL_FRACTION) {
    add({ id: 'bag-full', kind: 'bag-full', topic: 'acre', priority: 88, text: 'Your bag is nearly full: salvage or stash spare gear (Acre, V)', place: 'acre', target: spot('bone_grinder'), pingInPlace: true, data: { used: s.bagUsed, size: s.bagSize } });
  }
  if (s.labor && s.labor.ready > 0) {
    add({ id: 'labor-ready', kind: 'labor-ready', topic: 'acre', priority: 70, text: s.labor.ready === 1 ? 'A laborer’s work is ready: collect it in the Acre (H)' : 'Your laborers are ready in the Acre (H)', place: 'acre', target: spot(npcInteractableId('sexton')), data: { ready: s.labor.ready } });
  }
  if (s.contracts && s.contracts.open > 0) {
    add({ id: 'contracts', kind: 'contracts', topic: 'acre', priority: 40, text: `${s.contracts.open} Sexton’s Contract${s.contracts.open === 1 ? ' waits' : 's wait'} for delivery (O)`, data: { open: s.contracts.open, total: s.contracts.total } });
  }
  if (s.labor && s.labor.unlocked > s.labor.assigned) {
    add({ id: 'labor-idle', kind: 'labor-idle', topic: 'acre', priority: 35, text: 'A Grave Laborer stands idle: give them a post (H)', place: 'acre', data: { idle: s.labor.unlocked - s.labor.assigned } });
  }
  if (['woodcutting', 'mining', 'fishing', 'gravedigging'].every((k) => (s.skills[k] ?? 1) <= 1) && !(s.labor && s.labor.assigned > 0)) {
    add({ id: 'gather-intro', kind: 'gather-intro', topic: 'acre', priority: 42, text: 'Gathering in the Sexton’s Acre trains skills and feeds the Workbench (P)', place: 'acre', target: areaCentre('acre'), data: {} });
  }

  // --- Brewing (the Apothecary) ---
  const alchemy = s.skills.alchemy ?? 1;
  if (s.dust >= GRAVE_DUST_FOR_TONIC && alchemy < 5) {
    add({ id: 'brew-dust', kind: 'brew-dust', topic: 'brew', priority: 45, text: `You carry ${s.dust} Grave Dust: brew a tonic at the Workbench (C)`, place: 'chapterhouse', target: spot('workbench'), pingInPlace: true, data: { dust: s.dust } });
  } else if (alchemy <= 1 && s.dust < GRAVE_DUST_FOR_TONIC) {
    add({ id: 'brew-first', kind: 'brew-first', topic: 'brew', priority: 12, text: 'Four Grave Dust brew your first tonic; the dead of the Graves drop it', quiet: true, data: { dust: s.dust } });
  }

  return out.sort((a, b) => b.priority - a.priority);
}

/** The line for the HUD: the best non-quiet suggestion that the player has not dismissed. */
export function nextSuggestion(s: GuidanceState, dismissed: string | null = null): Suggestion | null {
  return suggestions(s).find((x) => !x.quiet && x.id !== dismissed) ?? null;
}

/** The best suggestion on one person's subject (what they answer to "where next?"). */
export function suggestionFor(npc: NpcId, s: GuidanceState): Suggestion | null {
  return suggestions(s).find((x) => x.topic === TOPIC_OF[npc]) ?? null;
}

// ---------------------------------------------------------------------------
// "Something new to say"
// ---------------------------------------------------------------------------

export interface NewsItem {
  key: string;
  /** Persistent news is told once ever (per character); the rest once per game session while it stays true. */
  persist: boolean;
}

/** What each person would like to tell you now, as keys. The greeting picks its words from these (content/dialogue.ts). */
export function newsFor(npc: NpcId, s: GuidanceState): NewsItem[] {
  const out: NewsItem[] = [];
  const p = (key: string) => out.push({ key, persist: true });
  const t = (key: string) => out.push({ key, persist: false });
  if (npc === 'prior') {
    if (s.canAscend) p(`ascend:ready:${s.ascension}`);
    for (const id of BOSS_IDS) if (bossBeaten(s, id)) p(`boss:${id}:${id === 'prelate' ? s.ascension : 0}`);
    for (const a of AREA_ORDER) if (AREAS[a].unlock && s.unlocked.includes(a)) p(`seal:${a}:${s.ascension}`);
    if (s.ascension > 0) p(`rank:${s.ascension}`);
  } else if (npc === 'sexton') {
    if (s.labor && s.labor.ready > 0) t('labor:ready');
    if (s.bagSize > 0 && s.bagUsed / s.bagSize >= BAG_FULL_FRACTION) t('bag:full');
    if (s.contracts && s.contracts.open > 0) t('contracts:open');
  } else {
    if (s.dust >= GRAVE_DUST_FOR_TONIC && (s.skills.alchemy ?? 1) < 5) p('dust:first');
    if ((s.skills.alchemy ?? 1) >= 10) p('alchemy:10');
    if (isOpen(s, 'cloister')) p('reagent:cloister');
    if (isOpen(s, 'pyre')) p('reagent:pyre');
    if (isOpen(s, 'fen')) p('reagent:fen');
  }
  return out;
}

/** Where the first-kill trophies of the area bosses are kept (WorldScene.claimTrophy writes it; this reads it). */
/** The bare key: browserStorage() adds the offline edition's prefix itself. */
export const bossTrophyKey = (characterId: number) => `dm_boss_trophies_v1:${characterId}`;

export function readTrophies(storage: StorageLike | null, characterId: number): BossId[] {
  try {
    const got = JSON.parse(storage?.getItem(bossTrophyKey(characterId)) ?? '[]');
    return Array.isArray(got) ? got.filter((x): x is BossId => typeof x === 'string' && (BOSS_IDS as string[]).includes(x)) : [];
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Memory: what this character has met and heard (browser storage, per character; no server change)
// ---------------------------------------------------------------------------

export interface GuidanceMemory {
  v: 1;
  met: NpcId[];
  /** Persistent news keys and `topic:<npc>:<id>` entries already heard. */
  heard: string[];
  /** The player's own sight of the NPCs: a counsel tip fires once on first sight. */
  seen: NpcId[];
}

export const guidanceStorageKey = (characterId: number) => `dm_guidance_v1:${characterId}`;
export const emptyMemory = (): GuidanceMemory => ({ v: 1, met: [], heard: [], seen: [] });

export function loadMemory(storage: StorageLike | null, characterId: number): GuidanceMemory {
  const mem = emptyMemory();
  try {
    const raw = storage?.getItem(guidanceStorageKey(characterId));
    if (!raw) return mem;
    const v = JSON.parse(raw) as Partial<GuidanceMemory>;
    const strs = (a: unknown) => (Array.isArray(a) ? a.filter((x): x is string => typeof x === 'string') : []);
    const known = (a: unknown) => strs(a).filter((x): x is NpcId => x in NPCS);
    return { v: 1, met: known(v.met), heard: strs(v.heard), seen: known(v.seen) };
  } catch {
    return mem;
  }
}

export function saveMemory(storage: StorageLike | null, characterId: number, mem: GuidanceMemory) {
  try {
    storage?.setItem(guidanceStorageKey(characterId), JSON.stringify(mem));
  } catch {
    /* storage unavailable: the guidance just forgets next session */
  }
}

/** The Memory plus this session's "already told you" set for the non-persistent news. */
export class Guidance {
  readonly mem: GuidanceMemory;
  private session = new Set<string>();

  constructor(private characterId: number, private storage: StorageLike | null = browserStorage()) {
    this.mem = loadMemory(storage, characterId);
  }

  private save() {
    saveMemory(this.storage, this.characterId, this.mem);
  }

  met(npc: NpcId) {
    return this.mem.met.includes(npc);
  }

  /** Unheard news for one person. */
  unheard(npc: NpcId, s: GuidanceState): NewsItem[] {
    return newsFor(npc, s).filter((n) => (n.persist ? !this.mem.heard.includes(`${npc}:${n.key}`) : !this.session.has(`${npc}:${n.key}`)));
  }

  /** The "!" over their head: they have something they have not said yet. A stranger always has a welcome. */
  hasSomethingNew(npc: NpcId, s: GuidanceState): boolean {
    return !this.met(npc) || this.unheard(npc, s).length > 0;
  }

  /**
   * They talk: remember you met, and that the current news was told. A first meeting does not replay the character's whole
   * history as "news": everything already true is simply marked as known.
   */
  told(npc: NpcId, s: GuidanceState) {
    if (!this.mem.met.includes(npc)) this.mem.met.push(npc);
    for (const n of newsFor(npc, s)) {
      if (n.persist) {
        if (!this.mem.heard.includes(`${npc}:${n.key}`)) this.mem.heard.push(`${npc}:${n.key}`);
      } else this.session.add(`${npc}:${n.key}`);
    }
    this.save();
  }

  heardTopic(npc: NpcId, topic: string) {
    return this.mem.heard.includes(`topic:${npc}:${topic}`);
  }

  hearTopic(npc: NpcId, topic: string) {
    const k = `topic:${npc}:${topic}`;
    if (this.mem.heard.includes(k)) return;
    this.mem.heard.push(k);
    this.save();
  }

  /** First sight of a person (for the counsel tip). Returns true once. */
  firstSight(npc: NpcId): boolean {
    if (this.mem.seen.includes(npc)) return false;
    this.mem.seen.push(npc);
    this.save();
    return true;
  }
}
