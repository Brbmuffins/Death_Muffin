/**
 * Recorded-sample layer (CC0 Kenney sources processed by
 * tools/audio/build-combat-samples.mjs; see docs/AUDIO-SOURCES.md). Every clip is
 * optional: if a file fails to load the synthesised sound still plays alone.
 */
import type { Sfx } from './Audio';
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
};

export class SampleBank {
  private buffers = new Map<string, AudioBuffer>();
  private lastPick = new Map<Sfx, number>();
  failed = 0;

  get loaded(): number {
    return this.buffers.size;
  }

  async load(ctx: BaseAudioContext, fetchImpl: typeof fetch = fetch): Promise<void> {
    const names = new Set<string>();
    for (const spec of Object.values(SAMPLE_MAP)) spec?.files.forEach((f) => names.add(f));
    await Promise.all([...names].map(async (name) => {
      try {
        const response = await fetchImpl(new URL(`audio/combat/${name}.ogg`, document.baseURI));
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
