import { describe, expect, it } from 'vitest';
import { veilLabel } from '../LoadVeil';

describe('load veil', () => {
  it('words the progress in steps and ends on ready', () => {
    expect(veilLabel(0)).toBe('Lighting the braziers');
    expect(veilLabel(0.5)).toBe('Raising the walls');
    expect(veilLabel(0.9)).toBe('Laying out the dead');
    expect(veilLabel(1)).toBe('The Covenant is ready');
  });
});
