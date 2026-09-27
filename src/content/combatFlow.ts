import type { AbilityId } from './abilities';

/** Short commitment, quick recovery: gestures can blend while walking resumes. */
export const CAST_FLOW: Record<AbilityId, { lockMs: number; gestureSeconds: number }> = {
  bone_needle: { lockMs: 60, gestureSeconds: 0.22 },
  marrow_spear: { lockMs: 100, gestureSeconds: 0.30 },
  exhume: { lockMs: 110, gestureSeconds: 0.34 },
  miasma: { lockMs: 90, gestureSeconds: 0.30 },
  black_litany: { lockMs: 160, gestureSeconds: 0.48 },
  corpse_explosion: { lockMs: 70, gestureSeconds: 0.24 },
  ossuary_wall: { lockMs: 130, gestureSeconds: 0.36 },
  command_rend: { lockMs: 130, gestureSeconds: 0.36 },
  dirge: { lockMs: 130, gestureSeconds: 0.36 },
  plague_bloom: { lockMs: 130, gestureSeconds: 0.36 },
};
