import { onSettingsChange, settings } from '../app/settings';
import type { AreaId } from '../content/areas';
import {
  BUS_IDS, CombatActivity, IdLimiter, REPEAT_WINDOW, VoiceLimiter, WindowCounter, accentsAllowed, activityWeight, bedDuckGain, busGain,
  distanceGain, culled, masterGain, panFor, partnerAudible, partnerGain, profileOf, repeatDropped, repeatGain, type BusId, type Duck,
} from './mixer';
import { LOOP_TRIM, ZONE_BEDS, accentGap, bedReady, pickAccent } from './ambience';
import { SampleBank, defOf, isKept, isPartial, type LegacySpec } from './samples';
import { GLOBAL_PACKS, areaPacks, capSeconds, type Pack } from './packs';
import { AUDIO_MAP, type SoundDef, type SoundId } from '../content/audioMap';

/**
 * Procedural sound with a recorded-sample layer (CC0, `public/audio/combat/`) on
 * the important combat sounds. Everything is routed through five buses
 * (combat, enemies, thralls, ui, ambience) with per-bus voice caps, repeat
 * attenuation, distance falloff and ducking; the rules are pure functions in
 * `./mixer`. Positional sounds are panned relative to the listener (the hero).
 * The context starts on the first user gesture, as browsers require.
 */
export type Sfx =
  | SoundId
  | 'needleCast'
  | 'needleHit'
  | 'spear'
  | 'exhume'
  | 'thrallRise'
  | 'miasma'
  | 'litany'
  | 'boneHit'
  | 'enemyDeath'
  | 'eliteDeath'
  | 'hurt'
  | 'thrallMelee'
  | 'thrallShot'
  | 'thrallMagic'
  | 'playerDeath'
  | 'toll'
  | 'tollSmall'
  | 'curse'
  | 'raise'
  | 'burst'
  | 'emberBurst'
  | 'emberCrackle'
  | 'chainTier'
  | 'chainBreak'
  | 'emberThrow'
  | 'slagSlam'
  | 'coin'
  | 'shard'
  | 'item'
  | 'levelUp'
  | 'gate'
  | 'click'
  | 'buy'
  | 'wave'
  | 'bossToll'
  | 'bossSlam'
  | 'bossAwaken'
  | 'bossDefeat'
  | 'step'
  | 'error'
  // Gathering (roadmap §7): one light sound per work cycle, and a skill level-up.
  | 'chop'
  | 'pick'
  | 'splash'
  | 'shovel'
  | 'skillUp'
  // Grimoire rites.
  | 'wail'
  | 'bloodStep'
  | 'frost'
  | 'mantle'
  // New Blood: distinct materials and gestures for the four newer families.
  | 'flail'
  | 'lantern'
  | 'chain'
  | 'pyre'
  | 'ward'
  | 'palm'
  | 'choir'
  | 'crow'
  | 'bloodRite'
  | 'veilRite'
  | 'spiritBolt'
  // Sparse environmental detail between combat sounds.
  | 'distantBell'
  | 'graveCreak'
  | 'waterDrip'
  | 'bogBubble'
  | 'crowCaw'
  | 'windGust'
  | 'crowdMoan'
  | 'dustFall'
  // Processing stations and the Vault (second pass).
  | 'reel'
  | 'sawpit'
  | 'kiln'
  | 'cook'
  | 'grind'
  | 'craft'
  | 'vaultOpen'
  | 'vaultClose'
  // More rites.
  | 'siphon'
  | 'prison'
  | 'hands'
  | 'storm'
  | 'soulRelease'
  | 'sigWall'
  | 'sigRend'
  | 'sigDirge'
  | 'sigBloom'
  // Interface.
  | 'panelOpen'
  | 'panelClose'
  | 'equip'
  | 'lootRare'
  | 'lootEpic';

const MIN_GAP: Partial<Record<Sfx, number>> = {
  needleHit: 0.04,
  boneHit: 0.05,
  emberBurst: 0.07,
  emberCrackle: 0.05,
  chainTier: 0.3,
  chainBreak: 0.5,
  emberThrow: 0.15,
  slagSlam: 0.2,
  enemyDeath: 0.06,
  coin: 0.05,
  hurt: 0.12,
  step: 0.2,
  wail: 0.08,
  tollSmall: 0.25,
  wave: 0.8,
  flail: 0.12,
  palm: 0.12,
  crow: 0.35,
  distantBell: 3,
  graveCreak: 3,
  waterDrip: 0.5,
  panelOpen: 0.08,
  panelClose: 0.08,
  equip: 0.15,
  lootRare: 0.4,
  lootEpic: 0.8,
  reel: 0.3,
  craft: 0.2,
  crowCaw: 4,
  windGust: 6,
  crowdMoan: 6,
  bogBubble: 0.6,
  dustFall: 1.5,
};

/** Safety net on raw audio nodes; the real limits are the per-bus caps in mixer.ts. */
const MAX_VOICES = 110;

class AudioEngine {
  private ctx: AudioContext | null = null;
  private master!: GainNode;
  private buses = {} as Record<BusId, { dry: GainNode; wet: GainNode; dkDry: GainNode; dkWet: GainNode; hub: GainNode }>;
  private bedGain!: GainNode;
  /** Zone beds pass through this so a fight can pull them down; the boss drum bypasses it. */
  private bedDuck!: GainNode;
  private activity = new CombatActivity();
  private lastDuckApply = -1;
  private duckTimer: ReturnType<typeof setInterval> | null = null;
  private busMeters: { id: BusId; node: AnalyserNode; buf: Float32Array<ArrayBuffer> }[] = [];
  private busPeak = Object.fromEntries(BUS_IDS.map((id) => [id, 0])) as Record<BusId, number>;
  private busSq = Object.fromEntries(BUS_IDS.map((id) => [id, 0])) as Record<BusId, number>;
  private busTicks = 0;
  private verb!: ConvolverNode;
  private verbSend!: GainNode;
  private noise!: AudioBuffer;
  private brown!: AudioBuffer;
  private samples = new SampleBank();
  private idLimiter = new IdLimiter();
  private packQueue: Promise<void> = Promise.resolve();
  private areaTrail: AreaId[] = [];
  /** Set around a remote player's events (WorldScene.handleEvent): their sounds are quieter, near-only and capped. */
  partner = false;
  private partnerWin = new WindowCounter();
  private voices = 0;
  private limiter = new VoiceLimiter();
  private repeats = new WindowCounter();
  private thin = new WindowCounter();
  private duckState = { depth: 0, until: 0 };
  private played = 0;
  private dropReasons = { far: 0, repeat: 0, thin: 0, bus: 0, global: 0, gap: 0, id: 0, partner: 0 };
  private duckCount = 0;
  private sampleHits = 0;
  private analysers: { node: AnalyserNode; buf: Float32Array<ArrayBuffer>; pre: boolean }[] = [];
  private peakOut = 0;
  private peakPre = 0;
  /** Mix context for the sound being started right now (play() is synchronous). */
  private cur = { bus: 'combat' as BusId, gain: 1, trim: 1 };
  private last = new Map<Sfx, number>();
  private listener = { x: 0, z: 0 };
  private ambience: { area: AreaId | null; nodes: AudioNode[]; gain: GainNode | null } = { area: null, nodes: [], gain: null };
  private wantArea: AreaId | null = null;
  private bedKind: 'loops' | 'synth' | 'none' = 'none';
  private bossBed: GainNode | null = null;
  private ambienceAccentTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    const start = () => {
      this.ensure();
      window.removeEventListener('pointerdown', start);
      window.removeEventListener('keydown', start);
    };
    window.addEventListener('pointerdown', start);
    window.addEventListener('keydown', start);
    onSettingsChange(() => this.applyVolume());
    if (import.meta.env.DEV) (window as unknown as { __cwAudio?: AudioEngine }).__cwAudio = this;
  }

  private ensure() {
    if (this.ctx) {
      if (this.ctx.state === 'suspended') void this.ctx.resume();
      return;
    }
    try {
      this.ctx = new AudioContext();
    } catch {
      return;
    }
    const c = this.ctx;
    // buses -> gentle compressor -> master -> brick-wall limiter -> speakers
    const limiter = c.createDynamicsCompressor();
    limiter.threshold.value = -3;
    limiter.knee.value = 0;
    limiter.ratio.value = 20;
    limiter.attack.value = 0.001;
    limiter.release.value = 0.12;
    limiter.connect(c.destination);
    this.master = c.createGain();
    this.master.connect(limiter);
    const comp = c.createDynamicsCompressor();
    comp.threshold.value = -18;
    comp.knee.value = 20;
    comp.ratio.value = 3;
    comp.attack.value = 0.006;
    comp.release.value = 0.25;
    comp.connect(this.master);
    for (const id of BUS_IDS) {
      const mk = (to: AudioNode) => {
        const g = c.createGain();
        const d = c.createGain();
        g.connect(d);
        d.connect(to);
        return [g, d] as const;
      };
      // wet chain feeds the reverb (connected below); both follow the bus level and ducking.
      const [dry, dkDry] = mk(comp);
      const wetHub = c.createGain();
      wetHub.gain.value = 1;
      const [wet, dkWet] = mk(wetHub);
      this.buses[id] = { dry, wet, dkDry, dkWet, hub: wetHub };
    }
    this.bedGain = c.createGain();
    this.bedGain.gain.value = 0.55;
    this.bedGain.connect(this.buses.ambience.dry);
    this.bedDuck = c.createGain();
    this.bedDuck.connect(this.bedGain);
    this.duckTimer = setInterval(() => this.applyBedDuck(), 400);
    if (import.meta.env.DEV) {
      // Per-bus meters on the dry path after the bus gain and ducking (the reverb send is not metered).
      for (const id of BUS_IDS) {
        const node = c.createAnalyser();
        node.fftSize = 2048;
        this.buses[id].dkDry.connect(node);
        this.busMeters.push({ id, node, buf: new Float32Array(node.fftSize) });
      }
      // QA meters: `pre` before the limiter (what the mix asks for), post after it (what reaches the speakers).
      for (const [src, pre] of [[this.master, true], [limiter, false]] as const) {
        const node = c.createAnalyser();
        node.fftSize = 2048;
        src.connect(node);
        this.analysers.push({ node, buf: new Float32Array(node.fftSize), pre });
      }
      setInterval(() => {
        this.busTicks++;
        for (const b of this.busMeters) {
          b.node.getFloatTimeDomainData(b.buf);
          let m = 0;
          let sq = 0;
          for (let i = 0; i < b.buf.length; i++) {
            const v = b.buf[i];
            m = Math.max(m, Math.abs(v));
            sq += v * v;
          }
          this.busPeak[b.id] = Math.max(this.busPeak[b.id], m);
          this.busSq[b.id] += sq / b.buf.length;
        }
        for (const a of this.analysers) {
          a.node.getFloatTimeDomainData(a.buf);
          let m = 0;
          for (let i = 0; i < a.buf.length; i++) m = Math.max(m, Math.abs(a.buf[i]));
          if (a.pre) this.peakPre = Math.max(this.peakPre, m);
          else this.peakOut = Math.max(this.peakOut, m);
        }
      }, 25);
    }
    this.verb = c.createConvolver();
    this.verb.buffer = this.impulse(2.8, 2.2);
    this.verbSend = c.createGain();
    this.verbSend.gain.value = 0.32;
    this.verbSend.connect(this.verb);
    this.verb.connect(comp);
    for (const id of BUS_IDS) this.buses[id].hub.connect(this.verbSend);
    this.noise = this.makeNoise(false);
    this.brown = this.makeNoise(true);
    void this.samples.loadLegacy(this.ctx).then(() => {
      // The recorded beds arrived after the synthesised one started: crossfade to them.
      if (this.wantArea && this.ctx) this.setArea(this.wantArea, true);
    });
    // Pack order: the hits and hurt first, then the area the player stands in, then the rest, all off the critical path.
    this.queuePacks(['core', ...(this.wantArea ? areaPacks(this.wantArea) : []), ...GLOBAL_PACKS.filter((p) => p !== 'core')]);
    this.applyVolume();
    if (this.wantArea) this.setArea(this.wantArea);
  }

  private applyVolume() {
    if (!this.master) return;
    const t = this.ctx!.currentTime;
    this.master.gain.setTargetAtTime(masterGain(settings), t, 0.02);
    for (const id of BUS_IDS) {
      const g = busGain(id, settings);
      this.buses[id].dry.gain.setTargetAtTime(g, t, 0.02);
      this.buses[id].wet.gain.setTargetAtTime(g, t, 0.02);
    }
  }

  /** Load packs one after another (each pack's clips decode in parallel, off the main thread). */
  private queuePacks(packs: Pack[]) {
    this.packQueue = this.packQueue.then(async () => {
      for (const pack of packs) {
        if (!this.ctx) return;
        await this.samples.loadPack(this.ctx, pack);
      }
    }).catch(() => undefined);
  }

  /** Keep this area's and the previous area's floor / voice / boss packs; release the rest, load what is new. */
  private syncAreaPacks(area: AreaId) {
    if (this.areaTrail[0] !== area) this.areaTrail = [area, ...this.areaTrail.filter((a) => a !== area)].slice(0, 2);
    const keep = new Set<Pack>(this.areaTrail.flatMap((a) => areaPacks(a)));
    for (const pack of this.samples.loadedPacks()) {
      if ((pack.startsWith('foot_') || pack.startsWith('fam_') || pack === 'boss') && !keep.has(pack)) this.samples.releasePack(pack);
    }
    this.queuePacks(areaPacks(area));
  }

  private makeNoise(brown: boolean) {
    const c = this.ctx!;
    const len = c.sampleRate * 2;
    const buf = c.createBuffer(1, len, c.sampleRate);
    const d = buf.getChannelData(0);
    let last = 0;
    for (let i = 0; i < len; i++) {
      const w = Math.random() * 2 - 1;
      if (brown) {
        last = (last + 0.02 * w) / 1.02;
        d[i] = last * 3.5;
      } else d[i] = w;
    }
    return buf;
  }

  /** Cathedral-ish reverb tail. */
  private impulse(seconds: number, decay: number) {
    const c = this.ctx!;
    const len = Math.floor(c.sampleRate * seconds);
    const buf = c.createBuffer(2, len, c.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = buf.getChannelData(ch);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, decay);
    }
    return buf;
  }

  setListener(x: number, z: number) {
    this.listener.x = x;
    this.listener.z = z;
  }

  // --- voice helpers -------------------------------------------------------

  /** Output node for one sound: gain (distance, repeat, layer trim) -> pan -> its bus (+ reverb send). */
  private out(x: number | undefined, z: number | undefined, vol: number, wet = 0.4) {
    const c = this.ctx!;
    const g = c.createGain();
    const { bus, gain, trim } = this.cur;
    let v = vol * gain * trim;
    let pan = 0;
    if (x !== undefined && z !== undefined) {
      const dx = x - this.listener.x;
      const dz = z - this.listener.z;
      v *= distanceGain(Math.hypot(dx, dz), bus);
      pan = panFor(dx);
    }
    g.gain.value = v;
    const p = c.createStereoPanner();
    p.pan.value = pan;
    g.connect(p);
    p.connect(this.buses[bus].dry);
    const send = c.createGain();
    send.gain.value = wet;
    p.connect(send);
    send.connect(this.buses[bus].wet);
    return g;
  }

  private track(node: AudioScheduledSourceNode, stopAt: number) {
    this.voices++;
    node.onended = () => (this.voices = Math.max(0, this.voices - 1));
    node.stop(stopAt);
  }

  /** Start one decoded clip: gain (map volume, jitter, intensity), pitch jitter, a tail fade at the id's cap, then the bus. */
  private startClip(buffer: AudioBuffer, vol: number, rate: number, jitter: number, x: number | undefined, z: number | undefined, t: number, capS: number, wet: number) {
    const source = this.ctx!.createBufferSource();
    source.buffer = buffer;
    const r = rate * (1 + (Math.random() * 2 - 1) * jitter);
    source.playbackRate.value = r;
    const o = this.out(x, z, vol, wet);
    source.connect(o);
    source.start(t);
    let len = buffer.duration / r;
    if (len > capS + 0.05) {
      // The file is long for this id (a clip shared with a boss moment): fade it out at the id's own cap.
      const base = o.gain.value;
      o.gain.setValueAtTime(base, t + capS - 0.12);
      o.gain.linearRampToValueAtTime(0.0001, t + capS);
      len = capS;
    }
    this.track(source, t + len + 0.02);
    this.sampleHits++;
  }

  /**
   * Play the recorded layer of a sound. Returns how much of the synthesised sound is still wanted underneath:
   * 0 = the clip is the sound, a fraction = layer that share of the synth, 1 = no clip played (synth alone).
   * Mapped ids replace the synth; `partial` ids keep it under the clip; `keep` ids use their older clip or the synth.
   */
  private recorded(name: Sfx, def: SoundDef | undefined, x: number | undefined, z: number | undefined, t: number, intensity: number, pg: number): number {
    const legacy = (mix: number): number => {
      const l = this.samples.pickLegacy(name);
      if (!l) return 1;
      const spec: LegacySpec = l.spec;
      this.startClip(l.buffer, spec.gain * (0.88 + Math.random() * 0.12) * Math.min(1.5, intensity) * pg, spec.rate ?? 1, spec.jitter ?? 0.06, x, z, t, 4, 0.3);
      return mix >= 0 ? mix : spec.synthMix;
    };
    if (!def || isKept(name)) return legacy(-1);
    const hit = this.samples.pick(name);
    if (!hit) return legacy(-1);
    const vol = def.volume * (0.88 + Math.random() * 0.12) * Math.min(1.5, intensity) * pg;
    const cap = capSeconds(name as SoundId);
    this.startClip(hit.buffer, vol, def.rate ?? 1, def.pitchJitter, x, z, t, cap, 0.3);
    if (def.layer) {
      const lb = this.samples.pickLayer(name);
      if (lb) this.startClip(lb, def.layer.volume * Math.min(1.5, intensity) * pg, def.rate ?? 1, def.pitchJitter, x, z, t + def.layer.delayMs / 1000, cap, 0.3);
    }
    if (!isPartial(name)) return 0;
    // Partial fit: the older sound (kept bell / generated accent / synth) stays underneath.
    const l = this.samples.pickLegacy(name);
    if (l) {
      this.startClip(l.buffer, l.spec.gain * 0.8 * pg * Math.min(1.5, intensity), l.spec.rate ?? 1, l.spec.jitter ?? 0.06, x, z, t, 4, 0.3);
      return Math.max(l.spec.synthMix, 0.3);
    }
    return 0.45;
  }

  /**
   * A rite bed made of re-triggered one-shots (the pack has no loops): plays `name` every `loopMs` for `ms`.
   * Returns a function that ends it early (the matching `*Gone` event).
   */
  loop(name: Sfx, ms: number, x?: number, z?: number, follow?: () => { x: number; z: number } | null): () => void {
    const every = AUDIO_MAP[name as SoundId]?.loopMs ?? 1500;
    const end = performance.now() + ms;
    const tick = () => {
      const at = follow?.();
      if (follow && !at) return stop();
      this.play(name, at?.x ?? x, at?.z ?? z);
    };
    const timer = setInterval(() => (performance.now() >= end ? stop() : tick()), every);
    const stop = () => clearInterval(timer);
    tick();
    return stop;
  }

  /** A footstep for a surface (`step<Surface>` ids), quieter in some areas, at the player's feet. */
  footstep(id: Sfx, x: number, z: number, gain: number) {
    this.play(id, x, z, gain);
  }

  /** Pull thralls and enemies down for a moment so the player's hurt / a boss tell cuts through. */
  private duck(d: Duck, now: number) {
    if (now < this.duckState.until && d.depth < this.duckState.depth) return;
    this.duckState = { depth: d.depth, until: now + d.hold };
    this.duckCount++;
    const apply = (id: BusId, depth: number) => {
      for (const node of [this.buses[id].dkDry, this.buses[id].dkWet]) {
        const prm = node.gain;
        prm.cancelScheduledValues(now);
        prm.setTargetAtTime(1 - depth, now, 0.03);
        prm.setTargetAtTime(1, now + d.hold, d.release);
      }
    };
    apply('thralls', d.depth);
    apply('enemies', d.voice ?? d.depth);
    if (d.ambience) apply('ambience', d.ambience);
  }

  /** Pull the zone bed down while a fight is on, and let it back up when it ends. */
  private applyBedDuck() {
    if (!this.ctx || !this.bedDuck) return;
    const t = this.ctx.currentTime;
    this.bedDuck.gain.setTargetAtTime(bedDuckGain(this.activity.level(t)), t, 0.35);
  }

  private drop(reason: keyof AudioEngine['dropReasons']) {
    this.dropReasons[reason]++;
  }

  /** Dev/QA snapshot: voices per bus, drops and loaded sample count. */
  stats() {
    const now = this.ctx?.currentTime ?? 0;
    const active = {} as Record<BusId, number>;
    for (const id of BUS_IDS) active[id] = this.limiter.active(id, now);
    return {
      state: this.ctx?.state ?? 'none',
      played: this.played,
      samplesLoaded: this.samples.loaded,
      samplesExpected: this.samples.requested,
      packs: this.samples.loadedPacks(),
      samplesFailed: this.samples.failed,
      samplePlays: this.sampleHits,
      active,
      peakVoices: { ...this.limiter.peak },
      dropped: this.limiter.dropped + this.dropReasons.far + this.dropReasons.repeat + this.dropReasons.thin + this.dropReasons.gap + this.dropReasons.id + this.dropReasons.partner,
      droppedByReason: { ...this.dropReasons },
      droppedByBus: { ...this.limiter.droppedByBus },
      ducks: this.duckCount,
      nodes: this.voices,
      peakOut: this.peakOut,
      peakPre: this.peakPre,
      busPeak: { ...this.busPeak },
      busRms: Object.fromEntries(BUS_IDS.map((id) => [id, this.busTicks ? Math.sqrt(this.busSq[id] / this.busTicks) : 0])) as Record<BusId, number>,
      combatLevel: this.activity.level(now),
      bedDuck: this.bedDuck?.gain.value ?? 1,
      area: this.ambience.area,
      bedKind: this.bedKind,
    };
  }

  resetStats() {
    this.played = 0;
    this.sampleHits = 0;
    this.duckCount = 0;
    this.peakOut = 0;
    this.peakPre = 0;
    this.busTicks = 0;
    for (const id of BUS_IDS) {
      this.busPeak[id] = 0;
      this.busSq[id] = 0;
    }
    this.limiter = new VoiceLimiter();
    this.idLimiter.reset();
    for (const k of Object.keys(this.dropReasons) as (keyof AudioEngine['dropReasons'])[]) this.dropReasons[k] = 0;
  }

  private env(g: GainNode, t: number, a: number, peak: number, d: number) {
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(peak, t + a);
    g.gain.exponentialRampToValueAtTime(0.0001, t + a + d);
  }

  private tone(dest: AudioNode, type: OscillatorType, f0: number, f1: number, t: number, a: number, d: number, peak: number) {
    const c = this.ctx!;
    const o = c.createOscillator();
    o.type = type;
    o.frequency.setValueAtTime(f0, t);
    if (f1 !== f0) o.frequency.exponentialRampToValueAtTime(Math.max(1, f1), t + a + d);
    const g = c.createGain();
    this.env(g, t, a, peak, d);
    o.connect(g);
    g.connect(dest);
    o.start(t);
    this.track(o, t + a + d + 0.05);
  }

  private burst(dest: AudioNode, t: number, dur: number, peak: number, filter: BiquadFilterType, f0: number, f1: number, q = 1, brown = false) {
    const c = this.ctx!;
    const s = c.createBufferSource();
    s.buffer = brown ? this.brown : this.noise;
    s.playbackRate.value = 0.8 + Math.random() * 0.4;
    const bq = c.createBiquadFilter();
    bq.type = filter;
    bq.Q.value = q;
    bq.frequency.setValueAtTime(f0, t);
    bq.frequency.exponentialRampToValueAtTime(Math.max(20, f1), t + dur);
    const g = c.createGain();
    this.env(g, t, Math.min(0.01, dur * 0.2), peak, dur);
    s.connect(bq);
    bq.connect(g);
    g.connect(dest);
    s.start(t, Math.random() * 1.5);
    this.track(s, t + dur + 0.05);
  }

  /** Inharmonic bell partials (church-bell ratios). */
  private bell(dest: AudioNode, t: number, f: number, dur: number, peak: number) {
    const partials: [number, number][] = [
      [0.5, 0.5],
      [1, 1],
      [1.19, 0.5],
      [1.56, 0.35],
      [2, 0.45],
      [2.51, 0.3],
      [2.66, 0.2],
      [3.01, 0.15],
    ];
    for (const [ratio, amp] of partials) {
      this.tone(dest, 'sine', f * ratio, f * ratio * 0.998, t, 0.004, dur * (1.1 - ratio * 0.18), peak * amp);
    }
    this.burst(dest, t, 0.06, peak * 0.4, 'highpass', 3000, 3000, 0.7);
  }

  // --- public --------------------------------------------------------------

  play(name: Sfx, x?: number, z?: number, intensity = 1) {
    if (!this.ctx || this.ctx.state !== 'running' || this.voices > MAX_VOICES) return;
    const now = this.ctx.currentTime;
    const prof = profileOf(name);
    const def = defOf(name);
    if (def && !def.spatial) {
      x = undefined;
      z = undefined;
    }
    const gap = def ? def.cooldownMs / 1000 : MIN_GAP[name];
    if (gap && now - (this.last.get(name) ?? -1) < gap) {
      this.drop('gap');
      return;
    }
    const distance = x !== undefined && z !== undefined ? Math.hypot(x - this.listener.x, z - this.listener.z) : 0;
    if (x !== undefined && z !== undefined && culled(distance, prof.bus, prof.priority)) {
      this.drop('far');
      return;
    }
    let pg = 1;
    if (this.partner) {
      // A co-op partner's sounds: faint, only nearby, and a handful at a time.
      if (!partnerAudible(distance) || this.partnerWin.count('p', now, 0.5) >= 4) {
        this.drop('partner');
        return;
      }
      pg = partnerGain(name.startsWith('step') ? 'step' : 'spell');
      this.partnerWin.add('p', now);
    }
    const repeats = this.repeats.count(name, now, REPEAT_WINDOW);
    if (repeatDropped(repeats, prof.priority)) {
      this.drop('repeat');
      return;
    }
    const thinKey = prof.thin ? `thin:${prof.bus}` : '';
    if (prof.thin && this.thin.count(thinKey, now, prof.thin.window) >= prof.thin.max) {
      this.drop('thin');
      return;
    }
    if (def && !this.idLimiter.request(name, now, Math.min(prof.dur, capSeconds(name as SoundId)), def.maxVoices, 0)) {
      this.drop('id');
      return;
    }
    if (!this.limiter.request(prof.bus, prof.priority, now, prof.dur).ok) return; // counted by the limiter
    this.last.set(name, now);
    this.repeats.add(name, now);
    if (thinKey) this.thin.add(thinKey, now);
    this.played++;
    const weight = activityWeight(prof.bus, prof.priority);
    if (weight) {
      this.activity.bump(now, weight);
      if (now - this.lastDuckApply > 0.1) {
        this.lastDuckApply = now;
        this.applyBedDuck();
      }
    }
    if (prof.duck && !this.partner) this.duck(prof.duck, now);
    const t = now + 0.005;
    this.cur = { bus: prof.bus, gain: repeatGain(repeats), trim: 1 };
    const synthShare = this.recorded(name, def, x, z, t, intensity, pg);
    if (synthShare === 0) return;
    this.cur.trim = synthShare;
    this.cur.gain *= pg;
    const r = () => 0.9 + Math.random() * 0.2;
    switch (name) {
      case 'needleCast': {
        const o = this.out(x, z, 0.35, 0.2);
        this.burst(o, t, 0.16, 0.6, 'bandpass', 2200 * r(), 6000, 2);
        this.tone(o, 'triangle', 900 * r(), 1800, t, 0.005, 0.08, 0.12);
        break;
      }
      case 'needleHit': {
        const o = this.out(x, z, 0.45 * intensity, 0.25);
        this.burst(o, t, 0.07, 0.9, 'bandpass', 2600 * r(), 1800, 3);
        this.tone(o, 'square', 380 * r(), 180, t, 0.002, 0.05, 0.08);
        break;
      }
      case 'boneHit': {
        const o = this.out(x, z, 0.3, 0.2);
        this.burst(o, t, 0.06, 0.8, 'bandpass', 1500 * r(), 900, 4);
        break;
      }
      case 'spear': {
        const o = this.out(x, z, 0.75, 0.35);
        for (let i = 0; i < 6; i++) this.burst(o, t + i * 0.035, 0.12, 0.7, 'bandpass', 1200 + i * 250, 500, 2.5);
        this.tone(o, 'sine', 90, 42, t, 0.005, 0.35, 0.8);
        this.burst(o, t, 0.5, 0.35, 'lowpass', 600, 150, 0.7, true);
        break;
      }
      case 'exhume': {
        const o = this.out(x, z, 0.6, 0.6);
        this.burst(o, t, 0.4, 0.45, 'lowpass', 900, 200, 0.8, true);
        this.tone(o, 'sine', 220 * r(), 660, t + 0.05, 0.25, 0.6, 0.18);
        this.tone(o, 'sine', 330 * r(), 990, t + 0.1, 0.25, 0.55, 0.12);
        break;
      }
      case 'thrallRise': {
        const o = this.out(x, z, 0.5, 0.5);
        for (let i = 0; i < 5; i++) this.burst(o, t + i * 0.06 + Math.random() * 0.03, 0.05, 0.6, 'bandpass', 1800 + Math.random() * 900, 1200, 5);
        this.tone(o, 'sine', 440, 880, t, 0.1, 0.5, 0.1);
        break;
      }
      case 'miasma': {
        const o = this.out(x, z, 0.55, 0.45);
        this.burst(o, t, 1.1, 0.4, 'bandpass', 500, 1400, 1.2);
        for (let i = 0; i < 9; i++) {
          const f = 180 + Math.random() * 380;
          this.tone(o, 'sine', f, f * 1.8, t + 0.1 + i * 0.09 + Math.random() * 0.05, 0.005, 0.07, 0.15);
        }
        break;
      }
      case 'litany': {
        const o = this.out(x, z, 0.95 * intensity, 0.8);
        // Inhale: reversed-feeling rise, then the boom.
        this.burst(o, t, 0.28, 0.5, 'bandpass', 300, 3000, 1.5);
        this.tone(o, 'sine', 70, 28, t + 0.2, 0.01, 1.4, 1);
        this.burst(o, t + 0.2, 1.2, 0.6, 'lowpass', 1400, 120, 0.7, true);
        for (const f of [110, 130.8, 164.8, 196]) this.tone(o, 'sawtooth', f * r() * 0.5, f * 0.5, t + 0.22, 0.12, 1.6, 0.05);
        break;
      }
      case 'enemyDeath': {
        const o = this.out(x, z, 0.45, 0.3);
        this.burst(o, t, 0.18, 0.7, 'bandpass', 900 * r(), 300, 1.5);
        this.tone(o, 'sine', 120, 60, t, 0.005, 0.2, 0.35);
        break;
      }
      case 'eliteDeath': {
        const o = this.out(x, z, 0.8, 0.6);
        this.burst(o, t, 0.4, 0.7, 'lowpass', 1800, 200, 0.8, true);
        this.tone(o, 'sine', 90, 35, t, 0.005, 0.6, 0.7);
        this.bell(o, t + 0.05, 880, 1.1, 0.12);
        break;
      }
      case 'thrallMelee': {
        const o = this.out(x, z, 0.3, 0.12);
        this.burst(o, t, 0.05, 0.6, 'bandpass', 1300 * r(), 800, 4);
        break;
      }
      case 'thrallShot': {
        const o = this.out(x, z, 0.25, 0.15);
        this.burst(o, t, 0.1, 0.4, 'bandpass', 2200 * r(), 4200, 2);
        break;
      }
      case 'thrallMagic': {
        const o = this.out(x, z, 0.25, 0.3);
        this.tone(o, 'sine', 520 * r(), 760, t, 0.01, 0.2, 0.1);
        break;
      }
      case 'hurt': {
        const o = this.out(undefined, undefined, 0.5, 0.1);
        this.burst(o, t, 0.12, 0.8, 'lowpass', 900, 250, 1);
        this.tone(o, 'sine', 160, 90, t, 0.003, 0.12, 0.35);
        break;
      }
      case 'playerDeath': {
        const o = this.out(undefined, undefined, 0.8, 0.8);
        this.bell(o, t, 196, 3.5, 0.35);
        this.tone(o, 'sine', 55, 30, t, 0.02, 2.5, 0.5);
        break;
      }
      case 'toll':
      case 'bossToll': {
        const big = name === 'bossToll';
        const o = this.out(x, z, big ? 1 : 0.55, 0.9);
        this.bell(o, t, big ? 98 : 196 * r(), big ? 4.5 : 2.4, big ? 0.55 : 0.3);
        if (big) this.tone(o, 'sine', 49, 45, t, 0.01, 3, 0.5);
        break;
      }
      case 'tollSmall': {
        const o = this.out(x, z, 0.3, 0.7);
        this.bell(o, t, 523 * r(), 1.2, 0.12);
        break;
      }
      case 'curse': {
        const o = this.out(x, z, 0.45, 0.5);
        this.tone(o, 'sawtooth', 140, 70, t, 0.05, 0.4, 0.12);
        this.burst(o, t, 0.35, 0.35, 'bandpass', 800, 300, 3);
        break;
      }
      case 'raise': {
        const o = this.out(x, z, 0.45, 0.6);
        this.tone(o, 'sine', 180, 120, t, 0.3, 1.1, 0.14);
        this.tone(o, 'sine', 187, 124, t, 0.3, 1.1, 0.12);
        break;
      }
      case 'burst': {
        const o = this.out(x, z, 0.6, 0.4);
        this.burst(o, t, 0.35, 0.8, 'lowpass', 2200, 300, 0.8);
        this.tone(o, 'sine', 110, 40, t, 0.003, 0.3, 0.5);
        break;
      }
      case 'emberBurst': {
        // Coals bursting: a soft whoomph under a spray of crackles.
        const o = this.out(x, z, 0.55, 0.4);
        this.burst(o, t, 0.3, 0.7, 'lowpass', 1600, 250, 0.8, true);
        this.tone(o, 'sine', 140, 55, t, 0.004, 0.25, 0.4);
        for (let i = 0; i < 5; i++) this.burst(o, t + 0.02 + i * 0.04 * r(), 0.03, 0.4, 'highpass', 3500 + 900 * r(), 3500, 1);
        break;
      }
      case 'chainTier': {
        // A rising bell-and-shimmer: bright, short, never harsh.
        const o = this.out(undefined, undefined, 0.5, 0.3);
        this.bell(o, t, 660, 0.9, 0.1);
        this.bell(o, t + 0.09, 880, 0.9, 0.1);
        this.bell(o, t + 0.18, 1320, 1.1, 0.1);
        this.burst(o, t, 0.25, 0.2, 'highpass', 4000, 6000, 1);
        break;
      }
      case 'chainBreak': {
        // A long chain snapping: a low thud and a slow falling tone.
        const o = this.out(undefined, undefined, 0.5, 0.2);
        this.tone(o, 'sine', 180, 60, t, 0.005, 0.5, 0.3);
        this.burst(o, t, 0.25, 0.3, 'lowpass', 700, 200, 1);
        break;
      }
      case 'emberCrackle': {
        // A pop and a few sparks from a distant fire.
        const o = this.out(x, z, 0.3, 0.5);
        for (let i = 0; i < 3 + Math.floor(Math.random() * 3); i++) this.burst(o, t + i * 0.05 * r(), 0.025, 0.3, 'highpass', 3000 + 1500 * r(), 3000, 1);
        this.burst(o, t, 0.08, 0.25, 'lowpass', 900, 300, 1, true);
        break;
      }
      case 'emberThrow': {
        // A coal leaving the censer: a rising hiss.
        const o = this.out(x, z, 0.4, 0.4);
        this.burst(o, t, 0.35, 0.35, 'bandpass', 700, 2600, 2);
        this.tone(o, 'sawtooth', 180, 420, t, 0.05, 0.3, 0.08);
        break;
      }
      case 'slagSlam': {
        // Molten fist on stone: a deep thud, a grind of slag and a hiss as it cools.
        const o = this.out(x, z, 0.85, 0.35);
        this.tone(o, 'sine', 80, 32, t, 0.003, 0.5, 0.75);
        this.burst(o, t, 0.5, 0.6, 'lowpass', 900, 150, 0.9, true);
        this.burst(o, t + 0.08, 0.6, 0.3, 'highpass', 3000, 1800, 1);
        for (let i = 0; i < 6; i++) this.burst(o, t + 0.1 + i * 0.05 * r(), 0.03, 0.35, 'highpass', 4000, 4000, 1);
        break;
      }
      case 'chop': {
        // An axe into coffin-oak: a dull knock plus a woody crack.
        const o = this.out(x, z, 0.4, 0.25);
        this.burst(o, t, 0.12, 0.7, 'lowpass', 700 * r(), 180, 1.2, true);
        this.burst(o, t + 0.005, 0.05, 0.35, 'bandpass', 1800 * r(), 900, 3);
        break;
      }
      case 'pick': {
        // Iron on stone: a bright clink with a short ring.
        const o = this.out(x, z, 0.32, 0.35);
        this.burst(o, t, 0.04, 0.5, 'highpass', 3000, 3000, 1);
        this.tone(o, 'triangle', 2400 * r(), 2200, t, 0.001, 0.22, 0.12);
        break;
      }
      case 'splash': {
        const o = this.out(x, z, 0.3, 0.4);
        this.burst(o, t, 0.35, 0.4, 'bandpass', 1200 * r(), 500, 0.8);
        this.burst(o, t + 0.08, 0.2, 0.15, 'highpass', 3500, 4000, 1);
        break;
      }
      case 'shovel': {
        // A spade into grave soil: a gritty scrape and a soft thud.
        const o = this.out(x, z, 0.36, 0.2);
        this.burst(o, t, 0.22, 0.35, 'bandpass', 900 * r(), 400, 1.4);
        this.burst(o, t + 0.12, 0.1, 0.5, 'lowpass', 260, 90, 1, true);
        break;
      }
      case 'skillUp': {
        const o = this.out(undefined, undefined, 0.5, 0.7);
        [392, 494, 587, 784].forEach((f, i) => this.bell(o, t + i * 0.09, f, 1.4, 0.15));
        break;
      }
      case 'coin': {
        const o = this.out(undefined, undefined, 0.22, 0.2);
        const f = 1900 * r();
        this.tone(o, 'sine', f, f, t, 0.002, 0.18, 0.4);
        this.tone(o, 'sine', f * 1.5, f * 1.5, t + 0.04, 0.002, 0.14, 0.25);
        break;
      }
      case 'shard': {
        const o = this.out(undefined, undefined, 0.35, 0.6);
        for (const [i, f] of [1318, 1760, 2637].entries()) this.tone(o, 'sine', f, f, t + i * 0.05, 0.003, 0.6, 0.18);
        break;
      }
      case 'item': {
        const o = this.out(undefined, undefined, 0.35, 0.5);
        this.bell(o, t, 659, 0.9, 0.14);
        break;
      }
      case 'levelUp': {
        const o = this.out(undefined, undefined, 0.6, 0.8);
        [262, 330, 392, 523].forEach((f, i) => this.bell(o, t + i * 0.12, f, 1.8, 0.18));
        break;
      }
      case 'gate': {
        const o = this.out(x, z, 0.9, 0.7);
        this.burst(o, t, 2.2, 0.6, 'lowpass', 300, 80, 0.7, true);
        for (let i = 0; i < 14; i++) this.burst(o, t + i * 0.13 + Math.random() * 0.05, 0.06, 0.4, 'bandpass', 2500 + Math.random() * 1500, 2000, 6);
        this.bell(o, t + 0.1, 147, 3, 0.3);
        break;
      }
      case 'click': {
        const o = this.out(undefined, undefined, 0.18, 0.05);
        this.burst(o, t, 0.03, 0.8, 'bandpass', 2400, 2000, 3);
        break;
      }
      case 'buy': {
        const o = this.out(undefined, undefined, 0.4, 0.6);
        this.bell(o, t, 784, 1.2, 0.16);
        this.tone(o, 'sine', 392, 392, t, 0.01, 0.5, 0.12);
        break;
      }
      case 'error': {
        const o = this.out(undefined, undefined, 0.2, 0.1);
        this.tone(o, 'square', 150, 120, t, 0.005, 0.12, 0.08);
        break;
      }
      case 'wave': {
        const o = this.out(x, z, 0.5, 0.6);
        this.burst(o, t, 1.2, 0.45, 'lowpass', 400, 90, 0.8, true);
        this.tone(o, 'sine', 62, 48, t, 0.2, 1, 0.35);
        break;
      }
      case 'bossSlam': {
        const o = this.out(x, z, 1, 0.6);
        this.tone(o, 'sine', 80, 30, t, 0.003, 0.7, 1);
        this.burst(o, t, 0.6, 0.8, 'lowpass', 1600, 150, 0.8, true);
        this.bell(o, t + 0.02, 130, 1.4, 0.2);
        break;
      }
      case 'bossAwaken': {
        const o = this.out(x, z, 1, 1);
        this.bell(o, t, 73, 6, 0.6);
        this.bell(o, t + 1.1, 98, 5, 0.5);
        this.tone(o, 'sine', 36, 34, t, 0.5, 5, 0.6);
        this.setBossBed(true);
        break;
      }
      case 'bossDefeat': {
        const o = this.out(x, z, 1, 1);
        this.bell(o, t, 110, 7, 0.6);
        this.burst(o, t, 3, 0.5, 'lowpass', 1000, 60, 0.7, true);
        this.setBossBed(false);
        break;
      }
      case 'step': {
        const o = this.out(undefined, undefined, 0.07 * intensity, 0.05);
        this.burst(o, t, 0.05, 0.9, 'lowpass', 700 * r(), 200, 1);
        break;
      }
      case 'lowHealth': {
        // No pulse in the pack: a low double thump, like a heartbeat heard from inside.
        const o = this.out(undefined, undefined, 0.5 * intensity, 0.1);
        this.tone(o, 'sine', 62, 38, t, 0.004, 0.16, 0.7);
        this.tone(o, 'sine', 56, 34, t + 0.2, 0.004, 0.18, 0.5);
        break;
      }
      case 'wail': {
        // Wailing Skull: a falling, slightly detuned shriek over breathy noise.
        const o = this.out(x, z, 0.4 * intensity, 0.45);
        this.tone(o, 'sine', 1150 * r(), 420, t, 0.02, 0.45, 0.14);
        this.tone(o, 'sine', 1190 * r(), 400, t + 0.015, 0.02, 0.45, 0.1);
        this.burst(o, t, 0.4, 0.3, 'bandpass', 2400, 900, 3);
        break;
      }
      case 'bloodStep': {
        // Grave Step: a wet rush of mist, then the thud of re-forming.
        const o = this.out(x, z, 0.6, 0.4);
        this.burst(o, t, 0.28, 0.55, 'lowpass', 300, 2200, 0.9, true);
        this.burst(o, t + 0.18, 0.16, 0.6, 'bandpass', 700 * r(), 260, 1.5);
        this.tone(o, 'sine', 110, 46, t + 0.18, 0.005, 0.3, 0.55);
        break;
      }
      case 'frost': {
        // Grave Frost: a cold exhale with ice crackling through it.
        const o = this.out(x, z, 0.55, 0.5);
        this.burst(o, t, 0.5, 0.35, 'highpass', 2800, 5200, 0.8);
        for (let i = 0; i < 7; i++) this.burst(o, t + 0.05 + i * 0.045 + Math.random() * 0.02, 0.035, 0.5, 'bandpass', 4200 + Math.random() * 2400, 3000, 6);
        this.tone(o, 'triangle', 1560 * r(), 1320, t + 0.02, 0.01, 0.3, 0.05);
        break;
      }
      case 'mantle': {
        // Bone Mantle: rattling bone that settles into a low hum.
        const o = this.out(x, z, 0.6, 0.5);
        for (let i = 0; i < 8; i++) this.burst(o, t + i * 0.04 + Math.random() * 0.02, 0.05, 0.6, 'bandpass', 1300 + Math.random() * 900, 800, 4);
        this.tone(o, 'sine', 82, 110, t + 0.1, 0.1, 0.7, 0.35);
        break;
      }
      case 'flail': {
        const o = this.out(x, z, 0.48 * intensity, 0.22);
        this.burst(o, t, 0.15, 0.4, 'bandpass', 700, 2300, 0.8);
        for (let i = 0; i < 3; i++) this.tone(o, 'triangle', (680 + i * 330) * r(), 280 + i * 70, t + 0.04 + i * 0.028, 0.002, 0.17, 0.12);
        break;
      }
      case 'lantern': {
        const o = this.out(x, z, 0.5, 0.35);
        this.burst(o, t, 0.45, 0.32, 'bandpass', 400, 1900, 0.7);
        this.tone(o, 'sine', 390, 520, t + 0.06, 0.09, 0.42, 0.11);
        break;
      }
      case 'chain': {
        const o = this.out(x, z, 0.55, 0.28);
        this.burst(o, t, 0.22, 0.35, 'highpass', 1200, 2800, 1);
        for (let i = 0; i < 4; i++) this.tone(o, 'triangle', (950 + i * 280) * r(), 600 + i * 90, t + i * 0.045, 0.002, 0.15, 0.1);
        break;
      }
      case 'pyre': {
        const o = this.out(x, z, 0.62 * intensity, 0.48);
        this.burst(o, t, 0.65, 0.5, 'bandpass', 250, 1700, 0.8);
        this.burst(o, t + 0.16, 0.4, 0.18, 'highpass', 3200, 5000, 0.8);
        this.tone(o, 'sine', 72, 48, t + 0.08, 0.05, 0.55, 0.4);
        break;
      }
      case 'ward': {
        const o = this.out(x, z, 0.5, 0.58);
        this.burst(o, t, 0.32, 0.2, 'bandpass', 2600, 700, 2);
        this.tone(o, 'sine', 164 * r(), 122, t, 0.04, 0.72, 0.25);
        this.tone(o, 'sine', 246 * r(), 185, t + 0.05, 0.04, 0.6, 0.12);
        break;
      }
      case 'palm': {
        const o = this.out(x, z, 0.48 * intensity, 0.45);
        this.burst(o, t, 0.09, 0.48, 'lowpass', 1300, 260, 0.8);
        this.tone(o, 'sine', 155 * r(), 72, t, 0.002, 0.18, 0.55);
        this.tone(o, 'sine', 520 * r(), 460, t + 0.025, 0.003, 0.45, 0.11);
        break;
      }
      case 'choir': {
        const o = this.out(x, z, 0.58 * intensity, 0.85);
        this.burst(o, t, 0.55, 0.22, 'bandpass', 380, 1200, 1.4);
        for (const [i, f] of [196, 246.9, 293.7].entries()) this.tone(o, 'sine', f * r(), f * 0.995, t + i * 0.045, 0.12, 1.15, 0.14);
        break;
      }
      case 'crow': {
        const o = this.out(x, z, 0.36 * intensity, 0.35);
        this.burst(o, t, 0.26, 0.24, 'bandpass', 2100, 900, 3);
        this.tone(o, 'sawtooth', 560 * r(), 210, t, 0.025, 0.22, 0.065);
        this.tone(o, 'sawtooth', 410 * r(), 180, t + 0.14, 0.012, 0.18, 0.035);
        break;
      }
      case 'bloodRite': {
        const o = this.out(x, z, 0.46 * intensity, 0.5);
        this.burst(o, t, 0.37, 0.36, 'lowpass', 280, 1300, 0.8, true);
        this.tone(o, 'sine', 96, 54, t + 0.08, 0.03, 0.52, 0.32);
        break;
      }
      case 'veilRite': {
        const o = this.out(x, z, 0.43 * intensity, 0.68);
        this.burst(o, t, 0.55, 0.2, 'bandpass', 450, 3400, 0.9);
        this.tone(o, 'sine', 360 * r(), 920, t + 0.06, 0.18, 0.52, 0.12);
        this.tone(o, 'sine', 540 * r(), 1380, t + 0.11, 0.14, 0.47, 0.07);
        break;
      }
      case 'spiritBolt': {
        const o = this.out(x, z, 0.36 * intensity, 0.5);
        this.burst(o, t, 0.18, 0.35, 'bandpass', 550, 2500, 2);
        this.tone(o, 'sine', 650 * r(), 1150, t, 0.015, 0.25, 0.12);
        break;
      }
      // --- second pass: synthesised fallbacks (the recorded layer plays when loaded) ---
      case 'reel': {
        const o = this.out(x, z, 0.3, 0.3);
        for (let i = 0; i < 6; i++) this.burst(o, t + i * 0.07, 0.02, 0.4, 'bandpass', 2800 + i * 90, 2400, 6);
        this.burst(o, t + 0.45, 0.35, 0.3, 'bandpass', 1300, 500, 0.8);
        break;
      }
      case 'sawpit': {
        const o = this.out(x, z, 0.3, 0.2);
        this.burst(o, t, 0.4, 0.28, 'bandpass', 1500, 2200, 2);
        this.burst(o, t + 0.5, 0.4, 0.28, 'bandpass', 2200, 1400, 2);
        this.burst(o, t + 1.05, 0.1, 0.4, 'lowpass', 500, 160, 1, true);
        break;
      }
      case 'kiln': {
        const o = this.out(x, z, 0.35, 0.3);
        this.burst(o, t, 1.2, 0.35, 'lowpass', 900, 250, 0.8, true);
        for (let i = 0; i < 6; i++) this.burst(o, t + 0.1 + Math.random() * 1.1, 0.02, 0.4, 'highpass', 4000, 4000, 1);
        break;
      }
      case 'cook': {
        const o = this.out(x, z, 0.3, 0.25);
        this.burst(o, t, 1, 0.3, 'highpass', 4500, 6000, 0.8);
        this.tone(o, 'triangle', 640 * r(), 600, t, 0.002, 0.3, 0.08);
        break;
      }
      case 'grind': {
        const o = this.out(x, z, 0.4, 0.2);
        this.burst(o, t, 1.1, 0.3, 'lowpass', 800, 400, 1.2, true);
        for (let i = 0; i < 4; i++) this.burst(o, t + 0.12 + i * 0.2, 0.05, 0.5, 'bandpass', 1100 * r(), 700, 4);
        break;
      }
      case 'craft': {
        const o = this.out(x, z, 0.35, 0.25);
        this.tone(o, 'triangle', 1500 * r(), 1300, t, 0.001, 0.25, 0.14);
        this.burst(o, t, 0.06, 0.55, 'bandpass', 2000, 1200, 3);
        break;
      }
      case 'vaultOpen':
      case 'vaultClose': {
        const o = this.out(undefined, undefined, 0.4, 0.5);
        const open = name === 'vaultOpen';
        this.burst(o, t, 0.7, 0.25, 'bandpass', open ? 300 : 700, open ? 700 : 250, 5, true);
        this.tone(o, 'sine', open ? 110 : 90, 50, t + (open ? 0.5 : 0.05), 0.005, 0.3, 0.4);
        this.burst(o, t + (open ? 0.05 : 0.15), 0.04, 0.5, 'bandpass', 2400, 2400, 5);
        break;
      }
      case 'siphon': {
        const o = this.out(x, z, 0.4, 0.5);
        this.burst(o, t, 1.3, 0.25, 'bandpass', 900, 500, 2);
        this.tone(o, 'sine', 330, 190, t, 0.1, 1.2, 0.1);
        break;
      }
      case 'prison': {
        const o = this.out(x, z, 0.5, 0.35);
        for (let i = 0; i < 4; i++) this.burst(o, t + i * 0.06, 0.06, 0.7, 'bandpass', 1200 - i * 150, 700, 4);
        this.tone(o, 'sine', 100, 48, t + 0.1, 0.005, 0.5, 0.5);
        break;
      }
      case 'hands': {
        const o = this.out(x, z, 0.5, 0.4);
        this.burst(o, t, 0.5, 0.45, 'lowpass', 700, 180, 0.9, true);
        for (let i = 0; i < 5; i++) this.burst(o, t + 0.15 + i * 0.1, 0.06, 0.4, 'bandpass', 900 + Math.random() * 600, 600, 3);
        break;
      }
      case 'storm': {
        const o = this.out(x, z, 0.5, 0.4);
        this.burst(o, t, 1.5, 0.35, 'bandpass', 500, 1700, 1.5);
        for (let i = 0; i < 8; i++) this.burst(o, t + 0.1 + i * 0.15, 0.04, 0.4, 'bandpass', 1500 + Math.random() * 800, 1000, 5);
        break;
      }
      case 'soulRelease': {
        const o = this.out(x, z, 0.5, 0.7);
        this.burst(o, t, 0.5, 0.3, 'bandpass', 400, 3200, 1.5);
        this.bell(o, t + 0.45, 523 * r(), 1.2, 0.1);
        this.tone(o, 'sine', 80, 40, t + 0.45, 0.01, 0.7, 0.45);
        break;
      }
      case 'sigWall': {
        const o = this.out(x, z, 0.55, 0.4);
        this.tone(o, 'sine', 70, 38, t, 0.005, 0.7, 0.8);
        this.burst(o, t, 0.5, 0.5, 'lowpass', 1100, 200, 0.9, true);
        break;
      }
      case 'sigRend': {
        const o = this.out(x, z, 0.5, 0.3);
        this.burst(o, t, 0.35, 0.5, 'bandpass', 3000, 900, 1.5);
        this.burst(o, t + 0.2, 0.08, 0.5, 'lowpass', 500, 180, 1, true);
        break;
      }
      case 'sigDirge': {
        const o = this.out(x, z, 0.5, 0.9);
        this.bell(o, t, 130 * r(), 2, 0.12);
        this.tone(o, 'sine', 65, 60, t, 0.2, 1.6, 0.3);
        break;
      }
      case 'sigBloom': {
        const o = this.out(x, z, 0.5, 0.5);
        this.burst(o, t, 0.7, 0.35, 'bandpass', 600, 1200, 1.2);
        for (let i = 0; i < 6; i++) {
          const f = 160 + Math.random() * 260;
          this.tone(o, 'sine', f, f * 1.7, t + 0.08 + i * 0.09, 0.005, 0.07, 0.14);
        }
        break;
      }
      case 'panelOpen':
      case 'panelClose': {
        const o = this.out(undefined, undefined, 0.2, 0.15);
        const open = name === 'panelOpen';
        this.burst(o, t, 0.1, 0.4, 'bandpass', open ? 1400 : 1900, open ? 2600 : 900, 1.2);
        break;
      }
      case 'equip': {
        const o = this.out(undefined, undefined, 0.3, 0.2);
        this.burst(o, t, 0.1, 0.4, 'bandpass', 900, 500, 1);
        this.tone(o, 'triangle', 1700 * r(), 1500, t + 0.07, 0.002, 0.18, 0.1);
        break;
      }
      case 'lootRare': {
        const o = this.out(undefined, undefined, 0.3, 0.6);
        this.bell(o, t, 988, 0.9, 0.09);
        break;
      }
      case 'lootEpic': {
        const o = this.out(undefined, undefined, 0.35, 0.8);
        this.bell(o, t, 660, 1.6, 0.11);
        this.bell(o, t + 0.1, 990, 1.4, 0.08);
        break;
      }
      case 'bogBubble': {
        const o = this.out(x, z, 0.2, 0.8);
        const f = 180 + Math.random() * 120;
        this.tone(o, 'sine', f, f * 2.2, t, 0.004, 0.14, 0.2);
        this.tone(o, 'sine', f * 1.4, f * 3, t + 0.22, 0.004, 0.1, 0.12);
        break;
      }
      case 'crowCaw': {
        const o = this.out(x, z, 0.25, 0.8);
        this.tone(o, 'sawtooth', 600 * r(), 330, t, 0.02, 0.22, 0.06);
        this.burst(o, t, 0.2, 0.12, 'bandpass', 1500, 900, 3);
        break;
      }
      case 'windGust': {
        const o = this.out(x, z, 0.25, 0.7);
        this.burst(o, t, 3.2, 0.25, 'bandpass', 400, 900, 1, true);
        break;
      }
      case 'crowdMoan': {
        const o = this.out(x, z, 0.2, 0.9);
        this.burst(o, t, 3, 0.18, 'bandpass', 350, 450, 5);
        break;
      }
      case 'dustFall': {
        const o = this.out(x, z, 0.18, 0.5);
        for (let i = 0; i < 6; i++) this.burst(o, t + i * 0.09, 0.03, 0.3, 'highpass', 3200, 3200, 1);
        break;
      }
      case 'distantBell': {
        const o = this.out(x, z, 0.12, 0.95);
        const f = 147 * r();
        for (const [ratio, peak] of [[1, 0.08], [1.56, 0.025], [2.51, 0.018]])
          this.tone(o, 'sine', f * ratio, f * ratio * 0.998, t, 0.004, 2.6, peak);
        break;
      }
      case 'graveCreak': {
        const o = this.out(x, z, 0.16, 0.8);
        this.burst(o, t, 0.75, 0.2, 'bandpass', 850, 180, 8, true);
        this.tone(o, 'sawtooth', 130 * r(), 83, t, 0.1, 0.6, 0.025);
        break;
      }
      case 'waterDrip': {
        const o = this.out(x, z, 0.18, 0.9);
        this.tone(o, 'sine', 980 * r(), 470, t, 0.002, 0.24, 0.2);
        this.burst(o, t, 0.025, 0.18, 'highpass', 2400, 2400);
        break;
      }
    }
  }

  // --- ambience ------------------------------------------------------------

  /**
   * Crossfade to the area's ambience bed: recorded noise loops when they have loaded,
   * otherwise the synthesised wind, plus low drones. `force` rebuilds the current area
   * (used once the loops finish loading).
   */
  setArea(area: AreaId, force = false) {
    this.wantArea = area;
    if (this.ctx && !force) this.syncAreaPacks(area);
    if (!this.ctx || (this.ambience.area === area && !force)) return;
    if (this.ambienceAccentTimer) clearTimeout(this.ambienceAccentTimer);
    const c = this.ctx;
    const t = c.currentTime;
    if (this.ambience.gain) {
      const old = this.ambience;
      old.gain!.gain.setTargetAtTime(0.0001, t, 0.8);
      setTimeout(() => old.nodes.forEach((n) => (n as AudioScheduledSourceNode).stop?.()), 4000);
    }
    const gain = c.createGain();
    gain.gain.value = 0.0001;
    gain.gain.setTargetAtTime(1, t, 1.2);
    gain.connect(this.bedDuck);
    const nodes: AudioNode[] = [];
    const bed = ZONE_BEDS[area];
    const wind = (lp: number, amt: number) => {
      const s = c.createBufferSource();
      s.buffer = this.brown;
      s.loop = true;
      const f = c.createBiquadFilter();
      f.type = 'lowpass';
      f.frequency.value = lp;
      const g = c.createGain();
      g.gain.value = amt;
      const lfo = c.createOscillator();
      lfo.frequency.value = 0.07 + Math.random() * 0.05;
      const lg = c.createGain();
      lg.gain.value = lp * 0.5;
      lfo.connect(lg);
      lg.connect(f.frequency);
      s.connect(f);
      f.connect(g);
      g.connect(gain);
      s.start();
      lfo.start();
      nodes.push(s, lfo);
    };
    const loop = (file: string, amt: number, rate = 1, lp?: number) => {
      const s = c.createBufferSource();
      s.buffer = this.samples.buffer(file)!;
      s.loop = true;
      s.playbackRate.value = rate;
      // Start each layer at a random point so two layers of one file never phase together.
      const g = c.createGain();
      g.gain.value = amt;
      if (lp) {
        const f = c.createBiquadFilter();
        f.type = 'lowpass';
        f.frequency.value = lp;
        s.connect(f);
        f.connect(g);
      } else s.connect(g);
      g.connect(gain);
      s.start(0, Math.random() * s.buffer.duration);
      nodes.push(s);
    };
    const drone = (f: number, amt: number) => {
      for (const det of [-3, 4]) {
        const o = c.createOscillator();
        o.type = 'sawtooth';
        o.frequency.value = f;
        o.detune.value = det;
        const lp = c.createBiquadFilter();
        lp.type = 'lowpass';
        lp.frequency.value = f * 3;
        const g = c.createGain();
        g.gain.value = amt;
        o.connect(lp);
        lp.connect(g);
        g.connect(gain);
        o.start();
        nodes.push(o);
      }
    };
    const recorded = bedReady(area, (f) => this.samples.has(f));
    this.bedKind = recorded ? 'loops' : 'synth';
    if (recorded) for (const l of bed.loops) loop(l.file, l.gain * LOOP_TRIM, l.rate, l.lp);
    else for (const [lp, amt] of bed.wind) wind(lp, amt);
    for (const [f, amt] of bed.drones) drone(f, amt);
    this.ambience = { area, nodes, gain };
    this.scheduleAmbienceAccent(area, true);
  }

  /** One sparse detail per long, random gap; skipped (and retried soon) while a fight is on. */
  private scheduleAmbienceAccent(area: AreaId, first = false) {
    const delay = first ? accentGap(area, Math.random()) * 0.5 : accentGap(area, Math.random());
    this.ambienceAccentTimer = setTimeout(() => {
      if (this.ambience.area !== area || !this.ctx) return;
      if (!accentsAllowed(this.activity.level(this.ctx.currentTime))) {
        this.ambienceAccentTimer = setTimeout(() => this.scheduleAmbienceAccent(area, true), 4000);
        return;
      }
      const distance = 7 + Math.random() * 9;
      const angle = Math.random() * Math.PI * 2;
      this.play(pickAccent(area, Math.random()),
        this.listener.x + Math.cos(angle) * distance,
        this.listener.z + Math.sin(angle) * distance);
      this.scheduleAmbienceAccent(area);
    }, delay * 1000);
  }

  stopArea() {
    this.wantArea = null;
    if (this.ambienceAccentTimer) clearTimeout(this.ambienceAccentTimer);
    this.ambienceAccentTimer = null;
    if (this.ctx && this.ambience.gain) {
      const old = this.ambience;
      old.gain!.gain.setTargetAtTime(0.0001, this.ctx.currentTime, 0.5);
      setTimeout(() => old.nodes.forEach((n) => (n as AudioScheduledSourceNode).stop?.()), 3000);
    }
    this.ambience = { area: null, nodes: [], gain: null };
    this.bedKind = 'none';
    this.setBossBed(false);
  }

  /** A slow war-drum pulse under boss fights. */
  private setBossBed(on: boolean) {
    if (!this.ctx) return;
    const c = this.ctx;
    if (!on) {
      this.bossBed?.gain.setTargetAtTime(0.0001, c.currentTime, 1);
      this.bossBed = null;
      return;
    }
    if (this.bossBed) return;
    const bed = c.createGain();
    bed.gain.value = 1;
    bed.connect(this.bedGain);
    this.bossBed = bed;
    const beat = () => {
      if (this.bossBed !== bed || !this.ctx) return;
      const t = this.ctx.currentTime + 0.02;
      for (const [off, f, v] of [[0, 62, 0.55], [0.42, 58, 0.35], [1.2, 62, 0.45]] as const) {
        this.tone(bed, 'sine', f, 38, t + off, 0.004, 0.45, v);
      }
      setTimeout(beat, 1600);
    };
    beat();
  }
}

export const audio = new AudioEngine();
