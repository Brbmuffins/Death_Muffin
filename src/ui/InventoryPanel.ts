import { equipItem } from '../net/api';
import type { InventorySlot } from '../net/types';
import { BAG_SIZE, type Inventory } from '../gameplay/loot';
import { BREWS, BREW_KEYS, brewSummary } from '../content/brews';
import { BUFF_FLASKS, HEALING_FLASKS, RARITY_COLOR, RARITY_MARK, itemMeta } from '../content/items';
import { MEALS } from '../content/processing';
import { EQUIP_SLOTS, equipSlotOf, equippedBySlot, type EquipSlot } from '../content/gear';
import { ARMOR_BY_ID } from '../content/armorSets';
import { necroWeaponTooltip } from '../content/necroWeapons';
import { ItemLocks, junkSlots } from '../gameplay/itemLocks';
import { isSalvageGear } from '../gameplay/salvageRules';

/** A small padlock for locked cells and the Lock button (inline SVG: no font or emoji dependency). */
export const LOCK_SVG = '<svg viewBox="0 0 12 14" width="11" height="13" aria-hidden="true"><path d="M3 6V4.2a3 3 0 0 1 6 0V6" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="1.5" y="6" width="9" height="7" rx="1" fill="currentColor"/></svg>';
import { badgeHtml, compareChipsHtml, compareTableHtml, itemStatsHtml, type StatContextSource } from './gearText';

const TYPE_GLYPH: Record<string, string> = {
  weapon: '⚔',
  armor_head: '⛨',
  armor_chest: '⛊',
  armor_legs: '⛊',
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
  return meta.icon ?? `art/items/${slot.item_id}.png`;
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
        <h2 class="cw-title">Reliquary</h2>
        <button class="cw-icon-btn" data-close aria-label="Close reliquary">✕</button>
      </div>
      <div class="cw-stats-line" data-stats></div>
      <div class="cw-inv-body">
        <div class="cw-equip" role="group" aria-label="Equipment"></div>
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
        cell.addEventListener('contextmenu', (e) => {
          if (!this.onBelt || !(slot.item_id in BREWS)) return;
          e.preventDefault();
          this.onBelt(slot.item_id);
        });
      } else cell.disabled = true;
      if (this.selected === i) cell.classList.add('selected');
      grid.appendChild(cell);
    }
    this.renderEquipment();
    this.renderTools();
    this.renderDetail();
  }

  /** Sell all junk: the count and gold are shown, then confirmed in place. Locked items are never included. */
  private renderTools() {
    const tools = this.el!.querySelector<HTMLDivElement>('[data-tools]')!;
    if (!this.onSold) {
      tools.innerHTML = '';
      return;
    }
    const junk = junkSlots(this.inventory.all, this.locks);
    const gold = junk.reduce((n, s) => n + s.sell_value * s.quantity, 0);
    const used = this.inventory.all.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE).length;
    if (this.confirmJunk && junk.length) {
      tools.innerHTML = `<span class="cw-tools-confirm">Sell <b>${junk.length}</b> junk item${junk.length === 1 ? '' : 's'} (common and uncommon gear, nothing locked) for <b>${gold.toLocaleString()}g</b>?</span>
        <button class="cw-button small" data-junk-yes>Sell them</button><button class="cw-button small ghost" data-junk-no>Cancel</button>`;
      tools.querySelector('[data-junk-yes]')!.addEventListener('click', () => this.sellJunk());
      tools.querySelector('[data-junk-no]')!.addEventListener('click', () => { this.confirmJunk = false; this.render(); });
      return;
    }
    this.confirmJunk = false;
    tools.innerHTML = `<span class="cw-tools-count" data-bagcount>${used} / ${BAG_SIZE} slots</span>
      <button class="cw-button small" data-junk ${junk.length ? '' : 'disabled'} title="Sells unlocked common and uncommon gear. Lock an item to keep it out.">Sell all junk${junk.length ? ` (${junk.length} · ${gold.toLocaleString()}g)` : ''}</button>`;
    tools.querySelector('[data-junk]')?.addEventListener('click', () => { this.confirmJunk = true; this.render(); });
  }

  private sellJunk() {
    if (!this.onSold) return;
    this.confirmJunk = false;
    const list = junkSlots(this.inventory.all, this.locks);
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

  /** What equipping this instead of the worn piece changes for this character (gearText.ts). */
  private compareLines(slot: InventorySlot) {
    return compareTableHtml(this.statContext?.() ?? null, slot);
  }

  private statLines(slot: InventorySlot) {
    return itemStatsHtml(this.statContext?.() ?? null, slot);
  }

  private setLine(slot: InventorySlot) {
    const weapon = necroWeaponTooltip(slot.item_id);
    if (weapon) return `<div class="stat">${weapon.effect}</div><div class="lore">Recommended level ${weapon.level}. Only necromancers gain the effect; other classes keep the stats.</div>`;
    const piece = ARMOR_BY_ID[slot.item_id];
    if (!piece) return '';
    const worn = this.inventory.all.filter((s) => s.equipped && ARMOR_BY_ID[s.item_id]?.setId === piece.setId).length;
    return `<div class="lore">${piece.setName} set · ${worn}/5 worn</div><div class="lore">Any class can wear it. Stats only, no set bonus.</div>`;
  }

  private showTooltip(slot: InventorySlot, e: PointerEvent) {
    if (!this.tooltip || e.pointerType === 'touch') return;
    const meta = itemMeta(slot.item_id);
    this.tooltip.innerHTML = `
      <div class="name" style="color:${RARITY_COLOR[slot.rarity]}">${slot.name}</div>
      <div class="type">${RARITY_MARK[slot.rarity]} ${slot.rarity} ${slot.item_type.replace('_', ' ')}</div>
      ${this.statLines(slot)}
      ${this.setLine(slot)}
      ${compareChipsHtml(this.statContext?.() ?? null, slot)}
      ${brewSummary(slot.item_id) ? `<div class="brew-line">${brewSummary(slot.item_id)}</div>` : ''}
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
    detail.innerHTML = `
      <div class="info${compare ? ' gs-wide' : ''}">
        <div class="gs-col">
        <div class="name" style="color:${RARITY_COLOR[slot.rarity]}">${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}</div>
        <div class="type">${RARITY_MARK[slot.rarity]} ${slot.rarity} ${slot.item_type.replace('_', ' ')}</div>
        ${this.statLines(slot)}
        ${this.setLine(slot)}
        ${brewSummary(slot.item_id) ? `<div class="brew-line">${brewSummary(slot.item_id)}</div>` : ''}
        ${meta.lore && !compare ? `<div class="lore">${meta.lore}</div>` : ''}
        </div>
        ${compare ? `<div class="gs-col">${compare}</div>` : ''}
      </div>
      <div class="cw-detail-actions">
      ${equippable ? `<button class="cw-button small" data-act>${slot.equipped ? 'Unequip' : 'Equip'}</button>` : ''}
      ${drinkable ? `<button class="cw-button small" data-act>Drink</button>` : ''}
      ${this.onBelt && slot.item_id in BREWS ? `<button class="cw-button small" data-belt>Put on belt (${BREW_KEYS[BREWS[slot.item_id].slot].toUpperCase()})</button>` : ''}
      ${edible ? `<button class="cw-button small" data-act>Eat</button>` : ''}
      ${!slot.equipped ? `<button class="cw-button small ${locked ? 'on' : ''}" data-lock title="${locked ? 'Unlock: bulk actions may take it again' : 'Lock: Sell all junk, Deposit and Salvage all will skip it'}">${LOCK_SVG} ${locked ? 'Unlock' : 'Lock'}</button>` : ''}
      ${this.grinder && !slot.equipped && isSalvageGear(slot.item_type) ? `<button class="cw-button small" data-salvage ${atGrinder ? '' : 'disabled'} title="${atGrinder ? 'Break it down for materials and reagents' : 'Stand at the Bone Grinder in the Sexton’s Acre to salvage'}">Salvage</button>${atGrinder ? '' : '<span class="cw-hint-text small">Needs the Bone Grinder (Acre)</span>'}` : ''}
      ${this.onSold && !slot.equipped && slot.sell_value > 0 ? `<button class="cw-button small" data-sell="1" ${locked ? 'disabled title="Unlock it to sell"' : ''}>Sell (${slot.sell_value}g)</button>` : ''}
      ${this.onSold && !slot.equipped && slot.sell_value > 0 && slot.quantity > 1 ? `<button class="cw-button small" data-sell="${slot.quantity}" ${locked ? 'disabled' : ''}>Sell all ×${slot.quantity} (${(slot.sell_value * slot.quantity).toLocaleString()}g)</button>` : ''}
      </div>
    `;
    detail.querySelector('[data-lock]')?.addEventListener('click', () => this.locks.toggle(slot));
    detail.querySelector('[data-salvage]')?.addEventListener('click', () => void this.salvageOne(slot));
    detail.querySelector('[data-act]')?.addEventListener('click', () => this.primaryAction(slot));
    detail.querySelector('[data-belt]')?.addEventListener('click', () => this.onBelt?.(slot.item_id));
    detail.querySelectorAll<HTMLButtonElement>('[data-sell]').forEach((b) => b.addEventListener('click', () => this.sell(slot, Number(b.dataset.sell))));
  }

  /** Sell from the bag (never equipped gear). Each unit goes through consume(), so saves stay race-safe. */
  private sell(slot: InventorySlot, quantity: number) {
    if (slot.equipped || !this.onSold) return;
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
