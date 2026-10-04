/**
 * The belt picker: click a Z / X slot on the HUD belt and choose which brew from the bag it holds. Built on demand (never per frame),
 * one small popup beside the belt. Pure `pickerTitle` / `emptyPickerText` keep the wording testable.
 */
export interface BeltChoice {
  id: string;
  label: string;
  glyph: string;
  color: number;
  effect: string;
  count: number;
  /** The brew the slot drinks now. */
  current: boolean;
}

export const BELT_DRAG_TYPE = 'application/x-dm-belt-item';

export function pickerTitle(slotName: string, key: string): string {
  return `${slotName} slot · key ${key}`;
}

/** Shown when the bag has nothing for the slot. */
export function emptyPickerText(slotName: string): string {
  const kind = slotName.toLowerCase();
  return `No ${kind}s in your bag. Brew ${kind === 'elixir' ? 'an' : 'a'} ${kind} in the Alchemist's Wing (the Chapterhouse's east door), then click here again.`;
}

export class BeltPicker {
  private el: HTMLDivElement | null = null;
  private onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopImmediatePropagation();
      this.close();
    }
  };
  private onDown = (e: PointerEvent) => {
    if (this.el && !this.el.contains(e.target as Node) && !(e.target as HTMLElement).closest?.('[data-brew]')) this.close();
  };

  constructor(private host: HTMLElement, private onPick: (id: string) => void) {}

  get isOpen(): boolean {
    return !!this.el;
  }

  open(slotName: string, key: string, choices: BeltChoice[]) {
    this.close();
    const el = document.createElement('div');
    el.className = 'belt-picker cw-plate';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-label', pickerTitle(slotName, key));
    const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
    el.innerHTML = `<div class="bp-head">${esc(pickerTitle(slotName, key))}</div>${
      choices.length
        ? choices
            .map(
              (c) =>
                `<button type="button" class="bp-row${c.current ? ' cur' : ''}" data-pick="${esc(c.id)}" style="--brew:#${c.color.toString(16).padStart(6, '0')}"><span class="g">${esc(c.glyph)}</span><span class="t"><b>${esc(c.label)}</b><i>${esc(c.effect)}</i></span><span class="n">${c.current ? 'on belt · ' : ''}×${c.count}</span></button>`,
            )
            .join('')
        : `<p class="bp-empty">${esc(emptyPickerText(slotName))}</p>`
    }<div class="bp-foot">You can also drag a brew from your bag onto the slot.</div>`;
    el.addEventListener('click', (e) => {
      const b = (e.target as HTMLElement).closest<HTMLElement>('[data-pick]');
      if (!b) return;
      const id = b.dataset.pick!;
      this.close();
      this.onPick(id);
    });
    this.host.appendChild(el);
    this.el = el;
    window.addEventListener('keydown', this.onKey, true);
    window.addEventListener('pointerdown', this.onDown, true);
  }

  close() {
    if (!this.el) return;
    this.el.remove();
    this.el = null;
    window.removeEventListener('keydown', this.onKey, true);
    window.removeEventListener('pointerdown', this.onDown, true);
  }
}
