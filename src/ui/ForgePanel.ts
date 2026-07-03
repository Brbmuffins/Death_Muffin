import { craft, getProfessions, getRecipes } from '../net/api';
import type { InventorySlot, Profession, Recipe } from '../net/types';

/**
 * Forge — Mining recipes for now (the only seeded profession). Craft calls
 * POST /api/craft; the server validates skill and ingredients, and its error
 * strings are player-readable, shown verbatim.
 */
export class ForgePanel {
  private el: HTMLDivElement | null = null;
  private recipes: Recipe[] = [];
  private professions: Profession[] = [];
  private busy = false;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private getSlots: () => InventorySlot[],
    private onCrafted: (inventory: InventorySlot[], profession: Profession) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  async open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-forge';
    this.el.innerHTML = `
      <div class="cw-bag-head">
        <span class="cw-bag-title">Forge</span>
        <button class="cw-icon-btn" data-close aria-label="Close forge">✕</button>
      </div>
      <div class="cw-forge-list"><span class="hint">Loading recipes…</span></div>
      <div class="cw-error" data-error></div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.root.appendChild(this.el);

    try {
      [this.recipes, this.professions] = await Promise.all([
        getRecipes('mining'),
        getProfessions(this.characterId),
      ]);
      this.render();
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Could not load recipes');
    }
  }

  close() {
    this.el?.remove();
    this.el = null;
  }

  private skillLevel(profession: string): number {
    return this.professions.find((p) => p.profession_id === profession)?.skill_level ?? 0;
  }

  private have(itemId: string): number {
    return this.getSlots()
      .filter((s) => s.item_id === itemId)
      .reduce((sum, s) => sum + s.quantity, 0);
  }

  private render() {
    const list = this.el?.querySelector<HTMLDivElement>('.cw-forge-list');
    if (!list) return;
    list.innerHTML = this.recipes
      .map((r) => {
        const skill = this.skillLevel(r.profession_id);
        const skillOk = skill >= r.skill_level_required;
        const ingredients = r.ingredients
          .map((ing) => {
            const have = this.have(ing.item_id);
            const ok = have >= ing.quantity;
            return `<span class="ing ${ok ? 'ok' : 'missing'}">${ing.quantity}× ${ing.name} <em>(${have})</em></span>`;
          })
          .join('');
        const craftable = skillOk && r.ingredients.every((i) => this.have(i.item_id) >= i.quantity);
        return `
          <div class="cw-recipe">
            <div class="info">
              <div class="row">
                <span class="name">${r.name}</span>
                <span class="req ${skillOk ? 'ok' : 'missing'}">${r.profession_id} ${r.skill_level_required}</span>
              </div>
              <div class="ings">${ingredients}</div>
            </div>
            <button class="cw-button cw-craft-btn" data-craft="${r.id}" ${craftable && !this.busy ? '' : 'disabled'}>Craft</button>
          </div>
        `;
      })
      .join('');
    list.querySelectorAll<HTMLButtonElement>('[data-craft]').forEach((btn) => {
      btn.addEventListener('click', () => this.craft(btn.dataset.craft!));
    });
  }

  private setError(msg: string) {
    const el = this.el?.querySelector<HTMLDivElement>('[data-error]');
    if (el) el.textContent = msg;
  }

  private async craft(recipeId: string) {
    if (this.busy) return;
    this.busy = true;
    this.setError('');
    this.render();
    try {
      const { updatedInventory, updatedProfession } = await craft(this.characterId, recipeId);
      this.professions = this.professions.map((p) =>
        p.profession_id === updatedProfession.profession_id ? updatedProfession : p,
      );
      this.onCrafted(updatedInventory, updatedProfession);
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Craft failed');
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
