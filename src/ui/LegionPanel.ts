import { SimplePanel } from './MiscPanels';
import { itemIcon } from './InventoryPanel';
import { kitMove } from '../net/api';
import type { InventorySlot } from '../net/types';
import type { Inventory } from '../gameplay/loot';
import { RARITY_COLOR, RARITY_MARK } from '../content/items';
import { LEGION_UPGRADE } from '../content/upgrades';
import { KIT_IDS, KIT_LABEL, kitSlotIndex, reinforceBonus, type KitId } from '../gameplay/legionRules';
import { bonusLines, kitCandidates, kitPieces, legionOf, pieceLines } from '../gameplay/legionKit';
import './legion.css';

/** How many spare pieces the list shows before it says how many more wait in the bag. */
export const SPARES_SHOWN = 4;

const pct = (x: number) => `${+(x * 100).toFixed(1)}%`;
const ARROW = { up: '▲', down: '▼', same: '=' } as const;

/** Move pieces between the bag and the Legion kit on the server (one at a time, in order, with no bag save in flight). The reply becomes the bag. */
export async function moveKit(inventory: Inventory, characterId: number, moves: { slot_index: number; equipped: 0 | 1 }[]) {
  await inventory.exclusive(async () => {
    for (const m of moves) inventory.replace(await kitMove(characterId, m.slot_index, m.equipped));
  });
}

export interface LegionDeps {
  /** Reinforcement tiers bought, and the gold the next costs (null at the top) and the gold you hold. */
  tier: () => number;
  cost: () => number | null;
  gold: () => number;
  /** Spend the gold. True when it was bought (the scene plays the sound and rebuilds the thralls' mods). */
  reinforce: () => boolean;
  /** What one freshly raised thrall has right now, or null before the hero exists. */
  thrall: () => { hp: number; damage: number } | null;
  /** A piece went in or out of the kit (counsel hooks hang off it). */
  onMoved?: (gave: boolean) => void;
}

/**
 * The Legion (Y, or the button in the Reliquary): the two kit slots your thralls wear, what each piece gives them in plain words, your spare
 * weapons and armour ranked by how much better (green up arrow) or worse (red down arrow) than the kit piece they would replace, and the
 * Reinforce button, the gold sink. The numbers all come from gameplay/legionRules.ts through legionKit.ts, so the words follow the math.
 */
export class LegionPanel extends SimplePanel {
  private off: (() => void) | null = null;
  private busy = false;

  constructor(
    root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private deps: LegionDeps,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    this.mount('Legion', '<div class="cw-error" data-error role="alert"></div><div class="lg-body"></div>');
    this.el!.classList.add('lg-panel');
    this.off = this.inventory.onChange(() => this.render());
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    super.close();
  }

  /** Refresh in place (the kit, the bag or the gold changed while the panel is open). */
  render() {
    const body = this.el?.querySelector<HTMLDivElement>('.lg-body');
    if (!body) return;
    const slots = this.inventory.all;
    const worn = kitPieces(slots);
    const tier = this.deps.tier();
    const bonus = legionOf(slots, tier);
    const lines = bonusLines({ hp: bonus.hpMult - 1, damage: bonus.damageMult - 1, speed: bonus.speedMult - 1, ward: bonus.wardAdd });
    const t = this.deps.thrall();
    const spares = kitCandidates(slots);
    body.innerHTML = `
      <div class="lg-slots">${KIT_IDS.map((id) => this.slotCard(id, worn[id])).join('')}</div>
      <div class="lg-mid">
        <section class="lg-total" aria-label="What your legion has now">
          <h3>Your legion now</h3>
          ${lines.length ? `<ul>${lines.map((l) => `<li>${l}</li>`).join('')}</ul>` : '<p class="lg-dim">Spare gear becomes thrall damage, health and attack speed. Give the legion a piece.</p>'}
          ${t ? `<p class="lg-dim">A thrall raised now: <b>${Math.round(t.hp)}</b> health, hits for <b>${t.damage.toFixed(1)}</b>. Reinforcing also strengthens the thralls already standing, once; swapping a kit piece reaches the next ones you raise.</p>` : ''}
        </section>
        ${this.reinforceBlock(tier)}
      </div>
      <section class="lg-spares" aria-label="Spare gear">
        <h3>Spare gear in your bag</h3>
        ${spares.length ? spares.slice(0, SPARES_SHOWN).map((c) => this.spareRow(c)).join('') : '<p class="lg-dim">No spare weapons or armour. Anything the Bone Grinder would eat can arm your legion instead.</p>'}
        ${spares.length > SPARES_SHOWN ? `<p class="lg-dim">${spares.length - SPARES_SHOWN} more in your bag, ranked lower.</p>` : ''}
      </section>`;
    body.querySelectorAll<HTMLButtonElement>('[data-take]').forEach((b) => b.addEventListener('click', () => void this.move(kitSlotIndex(b.dataset.take as KitId), 0)));
    body.querySelectorAll<HTMLButtonElement>('[data-give]').forEach((b) => b.addEventListener('click', () => void this.move(Number(b.dataset.give), 1)));
    body.querySelector('[data-reinforce]')?.addEventListener('click', () => {
      this.setError('');
      if (this.deps.reinforce()) this.render();
      else this.setError('Not enough gold.');
    });
    body.querySelectorAll<HTMLImageElement>('img.lg-img').forEach((img) => {
      img.onerror = () => img.replaceWith(Object.assign(document.createElement('span'), { className: 'lg-glyph', textContent: '◆' }));
    });
  }

  private slotCard(id: KitId, slot: InventorySlot | undefined) {
    if (!slot) {
      const hint = id === 'weapon' ? 'a sword, staff, wand or off-hand' : 'a helm, chest, legs, boots or gloves';
      return `<div class="lg-slot empty" data-kit="${id}"><div class="lg-icon"><span class="lg-glyph dim">${id === 'weapon' ? '⚔' : '⛊'}</span></div>
        <div class="lg-info"><div class="lg-label">${KIT_LABEL[id]}</div><div class="lg-empty">Empty. Give it ${hint} from your bag.</div></div></div>`;
    }
    const { lines, unused } = pieceLines(id, slot);
    return `<div class="lg-slot" data-kit="${id}" style="--rarity:${RARITY_COLOR[slot.rarity] ?? RARITY_COLOR.common}">
      <div class="lg-icon"><img class="lg-img" src="${itemIcon(slot)}" alt="" /></div>
      <div class="lg-info"><div class="lg-label">${KIT_LABEL[id]}</div>
        <div class="lg-name" style="color:${RARITY_COLOR[slot.rarity]}">${RARITY_MARK[slot.rarity] ?? ''} ${slot.name}${slot.inst ? ` <small>ilvl ${slot.inst.ilvl}</small>` : ''}</div>
        <ul class="lg-gives">${lines.length ? lines.map((l) => `<li>${l}</li>`).join('') : '<li class="lg-dim">Gives your thralls nothing.</li>'}</ul>
        ${unused.length ? `<div class="lg-dim" title="These affixes help you, not your thralls">Not used by thralls: ${unused.join(', ')}</div>` : ''}
        <button class="cw-button small" data-take="${id}" aria-label="Take the ${KIT_LABEL[id]} off the legion">Take off</button></div></div>`;
  }

  private spareRow(c: ReturnType<typeof kitCandidates>[number]) {
    const s = c.slot;
    const where = c.kit === 'weapon' ? 'Weapon' : 'Armour';
    return `<div class="lg-row" style="--rarity:${RARITY_COLOR[s.rarity] ?? RARITY_COLOR.common}">
      <div class="lg-icon sm"><img class="lg-img" src="${itemIcon(s)}" alt="" /></div>
      <div class="lg-rowtext"><span class="lg-name" style="color:${RARITY_COLOR[s.rarity]}">${s.name}</span>
        <span class="lg-verdict ${c.verdict}" title="Against what the legion's ${where} slot holds now"><span class="ar" aria-hidden="true">${ARROW[c.verdict]}</span> ${c.verdict === 'same' ? 'no change' : c.text}</span></div>
      <button class="cw-button small" data-give="${s.slot_index}" aria-label="Give ${s.name} to the legion's ${where} slot">Give</button></div>`;
  }

  /** The gold sink: tier, what it gives, the price of the next tier, and the button. */
  private reinforceBlock(tier: number) {
    const cost = this.deps.cost();
    const have = this.deps.gold();
    const now = reinforceBonus(tier);
    const next = reinforceBonus(tier + 1);
    const max = LEGION_UPGRADE.maxTier;
    const bar = Array.from({ length: max }, (_, i) => `<i class="${i < tier ? 'on' : ''}"></i>`).join('');
    const afford = cost !== null && have >= cost;
    return `<section class="lg-reinforce" aria-label="Reinforce the legion">
      <h3>Reinforce <small>tier ${tier} / ${max}</small></h3>
      <div class="lg-pips" aria-hidden="true">${bar}</div>
      <p>${tier ? `Bound: <b>+${pct(now.hp)}</b> health and damage, <b>+${pct(now.speed)}</b> attack speed.` : 'Spend gold to bind the dead tighter.'}</p>
      ${cost === null ? '<p class="lg-dim">Fully reinforced. The bindings reset when you Ascend.</p>'
        : `<div class="lg-buy"><button class="cw-button small" data-reinforce ${afford ? '' : 'disabled'} title="${afford ? `Costs gold, rises with each tier (you hold ${have.toLocaleString()}g). Thralls already standing are strengthened at once` : `You need ${(cost - have).toLocaleString()} more gold`}">Reinforce · ${cost.toLocaleString()}g</button>
           <span class="lg-dim">Next: +${pct(next.hp)} health and damage, +${pct(next.speed)} attack speed</span></div>`}
    </section>`;
  }

  private setError(msg: string) {
    const el = this.el?.querySelector<HTMLDivElement>('[data-error]');
    if (el) el.textContent = msg;
  }

  private async move(slotIndex: number, equipped: 0 | 1) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    try {
      await moveKit(this.inventory, this.characterId, [{ slot_index: slotIndex, equipped }]);
      this.deps.onMoved?.(equipped === 1);
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'The legion would not take that.');
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
