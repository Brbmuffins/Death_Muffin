import { onSettingsChange, settings, updateSettings } from '../app/settings';
import { browserStorage, type StorageLike } from '../gameplay/codexJournal';

/**
 * First-time contextual tips, shown once per character. A small reliquary card
 * movable by its header: it never takes focus or pauses play, dismisses on click or
 * after 8s (longer cards stay longer), and queues so two tips never stack. "Don't show tips" (here or in
 * Settings) turns the whole sequence off via app/settings `tips`.
 */
export type TipId =
  | 'minimap'
  | 'auto_combat'
  | 'change_class'
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
  | 'boons'
  // The Grimoire and its level-gated rites (shown the first time each is placed on a key).
  | 'grimoire'
  | 'rite_skull'
  | 'rite_step'
  | 'rite_frost'
  | 'rite_mantle'
  // Enemy variety: processions and the four newer kinds of dead (first sight).
  | 'procession'
  | 'censer'
  | 'wraith'
  | 'swarm'
  | 'golem'
  // Professions (docs/PROFESSIONS-ROADMAP.md §11).
  | 'acre'
  | 'gather'
  | 'bag_full'
  | 'skill_up'
  | 'rich_node'
  | 'station';

interface Tip {
  title: string;
  /**
   * Trusted static HTML (kbd hints only). `{key:<abilityId>}` becomes the key that
   * rite sits on in the player's Grimoire loadout (see Onboarding.keyFor).
   */
  body: string;
}

export const TIPS: Record<TipId, Tip> = {
  minimap: {
    title: 'Choose your path',
    body: 'Click a walkable spot on the minimap to travel there. The amber marker shows your fixed destination. Click another spot to change it; sealed halls stay closed. Hover a spell icon for its cost, targeting, effects and a useful combat tip.',
  },
  auto_combat: {
    title: 'Settle into the fight',
    body: 'Auto combat uses nearby targets and basic rites while you stand still. Click to move whenever you like; your hero stays where you choose. Toggle it with <kbd>G</kbd> or the Auto button. Hold <kbd>1</kbd>–<kbd>4</kbd> to repeat a rite at your cursor. Signature rites remain yours to cast.',
  },
  change_class: {
    title: 'A new discipline',
    body: 'Choose a class here whenever you want. Your level, gold, items and permanent progress stay with the same character. Changing discipline returns you safely to the Chapterhouse with its new model and passives.',
  },
  welcome: {
    title: 'The Sexton\'s Acre',
    body: 'Begin at your own pace: this gathering sanctuary has <b>no enemies</b>. Click a tree, ore seam, fishing spot or grave to work it; <kbd>P</kbd> opens Skills. When you want combat, walk <b>east</b> to the Chapterhouse, then <b>north</b> through its open gate into the Hollow Graves. <kbd>T</kbd> returns you to the Chapterhouse. <kbd>Esc</kbd> sets difficulty and graphics.',
  },
  move: {
    title: 'Walk among the dead',
    body: '<kbd>Click</kbd> the ground to walk to that spot; click again to change destination. While standing, face and aim toward the mouse. While walking, face your path. <kbd>Click</kbd> an enemy to loose Bone Needles at it; every hit refills Grave Essence. Aim with the mouse and press <kbd>1</kbd>–<kbd>4</kbd> for rites. <kbd>Right-click</kbd> bursts corpses. <kbd>Shift</kbd>+<kbd>Click</kbd> attacks without moving.',
  },
  exhume: {
    title: 'A corpse lies near',
    body: 'Press {key:exhume} to Exhume the corpse nearest your cursor and raise it as your thrall. Unclaimed bodies rot away.',
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
    body: 'Press {key:black_litany} to give everything within 7m (corpses and thralls) to one burst. The more you give, the harder it hits. Pull the pack onto a pile of bodies first.',
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
  grimoire: {
    title: 'The Grimoire',
    body: 'New rites have come to you. Press <kbd>L</kbd> (or the open-book button) to choose which four sit on keys <kbd>1</kbd>–<kbd>4</kbd>. Swap them whenever you like; each rite keeps its own cooldown, and auto combat uses whatever is on your bar.',
  },
  rite_skull: {
    title: 'Wailing Skull',
    body: 'The skull hunts the enemy nearest your cursor, then leaps on to two more, each bite a little weaker. Finish a wounded foe with it and it earns an extra leap. Good for elites and stragglers.',
  },
  rite_step: {
    title: 'Grave Step',
    body: 'Aim at a corpse up to 12m away to re-form on it in blood mist, bleeding everything beside it. The body stays, so follow with Corpse Explosion or Exhume. It never carries you through a sealed door.',
  },
  rite_frost: {
    title: 'Grave Frost',
    body: 'A cone of grave cold: everything it touches is <b>Chilled</b>, slower to move and to strike. Breathe on the same pack again and the Chilled enemies <b>shatter</b> for +50% damage.',
  },
  procession: {
    title: 'A procession',
    body: 'Not every wave is a mix. Now and then the dead arrive as a <b>procession</b>, a themed band named on the banner (hounds and rats, a choir, a censer and its bells). Read the name, then pick your rites for it.',
  },
  censer: {
    title: 'Censer Bearer',
    body: 'Its bronze incense <b>Incenses</b> the dead around it: faster feet, faster blows (bronze motes on them). Kill the censer first and the pack slows back down.',
  },
  wraith: {
    title: 'Choir Wraith',
    body: 'Pale song-lines mark a ring where you stand; when the hymn breaks, the ring screams. One step out is enough. Wraiths leave no corpse.',
  },
  swarm: {
    title: 'Skull-rats',
    body: 'They pour out in packs and leave no corpses. Needles are wasted on them: a Miasma, a Grave Frost cone or a Corpse Explosion ends a whole pack at once.',
  },
  golem: {
    title: 'Bone Golem',
    body: 'A slow giant with a wide bronze-brown slam ring: step out, then punish it. It falls apart into <b>three corpses</b>, a whole legion or a Litany in one kill.',
  },
  acre: {
    title: "The Sexton's Acre",
    body: 'No waves ever come here. <kbd>Click</kbd> a tree, an ore seam, a fishing spot on the pond or a burial plot, and your necromancer keeps working it until it is spent. Coffin-Oaks just north of the entrance, the nearby Copper Seam and Pauper’s Grave, and Still Pools on the pond are usable at <b>level 1</b>. The stronger nodes lie further from the door. Press <kbd>P</kbd> to see your skills.',
  },
  gather: {
    title: 'Working a node',
    body: 'Each swing, cast or dig is one work cycle; the ring under you fills as it goes. Every success gives skill XP and a find. For hands-off work in the Acre, open <kbd>P</kbd>, choose a node and <b>Start AFK</b>. Keep the game open: your hero changes nodes and waits for respawns until your bag fills. Skills can stay open; moving, casting or other panels pause work. <b>Pause AFK</b> stops it whenever you like.',
  },
  bag_full: {
    title: 'Your bag is full',
    body: 'Gathering stops when nothing more fits. Open the Reliquary (<kbd>I</kbd>) to drop or equip things, or take materials to the stations: the Bone Kiln, the Sawpit and the Cooking Fire stand by the Acre door.',
  },
  skill_up: {
    title: 'A skill rises',
    body: 'Each level improves your odds on every node of that skill and opens a stronger one. The Skills panel (<kbd>P</kbd>) shows what the next level unlocks and your total level.',
  },
  rich_node: {
    title: 'A rich node',
    body: 'Gold-lit nodes in the hunting grounds hold more before they are spent and come back twice as fast. Taking a hit stops gathering, so clear the dead around it first.',
  },
  station: {
    title: 'A working station',
    body: 'Stations turn what you gather into something useful. The Sawpit’s warm gold light marks where to click for wood recipes. Recipes need the matching skill level and their ingredients in your bag; crafting grants skill XP too. The server checks every recipe, and its reason is shown if one fails.',
  },
  rite_mantle: {
    title: 'Bone Mantle',
    body: 'Cast it standing among the dead: each corpse within 6m thickens a barrier that holds for 6 seconds, while whirling shards cut whatever reaches you. With no corpses you still get a thin mantle.',
  },
};

const SHOW_MS = 25000;
const GAP_MS = 500;
const tipsKey = (characterId: number) => `dm_tips_v1_${characterId}`;
const POSITION_KEY = 'dm_counsel_position_v1';
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
  private position: { x: number; y: number } | null = null;
  private onResize = () => { if (this.el) this.place(this.el); };
  /** The key a rite sits on (Grimoire loadout), or null when it isn't on the bar. */
  keyFor: ((abilityId: string) => string | null) | null = null;

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
    try {
      const saved = JSON.parse(this.storage?.getItem(POSITION_KEY) ?? 'null');
      if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) this.position = saved;
    } catch { /* Use the default position when storage is unavailable. */ }
    window.addEventListener('resize', this.onResize);
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
    const body = tip.body.replace(/\{key:(\w+)\}/g, (_m, ability: string) => {
      const k = this.keyFor?.(ability);
      return k ? `<kbd>${k}</kbd>` : 'a key from your Grimoire (<kbd>L</kbd>)';
    });
    const el = document.createElement('div');
    el.className = 'cw-plate cw-tip';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    // Give each card at least 25 seconds and longer counsel more reading time.
    const words = body.replace(/<[^>]+>/g, ' ').split(/\s+/).filter(Boolean).length;
    const ms = Math.max(SHOW_MS, 5000 + words * 600);
    el.style.setProperty('--tip-ms', `${ms}ms`);
    el.innerHTML = `
      <div class="kicker" data-move role="button" tabindex="0" aria-label="Move Covenant counsel" title="Drag to move, or use arrow keys"><span>⋮⋮ Covenant counsel</span><span class="move-hint">Drag to move</span></div>
      <div class="title">${tip.title}</div>
      <div class="body">${body}</div>
      <div class="foot"><span>Click to dismiss</span><button type="button" data-skip>Don't show tips</button></div>
      <div class="timer"></div>`;
    el.addEventListener('click', e => { if (!(e.target as HTMLElement).closest('[data-move]')) this.dismiss(); });
    el.querySelector('[data-skip]')!.addEventListener('click', (e) => {
      e.stopPropagation();
      updateSettings({ tips: false });
    });
    this.root.appendChild(el);
    this.el = el;
    this.place(el);
    const handle = el.querySelector<HTMLElement>('[data-move]')!;
    let drag: { pointer: number; x: number; y: number; left: number; top: number } | null = null;
    handle.addEventListener('pointerdown', e => {
      if (e.button !== 0 || drag) return;
      e.preventDefault(); e.stopPropagation();
      handle.focus({ preventScroll: true });
      const bounds = el.getBoundingClientRect();
      drag = { pointer: e.pointerId, x: e.clientX, y: e.clientY, left: bounds.left, top: bounds.top };
      el.style.animation = 'none';
      el.classList.add('dragging');
      handle.setPointerCapture(e.pointerId);
      pauseTimer();
    });
    handle.addEventListener('pointermove', e => {
      if (!drag || drag.pointer !== e.pointerId) return;
      e.preventDefault(); e.stopPropagation();
      this.place(el, drag.left + e.clientX - drag.x, drag.top + e.clientY - drag.y);
    });
    const endDrag = (e: PointerEvent) => {
      if (!drag || drag.pointer !== e.pointerId) return;
      e.stopPropagation();
      drag = null;
      el.classList.remove('dragging');
      if (handle.hasPointerCapture(e.pointerId)) handle.releasePointerCapture(e.pointerId);
      this.savePosition();
      if (!el.matches(':hover')) resumeTimer();
    };
    handle.addEventListener('pointerup', endDrag);
    handle.addEventListener('pointercancel', endDrag);
    handle.addEventListener('keydown', e => {
      const step = e.shiftKey ? 30 : 10;
      const moves: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
      const delta = moves[e.key];
      if (!delta) return;
      e.preventDefault(); e.stopPropagation();
      const bounds = el.getBoundingClientRect();
      this.place(el, bounds.left + delta[0], bounds.top + delta[1]);
      this.savePosition();
    });
    let remaining = ms;
    let startedAt = performance.now();
    const timer = el.querySelector<HTMLElement>('.timer')!;
    let paused = false;
    const pauseTimer = () => {
      if (paused) return;
      paused = true;
      remaining = Math.max(0, remaining - (performance.now() - startedAt));
      this.cancel(this.hideTimer);
      timer.style.animationPlayState = 'paused';
    };
    el.addEventListener('pointerenter', pauseTimer);
    const resumeTimer = () => {
      if (this.el !== el || drag || !paused) return;
      paused = false;
      this.cancel(this.hideTimer);
      startedAt = performance.now();
      timer.style.animationPlayState = 'running';
      this.hideTimer = this.later(() => this.dismiss(), remaining);
    };
    el.addEventListener('pointerleave', resumeTimer);
    this.hideTimer = this.later(() => this.dismiss(), remaining);
  }

  private place(el: HTMLElement, x = this.position?.x ?? 18, y = this.position?.y ?? 100) {
    const bounds = el.getBoundingClientRect();
    this.position = {
      x: Math.max(8, Math.min(x, window.innerWidth - bounds.width - 8)),
      y: Math.max(8, Math.min(y, window.innerHeight - bounds.height - 8)),
    };
    el.style.left = `${this.position.x}px`;
    el.style.top = `${this.position.y}px`;
  }

  private savePosition() {
    try { this.storage?.setItem(POSITION_KEY, JSON.stringify(this.position)); }
    catch { /* Position still works for this session. */ }
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
    window.removeEventListener('resize', this.onResize);
  }
}
