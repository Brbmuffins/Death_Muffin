import { craft, getInventory, getProfessions, getRecipes } from '../net/api';
import type { InventorySlot, Profession, Recipe } from '../net/types';
import type { Inventory } from '../gameplay/loot';

const PROFESSIONS = ['mining', 'fishing', 'woodcutting'] as const;
const LABEL: Record<string, string> = { mining: 'Smelting', fishing: 'Tinctures', woodcutting: 'Coffin-wood' };

/** The Sexton's Acre stations: each is the Workbench locked to one rite's recipes. */
export type Station = 'kiln' | 'sawpit' | 'fire';
const STATIONS: Record<Station, { title: string; tab: (typeof PROFESSIONS)[number]; blurb: string }> = {
  kiln: { title: 'Bone Kiln', tab: 'mining', blurb: 'Smelt ore into ingots and forge them into gear.' },
  sawpit: { title: 'Sawpit', tab: 'woodcutting', blurb: 'Saw logs into planks, staves and bows.' },
  fire: { title: 'Cooking Fire', tab: 'fishing', blurb: 'Render fish into fillets, tinctures and flasks.' },
};

/**
 * The Ossuary Workbench. Recipes come from GET /api/recipes per profession;
 * crafting is POST /api/craft and the server's error strings are shown
 * verbatim (they're player-readable by contract).
 */
export class ForgePanel {
  private el: HTMLDivElement | null = null;
  private recipes: Recipe[] = [];
  private professions: Profession[] = [];
  private tab: (typeof PROFESSIONS)[number] = 'mining';
  private busy = false;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private onCrafted: (inventory: InventorySlot[], professions: Profession[]) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  /** The Workbench (every rite), or one Acre station locked to its rite. */
  async open(station?: Station) {
    if (this.el) return;
    const st = station ? STATIONS[station] : null;
    if (st) this.tab = st.tab;
    const title = st?.title ?? 'Ossuary Workbench';
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', title);
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">${title}</h2>
        <button class="cw-icon-btn" data-close aria-label="Close ${title}">✕</button>
      </div>
      ${st ? `<p class="cw-hint-text">${st.blurb}</p>` : `<div class="cw-tabs">${PROFESSIONS.map((p) => `<button data-tab="${p}">${LABEL[p]}</button>`).join('')}</div>`}
      <div class="cw-recipes"><span class="cw-hint-text">Loading recipes…</span></div>
      <div class="cw-error" data-error></div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach((b) =>
      b.addEventListener('click', () => {
        this.tab = b.dataset.tab as typeof this.tab;
        void this.load();
      }),
    );
    this.root.appendChild(this.el);
    await this.load();
  }

  private async load() {
    this.setError('');
    this.el?.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach((b) => b.classList.toggle('on', b.dataset.tab === this.tab));
    try {
      [this.recipes, this.professions] = await Promise.all([getRecipes(this.tab), getProfessions(this.characterId)]);
      this.render();
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Could not load recipes');
    }
  }

  close() {
    this.el?.remove();
    this.el = null;
  }

  private skill(profession: string) {
    return this.professions.find((p) => p.profession_id === profession)?.skill_level ?? 0;
  }

  private render() {
    const list = this.el?.querySelector<HTMLDivElement>('.cw-recipes');
    if (!list) return;
    if (!this.recipes.length) {
      list.innerHTML = '<span class="cw-hint-text">No recipes known for this rite.</span>';
      return;
    }
    list.innerHTML = this.recipes
      .map((r) => {
        const skill = this.skill(r.profession_id);
        const skillOk = skill >= r.skill_level_required;
        const ings = r.ingredients
          .map((ing) => {
            const have = this.inventory.count(ing.item_id);
            return `<span class="ing ${have >= ing.quantity ? 'ok' : 'missing'}">${ing.quantity}× ${ing.name} <em>(${have})</em></span>`;
          })
          .join('');
        const craftable = skillOk && r.ingredients.every((i) => this.inventory.count(i.item_id) >= i.quantity);
        return `
          <div class="cw-recipe">
            <div class="info">
              <div class="row"><span class="name">${r.name}</span><span class="req ${skillOk ? 'ok' : 'missing'}">${r.profession_id} ${r.skill_level_required}</span></div>
              <div class="ings">${ings}</div>
            </div>
            <button class="cw-button small" data-craft="${r.id}" ${craftable && !this.busy ? '' : 'disabled'}>Craft</button>
          </div>`;
      })
      .join('');
    list.querySelectorAll<HTMLButtonElement>('[data-craft]').forEach((b) => b.addEventListener('click', () => void this.doCraft(b.dataset.craft!)));
  }

  private setError(msg: string) {
    const el = this.el?.querySelector<HTMLDivElement>('[data-error]');
    if (el) el.textContent = msg;
  }

  private async doCraft(recipeId: string) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    this.render();
    try {
      await this.inventory.flush();
      await craft(this.characterId, recipeId);
      // The live server answers with the crafted item and XP, not the bag, so re-read both:
      // keeping the pre-craft bag would let the next save write the spent ingredients back.
      const [inventory, professions] = await Promise.all([getInventory(this.characterId), getProfessions(this.characterId)]);
      this.professions = professions;
      this.onCrafted(inventory, professions);
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Craft failed');
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
