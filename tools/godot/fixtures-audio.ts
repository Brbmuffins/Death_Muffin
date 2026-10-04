/**
 * Golden fixtures for godot/audio, generated FROM the TypeScript (src/audio/*).
 * Run: npx vite-node tools/godot/fixtures-audio.ts   ->  godot/tests/audio/fixtures/*.json  (small: committed)
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { AUDIO_MAP, type SoundId } from '../../src/content/audioMap';
import { AREAS } from '../../src/content/areas';
import {
  BUS_IDS, BUS_CAP, PROFILES, profileOf, sliderGain, busGain, masterGain, distanceGain, culled, panFor, repeatGain, repeatDropped,
  effectiveCap, pickVariant, activityWeight, CombatActivity, bedDuckGain, accentsAllowed, lootSfx, VoiceLimiter, IdLimiter, WindowCounter,
  type BusId,
} from '../../src/audio/mixer';
import { packOf, capSeconds, keepsStart, mixBusOf, clipsOf, areaPacks, ALL_PACKS, packClips, clipFile, isKeep } from '../../src/audio/packs';
import { ZONE_BEDS, ZONE_ACCENTS, accentGap, pickAccent } from '../../src/audio/ambience';
import { FootstepTracker } from '../../src/audio/footsteps';
import { gatherSfx } from '../../src/audio/gatherSfx';
import { MUSIC_FOR_AREA } from '../../src/audio/music';
import { LEGACY, legacyUrl, legacyNames } from '../../src/audio/samples';

const out = 'godot/tests/audio/fixtures';
mkdirSync(out, { recursive: true });
const w = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v) + '\n');

const R = mulberry32(20261005);
const rint = (lo: number, hi: number) => lo + Math.floor(R() * (hi - lo + 1));
const rpick = <T>(l: readonly T[]): T => l[Math.floor(R() * l.length)];
const areaIds = Object.keys(AREAS);
const ids = Object.keys(AUDIO_MAP) as SoundId[];
const buses = [...BUS_IDS];

// ── mixer maths ──
{
  const sliders = [0, 0.05, 0.1, 0.25, 0.3333, 0.5, 0.6, 0.75, 0.85, 0.9, 1, -0.5, 1.5, 7];
  const settings = Array.from({ length: 60 }, () => ({ volume: R(), combatVolume: R(), ambienceVolume: R(), musicVolume: R(), interfaceVolume: R() }));
  settings.push({ volume: 0.6, combatVolume: 1, ambienceVolume: 1, musicVolume: 0.85, interfaceVolume: 1 }, { volume: 0, combatVolume: 0, ambienceVolume: 0, musicVolume: 0, interfaceVolume: 0 });
  w('mix_gain', {
    slider: sliders.map((v) => ({ v, g: sliderGain(v) })),
    bus: settings.flatMap((s) => [...buses.map((b) => ({ s, bus: b, g: busGain(b, s) })), { s, bus: 'master', g: masterGain(s) }]),
  });
  const dists = [0, 0.5, 1, 3, 6, 7.5, 9, 14, 20, 25.9, 26.1, 33.9, 34.1, 40, 59.9, 60.1, 100];
  w('mix_distance', {
    gain: buses.flatMap((b) => dists.map((d) => ({ bus: b, d, g: distanceGain(d, b) }))),
    culled: buses.flatMap((b) => dists.flatMap((d) => [0, 2, 5, 8, 9, 10].map((p) => ({ bus: b, d, p, c: culled(d, b, p) })))),
    pan: [-40, -14, -7, -1, 0, 3, 14, 20, 100].map((dx) => ({ dx, p: panFor(dx) })),
  });
  w('mix_repeat', {
    gain: Array.from({ length: 10 }, (_, n) => ({ n, g: repeatGain(n) })),
    drop: Array.from({ length: 10 }, (_, n) => [0, 5, 8, 9, 10].map((p) => ({ n, p, d: repeatDropped(n, p) }))).flat(),
    cap: buses.flatMap((b) => Array.from({ length: 11 }, (_, p) => ({ bus: b, p, cap: effectiveCap(b, p), base: BUS_CAP[b] }))),
  });
  w('mix_pick_variant', Array.from({ length: 400 }, () => {
    const count = rint(1, 6);
    return { count, last: rint(-1, count - 1), rnd: R(), v: 0 };
  }).map((c) => ({ ...c, v: pickVariant(c.count, c.last, c.rnd) })));
  w('mix_loot', [[], ['common'], ['uncommon', 'rare'], ['epic', 'rare'], ['legendary', 'epic'], ['common', 'legendary']].map((r) => ({ r, s: lootSfx(r) })));
  const act = new CombatActivity();
  const steps: unknown[] = [];
  let t = 0;
  for (let i = 0; i < 80; i++) {
    t += R() * 1.5;
    const b = rpick(buses);
    const p = rint(0, 10);
    const weight = activityWeight(b, p);
    if (R() < 0.6) act.bump(t, weight);
    steps.push({ t, bus: b, p, weight, level: act.level(t), bed: bedDuckGain(act.level(t)), accents: accentsAllowed(act.level(t)) });
  }
  w('mix_activity', steps);
}

// ── profiles (bus, priority, duration, thinning, duck) for every id ──
{
  const names = [...new Set([...Object.keys(PROFILES), ...ids, 'nonexistentSound'])];
  w('profiles', names.map((n) => {
    const p = profileOf(n as never);
    return { n, bus: p.bus, priority: p.priority, dur: p.dur, thin: p.thin ?? null, duck: p.duck ?? null };
  }));
}

// ── limiters on scripted event streams ──
{
  const vl = new VoiceLimiter();
  const ops: unknown[] = [];
  let t = 0;
  for (let i = 0; i < 600; i++) {
    t += R() * 0.08;
    const bus = rpick(buses);
    const priority = rint(0, 10);
    const dur = 0.2 + R() * 3;
    const r = vl.request(bus, priority, t, dur);
    ops.push({ bus, priority, now: t, dur, ok: r.ok, reason: r.ok ? '' : r.reason, active: vl.active(bus, t), total: vl.total(t) });
  }
  const il = new IdLimiter();
  const idOps: unknown[] = [];
  const idList = ['a', 'b', 'c', 'd'];
  t = 0;
  for (let i = 0; i < 400; i++) {
    t += R() * 0.2;
    const id = rpick(idList);
    const dur = 0.1 + R() * 1.5;
    const maxVoices = rint(1, 4);
    const cooldown = R() < 0.4 ? 0 : R() * 0.3;
    idOps.push({ id, now: t, dur, maxVoices, cooldown, ok: il.request(id, t, dur, maxVoices, cooldown), dropped: il.dropped });
  }
  const wc = new WindowCounter();
  const wOps: unknown[] = [];
  t = 0;
  for (let i = 0; i < 300; i++) {
    t += R() * 0.1;
    const key = rpick(['x', 'y']);
    const window = rpick([0.1, 0.15, 0.5]);
    const count = wc.count(key, t, window);
    const added = R() < 0.7;
    if (added) wc.add(key, t);
    wOps.push({ key, now: t, window, count, added });
  }
  w('limiters', { voice: ops, id: idOps, window: wOps, dropped: vl.dropped, droppedByBus: vl.droppedByBus, peak: vl.peak });
}

// ── packs / map-derived rules ──
{
  w('packs', {
    ids: ids.map((id) => ({
      id, pack: packOf(id), cap: capSeconds(id), capLayer: capSeconds(id, true), keepsStart: keepsStart(id), mixBus: mixBusOf(id), clips: clipsOf(id), keep: isKeep(id),
    })),
    all: ALL_PACKS,
    byPack: Object.fromEntries(ALL_PACKS.map((p) => [p, [...packClips(p)].sort()])),
    areas: Object.fromEntries(areaIds.map((a) => [a, areaPacks(a as never)])),
    clipFileSample: ids.slice(0, 20).flatMap((id) => clipsOf(id).slice(0, 1)).map((c) => ({ c, f: clipFile(c) })),
  });
  w('legacy', { LEGACY, names: legacyNames(), urls: legacyNames().map((n) => ({ n, u: legacyUrl(n) })) });
}

// ── ambience ──
{
  w('ambience', {
    beds: ZONE_BEDS,
    accents: ZONE_ACCENTS,
    gap: areaIds.flatMap((a) => Array.from({ length: 12 }, () => { const r = R(); return { a, r, v: accentGap(a as never, r) }; })),
    pick: areaIds.flatMap((a) => Array.from({ length: 30 }, () => { const r = R(); return { a, r, v: pickAccent(a as never, r) }; })),
    music: MUSIC_FOR_AREA,
  });
}

// ── footsteps: a random walk with a phase that sometimes drops out ──
{
  const runs: unknown[] = [];
  for (let k = 0; k < 20; k++) {
    const ft = new FootstepTracker();
    const frames: unknown[] = [];
    let phase = R();
    let x = 0;
    let z = 0;
    let noPhase = false;
    for (let i = 0; i < 120; i++) {
      if (R() < 0.04) noPhase = !noPhase;
      const reset = R() < 0.02;
      if (reset) ft.reset();
      phase = (phase + 0.01 + R() * 0.06) % 1;
      x += (R() - 0.3) * 0.5;
      z += (R() - 0.5) * 0.5;
      const ph = noPhase ? null : phase;
      frames.push({ reset, phase: ph, x, z, step: ft.step(ph, x, z) });
    }
    runs.push(frames);
  }
  w('footsteps', runs);
}

// ── gather sfx ──
{
  const skills = ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening', 'alchemy', 'salvaging', 'cooking', 'nonsense'];
  const kinds = [undefined, 'seam', 'herb', 'tree', 'rock'];
  w('gather_sfx', skills.flatMap((s) => kinds.map((k) => ({ s, k: k ?? '', v: gatherSfx(s, k as never) }))));
}
console.log('audio fixtures written');
