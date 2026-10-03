import { describe, expect, it } from 'vitest';
import { plotStateAt } from '../gardenView';

describe('plotStateAt', () => {
  const growing = { seedId: 'seed_moss', readyAt: 60_000, state: 'growing' as const };
  it('a plot fetched as growing turns ready once the server clock passes readyAt', () => {
    expect(plotStateAt(growing, 59_999)).toBe('growing');
    expect(plotStateAt(growing, 60_000)).toBe('ready');
  });
  it('an empty plot stays empty', () => {
    expect(plotStateAt({ seedId: null, readyAt: 0, state: 'empty' }, 1e12)).toBe('empty');
  });
});

import { useCompost } from '../gardenView';
describe('useCompost', () => {
  it('a tick left over from the last bone meal is not sent', () => {
    expect(useCompost(true, 0)).toBe(false);
    expect(useCompost(true, 2)).toBe(true);
    expect(useCompost(false, 2)).toBe(false);
  });
});
