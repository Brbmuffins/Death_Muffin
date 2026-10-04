import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MusicDirector } from '../music';

/** Minimal stand-ins: an <audio> element that "plays" at once, and an AudioContext with inert nodes. */
class FakeAudio {
  static made: FakeAudio[] = [];
  duration = 85; currentTime = 0; paused = true; loop = false; preload = ''; readyState = 4;
  private on: Record<string, (() => void)[]> = {};
  constructor(public src: string) { FakeAudio.made.push(this); }
  addEventListener(k: string, f: () => void) { (this.on[k] ??= []).push(f); }
  fire(k: string) { for (const f of this.on[k] ?? []) f(); }
  play() { this.paused = false; return Promise.resolve(); }
  pause() { this.paused = true; }
  removeAttribute() {}
  load() {}
}
const node = () => ({ connect() {}, disconnect() {}, gain: { value: 1, setTargetAtTime() {}, cancelScheduledValues() {} } });
const ctx = { currentTime: 0, createGain: node, createMediaElementSource: node } as unknown as AudioContext;
const flush = () => new Promise((r) => setTimeout(r, 0));

describe('music director', () => {
  beforeEach(() => { FakeAudio.made = []; vi.stubGlobal('Audio', FakeAudio); });
  afterEach(() => vi.unstubAllGlobals());

  it('plays the area theme, crossfades to the boss cue and back', async () => {
    const m = new MusicDirector(ctx, node() as unknown as AudioNode);
    m.setVolume(0.8); m.setArea('graves'); await flush();
    expect(m.cue).toBe('graves');
    m.setBoss(true); await flush();
    expect(m.cue).toBe('boss');
    m.setBoss(false); await flush();
    expect(m.cue).toBe('graves');
    expect(FakeAudio.made.every((a) => !a.loop)).toBe(true);
  });

  it('loops by handing over to a fresh copy just before the end (no MP3 loop gap)', async () => {
    const m = new MusicDirector(ctx, node() as unknown as AudioNode);
    m.setVolume(0.8); m.setArea('chapterhouse'); await flush();
    const first = FakeAudio.made[0];
    first.currentTime = 40; first.fire('timeupdate');
    expect(FakeAudio.made).toHaveLength(1); // mid-track: nothing happens
    first.currentTime = first.duration - 2; first.fire('timeupdate'); first.fire('timeupdate');
    expect(FakeAudio.made).toHaveLength(2); // one hand-over, not one per tick
    await flush();
    expect(m.cue).toBe('chapterhouse');
    expect(m.status.current).toBe('chapterhouse');
    first.fire('ended'); // the retired copy ending does not start a third
    expect(FakeAudio.made).toHaveLength(2);
  });

  it('music off stops it; turning it back on resumes the area theme', async () => {
    const m = new MusicDirector(ctx, node() as unknown as AudioNode);
    m.setVolume(0.8); m.setArea('pyre'); await flush();
    m.setVolume(0); await flush();
    expect(m.cue).toBeNull();
    m.setVolume(0.5); await flush();
    expect(m.cue).toBe('pyre');
  });
});
