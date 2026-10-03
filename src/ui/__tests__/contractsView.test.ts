import { describe, expect, it } from 'vitest';
import { boardExpired } from '../contractsView';

describe('boardExpired', () => {
  it('is true from the reset instant on', () => {
    const reset = '2026-10-04T00:00:00.000Z';
    expect(boardExpired(reset, Date.parse(reset) - 1)).toBe(false);
    expect(boardExpired(reset, Date.parse(reset))).toBe(true);
    expect(boardExpired('garbage', 1e15)).toBe(false);
  });
});
