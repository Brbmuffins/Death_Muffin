import { onSettingsChange, settings, updateSettings } from '../app/settings';
import { browserStorage, type StorageLike } from '../gameplay/codexJournal';

/**
 * First-time contextual tips, shown once per character. A small reliquary card
 * above the hotbar: it never takes focus or pauses play, dismisses on click or
 * after 8s (longer cards stay longer), and queues so two tips never stack. "Don't show tips" (here or in
 * Settings) turns the whole sequence off via app/settings `tips`.
 */
export type TipId =
  | 'welcome'
  | 'move'
  | 'exhume'
  | 'wave'
  | 'deacon'
  | 'gate'
  // Just-in-time counsel for the rest of the kit and the loop.
  | 'essence'
  | 'thrall'
  | 'litany'
  | 'burst'
  | 'hurt'
  | 'elite'
  | 'surge'
  | 'relic'
  | 'codex'
  | 'signature'
  | 'prelate'
  | 'ascend'
  | 'souls'
  | 'sanctify'
  | 'boons';

interface Tip {
  title: string;
  /** Trusted static HTML (kbd hints only). */
  body: string;
}

export const TIPS: Record<TipId, Tip> = {
  welcome: {
    title: 'The Chapterhouse',
    body: 'Your sanctuary: the dead cannot follow you here. Around you stand the Reliquary, the Workbench, the Altar and a Waystone. The Hollow Graves lie <b>north</b>, through the open gate. <kbd>Esc</kbd> sets difficulty and graphics.',
  },
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
    body: 'You can afford to <b>Quicken</b> the waves (lower right). Faster waves bring more dead and richer rewards. The three diamonds are milestones (tiers 3, 6 and 8) that add wave affixes; hover them. Use <kbd>−</kbd> to dial the active tier back down whenever the pressure is too much.',
  },
  deacon: {
    title: 'Kill the Crypt Deacon first',
    body: 'Deacons steal unclaimed corpses and raise them as Risen against you. Watch for the green beam, and put it down before it reaches the dead.',
  },
  gate: {
    title: 'A sealed door',
    body: 'This gate stays sealed until you have slain enough of the dead on this side. The count sits under the map, top right.',
  },
  essence: {
    title: 'Grave Essence',
    body: 'Rites cost essence (the blue orb). Bone Needle is free, and every needle hit refunds some, so keep a target under attack between rites.',
  },
  thrall: {
    title: 'Your first thrall',
    body: 'It follows you and fights what you fight. Raise more with <kbd>2</kbd> up to your cap (the skull count, lower right); past the cap your oldest crumbles. A corpse remembers what it was: Penitents rise as archers, Deacons as bone mages, Carrion Sacs as plague bearers.',
  },
  litany: {
    title: 'Black Litany',
    body: 'Press <kbd>4</kbd> to give everything within 7m (corpses and thralls) to one burst. The more you give, the harder it hits. Pull the pack onto a pile of bodies first.',
  },
  burst: {
    title: 'Corpse Explosion',
    body: '<kbd>Right-click</kbd> a corpse to burst it under a pack. Best when the dead are already on you, or your legion is full.',
  },
  hurt: {
    title: 'Hurt?',
    body: 'Press <kbd>Q</kbd> to drink a healing flask. <kbd>T</kbd> returns you to the Chapterhouse. Falling costs nothing but the walk back, and <kbd>−</kbd> on the Wave Speed dial eases the pressure.',
  },
  elite: {
    title: 'An elite',
    body: 'Elites glow and carry an affix; read its tag in the target frame (top) before you engage. They drop soul shards, and five shards summon the Prelate.',
  },
  surge: {
    title: 'Grave Surge',
    body: 'A crypt has cracked open. Kill most of what climbs out before it seals (about 20s) and it yields a guaranteed relic and bonus gold.',
  },
  relic: {
    title: 'A relic',
    body: 'Loot goes to your Reliquary (<kbd>I</kbd>). Equip gear there; the Workbench (<kbd>C</kbd>) turns ore and bars into more.',
  },
  codex: {
    title: 'The Codex',
    body: 'Press <kbd>K</kbd> for everything you have met: every rite, every kind of dead, and how to beat it.',
  },
  signature: {
    title: 'Your signature rite awakens',
    body: 'Level 10: press <kbd>R</kbd> for your discipline\'s own rite. Hover the new slot to read what it does.',
  },
  ascend: {
    title: 'The Altar of Ascension stirs',
    body: 'The Prelate has fallen. At the Altar in the Chapterhouse you may <b>Ascend</b>: your tiers, shards and opened seals reset, but you keep your level, gold and relics, earn Ashes for permanent boons, and the dead grow older and richer.',
  },
  souls: {
    title: 'Soul Harvest',
    body: 'The skull above your hotbar is full. Your next Marrow Spear, Miasma Circle or Black Litany is <b>free and 50% larger</b>; the empowered slots glow jade.',
  },
  sanctify: {
    title: 'Sanctified',
    body: 'That pale gold halo is a Deacon\'s blessing: the enemy takes 30% less damage while it lasts. Kill the Deacon, or turn your rites on something else until it fades.',
  },
  boons: {
    title: 'Ashes to spend',
    body: 'Your Ashes buy permanent <b>Covenant Boons</b> at the Altar of Ascension: more health, cheaper upgrades, a head start on every run, even another thrall at higher ranks.',
  },
  prelate: {
    title: 'Five soul shards',
    body: 'Enough to wake the Bell-Sworn Prelate. Offer them at the Sundered Bell in the Bell Sanctum, and learn to step out of its bronze rings.',
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
    // Long counsel stays up longer: ~280ms per word, never under SHOW_MS.
    const words = tip.body.replace(/<[^>]+>/g, ' ').split(/\s+/).filter(Boolean).length;
    const ms = Math.max(SHOW_MS, words * 280);
    el.style.setProperty('--tip-ms', `${ms}ms`);
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
    this.hideTimer = this.later(() => this.dismiss(), ms);
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

  /** Forget which tips this character has seen, so the whole sequence plays again. */
  reset() {
    this.clear();
    this.seen.clear();
    this.persist();
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
