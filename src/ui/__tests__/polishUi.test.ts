import { describe, expect, it } from 'vitest';
import { dropStale } from '../Onboarding';
import { isMinorLoot, lootToastLine, lootToastMs } from '../lootToast';
import { EQUIP_SLOTS } from '../../content/gear';

describe('counsel cards whose context is gone', () => {
  it('drops a stale card and keeps the rest in order', () => {
    const q = [{ id: 'thrall' }, { id: 'wave' }, { id: 'litany' }];
    expect(dropStale(q, (id) => id === 'thrall').map((t) => t.id)).toEqual(['wave', 'litany']);
  });
  it('returns the same queue when nothing is stale', () => {
    const q = [{ id: 'wave' }];
    expect(dropStale(q, () => false)).toBe(q);
  });
});

describe('pickup toasts', () => {
  it('merges repeats into a count', () => {
    expect(lootToastLine('Bone Dust', 1)).toBe('Bone Dust');
    expect(lootToastLine('Bone Dust', 3)).toBe('Bone Dust ×3');
  });
  it('commons are brief, rare and better stay', () => {
    expect(isMinorLoot('common')).toBe(true);
    expect(isMinorLoot('rare')).toBe(false);
    expect(lootToastMs('common')).toBeLessThan(lootToastMs('rare'));
    expect(lootToastMs('legendary')).toBe(8000);
  });
});

describe('paper doll', () => {
  it('gives every slot its own glyph', () => {
    const glyphs = EQUIP_SLOTS.map((s) => s.glyph);
    expect(new Set(glyphs).size).toBe(glyphs.length);
  });
});
