import type { Profession } from '../net/types';

const RITE: Record<string, { name: string; text: string }> = {
  mining: { name: 'Rite of Grave-Iron', text: 'Smelt coffin nails and crypt ore into relic metal.' },
  fishing: { name: 'Rite of the Black Water', text: 'Draw draughts from the drowned nave’s pools.' },
  woodcutting: { name: 'Rite of Coffin-Oak', text: 'Shape the old coffins into staves and planks.' },
};

// XP needed for next skill level = skill_level × 50 (server rule).
const xpToNext = (p: Profession) => p.skill_level * 50;

/** The Rite Niches: profession levels presented as funerary rites. */
export class ProfessionsPanel {
  private el: HTMLDivElement | null = null;

  constructor(private root: HTMLElement) {}

  get isOpen() {
    return this.el !== null;
  }

  open(professions: Profession[]) {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Rites');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Rite Niches</h2>
        <button class="cw-icon-btn" data-close aria-label="Close rites">✕</button>
      </div>
      ${
        professions.length === 0
          ? '<span class="cw-hint-text">No rites learned yet.</span>'
          : professions
              .map((p) => {
                const next = xpToNext(p);
                const pct = Math.min(100, Math.round((p.skill_xp / next) * 100));
                const rite = RITE[p.profession_id] ?? { name: p.profession_id, text: '' };
                return `
                  <div class="cw-prof">
                    <div class="row"><span class="name">${rite.name}</span><span class="lvl">Lv ${p.skill_level}</span></div>
                    <div class="rite">${rite.text}</div>
                    <div class="bar" role="meter" aria-valuenow="${p.skill_xp}" aria-valuemax="${next}"><div class="fill" style="width:${pct}%"></div></div>
                    <div class="xp">${p.skill_xp} / ${next} xp · ${p.profession_id}</div>
                  </div>`;
              })
              .join('')
      }
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.root.appendChild(this.el);
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
