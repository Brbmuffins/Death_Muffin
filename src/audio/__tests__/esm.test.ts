import { existsSync, readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { AREAS, type AreaId } from '../../../server/rules/content/areas';
import { AUDIO_MAP, AREA_SURFACE, ENEMY_VOICE, STEP_SOUND, type SoundId } from '../../content/audioMap';
import { GLOBAL_PACKS, ALL_PACKS, areaPacks, clipFile, clipsOf, keepsStart, mixBusOf, packClips, packOf, capSeconds, type Pack } from '../packs';
import { IdLimiter, partnerAudible, partnerGain, profileOf } from '../mixer';
import { SampleBank, defOf, isKept, isPartial } from '../samples';

const PUBLIC = resolve(__dirname, '../../../public');
const IDS = Object.keys(AUDIO_MAP) as SoundId[];

describe('the map and the packs', () => {
  it('puts every sound in exactly one pack and every clip in at least one', () => {
    for (const id of IDS) expect(ALL_PACKS.includes(packOf(id)) || AUDIO_MAP[id].files.length === 0, id).toBe(true);
    const seen = new Set(ALL_PACKS.flatMap((p) => packClips(p)));
    for (const id of IDS) for (const c of clipsOf(id)) expect(seen.has(c), c).toBe(true);
  });
  it('encodes every named clip to a flat .opus file that exists', () => {
    for (const id of IDS) for (const c of clipsOf(id)) {
      const f = resolve(PUBLIC, clipFile(c));
      expect(existsSync(f), f).toBe(true);
    }
    expect(clipFile('UI/Foo_Bar')).toBe('audio/esm/UI__Foo_Bar.opus');
  });
  it('keeps the download inside the budget and every clip short', () => {
    const manifest = JSON.parse(readFileSync(resolve(PUBLIC, 'audio/esm/manifest.json'), 'utf8'));
    expect(manifest.totalBytes).toBeLessThan(6 * 1024 * 1024);
    expect(manifest.clips.length).toBe(new Set(IDS.flatMap(clipsOf)).size);
    for (const c of manifest.clips) {
      expect(c.dur, c.clip).toBeLessThanOrEqual(3.01);
      expect(statSync(resolve(PUBLIC, 'audio/esm', c.file)).size).toBe(c.bytes);
    }
  });
  it('maps each area to its floor, the wading sound, its dead\'s voices and (outside the hub) the boss pack', () => {
    for (const area of Object.keys(AREAS) as AreaId[]) {
      const packs = areaPacks(area);
      expect(packs).toContain(`foot_${AREA_SURFACE[area]}`);
      expect(packs).toContain('foot_water');
      for (const e of AREAS[area].enemies) {
        const fam = ENEMY_VOICE[e.id];
        if (fam) expect(packs).toContain(`fam_${fam}`);
      }
      expect(packs.includes('boss')).toBe(!AREAS[area].safe);
    }
    // The global packs never include per-area ones, so the first fight is not waiting on a boss pack.
    for (const p of GLOBAL_PACKS) expect(p.startsWith('foot_') || p.startsWith('fam_') || p === 'boss').toBe(false);
  });
  it('lazy per-area packs are a small share of the whole', () => {
    const manifest = JSON.parse(readFileSync(resolve(PUBLIC, 'audio/esm/manifest.json'), 'utf8'));
    const bytes = (p: Pack) => manifest.packs[p]?.bytes ?? 0;
    for (const area of Object.keys(AREAS) as AreaId[]) {
      expect(areaPacks(area).reduce((n, p) => n + bytes(p), 0)).toBeLessThan(700 * 1024);
    }
  });
  it('keeps build-ups, stations and footsteps from being cut to their impact', () => {
    for (const id of ['litany', 'bossToll', 'bossTellEarth', 'stepStone', 'chop', 'waterDrip', 'miasmaLoop'] as const) expect(keepsStart(id), id).toBe(true);
    for (const id of ['needleCast', 'bossSlam', 'frost', 'corpseExplode'] as const) expect(keepsStart(id), id).toBe(false);
  });
  it('routes ids to the right mixer bus', () => {
    expect(mixBusOf('needleCast')).toBe('combat');
    expect(mixBusOf('thrallMelee')).toBe('thralls');
    expect(mixBusOf('enemyAttackBeast')).toBe('enemies');
    expect(mixBusOf('click')).toBe('ui');
    expect(mixBusOf('stepStone')).toBe('ambience');
    expect(mixBusOf('waterDrip')).toBe('ambience');
    expect(profileOf('bossTellWater').priority).toBe(AUDIO_MAP.bossTellWater.priority * 2);
    for (const id of IDS) expect(profileOf(id).dur, id).toBeGreaterThan(0);
    for (const sound of Object.values(STEP_SOUND)) expect(isKept(sound)).toBe(false);
  });
  it('flags the imperfect fits so the older sound stays underneath', () => {
    for (const id of ['toll', 'bossToll', 'crowCaw', 'waterDrip'] as const) expect(isPartial(id), id).toBe(true);
    for (const id of ['distantBell', 'windGust', 'lowHealth'] as const) expect(isKept(id), id).toBe(true);
    expect(capSeconds('bossSlam')).toBeGreaterThan(capSeconds('needleHit'));
  });
});

describe('per-id caps and cooldowns', () => {
  it('limits concurrent voices of one id and honours the cooldown', () => {
    const l = new IdLimiter();
    expect(l.request('a', 0, 1, 2, 0)).toBe(true);
    expect(l.request('a', 0.1, 1, 2, 0)).toBe(true);
    expect(l.request('a', 0.2, 1, 2, 0)).toBe(false); // two already sounding
    expect(l.request('a', 1.05, 1, 2, 0)).toBe(true); // the first has ended
    expect(l.request('b', 0, 1, 1, 0.5)).toBe(true);
    expect(l.request('b', 0.3, 1, 1, 0.5)).toBe(false); // cooldown
    expect(l.request('b', 1.1, 1, 1, 0.5)).toBe(true);
    expect(l.dropped).toBe(2);
    l.reset();
    expect(l.request('a', 0, 1, 1, 0)).toBe(true);
  });
  it('every map id has sane caps', () => {
    for (const id of IDS) {
      const d = AUDIO_MAP[id];
      expect(d.maxVoices, id).toBeGreaterThanOrEqual(1);
      expect(d.cooldownMs, id).toBeGreaterThanOrEqual(0);
      if (!isKept(id)) expect(d.volume, id).toBeGreaterThan(0);
      expect(d.volume, id).toBeLessThanOrEqual(1);
    }
  });
});

describe('partner sounds', () => {
  it('are faint, near-only, and footsteps fainter still', () => {
    expect(partnerGain('spell')).toBeLessThan(0.5);
    expect(partnerGain('step')).toBeLessThan(partnerGain('spell'));
    expect(partnerAudible(10)).toBe(true);
    expect(partnerAudible(40)).toBe(false);
  });
});

describe('lazy sample loading', () => {
  const fakeCtx = { decodeAudioData: async (b: ArrayBuffer) => ({ duration: b.byteLength / 100 }) as unknown as AudioBuffer } as unknown as BaseAudioContext;
  const urls: string[] = [];
  const fakeFetch = (async (u: URL) => {
    urls.push(String(u));
    return { ok: true, arrayBuffer: async () => new ArrayBuffer(150) };
  }) as unknown as typeof fetch;
  (globalThis as { document?: unknown }).document ??= { baseURI: 'http://x/' };

  it('loads a pack on demand, never twice, and releases it', async () => {
    const bank = new SampleBank();
    urls.length = 0;
    await bank.loadPack(fakeCtx, 'foot_stone', fakeFetch);
    const n = packClips('foot_stone').length;
    expect(urls.length).toBe(n);
    expect(bank.hasPack('foot_stone')).toBe(true);
    await bank.loadPack(fakeCtx, 'foot_stone', fakeFetch);
    expect(urls.length).toBe(n);
    expect(bank.pick('stepStone')).not.toBeNull();
    bank.releasePack('foot_stone');
    expect(bank.loaded).toBe(0);
    expect(bank.pick('stepStone')).toBeNull();
  });
  it('picks round-robin without repeating the same clip back to back', async () => {
    const bank = new SampleBank();
    await bank.loadPack(fakeCtx, 'foot_dirt', fakeFetch);
    let last = '';
    for (let i = 0; i < 40; i++) {
      const hit = bank.pick('stepDirt', (i * 0.37) % 1)!;
      expect(hit.clip).not.toBe(last);
      last = hit.clip;
    }
    expect(defOf('stepDirt')!.files.length).toBeGreaterThan(1);
  });
  it('keeps a clip two packs share until both are released', async () => {
    const bank = new SampleBank();
    const shared = [...new Set(ALL_PACKS.flatMap((p) => packClips(p).map((c) => [c, p] as const)).filter(([c], _i, all) => all.filter(([d]) => d === c).length > 1).map(([c]) => c))][0];
    if (!shared) return;
    const owners = ALL_PACKS.filter((p) => packClips(p).includes(shared));
    for (const p of owners) await bank.loadPack(fakeCtx, p, fakeFetch);
    bank.releasePack(owners[0]);
    expect(bank.has(shared)).toBe(true);
    for (const p of owners.slice(1)) bank.releasePack(p);
    expect(bank.has(shared)).toBe(false);
  });
  it('counts failures and carries on', async () => {
    const bank = new SampleBank();
    const bad = (async () => ({ ok: false })) as unknown as typeof fetch;
    await bank.loadPack(fakeCtx, 'foot_water', bad);
    expect(bank.failed).toBe(packClips('foot_water').length);
    expect(bank.pick('stepWater')).toBeNull();
  });
});
