import { craft, getInventory, getProfessions, getRecipes } from '../net/api';
import type { InventorySlot, Profession, Recipe } from '../net/types';
import type { Inventory } from '../gameplay/loot';
import { browserStorage } from '../gameplay/codexJournal';
import { bonusAvailable, brewOfTheDay, claimBonus } from '../content/wing';
import { itemMeta } from '../content/items';
import { BAG_SIZE } from '../gameplay/loot';
import { clampCraftQty, maxCraftable } from '../gameplay/craftQuantity';

/** Tabs: a profession's recipes; 'tools' is the smithing recipes for gathering tools (mining, `smith_*`). */
const PROFESSIONS = ['mining', 'tools', 'fishing', 'woodcutting', 'gravedigging', 'alchemy'] as const;
type Tab = (typeof PROFESSIONS)[number];
const LABEL: Record<Tab, string> = { mining: 'Smelting', tools: 'Tools', fishing: 'Cooking', woodcutting: 'Coffin-wood', gravedigging: 'Bonework', alchemy: 'Alchemy' };
const isTool = (id: string) => id.startsWith('smith_');

/** The Sexton's Acre stations: each is the Workbench locked to its rites' recipes. */
export type Station = 'kiln' | 'sawpit' | 'fire' | 'cauldron';
const STATIONS: Record<Station, { title: string; tabs: Tab[]; blurb: string }> = {
  kiln: { title: 'Bone Kiln', tabs: ['mining', 'tools', 'gravedigging'], blurb: 'Smelt ore into ingots, forge gathering tools, and grind bones into bone meal.' },
  sawpit: { title: 'Sawpit', tabs: ['woodcutting'], blurb: 'Saw logs into planks, staves and bows.' },
  cauldron: { title: 'The Great Cauldron', tabs: ['alchemy'], blurb: 'Brew herbs and reagents into flasks, tonics and elixirs. Today\'s pick brews one extra the first time you make it here.' },
  fire: { title: 'Cooking Fire', tabs: ['fishing'], blurb: 'Cook fish into meals, and render fillets into tinctures and flasks.' },
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
  private tab: Tab = 'mining';
  private busy = false;
  /** The quantity picked per recipe (session only). */
  private qty = new Map<string, number>();
  /** Progress / result line of the last batch. */
  private status = '';

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private onCrafted: (inventory: InventorySlot[], professions: Profession[]) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  /** The Acre station the panel is open on (null: the Workbench). */
  station: Station | null = null;

  /** The Workbench (every rite), or one Acre station locked to its rite. */
  async open(station?: Station) {
    if (this.el) return;
    this.station = station ?? null;
    const st = station ? STATIONS[station] : null;
    if (st && !st.tabs.includes(this.tab)) this.tab = st.tabs[0];
    const tabs = st?.tabs ?? PROFESSIONS;
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
      ${st ? `<p class="cw-hint-text">${st.blurb}</p>` : ''}
      ${tabs.length > 1 ? `<div class="cw-tabs">${tabs.map((p) => `<button data-tab="${p}">${LABEL[p]}</button>`).join('')}</div>` : ''}
      <p class="cw-hint-text" data-wing-hint></p>
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
      const prof = this.tab === 'tools' ? 'mining' : this.tab;
      const [recipes, professions] = await Promise.all([getRecipes(prof), getProfessions(this.characterId)]);
      this.recipes = recipes.filter((r) => (this.tab === 'tools') === isTool(r.id));
      this.professions = professions;
      this.render();
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Could not load recipes');
    }
  }

  close() {
    this.station = null;
    this.el?.remove();
    this.el = null;
  }

  private skill(profession: string) {
    // No row yet means level 1, exactly as the server's craft check treats it.
    return this.professions.find((p) => p.profession_id === profession)?.skill_level ?? 1;
  }

  private render() {
    const list = this.el?.querySelector<HTMLDivElement>('.cw-recipes');
    if (!list) return;
    const hint = this.el?.querySelector<HTMLElement>('[data-wing-hint]');
    const day = brewOfTheDay();
    if (hint) {
      if (this.station === 'cauldron') {
        const claimed = !bonusAvailable(browserStorage(), this.characterId);
        hint.innerHTML = `Brew of the day: <b>${itemMeta(day.brewId).name}</b> ${claimed ? '(bonus claimed today)' : '(one extra on your first brew today)'}`;
      } else hint.textContent = this.station === null && this.tab === 'alchemy' ? 'Brewing is easier in the Alchemist\'s Wing, east of the Chapterhouse: the Great Cauldron and the Reagent Shelf are there.' : '';
    }
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
        const max = skillOk ? this.maxFor(r) : 0;
        const n = this.effectiveQty(r, max);
        return `
          <div class="cw-recipe" data-recipe="${r.id}">
            <div class="info">
              <div class="row"><span class="name">${r.name}${this.station === 'cauldron' && r.id === day.recipeId ? ' <em class="botd">brew of the day</em>' : ''}</span><span class="req ${skillOk ? 'ok' : 'missing'}">${r.profession_id} ${r.skill_level_required}</span></div>
              <div class="ings">${ings}</div>
            </div>
            <div class="cw-craft-qty">
              <div class="cw-qty-step" role="group" aria-label="Quantity for ${r.name}">
                <button class="cw-button small" data-dec="${r.id}" aria-label="Fewer" ${max < 1 || this.busy ? 'disabled' : ''}>−</button>
                <input class="cw-qty-input" type="number" inputmode="numeric" min="1" max="${Math.max(1, max)}" value="${this.qty.get(r.id) ?? 1}" data-qty="${r.id}" aria-label="Quantity" ${max < 1 || this.busy ? 'disabled' : ''}>
                <button class="cw-button small" data-inc="${r.id}" aria-label="More" ${max < 1 || this.busy ? 'disabled' : ''}>+</button>
              </div>
              <button class="cw-button small" data-set="${r.id}:5" ${max < 1 || this.busy ? 'disabled' : ''}>×5</button>
              <button class="cw-button small" data-set="${r.id}:max" ${max < 1 || this.busy ? 'disabled' : ''}>Max${max > 0 ? ` (${max})` : ''}</button>
              <button class="cw-button small primary cw-craft-go" data-craft="${r.id}" ${max >= 1 && !this.busy ? '' : 'disabled'}>${this.busy && this.busyRecipe === r.id ? this.status : `Craft ×${n}`}</button>
            </div>
          </div>`;
      })
      .join('');
    const recipeOf = (id: string) => this.recipes.find((x) => x.id === id)!;
    const setQty = (id: string, v: number) => {
      this.qty.set(id, clampCraftQty(v, this.maxFor(recipeOf(id)) || 1));
      this.render();
    };
    list.querySelectorAll<HTMLButtonElement>('[data-craft]').forEach((b) => b.addEventListener('click', () => void this.doCraft(b.dataset.craft!)));
    list.querySelectorAll<HTMLButtonElement>('[data-dec]').forEach((b) => b.addEventListener('click', () => setQty(b.dataset.dec!, this.effectiveQty(recipeOf(b.dataset.dec!), this.maxFor(recipeOf(b.dataset.dec!))) - 1)));
    list.querySelectorAll<HTMLButtonElement>('[data-inc]').forEach((b) => b.addEventListener('click', () => setQty(b.dataset.inc!, this.effectiveQty(recipeOf(b.dataset.inc!), this.maxFor(recipeOf(b.dataset.inc!))) + 1)));
    list.querySelectorAll<HTMLButtonElement>('[data-set]').forEach((b) =>
      b.addEventListener('click', () => {
        const [id, v] = b.dataset.set!.split(':');
        setQty(id, v === 'max' ? this.maxFor(recipeOf(id)) : Number(v));
      }),
    );
    // Typing: keep focus (no re-render) and just refresh the craft button's label; clamp on commit.
    list.querySelectorAll<HTMLInputElement>('[data-qty]').forEach((inp) => {
      const id = inp.dataset.qty!;
      inp.addEventListener('input', () => {
        const r = recipeOf(id);
        this.qty.set(id, clampCraftQty(inp.value, this.maxFor(r) || 1));
        const go = list.querySelector<HTMLButtonElement>(`[data-craft="${id}"]`);
        if (go && !this.busy) go.textContent = `Craft ×${this.effectiveQty(r, this.maxFor(r))}`;
      });
      // No re-render here: a rebuild between pointer-down and pointer-up on Craft would swallow that tap.
      inp.addEventListener('change', () => {
        const r = recipeOf(id);
        const v = this.effectiveQty(r, this.maxFor(r));
        this.qty.set(id, v);
        inp.value = String(v);
        const go = list.querySelector<HTMLButtonElement>(`[data-craft="${id}"]`);
        if (go && !this.busy) go.textContent = `Craft ×${v}`;
      });
    });
  }

  private busyRecipe = '';

  /** Most this recipe can be made right now (materials and bag room). */
  private maxFor(r: Recipe): number {
    return maxCraftable(r, this.inventory.all, {
      bagSize: BAG_SIZE,
      stackOf: (id) => {
        const m = itemMeta(id);
        return m.type === 'material' ? (m.stack ?? Infinity) : 1;
      },
    });
  }

  /** The count a craft press will attempt: the picked quantity, never above what is makeable. */
  private effectiveQty(r: Recipe, max: number): number {
    return Math.max(1, Math.min(this.qty.get(r.id) ?? 1, max || 1));
  }

  private setError(msg: string) {
    const el = this.el?.querySelector<HTMLDivElement>('[data-error]');
    if (el) el.textContent = msg;
  }

  /**
   * Craft the picked quantity as a run of single server crafts (each one atomic: ingredients, space and XP in its own
   * transaction), stopping at the first error, which is shown verbatim. The bag is re-read once at the end.
   */
  private async doCraft(recipeId: string) {
    if (this.busy) return;
    const recipe = this.recipes.find((x) => x.id === recipeId);
    if (!recipe) return;
    const total = this.effectiveQty(recipe, this.maxFor(recipe));
    this.busy = true;
    this.busyRecipe = recipeId;
    this.status = total > 1 ? `Crafting 0/${total}…` : 'Crafting…';
    this.setError('');
    this.render();
    let made = 0;
    let failure = '';
    try {
      // No save may fly during the craft (it would write the spent ingredients back): see Inventory.exclusive.
      await this.inventory.exclusive(async () => {
        try {
          for (; made < total; made++) {
            await craft(this.characterId, recipeId);
            if (total > 1) {
              this.status = `Crafting ${made + 1}/${total}…`;
              const btn = this.el?.querySelector<HTMLButtonElement>(`[data-craft="${recipeId}"]`);
              if (btn) btn.textContent = this.status;
            }
          }
        } catch (err) {
          failure = err instanceof Error ? err.message : 'Craft failed';
        }
        if (made === 0 && !failure) return;
        // The live server answers with the crafted item and XP, not the bag, so re-read both.
        const [inventory, professions] = await Promise.all([getInventory(this.characterId), getProfessions(this.characterId)]);
        this.professions = professions;
        this.onCrafted(inventory, professions);
        // The Wing's daily bonus: the first brew of the day's pick made at the Great Cauldron yields one extra.
        if (made > 0 && this.station === 'cauldron' && recipeId === brewOfTheDay().recipeId && bonusAvailable(browserStorage(), this.characterId)) {
          if (this.inventory.add({ item_id: recipe.result_item_id, quantity: 1 })) claimBonus(browserStorage(), this.characterId);
        }
      });
      if (failure) this.setError(total > 1 ? `Made ${made} of ${total}. ${failure}` : failure);
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Craft failed');
    } finally {
      this.busy = false;
      this.busyRecipe = '';
      this.render();
    }
  }
}
