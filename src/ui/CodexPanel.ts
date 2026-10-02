import { ABILITIES } from '../content/abilities';
import { AREAS, AREA_ORDER } from '../content/areas';
import {
  BEHAVIOUR_LABEL,
  CLASS_CHANGE_COUNSEL,
  CODEX_TRAVEL_COUNSEL,
  CODEX_PROFESSIONS_COUNSEL,
  CODEX_BREWS_COUNSEL,
  CODEX_REAGENTS_COUNSEL,
  CODEX_SALVAGE_COUNSEL,
  CODEX_VAULT_COUNSEL,
  codexSalvageRows,
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
  CODEX_SETS_COUNSEL,
  CODEX_LEGENDARY_COUNSEL,
  codexSetRows,
  type CodexSetRow,
  CODEX_STATS,
  CODEX_STATS_COUNSEL,
  CODEX_AFFIX_COUNSEL,
  CODEX_LEGION_COUNSEL,
  codexLegionExamples,
  codexLegionTiers,
  codexAffixRows,
  codexRuneRows,
  CODEX_RUNES_COUNSEL,
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
import { CODEX_PEOPLE_COUNSEL, codexPeopleRows } from '../content/codex';
import type { NpcId } from '../content/npcs';
import { generateLayout } from '../content/layout';
import { itemMeta, RARITY_COLOR } from '../content/items';
import { ICON } from './icons';
import './runes.css';
import type { Chronicle } from '../gameplay/chronicle';

const TABS = [
  { id: 'rites', label: 'Rites' },
  { id: 'disciplines', label: 'Disciplines' },
  { id: 'weapons', label: 'Weapons' },
  { id: 'sets', label: 'Armor sets' },
  { id: 'affixes', label: 'Item affixes' },
  { id: 'runes', label: 'Relic Runes' },
  { id: 'stats', label: 'Stats' },
  { id: 'dead', label: 'The Dead' },
  { id: 'diocese', label: 'The Diocese' },
  { id: 'people', label: 'People' },
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

  /** Redraw after something outside the journal changed (a rune was found). */
  refresh() {
    this.render();
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
          : this.tab === 'sets'
            ? this.sets()
          : this.tab === 'affixes'
            ? this.affixes()
          : this.tab === 'runes'
            ? this.runes()
          : this.tab === 'stats'
            ? this.stats()
          : this.tab === 'dead'
            ? this.dead()
            : this.tab === 'diocese'
              ? this.diocese()
              : this.tab === 'people'
                ? this.people()
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
        ${group('Combat', rows([['Foes slain', n(life.kills)], ...areas, ...bosses, ['Deaths', n(life.deaths)], ...(life['peak.depth'] ? [['Deepest descent', `Depth ${n(life['peak.depth'])}`] as [string, string], ['Depths floors cleared', n(life['depths.floors'])] as [string, string], ['Depths chests opened', n(life['depths.chests'])] as [string, string]] : []), ['Highest level', n(life['peak.level'])], ['Highest wave tier', n(life['peak.wave'])]]))}
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
      const key = a.slot === 0 ? 'Left click' : a.slot === 6 ? 'Key R' : 'Grimoire · slots 1–5';
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

  private stats() {
    return `<p class="tip">${CODEX_STATS_COUNSEL}</p>` + CODEX_STATS.map((s) => `
        <article class="cw-codex-entry">
          <div class="txt">
            <div class="hd"><h3>${s.name}</h3><span class="meta">${s.stat}</span></div>
            <p>${s.effects}</p>
          </div>
        </article>`).join('');
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

  /** Runes you have not held yet show their name and where they drop, not what they do (the sealed-page rule of the bestiary). */
  runesFound: () => ReadonlySet<string> = () => new Set();

  private runes() {
    const found = this.runesFound();
    const rows = codexRuneRows().map((g) => `
      <article class="cw-codex-entry">
        <div class="txt">
          <div class="hd"><h3>${g.rite}</h3><span class="meta">${g.runes.filter((r) => found.has(r.id)).length} of ${g.runes.length} found</span></div>
          ${g.runes.map((r) => found.has(r.id)
            ? `<div class="cw-rune-opt on" style="grid-template-columns:44px 1fr;margin-top:8px"><img src="art/items/${r.id}.webp" alt="" style="width:44px;height:44px" /><span><span class="nm">${r.name}<i>${r.rarity}</i></span><span class="sh"><b>${r.short}.</b> ${r.lines.join(' ')}${r.cost ? ` <em style="font-style:normal;color:#e7b07a">${r.cost}</em>` : ''}</span><span class="sh" style="opacity:.7"><i style="font-style:italic">${r.lore}</i> Drops from ${r.sources}.</span></span></div>`
            : `<div class="cw-rune-opt sealed" style="grid-template-columns:44px 1fr;margin-top:8px"><img src="art/items/${r.id}.webp" alt="" style="width:44px;height:44px;filter:grayscale(1) brightness(0.55)" /><span><span class="nm">${r.name}<i>${r.rarity}</i></span><span class="sh">Not found yet. Drops from ${r.sources}.</span></span></div>`).join('')}
        </div>
      </article>`).join('');
    return `<p class="tip">${CODEX_RUNES_COUNSEL}</p>${rows}`;
  }

  private affixes() {
    const rows = codexAffixRows()
      .map((r) => `<tr class="${r.necro ? 'necro' : ''}"><td>${r.necro ? '\u2020 ' : ''}${r.word}</td><td>${r.low}</td><td>${r.high}</td></tr>`)
      .join('');
    const legion = `
      <article class="cw-codex-entry">
        <div class="txt">
          <div class="hd"><h3>The Legion kit</h3><span class="meta">Y · thrall gear</span></div>
          <p>${CODEX_LEGION_COUNSEL}</p>
          <table class="cw-codex-table"><thead><tr><th>Spare piece</th><th>Slot</th><th>Stat points</th><th>Gives your thralls</th></tr></thead><tbody>${codexLegionExamples().map((r) => `<tr><td>${r.item}</td><td>${r.slot}</td><td>${r.points}</td><td>${r.gives}</td></tr>`).join('')}</tbody></table>
          <table class="cw-codex-table"><thead><tr><th>Reinforce tier</th><th>Gold</th><th>Total</th><th>Legion bonus</th></tr></thead><tbody>${codexLegionTiers().map((r) => `<tr><td>${r.tier}</td><td>${r.cost.toLocaleString()}</td><td>${r.total.toLocaleString()}</td><td>${r.bonus}</td></tr>`).join('')}</tbody></table>
        </div>
      </article>`;
    return `<p class="tip">${CODEX_AFFIX_COUNSEL}</p><table class="cw-codex-table"><thead><tr><th>Name</th><th>Item level 10</th><th>Item level 40</th></tr></thead><tbody>${rows}</tbody></table>${legion}`;
  }

  private sets() {
    const entry = (r: CodexSetRow) => `
        <article class="cw-codex-entry${r.collection === 3 ? ' legendary' : ''}">
          <div class="txt">
            <div class="hd"><h3>${r.name}</h3><span class="meta">${r.wearer} \u00B7 ${r.collection === 3 ? 'Legendary' : r.collection === 1 ? 'First collection' : 'Ascended collection'}</span></div>
            <dl>${r.bonuses.map((b) => `<dt>${b.pieces} pieces</dt><dd>${b.name ? `<b>${b.name}.</b> ` : ''}${b.text}</dd>`).join('')}</dl>
            <p class="tip">${r.drops}</p>
          </div>
        </article>`;
    const rows = codexSetRows();
    return `<p class="tip">${CODEX_SETS_COUNSEL}</p>` + rows.filter((r) => r.collection !== 3).map(entry).join('') +
      `<h3 class="cw-codex-section" style="color:${RARITY_COLOR.legendary}">Legendary sets</h3><p class="tip">${CODEX_LEGENDARY_COUNSEL}</p>` + rows.filter((r) => r.collection === 3).map(entry).join('');
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
      // The Depths have no fixed level (the dead are yours plus the depth) and keep a personal best in the Chronicle.
      const best = a.instance ? `<dt>Your deepest</dt><dd>${this.chronicle?.view().life['peak.depth'] ? `Depth ${Math.floor(this.chronicle.view().life['peak.depth'])}` : 'You have not been down yet'}</dd>` : '';
      return `
        <article class="cw-codex-entry">
          <div class="txt">
            <div class="hd"><h3>${a.name}</h3><span class="meta">${a.instance ? 'Your level + depth' : `Level ${a.level}`}</span></div>
            <p class="quote">${a.subtitle}</p>
            <dl>
              <dt>${a.instance ? 'Reached' : 'Unsealed'}</dt><dd>${areaUnlockText(id)}</dd>
              <dt>Dangers</dt><dd>${CODEX_AREAS[id].dangers}</dd>
              ${best}
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
            <dt>Great Cauldron &amp; Alembic</dt><dd>The Alchemist's Wing, through the Chapterhouse's east door: every Alchemy brew, plus a daily bonus brew. The Reagent Shelf there lists every reagent you have found.</dd>
            <dt>Bone Grinder</dt><dd>Grinds spare gear into ingots, planks and reagents (Salvaging). See below.</dd>
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
          <div class="hd"><h3>Reagents</h3><span class="meta">Alchemist's Wing · Alchemy</span></div>
          <p>${CODEX_REAGENTS_COUNSEL}</p>
          <dl>${codexReagentRows().map((r) => `<dt>${r.name}</dt><dd>${r.from}${r.usedIn ? `. Brews: ${r.usedIn}.` : ''}</dd>`).join('')}</dl>
          <table class="cw-codex-table">
            <thead><tr><th>Alch</th><th>Brew</th><th>Makes</th><th>Needs</th><th>Effect</th></tr></thead>
            <tbody>${codexReagentRecipes().map((r) => `<tr><td>${r.level}</td><td>${r.name}</td><td>${r.qty}</td><td>${r.ings}</td><td>${r.slot} · ${r.effects} · ${r.seconds}s</td></tr>`).join('')}</tbody>
          </table>
        </div>
      </article>`;
    const salvage = `
      <article class="cw-codex-entry" style="border-left:3px solid ${SKILLS.salvaging.color}">
        <div class="txt">
          <div class="hd"><h3>Salvaging</h3><span class="meta">${SKILLS.salvaging.rite} · Bone Grinder</span></div>
          <p>${CODEX_SALVAGE_COUNSEL}</p>
          <table class="cw-codex-table">
            <thead><tr><th>Gear</th><th>Qty</th><th>Ingot (most gear)</th><th>Plank (staff, wand, grimoire)</th><th>Reagents</th><th>XP</th></tr></thead>
            <tbody>${codexSalvageRows().map((r) => `<tr><td>${r.rarity}</td><td>${r.qty}</td><td>${r.ingots}</td><td>${r.planks}</td><td>${r.reagents}</td><td>${r.xp}</td></tr>`).join('')}</tbody>
          </table>
        </div>
      </article>`;
    const vault = `
      <article class="cw-codex-entry">
        <div class="txt">
          <div class="hd"><h3>The Ossuary Vault</h3><span class="meta">V · Chapterhouse</span></div>
          <p>${CODEX_VAULT_COUNSEL}</p>
        </div>
      </article>`;
    return `<p class="tip">${CODEX_PROFESSIONS_COUNSEL}</p>${sections}${stations}${vault}${salvage}${brews}${reagents}`;
  }

  /** Who has been spoken to (set by the scene from the guidance memory). */
  metNpc: (id: NpcId) => boolean = () => false;

  /** People of the Covenant: where each stands and what to ask them. They are always listed; the mark shows whom you have met. */
  private people() {
    const rows = codexPeopleRows()
      .map(
        (p) => `
        <article class="cw-codex-entry">
          <div class="txt">
            <div class="hd"><h3>${p.name}</h3><span class="meta">${this.metNpc(p.id) ? 'Met' : 'Not yet met'} · ${p.where}</span></div>
            <p>${p.blurb}</p>
            <p><b>Ask about:</b> ${p.ask}</p>
          </div>
        </article>`,
      )
      .join('');
    return `<p class="cw-codex-note">${CODEX_PEOPLE_COUNSEL}</p>${rows}`;
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
