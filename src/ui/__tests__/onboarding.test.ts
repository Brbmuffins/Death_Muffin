import { describe, expect, it } from 'vitest';
import { TIPS } from '../Onboarding';

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
