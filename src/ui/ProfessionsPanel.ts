import type { Skills } from '../gameplay/Gathering';
import { ALL_SKILLS, GATHER_SKILLS, LEVEL_CAP, SKILLS, TOOL_KIND, nodesForSkill, toolItemId, toolTierFor, type GatherSkill, type SkillId } from '../gameplay/gatheringRules';

/** Gardening and alchemy have no nodes to work: they live in the Garden panel and at the Workbench. */
const isGather = (id: SkillId): id is GatherSkill => (GATHER_SKILLS as SkillId[]).includes(id);
import { itemMeta } from '../content/items';
import { preserveScroll } from './preserveScroll';
import { controlUnderPointer } from './redrawGuard';

/** What each skill is for, and where its processing happens (roadmap §3). */
const BLURB: Record<SkillId, string> = {
  woodcutting: 'Chop trees in the Sexton’s Acre. The Sawpit turns logs into planks, staves and bows.',
  mining: 'Mine ore seams and geodes. The Bone Kiln smelts ore into ingots and gear.',
  fishing: 'Fish the drifting spots on black water. The Cooking Fire renders fish into fillets and flasks.',
  gravedigging: 'Dig pauper’s graves, mounds and tombs for bones, grave goods and a little gold.',
  gardening: 'Plant seeds and saplings in the Mourning Beds and Coffin Patches (Garden, U). They grow while you are away.',
  alchemy: 'Brew herbs and bone meal into flasks and elixirs in the Alchemist\'s Wing, through the Chapterhouse\'s east door.',
  salvaging: 'Break spare gear down at the Bone Grinder in the Sexton’s Acre for ingots, planks and reagents. Higher levels add a chance of an extra material.',
};

/**
 * The Skills panel (the Rite Niches, key P): a RuneScape-style grid with each
 * skill's level, XP bar, XP to next level, what the next level opens, and the
 * total level. Numbers come from gatheringRules, so they can't drift.
 */
export class ProfessionsPanel {
  private el: HTMLDivElement | null = null;
  private busy = false;
  private message = '';

  constructor(private root: HTMLElement, private afk?: {
    start(type: string): Promise<void>;
    pause(): void;
    status(): { active: boolean; text: string; allowed: boolean };
  }, private heldItems?: () => string[], private onContracts?: () => void, private onGarden?: () => void, private onLabor?: () => void, private onCosmetics?: () => void) {}

  /** Item ids on the tool belt (set by the scene), so the tool line can say where the active tool is. */
  beltItems: (() => string[]) | null = null;

  get isOpen() {
    return this.el !== null;
  }

  refreshStatus() {
    const status = this.afk?.status();
    const label = this.el?.querySelector<HTMLElement>('[data-afk-status]');
    if (!status || !label) return;
    label.textContent = (this.busy ? 'Starting…' : status.active ? `AFK · ${status.text}` : this.message || status.text) + (!status.allowed ? ' · Visit the Sexton’s Acre to start.' : '');
    const pause=this.el?.querySelector<HTMLButtonElement>('[data-pause-afk]');
    if(pause)pause.disabled=!status.active||this.busy;
  }

  /** Gathering tools (G6): the best one carried for this skill, or where to get one. */
  private toolLine(id: SkillId) {
    if (!TOOL_KIND[id] || !this.heldItems) return '';
    const tier = toolTierFor(id, this.heldItems());
    // Where the active tool is: the best of belt and bag counts; a tie reads as the belt.
    const where = tier ? (toolTierFor(id, this.beltItems?.() ?? []) === tier ? 'on belt' : 'in bag') : '';
    return tier
      ? `<div class="next" data-tool="${id}">Tool: ${itemMeta(toolItemId(id, tier)).name} · +${tier * 5}% success · ${where}</div>`
      : '<div class="next" data-tool="none">No tool: forge one at the Bone Kiln for +5% or more.</div>';
  }

  open(skills: Skills) {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-skills-panel';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Skills');
    this.root.appendChild(this.el);
    this.render(skills);
  }

  /**
   * The redraw the scene asks for when XP or a level changes (every AFK work cycle). It waits while the pointer is over a control, so
   * a press on Pause AFK / Start AFK is not lost to a redraw between press and release; the next change catches it up.
   */
  refresh(skills: Skills) {
    if (!this.el || controlUnderPointer(this.el)) return;
    this.render(skills);
  }

  render(skills: Skills) {
    if (!this.el) return;
    // Leave an open native node picker intact while the player chooses a tier.
    if (this.el.querySelector('select:focus')) return;
    const selections = new Map([...this.el.querySelectorAll<HTMLSelectElement>('[data-afk-node]')].map(el => [el.dataset.afkNode, el.value]));
    const focused = this.el.contains(document.activeElement) ? (document.activeElement as HTMLElement).getAttribute('aria-label') : null;
    const status = this.afk?.status();
    const cards = ALL_SKILLS.map((id) => {
      const meta = SKILLS[id];
      const s = skills.shown(id);
      const capped = s.level >= LEVEL_CAP;
      const pct = capped ? 100 : Math.min(100, Math.round((s.xp / s.next) * 100));
      const nextNode = !isGather(id) ? null : nodesForSkill(id).find((n) => n.level > s.level);
      const unlock = capped
        ? 'Mastered.'
        : nextNode
          ? `Level ${nextNode.level}: ${nextNode.name}`
          : id === 'gardening'
            ? 'Plant in the Garden (U).'
            : id === 'alchemy'
              ? 'Brew at the Great Cauldron in the Alchemist\'s Wing.'
              : id === 'salvaging'
                ? 'Grind gear at the Bone Grinder in the Acre.'
              : 'Every node is open to you.';
      const choices = !isGather(id) ? [] : nodesForSkill(id).filter(n => n.level <= skills.gateLevel(id));
      const selected = selections.get(id) ?? choices[0]?.id;
      const afk = this.afk && choices.length ? `<div class="cw-afk-controls">
        <select data-afk-node="${id}" aria-label="${meta.name} gathering node" ${this.busy ? 'disabled' : ''}>${choices.map(n => `<option value="${n.id}" ${n.id === selected ? 'selected' : ''}>${n.name} · level ${n.level}</option>`).join('')}</select>
        <button class="cw-button small" data-start-afk="${id}" aria-label="Start AFK ${meta.name}" ${this.busy || !status?.allowed ? 'disabled' : ''}>Start AFK</button>
      </div>` : '';
      return `
        <div class="cw-skill" style="--skill:${meta.color}">
          <div class="row"><span class="name">${meta.name}</span><span class="lvl">${s.level}<small>/${LEVEL_CAP}</small></span></div>
          <div class="rite">${meta.rite}</div>
          <div class="bar" role="meter" aria-label="${meta.name} XP" aria-valuenow="${s.xp}" aria-valuemax="${s.next}"><div class="fill" style="width:${pct}%"></div></div>
          <div class="xp">${capped ? 'Level cap' : `${s.xp.toLocaleString()} / ${s.next.toLocaleString()} XP · ${(s.next - s.xp).toLocaleString()} to go`}</div>
          <div class="next">${unlock}</div>
          ${this.toolLine(id)}
          <div class="blurb">${BLURB[id]}</div>
          ${afk}
        </div>`;
    }).join('');
    const panel = this.el;
    preserveScroll(panel, () => { panel.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Skills</h2>
        <span class="cw-skill-total">Total level <b>${skills.total()}</b></span>
        <button class="cw-icon-btn" data-close aria-label="Close skills">✕</button>
      </div>
      <div class="cw-panel-actions" aria-label="Professions and rewards">
        ${this.onCosmetics ? '<button class="cw-button small" data-cosmetics title="Capes and pets (N)">Capes</button>' : ''}
        ${this.onLabor ? '<button class="cw-button small" data-labor title="Grave Laborers (H)">Laborers</button>' : ''}
        ${this.onGarden ? '<button class="cw-button small" data-garden title="Grave Gardening (U)">Garden</button>' : ''}
        ${this.onContracts ? '<button class="cw-button small" data-contracts title="Daily delivery orders (O)">Contracts</button>' : ''}
      </div>
      <h3 class="cw-panel-section-title">AFK gathering</h3>
      <p class="cw-hint-text">Choose a node and Start AFK in the Sexton’s Acre. Keep the game open; your hero repeats, changes nodes and waits for respawns until the bag fills. Skills can stay open. Moving, casting or other panels pause work.</p>
      ${status ? `<div class="cw-afk-status"><span data-afk-status></span><button class="cw-button small" data-pause-afk ${!status.active || this.busy ? 'disabled' : ''}>Pause AFK</button></div>` : ''}
      <div class="cw-skill-grid">${cards}</div>
    `; });
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelector('[data-contracts]')?.addEventListener('click', () => this.onContracts?.());
    this.el.querySelector('[data-garden]')?.addEventListener('click', () => this.onGarden?.());
    this.el.querySelector('[data-labor]')?.addEventListener('click', () => this.onLabor?.());
    this.el.querySelector('[data-cosmetics]')?.addEventListener('click', () => this.onCosmetics?.());
    this.refreshStatus();
    this.el.querySelector('[data-pause-afk]')?.addEventListener('click', () => { this.afk?.pause(); this.message = 'AFK paused'; this.render(skills); });
    for (const button of this.el.querySelectorAll<HTMLButtonElement>('[data-start-afk]')) button.addEventListener('click', async () => {
      const type = this.el?.querySelector<HTMLSelectElement>(`[data-afk-node="${button.dataset.startAfk}"]`)?.value;
      if (!type || !this.afk || this.busy) return;
      this.busy = true;this.message = '';this.render(skills);
      try { await this.afk.start(type); }
      catch (error) { this.message = (error as Error).message; }
      finally { this.busy = false;this.render(skills); }
    });
    if (focused) [...this.el.querySelectorAll<HTMLElement>('[aria-label]')].find(el => el.getAttribute('aria-label') === focused)?.focus();
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
