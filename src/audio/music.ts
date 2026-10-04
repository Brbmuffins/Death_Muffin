import type { AreaId } from '../content/areas';
import { sliderGain } from './mixer';

export type MusicCue = 'chapterhouse' | 'graves' | 'ossuary' | 'pyre' | 'boss';

/** Five themes cover the world without restarting on every adjacent room. */
export const MUSIC_FOR_AREA: Record<AreaId, Exclude<MusicCue, 'boss'>> = {
  chapterhouse: 'chapterhouse',
  alchemist_wing: 'chapterhouse',
  acre: 'chapterhouse', // the calm, enemy-free gathering sanctuary takes the quiet theme (owner, 2026-10-04)
  graves: 'graves',
  cloister: 'graves',
  fen: 'graves',
  coliseum: 'graves',
  ossuary: 'ossuary',
  nave: 'ossuary',
  sanctum: 'ossuary',
  warren: 'ossuary',
  depths: 'ossuary',
  pyre: 'pyre',
};

const FADE_SECONDS = 3;
const MUSIC_TRIM = 0.72;

interface Slot {
  cue: MusicCue;
  element: HTMLAudioElement;
  source: MediaElementAudioSourceNode;
  gain: GainNode;
}

/** Streams one cue at a time and crossfades on room or boss changes. */
export class MusicDirector {
  private output: GainNode;
  private combatDuck: GainNode;
  private cueDuck: GainNode;
  private current: Slot | null = null;
  private pending: Slot | null = null;
  private desired: MusicCue | null = null;
  private area: AreaId | null = null;
  private boss = false;
  private volume = 0;
  private serial = 0;
  private lastError: string | null = null;

  constructor(private ctx: AudioContext, destination: AudioNode) {
    this.output = ctx.createGain();
    this.combatDuck = ctx.createGain();
    this.cueDuck = ctx.createGain();
    this.output.connect(this.combatDuck);
    this.combatDuck.connect(this.cueDuck);
    this.cueDuck.connect(destination);
    this.output.gain.value = 0;
  }

  get cue(): MusicCue | null { return this.current?.cue ?? null; }
  get status() {
    return { desired: this.desired, pending: this.pending?.cue ?? null, current: this.current?.cue ?? null,
      paused: this.current?.element.paused ?? null, readyState: this.current?.element.readyState ?? null, error: this.lastError };
  }

  setVolume(value: number) {
    const previous = this.volume;
    this.volume = value;
    this.output.gain.setTargetAtTime(sliderGain(value) * MUSIC_TRIM, this.ctx.currentTime, 0.08);
    if (value <= 0 && previous > 0) this.change(null);
    else if (value > 0 && previous <= 0) this.sync();
  }

  setArea(area: AreaId | null) {
    if (this.area === area) return;
    this.area = area;
    this.boss = false;
    this.sync();
  }

  setBoss(active: boolean) {
    if (this.boss === active) return;
    this.boss = active;
    this.sync();
  }

  setCombatLevel(level: number) {
    const depth = this.boss ? 0.2 : 0.38;
    const gain = 1 - depth * Math.min(1, Math.max(0, level));
    this.combatDuck.gain.setTargetAtTime(gain, this.ctx.currentTime, 0.3);
  }

  duckForCue(depth: number, hold: number, release: number) {
    const t = this.ctx.currentTime;
    const gain = this.cueDuck.gain;
    gain.cancelScheduledValues(t);
    gain.setTargetAtTime(1 - depth, t, 0.03);
    gain.setTargetAtTime(1, t + hold, release);
  }

  private sync() {
    this.change(this.area && this.volume > 0 ? this.boss ? 'boss' : MUSIC_FOR_AREA[this.area] : null);
  }

  private change(cue: MusicCue | null) {
    if (cue === this.desired) return;
    this.desired = cue;
    if (!cue || this.current?.cue === cue) {
      this.serial++;
      if (this.pending) this.dispose(this.pending);
      this.pending = null;
      if (!cue && this.current) { this.retire(this.current); this.current = null; }
      return;
    }
    this.start(cue);
  }

  /**
   * Start `cue` in a new element and crossfade to it once it plays. Also used to loop: an MP3 played with `loop = true` leaves a short
   * silent gap at every restart (encoder padding), so each track instead hands over to a fresh copy of itself just before it ends.
   * The cues are prepared with their tail crossfaded into their head (tools/audio/prepare-eleven-music.mjs), so the handover is seamless.
   */
  private start(cue: MusicCue) {
    const serial = ++this.serial;
    if (this.pending) this.dispose(this.pending);
    const element = new Audio(`${import.meta.env.BASE_URL}audio/music/${cue}.mp3`);
    element.preload = 'auto';
    const source = this.ctx.createMediaElementSource(element);
    const gain = this.ctx.createGain();
    gain.gain.value = 0;
    source.connect(gain);
    gain.connect(this.output);
    const slot: Slot = { cue, element, source, gain };
    this.pending = slot;
    const handOver = () => {
      if (this.current !== slot || this.pending || this.desired !== cue) return;
      const left = element.duration - element.currentTime;
      if (Number.isFinite(left) && left <= FADE_SECONDS + 0.25) this.start(cue);
    };
    element.addEventListener('timeupdate', handOver);
    element.addEventListener('ended', handOver);
    // Calling play now preserves the first-gesture permission; the promise resolves after buffering.
    void element.play().then(() => {
      if (serial !== this.serial) { this.dispose(slot); return; }
      this.pending = null;
      this.lastError = null;
      const t = this.ctx.currentTime;
      if (this.current) this.retire(this.current);
      this.current = slot;
      gain.gain.setTargetAtTime(1, t, FADE_SECONDS / 3);
    }).catch((error: unknown) => {
      if (serial !== this.serial) return;
      // A browser may require another gesture, or the file may be unavailable.
      this.lastError = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      this.pending = null;
      this.dispose(slot);
      // A failed hand-over keeps the playing copy going (and lets it loop on its own) rather than falling silent.
      if (this.current?.cue === cue) { this.current.element.loop = true; return; }
      this.desired = null;
    });
  }

  private retire(slot: Slot) {
    slot.gain.gain.setTargetAtTime(0, this.ctx.currentTime, FADE_SECONDS / 3);
    setTimeout(() => this.dispose(slot), FADE_SECONDS * 1000 + 300);
  }

  private dispose(slot: Slot) {
    slot.element.pause();
    slot.element.removeAttribute('src');
    slot.element.load();
    slot.source.disconnect();
    slot.gain.disconnect();
  }
}
