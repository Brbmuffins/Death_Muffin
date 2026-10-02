import { getGarden, getInventory, harvestGarden, plantGarden, type GardenResult, type GardenView } from '../net/api';
import { RARITY_COLOR, itemMeta } from '../content/items';
import { COMPOST_ITEM, seedDef } from '../content/gardening';
import { remainingText } from '../gameplay/gardeningRules';
import type { Inventory } from '../gameplay/loot';
import { preserveScroll } from './preserveScroll';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const iconOf = (itemId: string) => itemMeta(itemId).icon ?? `art/items/${itemId}.webp`;

/**
 * Grave Gardening (U): four Mourning Beds and two Coffin Patches. Plant a seed (bone meal makes it grow a quarter faster) and come
 * back: growth runs on the server's clock, so it continues while you are away. Planting and harvesting are server actions that move
 * items through the bag, so they run under Inventory.exclusive like a craft.
 */
export class GardenPanel {
  private el: HTMLDivElement | null = null;
  private view: GardenView | null = null;
  private skew = 0;
  private error = '';
  private busy = false;
  private tick = 0;
  private off: (() => void) | null = null;
  private choice = new Map<string, { seed: string; compost: boolean }>();

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private onResult: (kind: 'plant' | 'harvest', r: GardenResult) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  async open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-garden';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Grave Gardening');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.tick = window.setInterval(() => this.tickRender(), 1000);
    this.render();
    await this.refresh();
  }

  private async refresh() {
    try {
      this.set(await getGarden(this.characterId));
      this.error = '';
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'Could not reach the garden.';
    }
    this.render();
  }

  private set(v: GardenView) {
    this.view = v;
    this.skew = v.now - Date.now();
  }

  close() {
    this.off?.();
    this.off = null;
    window.clearInterval(this.tick);
    this.el?.remove();
    this.el = null;
  }

  /** Seeds in the bag that suit this plot kind at the player's level. */
  private seedsFor(kind: 'herb' | 'tree', level: number) {
    const out: { id: string; name: string; qty: number; level: number; ok: boolean }[] = [];
    for (const s of this.inventory.all) {
      const d = seedDef(s.item_id);
      if (!d || d.kind !== kind || s.equipped) continue;
      const have = out.find((o) => o.id === d.id);
      if (have) have.qty += s.quantity;
      else out.push({ id: d.id, name: itemMeta(d.id).name, qty: s.quantity, level: d.level, ok: level >= d.level });
    }
    return out.sort((a, b) => a.level - b.level);
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
    const v = this.view;
    const now = Date.now() + this.skew;
    const meal = this.inventory.count(COMPOST_ITEM);
    const cards = !v
      ? `<p class="cw-hint-text">${this.error ? esc(this.error) : 'Tending the beds…'}</p>`
      : v.plots
          .map((p) => {
            const seed = p.seedId ? seedDef(p.seedId) : undefined;
            const crop = seed ? itemMeta(seed.harvest) : undefined;
            const head = `<div class="hd"><b>${esc(p.label)}</b><span class="meta">${p.kind === 'tree' ? 'Tree patch' : 'Herb bed'}</span></div>`;
            if (p.state === 'empty') {
              const seeds = this.seedsFor(p.kind, v.level);
              const pick = this.choice.get(p.plot) ?? { seed: seeds.find((s) => s.ok)?.id ?? seeds[0]?.id ?? '', compost: false };
              if (!seeds.some((s) => s.id === pick.seed)) pick.seed = seeds.find((s) => s.ok)?.id ?? seeds[0]?.id ?? '';
              this.choice.set(p.plot, pick);
              const chosen = seeds.find((s) => s.id === pick.seed);
              const disabled = this.busy || !chosen || !chosen.ok;
              return `<article class="cw-plot empty" data-plot="${p.plot}">${head}
                ${seeds.length
                  ? `<div class="row"><select data-seed="${p.plot}" aria-label="Seed for ${esc(p.label)}">${seeds.map((s) => `<option value="${s.id}" ${s.id === pick.seed ? 'selected' : ''}>${esc(s.name)} ×${s.qty}${s.ok ? '' : ` (Lv ${s.level})`}</option>`).join('')}</select>
                     ${meal ? `<label class="cw-check"><input type="checkbox" data-compost="${p.plot}" ${pick.compost ? 'checked' : ''}/> Bone meal (${meal})</label>` : ''}
                     <button class="cw-button small" data-plant="${p.plot}" ${disabled ? 'disabled' : ''}>Plant</button></div>
                     ${chosen && !chosen.ok ? `<div class="rw">Requires Grave Gardening ${chosen.level}.</div>` : chosen ? `<div class="rw">Grows in ${remainingText(seedDef(chosen.id)!.growMin * 60_000 * (pick.compost ? 0.75 : 1))}.</div>` : ''}`
                  : `<div class="rw">${p.kind === 'tree' ? 'No saplings. Coffin-Oaks and Churchyard Yews sometimes drop them.' : 'No seeds. Dig graves in the Sexton’s Acre for Mourning Moss seeds.'}</div>`}
              </article>`;
            }
            const total = Math.max(1, p.readyAt - p.plantedAt);
            const left = Math.max(0, p.readyAt - now);
            const pct = p.state === 'ready' ? 100 : Math.min(100, Math.round(((total - left) / total) * 100));
            return `<article class="cw-plot ${p.state}" data-plot="${p.plot}" style="--rarity:${RARITY_COLOR[crop?.rarity ?? 'common']}">${head}
              <div class="row"><img src="${iconOf(seed!.harvest)}" alt="" onerror="this.style.visibility='hidden'" />
                <div class="grow"><div class="bar" aria-hidden="true"><i style="width:${pct}%"></i></div>
                <div class="rw">${esc(crop?.name ?? seed!.harvest)} · ${p.state === 'ready' ? '<b>Ready to harvest</b>' : `${remainingText(left)} left`}${p.composted ? ' · <i>bone meal</i>' : ''}</div></div>
                <button class="cw-button small" data-harvest="${p.plot}" ${p.state !== 'ready' || this.busy ? 'disabled' : ''}>Harvest</button></div>
            </article>`;
          })
          .join('');
    const level = v ? `<span class="cw-skill-total">Grave Gardening <b>${v.level}</b> · ${v.xp.toLocaleString()} / ${v.xpToNext.toLocaleString()} xp</span>` : '';
    const panel = this.el;
    preserveScroll(panel, () => { panel.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Grave Gardening</h2>
        ${level}
        <button class="cw-icon-btn" data-close aria-label="Close garden">✕</button>
      </div>
      <p class="cw-codex-note">Plant a seed and come back: it keeps growing while you are away. Bone meal from the Bone Kiln grows a plot a quarter faster.</p>
      <div class="cw-plots">${cards}</div>
      <div class="cw-error" data-error>${this.error && v ? esc(this.error) : ''}</div>`; });
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelectorAll<HTMLSelectElement>('[data-seed]').forEach((sel) => sel.addEventListener('change', () => {
      const cur = this.choice.get(sel.dataset.seed!)!;
      cur.seed = sel.value;
      this.render();
    }));
    this.el.querySelectorAll<HTMLInputElement>('[data-compost]').forEach((cb) => cb.addEventListener('change', () => {
      this.choice.get(cb.dataset.compost!)!.compost = cb.checked;
      this.render();
    }));
    this.el.querySelectorAll<HTMLButtonElement>('[data-plant]').forEach((b) => b.addEventListener('click', () => void this.act('plant', b.dataset.plant!)));
    this.el.querySelectorAll<HTMLButtonElement>('[data-harvest]').forEach((b) => b.addEventListener('click', () => void this.act('harvest', b.dataset.harvest!)));
  }

  private async act(kind: 'plant' | 'harvest', plot: string) {
    if (this.busy) return;
    this.busy = true;
    this.error = '';
    this.render();
    try {
      const pick = this.choice.get(plot);
      const result = await this.inventory.exclusive(async () => {
        const r = kind === 'plant' ? await plantGarden(this.characterId, plot, pick?.seed ?? '', !!pick?.compost) : await harvestGarden(this.characterId, plot);
        this.inventory.replace(await getInventory(this.characterId));
        return r;
      });
      this.set(result);
      this.onResult(kind, result);
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The garden refuses.';
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
