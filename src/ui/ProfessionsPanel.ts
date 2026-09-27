import type { Skills } from '../gameplay/Gathering';
import { ALL_SKILLS, LEVEL_CAP, SKILLS, nodesForSkill, type SkillId } from '../gameplay/gatheringRules';

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

  constructor(private root: HTMLElement) {}

  get isOpen() {
    return this.el !== null;
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
      return `
        <div class="cw-skill" style="--skill:${meta.color}">
          <div class="row"><span class="name">${meta.name}</span><span class="lvl">${s.level}<small>/${LEVEL_CAP}</small></span></div>
          <div class="rite">${meta.rite}</div>
          <div class="bar" role="meter" aria-label="${meta.name} XP" aria-valuenow="${s.xp}" aria-valuemax="${s.next}"><div class="fill" style="width:${pct}%"></div></div>
          <div class="xp">${capped ? 'Level cap' : `${s.xp.toLocaleString()} / ${s.next.toLocaleString()} XP · ${(s.next - s.xp).toLocaleString()} to go`}</div>
          <div class="next">${unlock}</div>
          <div class="blurb">${BLURB[id]}</div>
        </div>`;
    }).join('');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Skills</h2>
        <span class="cw-skill-total">Total level <b>${skills.total()}</b></span>
        <button class="cw-icon-btn" data-close aria-label="Close skills">✕</button>
      </div>
      <p class="cw-hint-text">Click a tree, seam, fishing spot or grave to work it. The Sexton’s Acre, west of the Chapterhouse, has every tier and no dead.</p>
      <div class="cw-skill-grid">${cards}</div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
