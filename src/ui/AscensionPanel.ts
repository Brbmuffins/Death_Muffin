import { ASCENSION, BOONS, BOON_ORDER, ascensionLevels, boonCost, roman, type BoonId } from '../content/ascension';
import type { Progression } from '../gameplay/progression';
import { SimplePanel } from './MiscPanels';

/**
 * The Altar of Ascension: burn a finished run for Ashes and a higher rank,
 * and spend Ashes on permanent Covenant Boons. Opening it never resets
 * anything — Ascend asks twice and lists exactly what goes and what stays.
 */
export class AscensionPanel extends SimplePanel {
  private confirming = false;
  private off: (() => void) | null = null;

  constructor(
    root: HTMLElement,
    private progression: Progression,
    private onAscend: () => void,
    private onBuyBoon: (id: BoonId) => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    this.confirming = false;
    this.mount('Altar of Ascension', '<div class="cw-ascend" data-body></div>');
    this.el!.classList.add('wide');
    this.off = this.progression.onChange(() => this.render());
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    super.close();
  }

  private render() {
    const body = this.el?.querySelector<HTMLElement>('[data-body]');
    if (!body) return;
    const l = this.progression.local;
    const earned = this.progression.ashesOnAscend();
    const next = l.ascension + 1;
    const maxed = l.ascension >= ASCENSION.maxRank;
    const run = l.run;
    const boons = BOON_ORDER.map((id) => {
      const def = BOONS[id];
      const owned = l.boons[id] ?? 0;
      const problem = this.progression.boonProblem(id);
      const cost = boonCost(id, l.boons);
      const pips = Array.from({ length: def.maxRank }, (_, i) => `<i class="${i < owned ? 'on' : ''}"></i>`).join('');
      const label = cost === null ? 'Mastered' : problem && !problem.startsWith('Needs') ? problem : `${cost} Ashes`;
      return `
        <div class="boon${owned ? ' owned' : ''}">
          <div class="bn"><b>${def.name}</b><span class="pips">${pips}</span></div>
          <div class="bd">${def.blurb}</div>
          <button class="cw-button" data-boon="${id}" ${problem ? 'disabled' : ''}>${label}</button>
        </div>`;
    }).join('');
    const ascendBlock = maxed
      ? '<p class="note">You have reached the final Ascension.</p>'
      : this.confirming
        ? `
          <div class="confirm">
            <p><b>Burn this run?</b> You rise to <b>Ascension ${roman(next)}</b> and gain <b>${earned} Ashes</b>.</p>
            <ul>
              <li class="lose">Resets: Damage and Wave Speed tiers, soul shards, area kills, every opened seal.</li>
              <li class="keep">Keeps: level, experience, gold, relics and professions, your Ashes and Boons.</li>
              <li>The dead rise <b>${ascensionLevels(next)} levels older</b> everywhere, and pay more.</li>
            </ul>
            <div class="row"><button class="cw-button primary" data-confirm>Ascend</button><button class="cw-button" data-cancel>Not yet</button></div>
          </div>`
        : `
          <button class="cw-button primary" data-ascend ${earned ? '' : 'disabled'}>${earned ? `Ascend — ${earned} Ashes` : 'Slay the Prelate this run to Ascend'}</button>`;
    body.innerHTML = `
      <div class="head">
        <div><span class="k">Rank</span><b>${l.ascension ? `Ascension ${roman(l.ascension)}` : 'Unascended'}</b></div>
        <div><span class="k">Ashes</span><b data-ashes>${l.ashes}</b></div>
        <div><span class="k">World</span><b>${l.ascension ? `+${ascensionLevels(l.ascension)} levels` : 'as it was'}</b></div>
      </div>
      <h3>This run</h3>
      <div class="run">
        <span>Prelate slain <b>${run.prelateKills}</b></span>
        <span>Peak Wave Speed <b>${run.peakWaveTier}</b></span>
        <span>Dead laid to rest <b>${run.kills}</b></span>
      </div>
      ${ascendBlock}
      <h3>Covenant Boons</h3>
      <div class="boons">${boons}</div>`;
    body.querySelector('[data-ascend]')?.addEventListener('click', () => {
      this.confirming = true;
      this.render();
    });
    body.querySelector('[data-cancel]')?.addEventListener('click', () => {
      this.confirming = false;
      this.render();
    });
    body.querySelector('[data-confirm]')?.addEventListener('click', () => {
      this.confirming = false;
      this.onAscend();
    });
    body.querySelectorAll<HTMLButtonElement>('[data-boon]').forEach((b) => b.addEventListener('click', () => this.onBuyBoon(b.dataset.boon as BoonId)));
  }
}
