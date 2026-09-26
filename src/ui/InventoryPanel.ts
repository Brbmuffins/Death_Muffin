import { equipItem } from '../net/api';
import type { InventorySlot } from '../net/types';
import { STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { BAG_SIZE, type Inventory } from '../gameplay/loot';
import { HEALING_FLASKS, RARITY_COLOR, RARITY_MARK, itemMeta } from '../content/items';

const TYPE_GLYPH: Record<string, string> = {
  weapon: '⚔',
  armor_head: '⛨',
  armor_chest: '⛊',
  armor_legs: '⛊',
  ring: '◎',
  trinket: '✦',
  material: '◆',
};

const EQUIPPABLE = new Set(['weapon', 'armor_head', 'armor_chest', 'armor_legs', 'ring', 'trinket']);

export function itemIcon(slot: Pick<InventorySlot, 'item_id'>) {
  const meta = itemMeta(slot.item_id);
  return meta.icon ?? `art/items/${slot.item_id}.png`;
}

/**
 * The Reliquary: 4×6 bag, hover tooltips, equip/unequip. Equip goes straight
 * to POST /api/inventory/equip and the server's slot array becomes truth.
 */
export class InventoryPanel {
  private el: HTMLDivElement | null = null;
  private tooltip: HTMLDivElement | null = null;
  private selected: number | null = null;
  private busy = false;
  private off: (() => void) | null = null;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private statsLine: () => string,
    private onUse: (itemId: string) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Reliquary');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Reliquary</h2>
        <button class="cw-icon-btn" data-close aria-label="Close reliquary">✕</button>
      </div>
      <div class="cw-stats-line" data-stats></div>
      <div class="cw-bag-grid" role="grid"></div>
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
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
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
    this.el.querySelector('[data-stats]')!.innerHTML = this.statsLine();
    const grid = this.el.querySelector<HTMLDivElement>('.cw-bag-grid')!;
    grid.innerHTML = '';
    for (let i = 0; i < BAG_SIZE; i++) {
      const slot = this.slotAt(i);
      const cell = document.createElement('button');
      cell.className = 'cw-slot';
      cell.setAttribute('role', 'gridcell');
      if (slot) {
        cell.classList.add('filled');
        if (slot.equipped) cell.classList.add('equipped');
        cell.style.setProperty('--rarity', RARITY_COLOR[slot.rarity] ?? RARITY_COLOR.common);
        cell.setAttribute('aria-label', `${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}, ${slot.rarity}${slot.equipped ? ', equipped' : ''}`);
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
          `${slot.quantity > 1 ? `<span class="qty">${slot.quantity}</span>` : ''}${slot.equipped ? '<span class="eq">E</span>' : ''}<span class="rm">${RARITY_MARK[slot.rarity] ?? ''}</span>`,
        );
        cell.addEventListener('pointerenter', (e) => this.showTooltip(slot, e));
        cell.addEventListener('pointermove', (e) => this.moveTooltip(e));
        cell.addEventListener('pointerleave', () => this.hideTooltip());
        cell.addEventListener('click', () => {
          this.selected = this.selected === i ? null : i;
          this.render();
        });
        cell.addEventListener('dblclick', () => this.primaryAction(slot));
      } else cell.disabled = true;
      if (this.selected === i) cell.classList.add('selected');
      grid.appendChild(cell);
    }
    this.renderDetail();
  }

  private statLines(slot: InventorySlot) {
    if (!slot.stat_bonus) return '';
    return STAT_KEYS.filter((k) => slot.stat_bonus![k])
      .map((k) => `<div class="stat">+${slot.stat_bonus![k]} ${STAT_LABELS[k]}</div>`)
      .join('');
  }

  private showTooltip(slot: InventorySlot, e: PointerEvent) {
    if (!this.tooltip || e.pointerType === 'touch') return;
    const meta = itemMeta(slot.item_id);
    this.tooltip.innerHTML = `
      <div class="name" style="color:${RARITY_COLOR[slot.rarity]}">${slot.name}</div>
      <div class="type">${RARITY_MARK[slot.rarity]} ${slot.rarity} ${slot.item_type.replace('_', ' ')}</div>
      ${this.statLines(slot)}
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
      detail.innerHTML = '<span class="cw-hint-text">Select a relic. Double-click to equip or drink.</span>';
      return;
    }
    const meta = itemMeta(slot.item_id);
    const equippable = EQUIPPABLE.has(slot.item_type);
    const drinkable = slot.item_id in HEALING_FLASKS;
    detail.innerHTML = `
      <div class="info">
        <div class="name" style="color:${RARITY_COLOR[slot.rarity]}">${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}</div>
        <div class="type">${RARITY_MARK[slot.rarity]} ${slot.rarity} ${slot.item_type.replace('_', ' ')}</div>
        ${this.statLines(slot)}
        ${meta.lore ? `<div class="lore">${meta.lore}</div>` : ''}
      </div>
      ${equippable ? `<button class="cw-button small" data-act>${slot.equipped ? 'Unequip' : 'Equip'}</button>` : ''}
      ${drinkable ? `<button class="cw-button small" data-act>Drink</button>` : ''}
    `;
    detail.querySelector('[data-act]')?.addEventListener('click', () => this.primaryAction(slot));
  }

  private primaryAction(slot: InventorySlot) {
    if (slot.item_id in HEALING_FLASKS) this.onUse(slot.item_id);
    else if (EQUIPPABLE.has(slot.item_type)) void this.toggleEquip(slot);
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
      // Unsaved pickups must land before equip so the server's array includes them.
      await this.inventory.flush();
      let slots = this.inventory.all;
      if (!slot.equipped) {
        const conflict = slots.find((s) => s.equipped && s.item_type === slot.item_type && s.slot_index !== slot.slot_index);
        if (conflict) slots = await equipItem(this.characterId, conflict.slot_index, 0);
      }
      slots = await equipItem(this.characterId, slot.slot_index, slot.equipped ? 0 : 1);
      this.inventory.replace(slots);
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Equip failed');
    } finally {
      this.busy = false;
    }
  }
}
