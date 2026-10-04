import type { Inventory } from '../gameplay/loot';
import { browserStorage } from '../gameplay/codexJournal';
import { RARITY_COLOR, itemMeta } from '../content/items';
import { SHELF_GROUPS, SHELF_IDS, loadFound, recordFound } from '../content/wing';
import { itemIcon } from './InventoryPanel';
import { wrapPanelBody } from './panelBody';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/**
 * The Reagent Shelf (Alchemist's Wing): every alchemy ingredient as a collection. Found ones show their icon and how many you
 * hold; the rest are dim silhouettes with a hint of where they come from. "Found" means you have ever carried one (browser-local).
 */
export class ReagentShelfPanel {
  private el: HTMLDivElement | null = null;
  private off: (() => void) | null = null;

  constructor(private root: HTMLElement, private characterId: number, private inventory: Inventory) {}

  get isOpen() {
    return this.el !== null;
  }

  open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-shelf';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Reagent Shelf');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    this.el?.remove();
    this.el = null;
  }

  private render() {
    if (!this.el) return;
    const held = new Map<string, number>();
    for (const s of this.inventory.all) held.set(s.item_id, (held.get(s.item_id) ?? 0) + s.quantity);
    const { found } = recordFound(browserStorage(), this.characterId, held.keys());
    for (const id of loadFound(browserStorage(), this.characterId)) found.add(id);
    const have = SHELF_IDS.filter((id) => found.has(id)).length;
    const groups = SHELF_GROUPS.map((g) => `
      <h3 class="cw-panel-section-title">${esc(g.title)}</h3>
      <p class="cw-hint-text">${esc(g.blurb)}</p>
      <div class="cw-shelf-grid">${g.ids.map((id) => {
        const m = itemMeta(id);
        const ok = found.has(id);
        const n = held.get(id) ?? 0;
        return `<div class="cw-shelf-item${ok ? ' found' : ''}" style="--rarity:${RARITY_COLOR[m.rarity] ?? RARITY_COLOR.common}" title="${esc(ok ? `${m.name}: you hold ${n}` : 'Not found yet')}">
          <img src="${itemIcon({ item_id: id })}" alt="" onerror="this.style.visibility='hidden'">
          <span class="nm">${ok ? esc(m.name) : '???'}</span>
          <span class="ct">${ok ? `×${n}` : ''}</span>
        </div>`;
      }).join('')}</div>`).join('');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Reagent Shelf</h2>
        <button class="cw-icon-btn" data-close aria-label="Close Reagent Shelf">✕</button>
      </div>
      <p class="cw-hint-text">Found <b>${have}/${SHELF_IDS.length}</b> reagents. Brew them at the Great Cauldron or the Alembic.</p>
      ${groups}`;
    wrapPanelBody(this.el);
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
  }
}
