import type { Profession } from '../net/types';

// XP needed for next skill level = skill_level × 50 (server rule).
function xpToNext(p: Profession) {
  return p.skill_level * 50;
}

export class ProfessionsPanel {
  private el: HTMLDivElement | null = null;

  constructor(private root: HTMLElement) {}

  get isOpen() {
    return this.el !== null;
  }

  open(professions: Profession[]) {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-professions';
    this.el.innerHTML = `
      <div class="cw-bag-head">
        <span class="cw-bag-title">Professions</span>
        <button class="cw-icon-btn" data-close aria-label="Close professions">✕</button>
      </div>
      <div class="cw-prof-list">
        ${
          professions.length === 0
            ? '<span class="hint">No professions learned yet</span>'
            : professions
                .map((p) => {
                  const next = xpToNext(p);
                  const pct = Math.min(100, Math.round((p.skill_xp / next) * 100));
                  return `
                    <div class="cw-prof">
                      <div class="row">
                        <span class="name">${p.profession_id}</span>
                        <span class="lvl">Lv ${p.skill_level}</span>
                      </div>
                      <div class="bar"><div class="fill" style="width:${pct}%"></div></div>
                      <div class="xp">${p.skill_xp} / ${next} xp</div>
                    </div>
                  `;
                })
                .join('')
        }
      </div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.root.appendChild(this.el);
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
