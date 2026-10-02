/**
 * Recorded-sample layer (CC0 Kenney sources processed by
 * tools/audio/build-combat-samples.mjs; see docs/AUDIO-SOURCES.md). Every clip is
 * optional: if a file fails to load the synthesised sound still plays alone.
 */
import type { Sfx } from './Audio';
import { BED_FILES } from './ambience';
import { pickVariant } from './mixer';

export interface SampleSpec {
  /** Basenames in public/audio/combat/ (no extension). */
  files: readonly string[];
  /** Linear gain before distance, repeat attenuation and bus. */
  gain: number;
  /**
   * `replace`: the sample is the sound, synth only if no sample loaded.
   * `layer`: sample plus a quieter synth underneath (`synthMix` of its volume).
   */
  mode: 'replace' | 'layer';
  synthMix?: number;
  /** Playback-rate multiplier and +/- random pitch spread. */
  rate?: number;
  jitter?: number;
}

const S = (files: string[], gain: number, mode: 'replace' | 'layer' = 'replace', extra: Partial<SampleSpec> = {}): SampleSpec => ({ files, gain, mode, ...extra });
const n = (base: string, count: number) => Array.from({ length: count }, (_, i) => `${base}_${i + 1}`);

/** Where a clip lives: loops in audio/ambience/, second-pass clips in audio/world/, pass-1 combat clips in audio/combat/. */
export function sampleUrl(name: string): string {
  if (name.startsWith('bed_')) return `audio/ambience/${name}.ogg`;
  if (/^(gather|rite|ui|amb)_/.test(name)) return `audio/world/${name}.ogg`;
  return `audio/combat/${name}.ogg`;
}

export const SAMPLE_MAP: Partial<Record<Sfx, SampleSpec>> = {
  needleCast: S(n('needle_cast', 3), 0.5),
  needleHit: S(n('needle_hit', 3), 0.7),
  boneHit: S(n('bone_hit', 3), 0.6),
  spear: S(n('spear', 2), 0.75, 'layer', { synthMix: 0.35 }),
  exhume: S(n('exhume', 3), 0.7, 'layer', { synthMix: 0.4 }),
  thrallRise: S(n('thrall_rise', 2), 0.75),
  mantle: S(n('thrall_rise', 2), 0.6, 'layer', { synthMix: 0.5, rate: 0.85 }),
  burst: S(n('corpse_burst', 3), 0.8, 'layer', { synthMix: 0.3 }),
  litany: S(n('litany', 2), 0.85, 'layer', { synthMix: 0.4 }),
  miasma: S(n('miasma', 2), 0.95, 'layer', { synthMix: 0.4 }),
  wail: S(n('wail', 3), 0.55, 'layer', { synthMix: 0.35 }),
  curse: S(n('wail', 3), 0.5, 'layer', { synthMix: 0.5, rate: 0.72 }),
  bloodStep: S(n('grave_step', 2), 0.65, 'layer', { synthMix: 0.4 }),
  veilRite: S(['veil_whoosh_1'], 0.5, 'layer', { synthMix: 0.5 }),
  enemyDeath: S(n('enemy_death', 3), 0.65),
  eliteDeath: S(n('elite_death', 2), 0.85, 'layer', { synthMix: 0.35 }),
  hurt: S(n('hurt', 3), 0.75, 'layer', { synthMix: 0.25 }),
  playerDeath: S(['player_death_1'], 0.8, 'layer', { synthMix: 0.4 }),
  thrallMelee: S(n('thrall_melee', 3), 0.55),
  thrallShot: S(n('thrall_shot', 2), 0.7),
  thrallMagic: S(n('thrall_magic', 2), 0.5),
  bossSlam: S(n('boss_slam', 2), 0.9, 'layer', { synthMix: 0.4 }),
  bossToll: S(n('boss_toll', 2), 0.85, 'layer', { synthMix: 0.45 }),
  bossAwaken: S(['boss_awaken_1'], 0.8, 'layer', { synthMix: 0.5 }),
  // --- second pass: necromancer rites not covered before ---
  frost: S(n('rite_frost', 2), 0.6, 'layer', { synthMix: 0.35 }),
  siphon: S(n('rite_siphon', 2), 0.55, 'layer', { synthMix: 0.3 }),
  prison: S(n('rite_prison', 2), 0.7, 'layer', { synthMix: 0.3 }),
  hands: S(n('rite_hands', 2), 0.65, 'layer', { synthMix: 0.3 }),
  storm: S(n('rite_storm', 2), 0.6, 'layer', { synthMix: 0.3 }),
  soulRelease: S(n('rite_soul', 2), 0.65, 'layer', { synthMix: 0.35 }),
  sigWall: S(['rite_wall_1'], 0.7, 'layer', { synthMix: 0.3 }),
  sigRend: S(['rite_rend_1'], 0.65, 'layer', { synthMix: 0.3 }),
  sigDirge: S(['rite_dirge_1'], 0.6, 'layer', { synthMix: 0.3 }),
  sigBloom: S(['rite_bloom_1'], 0.65, 'layer', { synthMix: 0.3 }),
  // other classes
  flail: S(n('rite_flail', 2), 0.55, 'layer', { synthMix: 0.35 }),
  chain: S(n('rite_chain', 2), 0.5, 'layer', { synthMix: 0.3 }),
  palm: S(['rite_palm_1'], 0.6, 'layer', { synthMix: 0.35 }),
  pyre: S(['rite_pyre_1'], 0.6, 'layer', { synthMix: 0.35 }),
  ward: S(['rite_ward_1'], 0.55, 'layer', { synthMix: 0.4 }),
  choir: S(['rite_choir_1'], 0.5, 'layer', { synthMix: 0.4 }),
  bloodRite: S(['rite_blood_1'], 0.55, 'layer', { synthMix: 0.35 }),
  spiritBolt: S(['rite_spirit_1'], 0.4, 'layer', { synthMix: 0.4 }),
  crow: S(n('amb_crow', 2), 0.4, 'layer', { synthMix: 0.35 }),
  // --- gathering and processing ---
  chop: S(n('gather_chop', 3), 0.42),
  pick: S(n('gather_mine', 3), 0.4),
  shovel: S(n('gather_dig', 2), 0.38),
  splash: S(n('gather_splash', 2), 0.4),
  reel: S(['gather_reel_1'], 0.45),
  sawpit: S(n('gather_saw', 2), 0.75),
  kiln: S(n('gather_kiln', 2), 0.5),
  cook: S(n('gather_cook', 2), 0.5),
  grind: S(n('gather_grind', 2), 0.55),
  craft: S(n('gather_craft', 2), 0.5),
  vaultOpen: S(['gather_vault_open_1'], 0.55),
  vaultClose: S(['gather_vault_close_1'], 0.55),
  // --- interface ---
  panelOpen: S(n('ui_open', 2), 0.45),
  panelClose: S(n('ui_close', 2), 0.4),
  equip: S(n('ui_equip', 2), 0.5),
  levelUp: S(['ui_level_1'], 0.65, 'layer', { synthMix: 0.5 }),
  lootRare: S(['ui_loot_rare_1'], 0.5),
  lootEpic: S(['ui_loot_epic_1'], 0.6),
  // --- sparse ambient details ---
  distantBell: S(n('amb_bell', 3), 0.5, 'layer', { synthMix: 0.4 }),
  waterDrip: S(n('amb_drip', 4), 0.55),
  emberCrackle: S(n('amb_ember', 3), 0.35),
  bogBubble: S(n('amb_bubble', 3), 0.5),
  crowCaw: S(n('amb_crow', 2), 0.34),
  windGust: S(n('amb_gust', 2), 0.3),
  crowdMoan: S(n('amb_moan', 2), 0.6),
  dustFall: S(n('amb_dust', 2), 0.4),
};

/** Every clip the engine may load: the sample map plus the looping beds. */
export function allSampleNames(): string[] {
  const names = new Set<string>(BED_FILES);
  for (const spec of Object.values(SAMPLE_MAP)) spec?.files.forEach((f) => names.add(f));
  return [...names];
}

export class SampleBank {
  private buffers = new Map<string, AudioBuffer>();
  private lastPick = new Map<Sfx, number>();
  failed = 0;

  get loaded(): number {
    return this.buffers.size;
  }

  has(name: string): boolean {
    return this.buffers.has(name);
  }

  buffer(name: string): AudioBuffer | undefined {
    return this.buffers.get(name);
  }

  async load(ctx: BaseAudioContext, fetchImpl: typeof fetch = fetch): Promise<void> {
    await Promise.all(allSampleNames().map(async (name) => {
      try {
        const response = await fetchImpl(new URL(sampleUrl(name), document.baseURI));
        if (!response.ok) throw new Error(String(response.status));
        this.buffers.set(name, await ctx.decodeAudioData(await response.arrayBuffer()));
      } catch {
        this.failed++; // the synthesised sound stands in
      }
    }));
  }

  /** A random loaded variant, never the same twice in a row when there is a choice. */
  pick(name: Sfx, rnd = Math.random()): { buffer: AudioBuffer; spec: SampleSpec } | null {
    const spec = SAMPLE_MAP[name];
    if (!spec) return null;
    const have = spec.files.filter((f) => this.buffers.has(f));
    if (!have.length) return null;
    const last = this.lastPick.get(name) ?? -1;
    const i = pickVariant(have.length, last, rnd);
    this.lastPick.set(name, i);
    return { buffer: this.buffers.get(have[i])!, spec };
  }
}
