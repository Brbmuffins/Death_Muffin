import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// Owner (Helix, 2026-10-04): every window has a fixed header (title + close button) and scrolls only its body.
// A window that draws a `.cw-panel-head` must call wrapPanelBody after drawing, or its header scrolls away with the content.
const UI_DIR = join(__dirname, '..');
const EXEMPT = new Set(['TabbedWindow.ts', 'panelBody.ts']); // the tab window scrolls `.cw-tabwin-body` instead

describe('window header', () => {
  it('every window that draws a panel head wraps its body so only the body scrolls', () => {
    const missing: string[] = [];
    for (const f of readdirSync(UI_DIR).filter((n) => n.endsWith('.ts') && !EXEMPT.has(n))) {
      const src = readFileSync(join(UI_DIR, f), 'utf8');
      if (src.includes('cw-panel-head') && !src.includes('wrapPanelBody(')) missing.push(f);
    }
    expect(missing).toEqual([]);
  });

  // Helix, 2026-10-04: scrolling windows get a Back to top button; it lives in wrapPanelBody so every window has it.
  it('wrapPanelBody adds a Back to top button that shows only after scrolling', () => {
    const src = readFileSync(join(UI_DIR, 'panelBody.ts'), 'utf8');
    expect(src).toContain('Back to top');
    expect(src).toContain('BACK_TO_TOP_AFTER');
    const css = readFileSync(join(UI_DIR, 'ui.css'), 'utf8');
    expect(css).toContain('.cw-back-top.show button');
  });
});
