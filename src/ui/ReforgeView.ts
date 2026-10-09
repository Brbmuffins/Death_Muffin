import { reforgeAffix, reforgeQuote, type ReforgeReply } from '../net/api';
import type { InventorySlot } from '../net/types';
import { RARITY_COLOR, RARITY_MARK } from '../../server/rules/content/items';
import type { Inventory } from '../gameplay/loot';
import { affixIsNecro, affixQuality, affixRange, affixText } from '../../server/rules/gameplay/affixRules';
import { reforgeCost, reforgeProblem } from '../../server/rules/gameplay/goldSinkRules';
import { itemIcon } from './InventoryPanel';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

export interface ReforgeHost {
  characterId: number;
  inventory: Inventory;
  /** The character's gold right now (the HUD's number). */
  gold: () => number;
  /** Runs a server-priced gold spend (Progression.spendOnServer): saves gold first, adopts the gold in the reply. */
  spend: (call: () => Promise<ReforgeReply>) => Promise<ReforgeReply>;
  /** After a successful reforge (sound, toast). */
  onDone: (r: ReforgeReply) => void;
}

/**
 * The Workbench's Reforge tab: pick a rolled piece (bag or worn), pick one of its affixes, see the price, confirm. Only that affix's
 * VALUE is drawn again (same affix, a new number in the range this item level allows); the price rises with every reforge of the piece.
 * The server prices and rolls (POST /api/reforge); this view only previews the price with the same rules.
 */
export class ReforgeView {
  private el: HTMLElement | null = null;
  private off: (() => void) | null = null;
  /** Reforges done per loot instance id (from POST /api/reforge/quote, then from every reply). */
  private counts = new Map<number, number>();
  private pickedInstance: number | null = null;
  private confirm: number | null = null;
  private busy = false;
  private error = '';
  private result = '';

  constructor(private host: ReforgeHost) {}

  get isMounted() {
    return this.el !== null;
  }

  async mount(el: HTMLElement) {
    this.el = el;
    this.off = this.host.inventory.onChange(() => this.render());
    this.error = '';
    this.confirm = null;
    this.render();
    try {
      const q = await reforgeQuote(this.host.characterId);
      this.counts = new Map(q.pieces.map((p) => [p.instance_id, p.rerolls]));
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The Workbench could not be reached.';
    }
    this.render();
  }

  unmount() {
    this.off?.();
    this.off = null;
    this.el = null;
  }

  private pieces(): InventorySlot[] {
    return this.host.inventory.all
      .filter((s) => s.inst && s.inst.affixes.length > 0 && s.slot_index >= 0 && s.slot_index < 200)
      // Worn pieces first, then by item level.
      .sort((a, b) => Number(b.slot_index >= 100) - Number(a.slot_index >= 100) || (b.inst!.ilvl - a.inst!.ilvl) || a.slot_index - b.slot_index);
  }

  private picked(list: InventorySlot[]): InventorySlot | null {
    return list.find((s) => s.inst!.id === this.pickedInstance) ?? null;
  }

  private costOf(s: InventorySlot) {
    return reforgeCost(s.inst!.ilvl, s.base_rarity ?? s.rarity, s.inst!.affixes.length, this.counts.get(s.inst!.id) ?? 0);
  }

  private render() {
    const el = this.el;
    if (!el) return;
    const list = this.pieces();
    const sel = this.picked(list);
    const gold = this.host.gold();
    el.innerHTML = `
      <p class="cw-hint-text">Pick a piece, then one of its affixes. <b>Reforge</b> draws that affix's number again (the affix itself stays) for gold. Each reforge of the same piece costs about 25% more. It can come out lower, and a roll already at the top of its range cannot be reforged.</p>
      <div class="cw-reforge">
        <div class="cw-reforge-list" role="listbox" aria-label="Gear with affixes">${list.length ? list.map((s) => {
          const on = sel === s;
          const n = this.counts.get(s.inst!.id) ?? 0;
          return `<button class="cw-reforge-pick ${on ? 'on' : ''}" role="option" aria-selected="${on}" data-pick="${s.inst!.id}" style="--rarity:${RARITY_COLOR[s.rarity] ?? RARITY_COLOR.common}">
            <img src="${itemIcon(s)}" alt="" onerror="this.style.visibility='hidden'" />
            <span class="nm"><b style="color:${RARITY_COLOR[s.rarity] ?? RARITY_COLOR.common}">${esc(s.name)}</b><small>${RARITY_MARK[s.rarity] ?? ''} ilvl ${s.inst!.ilvl}${s.slot_index >= 100 ? ' · worn' : ''}${n ? ` · reforged ${n}×` : ''}</small></span>
          </button>`;
        }).join('') : '<p class="cw-hint-text">You carry no gear with affixes. Rolled drops (magic, rare and better) have them; common pieces do not.</p>'}</div>
        <div class="cw-reforge-detail">${sel ? this.detail(sel, gold) : '<p class="cw-hint-text">Choose a piece on the left.</p>'}</div>
      </div>
      <div class="cw-reforge-gold">Your gold <b>${gold.toLocaleString()}</b></div>
      ${this.result ? `<div class="cw-salvage-result" data-result>${this.result}</div>` : ''}
      <div class="cw-error" data-error>${esc(this.error)}</div>`;
    el.querySelectorAll<HTMLButtonElement>('[data-pick]').forEach((b) => b.addEventListener('click', () => {
      this.pickedInstance = Number(b.dataset.pick);
      this.confirm = null;
      this.result = '';
      this.render();
    }));
    el.querySelectorAll<HTMLButtonElement>('[data-ask]').forEach((b) => b.addEventListener('click', () => {
      this.confirm = Number(b.dataset.ask);
      this.result = '';
      this.render();
    }));
    el.querySelector('[data-cancel]')?.addEventListener('click', () => {
      this.confirm = null;
      this.render();
    });
    el.querySelector('[data-go]')?.addEventListener('click', () => void this.go());
  }

  private detail(s: InventorySlot, gold: number): string {
    const inst = s.inst!;
    const cost = this.costOf(s);
    const afford = gold >= cost;
    const rows = inst.affixes.map((a, i) => {
      const range = affixRange(a.id, inst.ilvl);
      const why = reforgeProblem(inst, i);
      const q = Math.round(affixQuality(a, inst.ilvl) * 100);
      const asking = this.confirm === i;
      return `<div class="cw-reforge-affix ${asking ? 'on' : ''}">
        <span class="tx ${affixIsNecro(a) ? 'necro' : ''}">${esc(affixText(a))}</span>
        <span class="rg" title="Where this roll sits between the lowest and highest this item level allows">${range ? `range ${range[0]}–${range[1]} · ${q}%` : ''}</span>
        <button class="cw-button small" data-ask="${i}" ${why || this.busy ? 'disabled' : ''} title="${esc(why ?? `Re-roll this affix's value for ${cost.toLocaleString()} gold`)}">${why ? esc(why.startsWith('That roll') ? 'Maxed' : 'No') : `Reforge · ${cost.toLocaleString()}g`}</button>
      </div>`;
    }).join('');
    const ask = this.confirm !== null && inst.affixes[this.confirm]
      ? `<div class="cw-reforge-confirm" role="group" aria-label="Confirm reforge">
          <span>Re-roll <b>${esc(affixText(inst.affixes[this.confirm]))}</b> for <b class="${afford ? '' : 'missing'}">${cost.toLocaleString()} gold</b>${afford ? '' : ` (you have ${gold.toLocaleString()})`}?</span>
          <button class="cw-button small primary" data-go ${afford && !this.busy ? '' : 'disabled'}>${this.busy ? 'Reforging…' : 'Reforge'}</button>
          <button class="cw-button small" data-cancel ${this.busy ? 'disabled' : ''}>Cancel</button>
        </div>`
      : '';
    return `<h3 class="cw-reforge-name" style="color:${RARITY_COLOR[s.rarity] ?? RARITY_COLOR.common}">${esc(s.name)}</h3>${rows}${ask}`;
  }

  private async go() {
    const list = this.pieces();
    const s = this.picked(list);
    const idx = this.confirm;
    if (!s || idx === null || this.busy) return;
    const was = affixText(s.inst!.affixes[idx]);
    const cost = this.costOf(s);
    this.busy = true;
    this.error = '';
    this.render();
    try {
      const reply = await this.host.inventory.exclusive(async () => {
        const r = await this.host.spend(() => reforgeAffix(this.host.characterId, s.slot_index, idx, cost));
        this.host.inventory.replace(r.bag);
        return r;
      });
      this.counts.set(s.inst!.id, reply.rerolls);
      const better = reply.to > reply.from;
      this.result = `${esc(was)} became <b>${esc(affixText({ id: s.inst!.affixes[idx].id, v: reply.to }))}</b> <span class="${better ? 'ok' : reply.to < reply.from ? 'missing' : ''}">${better ? 'higher' : reply.to < reply.from ? 'lower' : 'the same'}</span> · ${reply.cost.toLocaleString()} gold`;
      this.confirm = null;
      this.host.onDone(reply);
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The reforge failed.';
      this.confirm = null;
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
