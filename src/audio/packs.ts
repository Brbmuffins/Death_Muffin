/**
 * Lazy-load groups for the recorded layer. Pure data and rules (no WebAudio), shared by the engine, the unit tests and
 * the encoder (tools/audio/build-esm.mjs), so the files that ship are exactly the clips some pack names.
 *
 * Groups: `core` (hits, hurt, thralls, deaths), `ui` (interface, loot, pickups), `rites` (every rite), `world` (gathering,
 * crafting, doors, stations), `amb` (sparse area accents) load once; `boss`, `foot_<surface>` and `fam_<voice>` load per
 * area and are released again two areas later, so decoded audio stays small.
 */
import { AUDIO_MAP, AREA_SURFACE, ENEMY_VOICE, EXISTING_SOUND_IDS, type SoundId, type Surface, type VoiceFamily } from '../content/audioMap';
import type { AreaId } from '../content/areas';
import { AREAS } from '../content/areas';
import type { BusId } from './mixer';

export type Pack =
  | 'core' | 'ui' | 'rites' | 'world' | 'amb' | 'boss'
  | `foot_${Surface}` | `fam_${VoiceFamily}`;

const set = (s: string) => new Set(s.split(/\s+/).filter(Boolean));

const CORE = set('needleCast needleHit boneHit thrallMelee thrallShot thrallMagic thrallDeath hurt playerDeath enemyDeath');
const RITES = set(`needleCast needleHit boneHit spear exhume thrallRise miasma litany wail bloodStep frost mantle siphon prison hands storm
  soulRelease sigWall sigRend sigDirge sigBloom curse raise burst flail lantern chain pyre ward palm choir crow bloodRite veilRite spiritBolt
  rotLance boneFan ivoryCleave hollowCut veilStep rallyDead carrionSeed seedBurst graveOffering corpseExplode shieldBash graveSlam
  graveSlamLand bulwarkRaise bulwarkBlock oathUnbroken corpseVigil graveBrand thrallDeath thrallBind miasmaLoop siphonLoop handsLoop
  boneStormLoop dirgeLoop bloomPulse crowSwarmLoop thrallMelee thrallShot thrallMagic hurt playerDeath enemyDeath`);
const BOSS = set(`bossToll bossSlam bossAwaken bossDefeat bossTell bossTellEarth bossTellWater bossTellRot bossTellFire bossPhase bossSummon
  nicheBreak slagSlam emberBurst emberThrow eliteDeath toll tollSmall wave surgeStart surgeCleared surgeFailed affixTell eliteAggro tellStrike`);
const WORLD = set(`chop pick splash shovel reel sawpit kiln cook grind craft pickOre gatherHerb nodeDepleted gardenTend gardenPlant
  gardenHarvest gardenReady brewTick brewCraft craftWeapon craftArmor craftMagic forgeFire chestOpen vaultOpen vaultClose gate waystoneTravel
  recallStart recallCancel runeSocket drinkFlask drinkElixir eatMeal lootDrop lootDropRare lootDropEpic lootDropLegendary goldPileDrop`);

/** Sounds whose build-up IS the sound: the encoder keeps their start instead of skipping to the impact. */
const BUILDUP = set(`litany oathUnbroken playerDeath bossAwaken bossPhase bossDefeat bossSummon bossToll bossTell bossTellEarth bossTellWater
  bossTellRot bossTellFire toll tollSmall surgeStart surgeCleared surgeFailed waystoneTravel recallStart levelUp skillUp lootLegendary
  lootDropLegendary wave eliteAggro tellStrike affixTell eliteDeath`);

const VOICE_ID = /^(enemyAttack|enemyDeath)(Beast|Humanoid|Brute|Spirit)$/;

export function packOf(id: SoundId): Pack {
  const m = VOICE_ID.exec(id);
  if (m) return `fam_${m[2].toLowerCase() as VoiceFamily}`;
  if (id === 'step') return 'foot_stone';
  if (id.startsWith('step')) return `foot_${id.slice(4).toLowerCase() as Surface}`;
  if (BOSS.has(id)) return 'boss';
  if (WORLD.has(id)) return 'world';
  const def = AUDIO_MAP[id];
  if (def.bus === 'ambience') return 'amb';
  if (CORE.has(id)) return 'core';
  if (RITES.has(id)) return 'rites';
  if (def.bus === 'ui') return 'ui';
  return 'core';
}

/**
 * Longest audible length (s) of an id's clip: the encoder cuts the file to the longest of its users, and the engine fades
 * each id out at its own cap, so a clip shared between a fast-repeat hit and a boss moment is long on disk but short in play.
 * Decoded audio costs memory (192 KB per second per clip), so everything is capped.
 */
export function capSeconds(id: SoundId, layer = false): number {
  const def = AUDIO_MAP[id];
  if (def.trim?.maxMs) return ((def.trim.startMs ?? 0) + def.trim.maxMs) / 1000;
  if (id.startsWith('step')) return 0.45;
  if (def.loopMs) return 1.0;
  if (def.bus === 'ambience') return 1.2;
  if (def.bus === 'ui') return def.priority >= 3 ? 1.4 : 0.9;
  if (def.priority >= 5 || packOf(id) === 'boss') return 2.6;
  if (def.bus === 'voice') return 1.5;
  return layer ? 1.5 : 1.3;
}

/** The encoder does not skip into the clip for these (stations, ambience, footsteps, loops, build-ups). */
export function keepsStart(id: SoundId): boolean {
  const def = AUDIO_MAP[id];
  return BUILDUP.has(id) || def.bus === 'ambience' || def.loopMs !== undefined || id.startsWith('step') || WORLD.has(id) && !id.startsWith('lootDrop');
}

/** Mixer bus an id plays on (the map's sfx / voice / ui / ambience, split the way mixer.ts PROFILES split them). */
export function mixBusOf(id: SoundId): BusId {
  const def = AUDIO_MAP[id];
  if (def.bus === 'ui') return 'ui';
  if (def.bus === 'ambience' || id.startsWith('step')) return 'ambience';
  if (id.startsWith('thrall') && id !== 'thrallRise') return 'thralls';
  if (def.bus === 'voice' || VOICE_ID.test(id) || BOSS.has(id) && !id.startsWith('boss') && id !== 'slagSlam' && id !== 'eliteDeath' && id !== 'emberBurst' && id !== 'emberThrow') return 'enemies';
  if (id === 'eliteDeath' || id === 'slagSlam' || id === 'emberBurst' || id === 'emberThrow' || id === 'enemyDeath' || id === 'tellStrike') return 'enemies';
  return 'combat';
}

/** Clip names (the map's `folder/name`) one id may play, layers included. */
export function clipsOf(id: SoundId): string[] {
  const def = AUDIO_MAP[id];
  return [...def.files, ...(def.layer?.files ?? [])];
}

const byPack = new Map<Pack, Set<string>>();
for (const id of Object.keys(AUDIO_MAP) as SoundId[]) {
  const pack = packOf(id);
  let s = byPack.get(pack);
  if (!s) byPack.set(pack, (s = new Set()));
  clipsOf(id).forEach((c) => s.add(c));
}
export const ALL_PACKS = [...byPack.keys()].sort();
export function packClips(pack: Pack): readonly string[] {
  return [...(byPack.get(pack) ?? [])];
}

/** Loaded once, at the first world entry (in this order: the first fight needs core before the rest). */
export const GLOBAL_PACKS: readonly Pack[] = ['core', 'ui', 'rites', 'world', 'amb'];

/** Packs one area adds: its floor, the wading sound, its dead's voices and (outside the hub) the boss moments. */
export function areaPacks(area: AreaId): Pack[] {
  const out = new Set<Pack>([`foot_${AREA_SURFACE[area]}`, 'foot_water']);
  for (const e of AREAS[area].enemies) {
    const fam = ENEMY_VOICE[e.id];
    if (fam) out.add(`fam_${fam}`);
  }
  if (!AREAS[area].safe) out.add('boss');
  return [...out];
}

/** The clip file under public/audio/esm/ (flat; the pack folders are logical, so a clip two groups use is encoded once). */
export function clipFile(name: string): string {
  return `audio/esm/${name.replace(/\//g, '__')}.opus`;
}

/** Ids of the map that the recorded layer cannot supply (status keep) or only partly: the engine keeps the old sound too. */
export function isKeep(id: SoundId): boolean {
  return AUDIO_MAP[id].status === 'keep' || AUDIO_MAP[id].files.length === 0;
}
export const LEGACY_IDS: readonly string[] = EXISTING_SOUND_IDS;
