import { salvageGear, type SalvageReply } from '../net/api';
import type { InventorySlot } from '../net/types';
import { RARITY_COLOR, RARITY_MARK, itemMeta } from '../content/items';
import type { Inventory } from '../gameplay/loot';
import { LOCK_SVG, itemIcon } from './InventoryPanel';
import { salvageBelowRare, type ItemLocks } from '../gameplay/itemLocks';
import { SALVAGE_RARITIES, isSalvageable, salvagePreview } from '../gameplay/salvageRules';
import type { Skills } from '../gameplay/Gathering';
import { rollOf } from '../gameplay/affixes';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/** The one salvage call both the Bone Grinder panel and the Reliquary's Salvage button use. */
export async function runSalvage(inventory: Inventory, characterId: number, slots: number[]): Promise<SalvageReply> {
  // Unsaved pickups land first and no save flies while the server takes the gear and gives the yield (Inventory.exclusive).
  return inventory.exclusive(async () => {
    const reply = await salvageGear(characterId, slots);
    inventory.replace(reply.bag);
    return reply;
  });
}

/**
 * The Bone Grinder (Sexton's Acre): tick the gear you no longer want and grind it into ingots or planks plus alchemy reagents.
 * Locked items are shown but never selectable and never taken by "Salvage all below rare".
 */
export class SalvagePanel {
  private el: HTMLDivElement | null = null;
  private chosen = new Set<number>();
  private busy = false;
  private error = '';
  private result: SalvageReply | null = null;
  private off: (() => void) | null = null;
  private offLocks: (() => void) | null = null;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private locks: ItemLocks,
    private skills: Skills,
    /** After a successful salvage (toasts, XP, counsel). */
    private onSalvaged: (r: SalvageReply) => void,
    private onOpened?: () => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-salvage';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Bone Grinder');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.offLocks = this.locks.onChange(() => this.render());
    this.chosen.clear();
    this.result = null;
    this.render();
    this.onOpened?.();
  }

  close() {
    this.off?.();
    this.offLocks?.();
    this.off = this.offLocks = null;
    this.el?.remove();
    this.el = null;
  }

  private gear(): InventorySlot[] {
    const rank = (r: string) => SALVAGE_RARITIES.indexOf(r as (typeof SALVAGE_RARITIES)[number]);
    return this.inventory.all
      .filter((s) => !s.equipped && s.slot_index >= 0 && s.slot_index < 100 && isSalvageable(s.item_type))
      .sort((a, b) => rank(a.rarity) - rank(b.rarity) || a.slot_index - b.slot_index);
  }

  /** "2-3 Silver Ingot or Steel Ingot, Grave Dust 1-2, ..." for one piece. */
  private previewLine(slot: InventorySlot) {
    const p = salvagePreview({ id: slot.item_id, item_type: slot.item_type, rarity: slot.base_rarity ?? slot.rarity, ...rollOf(slot) });
    const mats = p.materials.map((id) => itemMeta(id).name).join(' or ');
    const qty = p.materialQty[0] === p.materialQty[1] ? `${p.materialQty[0]}` : `${p.materialQty[0]}-${p.materialQty[1]}`;
    // A rune is ground one at a time into reagents only.
    if (!p.materials.length) return `one rune${slot.quantity > 1 ? ` (of ${slot.quantity})` : ''} · ${p.reagents.map((r) => `${itemMeta(r.id).name}${r.qty[0] !== r.qty[1] ? ` ×${r.qty[0]}-${r.qty[1]}` : ''}${r.chance < 1 ? ` (${Math.round(r.chance * 100)}%)` : ''}`).join(', ')}`;
    const reagents = p.reagents.map((r) => `${itemMeta(r.id).name}${r.qty[0] !== r.qty[1] ? ` ×${r.qty[0]}-${r.qty[1]}` : ''}${r.chance < 1 ? ` (${Math.round(r.chance * 100)}%)` : ''}`).join(', ');
    return `${qty} ${mats}${p.extraChance > 0 ? ` (+1 ${Math.round(p.extraChance * 100)}%)` : ''} · ${reagents}`;
  }

  private render() {
    if (!this.el) return;
    const gear = this.gear();
    // Drop picks that are gone or have since been locked.
    for (const i of [...this.chosen]) {
      const s = gear.find((g) => g.slot_index === i);
      if (!s || this.locks.isLocked(s)) this.chosen.delete(i);
    }
    const level = this.skills.shown('salvaging');
    const picked = gear.filter((g) => this.chosen.has(g.slot_index));
    const below = salvageBelowRare(this.inventory.all, this.locks);
    const xp = picked.reduce((n, g) => n + salvagePreview({ id: g.item_id, item_type: g.item_type, rarity: g.base_rarity ?? g.rarity, ...rollOf(g) }).xp, 0);
    const r = this.result;
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Bone Grinder</h2>
        <span class="cw-skill-total">Salvaging <b>${level.level}</b> <small>${level.xp.toLocaleString()} / ${level.next.toLocaleString()} XP</small></span>
        <button class="cw-icon-btn" data-close aria-label="Close grinder">✕</button>
      </div>
      <p class="cw-codex-note">Feed it gear you will not wear. It gives back <b>ingots</b> (or <b>planks</b> from staffs, wands and grimoires) by rarity, plus <b>Grave Dust</b> and other alchemy reagents. Higher Salvaging adds a chance of an extra material (+0.5% a level); gear with a high item level or affixes adds more. A spare <b>Relic rune</b> is ground one at a time into reagents only.</p>
      <div class="cw-salvage-list" role="group" aria-label="Gear in your bag">${gear.length ? gear.map((g) => {
        const locked = this.locks.isLocked(g);
        const on = this.chosen.has(g.slot_index);
        return `<label class="cw-salv ${locked ? 'locked' : ''} ${on ? 'on' : ''}" style="--rarity:${RARITY_COLOR[g.rarity] ?? RARITY_COLOR.common}">
          <input type="checkbox" data-pick="${g.slot_index}" ${on ? 'checked' : ''} ${locked || this.busy ? 'disabled' : ''} aria-label="Salvage ${esc(g.name)}" />
          <img src="${itemIcon(g)}" alt="" onerror="this.style.visibility='hidden'" />
          <span class="nm"><b style="color:${RARITY_COLOR[g.rarity] ?? RARITY_COLOR.common}">${esc(g.name)}</b> <small>${RARITY_MARK[g.rarity] ?? ''} ${g.rarity}${g.inst ? ` · ilvl ${g.inst.ilvl}` : ''}</small>${locked ? `<span class="lk" title="Locked">${LOCK_SVG}</span>` : ''}</span>
          <span class="yl">${esc(this.previewLine(g))}</span>
        </label>`;
      }).join('') : '<p class="cw-hint-text">You carry no gear to salvage. Worn gear never appears here.</p>'}</div>
      <div class="cw-salvage-foot">
        <span class="cw-hint-text">${picked.length ? `${picked.length} chosen · about <b>${xp}</b> Salvaging XP` : 'Tick the gear to grind. Locked items cannot be chosen.'}</span>
        <button class="cw-button small" data-go ${picked.length && !this.busy ? '' : 'disabled'}>Salvage selected</button>
        <button class="cw-button small" data-below ${below.length && !this.busy ? '' : 'disabled'} title="Every unlocked common and uncommon piece in your bag">Salvage all below rare${below.length ? ` (${below.length})` : ''}</button>
      </div>
      ${r ? `<div class="cw-salvage-result" data-result><b>Ground ${r.salvaged.length} piece${r.salvaged.length === 1 ? '' : 's'}</b> for ${r.gained.map((g) => `${g.quantity}× ${esc(itemMeta(g.item_id).name)}`).join(', ')} · +${r.xp} Salvaging XP${r.leveledUp ? ` · <b>Salvaging level ${r.level}</b>` : ''}</div>` : ''}
      <div class="cw-error" data-error>${esc(this.error)}</div>`;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelectorAll<HTMLInputElement>('[data-pick]').forEach((box) => box.addEventListener('change', () => {
      const i = Number(box.dataset.pick);
      if (box.checked) this.chosen.add(i);
      else this.chosen.delete(i);
      this.render();
    }));
    this.el.querySelector('[data-go]')?.addEventListener('click', () => void this.go([...this.chosen]));
    this.el.querySelector('[data-below]')?.addEventListener('click', () => void this.go(below.map((s) => s.slot_index)));
  }

  private async go(slots: number[]) {
    if (this.busy || !slots.length) return;
    this.busy = true;
    this.error = '';
    this.render();
    try {
      const reply = await runSalvage(this.inventory, this.characterId, slots);
      this.result = reply;
      this.chosen.clear();
      this.onSalvaged(reply);
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The grinder jams.';
    } finally {
      this.busy = false;
      this.render();
    }
  }

  dispose() {
    this.close();
  }
}
