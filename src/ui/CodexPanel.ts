import { ABILITIES } from '../content/abilities';
import { AREAS, AREA_ORDER } from '../content/areas';
import {
  BEHAVIOUR_LABEL,
  CLASS_CHANGE_COUNSEL,
  CODEX_TRAVEL_COUNSEL,
  CODEX_PROFESSIONS_COUNSEL,
  CODEX_BREWS_COUNSEL,
  CODEX_REAGENTS_COUNSEL,
  codexReagentRecipes,
  codexReagentRows,
  codexBrewRows,
  CODEX_AREAS,
  CODEX_DEAD,
  CODEX_DISCIPLINES,
  CODEX_RITES,
  CODEX_SEALED,
  CODEX_WEAPONS,
  CODEX_WEAPONS_COUNSEL,
  CODEX_WEAPON_TIERS,
  COVENANT_LORE,
  DEAD_ORDER,
  RITE_ORDER,
  areaUnlockText,
  riteSwatch,
} from '../content/codex';
import { PLAYABLE_DISCIPLINES, type DisciplineId } from '../content/disciplines';
import { ENEMIES, type EnemyId } from '../content/enemies';
import { BOSSES, type BossId } from '../content/bosses';
import type { CodexJournal } from '../gameplay/codexJournal';
import { GATHER_SKILLS, SKILLS, actionMs, nodesForSkill, xpPerHour } from '../gameplay/gatheringRules';
import { generateLayout } from '../content/layout';
import { itemMeta } from '../content/items';
import { ICON } from './icons';
import type { Chronicle } from '../gameplay/chronicle';

const TABS = [
  { id: 'rites', label: 'Rites' },
  { id: 'disciplines', label: 'Disciplines' },
  { id: 'weapons', label: 'Weapons' },
  { id: 'dead', label: 'The Dead' },
  { id: 'diocese', label: 'The Diocese' },
  { id: 'professions', label: 'Professions' },
  { id: 'lore', label: 'Covenant Lore' },
  { id: 'chronicle', label: 'Chronicle' },
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
    private chronicle?: Chronicle,
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
        // The Chronicle reads the server's record, so refresh it when the tab opens.
        if (this.tab === 'chronicle') void this.chronicle?.load().then(() => this.render());
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
          : this.tab === 'weapons'
            ? this.weapons()
          : this.tab === 'dead'
            ? this.dead()
            : this.tab === 'diocese'
              ? this.diocese()
              : this.tab === 'professions'
                ? this.professions()
                : this.tab === 'chronicle'
                  ? this.chronicleTab()
                  : this.lore();
  }

  /** Lifetime totals, this run, and every finished run: what Ascension can't erase. */
  private chronicleTab() {
    if (!this.chronicle) return '<p class="cw-codex-note">The Chronicle is not being kept.</p>';
    const c = this.chronicle.view();
    const n = (v = 0) => Math.floor(v).toLocaleString();
    const dur = (s = 0) => {
      const h = Math.floor(s / 3600);
      const m = Math.floor((s % 3600) / 60);
      return h ? `${h}h ${m}m` : `${m}m`;
    };
    const rows = (rs: [string, string][]) => rs.map(([l, v]) => `<div class="row"><span>${l}</span><b>${v}</b></div>`).join('');
    const life = c.life;
    const areas = AREA_ORDER.filter((a) => life[`kills.${a}`]).map((a): [string, string] => [AREAS[a].name, n(life[`kills.${a}`])]);
    const bosses = (Object.keys(BOSSES) as BossId[]).filter((b) => life[`boss.${b}`]).map((b): [string, string] => [BOSSES[b].name, n(life[`boss.${b}`])]);
    const skills = GATHER_SKILLS.map((s): [string, string] => [SKILLS[s].name, n(life[`gathered.${s}`])]);
    const group = (title: string, body: string) => `<div class="cw-chron-grp"><h4>${title}</h4>${body}</div>`;
    const runRow = (label: string, s: Record<string, number>, ended: string) =>
      `<tr><td>${label}</td><td>${n(s.kills)}</td><td>${n(s['boss.prelate'])}</td><td>${n(s.deaths)}</td><td>${n(s['gold.earned'])}</td><td>${dur(s.playSeconds)}</td><td>${ended}</td></tr>`;
    const past = c.runs.map((r) => runRow(`#${r.runNo}`, r.stats, new Date(r.endedAt).toLocaleDateString())).join('');
    return `
      <p class="cw-codex-note">Everything you do is written here. Lifetime totals never reset; each Ascension closes a run and opens the next. Counting began on the day the Chronicle was opened.</p>
      <div class="cw-chron">
        ${group('Combat', rows([['Foes slain', n(life.kills)], ...areas, ...bosses, ['Deaths', n(life.deaths)], ['Highest level', n(life['peak.level'])], ['Highest wave tier', n(life['peak.wave'])]]))}
        ${group('Economy', rows([['Gold earned', n(life['gold.earned'])], ['Gold spent', n(life['gold.spent'])], ['Items sold', n(life.sold)], ['Items crafted', n(life.crafted)]]))}
        ${group('Gathering', rows([...skills, ['AFK time', dur(life.afkSeconds)]]))}
        ${group('Time', rows([['Time played', dur(life.playSeconds)], ['Runs completed', n(c.runNo - 1)], ['This run', `#${c.runNo}`]]))}
      </div>
      <h3 class="cw-chron-h">Runs</h3>
      <table class="cw-codex-table cw-chron-runs">
        <thead><tr><th>Run</th><th>Kills</th><th>Prelate</th><th>Deaths</th><th>Gold</th><th>Time</th><th>Ended</th></tr></thead>
        <tbody>${runRow(`#${c.runNo} (now)`, c.run, '—')}${past}</tbody>
      </table>
      <p class="cw-codex-note"><a href="../leaderboard.html" target="_blank" rel="noopener">The public leaderboard</a> shows every player's time played and completed runs.</p>`;
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

  private weapons() {
    const ladder = CODEX_WEAPON_TIERS.map((t) => `<tr><td>${t.label}</td><td>${t.level}+</td><td>${t.areas.map((a) => AREAS[a].name).join(', ')}</td></tr>`).join('');
    return `<p class="tip">${CODEX_WEAPONS_COUNSEL}</p>` + CODEX_WEAPONS.map((w) => `
        <article class="cw-codex-entry">
          <img class="ico" src="art/items/${w.kind}_gold.svg" alt="" draggable="false" />
          <div class="txt">
            <div class="hd"><h3>${w.name}</h3><span class="meta">${w.hands} · ${w.suits}</span></div>
            <p>${w.change}</p>
            <p class="tip"><b>Use it well.</b> ${w.tip}</p>
          </div>
        </article>`).join('') + `<table class="cw-codex-table"><thead><tr><th>Tier</th><th>Recommended level</th><th>Drops in</th></tr></thead><tbody>${ladder}</tbody></table>`;
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
      const boss = id in BOSSES ? BOSSES[id as BossId] : null;
      const blurb = boss ? (boss.portrait && id !== 'prelate' ? `<img class="cw-boss-portrait" src="${boss.portrait}" alt="" width="96" height="96" />` : '') : `<p class="quote">${ENEMIES[id as EnemyId].blurb}</p>`;
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
            <dt>Bone Kiln</dt><dd>Smelting, gathering tools (Mining recipes) and Bonework: bones ground into bone meal (Gravedigging).</dd>
            <dt>Sawpit</dt><dd>A plank for every log, plus staves and bows (Woodcutting recipes).</dd>
            <dt>Cooking Fire</dt><dd>A meal for every fish (heals over time), fillets, tinctures and flasks (Fishing recipes).</dd>
            <dt>Tools</dt><dd>A hatchet, pickaxe, rod or spade in your bag adds +5% success per metal tier to its skill (copper to moon; the best you carry counts).</dd>
          </dl>
          <p>XP/h assumes steady work at the node's own level with the node always ready; your odds improve with every level above it.</p>
        </div>
      </article>`;
    const brews = `
      <article class="cw-codex-entry">
        <div class="txt">
          <div class="hd"><h3>Elixirs &amp; Tonics</h3><span class="meta">Z elixir · X tonic</span></div>
          <p>${CODEX_BREWS_COUNSEL}</p>
          <dl>${codexBrewRows().map((r) => `<dt>${r.name}</dt><dd>${r.slot} · ${r.effects} · ${r.seconds}s</dd>`).join('')}</dl>
        </div>
      </article>`;
    const reagents = `
      <article class="cw-codex-entry">
        <div class="txt">
          <div class="hd"><h3>Reagents</h3><span class="meta">Workbench · Alchemy tab</span></div>
          <p>${CODEX_REAGENTS_COUNSEL}</p>
          <dl>${codexReagentRows().map((r) => `<dt>${r.name}</dt><dd>${r.from}${r.usedIn ? `. Brews: ${r.usedIn}.` : ''}</dd>`).join('')}</dl>
          <table class="cw-codex-table">
            <thead><tr><th>Alch</th><th>Brew</th><th>Makes</th><th>Needs</th><th>Effect</th></tr></thead>
            <tbody>${codexReagentRecipes().map((r) => `<tr><td>${r.level}</td><td>${r.name}</td><td>${r.qty}</td><td>${r.ings}</td><td>${r.slot} · ${r.effects} · ${r.seconds}s</td></tr>`).join('')}</tbody>
          </table>
        </div>
      </article>`;
    return `<p class="tip">${CODEX_PROFESSIONS_COUNSEL}</p>${sections}${stations}${brews}${reagents}`;
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
