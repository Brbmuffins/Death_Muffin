import { craft, getInventory, getProfessions, getRecipes } from '../net/api';
import type { InventorySlot, Profession, Recipe } from '../net/types';
import type { Inventory } from '../gameplay/loot';
import { browserStorage } from '../gameplay/codexJournal';
import { bonusAvailable, brewOfTheDay, claimBonus } from '../content/wing';
import { itemMeta } from '../content/items';

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
        const craftable = skillOk && r.ingredients.every((i) => this.inventory.count(i.item_id) >= i.quantity);
        return `
          <div class="cw-recipe">
            <div class="info">
              <div class="row"><span class="name">${r.name}${this.station === 'cauldron' && r.id === day.recipeId ? ' <em class="botd">brew of the day</em>' : ''}</span><span class="req ${skillOk ? 'ok' : 'missing'}">${r.profession_id} ${r.skill_level_required}</span></div>
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
      // No save may fly during the craft (it would write the spent ingredients back): see Inventory.exclusive.
      await this.inventory.exclusive(async () => {
        await craft(this.characterId, recipeId);
        // The live server answers with the crafted item and XP, not the bag, so re-read both.
        const [inventory, professions] = await Promise.all([getInventory(this.characterId), getProfessions(this.characterId)]);
        this.professions = professions;
        this.onCrafted(inventory, professions);
        // The Wing's daily bonus: the first brew of the day's pick made at the Great Cauldron yields one extra.
        if (this.station === 'cauldron' && recipeId === brewOfTheDay().recipeId && bonusAvailable(browserStorage(), this.characterId)) {
          const r = this.recipes.find((x) => x.id === recipeId);
          if (r && this.inventory.add({ item_id: r.result_item_id, quantity: 1 })) claimBonus(browserStorage(), this.characterId);
        }
      });
    } catch (err) {
      this.setError(err instanceof Error ? err.message : 'Craft failed');
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
