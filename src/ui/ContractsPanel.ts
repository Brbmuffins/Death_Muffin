import { deliverContract, getContracts, getInventory, type ContractBoard, type ContractDelivery } from '../net/api';
import { RARITY_COLOR, itemMeta } from '../content/items';
import { SKILLS, type SkillId } from '../gameplay/gatheringRules';
import type { Inventory } from '../gameplay/loot';

const iconOf = (itemId: string) => itemMeta(itemId).icon ?? `art/items/${itemId}.png`;
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/**
 * The Sexton's Contracts (O): three delivery orders a day, easy to hard, drawn from what your skills can make. Delivery is a
 * server action (it takes the items from the bag and pays); gold comes back to the scene, which owns the gold total.
 */
export class ContractsPanel {
  private el: HTMLDivElement | null = null;
  private board: ContractBoard | null = null;
  private error = '';
  private busy = false;
  private off: (() => void) | null = null;
  private tick = 0;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private onDelivered: (d: ContractDelivery) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  async open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-contracts';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Sexton’s Contracts');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.tick = window.setInterval(() => this.tickRender(), 30_000);
    this.render();
    try {
      this.board = await getContracts(this.characterId);
      this.error = '';
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'Could not reach the Sexton.';
    }
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    window.clearInterval(this.tick);
    this.el?.remove();
    this.el = null;
  }

  private resetText() {
    if (!this.board) return '';
    const ms = Math.max(0, Date.parse(this.board.resetsAt) - Date.now());
    const h = Math.floor(ms / 3_600_000);
    const m = Math.floor((ms % 3_600_000) / 60_000);
    return `${h}h ${m}m`;
  }

  /**
   * The countdown tick. Redrawing replaces the buttons, so a click that starts on one while a redraw lands is lost: skip the redraw
   * while the pointer is over a control or a dropdown is open, and catch up on the next tick.
   */
  private tickRender() {
    if (!this.el || this.el.querySelector('button:hover, select:hover, select:focus, input:hover, input:focus')) return;
    this.render();
  }

  private render() {
    if (!this.el) return;
    const b = this.board;
    const body = !b
      ? `<p class="cw-hint-text">${this.error ? esc(this.error) : 'The Sexton is checking his ledger…'}</p>`
      : `<p class="cw-codex-note">The Sexton wants goods from the grave, and pays for them. New orders every day (in <b>${this.resetText()}</b>). Fill all three for a bonus.</p>
        <div class="cw-ctr-list">${b.contracts.map((c) => {
          const have = this.inventory.count(c.itemId);
          const ready = have >= c.qty;
          const pct = Math.min(100, Math.round((have / c.qty) * 100));
          const skill = SKILLS[c.skill as SkillId]?.name ?? c.skill;
          const reward = `${c.rewardGold.toLocaleString()}g${c.rewardItem ? ` + ${c.rewardItem.qty > 1 ? `${c.rewardItem.qty}× ` : ''}${esc(c.rewardItem.name)}` : ''}`;
          return `<article class="cw-ctr ${c.done ? 'done' : ''}" style="--rarity:${RARITY_COLOR[c.rarity]}">
            <img src="${iconOf(c.itemId)}" alt="" onerror="this.style.visibility='hidden'" />
            <div class="txt">
              <div class="hd"><b>${['Easy', 'Steady', 'Hard'][c.slot] ?? 'Order'} · ${c.qty.toLocaleString()}× ${esc(c.name)}</b><span class="meta">${esc(skill)}</span></div>
              <div class="bar" aria-hidden="true"><i style="width:${c.done ? 100 : pct}%"></i></div>
              <div class="rw">${c.done ? 'Filled' : `${Math.min(have, c.qty).toLocaleString()} / ${c.qty.toLocaleString()} in your bag`} · Pays <b>${reward}</b></div>
            </div>
            <button class="cw-button small" data-deliver="${c.slot}" ${c.done || !ready || this.busy ? 'disabled' : ''}>${c.done ? '✓' : 'Deliver'}</button>
          </article>`;
        }).join('')}</div>
        <div class="cw-ctr-foot">
          <span>Bonus for all three: <b>${b.bonus.gold.toLocaleString()}g</b> + ${esc(b.bonus.item.name)} ${b.bonus.claimed ? '<i>(claimed today)</i>' : ''}</span>
          <span>Streak: <b>${b.streak}</b> day${b.streak === 1 ? '' : 's'}</span>
        </div>`;
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Sexton’s Contracts</h2>
        <button class="cw-icon-btn" data-close aria-label="Close contracts">✕</button>
      </div>
      ${body}
      <div class="cw-error" data-error>${this.error && b ? esc(this.error) : ''}</div>`;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelectorAll<HTMLButtonElement>('[data-deliver]').forEach((btn) => btn.addEventListener('click', () => void this.deliver(Number(btn.dataset.deliver))));
  }

  private async deliver(slot: number) {
    if (this.busy) return;
    this.busy = true;
    this.error = '';
    this.render();
    try {
      // Unsaved pickups land first and no save flies while the server takes items from the bag (Inventory.exclusive).
      const result = await this.inventory.exclusive(async () => {
        const res = await deliverContract(this.characterId, slot);
        this.inventory.replace(await getInventory(this.characterId));
        return res;
      });
      this.board = result;
      this.onDelivered(result);
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The Sexton refuses.';
    } finally {
      this.busy = false;
      this.render();
    }
  }

  dispose() {
    this.close();
  }
}
