import { RUNES, isRuneId } from '../../server/rules/content/runes';
import { getVault, vaultDeposit, vaultDepositAll, vaultSort, vaultWithdraw, type VaultState } from '../net/api';
import type { InventorySlot } from '../net/types';
import { RARITY_COLOR, RARITY_MARK, itemMeta } from '../../server/rules/content/items';
import { rollTitleLines } from '../gameplay/affixes';
import { BAG_SIZE, type Inventory } from '../gameplay/loot';
import { VAULT_SLOTS, VAULT_TAB_SIZE } from '../../server/rules/gameplay/vaultRules';
import type { ItemLocks } from '../gameplay/itemLocks';
import { LOCK_SVG, itemIcon } from './InventoryPanel';
import { itemTypeLabel } from './gearText';
import { wrapPanelBody } from './panelBody';
import { STAT_KEYS, STAT_LABELS } from '../gameplay/stats';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const GLYPH = '◆';

/**
 * The Ossuary Vault (V, in the Chapterhouse or the Acre): a 120-slot stash shared by every character on the account.
 * Click an item to move its whole stack across (the server stacks first, then takes free slots, and refuses a move that will not
 * fit). Every move is a server action wrapped in Inventory.exclusive(), so no bag save races it; the server reply is the truth.
 */
export class VaultPanel {
  private el: HTMLDivElement | null = null;
  private state: VaultState | null = null;
  private tab = 0;
  private busy = false;
  private error = '';
  private note = '';
  private off: (() => void) | null = null;
  private offLocks: (() => void) | null = null;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private locks: ItemLocks,
    /** Fired after the first successful load, for the first-open counsel tip. */
    private onOpened?: () => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  async open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-vault';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Ossuary Vault');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.offLocks = this.locks.onChange(() => this.render());
    this.render();
    try {
      this.state = await this.inventory.exclusive(async () => {
        const st = await getVault(this.characterId);
        this.inventory.replace(st.bag);
        return st;
      });
      this.error = '';
      this.onOpened?.();
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The Vault will not open.';
    }
    this.render();
  }

  close() {
    this.off?.();
    this.offLocks?.();
    this.off = this.offLocks = null;
    this.el?.remove();
    this.el = null;
  }

  private bagSlots(): InventorySlot[] {
    return this.inventory.all.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE);
  }

  private cell(slot: InventorySlot | undefined, kind: 'bag' | 'vault', index: number, locked = false) {
    const btn = document.createElement('button');
    btn.className = 'cw-slot';
    btn.setAttribute('role', 'gridcell');
    if (!slot) {
      btn.disabled = true;
      return btn;
    }
    btn.classList.add('filled');
    if (slot.equipped) btn.classList.add('equipped');
    if (locked) btn.classList.add('locked');
    btn.style.setProperty('--rarity', RARITY_COLOR[slot.rarity] ?? RARITY_COLOR.common);
    const meta = itemMeta(slot.item_id);
    const where = kind === 'bag' ? 'Click to store it in the Vault' : 'Click to take it into your bag';
    // What the Reliquary tooltip would say, in plain text: the kind of item, its base stats, then the roll, the price and the move.
    const stats = slot.stat_bonus ? STAT_KEYS.filter((k) => slot.stat_bonus![k]).map((k) => `+${slot.stat_bonus![k]} ${STAT_LABELS[k]}`).join(', ') : '';
    btn.title = `${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''} (${slot.rarity} ${itemTypeLabel(slot)})${locked ? ' · locked' : ''}\n${stats ? `${stats}\n` : ''}${rollTitleLines(slot).map((l) => `${l}\n`).join('')}${isRuneId(slot.item_id) ? `${RUNES[slot.item_id].short}: ${RUNES[slot.item_id].lines[0]}\n` : ''}${slot.sell_value > 0 ? `Worth ${slot.sell_value}g${slot.quantity > 1 ? ' each' : ''}\n` : ''}${slot.equipped ? 'Equipped gear cannot be stored' : where}`;
    btn.setAttribute('aria-label', `${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}, ${slot.rarity}${locked ? ', locked' : ''}. ${where}`);
    const img = document.createElement('img');
    img.className = 'item-icon';
    img.src = itemIcon(slot);
    img.alt = '';
    img.onerror = () => img.replaceWith(Object.assign(document.createElement('span'), { className: 'glyph', textContent: GLYPH }));
    btn.appendChild(img);
    btn.insertAdjacentHTML('beforeend', `${slot.quantity > 1 ? `<span class="qty">${slot.quantity}</span>` : ''}${locked ? `<span class="lk">${LOCK_SVG}</span>` : ''}<span class="rm">${RARITY_MARK[slot.rarity] ?? ''}</span>`);
    void meta;
    btn.addEventListener('click', () => void (kind === 'bag' ? this.deposit(slot) : this.withdraw(slot)));
    return btn;
  }

  private render() {
    if (!this.el) return;
    const st = this.state;
    const bag = this.bagSlots();
    const vault = st?.vault ?? [];
    const lockedSlots = this.locks.slotsOf(bag);
    const tabCount = Math.ceil(VAULT_SLOTS / VAULT_TAB_SIZE);
    const usedVault = vault.length;
    const tabUsed = (t: number) => vault.filter((v) => v.slot_index >= t * VAULT_TAB_SIZE && v.slot_index < (t + 1) * VAULT_TAB_SIZE).length;
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Ossuary Vault</h2>
        <button class="cw-icon-btn" data-close aria-label="Close vault">✕</button>
      </div>
      <p class="cw-codex-note">One stash for every character on this account. Click an item to move its whole stack across. Locked items stay in your bag when you use the buttons below.</p>
      <div class="cw-vault-cols">
        <section aria-label="Your Reliquary">
          <h3 class="cw-panel-section-title">Reliquary <span class="cw-vault-count">${bag.length} / ${BAG_SIZE}</span></h3>
          <div class="cw-bag-grid cw-vault-grid" data-bag role="grid"></div>
        </section>
        <section aria-label="The Vault">
          <h3 class="cw-panel-section-title">Vault <span class="cw-vault-count">${usedVault} / ${VAULT_SLOTS}</span></h3>
          <div class="cw-vault-tabs" role="tablist">${Array.from({ length: tabCount }, (_, t) => `<button role="tab" aria-selected="${t === this.tab}" class="${t === this.tab ? 'on' : ''}" data-tab="${t}">Tab ${t + 1} <small>${tabUsed(t)}/${VAULT_TAB_SIZE}</small></button>`).join('')}</div>
          <div class="cw-bag-grid cw-vault-grid" data-vault role="grid">${st ? '' : '<span class="cw-hint-text">Opening the Vault…</span>'}</div>
        </section>
      </div>
      <div class="cw-vault-actions">
        <div class="cw-vault-actcol">
          <button class="cw-button small" data-all="materials" ${this.busy || !st ? 'disabled' : ''} title="Stores every unlocked material and consumable in the Vault">Deposit materials</button>
          <button class="cw-button small" data-take="materials" ${this.busy || !st ? 'disabled' : ''} title="Takes every material and consumable from the open Vault tab into your bag, as far as it fits">Take materials</button>
        </div>
        <div class="cw-vault-actcol">
          <button class="cw-button small" data-all="all" ${this.busy || !st ? 'disabled' : ''} title="Stores everything unlocked and not worn">Deposit all</button>
          <button class="cw-button small" data-take="all" ${this.busy || !st ? 'disabled' : ''} title="Takes everything from the open Vault tab into your bag, as far as it fits">Take all</button>
        </div>
        <button class="cw-button small" data-sort ${this.busy || !st ? 'disabled' : ''} title="Merges stacks, then orders by type, rarity and name">Sort</button>
        <span class="cw-hint-text small">${lockedSlots.length ? `${lockedSlots.length} locked item${lockedSlots.length === 1 ? '' : 's'} stay${lockedSlots.length === 1 ? 's' : ''} put` : 'Lock items in the Reliquary (I) to keep them out of the bulk buttons'}</span>
      </div>
      <div class="cw-vault-note" data-note>${esc(this.note)}</div>
      <div class="cw-error" data-error>${esc(this.error)}</div>`;
    wrapPanelBody(this.el);
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    const bagGrid = this.el.querySelector<HTMLDivElement>('[data-bag]')!;
    for (let i = 0; i < BAG_SIZE; i++) {
      const slot = bag.find((s) => s.slot_index === i);
      bagGrid.appendChild(this.cell(slot, 'bag', i, !!slot && this.locks.isLocked(slot)));
    }
    if (st) {
      const vaultGrid = this.el.querySelector<HTMLDivElement>('[data-vault]')!;
      for (let i = 0; i < VAULT_TAB_SIZE; i++) {
        const idx = this.tab * VAULT_TAB_SIZE + i;
        vaultGrid.appendChild(this.cell(vault.find((s) => s.slot_index === idx), 'vault', idx));
      }
    }
    this.el.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach((b) => b.addEventListener('click', () => { this.tab = Number(b.dataset.tab); this.render(); }));
    this.el.querySelectorAll<HTMLButtonElement>('[data-all]').forEach((b) => b.addEventListener('click', () => void this.depositAll(b.dataset.all as 'materials' | 'all')));
    this.el.querySelectorAll<HTMLButtonElement>('[data-take]').forEach((b) => b.addEventListener('click', () => void this.withdrawAll(b.dataset.take as 'materials' | 'all')));
    this.el.querySelector('[data-sort]')?.addEventListener('click', () => void this.sort());
  }

  /** Run a server move with no bag save in flight, adopt the reply's bag, and show its vault. */
  private async run(note: string, call: () => Promise<VaultState>) {
    // No state yet = the opening load is still in flight; a move now would overlap it and its stale reply would win.
    if (this.busy || !this.state) return;
    this.busy = true;
    this.error = '';
    this.note = '';
    this.render();
    try {
      this.state = await this.inventory.exclusive(async () => {
        const st = await call();
        this.inventory.replace(st.bag);
        return st;
      });
      this.note = note;
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The Vault refuses.';
    } finally {
      this.busy = false;
      this.render();
    }
  }

  private deposit(slot: InventorySlot) {
    if (slot.equipped) {
      this.error = 'Equipped gear cannot be stored. Unequip it first.';
      this.render();
      return Promise.resolve();
    }
    return this.run(`Stored ${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}.`, () => vaultDeposit(this.characterId, slot.slot_index));
  }

  private withdraw(slot: InventorySlot) {
    return this.run(`Took ${slot.name}${slot.quantity > 1 ? ` ×${slot.quantity}` : ''}.`, () => vaultWithdraw(this.characterId, slot.slot_index));
  }

  private depositAll(kind: 'materials' | 'all') {
    return this.run(kind === 'materials' ? 'Materials stored.' : 'Everything unlocked is stored.', () => vaultDepositAll(this.characterId, kind, this.locks.slotsOf(this.bagSlots())));
  }

  /** Take every vault stack of `kind` on the open tab into the bag, one server move each. Stops at the first stack that will not fit and keeps what already moved. */
  private async withdrawAll(kind: 'materials' | 'all') {
    if (!this.state) return;
    const label = kind === 'materials' ? 'Materials' : 'Everything';
    let stoppedBy = '';
    await this.run(`${label} taken.`, async () => {
      let st = this.state!;
      const lo = this.tab * VAULT_TAB_SIZE;
      const slots = st.vault.filter((s) => s.slot_index >= lo && s.slot_index < lo + VAULT_TAB_SIZE && (kind === 'all' || ['material', 'consumable', 'rune'].includes(s.item_type))).map((s) => s.slot_index);
      if (!slots.length) throw new Error(kind === 'materials' ? 'This tab holds no materials to take.' : 'This tab is empty.');
      for (const slot of slots) {
        try {
          st = await vaultWithdraw(this.characterId, slot);
          this.inventory.replace(st.bag);
        } catch (err) {
          if (st === this.state) throw err;
          stoppedBy = err instanceof Error ? err.message : 'The Vault refuses.';
          break;
        }
      }
      return st;
    });
    if (stoppedBy) {
      this.note = `Took what fit. ${stoppedBy}`;
      this.render();
    }
  }

  private sort() {
    return this.run('Vault sorted.', () => vaultSort(this.characterId));
  }

  dispose() {
    this.close();
  }
}
