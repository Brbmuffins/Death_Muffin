import { AREAS, type AreaId } from '../content/areas';
import { AREA_RUNE_POOL } from '../content/runes';
import { fx } from './fxTextures';
import { FX_PRESETS } from './binbun/presets';
import type { BinbunFX } from './binbun/BinbunFX';
import type { LootView } from './LootView';
import { runIdleSequence, warmObjects } from './warmModel';

/**
 * Ambient world looping effects (fires, candles, fog, portals): the ones near the spawn draw from the start, but every other room's loopers
 * sit culled (Binbun hides loopers off screen) and compile their shader the first frame the player walks in view of them: a hitch at the
 * arch. Warm them first: the first thing a new player does is walk through the neighbouring rooms.
 */
const AMBIENT = new Set(['interact_rim', 'altar_beacon', 'waystone_portal', 'brazier_fire', 'chapterhouse_candle', 'bonfire', 'kiln_fire', 'nave_fog', 'area_gate']);
/** Reward and most common combat effects first, so what the first minute of play touches is warm earliest. */
const FX_FIRST = ['loot_rare', 'loot_epic', 'soul_orb', 'needle_hit', 'crit_hit', 'thrall_rise', 'exhume_lift', 'corpse_explosion', 'levelup_pillar'];

const warmedFx = new WeakMap<BinbunFX, Set<string>>();
let fxTexturesDone = false;

/**
 * Everything that can load, compile or upload for the first time in the middle of a fight, warmed one piece per idle
 * turn at area entry (see `runIdleSequence`): the procedural FX textures (canvas-drawn on first use), Binbun effects
 * (template parse, noise textures baked, shader programs, uploads), the loot kit and the area's loot icons.
 * Returns a cancel function. Each piece is done once per session.
 */
export function warmColdPaths(o: { area: AreaId; binbun: BinbunFX; loot: LootView }): () => void {
  const tasks: (() => Promise<unknown>)[] = [];
  const itemIds = [...AREAS[o.area].loot.map((l) => l.item), ...(AREA_RUNE_POOL[o.area] ?? [])];
  tasks.push(...o.loot.warmTasks(itemIds));
  if (!fxTexturesDone) {
    fxTexturesDone = true;
    for (const make of Object.values(fx)) tasks.push(() => warmObjects([], [make()]));
  }
  if (o.binbun.enabled) {
    let done = warmedFx.get(o.binbun);
    if (!done) warmedFx.set(o.binbun, (done = new Set()));
    const all = [...new Set([...FX_FIRST, ...Object.keys(FX_PRESETS)])];
    const ids = [...all.filter((id) => AMBIENT.has(id)), ...all.filter((id) => !AMBIENT.has(id))];
    for (const id of ids) {
      if (done.has(id)) continue;
      done.add(id);
      tasks.push(() => o.binbun.warm(id as never, (objs) => warmObjects(objs)));
    }
  }
  return runIdleSequence(tasks);
}
