import { describe, expect, it } from 'vitest';
import { unlockLevel } from '../../content/abilities';
import { PLAYABLE_DISCIPLINES } from '../../content/disciplines';
import { topicLines } from '../../content/dialogue';
import { kitFor } from '../../content/kits';
import { baseState, formatSealProgress, nextSuggestion, pendingSeals, sealDoorName } from '../../gameplay/guidance';
import { FIRST_RUN_DISCIPLINE, recommendedForFirstRun, swapReady } from '../firstHourRules';

describe('one seal-progress format that names the door', () => {
  it('reads "<Door> seal: n/need kills" for every sealed hall', () => {
    expect(formatSealProgress('ossuary', 0, 300)).toBe('Ossuary seal: 0/300 kills');
    expect(formatSealProgress('warren', 0, 150)).toBe('Warren seal: 0/150 kills');
    expect(formatSealProgress('nave', 12, 420)).toBe('Nave seal: 12/420 kills');
    expect(formatSealProgress('fen', 800, 800)).toBe('Fen seal: 800/800 kills');
  });
  it('caps the count at the need and names every door by one word', () => {
    expect(formatSealProgress('ossuary', 999, 300)).toBe('Ossuary seal: 300/300 kills');
    expect(sealDoorName('coliseum')).toBe('Coliseum');
  });
  it('is what the Next line and the Prior say', () => {
    const s = baseState({ area: 'graves', totalKills: 0, areaKills: { graves: 0 } });
    expect(nextSuggestion(s)!.text).toBe('Ossuary seal: 0/300 kills');
    expect(pendingSeals(s).map((x) => formatSealProgress(x.area, x.kills, x.need))).toEqual(['Ossuary seal: 0/300 kills', 'Warren seal: 0/150 kills']);
    expect(topicLines('prior', 'seals', s).join(' ')).toContain('Ossuary seal: 0/300 kills');
  });
});

describe('hotbar swap visibility', () => {
  const grimoire = kitFor('necromancer').grimoire;
  const first = Math.min(...grimoire.map(unlockLevel).filter((l) => l > 1));
  it('is hidden at level 1 and shown from the first alternative rite on', () => {
    expect(first).toBeGreaterThan(1);
    expect(swapReady(grimoire, 1)).toBe(false);
    expect(swapReady(grimoire, first - 1)).toBe(false);
    expect(swapReady(grimoire, first)).toBe(true);
    expect(swapReady(grimoire, 60)).toBe(true);
  });
  it('stays hidden for an empty pool', () => {
    expect(swapReady([], 60)).toBe(false);
  });
});

describe('first-run class recommendation', () => {
  it('badges Gravecaller only for an account with no character', () => {
    expect(FIRST_RUN_DISCIPLINE).toBe('gravecaller');
    expect(recommendedForFirstRun('gravecaller', false)).toBe(true);
    expect(recommendedForFirstRun('gravecaller', true)).toBe(false);
  });
  it('badges nothing else', () => {
    expect(PLAYABLE_DISCIPLINES.filter((d) => recommendedForFirstRun(d.id, false)).map((d) => d.id)).toEqual(['gravecaller']);
  });
});
