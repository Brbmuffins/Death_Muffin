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

describe('onboarding tips by device', () => {
  const keyFor = (id: string) => ({ exhume: '2', black_litany: '3', grave_offering: '4', ivory_cleave: '1', veil_step: '5', carrion_seed: '4' } as Record<string, string>)[id] ?? null;
  // The tip table as it was before touch wording existed (keys resolved with the same stub).
  const before = fixture as Record<string, { title: string; body: string }>;
  const oldBody = (b: string) => b.replace(/\{key:(\w+)\}/g, (_m, a: string) => { const k = keyFor(a); return k ? `<kbd>${k}</kbd>` : 'a key from your Grimoire (<kbd>L</kbd>)'; });

  it('every tip reads byte-for-byte as before on desktop', () => {
    expect(Object.keys(TIPS).sort()).toEqual(Object.keys(before).sort());
    for (const [id, tip] of Object.entries(TIPS)) {
      expect(renderText(tip.title, false), id).toBe(before[id].title);
      expect(renderText(tip.body, false, keyFor), id).toBe(oldBody(before[id].body));
    }
  });

  it('touch text names no keyboard or mouse input', () => {
    let changed = 0;
    for (const [id, tip] of Object.entries(TIPS)) {
      const text = renderText(`${tip.title} ${tip.body}`, true, keyFor);
      expect(text, id).not.toMatch(/<kbd>|WASD|\bclick|right-click|\bEsc\b|\bhover|\bmouse|\bcursor|\bLMB\b/i);
      expect(text, id).not.toMatch(/\[\[|\]\]|\{p:|\{key:/);
      if (text !== renderText(`${tip.title} ${tip.body}`, false, keyFor)) changed++;
    }
    expect(changed).toBeGreaterThan(40);
  });

  it('auto combat is owner-only: its text is dropped for everyone else', () => {
    expect(renderText('Hold 1.{auto} On Easy, Auto (G) plays for you.{/auto}', false)).toBe('Hold 1.');
    expect(renderText(TIPS.signature.body, false)).not.toMatch(/\bAuto\b|\bEasy\b/);
    expect(renderText(TIPS.grimoire.body, false)).not.toMatch(/\bauto\b|\bEasy\b/i);
  });

  it('touch wording reads naturally in a few samples', () => {
    expect(renderText(TIPS.welcome.body, true)).toContain('drag a finger');
    expect(renderText(TIPS.warden_oil.body, true)).toContain('the third rite on your hotbar');
    expect(renderText('Loot goes to your Reliquary{p:I}; the Workbench{p:C} crafts.', true)).toBe('Loot goes to your Reliquary (in the Menu); the Workbench crafts.');
    expect(renderText('Press {key:exhume} now', true)).toBe('Press Exhume now');
    expect(renderText('Press {key:exhume} now', false, keyFor)).toBe('Press <kbd>2</kbd> now');
  });
});

describe('tip anchors (the HUD part a card lights up)', () => {
  it('every anchor names something the HUD actually renders', async () => {
    const { TIP_ANCHOR } = await import('../Onboarding');
    const fs = await import('node:fs');
    const hud = fs.readFileSync(new URL('../HUD.ts', import.meta.url), 'utf8');
    const menuKeys = [...hud.matchAll(/\['([a-z]+)', '/g)].map((m) => m[1]);
    for (const [id, sel] of Object.entries(TIP_ANCHOR)) {
      expect(id in TIPS, id).toBe(true);
      for (const part of sel!.split(',').map((x) => x.trim())) {
        const open = /^\[data-open="(\w+)"\]$/.exec(part);
        if (open) { expect(menuKeys, `${id}: ${part}`).toContain(open[1]); continue; }
        const token = /^\[(data-[\w-]+)(?:="([^"]+)")?\]$/.exec(part) ?? /^\.([\w-]+)$/.exec(part);
        expect(token, `${id}: ${part}`).not.toBeNull();
        expect(hud.includes(token![2] ?? token![1]), `${id}: ${part}`).toBe(true);
      }
    }
  });
});
