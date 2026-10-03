import { describe, expect, it, vi } from 'vitest';
import { CONTROL_ACTIVE_SELECTOR, controlUnderPointer } from '../redrawGuard';
import { ProfessionsPanel } from '../ProfessionsPanel';
import type { Skills } from '../../gameplay/Gathering';

// No DOM environment: a fake panel that answers querySelector the way a browser would for a hovered control.
const fakePanel = (hovered: boolean) => ({ querySelector: (sel: string) => (hovered && sel === CONTROL_ACTIVE_SELECTOR ? {} : null) });

describe('redraw guard', () => {
  it('waits while the pointer is over a control or a dropdown has focus', () => {
    expect(controlUnderPointer(fakePanel(true))).toBe(true);
    expect(controlUnderPointer(fakePanel(false))).toBe(false);
    expect(controlUnderPointer(null)).toBe(false);
    for (const part of ['button:hover', 'select:hover', 'select:focus', 'input:hover', 'input:focus']) expect(CONTROL_ACTIVE_SELECTOR).toContain(part);
  });

  it('the Skills panel does not redraw under the pointer when AFK XP ticks, and does when it is clear', () => {
    const panel = new ProfessionsPanel({} as HTMLElement);
    const render = vi.spyOn(panel, 'render').mockImplementation(() => {});
    const skills = {} as Skills;
    (panel as unknown as { el: unknown }).el = fakePanel(true);
    panel.refresh(skills);
    expect(render).not.toHaveBeenCalled();
    (panel as unknown as { el: unknown }).el = fakePanel(false);
    panel.refresh(skills);
    expect(render).toHaveBeenCalledTimes(1);
  });
});
