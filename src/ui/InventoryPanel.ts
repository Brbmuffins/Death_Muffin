import { adoptPet, equipItem, getInventory } from '../net/api';
import { petForCharm } from '../content/cosmetics';
import type { InventorySlot } from '../net/types';
import { BAG_SIZE, type Inventory } from '../gameplay/loot';
import { BREWS, BREW_KEYS, brewSummary } from '../content/brews';
import { BUFF_FLASKS, HEALING_FLASKS, RARITY_COLOR, RARITY_MARK, itemMeta } from '../content/items';
import { MEALS } from '../content/processing';
import { EQUIP_SLOTS, equipSlotOf, equippedBySlot, type EquipSlot } from '../content/gear';
import { ARMOR_BY_ID, ARMOR_PARTS } from '../content/armorSets';
import { necroWeaponTooltip } from '../content/necroWeapons';
import { ItemLocks, junkSlots } from '../gameplay/itemLocks';
import { isSalvageable } from '../gameplay/salvageRules';
import { ABILITIES } from '../content/abilities';
import { RUNES, isRuneId, runeSources, type RuneId, type RuneRite } from '../content/runes';
import './runes.css';
import { BELT_DRAG_TYPE } from './BeltPicker';
import { BELT_KINDS, toolKindOf } from '../gameplay/gatheringRules';
import { kitCandidate } from '../gameplay/legionKit';
import { KIT_LABEL } from '../gameplay/legionRules';
import { moveKit } from './LegionPanel';
import { BELT_LABEL, beltOffer, beltTools, dismissOffer, isOnBelt, moveTools, offerDismissed } from './toolBelt';

/** A small padlock for locked cells and the Lock button (inline SVG: no font or emoji dependency). */
export const LOCK_SVG = '<svg viewBox="0 0 12 14" width="11" height="13" aria-hidden="true"><path d="M3 6V4.2a3 3 0 0 1 6 0V6" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="1.5" y="6" width="9" height="7" rx="1" fill="currentColor"/></svg>';
import { badgeHtml, compareChipsHtml, compareTableHtml, itemLevelHtml, itemStatsHtml, itemTypeLabel, keepsForYou, setTooltipHtml, verdictHtml, type StatContextSource } from './gearText';
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
import { effectRelevant, resolveSetBonuses } from '../gameplay/setBonuses';

const TYPE_GLYPH: Record<string, string> = {
  weapon: '⚔',
  armor_head: '⛨',
  armor_chest: '⛊',
  armor_legs: '‖',
  armor_feet: '◭',
  armor_hands: '✋',
  offhand: '◐',
  ring: '◎',
  trinket: '✦',
  material: '◆',
};

/** Paper-doll order (3 columns); null cells are spacers. */
const DOLL: (EquipSlot | null)[] = ['ring', 'head', 'trinket', 'main_hand', 'chest', 'off_hand', 'hands', 'legs', null, null, 'feet', null];

export function itemIcon(slot: Pick<InventorySlot, 'item_id'>) {
  const meta = itemMeta(slot.item_id);
  return meta.icon ?? `art/items/${slot.item_id}.webp`;
}

/**
 * The Reliquary: 8×6 bag, hover tooltips, equip/unequip. Equip goes straight
 * to POST /api/inventory/equip and the server's slot array becomes truth.
 */
export class InventoryPanel {
  private el: HTMLDivElement | null = null;
  private tooltip: HTMLDivElement | null = null;
  private selected: number | null = null;
  private busy = false;
  private off: (() => void) | null = null;
  private offLocks: (() => void) | null = null;
  private confirmJunk = false;
  /** Gear you can read: set by the scene so stat lines and compare blocks speak for this character. */
  statContext: StatContextSource | null = null;
  /** Opens the Character sheet (the paper doll's Sheet button). */
  onSheet: (() => void) | null = null;
  /** Called after the server accepted an equip (not an unequip): the first-time counsel hangs off it. */
  onEquipped: (() => void) | null = null;
  /** Called after a tool went onto the belt: the first-time counsel hangs off it. */
  onToolBelted: (() => void) | null = null;
  /** Opens the Legion panel (set for necromancers only: other classes raise no thralls, so they get no Legion button). */
  onLegion: (() => void) | null = null;
  /** Socket a Relic rune into its rite (the scene moves it on the server and answers with a readable error, or null). */
  onRune: ((rite: RuneRite, id: RuneId) => Promise<string | null>) | null = null;
  /** The rune currently socketed in a rite, if any (to say what a socket would replace). */
  socketed: (rite: RuneRite) => RuneId | undefined = () => undefined;
  /** Called after a piece went to the legion's kit. */
  onLegionGiven: (() => void) | null = null;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private statsLine: () => string,
    private onUse: (itemId: string) => void,
    /** Right-click or the detail button on a brew: put it on its belt key (Z elixir, X tonic). */
    private onBelt?: (itemId: string) => void,
    /** Selling (2026-09-29): gold is credited by the scene, like any pickup. */
    private onSold?: (gold: number, name: string, quantity: number) => void,
    /** Per-character item locks (bulk actions skip locked items) and the Bone Grinder hook for the detail's Salvage button. */
    private locks: ItemLocks = new ItemLocks(characterId),
    private grinder?: { near: () => boolean; salvage: (slots: number[]) => Promise<void> },
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-reliquary';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Reliquary');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Reliquary<span class="aka">Bag · I</span></h2>
        <button class="cw-icon-btn" data-close aria-label="Close reliquary">✕</button>
      </div>
      <div class="cw-stats-line" data-stats></div>
      <div class="cw-inv-body">
        <div class="cw-equip-col">
          <div class="cw-equip" role="group" aria-label="Equipment"></div>
          <div class="cw-setsum" role="group" aria-label="Set bonuses" hidden></div>
          <div class="cw-toolbelt" role="group" aria-label="Tool belt"></div>
          <button type="button" class="cw-button small cw-legion-btn" data-legion hidden aria-label="Open the Legion: gear for your thralls (Y)" title="Spare weapons and armour for your thralls (Y)">Legion · Y</button>
        </div>
        <div class="cw-bag-grid" role="grid"></div>
      </div>
      <div class="cw-bag-tools" data-tools></div>
      <div class="cw-bag-detail" data-detail></div>
      <div class="cw-error" data-error></div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.root.appendChild(this.el);
    this.tooltip = document.createElement('div');
    this.tooltip.className = 'cw-tooltip';
    this.tooltip.style.display = 'none';
    this.root.appendChild(this.tooltip);
    this.off = this.inventory.onChange(() => this.render());
    this.offLocks = this.locks.onChange(() => this.render());
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    this.offLocks?.();
    this.offLocks = null;
    this.confirmJunk = false;
    this.el?.remove();
    this.el = null;
    this.tooltip?.remove();
    this.tooltip = null;
    this.selected = null;
  }

  private slotAt(i: number) {
    return this.inventory.all.find((s) => s.slot_index === i);
  }

  render() {
    if (!this.el) return;
    this.hideTooltip(); // the cell under the pointer is rebuilt, so its pointerleave never fires
    this.el.querySelector('[data-stats]')!.innerHTML = this.statsLine();
    const grid = this.el.querySelector<HTMLDivElement>('.cw-bag-grid')!;
    grid.innerHTML = '';
    const sctx = this.statContext?.() ?? null;
    for (let i = 0; i < BAG_SIZE; i++) {
      const slot = this.slotAt(i);
      const cell = document.createElement('button');
      cell.className = 'cw-slot';
      cell.setAttribute('role', 'gridcell');
      if (slot) {
        cell.classList.add('filled');
        if (slot.equipped) cell.classList.add('equipped');
        const locked = this.locks.isLocked(slot);
        if (locked) cell.classList.add('locked');
        cell.style.setProperty('--rarity', RARITY_COLOR[slot.rarity] ?? RARITY_COLOR.common);
        cell.setAttribute('aria-label', `${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}, ${slot.rarity}${slot.equipped ? ', equipped' : ''}${locked ? ', locked' : ''}`);
        const img = document.createElement('img');
        img.className = 'item-icon';
        img.src = itemIcon(slot);
        img.alt = '';
        img.onerror = () => {
          img.replaceWith(Object.assign(document.createElement('span'), { className: 'glyph', textContent: TYPE_GLYPH[slot.item_type] ?? '◆' }));
        };
        cell.appendChild(img);
        cell.insertAdjacentHTML(
          'beforeend',
          `${slot.quantity > 1 ? `<span class="qty">${slot.quantity}</span>` : ''}${slot.equipped ? '<span class="eq">E</span>' : ''}${locked ? `<span class="lk" title="Locked">${LOCK_SVG}</span>` : ''}<span class="rm">${RARITY_MARK[slot.rarity] ?? ''}</span>${badgeHtml(sctx, slot)}`,
        );
        cell.addEventListener('pointerenter', (e) => this.showTooltip(slot, e));
        cell.addEventListener('pointermove', (e) => this.moveTooltip(e));
        cell.addEventListener('pointerleave', () => this.hideTooltip());
        cell.addEventListener('click', () => {
          this.selected = this.selected === i ? null : i;
          this.render();
        });
        cell.addEventListener('dblclick', () => this.primaryAction(slot));
        if (this.onBelt && slot.item_id in BREWS) {
          // Drag a brew onto its slot on the HUD belt (the HUD listens for this type).
          cell.draggable = true;
          cell.addEventListener('dragstart', (e) => {
            e.dataTransfer?.setData(BELT_DRAG_TYPE, slot.item_id);
            if (e.dataTransfer) e.dataTransfer.effectAllowed = 'copy';
            this.hideTooltip();
          });
        }
        cell.addEventListener('contextmenu', (e) => {
          if (toolKindOf(slot.item_id)) {
            e.preventDefault();
            void this.toggleToolBelt(slot);
            return;
          }
          if (!this.onBelt || !(slot.item_id in BREWS)) return;
          e.preventDefault();
          this.onBelt(slot.item_id);
        });
      } else cell.disabled = true;
      if (this.selected === i) cell.classList.add('selected');
      grid.appendChild(cell);
    }
    this.renderEquipment();
    this.renderSetSummary();
    this.renderLegionButton();
    this.renderToolBelt();
    this.renderTools();
    this.renderBeltOffer();
    this.renderDetail();
  }

  /** Sell all junk: the count and gold are shown, then confirmed in place. Locked items are never included. */
  private renderTools() {
    const tools = this.el!.querySelector<HTMLDivElement>('[data-tools]')!;
    // The Legion button lives in this footer row (beside the slot count) so it costs no height of its own. The row is rebuilt
    // below, so lift the button out first and put it back after; it keeps its click handler because it is the same element.
    const legionBtn = this.el!.querySelector<HTMLButtonElement>('[data-legion]');
    legionBtn?.remove();
    const placeLegion = () => { if (legionBtn) tools.insertBefore(legionBtn, tools.querySelector('[data-junk], [data-junk-yes]')); };
    if (!this.onSold) {
      tools.innerHTML = '';
      placeLegion();
      return;
    }
    const junk = junkSlots(this.inventory.all, this.locks, keepsForYou(this.statContext?.() ?? null));
    const gold = junk.reduce((n, s) => n + s.sell_value * s.quantity, 0);
    const used = this.inventory.all.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE).length;
    if (this.confirmJunk && junk.length) {
      tools.innerHTML = `<span class="cw-tools-confirm">Sell <b>${junk.length}</b> junk item${junk.length === 1 ? '' : 's'} (common and uncommon gear; locked items and upgrades for you are kept) for <b>${gold.toLocaleString()}g</b>?</span>
        <button class="cw-button small" data-junk-yes>Sell them</button><button class="cw-button small ghost" data-junk-no>Cancel</button>`;
      tools.querySelector('[data-junk-yes]')!.addEventListener('click', () => this.sellJunk());
      tools.querySelector('[data-junk-no]')!.addEventListener('click', () => { this.confirmJunk = false; this.render(); });
      placeLegion();
      return;
    }
    this.confirmJunk = false;
    tools.innerHTML = `<span class="cw-tools-count" data-bagcount>${used} / ${BAG_SIZE} slots</span>
      <button class="cw-button small" data-sort ${used > 1 ? '' : 'disabled'} title="Merges stacks, then orders the bag by type, rarity, item level and name">Sort</button>
      <button class="cw-button small" data-junk ${junk.length ? '' : 'disabled'} title="Sells unlocked common and uncommon gear, except pieces that would upgrade you (the green arrow). Lock an item to keep it out.">Sell all junk${junk.length ? ` (${junk.length} · ${gold.toLocaleString()}g)` : ''}</button>`;
    tools.querySelector('[data-sort]')?.addEventListener('click', () => { this.selected = null; this.inventory.sortBag((moves) => this.locks.remap(moves)); });
    tools.querySelector('[data-junk]')?.addEventListener('click', () => { this.confirmJunk = true; this.render(); });
    placeLegion();
  }

  private sellJunk() {
    if (!this.onSold) return;
    this.confirmJunk = false;
    const list = junkSlots(this.inventory.all, this.locks, keepsForYou(this.statContext?.() ?? null));
    let gold = 0;
    let count = 0;
    for (const slot of list) {
      for (let i = 0; i < slot.quantity && this.inventory.consumeAt(slot.slot_index); i++) {
        gold += slot.sell_value;
        count++;
      }
    }
    this.selected = null;
    if (count) this.onSold(gold, `${count} junk item${count === 1 ? '' : 's'}`, count);
    this.render();
  }

  /** Worn gear (server slots 100+) is invisible to the bag grid, so it gets its own paper-doll. */
  private renderEquipment() {
    const doll = this.el!.querySelector<HTMLDivElement>('.cw-equip')!;
    doll.innerHTML = '';
    const worn = equippedBySlot(this.inventory.all);
    // Pieces of a set with at least two worn glow faintly in that set's accent, so you can see what counts.
    const setOf = new Map(resolveSetBonuses(this.inventory.all).sets.filter((s) => s.worn >= 2).flatMap((s) => s.wornParts.map((p) => [p as string, s] as const)));
    for (const [at, id] of DOLL.entries()) {
      if (!id) {
        if (at === DOLL.length - 1 && this.onSheet) {
          const b = Object.assign(document.createElement('button'), { className: 'cw-equip-sheet', type: 'button', innerHTML: '<span class="glyph">☰</span>Sheet · J' });
          b.setAttribute('aria-label', 'Open the character sheet (J)');
          b.addEventListener('click', () => this.onSheet?.());
          doll.appendChild(b);
          continue;
        }
        doll.appendChild(Object.assign(document.createElement('div'), { className: 'cw-equip-gap' }));
        continue;
      }
      const meta = EQUIP_SLOTS.find((s) => s.id === id)!;
      const slot = worn[id];
      const cell = document.createElement('button');
      cell.className = 'cw-slot cw-equip-slot';
      cell.setAttribute('aria-label', slot ? `${meta.label}: ${slot.name}, ${slot.rarity}` : `${meta.label}: empty`);
      if (slot) {
        cell.classList.add('filled', 'equipped');
        const inSet = setOf.get(id);
        if (inSet) {
          cell.classList.add('in-set');
          cell.style.setProperty('--set', `#${inSet.accent.toString(16).padStart(6, '0')}`);
          cell.setAttribute('aria-label', `${meta.label}: ${slot.name}, ${slot.rarity}, part of ${inSet.setName} ${inSet.worn} of 5`);
        }
        cell.style.setProperty('--rarity', RARITY_COLOR[slot.rarity] ?? RARITY_COLOR.common);
        const img = document.createElement('img');
        img.className = 'item-icon';
        img.src = itemIcon(slot);
        img.alt = '';
        img.onerror = () => img.replaceWith(Object.assign(document.createElement('span'), { className: 'glyph', textContent: meta.glyph }));
        cell.appendChild(img);
        cell.insertAdjacentHTML('beforeend', `<span class="rm">${RARITY_MARK[slot.rarity] ?? ''}</span>`);
        cell.addEventListener('pointerenter', (e) => this.showTooltip(slot, e));
        cell.addEventListener('pointermove', (e) => this.moveTooltip(e));
        cell.addEventListener('pointerleave', () => this.hideTooltip());
        cell.addEventListener('click', () => {
          this.selected = this.selected === slot.slot_index ? null : slot.slot_index;
          this.render();
        });
        cell.addEventListener('dblclick', () => void this.toggleEquip(slot));
        if (this.selected === slot.slot_index) cell.classList.add('selected');
      } else {
        cell.classList.add('empty');
        cell.disabled = true;
        cell.insertAdjacentHTML('beforeend', `<span class="glyph dim">${meta.glyph}</span><span class="slot-label">${meta.label}</span>`);
      }
      doll.appendChild(cell);
    }
  }

  /** Under the paper doll: for each set you wear (best two), five pips for its pieces, the tiers that are on, and what the next tier needs. */
  private renderSetSummary() {
    const box = this.el!.querySelector<HTMLDivElement>('.cw-setsum')!;
    const sets = resolveSetBonuses(this.inventory.all).sets.slice(0, 2);
    box.hidden = sets.length === 0;
    box.innerHTML = sets.map((s) => {
      const color = `#${s.accent.toString(16).padStart(6, '0')}`;
      const family = this.statContext?.()?.discipline ?? { family: 'necromancer' as const };
      const pips = ARMOR_PARTS.map((part) => `<i class="${s.wornParts.includes(part) ? 'on' : ''}" title="${part}${s.wornParts.includes(part) ? ' (worn)' : ''}"></i>`).join('');
      const on = s.bonuses.filter((b) => b.active).map((b) => `<div class="on"><span class="n">${b.pieces}</span>${esc(b.name ? `${b.name}: ` : '')}${esc(b.lines.join(' \u00B7 '))}${effectRelevant(b.effect, family) ? '' : ' <i>(no effect for your class)</i>'}</div>`).join('');
      const nextB = s.bonuses.find((b) => !b.active);
      let next = '<div class="done">Set complete</div>';
      if (nextB) {
        const need = nextB.pieces - s.worn;
        const miss = s.missing.map((m) => m.part).join(' or ');
        const where = s.missing.length === 1 || need === s.missing.length ? s.missing.map((m) => m.where).filter((w, i, a) => a.indexOf(w) === i).join(', ') : '';
        next = `<div class="nx"><span class="n">${nextB.pieces}</span>${esc(nextB.name ? `${nextB.name}: ` : '')}${esc(nextB.lines.join(' \u00B7 '))}<em>Need ${need} more: ${esc(need === s.missing.length ? miss.replace(/ or /g, ', ') : miss)}${where ? ` \u00B7 ${esc(where)}` : ''}</em></div>`;
      }
      return `<div class="ss" style="--set:${color}"><div class="hd"><b>${esc(s.setName)}</b><span class="pips">${pips}</span></div>${on}${next}</div>`;
    }).join('');
  }

  /** The Legion button under the tool belt: a dot when a spare piece would beat what the legion wears. */
  private renderLegionButton() {
    const b = this.el!.querySelector<HTMLButtonElement>('[data-legion]')!;
    b.hidden = !this.onLegion;
    if (!this.onLegion) return;
    const better = this.inventory.all.some((s) => kitCandidate(this.inventory.all, s)?.verdict === 'up');
    b.classList.toggle('flag', better);
    b.title = better ? 'A spare piece in your bag would arm your thralls better (Y)' : 'Spare weapons and armour for your thralls (Y)';
    b.onclick = () => this.onLegion?.();
  }

  /** The gathering tool belt: four slots (hatchet, pickaxe, rod, spade) under the paper doll. */
  private renderToolBelt() {
    const row = this.el!.querySelector<HTMLDivElement>('.cw-toolbelt')!;
    row.innerHTML = '';
    const on = beltTools(this.inventory.all);
    for (const kind of BELT_KINDS) {
      const slot = on[kind];
      const cell = document.createElement('button');
      cell.className = 'cw-slot cw-belt-slot';
      cell.setAttribute('aria-label', slot ? `Tool belt, ${BELT_LABEL[kind]}: ${slot.name}` : `Tool belt, ${BELT_LABEL[kind]}: empty`);
      if (slot) {
        cell.classList.add('filled', 'equipped');
        cell.style.setProperty('--rarity', RARITY_COLOR[slot.rarity] ?? RARITY_COLOR.common);
        const img = document.createElement('img');
        img.className = 'item-icon';
        img.src = itemIcon(slot);
        img.alt = '';
        img.onerror = () => img.replaceWith(Object.assign(document.createElement('span'), { className: 'glyph', textContent: '◆' }));
        cell.appendChild(img);
        cell.addEventListener('pointerenter', (e) => this.showTooltip(slot, e));
        cell.addEventListener('pointermove', (e) => this.moveTooltip(e));
        cell.addEventListener('pointerleave', () => this.hideTooltip());
        cell.addEventListener('click', () => {
          this.selected = this.selected === slot.slot_index ? null : slot.slot_index;
          this.render();
        });
        cell.addEventListener('dblclick', () => void this.toggleToolBelt(slot));
        if (this.selected === slot.slot_index) cell.classList.add('selected');
      } else {
        cell.classList.add('empty');
        cell.disabled = true;
        cell.insertAdjacentHTML('beforeend', `<span class="slot-label">${BELT_LABEL[kind]}</span>`);
      }
      row.appendChild(cell);
    }
  }

  /** The one-time offer: an empty belt and tools in the bag. Offered, never forced; "No thanks" is remembered per character. */
  private renderBeltOffer() {
    const tools = this.el!.querySelector<HTMLDivElement>('[data-tools]')!;
    if (this.confirmJunk || offerDismissed(this.characterId)) return;
    const picks = beltOffer(this.inventory.all);
    if (!picks.length) return;
    const offer = document.createElement('span');
    offer.className = 'cw-belt-offer';
    offer.innerHTML = `Belt your best tools? <button class="cw-button small" data-belt-yes title="Moves the best hatchet, pickaxe, rod and spade in your bag onto the tool belt">Put ${picks.length === 1 ? 'it' : picks.length} on the belt</button><button class="cw-button small ghost" data-belt-no>No thanks</button>`;
    offer.querySelector('[data-belt-yes]')!.addEventListener('click', () => {
      dismissOffer(this.characterId);
      void this.moveToBelt(picks.map((p) => ({ slot_index: p.slot_index, equipped: 1 as const })));
    });
    offer.querySelector('[data-belt-no]')!.addEventListener('click', () => { dismissOffer(this.characterId); this.render(); });
    tools.prepend(offer);
  }

  private async moveToBelt(moves: { slot_index: number; equipped: 0 | 1 }[]) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    try {
      await moveTools(this.inventory, this.characterId, moves);
      this.selected = null;
      if (moves.some((m) => m.equipped)) this.onToolBelted?.();
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'The belt would not take that.');
    } finally {
      this.busy = false;
      this.render();
    }
  }

  private async giveToLegion(slot: InventorySlot) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    try {
      await moveKit(this.inventory, this.characterId, [{ slot_index: slot.slot_index, equipped: 1 }]);
      this.selected = null;
      this.onLegionGiven?.();
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'The legion would not take that.');
    } finally {
      this.busy = false;
      this.render();
    }
  }

  private toggleToolBelt(slot: InventorySlot) {
    return this.moveToBelt([{ slot_index: slot.slot_index, equipped: isOnBelt(slot) ? 0 : 1 }]);
  }

  /** What equipping this instead of the worn piece changes for this character (gearText.ts). */
  private compareLines(slot: InventorySlot) {
    return compareTableHtml(this.statContext?.() ?? null, slot);
  }

  private statLines(slot: InventorySlot, withVerdict = true) {
    return itemStatsHtml(this.statContext?.() ?? null, slot, withVerdict);
  }

  /** A Relic rune says exactly what it changes, what it costs, which rite it fits and where it drops. */
  private runeLines(slot: InventorySlot) {
    if (!isRuneId(slot.item_id)) return '';
    const r = RUNES[slot.item_id];
    const rite = ABILITIES[r.rite].name;
    const now = this.socketed(r.rite);
    return `<div class="cw-rune-line"><b>Fits ${rite}.</b> ${r.lines.map((l) => l).join(' ')}</div>${r.cost ? `<div class="cw-rune-line"><em>Cost: ${r.cost}</em></div>` : ''}<div class="cw-rune-line">${now ? (now === r.id ? 'Already socketed in this rite.' : `Replaces ${RUNES[now].name}, which returns to your bag.`) : `Socket it in the Grimoire or with the button below.`} Drops from ${runeSources(r.id)}.</div>`;
  }

  private setLine(slot: InventorySlot) {
    if (slot.item_type === 'rune') return this.runeLines(slot);
    const weapon = necroWeaponTooltip(slot.item_id);
    if (weapon) return `<div class="stat">${weapon.effect}</div><div class="lore">Recommended level ${weapon.level}. Only necromancers gain the effect; other classes keep the stats.</div>`;
    const piece = ARMOR_BY_ID[slot.item_id];
    if (!piece) return '';
    return `${setTooltipHtml(this.statContext?.() ?? null, this.inventory.all, slot)}<div class="lore">Any class can wear it.</div>`;
  }

  private showTooltip(slot: InventorySlot, e: PointerEvent) {
    if (!this.tooltip || e.pointerType === 'touch') return;
    const meta = itemMeta(slot.item_id);
    this.tooltip.innerHTML = `
      <div class="name" style="color:${RARITY_COLOR[slot.rarity]}">${slot.name}</div>
      <div class="type">${RARITY_MARK[slot.rarity]} ${slot.rarity} ${itemTypeLabel(slot)}</div>
      ${itemLevelHtml(slot)}
      ${this.statLines(slot)}
      ${this.setLine(slot)}
      ${compareChipsHtml(this.statContext?.() ?? null, slot)}
      ${brewSummary(slot.item_id) ? `<div class="brew-line">${brewSummary(slot.item_id)}</div>` : ''}
      ${this.onBelt && slot.item_id in BREWS ? `<div class="brew-line">Belt key ${BREW_KEYS[BREWS[slot.item_id].slot].toUpperCase()}: right-click or drag it onto the Belt at the left edge.</div>` : ''}
      ${meta.lore ? `<div class="lore">${meta.lore}</div>` : ''}
      <div class="sell">Worth ${slot.sell_value}g</div>
    `;
    this.tooltip.style.display = 'block';
    this.moveTooltip(e);
  }

  private moveTooltip(e: PointerEvent) {
    if (!this.tooltip || this.tooltip.style.display === 'none') return;
    const r = this.tooltip.getBoundingClientRect();
    this.tooltip.style.left = `${Math.min(e.clientX + 14, window.innerWidth - r.width - 8)}px`;
    this.tooltip.style.top = `${Math.min(e.clientY + 14, window.innerHeight - r.height - 8)}px`;
  }

  private hideTooltip() {
    if (this.tooltip) this.tooltip.style.display = 'none';
  }

  /** `slot:item` of the stack whose Sell all is awaiting its in-place confirm. */
  private confirmSellAll: string | null = null;

  private renderDetail() {
    const detail = this.el!.querySelector<HTMLDivElement>('[data-detail]')!;
    const slot = this.selected !== null ? this.slotAt(this.selected) : undefined;
    if (!slot) {
      detail.innerHTML = '<span class="cw-hint-text">Select a relic. Double-click to equip, drink or eat.</span>';
      return;
    }
    const meta = itemMeta(slot.item_id);
    const equippable = equipSlotOf(slot) !== null;
    const drinkable = slot.item_id in HEALING_FLASKS || slot.item_id in BUFF_FLASKS;
    const edible = slot.item_id in MEALS;
    const locked = this.locks.isLocked(slot);
    const atGrinder = this.grinder?.near() ?? false;
    const compare = this.compareLines(slot);
    const pet = petForCharm(slot.item_id);
    const legion = this.onLegion ? kitCandidate(this.inventory.all, slot) : null;
    detail.innerHTML = `
      <div class="info${compare ? ' gs-wide' : ''}">
        <div class="gs-head">
          <div class="name" style="color:${RARITY_COLOR[slot.rarity]}">${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}</div>
          <div class="type">${RARITY_MARK[slot.rarity]} ${slot.rarity} ${itemTypeLabel(slot)}${itemLevelHtml(slot, true)}</div>
          ${verdictHtml(this.statContext?.() ?? null, slot)}
          ${legion ? `<div class="lg-line ${legion.verdict}" title="What this piece would do on your thralls, against what the legion's ${KIT_LABEL[legion.kit]} slot holds now">Legion ${KIT_LABEL[legion.kit].toLowerCase()}: <span class="ar">${legion.verdict === 'up' ? '\u25B2' : legion.verdict === 'down' ? '\u25BC' : '='}</span> ${legion.verdict === 'same' ? 'no change' : legion.text}</div>` : ''}
        </div>
        <div class="gs-col">
        ${this.statLines(slot, false)}
        ${this.setLine(slot)}
        ${brewSummary(slot.item_id) ? `<div class="brew-line">${brewSummary(slot.item_id)}</div>` : ''}
        ${meta.lore && !compare ? `<div class="lore">${meta.lore}</div>` : ''}
        </div>
        ${compare ? `<div class="gs-col">${compare}</div>` : ''}
      </div>
      <div class="cw-detail-actions">
      ${equippable ? `<button class="cw-button small" data-act>${slot.equipped ? 'Unequip' : 'Equip'}</button>` : ''}
      ${legion ? `<button class="cw-button small" data-legiongive title="Move it to the legion's ${KIT_LABEL[legion.kit]} slot; a piece already there returns to your bag">Give to legion</button>` : ''}
      ${toolKindOf(slot.item_id) ? `<button class="cw-button small" data-toolbelt>${isOnBelt(slot) ? 'Take off belt' : 'Put on belt'}</button>` : ''}
      ${drinkable ? `<button class="cw-button small" data-act>Drink</button>` : ''}
      ${this.onBelt && slot.item_id in BREWS ? `<button class="cw-button small primary" data-belt title="Puts it in the ${BREW_KEYS[BREWS[slot.item_id].slot] === 'z' ? 'Elixir' : 'Tonic'} slot of the Belt at the left edge">Put on belt (key ${BREW_KEYS[BREWS[slot.item_id].slot].toUpperCase()})</button>` : ''}
      ${edible ? `<button class="cw-button small" data-act>Eat</button>` : ''}
      ${pet ? `<button class="cw-button small" data-adopt title="The ${pet.name} joins you for good and the charm is spent. Call it from Capes &amp; Pets (N)">Adopt ${pet.name}</button>` : ''}
      ${!slot.equipped ? `<button class="cw-button small ${locked ? 'on' : ''}" data-lock title="${locked ? 'Unlock: bulk actions may take it again' : 'Lock: Sell all junk, Deposit and Salvage all will skip it'}">${LOCK_SVG} ${locked ? 'Unlock' : 'Lock'}</button>` : ''}
      ${slot.item_type === 'rune' && isRuneId(slot.item_id) && this.onRune ? `<button class="cw-button small" data-runesocket title="Move one into the ${ABILITIES[RUNES[slot.item_id].rite].name} socket">Socket into ${ABILITIES[RUNES[slot.item_id].rite].name}</button>` : ''}
      ${this.grinder && !slot.equipped && isSalvageable(slot.item_type) ? `<button class="cw-button small" data-salvage ${atGrinder ? '' : 'disabled'} title="${atGrinder ? 'Break it down for materials and reagents' : 'Stand at the Bone Grinder in the Sexton’s Acre to salvage'}">Salvage</button>${atGrinder ? '' : '<span class="cw-hint-text small">Needs the Bone Grinder (Acre)</span>'}` : ''}
      ${this.onSold && !slot.equipped && slot.sell_value > 0 ? `<button class="cw-button small" data-sell="1" ${locked ? 'disabled title="Unlock it to sell"' : ''}>Sell (${slot.sell_value}g)</button>` : ''}
      ${this.onSold && !slot.equipped && slot.sell_value > 0 && slot.quantity > 1 ? (this.confirmSellAll === `${slot.slot_index}:${slot.item_id}` && !locked
        ? `<span class="cw-tools-confirm">Sell all <b>${slot.quantity}</b> ${slot.name} for <b>${(slot.sell_value * slot.quantity).toLocaleString()}g</b>?</span><button class="cw-button small primary" data-sell="${slot.quantity}">Sell them</button><button class="cw-button small ghost" data-sellall-no>Cancel</button>`
        : `<button class="cw-button small" data-sellall ${locked ? 'disabled title="Unlock it to sell"' : ''}>Sell all (${slot.quantity} · ${(slot.sell_value * slot.quantity).toLocaleString()}g)</button>`) : ''}
      </div>
    `;
    detail.querySelector('[data-runesocket]')?.addEventListener('click', () => void this.socketRune(slot));
    detail.querySelector('[data-adopt]')?.addEventListener('click', () => pet && void this.adoptCharm(pet.id));
    detail.querySelector('[data-lock]')?.addEventListener('click', () => this.locks.toggle(slot));
    detail.querySelector('[data-salvage]')?.addEventListener('click', () => void this.salvageOne(slot));
    detail.querySelector('[data-act]')?.addEventListener('click', () => this.primaryAction(slot));
    detail.querySelector('[data-toolbelt]')?.addEventListener('click', () => void this.toggleToolBelt(slot));
    detail.querySelector('[data-legiongive]')?.addEventListener('click', () => void this.giveToLegion(slot));
    detail.querySelector('[data-belt]')?.addEventListener('click', () => this.onBelt?.(slot.item_id));
    detail.querySelector('[data-sellall]')?.addEventListener('click', () => { this.confirmSellAll = `${slot.slot_index}:${slot.item_id}`; this.render(); });
    detail.querySelector('[data-sellall-no]')?.addEventListener('click', () => { this.confirmSellAll = null; this.render(); });
    // On a phone the bag detail sits at the bottom of a scrolled panel: keep the confirm buttons in view.
    detail.querySelector('[data-sellall-no]')?.scrollIntoView({ block: 'nearest' });
    detail.querySelectorAll<HTMLButtonElement>('[data-sell]').forEach((b) => b.addEventListener('click', () => this.sell(slot, Number(b.dataset.sell))));
  }

  /** Adopt a pet from its charm in the bag: the same server call as Capes & Pets, run under exclusiveAction so saves stay race-safe. */
  private async adoptCharm(petId: string) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    try {
      await this.inventory.exclusiveAction(() => adoptPet(this.characterId, petId), () => getInventory(this.characterId));
      if (this.selected !== null && !this.slotAt(this.selected)) this.selected = null;
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'The Sexton refuses.');
    } finally {
      this.busy = false;
      this.render();
    }
  }

  private async socketRune(slot: InventorySlot) {
    if (this.busy || !this.onRune || !isRuneId(slot.item_id)) return;
    this.busy = true;
    this.setError('');
    try {
      const err = await this.onRune(RUNES[slot.item_id].rite, slot.item_id);
      if (err) this.setError(err);
      else if (!this.slotAt(slot.slot_index)) this.selected = null;
    } finally {
      this.busy = false;
      this.render();
    }
  }

  /** Sell from the bag (never equipped gear). Each unit goes through consume(), so saves stay race-safe. */
  private sell(slot: InventorySlot, quantity: number) {
    if (slot.equipped || !this.onSold) return;
    this.confirmSellAll = null;
    let sold = 0;
    if (this.locks.isLocked(slot)) return;
    for (let i = 0; i < quantity && this.inventory.consumeAt(slot.slot_index); i++) sold++;
    if (!sold) return;
    this.onSold(sold * slot.sell_value, slot.name, sold);
    if (!this.slotAt(slot.slot_index)) this.selected = null;
    this.render();
  }

  private async salvageOne(slot: InventorySlot) {
    if (this.busy || !this.grinder) return;
    this.busy = true;
    this.setError('');
    try {
      await this.grinder.salvage([slot.slot_index]);
      this.selected = null;
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Salvage failed');
    } finally {
      this.busy = false;
      this.render();
    }
  }

  private primaryAction(slot: InventorySlot) {
    if (slot.item_id in HEALING_FLASKS || slot.item_id in BUFF_FLASKS || slot.item_id in MEALS) this.onUse(slot.item_id);
    else if (toolKindOf(slot.item_id)) void this.toggleToolBelt(slot);
    else if (equipSlotOf(slot) !== null) void this.toggleEquip(slot);
  }

  private setError(msg: string) {
    const el = this.el?.querySelector<HTMLDivElement>('[data-error]');
    if (el) el.textContent = msg;
  }

  private async toggleEquip(slot: InventorySlot) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    try {
      // Unsaved pickups land first and no save flies during the equip (Inventory.exclusive).
      await this.inventory.exclusive(async () => {
        // The server displaces whatever already fills the slot (and a two-hander's off-hand) back into the bag.
        const slots = await equipItem(this.characterId, slot.slot_index, slot.equipped ? 0 : 1);
        this.selected = null;
        this.inventory.replace(slots);
        if (!slot.equipped) this.onEquipped?.();
      });
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Equip failed');
    } finally {
      this.busy = false;
    }
  }
}
