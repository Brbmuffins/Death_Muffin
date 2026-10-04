import { adoptPet, getCosmetics, getInventory, selectCosmetics, type CosmeticsResult, type CosmeticsView } from '../net/api';
import { RARITY_COLOR, itemMeta } from '../content/items';
import { SKILLS, type SkillId } from '../gameplay/gatheringRules';
import { petDef } from '../content/cosmetics';
import type { Inventory } from '../gameplay/loot';
import { wrapPanelBody } from './panelBody';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const hex = (n: number) => `#${n.toString(16).padStart(6, '0')}`;

/**
 * Capes & Pets (N): mastery capes you have earned (level 99 in a skill, or total level for the mantles), and the companions you have
 * adopted from charms found while working. Choices are saved on the server and shown to other players. Adopting spends a charm from
 * the bag, so it runs under Inventory.exclusive like a craft.
 */
export class CosmeticsPanel {
  private el: HTMLDivElement | null = null;
  private view: CosmeticsView | null = null;
  private error = '';
  private busy = false;
  private off: (() => void) | null = null;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    /** Called with the saved choice after any change so the scene can dress the hero. */
    private onChanged: (v: CosmeticsView) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  async open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-cosmetics';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Capes and pets');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.render();
    try {
      this.view = await getCosmetics(this.characterId);
      this.error = '';
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'Could not reach the Sexton.';
    }
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    this.el?.remove();
    this.el = null;
  }

  private render() {
    if (!this.el) return;
    const v = this.view;
    const capes = !v
      ? ''
      : v.capes
          .map((c) => {
            const worn = v.selected.cape === c.id;
            const pct = Math.min(100, Math.round((c.have / c.need) * 100));
            return `<article class="cw-cos ${c.unlocked ? 'open' : 'locked'} ${worn ? 'worn' : ''}">
              <i class="sw" style="background:${hex(c.color)};box-shadow:inset 0 -6px 0 ${hex(c.trim)}"></i>
              <div class="txt"><div class="hd"><b>${esc(c.name)}</b></div>
                <div class="rw">${esc(c.lore)}</div>
                ${c.unlocked ? '' : `<div class="bar" aria-hidden="true"><i style="width:${pct}%"></i></div><div class="rw">${c.have.toLocaleString()} / ${c.need.toLocaleString()}</div>`}</div>
              <button class="cw-button small" data-cape="${c.id}" ${!c.unlocked || this.busy ? 'disabled' : ''}>${worn ? 'Take off' : c.unlocked ? 'Wear' : 'Locked'}</button>
            </article>`;
          })
          .join('');
    const pets = !v
      ? ''
      : v.pets
          .map((p) => {
            const called = v.selected.pet === p.id;
            const def = petDef(p.id);
            const have = this.inventory.count(p.charm);
            const meta = itemMeta(p.charm);
            const skill = SKILLS[p.skill as SkillId]?.name ?? p.skill;
            let action: string;
            if (p.adopted) action = `<button class="cw-button small" data-pet="${p.id}" ${this.busy ? 'disabled' : ''}>${called ? 'Send away' : 'Call'}</button>`;
            else if (have > 0) action = `<button class="cw-button small" data-adopt="${p.id}" ${this.busy ? 'disabled' : ''}>Adopt (charm ×${have})</button>`;
            else action = `<button class="cw-button small" disabled>Not found</button>`;
            return `<article class="cw-cos ${p.adopted ? 'open' : 'locked'} ${called ? 'worn' : ''}" style="--rarity:${RARITY_COLOR[def?.rarity ?? 'rare']}">
              <i class="sw pet" aria-hidden="true">${p.adopted ? '✦' : '?'}</i>
              <div class="txt"><div class="hd"><b>${esc(p.name)}</b></div>
                <div class="rw">${esc(p.lore)}</div>
                ${p.adopted ? '' : `<div class="rw">A rare find while working ${esc(skill)}. ${esc(meta.name)}.</div>`}</div>
              ${action}
            </article>`;
          })
          .join('');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Capes &amp; Pets</h2>
        ${v ? `<span class="cw-skill-total">Total level <b>${v.totalLevel.toLocaleString()}</b></span>` : ''}
        <button class="cw-icon-btn" data-close aria-label="Close capes and pets">✕</button>
      </div>
      ${!v ? `<p class="cw-hint-text">${this.error ? esc(this.error) : 'The Sexton is opening the chest…'}</p>` : `
        <p class="cw-codex-note">Capes are earned: level 99 in a skill, or a total level for the mantles. Pets are rare finds while you work; adopt a charm and the companion is yours for good. Other players see what you wear.</p>
        <h3 class="cw-chron-h">Capes</h3><div class="cw-cos-list">${capes}</div>
        <h3 class="cw-chron-h">Companions</h3><div class="cw-cos-list">${pets}</div>`}
      <div class="cw-error" data-error>${this.error && v ? esc(this.error) : ''}</div>`;
    wrapPanelBody(this.el);
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelectorAll<HTMLButtonElement>('[data-cape]').forEach((b) => b.addEventListener('click', () => {
      const id = b.dataset.cape!;
      void this.act(() => selectCosmetics(this.characterId, { cape: v?.selected.cape === id ? null : id }));
    }));
    this.el.querySelectorAll<HTMLButtonElement>('[data-pet]').forEach((b) => b.addEventListener('click', () => {
      const id = b.dataset.pet!;
      void this.act(() => selectCosmetics(this.characterId, { pet: v?.selected.pet === id ? null : id }));
    }));
    this.el.querySelectorAll<HTMLButtonElement>('[data-adopt]').forEach((b) => b.addEventListener('click', () => {
      const id = b.dataset.adopt!;
      void this.act(async () => (await this.inventory.exclusiveAction(() => adoptPet(this.characterId, id), () => getInventory(this.characterId))).reply);
    }));
  }

  private async act(fn: () => Promise<CosmeticsResult>) {
    if (this.busy) return;
    this.busy = true;
    this.error = '';
    this.render();
    try {
      const r = await fn();
      this.view = r;
      this.onChanged(r);
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The Sexton refuses.';
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
