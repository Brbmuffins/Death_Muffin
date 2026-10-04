/**
 * Recorded-sample layer. The event -> clip table is `AUDIO_MAP` (src/content/audioMap.ts, the ESM Fantasy Game pack, owner
 * licence, see docs/AUDIO-SOURCES.md); the clips are encoded by tools/audio/build-esm.mjs into public/audio/esm/ and loaded
 * lazily by pack (./packs): core first, the area's footsteps / enemy voices / boss moments when the area is entered, and
 * released again two areas later. A few sounds keep an older clip (`LEGACY`: the bells and generated accents, because the pack
 * has no bells, wind or crows), and every clip is optional: the synthesised sound plays alone if one fails to load.
 */
import type { Sfx } from './Audio';
import { BED_FILES } from './ambience';
import { pickVariant } from './mixer';
import { AUDIO_MAP, type SoundDef, type SoundId } from '../content/audioMap';
import { clipFile, packClips, type Pack } from './packs';

/** Older clips that stay: Kenney bells (the pack has no bell) and generated accents (no wind / crow / moan in the pack). */
export interface LegacySpec {
  files: readonly string[];
  gain: number;
  rate?: number;
  jitter?: number;
  /** Share of the synthesised sound kept under the clip. */
  synthMix: number;
}
const n = (base: string, count: number) => Array.from({ length: count }, (_, i) => `${base}_${i + 1}`);
export const LEGACY: Partial<Record<Sfx, LegacySpec>> = {
  bossToll: { files: n('boss_toll', 2), gain: 0.85, synthMix: 0.45 },
  distantBell: { files: n('amb_bell', 3), gain: 0.5, synthMix: 0.4 },
  windGust: { files: n('amb_gust', 2), gain: 0.3, synthMix: 0 },
  emberCrackle: { files: n('amb_ember', 3), gain: 0.35, synthMix: 0 },
  crowCaw: { files: n('amb_crow', 2), gain: 0.34, synthMix: 0.35 },
  crow: { files: n('amb_crow', 2), gain: 0.4, synthMix: 0.35 },
  crowdMoan: { files: n('amb_moan', 2), gain: 0.5, synthMix: 0 },
};

/** Where an older clip lives: loops in audio/ambience/, the rest in audio/combat/ or audio/world/. */
export function legacyUrl(name: string): string {
  if (name.startsWith('bed_')) return `audio/ambience/${name}.ogg`;
  if (name.startsWith('amb_')) return `audio/world/${name}.ogg`;
  return `audio/combat/${name}.ogg`;
}

export function legacyNames(): string[] {
  const names = new Set<string>(BED_FILES);
  for (const spec of Object.values(LEGACY)) spec?.files.forEach((f) => names.add(f));
  return [...names];
}

export const hasDef = (name: string): name is SoundId => name in AUDIO_MAP;
export const defOf = (name: Sfx): SoundDef | undefined => (hasDef(name) ? AUDIO_MAP[name] : undefined);
/** True when the map has no pack clip for this id (status keep): the older sound stays as it is. */
export const isKept = (name: Sfx): boolean => {
  const def = defOf(name);
  return !def || def.status === 'keep' || def.files.length === 0;
};
/** True when a pack clip is used but the fit is imperfect: the older sound stays underneath. */
export const isPartial = (name: Sfx): boolean => defOf(name)?.status === 'partial';

export type Fetcher = typeof fetch;

export class SampleBank {
  /** Decoded clips by name (pack names are `folder/clip`, older ones their file stem). */
  private buffers = new Map<string, AudioBuffer>();
  private lastPick = new Map<string, number>();
  /** Which loaded packs hold a clip, so a clip two packs share stays until both are released. */
  private owners = new Map<string, Set<Pack | 'legacy'>>();
  private packs = new Set<Pack>();
  private pending = new Map<string, Promise<void>>();
  failed = 0;
  /** Clips decoded, failed or still in flight (released clips drop out). */
  get requested(): number {
    return this.buffers.size + this.failed + this.pending.size;
  }

  get loaded(): number {
    return this.buffers.size;
  }
  has(name: string): boolean {
    return this.buffers.has(name);
  }
  buffer(name: string): AudioBuffer | undefined {
    return this.buffers.get(name);
  }
  hasPack(pack: Pack): boolean {
    return this.packs.has(pack);
  }
  loadedPacks(): Pack[] {
    return [...this.packs];
  }

  private async fetchOne(ctx: BaseAudioContext, name: string, url: string, fetchImpl: Fetcher): Promise<void> {
    if (this.buffers.has(name)) return;
    let p = this.pending.get(name);
    if (!p) {
      p = (async () => {
        try {
          const response = await fetchImpl(new URL(url, document.baseURI));
          if (!response.ok) throw new Error(String(response.status));
          this.buffers.set(name, await ctx.decodeAudioData(await response.arrayBuffer()));
        } catch {
          this.failed++; // the synthesised sound stands in
        } finally {
          this.pending.delete(name);
        }
      })();
      this.pending.set(name, p);
    }
    await p;
  }

  /** Load the older kept clips and the zone beds (small, always wanted). */
  async loadLegacy(ctx: BaseAudioContext, fetchImpl: Fetcher = fetch): Promise<void> {
    await Promise.all(legacyNames().map(async (name) => {
      await this.fetchOne(ctx, name, legacyUrl(name), fetchImpl);
      this.own(name, 'legacy');
    }));
  }

  private own(name: string, owner: Pack | 'legacy') {
    let s = this.owners.get(name);
    if (!s) this.owners.set(name, (s = new Set()));
    s.add(owner);
  }

  /** Fetch and decode every clip of a pack (several at once: decoding runs off the main thread). */
  async loadPack(ctx: BaseAudioContext, pack: Pack, fetchImpl: Fetcher = fetch): Promise<void> {
    if (this.packs.has(pack)) return;
    this.packs.add(pack);
    await Promise.all(packClips(pack).map(async (name) => {
      this.own(name, pack);
      await this.fetchOne(ctx, name, clipFile(name), fetchImpl);
    }));
  }

  /** Drop a pack's decoded audio (clips another loaded pack still owns stay). */
  releasePack(pack: Pack) {
    if (!this.packs.delete(pack)) return;
    for (const name of packClips(pack)) {
      const o = this.owners.get(name);
      o?.delete(pack);
      if (!o || o.size === 0) {
        this.owners.delete(name);
        this.buffers.delete(name);
      }
    }
  }

  /** A random loaded variant of a sound, never the same twice in a row when there is a choice. */
  pick(name: Sfx, rnd = Math.random()): { buffer: AudioBuffer; clip: string; def: SoundDef } | null {
    const def = defOf(name);
    if (!def || def.files.length === 0) return null;
    const have = def.files.filter((f) => this.buffers.has(f));
    if (!have.length) return null;
    const last = this.lastPick.get(name) ?? -1;
    const i = pickVariant(have.length, last, rnd);
    this.lastPick.set(name, i);
    return { buffer: this.buffers.get(have[i])!, clip: have[i], def };
  }

  pickLayer(name: Sfx, rnd = Math.random()): AudioBuffer | null {
    const files = defOf(name)?.layer?.files.filter((f) => this.buffers.has(f));
    if (!files?.length) return null;
    return this.buffers.get(files[Math.min(files.length - 1, Math.floor(rnd * files.length))])!;
  }

  /** A random loaded older clip for a sound that keeps one (the bells, the generated accents). */
  pickLegacy(name: Sfx, rnd = Math.random()): { buffer: AudioBuffer; spec: LegacySpec } | null {
    const spec = LEGACY[name];
    if (!spec) return null;
    const have = spec.files.filter((f) => this.buffers.has(f));
    if (!have.length) return null;
    const key = `legacy:${name}`;
    const i = pickVariant(have.length, this.lastPick.get(key) ?? -1, rnd);
    this.lastPick.set(key, i);
    return { buffer: this.buffers.get(have[i])!, spec };
  }
}
