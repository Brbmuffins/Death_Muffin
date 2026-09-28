import type { Skills } from '../gameplay/Gathering';
import { ALL_SKILLS, LEVEL_CAP, SKILLS, TOOL_KIND, nodesForSkill, toolItemId, toolTierFor, type SkillId } from '../gameplay/gatheringRules';
import { itemMeta } from '../content/items';

/** What each skill is for, and where its processing happens (roadmap §3). */
const BLURB: Record<SkillId, string> = {
  woodcutting: 'Chop trees in the Sexton’s Acre. The Sawpit turns logs into planks, staves and bows.',
  mining: 'Mine ore seams and geodes. The Bone Kiln smelts ore into ingots and gear.',
  fishing: 'Fish the drifting spots on black water. The Cooking Fire renders fish into fillets and flasks.',
  gravedigging: 'Dig pauper’s graves, mounds and tombs for bones, grave goods and a little gold.',
  gardening: 'Mourning beds and tree patches are still being dug in the Acre. Seeds you find will keep.',
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
  }, private heldItems?: () => string[]) {}

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
    return tier
      ? `<div class="next">Tool: ${itemMeta(toolItemId(id, tier)).name} · +${tier * 5}% success</div>`
      : '<div class="next">No tool: forge one at the Bone Kiln for +5% or more.</div>';
  }

  open(skills: Skills) {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Skills');
    this.root.appendChild(this.el);
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
      const nextNode = id === 'gardening' ? null : nodesForSkill(id).find((n) => n.level > s.level);
      const unlock = capped
        ? 'Mastered.'
        : nextNode
          ? `Level ${nextNode.level}: ${nextNode.name}`
          : id === 'gardening'
            ? 'Not open yet.'
            : 'Every node is open to you.';
      const choices = id === 'gardening' ? [] : nodesForSkill(id).filter(n => n.level <= skills.gateLevel(id));
      const selected = selections.get(id) ?? choices[0]?.id;
      const afk = this.afk && choices.length ? `<div class="cw-afk-controls">
        <select data-afk-node="${id}" aria-label="${meta.name} gathering node" ${this.busy ? 'disabled' : ''}>${choices.map(n => `<option value="${n.id}" ${n.id === selected ? 'selected' : ''}>${n.name} · level ${n.level}</option>`).join('')}</select>
        <button class="cw-btn" data-start-afk="${id}" aria-label="Start AFK ${meta.name}" ${this.busy || !status?.allowed ? 'disabled' : ''}>Start AFK</button>
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
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Skills</h2>
        <span class="cw-skill-total">Total level <b>${skills.total()}</b></span>
        <button class="cw-icon-btn" data-close aria-label="Close skills">✕</button>
      </div>
      <p class="cw-hint-text">Choose a node and Start AFK in the Sexton’s Acre. Keep the game open; your hero repeats, changes nodes and waits for respawns until the bag fills. Skills can stay open. Moving, casting or other panels pause work.</p>
      ${status ? `<div class="cw-afk-status"><span data-afk-status></span><button class="cw-btn" data-pause-afk ${!status.active || this.busy ? 'disabled' : ''}>Pause AFK</button></div>` : ''}
      <div class="cw-skill-grid">${cards}</div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
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
