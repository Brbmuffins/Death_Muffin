import { onSettingsChange, settings, updateSettings } from '../app/settings';
import { browserStorage, type StorageLike } from '../gameplay/codexJournal';

/**
 * First-time contextual tips, shown once per character. A small reliquary card
 * above the hotbar: it never takes focus or pauses play, dismisses on click or
 * after 8s, and queues so two tips never stack. "Don't show tips" (here or in
 * Settings) turns the whole sequence off via app/settings `tips`.
 */
export type TipId = 'move' | 'exhume' | 'wave' | 'deacon' | 'gate';

interface Tip {
  title: string;
  /** Trusted static HTML (kbd hints only). */
  body: string;
}

export const TIPS: Record<TipId, Tip> = {
  move: {
    title: 'Walk among the dead',
    body: '<kbd>Click</kbd> the ground to walk. <kbd>Click</kbd> an enemy to loose Bone Needles at it; every hit refills Grave Essence. <kbd>Shift</kbd>+<kbd>Click</kbd> casts without moving.',
  },
  exhume: {
    title: 'A corpse lies near',
    body: 'Press <kbd>2</kbd> to Exhume the corpse nearest your cursor and raise it as your thrall. Unclaimed bodies rot away.',
  },
  wave: {
    title: 'Wave Speed',
    body: 'You can afford to <b>Quicken</b> the waves (lower right). Faster waves bring more dead and richer rewards. Use <kbd>−</kbd> to dial the active tier back down whenever the pressure is too much.',
  },
  deacon: {
    title: 'Kill the Crypt Deacon first',
    body: 'Deacons steal unclaimed corpses and raise them as Risen against you. Watch for the green beam, and put it down before it reaches the dead.',
  },
  gate: {
    title: 'A sealed door',
    body: 'This gate stays sealed until you have slain enough of the dead on this side. The count sits under the map, top right.',
  },
};

const SHOW_MS = 8000;
const GAP_MS = 500;
const tipsKey = (characterId: number) => `cw_tips_v1_${characterId}`;
const TIP_IDS = Object.keys(TIPS) as TipId[];

export class Onboarding {
  private seen = new Set<TipId>();
  private queue: TipId[] = [];
  private pending = new Set<TipId>();
  private el: HTMLDivElement | null = null;
  private timers = new Set<number>();
  private hideTimer = 0;
  private offSettings: () => void;
  private key: string;

  constructor(
    private root: HTMLElement,
    characterId: number,
    private storage: StorageLike | null = browserStorage(),
  ) {
    this.key = tipsKey(characterId);
    try {
      const raw = this.storage?.getItem(this.key);
      const list: unknown = raw ? JSON.parse(raw) : [];
      if (Array.isArray(list)) for (const id of list) if (TIP_IDS.includes(id as TipId)) this.seen.add(id as TipId);
    } catch {
      /* storage unavailable or corrupt — tips simply show again */
    }
    this.offSettings = onSettingsChange((s) => {
      if (!s.tips) this.clear();
    });
  }

  /** Show a tip once per character (no-op when seen, queued, or tips are off). */
  show(id: TipId, delayMs = 0) {
    if (!settings.tips || this.seen.has(id) || this.pending.has(id) || this.queue.includes(id)) return;
    if (delayMs > 0) {
      this.pending.add(id);
      this.later(() => {
        this.pending.delete(id);
        this.show(id);
      }, delayMs);
      return;
    }
    if (this.el) this.queue.push(id);
    else this.present(id);
  }

  private present(id: TipId) {
    if (!settings.tips || this.seen.has(id)) return this.next();
    this.seen.add(id);
    this.persist();
    const tip = TIPS[id];
    const el = document.createElement('div');
    el.className = 'cw-plate cw-tip';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    el.style.setProperty('--tip-ms', `${SHOW_MS}ms`);
    el.innerHTML = `
      <div class="kicker">Covenant counsel</div>
      <div class="title">${tip.title}</div>
      <div class="body">${tip.body}</div>
      <div class="foot"><span>Click to dismiss</span><button type="button" data-skip>Don't show tips</button></div>
      <div class="timer"></div>`;
    el.addEventListener('click', () => this.dismiss());
    el.querySelector('[data-skip]')!.addEventListener('click', (e) => {
      e.stopPropagation();
      updateSettings({ tips: false });
    });
    this.root.appendChild(el);
    this.el = el;
    this.hideTimer = this.later(() => this.dismiss(), SHOW_MS);
  }

  private dismiss() {
    const el = this.el;
    if (!el) return;
    this.el = null;
    this.cancel(this.hideTimer);
    el.classList.add('out');
    this.later(() => el.remove(), 220);
    this.later(() => this.next(), GAP_MS);
  }

  private next() {
    const id = this.queue.shift();
    if (id && !this.el) this.present(id);
  }

  /** Hide the current card and drop everything queued (tips turned off). */
  private clear() {
    this.queue = [];
    this.pending.clear();
    for (const t of this.timers) window.clearTimeout(t);
    this.timers.clear();
    this.el?.remove();
    this.el = null;
  }

  private persist() {
    try {
      this.storage?.setItem(this.key, JSON.stringify([...this.seen]));
    } catch {
      /* storage unavailable — the tip may show again next session */
    }
  }

  private later(fn: () => void, ms: number) {
    const t = window.setTimeout(() => {
      this.timers.delete(t);
      fn();
    }, ms);
    this.timers.add(t);
    return t;
  }

  private cancel(t: number) {
    window.clearTimeout(t);
    this.timers.delete(t);
  }

  dispose() {
    this.clear();
    this.offSettings();
  }
}
