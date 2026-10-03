import { ABILITIES, HOTBAR, type AbilityId, type HotbarSlot } from '../content/abilities';
import type { Discipline } from '../content/disciplines';
import type { EliteAffix } from '../content/enemies';
import { DAMAGE_UPGRADE, WAVE_MILESTONES, WAVE_UPGRADE, damageBonusPct, milestones, waveModifiers } from '../content/upgrades';
import { MAX_PARTY_SIZE } from '../net/config';
import { ICON } from './icons';
import { isMinorLoot, lootToastLine, lootToastMs } from './lootToast';
import type { Rarity } from '../net/types';
import { Minimap, type MinimapFrame } from './Minimap';
import { spellTooltip } from './spellTooltip';
import { RUNES, isRuneRite, type RuneRite } from '../content/runes';
import type { RuneSockets } from '../gameplay/runeRules';

/** Key caps under each hotbar slot (slot 5 is the right-click action). */
const SLOT_KEYS = ['1', '2', '3', '4', 'RMB', 'R'];
let nextTooltipId = 0;
/** Two small opposed arrows: the hotbar's swap affordance (replaces the old SWAP text). */
const SWAP_ICON = '<svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h15m-4-4l4 4-4 4"/><path d="M20 16H5m4-4l-4 4 4 4"/></svg>';

export type HudPanel = 'inventory' | 'forge' | 'professions' | 'settings' | 'map' | 'codex' | 'grimoire' | 'contracts' | 'garden' | 'labor' | 'cosmetics' | 'vault' | 'sheet' | 'legion' | 'atlas';
/** Menu row: icon + short label, tooltip with the key, aria name. */
const MENU_ROW: Array<[HudPanel, keyof typeof ICON, string, string, string]> = [
  ['inventory', 'bag', 'Bag', 'Reliquary (I)', 'Reliquary'],
  ['forge', 'anvil', 'Craft', 'Workbench (C)', 'Workbench'],
  ['professions', 'skills', 'Skills', 'Skills (P)', 'Skills'],
  ['map', 'waymap', 'Map', 'Waystones (M)', 'Waystones'],
  ['grimoire', 'grimoire', 'Spells', 'Grimoire (L)', 'Grimoire'],
  ['atlas', 'atlas', 'Atlas', 'Gear Atlas (.)', 'Gear Atlas'],
  ['codex', 'book', 'Codex', 'Codex (K)', 'Codex'],
  ['settings', 'gear', 'Settings', 'Settings (Esc)', 'Settings'],
];
export interface HudCallbacks {
  cast(slot: HotbarSlot): void;
  buyDamage(): void;
  buyWave(): void;
  dialWave(delta: number): void;
  open(panel: HudPanel): void;
  chat(text: string): void;
  toggleAutoCombat(): void;
  /** Open the Grimoire with a socket preselected (a rite index 0–4 or the LMB primary). */
  openGrimoire(select?: number | 'primary'): void;
  /** The player hid the "Next" suggestion with its X. */
  dismissNext?(): void;
}

export interface SlotFrame {
  left: number;
  total: number;
  affordable: boolean;
  /** Soul Harvest is charged and this spell will be free + 50% larger. */
  empowered?: boolean;
  /** Rite not yet unlocked (below its unlock level). */
  locked?: boolean;
}

export interface HudFrame {
  autoCombat: boolean;
  autoCombatAvailable: boolean;
  autoCombatVisible: boolean;
  hp: number;
  maxHp: number;
  barrier: number;
  /** The family resource (Grave Essence, Rage, …) and its ceiling. */
  essence: number;
  maxEssence: number;
  /** Right-orb label and liquid colour, from the family's resource rules. */
  resourceLabel?: string;
  resourceColor?: string;
  beatPulse?: boolean;
  level: number;
  xp: number;
  xpNext: number;
  slots: SlotFrame[];
  souls: number;
  soulsMax: number;
  thralls: number;
  thrallCap: number;
  gold: number;
  shards: number;
  damageTier: number;
  damagePct: number;
  damageCost: number | null;
  waveOwned: number;
  waveActive: number;
  wavePct: number;
  waveCost: number | null;
  areaName: string;
  areaProgress: string;
  /** Ossuary's Bone Ward: damage shaved off by the thralls standing now. Null for other disciplines. */
  ward: null | { pct: number; thralls: number; perThrall: number };
  /** The player raises thralls: Damage tiers only reach thralls raised after the purchase (legionKit.ts), and the tooltip says so. */
  raisesThralls?: boolean;
  /** The belt: always three slots (heal Q, elixir Z, tonic X); `empty` ones show a faint placeholder and the how-to-fill tip. */
  brews: { slot: string; key: string; label: string; glyph: string; color: number; active: boolean; left: number; frac: number; count: number; empty: boolean; tip: string }[];
  save: { text: string; warn: boolean };
  target: null | {
    name: string;
    elite: boolean;
    affix: { id: EliteAffix; name: string } | null;
    /** The Catacomb Depths: the affixes beyond the first (an elite on depth 5 bears two, on 10 three). */
    moreAffixes?: { id: EliteAffix; name: string }[];
    hp: number;
    maxHp: number;
    statuses: { icon: string; label: string; n: number }[];
    blurb: string;
  };
  boss: null | { name: string; phase: number; hp: number; maxHp: number; phases?: readonly string[] };
}

export interface PartyMember {
  id: string;
  name: string;
  discipline: string;
  portrait: string;
  hpFrac: number;
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/** The rune line on a rite's card: which rune sits in it and what it changes. */
function runeCard(id: AbilityId, runes: RuneSockets): string {
  const r = isRuneRite(id) ? runes[id as RuneRite] : undefined;
  if (!r) return '';
  const d = RUNES[r];
  return `<div class="spell-rune"><img src="art/items/${r}.webp" alt="" /><div><b>${esc(d.name)}</b><p>${d.lines.map(esc).join(' ')}${d.cost ? ` <em>${esc(d.cost)}</em>` : ''}</p></div></div>`;
}

/**
 * The in-world HUD. Built once; `update()` only writes DOM when a value
 * changes, so it's cheap to call every frame.
 */
export class HUD {
  readonly el = document.createElement('div');
  readonly minimap = new Minimap();
  private cache = new Map<string, string | number | boolean>();
  private $ = <T extends HTMLElement = HTMLElement>(sel: string) => this.el.querySelector<T>(sel)!;
  private tooltip = document.createElement('div');
  private tooltipSlot: number | null = null;
  private tooltipHideTimer = 0;
  private tooltipKey = '';
  private slotFrames: SlotFrame[] = [];
  /** Relic runes socketed in the rites (a small rune badge on the slot and a line on its card). */
  private runes: RuneSockets = {};
  private resizeTooltip = () => this.positionTooltip();
  private tooltipKeydown = (e: KeyboardEvent) => {
    if (e.key === 'Escape' && !this.tooltip.hidden) {
      e.preventDefault();
      e.stopImmediatePropagation();
      this.hideTooltip();
    }
  };

  constructor(
    root: HTMLElement,
    private cb: HudCallbacks,
    /** The slots in order: five Grimoire rites, then the signature rite. */
    private hotbar: AbilityId[] = HOTBAR,
    private discipline?: Discipline,
    /** The left-click primary shown in the LMB socket. */
    private primary: AbilityId = 'bone_needle',
  ) {
    this.el.className = 'hud';
    const slots = this.slotsHtml();
    this.el.innerHTML = `
      <div class="hud-vignette passive" data-vig></div>
      <div class="hud-party" data-party></div>
      <div class="hud-omen" data-omen hidden><img alt="" data-omen-img /><span data-omen-name></span></div>
      <div class="hud-ward" data-ward hidden></div>
      <div class="hud-brews" data-brews hidden></div>
      <div class="hud-chain passive" data-chain hidden aria-live="off">
        <div class="n" data-chain-n></div>
        <div class="lbl" data-chain-lbl></div>
        <div class="track"><div class="fill" data-chain-fill></div></div>
      </div>
      <div class="hud-target passive" data-target hidden>
        <div class="nm" data-tname></div>
        <div class="track"><div class="fill" data-thp></div></div>
        <div class="statuses" data-tstat></div>
        <div class="blurb" data-tblurb></div>
      </div>
      <div class="hud-boss cw-plate passive" data-boss hidden>
        <div class="nm" data-bname></div>
        <div class="ph" data-bphase></div>
        <div class="track"><div class="fill" data-bhp></div><div class="mark" style="left:60%"></div><div class="mark" style="left:30%"></div></div>
        <div class="hpnum" data-bnum></div>
      </div>
      <div class="hud-map">
        <div class="frame" data-mapframe></div>
        <div class="area" data-area></div>
        <div class="prog" data-prog></div>
        <div class="hud-depth passive" data-depth hidden role="status" aria-live="polite">
          <div class="row"><span class="d">Depth <b data-depth-n></b></span><span class="k" data-depth-k></span></div>
          <div class="track"><div class="fill" data-depth-fill></div></div>
          <div class="cue" data-depth-cue></div>
        </div>
        <div class="hud-next" data-next hidden role="status"><div class="txt"><span class="kick">Next</span><span data-nexttxt></span></div><button type="button" data-nextx aria-label="Hide this suggestion" title="Hide this suggestion (turn the line off in Settings)">×</button></div>
        <div class="hud-menu">
          ${MENU_ROW.map(([k, i, l, t, n]) => `<button class="hud-mi" data-open="${k}" title="${t}" aria-label="${n}">${ICON[i]}<span class="lbl">${l}</span></button>`).join('')}
          <button class="hud-auto" data-auto hidden aria-label="Auto combat" title="Available on Easy difficulty" aria-pressed="false">Auto: Easy only</button>
        </div>
      </div>
      <div class="hud-toasts passive" data-toasts></div>
      <div class="hud-nodetip passive" data-nodetip role="tooltip" hidden></div>
      <div class="hud-banner passive" data-banner><div class="t"></div><div class="rule"></div><div class="s"></div></div>
      <div class="hud-prompt passive" data-prompt hidden></div>
      <div class="hud-hint passive" data-hint></div>
      <div class="cw-chat">
        <div class="log" data-chatlog aria-live="polite"></div>
        <input data-chatin type="text" maxlength="240" placeholder="Enter to speak" aria-label="Chat message" />
      </div>
      <div class="hud-xp">
        <div class="hud-level" data-level aria-label="Level">1</div>
        <span class="hud-dev" data-dev hidden title="Dev access: every rite, area and gathering tier is open. Nothing is saved. Toggle it in Settings.">DEV</span>
        <div class="hud-xpbar">
          <div class="track"><div class="fill" data-xpfill></div></div>
          <div class="txt"><span>Experience</span><span data-xptxt></span></div>
        </div>
      </div>
      <div class="hud-altar">
        <div class="hud-orb-wrap">
          <div class="hud-orb hp" data-hporb role="meter" aria-label="Health"><div class="liquid"></div><div class="barrier"></div></div>
          <div class="hud-orb-label" data-hptxt></div>
        </div>
        <div>
          <div class="hud-souls" data-souls role="meter" aria-label="Soul Harvest" aria-valuemin="0" title="Soul Harvest — kills by you or your thralls fill the skull. When full, your next Marrow Spear, Miasma or Black Litany is free and 50% larger.">
            <span class="skull">${ICON.skull}</span>
            <div class="track"><div class="fill" data-soulfill></div></div>
            <span class="n" data-soultxt></span>
          </div>
          <div class="hud-slots-wrap">
            <div class="hud-slot primary" data-primarywrap>${this.primaryHtml()}</div>
            <div class="hud-slots">${slots}</div>
            <button class="hud-grimoire-btn" data-grimbtn aria-label="Swap spells in the Grimoire (L)">${ICON.grimoire}<span>Swap spells · L</span><span class="pip" data-grimpip hidden>NEW</span></button>
          </div>
          <div class="hud-thralls" data-thralls aria-label="Thralls"></div>
        </div>
        <div class="hud-orb-wrap">
          <div class="hud-orb ess" data-essorb role="meter" aria-label="Grave Essence"><div class="liquid"></div></div>
          <div class="hud-orb-label" data-esstxt></div>
        </div>
      </div>
      <div class="hud-right">
        <div class="hud-upgrades cw-plate">
          <div class="hud-up">
            <div class="icon">${ICON.crown}</div>
            <div class="row"><span class="pct" data-dmgpct></span><span class="lbl">Damage</span></div>
            <button class="buy" data-buydmg><span>Empower</span><b data-dmgcost></b></button>
            <div class="row" style="gap:8px"><div class="bar" style="flex:1"><div class="fill" data-dmgbar></div></div><div class="gems" data-dmggems></div></div>
          </div>
          <div class="hud-up">
            <div class="icon">${ICON.skull}</div>
            <div class="row"><span class="pct" data-wavepct></span><span class="lbl">Wave Speed</span></div>
            <button class="buy" data-buywave><span>Quicken</span><b data-wavecost></b></button>
            <div class="row" style="gap:8px"><div class="bar" style="flex:1"><div class="fill" data-wavebar></div></div><div class="gems" data-wavegems></div></div>
          </div>
          <div class="hud-wave-dial">
            <span>Active</span>
            <button data-dial="-1" aria-label="Lower active wave speed">−</button>
            <span class="tier" data-wavetier></span>
            <button data-dial="1" aria-label="Raise active wave speed">+</button>
            <span class="hud-milestone" data-milestone></span>
          </div>
        </div>
        <div class="hud-currency">
          <span title="Gold"><img src="art/ui/gold.webp" alt="Gold" /><b data-gold></b></span>
          <span title="Thralls"><span class="thrall-ico" style="color:var(--cw-bone-300)">${ICON.skull}</span><b data-thrallnum></b></span>
          <span title="Soul Shards"><img src="art/ui/soul_shard.webp" alt="Soul shards" /><b data-shards></b></span>
        </div>
        <div class="hud-save" data-save></div>
      </div>
      <div class="hud-death passive" data-death><div><div class="t">You have fallen</div><div class="s" data-deathsub></div></div></div>
    `;
    root.appendChild(this.el);
    this.tooltip.className = 'hud-spell-tooltip cw-plate';
    this.tooltip.id = `hud-spell-tooltip-${++nextTooltipId}`;
    this.tooltip.setAttribute('role', 'tooltip');
    this.tooltip.setAttribute('aria-label', 'Spell details');
    this.tooltip.tabIndex = 0;
    this.tooltip.hidden = true;
    this.el.appendChild(this.tooltip);
    this.$('[data-mapframe]').appendChild(this.minimap.canvas);

    this.bindSlots();
    this.$('[data-grimbtn]').addEventListener('click', () => { this.hideTooltip(); this.cb.openGrimoire(); });
    this.el.querySelectorAll<HTMLButtonElement>('.hud-menu [data-open]').forEach((b) =>
      b.addEventListener('click', () => { this.hideTooltip(); this.cb.open(b.dataset.open as HudPanel); }),
    );
    this.$('[data-nextx]').addEventListener('click', () => this.cb.dismissNext?.());
    this.$('[data-buydmg]').addEventListener('click', () => this.cb.buyDamage());
    this.$('[data-auto]').addEventListener('click', () => this.cb.toggleAutoCombat());
    this.$('[data-buywave]').addEventListener('click', () => this.cb.buyWave());
    this.el.querySelectorAll<HTMLButtonElement>('[data-dial]').forEach((b) =>
      b.addEventListener('click', () => this.cb.dialWave(Number(b.dataset.dial))),
    );
    this.tooltip.addEventListener('pointerenter', () => window.clearTimeout(this.tooltipHideTimer));
    this.tooltip.addEventListener('pointerleave', () => this.scheduleTooltipHide());
    this.tooltip.addEventListener('focus', () => window.clearTimeout(this.tooltipHideTimer));
    this.tooltip.addEventListener('blur', () => this.scheduleTooltipHide());
    window.addEventListener('keydown', this.tooltipKeydown, true);
    window.addEventListener('resize', this.resizeTooltip);
    const chat = this.$<HTMLInputElement>('[data-chatin]');
    chat.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') {
        const text = chat.value.trim();
        if (text) this.cb.chat(text);
        chat.value = '';
        chat.blur();
      } else if (e.key === 'Escape') chat.blur();
    });
  }

  focusChat() {
    this.$<HTMLInputElement>('[data-chatin]').focus();
  }

  private primaryHtml() {
    const a = ABILITIES[this.primary];
    return `
          <button data-slot="0" aria-label="${a.name} (left click). Open the Grimoire to inspect this slot">
            <img src="${a.icon}" alt="" draggable="false" />${this.runePip(this.primary)}
          </button>
          <span class="key">LMB</span>`;
  }

  /** The badge of the rune socketed in a rite, or nothing. */
  private runePip(id: AbilityId): string {
    const r = isRuneRite(id) ? this.runes[id as RuneRite] : undefined;
    return r ? `<img class="rune-pip" src="art/items/${r}.webp" alt="" draggable="false" title="${esc(RUNES[r].name)}" />` : '';
  }

  /** The sockets changed: redraw the slots so each rite wears its rune. */
  setRunes(runes: RuneSockets) {
    this.runes = runes;
    this.$('[data-primarywrap]').innerHTML = this.primaryHtml();
    this.$('.hud-slots').innerHTML = this.slotsHtml();
    for (const key of [...this.cache.keys()]) if (/^(cd|cdt|res|emp|lock)\d+$/.test(key)) this.cache.delete(key);
    this.bindSlots();
    this.tooltipKey = '';
    this.refreshTooltip();
  }

  /** The LMB socket's primary changed (Grimoire). */
  setPrimary(id: AbilityId) {
    this.primary = id;
    this.$('[data-primarywrap]').innerHTML = this.primaryHtml();
    this.bindSlots();
    this.refreshTooltip();
  }

  /** The hotbar Grimoire button's NEW pip: a learned rite nobody has looked at yet. */
  setGrimoireNew(on: boolean) {
    this.set('grimnew', on, () => (this.$('[data-grimpip]').hidden = !on));
  }

  /** Draw the eye to the Grimoire button for ~6 s (first new rite). */
  pulseGrimoire() {
    const b = this.$('[data-grimbtn]');
    b.classList.remove('pulse');
    void (b as HTMLElement).offsetWidth;
    b.classList.add('pulse');
  }

  /** Swap controls stay hidden until the first alternative rite is learned (see firstHourRules.swapReady). */
  private swapOn = false;

  setSwapReady(on: boolean) {
    if (this.swapOn === on) return;
    this.swapOn = on;
    this.setHotbar(this.hotbar);
  }

  private slotsHtml() {
    return this.hotbar.map((id, i) => {
      const a = ABILITIES[id];
      const alt = SLOT_KEYS[i] === 'RMB';
      return `
        <div class="hud-slot${alt ? ' alt' : ''}">
          <button data-slot="${i + 1}" aria-label="${a.name} (${alt ? 'right-click or key 5' : a.slot === 6 ? 'key R or 6' : `key ${i + 1}`})">
            <img src="${a.icon}" alt="" draggable="false" />${this.runePip(id)}
            <span class="cd" data-cd="${i + 1}"></span>
            <span class="cdtext" data-cdt="${i + 1}"></span>
            ${a.essenceCost ? `<span class="cost">${a.essenceCost}</span>` : ''}
          </button>
          ${i < 5 && this.swapOn ? `<button class="key swap" data-swap="${i}" title="Swap this rite (L)" aria-label="Swap ${a.name} in ${alt ? 'right-click or slot 5' : `slot ${i + 1}`}">${SLOT_KEYS[i]}<span class="swap-ico" aria-hidden="true">${SWAP_ICON}</span></button>` : `<span class="key">${SLOT_KEYS[i] ?? i + 1}</span>`}
        </div>`;
    }).join('');
  }

  /** Click-to-cast plus tooltips (name, cost, cooldown, description, unlock level). */
  /**
   * Click-to-cast plus the spell cards. The cards (spellTooltip) replace native titles and stay
   * readable while the button or card is hovered or keyboard-focused; opening one never casts.
   * Bound here, not once in the constructor, because a Grimoire swap rebuilds the buttons.
   */
  private bindSlots() {
    // i = -1 is LMB; 0–4 are the five swappable rites; 5 is the signature.
    for (let i = -1; i < this.hotbar.length; i++) {
      const btn = this.el.querySelector<HTMLButtonElement>(`[data-slot="${i + 1}"]`);
      if (!btn || btn.dataset.bound) continue;
      btn.dataset.bound = '1';
      if (i === -1) btn.addEventListener('click', () => { this.hideTooltip(); this.cb.openGrimoire('primary'); });
      else btn.addEventListener('click', () => this.cb.cast((i + 1) as HotbarSlot));
      if (i < 5) {
        btn.addEventListener('contextmenu', (e) => {
          e.preventDefault();
          e.stopPropagation();
          this.hideTooltip();
          this.cb.openGrimoire(i === -1 ? 'primary' : i);
        });
      }
      btn.addEventListener('pointerenter', () => this.showTooltip(i));
      btn.addEventListener('pointerleave', () => this.scheduleTooltipHide());
      btn.addEventListener('focus', () => this.showTooltip(i));
      btn.addEventListener('blur', () => this.scheduleTooltipHide());
    }
    this.el.querySelectorAll<HTMLButtonElement>('[data-swap]').forEach((button) => {
      button.addEventListener('click', () => { this.hideTooltip(); this.cb.openGrimoire(Number(button.dataset.swap)); });
    });
  }

  /** The Grimoire loadout changed: rebuild the slots (cooldowns carry over — they belong to the rite). */
  setHotbar(hotbar: AbilityId[]) {
    this.hotbar = hotbar;
    this.$('.hud-slots').innerHTML = this.slotsHtml();
    for (const key of [...this.cache.keys()]) if (/^(cd|cdt|res|emp|lock)\d+$/.test(key)) this.cache.delete(key);
    this.bindSlots();
    this.refreshTooltip();
  }

  private set(key: string, value: string | number | boolean, apply: () => void) {
    if (this.cache.get(key) === value) return;
    this.cache.set(key, value);
    apply();
  }

  private showTooltip(i: number) {
    window.clearTimeout(this.tooltipHideTimer);
    if (this.tooltipSlot !== i) {
      this.hideTooltip();
      this.tooltipSlot = i;
      this.$(`[data-slot="${i + 1}"]`).setAttribute('aria-describedby', this.tooltip.id);
      this.tooltipKey = '';
      this.tooltip.scrollTop = 0;
    }
    this.tooltip.hidden = false;
    this.refreshTooltip();
  }

  private refreshTooltip() {
    if (this.tooltipSlot === null || this.tooltip.hidden) return;
    const i = this.tooltipSlot;
    const state = this.slotFrames[i] ?? {};
    const id = i === -1 ? this.primary : this.hotbar[i];
    // The rite id is part of the key: a Grimoire swap puts a different rite in the same slot.
    const key = `${i}|${id}|${isRuneRite(id) ? this.runes[id as RuneRite] ?? '' : ''}|${!!state.empowered}|${!!state.locked}|${state.affordable}|${Math.ceil((state.left ?? 0) / 1000)}`;
    if (key === this.tooltipKey) return;
    this.tooltipKey = key;
    const data = spellTooltip(id, this.discipline, { ...(i === -1 ? {} : state), key: i === -1 ? 'LMB' : i < 5 ? SLOT_KEYS[i] : undefined });
    const scroll = this.tooltip.scrollTop;
    this.tooltip.innerHTML = `
      <div class="spell-name">${esc(data.name)}</div>
      <div class="spell-control">${esc(data.control)}</div>
      <div class="spell-state${data.locked ? ' locked' : data.empowered ? ' empowered' : ''}">${esc(data.status)}</div>
      <p class="spell-description">${esc(data.description)}</p>
      <div class="spell-metrics">${data.metrics.map((m) => `<div><span>${esc(m.label)}</span><b>${esc(m.value)}</b></div>`).join('')}</div>
      <p class="spell-targeting">${esc(data.targeting)}</p>
      <ul class="spell-details">${data.details.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>
      ${runeCard(id, this.runes)}
      <div class="spell-tip"><b>Combat tip</b><p>${esc(data.tip)}</p></div>
      <div class="spell-footer">${i < 5 ? 'Click the swap arrows below this slot or press L · ' : ''}Codex (K) · Esc closes this card</div>`;
    this.tooltip.scrollTop = scroll;
    this.positionTooltip();
  }

  private positionTooltip() {
    if (this.tooltipSlot === null || this.tooltip.hidden) return;
    const anchor = this.$(`[data-slot="${this.tooltipSlot + 1}"]`).getBoundingClientRect();
    const card = this.tooltip.getBoundingClientRect();
    const margin = 12;
    const left = Math.max(margin, Math.min(window.innerWidth - card.width - margin, anchor.left + anchor.width / 2 - card.width / 2));
    const above = anchor.top - card.height - 8;
    const top = Math.max(margin, Math.min(window.innerHeight - card.height - margin, above >= margin ? above : anchor.bottom + 8));
    this.tooltip.style.left = `${left}px`;
    this.tooltip.style.top = `${top}px`;
  }

  private scheduleTooltipHide() {
    window.clearTimeout(this.tooltipHideTimer);
    // A small bridge lets the pointer cross the gap into a scrollable card.
    this.tooltipHideTimer = window.setTimeout(() => {
      if (this.tooltipSlot === null) return;
      const btn = this.$(`[data-slot="${this.tooltipSlot + 1}"]`);
      if (btn.matches(':hover, :focus-visible') || this.tooltip.matches(':hover') || document.activeElement === this.tooltip) return;
      this.hideTooltip();
    }, 180);
  }

  private hideTooltip() {
    window.clearTimeout(this.tooltipHideTimer);
    if (this.tooltipSlot !== null) this.$(`[data-slot="${this.tooltipSlot + 1}"]`).removeAttribute('aria-describedby');
    this.tooltipSlot = null;
    this.tooltip.hidden = true;
  }

  update(f: HudFrame) {
    this.slotFrames = f.slots;
    this.refreshTooltip();
    this.set('autoCombat', `${f.autoCombat}|${f.autoCombatAvailable}|${f.autoCombatVisible}`, () => {
      const button = this.$('[data-auto]') as HTMLButtonElement;
      button.hidden = !f.autoCombatVisible;
      button.disabled = !f.autoCombatAvailable;
      button.textContent = f.autoCombatAvailable ? (f.autoCombat ? 'Auto: On · G' : 'Auto: Off · G') : 'Auto: Easy only';
      button.title = f.autoCombatAvailable ? 'Toggle auto combat (G)' : 'Available on Easy difficulty';
      button.setAttribute('aria-pressed', String(f.autoCombat));
    });
    const hpFrac = Math.max(0, f.hp / f.maxHp);
    this.set('hp', Math.round(hpFrac * 400), () => this.$('[data-hporb]').style.setProperty('--fill', `${hpFrac * 100}%`));
    this.set('hptxt', `${Math.ceil(f.hp)}/${f.maxHp}`, () => (this.$('[data-hptxt]').innerHTML = `${Math.ceil(f.hp).toLocaleString()} / ${f.maxHp.toLocaleString()}<small>Health</small>`));
    this.set('barrier', Math.round((f.barrier / f.maxHp) * 20), () => this.$('[data-hporb]').style.setProperty('--barrier', String(Math.min(0.9, (f.barrier / f.maxHp) * 3))));
    this.set('low', hpFrac < 0.3 && f.hp > 0, () => this.$('[data-vig]').classList.toggle('low', hpFrac < 0.3 && f.hp > 0));
    const eFrac = f.essence / f.maxEssence;
    const resLabel = f.resourceLabel ?? 'Grave Essence';
    this.set('ess', Math.round(eFrac * 400), () => this.$('[data-essorb]').style.setProperty('--fill', `${eFrac * 100}%`));
    this.set('esstxt', `${Math.floor(f.essence)}/${f.maxEssence}|${resLabel}`, () => (this.$('[data-esstxt]').innerHTML = `${Math.floor(f.essence)} / ${f.maxEssence}<small>${resLabel}</small>`));
    this.set('reslabel', resLabel, () => this.$('[data-essorb]').setAttribute('aria-label', resLabel));
    this.set('beatpulse', !!f.beatPulse, () => this.$('[data-essorb]').classList.toggle('beat-pulse', !!f.beatPulse));
    this.set('rescolor', f.resourceColor ?? '', () => {
      const orb = this.$('[data-essorb]');
      if (f.resourceColor) orb.style.setProperty('--res-color', f.resourceColor);
      else orb.style.removeProperty('--res-color');
    });

    f.slots.forEach((s, i) => {
      const n = i + 1;
      const pct = s.left > 0 ? Math.round((s.left / s.total) * 100) : 0;
      this.set(`cd${n}`, pct, () => this.$(`[data-cd="${n}"]`).style.setProperty('--cd', `${pct}%`));
      const txt = s.left > 0 ? (s.left >= 1000 ? Math.ceil(s.left / 1000).toString() : (s.left / 1000).toFixed(1)) : '';
      this.set(`cdt${n}`, txt, () => (this.$(`[data-cdt="${n}"]`).textContent = txt));
      this.set(`res${n}`, s.affordable, () => this.$(`[data-slot="${n}"]`).classList.toggle('nores', !s.affordable));
      this.set(`emp${n}`, !!s.empowered, () => this.$(`[data-slot="${n}"]`).classList.toggle('empowered', !!s.empowered));
      this.set(`lock${n}`, !!s.locked, () => this.$(`[data-slot="${n}"]`).classList.toggle('locked', !!s.locked));
    });

    const soulFrac = Math.min(1, f.souls / f.soulsMax);
    this.set('souls', `${f.souls}/${f.soulsMax}`, () => {
      const el = this.$('[data-souls]');
      el.classList.toggle('full', f.souls >= f.soulsMax);
      el.setAttribute('aria-valuemax', String(f.soulsMax));
      el.setAttribute('aria-valuenow', String(f.souls));
      this.$('[data-soulfill]').style.width = `${soulFrac * 100}%`;
      this.$('[data-soultxt]').textContent = f.souls >= f.soulsMax ? 'Harvest' : `${f.souls} / ${f.soulsMax}`;
    });

    this.set('thr', `${f.thralls}/${f.thrallCap}`, () => {
      this.$('[data-thralls]').innerHTML = Array.from({ length: f.thrallCap }, (_, i) => `<i class="${i < f.thralls ? 'on' : ''}"></i>`).join('');
      this.$('[data-thrallnum]').textContent = `${f.thralls}/${f.thrallCap}`;
    });
    this.set('lvl', f.level, () => (this.$('[data-level]').textContent = String(f.level)));
    this.set('xp', `${f.xp}/${f.xpNext}`, () => {
      this.$('[data-xpfill]').style.width = `${Math.min(100, (f.xp / f.xpNext) * 100)}%`;
      this.$('[data-xptxt]').textContent = `${f.xp.toLocaleString()} / ${f.xpNext.toLocaleString()}`;
    });
    this.set('gold', f.gold, () => (this.$('[data-gold]').textContent = f.gold.toLocaleString()));
    this.set('shards', f.shards, () => (this.$('[data-shards]').textContent = String(f.shards)));

    this.set('dmg', `${f.damageTier}|${f.damageCost}|${f.gold >= (f.damageCost ?? Infinity)}|${!!f.raisesThralls}`, () => {
      this.$('[data-dmgpct]').textContent = `+${f.damagePct}%`;
      this.$('[data-dmgbar]').style.width = `${(f.damageTier / DAMAGE_UPGRADE.maxTier) * 100}%`;
      this.$('[data-dmggems]').innerHTML = milestones(f.damageTier, DAMAGE_UPGRADE.maxTier).map((on) => `<i class="${on ? 'on' : ''}"></i>`).join('');
      this.$('[data-dmgcost]').textContent = f.damageCost === null ? 'Max' : `${f.damageCost.toLocaleString()}g`;
      this.$<HTMLButtonElement>('[data-buydmg]').disabled = f.damageCost === null || f.gold < f.damageCost;
      this.$('[data-buydmg]').title = f.damageCost === null
        ? `Damage is at its highest tier (+${f.damagePct}% to all your damage).`
        : `Empower: +${Math.round(DAMAGE_UPGRADE.perTier * 100)}% damage per tier, tier ${f.damageTier} of ${DAMAGE_UPGRADE.maxTier}. This one takes you from +${f.damagePct}% to +${damageBonusPct(f.damageTier + 1)}%${f.raisesThralls ? ', and your thralls already standing hit harder at once' : ''}. Resets when you Ascend.`;
    });
    this.set('wave', `${f.waveOwned}|${f.waveActive}|${f.waveCost}|${f.gold >= (f.waveCost ?? Infinity)}`, () => {
      this.$('[data-wavepct]').textContent = `+${f.wavePct}%`;
      this.$('[data-wavebar]').style.width = `${(f.waveOwned / WAVE_UPGRADE.maxTier) * 100}%`;
      this.$('[data-wavegems]').innerHTML = milestones(f.waveOwned, WAVE_UPGRADE.maxTier)
        .map((on, i) => {
          const m = WAVE_MILESTONES[i];
          return `<i class="${on ? 'on' : ''}" title="${m ? esc(`Tier ${m.tier} — ${m.name}: ${m.blurb}`) : ''}"></i>`;
        })
        .join('');
      // The dial's active milestones (or the next one to reach) in place of a generic hint.
      const active = WAVE_MILESTONES.filter((m) => f.waveActive >= m.tier);
      const next = WAVE_MILESTONES.find((m) => f.waveActive < m.tier);
      const ms = this.$('[data-milestone]');
      const top = active[active.length - 1];
      ms.textContent = top ? `${top.name}${active.length > 1 ? ` +${active.length - 1}` : ''}` : next ? `${next.name} at tier ${next.tier}` : '';
      ms.classList.toggle('on', active.length > 0);
      ms.title = (active.length ? active : next ? [next] : []).map((m) => `${m.name} (tier ${m.tier}): ${m.blurb}`).join('\n');
      this.$('[data-wavecost]').textContent = f.waveCost === null ? 'Max' : `${f.waveCost.toLocaleString()}g`;
      this.$<HTMLButtonElement>('[data-buywave]').disabled = f.waveCost === null || f.gold < f.waveCost;
      const now = waveModifiers(f.waveOwned);
      const nxt = waveModifiers(f.waveOwned + 1);
      const pct = (a: number, b: number) => Math.round((b / a - 1) * 100);
      this.$('[data-buywave]').title = f.waveCost === null
        ? 'Wave Speed is at its highest tier. Use the dial to run any tier you own.'
        : `Quicken: tier ${f.waveOwned} of ${WAVE_UPGRADE.maxTier}. The next tier brings faster, angrier waves and pays +${pct(now.rewardMult, nxt.rewardMult)}% gold, +${pct(now.xpMult, nxt.xpMult)}% XP and +${pct(now.itemChanceMult, nxt.itemChanceMult)}% item drops more. The dial picks which tier you actually run (0 to ${f.waveOwned}). Resets when you Ascend.`;
      this.$('[data-wavetier]').textContent = `Tier ${f.waveActive} / ${f.waveOwned}`;
      this.$<HTMLButtonElement>('[data-dial="-1"]').disabled = f.waveActive <= 0;
      this.$<HTMLButtonElement>('[data-dial="1"]').disabled = f.waveActive >= f.waveOwned;
    });
    this.set('area', f.areaName, () => (this.$('[data-area]').textContent = f.areaName));
    this.set('ward', f.ward && f.ward.pct > 0 ? `${f.ward.pct}|${f.ward.thralls}` : '', () => {
      const el = this.$('[data-ward]');
      el.hidden = !f.ward || f.ward.pct <= 0;
      if (!f.ward || f.ward.pct <= 0) return;
      el.classList.toggle('on', f.ward.pct > 0);
      el.innerHTML = `<span class="lbl">Bone Ward</span><span class="n">−${f.ward.pct}%</span>`;
      el.title = `Each active thrall shields you from ${Math.round(f.ward.perThrall * 100)}% of incoming damage (you have ${f.ward.thralls}; the most it gives is 60%).`;
    });
    this.set('brews', f.brews.map((b) => `${b.slot}|${b.label}|${b.active}|${b.left}|${b.count}|${b.empty}|${Math.round(b.frac * 8)}|${b.tip.length}`).join(';'), () => {
      const el = this.$('[data-brews]');
      el.hidden = !f.brews.length;
      // Update the three slots in place: replacing them would swallow a tap that lands while a timer redraws.
      for (const b of f.brews) {
        let chip = el.querySelector<HTMLElement>(`[data-brew="${b.slot}"]`);
        if (!chip) {
          chip = document.createElement('div');
          chip.dataset.brew = b.slot;
          chip.innerHTML = '<kbd></kbd><span class="glyph"></span><span class="txt"><span class="lbl"></span><span class="sub"></span></span><span class="bar"><i></i></span>';
          el.appendChild(chip);
        }
        chip.className = `brew-chip${b.active ? ' on' : ''}${b.empty ? ' empty' : ''}${b.frac && !b.active ? ' cd' : ''}`;
        chip.style.setProperty('--brew', `#${b.color.toString(16).padStart(6, '0')}`);
        chip.title = b.tip;
        chip.setAttribute('aria-label', b.tip);
        const q = (sel: string) => chip!.querySelector<HTMLElement>(sel)!;
        q('kbd').textContent = b.key;
        q('.glyph').textContent = b.glyph;
        q('.lbl').textContent = b.label;
        q('.sub').textContent = b.empty ? '' : b.active ? `${b.left}s` : b.count ? `×${b.count}` : 'ready';
        q('.bar i').style.width = `${Math.round(b.frac * 100)}%`;
      }
    });
    this.set('prog', f.areaProgress, () => (this.$('[data-prog]').innerHTML = f.areaProgress));
    this.set('save', f.save.text, () => {
      const el = this.$('[data-save]');
      el.textContent = f.save.text;
      el.classList.toggle('warn', f.save.warn);
    });

    const t = f.boss ? null : f.target;
    this.set('tvis', !!t, () => (this.$('[data-target]').hidden = !t));
    if (t) {
      this.set('tname', `${t.name}|${t.elite}|${t.affix?.id ?? ''}|${(t.moreAffixes ?? []).map((a) => a.id).join(',')}`, () => {
        const affix = [...(t.affix ? [t.affix] : []), ...(t.moreAffixes ?? [])].map((a) => `<span class="affix affix-${a.id}">${esc(a.name)}</span>`).join('');
        this.$('[data-tname]').innerHTML = `${esc(t.name)}${t.elite ? '<span class="elite">◆ Elite</span>' : ''}${affix}`;
        this.$('[data-tblurb]').textContent = t.blurb;
      });
      this.set('thp', Math.round((t.hp / t.maxHp) * 200), () => (this.$('[data-thp]').style.width = `${Math.max(0, (t.hp / t.maxHp) * 100)}%`));
      const st = t.statuses.map((s) => `${s.icon}${s.n}`).join(',');
      this.set('tstat', st, () => {
        this.$('[data-tstat]').innerHTML = t.statuses
          .map((s) => `<span title="${s.label}"><img src="${s.icon}" alt="${s.label}" />${s.label} ×${s.n}</span>`)
          .join('');
      });
    }
    const b = f.boss;
    this.set('bvis', !!b, () => (this.$('[data-boss]').hidden = !b));
    if (b) {
      this.set('bname', `${b.name}|${b.phase}`, () => {
        this.$('[data-bname]').textContent = b.name;
        this.$('[data-bphase]').textContent = (b.phases ?? ['The bell is silent', 'The procession begins', 'The bell is breaking'])[b.phase - 1] ?? '';
      });
      // Keyed on max HP too: a new boss at full health must not keep the last boss's numbers.
      this.set('bhp', `${Math.round((b.hp / b.maxHp) * 400)}|${Math.round(b.maxHp)}`, () => {
        this.$('[data-bhp]').style.width = `${Math.max(0, (b.hp / b.maxHp) * 100)}%`;
        this.$('[data-bnum]').textContent = `${Math.max(0, Math.ceil(b.hp)).toLocaleString()} / ${Math.ceil(b.maxHp).toLocaleString()}`;
      });
    }
  }

  drawMap(f: MinimapFrame) {
    this.minimap.draw(f);
  }

  party(members: PartyMember[]) {
    const key = members.map((m) => `${m.id}${m.name}${m.discipline}${Math.round(m.hpFrac * 20)}`).join('|');
    this.set('party', key, () => {
      this.$('[data-party]').innerHTML = members
        .slice(0, MAX_PARTY_SIZE)
        .map(
          (m) => `<div class="hud-member"><img src="${m.portrait}" alt="" /><div class="who"><div class="nm">${esc(m.name)}</div><div class="dc">${esc(m.discipline)}</div><div class="hp"><i style="width:${Math.round(m.hpFrac * 100)}%"></i></div></div></div>`,
        )
        .join('');
    });
  }

  /** `onClick` makes the toast a button (e.g. a new rite opens the Grimoire). */
  /** The week's Omen chip under the party list (its blurb is the tooltip). */
  setOmen(o: { name: string; icon: string; blurb: string } | null) {
    const el = this.$('[data-omen]');
    el.hidden = o === null;
    if (!o) return;
    (this.$('[data-omen-img]') as HTMLImageElement).src = o.icon;
    this.$('[data-omen-name]').textContent = o.name;
    el.title = o.blurb;
    el.setAttribute('aria-label', `${o.name}. ${o.blurb}`);
  }

  /**
   * The Catacomb Depths readout, under the minimap and quiet: "Depth 7 · 12/20" over a thin bar. When the quota is met the count gives way to a
   * gold "Stair open" cue (the minimap points to the stair). Null hides it.
   */
  setDepths(d: null | { depth: number; kills: number; need: number; open: boolean; chest: boolean }) {
    this.set('depth.on', d !== null, () => (this.$('[data-depth]').hidden = d === null));
    if (!d) return;
    this.set('depth.n', d.depth, () => (this.$('[data-depth-n]').textContent = String(d.depth)));
    this.set('depth.k', `${d.kills}/${d.need}/${d.open}`, () => {
      this.$('[data-depth-k]').textContent = d.open ? 'Stair open' : `${d.kills}/${d.need}`;
      this.$('[data-depth]').classList.toggle('open', d.open);
    });
    this.set('depth.fill', Math.round((d.kills / Math.max(1, d.need)) * 100), () => this.$('[data-depth-fill]').style.setProperty('width', `${Math.min(100, (d.kills / Math.max(1, d.need)) * 100)}%`));
    this.set('depth.cue', `${d.open}|${d.chest}`, () => (this.$('[data-depth-cue]').textContent = d.open ? (d.chest ? 'The stair is open · a chest waits on this floor' : 'Follow the amber mark on the minimap') : d.chest ? 'A chest waits on this floor' : ''));
  }

  /** The Kill Chain readout: a count, the tier name and bonus, and the time left before it breaks (null hides it). */
  setChain(c: null | { count: number; name: string; bonus: number; frac: number; tier: number }) {
    this.set('chain.on', c !== null, () => (this.$('[data-chain]').hidden = c === null));
    if (!c) return;
    this.set('chain.n', c.count, () => (this.$('[data-chain-n]').textContent = `×${c.count}`));
    this.set('chain.lbl', `${c.name}|${c.bonus}`, () => (this.$('[data-chain-lbl]').textContent = c.bonus > 0 ? `${c.name} · +${Math.round(c.bonus * 100)}% XP & gold` : 'Chain'));
    this.set('chain.tier', c.tier, () => (this.$('[data-chain]').dataset.tier = String(c.tier)));
    this.set('chain.fill', Math.round(c.frac * 50), () => this.$('[data-chain-fill]').style.setProperty('width', `${c.frac * 100}%`));
  }

  /** A short pop on the readout when the count climbs (retriggers the CSS animation). */
  pulseChain() {
    const el = this.$('[data-chain-n]');
    el.classList.remove('pop');
    void el.offsetWidth;
    el.classList.add('pop');
  }

  toast(text: string, kind: '' | 'err' | 'good' = '', onClick?: () => void) {
    const el = document.createElement('div');
    el.className = `hud-toast ${kind}${onClick ? ' clickable' : ''}`;
    el.textContent = text;
    if (onClick) {
      el.setAttribute('role', 'button');
      el.tabIndex = 0;
      el.addEventListener('click', () => { onClick(); el.remove(); });
      el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(); el.remove(); } });
    }
    const box = this.$('[data-toasts]');
    // The same line twice (two drops, two milestones) is one toast: the older copy goes.
    for (const old of Array.from(box.children)) if (old.textContent === text) old.remove();
    box.appendChild(el);
    // Three at most: a kill that crosses several milestones used to stack four boxes over the middle of the fight.
    while (box.children.length > 3) box.firstChild?.remove();
    const duration = Math.max(6000, 2000 + text.split(/\s+/).length * 400);
    el.style.setProperty('--toast-ms', `${duration}ms`);
    setTimeout(() => el.remove(), duration + 700);
  }

  /** Live pickup toasts by item name, so a repeat pickup bumps the count instead of stacking another box. */
  private lootToasts = new Map<string, { el: HTMLElement; total: number; timer: number }>();

  /**
   * A pickup. The same item picked up again while its toast is up becomes "Name ×3" and restarts its clock; commons and
   * uncommons live 3.5 s and are the first to make room, rare and better keep the full time and a gold edge.
   */
  lootToast(name: string, qty: number, rarity: Rarity) {
    const box = this.$('[data-toasts]');
    const live = this.lootToasts.get(name);
    if (live && live.el.isConnected) {
      live.total += qty;
      window.clearTimeout(live.timer);
      live.el.textContent = lootToastLine(name, live.total);
      // Restart the fade: remove and re-add the animation, and move it to the newest spot.
      live.el.style.animation = 'none';
      void live.el.offsetWidth;
      live.el.style.animation = '';
      box.appendChild(live.el);
      live.timer = window.setTimeout(() => this.dropLoot(name, live.el), lootToastMs(rarity) + 700);
      return;
    }
    const el = document.createElement('div');
    const minor = isMinorLoot(rarity);
    el.className = `hud-toast good loot ${minor ? 'minor' : 'major'}`;
    el.dataset.rarity = rarity;
    el.textContent = lootToastLine(name, qty);
    const ms = lootToastMs(rarity);
    el.style.setProperty('--toast-ms', `${ms}ms`);
    box.appendChild(el);
    // Room for a drop: the oldest minor pickup goes first, then the oldest of anything (four at most with loot in the stack).
    while (box.children.length > 4) (box.querySelector('.loot.minor') ?? box.firstChild)?.remove();
    this.lootToasts.set(name, { el, total: qty, timer: window.setTimeout(() => this.dropLoot(name, el), ms + 700) });
  }

  private dropLoot(name: string, el: HTMLElement) {
    el.remove();
    if (this.lootToasts.get(name)?.el === el) this.lootToasts.delete(name);
  }

  private bannerTimer = 0;
  /** The area-name banner is on screen (counsel cards wait for it to clear). */
  get bannerActive() {
    return this.$('[data-banner]').classList.contains('show');
  }

  banner(title: string, sub: string, ms = 3200) {
    const el = this.$('[data-banner]');
    el.querySelector('.t')!.textContent = title;
    el.querySelector('.s')!.textContent = sub;
    el.classList.add('show');
    window.clearTimeout(this.bannerTimer);
    this.bannerTimer = window.setTimeout(() => el.classList.remove('show'), ms);
  }

  /** The DEV chip beside the level badge while the dev-access overlay is on. */
  setDev(on: boolean) {
    this.$('[data-dev]').hidden = !on;
  }

  /** Hover card for a gathering node (trusted HTML built from gatheringRules), beside the cursor. */
  nodeTip(html: string | null, x: number, y: number) {
    const el = this.$('[data-nodetip]');
    this.set('nodetip', html ?? '', () => {
      el.hidden = !html;
      if (html) el.innerHTML = html;
    });
    if (!html) return;
    const w = el.offsetWidth || 220;
    const h = el.offsetHeight || 70;
    el.style.left = `${Math.max(8, Math.min(window.innerWidth - w - 8, x + 18))}px`;
    el.style.top = `${Math.max(8, Math.min(window.innerHeight - h - 8, y - h - 12))}px`;
  }

  prompt(html: string | null) {
    this.set('prompt', html ?? '', () => {
      const el = this.$('[data-prompt]');
      el.hidden = !html;
      if (html) el.innerHTML = html;
    });
  }

  /** The optional "Next" suggestion under the minimap (plain text); null hides it. */
  next(text: string | null) {
    this.set('next', text ?? '', () => {
      const el = this.$('[data-next]');
      el.hidden = !text;
      this.$('[data-nexttxt]').textContent = text ?? '';
    });
  }

  hint(text: string) {
    this.set('hint', text, () => (this.$('[data-hint]').textContent = text));
  }

  hitFlash() {
    const v = this.$('[data-vig]');
    v.classList.remove('hit');
    void v.offsetWidth;
    v.classList.add('hit');
    setTimeout(() => v.classList.remove('hit'), 90);
  }

  slotFlash(n: number) {
    const b = this.$(`[data-slot="${n}"]`);
    b.classList.remove('flash');
    void b.offsetWidth;
    b.classList.add('flash');
  }

  death(show: boolean, sub = '') {
    this.$('[data-death]').classList.toggle('show', show);
    this.$('[data-deathsub]').textContent = sub;
  }

  chatLine(text: string) {
    const log = this.$('[data-chatlog]');
    const line = document.createElement('div');
    line.textContent = text;
    log.appendChild(line);
    while (log.children.length > 8) log.firstChild?.remove();
    log.scrollTop = log.scrollHeight;
  }

  dispose() {
    this.hideTooltip();
    window.removeEventListener('resize', this.resizeTooltip);
    window.removeEventListener('keydown', this.tooltipKeydown, true);
    this.el.remove();
  }
}
