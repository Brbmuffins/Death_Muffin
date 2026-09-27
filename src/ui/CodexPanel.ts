import { ABILITIES } from '../content/abilities';
import { AREAS, AREA_ORDER } from '../content/areas';
import {
  BEHAVIOUR_LABEL,
  CLASS_CHANGE_COUNSEL,
  CODEX_TRAVEL_COUNSEL,
  CODEX_PROFESSIONS_COUNSEL,
  CODEX_AREAS,
  CODEX_DEAD,
  CODEX_DISCIPLINES,
  CODEX_RITES,
  CODEX_SEALED,
  COVENANT_LORE,
  DEAD_ORDER,
  RITE_ORDER,
  areaUnlockText,
  riteSwatch,
} from '../content/codex';
import { PLAYABLE_DISCIPLINES, type DisciplineId } from '../content/disciplines';
import { ENEMIES } from '../content/enemies';
import type { CodexJournal } from '../gameplay/codexJournal';
import { GATHER_SKILLS, SKILLS, actionMs, nodesForSkill, xpPerHour } from '../gameplay/gatheringRules';
import { generateLayout } from '../content/layout';
import { itemMeta } from '../content/items';
import { ICON } from './icons';

const TABS = [
  { id: 'rites', label: 'Rites' },
  { id: 'disciplines', label: 'Disciplines' },
  { id: 'dead', label: 'The Dead' },
  { id: 'diocese', label: 'The Diocese' },
  { id: 'professions', label: 'Professions' },
  { id: 'lore', label: 'Covenant Lore' },
] as const;
type TabId = (typeof TABS)[number]['id'];

const secs = (ms: number) => `${+(ms / 1000).toFixed(2)}s`;

/**
 * The Codex (K): rites, disciplines, a bestiary and an atlas of the diocese,
 * plus Covenant lore. All text comes from content/codex.ts; enemy and area
 * entries stay sealed until the CodexJournal records them for this character.
 */
export class CodexPanel {
  private el: HTMLDivElement | null = null;
  private tab: TabId = 'rites';
  private offJournal: () => void;

  constructor(
    private root: HTMLElement,
    private journal: CodexJournal,
    private discipline: DisciplineId,
  ) {
    this.offJournal = journal.onChange(() => this.render());
  }

  get isOpen() {
    return this.el !== null;
  }

  open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float cw-codex';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Codex');
    this.el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Codex</h2>
        <button class="cw-icon-btn" data-close aria-label="Close codex">✕</button>
      </div>
      <div class="cw-tabs">${TABS.map((t) => `<button data-tab="${t.id}">${t.label}</button>`).join('')}</div>
      <div class="cw-codex-body" data-body></div>
    `;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach((b) =>
      b.addEventListener('click', () => {
        this.tab = b.dataset.tab as TabId;
        this.render();
        if (this.el) this.el.scrollTop = 0;
      }),
    );
    this.root.appendChild(this.el);
    this.render();
  }

  close() {
    this.el?.remove();
    this.el = null;
  }

  dispose() {
    this.close();
    this.offJournal();
  }

  private render() {
    if (!this.el) return;
    this.el.querySelectorAll<HTMLButtonElement>('[data-tab]').forEach((b) => {
      const on = b.dataset.tab === this.tab;
      b.classList.toggle('on', on);
      b.setAttribute('aria-pressed', String(on));
    });
    const body = this.el.querySelector<HTMLDivElement>('[data-body]')!;
    body.innerHTML =
      this.tab === 'rites'
        ? this.rites()
        : this.tab === 'disciplines'
          ? this.disciplines()
          : this.tab === 'dead'
            ? this.dead()
            : this.tab === 'diocese'
              ? this.diocese()
              : this.tab === 'professions'
                ? this.professions()
                : this.lore();
  }

  private rites() {
    return RITE_ORDER.map((id) => {
      const a = ABILITIES[id];
      const r = CODEX_RITES[id];
      const key = a.slot === 0 ? 'Left click' : a.slot === 5 ? 'Right click / Key 5' : a.slot === 6 ? 'Key R' : 'Grimoire · keys 1–4';
      const cost = a.essenceCost ? `${a.essenceCost} essence` : 'No cost';
      return `
        <article class="cw-codex-entry">
          <img class="ico" src="${a.icon}" alt="" draggable="false" />
          <div class="txt">
            <div class="hd"><h3>${a.name}</h3><span class="meta">${key} · ${cost} · ${secs(a.cooldownMs)}</span></div>
            <p>${a.description}</p>
            <p class="tip"><b>Use it well.</b> ${r.tip}</p>
            <div class="swatch" title="Colour identity">
              <span class="chips">${riteSwatch(id).map((c) => `<i style="background:${c}"></i>`).join('')}</span>
              <span>${r.colour}</span>
            </div>
          </div>
        </article>`;
    }).join('');
  }

  private disciplines() {
    return `<p class="tip">${CLASS_CHANGE_COUNSEL}</p>` + PLAYABLE_DISCIPLINES.map((d) => {
      const mine = d.id === this.discipline;
      return `
        <article class="cw-codex-entry disc${mine ? ' mine' : ''}" style="--disc-color:${d.color}">
          <img class="portrait" src="art/portraits/${d.id}.webp" alt="" draggable="false" />
          <div class="txt">
            <div class="hd"><h3>${d.name}</h3>${mine ? '<span class="meta">Your discipline</span>' : ''}</div>
            <div class="epithet">${d.epithet}</div>
            <p>${d.description}</p>
            <p class="passive"><b>${d.passive.name}.</b> ${d.passive.text}</p>
            <p class="tip">${CODEX_DISCIPLINES[d.id].tip}</p>
          </div>
        </article>`;
    }).join('');
  }

  private dead() {
    const known = DEAD_ORDER.filter((id) => this.journal.has('dead', id)).length;
    const rows = DEAD_ORDER.map((id) => {
      if (!this.journal.has('dead', id)) return this.sealed(CODEX_SEALED.dead);
      const e = CODEX_DEAD[id];
      const blurb = id === 'prelate' ? '' : `<p class="quote">${ENEMIES[id].blurb}</p>`;
      return `
        <article class="cw-codex-entry">
          <div class="txt">
            <div class="hd"><h3>${e.name}</h3><span class="meta">${BEHAVIOUR_LABEL[e.role]}</span></div>
            ${blurb}
            <dl>
              <dt>Behaviour</dt><dd>${e.behaviour}</dd>
              <dt>Corpse</dt><dd>${e.corpse}</dd>
              <dt>Counter</dt><dd>${e.counter}</dd>
            </dl>
          </div>
        </article>`;
    }).join('');
    return `<div class="cw-codex-count">Recorded <b>${known}</b> of ${DEAD_ORDER.length}</div>${rows}`;
  }

  private diocese() {
    const known = AREA_ORDER.filter((id) => this.journal.has('area', id)).length;
    const rows = AREA_ORDER.map((id) => {
      if (!this.journal.has('area', id)) return this.sealed(CODEX_SEALED.area);
      const a = AREAS[id];
      const seen = a.enemies.filter((e) => this.journal.has('dead', e.id)).map((e) => ENEMIES[e.id].name);
      const unseen = a.enemies.length - seen.length;
      const dead = a.enemies.length
        ? `<dt>The dead</dt><dd>${[...seen, ...(unseen ? [`${unseen} unrecorded`] : [])].join(', ')}</dd>`
        : '';
      return `
        <article class="cw-codex-entry">
          <div class="txt">
            <div class="hd"><h3>${a.name}</h3><span class="meta">Level ${a.level}</span></div>
            <p class="quote">${a.subtitle}</p>
            <dl>
              <dt>Unsealed</dt><dd>${areaUnlockText(id)}</dd>
              <dt>Dangers</dt><dd>${CODEX_AREAS[id].dangers}</dd>
              ${dead}
            </dl>
          </div>
        </article>`;
    }).join('');
    return `<p class="tip">${CODEX_TRAVEL_COUNSEL}</p><div class="cw-codex-count">Walked <b>${known}</b> of ${AREA_ORDER.length}</div>${rows}`;
  }

  /** Every gathering node, generated from gatheringRules + the layout so the numbers never drift. */
  private professions() {
    const nodes = generateLayout().nodes;
    const where = (type: string) => {
      const areas = [...new Set(nodes.filter((n) => n.type === type).map((n) => (n.rich ? `${AREAS[n.area].name} (rich)` : AREAS[n.area].name)))];
      return areas.join(', ');
    };
    const sections = GATHER_SKILLS.map((skill) => {
      const meta = SKILLS[skill];
      const rows = nodesForSkill(skill)
        .map(
          (n) => `<tr><td>${n.level}</td><td>${n.name}</td><td>${n.xp}</td><td>${(actionMs(n) / 1000).toFixed(1)}s</td><td>${itemMeta(n.item).name}</td><td>~${Math.round(xpPerHour(n, n.level) / 100) / 10}k</td><td>${where(n.id)}</td></tr>`,
        )
        .join('');
      return `
        <article class="cw-codex-entry" style="border-left:3px solid ${meta.color}">
          <div class="txt">
            <div class="hd"><h3>${meta.name}</h3><span class="meta">${meta.rite}</span></div>
            <table class="cw-codex-table">
              <thead><tr><th>Lvl</th><th>Node</th><th>XP</th><th>Cycle</th><th>Yields</th><th>XP/h</th><th>Where</th></tr></thead>
              <tbody>${rows}</tbody>
            </table>
          </div>
        </article>`;
    }).join('');
    const stations = `
      <article class="cw-codex-entry">
        <div class="txt">
          <div class="hd"><h3>Stations</h3><span class="meta">Sexton's Acre, by the door</span></div>
          <dl>
            <dt>Bone Kiln</dt><dd>Smelting and forging (Mining recipes).</dd>
            <dt>Sawpit</dt><dd>Planks, staves and bows (Woodcutting recipes).</dd>
            <dt>Cooking Fire</dt><dd>Fillets, tinctures and flasks (Fishing recipes).</dd>
          </dl>
          <p>XP/h assumes steady work at the node's own level with the node always ready; your odds improve with every level above it.</p>
        </div>
      </article>`;
    return `<p class="tip">${CODEX_PROFESSIONS_COUNSEL}</p>${sections}${stations}`;
  }

  private lore() {
    return `
      <div class="cw-codex-lore">
        <h3>${COVENANT_LORE.title}</h3>
        ${COVENANT_LORE.paragraphs.map((p) => `<p>${p}</p>`).join('')}
      </div>`;
  }

  private sealed(text: string) {
    return `
      <article class="cw-codex-entry sealed">
        <span class="seal">${ICON.seal}</span>
        <div class="txt"><div class="hd"><h3>Sealed</h3></div><p>${text}</p></div>
      </article>`;
  }
}
