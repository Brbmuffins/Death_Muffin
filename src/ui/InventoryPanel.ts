import { equipItem } from '../net/api';
import type { InventorySlot, Rarity } from '../net/types';
import { STAT_KEYS, STAT_LABELS } from '../gameplay/stats';

export const BAG_COLS = 6;
export const BAG_ROWS = 4;
export const BAG_SIZE = BAG_COLS * BAG_ROWS; // matches Unity's 4×6 bag

const RARITY_COLORS: Record<Rarity, string> = {
  common: '#b8c2cc',
  uncommon: '#4ade80',
  rare: '#60a5fa',
  epic: '#c084fc',
};

const TYPE_GLYPHS: Record<InventorySlot['item_type'], string> = {
  weapon: '⚔',
  armor_head: '⛨',
  armor_chest: '🛡',
  armor_legs: '⛊',
  ring: '◎',
  trinket: '✦',
  material: '◆',
};

// PNG icons keyed by item_id. Falls back to TYPE_GLYPHS for anything not listed.
const ITEM_ICONS: Record<string, string> = {
  copper_shard: 'art/items/material_copper_shard.png',
  copper_bar:   'art/items/material_copper_bar.png',
  copper_ring:  'art/items/ring_copper.png',
};

const EQUIPPABLE = new Set(['weapon', 'armor_head', 'armor_chest', 'armor_legs', 'ring', 'trinket']);

/**
 * 4×6 bag grid with hover tooltips and an equip/unequip detail bar.
 * Desktop: hover shows the tooltip, click selects. Touch: tap selects and
 * the detail bar doubles as the tooltip. Equip toggles go straight to
 * POST /api/inventory/equip; the server responds with the full updated
 * slot array, which becomes the new source of truth.
 */
export class InventoryPanel {
  private el: HTMLDivElement | null = null;
  private tooltip: HTMLDivElement | null = null;
  private slots: InventorySlot[] = [];
  private selectedIndex: number | null = null;
  private busy = false;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private onSlotsChanged: (slots: InventorySlot[]) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  setSlots(slots: InventorySlot[]) {
    this.slots = slots;
    if (this.el) this.renderGrid();
  }

  open(slots: InventorySlot[]) {
    if (this.el) return;
    this.slots = slots;
    this.el = document.createElement('div');
    this.el.className = 'cw-bag';
    this.el.innerHTML = `
      <div class="cw-bag-head">
        <span class="cw-bag-title">Inventory</span>
        <button class="cw-icon-btn" data-close aria-label="Close inventory">✕</button>
      </div>
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

    this.renderGrid();
  }

  close() {
    this.el?.remove();
    this.el = null;
    this.tooltip?.remove();
    this.tooltip = null;
    this.selectedIndex = null;
  }

  private slotAt(index: number): InventorySlot | undefined {
    return this.slots.find((s) => s.slot_index === index);
  }

  private renderGrid() {
    const grid = this.el!.querySelector<HTMLDivElement>('.cw-bag-grid')!;
    grid.innerHTML = '';
    for (let i = 0; i < BAG_SIZE; i++) {
      const slot = this.slotAt(i);
      const cell = document.createElement('button');
      cell.className = 'cw-slot';
      cell.setAttribute('role', 'gridcell');
      if (slot) {
        cell.classList.add('filled');
        if (slot.equipped) cell.classList.add('equipped');
        cell.style.setProperty('--rarity', RARITY_COLORS[slot.rarity] ?? RARITY_COLORS.common);
        const iconPng = ITEM_ICONS[slot.item_id];
        cell.innerHTML = `
          ${iconPng
            ? `<img class="item-icon" src="${iconPng}" alt="${slot.name}" onerror="this.style.display='none'">`
            : `<span class="glyph">${TYPE_GLYPHS[slot.item_type] ?? '◆'}</span>`}
          ${slot.quantity > 1 ? `<span class="qty">${slot.quantity}</span>` : ''}
          ${slot.equipped ? '<span class="eq">E</span>' : ''}
        `;
        cell.addEventListener('pointerenter', (e) => this.showTooltip(slot, e));
        cell.addEventListener('pointermove', (e) => this.moveTooltip(e));
        cell.addEventListener('pointerleave', () => this.hideTooltip());
        cell.addEventListener('click', () => this.select(i));
      } else {
        cell.disabled = true;
      }
      if (this.selectedIndex === i) cell.classList.add('selected');
      grid.appendChild(cell);
    }
    this.renderDetail();
  }

  private select(index: number) {
    this.selectedIndex = this.selectedIndex === index ? null : index;
    this.renderGrid();
  }

  private statLines(slot: InventorySlot): string {
    if (!slot.stat_bonus) return '';
    return STAT_KEYS.filter((k) => slot.stat_bonus![k])
      .map((k) => `<div class="stat">+${slot.stat_bonus![k]} ${STAT_LABELS[k]}</div>`)
      .join('');
  }

  private showTooltip(slot: InventorySlot, e: PointerEvent) {
    if (!this.tooltip || e.pointerType === 'touch') return;
    this.tooltip.innerHTML = `
      <div class="name" style="color:${RARITY_COLORS[slot.rarity]}">${slot.name}</div>
      <div class="type">${slot.rarity} ${slot.item_type.replace('_', ' ')}</div>
      ${this.statLines(slot)}
      <div class="sell">Sell: ${slot.sell_value}g</div>
    `;
    this.tooltip.style.display = 'block';
    this.moveTooltip(e);
  }

  private moveTooltip(e: PointerEvent) {
    if (!this.tooltip || this.tooltip.style.display === 'none') return;
    const pad = 14;
    const rect = this.tooltip.getBoundingClientRect();
    const x = Math.min(e.clientX + pad, window.innerWidth - rect.width - 8);
    const y = Math.min(e.clientY + pad, window.innerHeight - rect.height - 8);
    this.tooltip.style.left = `${x}px`;
    this.tooltip.style.top = `${y}px`;
  }

  private hideTooltip() {
    if (this.tooltip) this.tooltip.style.display = 'none';
  }

  private renderDetail() {
    const detail = this.el!.querySelector<HTMLDivElement>('[data-detail]')!;
    const slot = this.selectedIndex !== null ? this.slotAt(this.selectedIndex) : undefined;
    if (!slot) {
      detail.innerHTML = '<span class="hint">Select an item</span>';
      return;
    }
    const equippable = EQUIPPABLE.has(slot.item_type);
    detail.innerHTML = `
      <div class="info">
        <div class="name" style="color:${RARITY_COLORS[slot.rarity]}">${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}</div>
        <div class="type">${slot.rarity} ${slot.item_type.replace('_', ' ')}</div>
        ${this.statLines(slot)}
      </div>
      ${equippable ? `<button class="cw-button cw-equip-btn" data-equip>${slot.equipped ? 'Unequip' : 'Equip'}</button>` : ''}
    `;
    detail
      .querySelector('[data-equip]')
      ?.addEventListener('click', () => this.toggleEquip(slot));
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
      let slots = this.slots;
      if (!slot.equipped) {
        // Only one item per gear type — swap out a same-type equipped item first.
        const conflict = slots.find(
          (s) => s.equipped && s.item_type === slot.item_type && s.slot_index !== slot.slot_index,
        );
        if (conflict) {
          slots = await equipItem(this.characterId, conflict.slot_index, 0);
        }
      }
      slots = await equipItem(this.characterId, slot.slot_index, slot.equipped ? 0 : 1);
      this.slots = slots;
      this.renderGrid();
      this.onSlotsChanged(slots);
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Equip failed');
    } finally {
      this.busy = false;
    }
  }
}
