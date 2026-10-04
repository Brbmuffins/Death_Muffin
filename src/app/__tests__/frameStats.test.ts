import { describe, expect, it } from 'vitest';
import { FrameStats, verdict } from '../frameStats';

describe('frame stats', () => {
  it('keeps about one second of frames and reports fps, worst and hitches', () => {
    const st = new FrameStats();
    for (let i = 0; i < 200; i++) st.push({ frameMs: 16.7, updateMs: 3, renderMs: 2 });
    st.push({ frameMs: 120, updateMs: 1, renderMs: 110 });
    const s = st.summary(16.7)!;
    expect(s.fps).toBeGreaterThan(45);
    expect(s.fps).toBeLessThan(60);
    expect(s.worstMs).toBe(120);
    expect(s.hitches).toBe(1);
  });
  it('is empty before any frame', () => {
    expect(new FrameStats().summary(16.7)).toBeNull();
  });
  it('averages GPU time once queries report', () => {
    const st = new FrameStats();
    st.push({ frameMs: 33, updateMs: 4, renderMs: 3 });
    expect(st.summary(16.7)!.gpuMs).toBeNull();
    st.pushGpu(28);
    st.pushGpu(30);
    expect(st.summary(16.7)!.gpuMs).toBe(29);
  });
});

describe('verdict', () => {
  it('holding the cap is ok', () => expect(verdict(16.9, 15, 15, 16.7)).toBe('ok'));
  it('CPU work filling the frame is cpu-bound', () => expect(verdict(33, 28, 10, 16.7)).toBe('cpu'));
  it('measured GPU time filling the frame is gpu-bound', () => expect(verdict(33, 6, 30, 16.7)).toBe('gpu'));
  it('without timer queries, an idle CPU on a slow frame means waiting on the GPU', () => expect(verdict(33, 6, null, 16.7)).toBe('gpu'));
  it('neither side dominating is unclear', () => expect(verdict(33, 18, 12, 16.7)).toBe('unclear'));
});
