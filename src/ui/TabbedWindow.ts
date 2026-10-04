import type { RevealId } from './progressiveHud';

/** What a tab hosts: any existing panel (open / close / isOpen) mounted into the tab's slot element instead of the scene root. */
export interface HostedPanel {
  open(): void | Promise<void>;
  close(): void;
  readonly isOpen: boolean;
}

export interface TabSpec {
  id: string;
  label: string;
  /** The key that used to open this panel, shown on the tab. */
  key?: string;
  /** NEW-cue id for the tab's pip. */
  newId?: RevealId;
  /** Hide the tab entirely (a necromancer-only Legion tab). */
  hidden?: boolean;
}

export interface TabbedWindowOptions {
  title: string;
  aria: string;
  /** Extra class on the plate, e.g. `cw-tabwin-acre`. */
  className?: string;
  tabs: TabSpec[];
  /** A tab became the visible one (clear its NEW cue, play a sound, stop gathering...). */
  onTab?: (id: string) => void;
}

/**
 * One window that hosts several existing panels as tabs. Panels keep their own code: each is built with the tab's slot as its root,
 * so it appends its own plate there (CSS flattens that plate: ui.css `.cw-tabwin-slot`). Only the visible tab's panel is open, so
 * an Acre ledger on the Skills tab polls nothing for Contracts. The window is created once and attached to the scene root on open.
 */
export class TabbedWindow {
  private el = document.createElement('div');
  private strip: HTMLElement;
  private slots = new Map<string, HTMLElement>();
  private panels = new Map<string, HostedPanel>();
  private buttons = new Map<string, HTMLButtonElement>();
  private active: string | null = null;
  private opened = false;

  constructor(private root: HTMLElement, private opts: TabbedWindowOptions) {
    this.el.className = `cw-plate cw-panel-float wide cw-tabwin ${opts.className ?? ''}`.trim();
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', opts.aria);
    this.el.innerHTML = `
      <div class="cw-panel-head"><h2 class="cw-title">${opts.title}</h2><button class="cw-icon-btn" data-close aria-label="Close ${opts.aria}">✕</button></div>
      <div class="cw-tabwin-strip" role="tablist" aria-label="${opts.aria}"></div>
      <div class="cw-tabwin-body"></div>`;
    this.strip = this.el.querySelector('.cw-tabwin-strip')!;
    const body = this.el.querySelector('.cw-tabwin-body')!;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    for (const t of opts.tabs) {
      const slot = document.createElement('div');
      slot.className = 'cw-tabwin-slot';
      slot.dataset.tab = t.id;
      slot.hidden = true;
      body.appendChild(slot);
      this.slots.set(t.id, slot);
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'cw-tabwin-tab';
      b.dataset.tab = t.id;
      b.setAttribute('role', 'tab');
      b.hidden = !!t.hidden;
      b.innerHTML = `<span>${t.label}</span>${t.key ? `<kbd>${t.key}</kbd>` : ''}${t.newId ? `<i class="dm-pip" data-new="${t.newId}" hidden>NEW</i>` : ''}`;
      b.addEventListener('click', () => this.open(t.id));
      this.strip.appendChild(b);
      this.buttons.set(t.id, b);
    }
  }

  /** The element a tab's panel must be constructed with as its root. */
  slot(id: string): HTMLElement {
    return this.slots.get(id)!;
  }

  attach(id: string, panel: HostedPanel) {
    this.panels.set(id, panel);
  }

  get isOpen() {
    return this.opened;
  }

  get activeTab() {
    return this.active;
  }

  /** Show or hide a tab (the Legion tab exists for necromancers only). */
  setTabHidden(id: string, hidden: boolean) {
    const b = this.buttons.get(id);
    if (b) b.hidden = hidden;
  }

  /** Draw or clear the NEW pip on a tab. */
  setNew(newId: string, on: boolean) {
    this.el.querySelectorAll<HTMLElement>(`[data-new="${newId}"]`).forEach((p) => (p.hidden = !on));
    this.el.querySelectorAll<HTMLElement>(`.cw-tabwin-tab:has([data-new="${newId}"])`).forEach((b) => b.classList.toggle('dm-glow', on));
  }

  /** Open on a tab (the first tab by default); a tab already showing stays as it is. */
  open(tab?: string) {
    const id = tab && this.slots.has(tab) ? tab : this.active ?? this.opts.tabs.find((t) => !t.hidden)?.id ?? this.opts.tabs[0].id;
    if (!this.opened) {
      this.root.appendChild(this.el);
      this.opened = true;
    }
    if (this.active === id && this.panels.get(id)?.isOpen) return;
    if (this.active && this.active !== id) {
      this.panels.get(this.active)?.close();
      this.slots.get(this.active)!.hidden = true;
    }
    this.active = id;
    this.slots.get(id)!.hidden = false;
    for (const [k, b] of this.buttons) {
      b.classList.toggle('on', k === id);
      b.setAttribute('aria-selected', String(k === id));
    }
    void this.panels.get(id)?.open();
    this.opts.onTab?.(id);
  }

  close() {
    if (!this.opened) return;
    for (const p of this.panels.values()) p.close();
    for (const s of this.slots.values()) s.hidden = true;
    this.el.remove();
    this.opened = false;
    this.active = null;
  }

  dispose() {
    this.close();
  }
}
