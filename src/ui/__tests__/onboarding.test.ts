import { describe, expect, it } from 'vitest';
import { TIPS, renderText } from '../Onboarding';
import fixture from './tips-desktop.fixture.json';

describe('onboarding tips', () => {
  it('every tip has a title and a body', () => {
    for (const [id, tip] of Object.entries(TIPS)) {
      expect(tip.title.trim().length, id).toBeGreaterThan(0);
      expect(tip.body.trim().length, id).toBeGreaterThan(20);
    }
  });

  it('bodies only use the trusted inline markup (kbd, b)', () => {
    for (const [id, tip] of Object.entries(TIPS)) {
      const tags = [...tip.body.matchAll(/<\/?([a-z0-9]+)[^>]*>/gi)].map((m) => m[1].toLowerCase());
      for (const t of tags) expect(['kbd', 'b'], `${id}: <${t}>`).toContain(t);
    }
  });

  it('opens with a welcome before the movement lesson', () => {
    const ids = Object.keys(TIPS);
    expect(ids.indexOf('welcome')).toBeLessThan(ids.indexOf('move'));
  });
});

describe('onboarding tips text', () => {
  const keyFor = (id: string) => ({ exhume: '2', black_litany: '3', grave_offering: '4', ivory_cleave: '1', veil_step: '5', carrion_seed: '4' } as Record<string, string>)[id] ?? null;
  // The tip table as it was before touch wording existed (the PC-only branch must still match it) (keys resolved with the same stub).
  const before = fixture as Record<string, { title: string; body: string }>;
  const oldBody = (b: string) => b.replace(/\{key:(\w+)\}/g, (_m, a: string) => { const k = keyFor(a); return k ? `<kbd>${k}</kbd>` : 'a key from your Grimoire (<kbd>L</kbd>)'; });

  it('every tip reads byte-for-byte as before on desktop', () => {
    expect(Object.keys(TIPS).sort()).toEqual(Object.keys(before).sort());
    for (const [id, tip] of Object.entries(TIPS)) {
      expect(renderText(tip.title), id).toBe(before[id].title);
      expect(renderText(tip.body, keyFor), id).toBe(oldBody(before[id].body));
    }
  });

  it('resolves key markup', () => {
    expect(renderText('Loot goes to your Reliquary{p:I}.')).toBe('Loot goes to your Reliquary (<kbd>I</kbd>).');
    expect(renderText('Press {key:exhume} now', keyFor)).toBe('Press <kbd>2</kbd> now');
    expect(renderText('Press {key:nope} now')).toContain('<kbd>L</kbd>');
  });
});
