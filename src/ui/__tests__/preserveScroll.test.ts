import { describe, expect, it } from 'vitest';
import { preserveScroll } from '../preserveScroll';

// No DOM environment is configured, so model just the bits the helper touches. A redraw replaces children and zeroes scroll.
type Fake = { tagName: string; className: string; scrollTop: number; scrollLeft: number; kids: Fake[]; querySelectorAll: () => Fake[] };
const node = (className: string, scrollTop = 0): Fake => {
  const n: Fake = { tagName: 'DIV', className, scrollTop, scrollLeft: 0, kids: [], querySelectorAll: () => n.kids };
  return n;
};

describe('preserveScroll', () => {
  it('restores panel and inner list scroll after a redraw resets them', () => {
    const panel = node('panel', 120);
    panel.kids = [node('cw-skill-grid', 300), node('other')];
    preserveScroll(panel as unknown as HTMLElement, () => {
      panel.scrollTop = 0;
      panel.kids = [node('cw-skill-grid'), node('other')];
    });
    expect(panel.scrollTop).toBe(120);
    expect(panel.kids[0].scrollTop).toBe(300);
    expect(panel.kids[1].scrollTop).toBe(0);
  });

  it('matches repeated same-class lists by occurrence and returns the redraw result', () => {
    const panel = node('panel');
    panel.kids = [node('list'), node('list', 40)];
    const out = preserveScroll(panel as unknown as HTMLElement, () => {
      panel.kids = [node('list'), node('list')];
      return 7;
    });
    expect(out).toBe(7);
    expect(panel.kids.map((k) => k.scrollTop)).toEqual([0, 40]);
  });
});
