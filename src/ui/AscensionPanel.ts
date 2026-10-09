import { ASCENSION, BOONS, BOON_ORDER, VOWS, VOW_ORDER, ashesForRun, ascensionRewardMult, boonCost, boonKey, isUnlocked, roman, vowHeat, vowKey, vowSteps, worldVows, type BoonId, type VowId, type VowRanks } from '../../server/rules/content/ascension';
import type { Progression } from '../gameplay/progression';
import { SimplePanel } from './MiscPanels';

/**
 * The Altar of Ascension. Three jobs, top to bottom:
 *  1. Vows: choose the curses for the next run (heat total, Ashes preview). Nothing changes until "Swear these vows".
 *  2. Ascend: burn a finished run (the Prelate must have fallen) for Ashes. Asks twice and lists what goes and what stays.
 *  3. Covenant Boons: bought with Ashes; the stranger ones are unlocked with soul shards first.
 * Opening it never resets anything.
 */
export class AscensionPanel extends SimplePanel {
  private confirming = false;
  private off: (() => void) | null = null;
  /** The vows being chosen (not yet sworn). */
  private draft: VowRanks = {};
  private drafted = false;

  constructor(
    root: HTMLElement,
    private progression: Progression,
    private onAscend: () => void,
    private onBuyBoon: (id: BoonId) => void,
    private onSwear: (vows: VowRanks) => void,
    private onOpen: (key: string) => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    this.confirming = false;
    this.draft = { ...this.progression.vows };
    this.drafted = false;
    this.mount('Altar of Ascension', '<div class="cw-ascend" data-body></div>');
    this.el!.classList.add('wide', 'cw-altar');
    this.off = this.progression.onChange(() => this.render());
    this.render();
  }

  close() {
    this.off?.();
    this.off = null;
    super.close();
  }

  private same(a: VowRanks, b: VowRanks) {
    return VOW_ORDER.every((id) => vowSteps(a, id) === vowSteps(b, id));
  }

  private render() {
    const body = this.el?.querySelector<HTMLElement>('[data-body]');
    if (!body) return;
    const l = this.progression.local;
    const sworn = this.progression.vows;
    // After a swear (or a server sync) the draft follows what is sworn until the player edits again.
    if (!this.drafted) this.draft = { ...sworn };
    const draftHeat = vowHeat(this.draft);
    const swornHeat = vowHeat(sworn);
    const changed = !this.same(this.draft, sworn);
    const run = l.run;
    const ashesNow = ashesForRun(run, swornHeat);
    const mult = 1 + ASCENSION.ashesPerHeat * draftHeat;
    const worldHeat = vowHeat(worldVows(this.draft));
    const reward = Math.round((ascensionRewardMult(worldHeat) - 1) * 100);
    const restart = changed && this.progression.vowsRestartRun(this.draft);

    const vowCards = VOW_ORDER.map((id) => {
      const def = VOWS[id];
      const key = vowKey(id);
      const open = isUnlocked(l.unlocks, key);
      const n = vowSteps(this.draft, id);
      if (!open) {
        const can = l.shards >= def.unlockShards;
        return `
        <div class="vow locked">
          <div class="vn"><b>${def.name}</b><span class="heat">+${def.heat} heat${def.maxRank > 1 ? ' per step' : ''}</span></div>
          <div class="vd">${def.blurb}</div>
          <button class="cw-button" data-open="${key}" ${can ? '' : 'disabled'} title="${can ? 'Spend soul shards to open this' : `You have ${l.shards} soul shards`}">Unlock &middot; ${def.unlockShards} shards</button>
        </div>`;
      }
      const stepper = def.maxRank === 1
        ? `<button class="cw-button vtoggle${n ? ' primary' : ''}" data-vow="${id}" data-to="${n ? 0 : 1}">${n ? 'Sworn' : 'Swear'}</button>`
        : `<div class="step"><button class="cw-button" data-vow="${id}" data-to="${n - 1}" ${n <= 0 ? 'disabled' : ''} aria-label="Fewer steps of ${def.name}">&minus;</button><span><b>${n}</b> / ${def.maxRank}</span><button class="cw-button" data-vow="${id}" data-to="${n + 1}" ${n >= def.maxRank ? 'disabled' : ''} aria-label="More steps of ${def.name}">+</button></div>`;
      return `
        <div class="vow${n ? ' sworn' : ''}">
          <div class="vn"><b>${def.name}</b><span class="heat">${n ? `+${n * def.heat} heat` : `+${def.heat} heat${def.maxRank > 1 ? ' per step' : ''}`}</span></div>
          <div class="vd">${def.blurb}${def.scope === 'self' ? ' <i>(only you)</i>' : ''}</div>
          ${stepper}
        </div>`;
    }).join('');

    const swearBlock = `
      <div class="swear">
        <div class="sum"><span class="k">Heat</span><b data-heat>${draftHeat}</b><span class="k">Ashes</span><b>&times;${mult.toFixed(1)}</b><span class="k">Gold &amp; XP</span><b>+${reward}%</b></div>
        <div class="row">
          <button class="cw-button primary" data-swear ${changed ? '' : 'disabled'}>${changed ? 'Swear these vows' : swornHeat ? 'Vows sworn' : 'No vows sworn'}</button>
          <button class="cw-button" data-clear ${draftHeat ? '' : 'disabled'}>Clear all</button>
        </div>
        ${restart ? '<p class="note warn">This run already has kills on the tally. Changing vows restarts the run\'s tally (kills and any Prelate kill), so its Ashes match the heat it was fought at. Tiers, seals and shards stay.</p>' : ''}
      </div>`;

    const boons = BOON_ORDER.map((id) => {
      const def = BOONS[id];
      const owned = l.boons[id] ?? 0;
      const key = boonKey(id);
      const open = isUnlocked(l.unlocks, key);
      const pips = Array.from({ length: def.maxRank }, (_, i) => `<i class="${i < owned ? 'on' : ''}"></i>`).join('');
      if (!open) {
        const can = l.shards >= def.unlockShards;
        return `
        <div class="boon locked">
          <div class="bn"><b>${def.name}</b><span class="tag">changes how you play</span></div>
          <div class="bd">${def.blurb}</div>
          <button class="cw-button" data-open="${key}" ${can ? '' : 'disabled'} title="${can ? 'Spend soul shards to open this' : `You have ${l.shards} soul shards`}">Unlock &middot; ${def.unlockShards} shards</button>
        </div>`;
      }
      const problem = this.progression.boonProblem(id);
      const cost = boonCost(id, l.boons);
      const label = cost === null ? 'Mastered' : problem && !problem.startsWith('Needs') ? problem : `${cost} Ashes`;
      return `
        <div class="boon${owned ? ' owned' : ''}">
          <div class="bn"><b>${def.name}</b>${def.shape ? '<span class="tag">changes how you play</span>' : ''}<span class="pips">${pips}</span></div>
          <div class="bd">${def.blurb}</div>
          <button class="cw-button" data-boon="${id}" ${problem ? 'disabled' : ''}>${label}</button>
        </div>`;
    }).join('');

    const ascendBlock = this.confirming
      ? `
          <div class="confirm">
            <p><b>Burn this run?</b> You gain <b>${ashesNow} Ashes</b> for ${swornHeat} heat${swornHeat > l.ascension ? ` and a new best rank, <b>Ascension ${roman(swornHeat)}</b>` : ''}.</p>
            <ul>
              <li class="lose">Resets: Damage, Wave Speed and Legion tiers, and this run's tally.</li>
              <li class="keep">Keeps: opened seals and kill counts, soul shards, level, experience, gold, relics, your Ashes, Boons and sworn vows.</li>
            </ul>
            <div class="row"><button class="cw-button primary" data-confirm>Ascend</button><button class="cw-button" data-cancel>Not yet</button></div>
          </div>`
      : `<button class="cw-button primary" data-ascend ${ashesNow && !changed ? '' : 'disabled'}>${!ashesNow ? 'Slay the Prelate this run to Ascend' : changed ? 'Swear or undo your vow changes first' : `Ascend: ${ashesNow} Ashes`}</button>`;

    body.innerHTML = `
      <div class="head">
        <div><span class="k">Best rank</span><b>${l.ascension ? `Ascension ${roman(l.ascension)}` : 'None yet'}</b></div>
        <div><span class="k">This run's heat</span><b>${swornHeat}</b></div>
        <div><span class="k">Ashes</span><b data-ashes>${l.ashes}</b></div>
        <div><span class="k">Soul shards</span><b data-shards>${l.shards}</b></div>
      </div>
      <h3>Vows <small>choose how hard the next run is; seals never close again</small></h3>
      <div class="vows">${vowCards}</div>
      ${swearBlock}
      <h3>This run</h3>
      <div class="run">
        <span>Prelate slain <b>${run.prelateKills}</b></span>
        <span>Peak Wave Speed <b>${run.peakWaveTier}</b></span>
        <span>Dead laid to rest <b>${run.kills}</b></span>
        <span>Pays <b>${ashesNow || '-'}</b> Ashes</span>
      </div>
      ${ascendBlock}
      <h3>Covenant Boons <small>bought with Ashes; soul shards unlock the stranger ones</small></h3>
      <div class="boons">${boons}</div>`;

    body.querySelectorAll<HTMLButtonElement>('[data-vow]').forEach((b) =>
      b.addEventListener('click', () => {
        const id = b.dataset.vow as VowId;
        const to = Math.max(0, Math.min(VOWS[id].maxRank, Number(b.dataset.to)));
        const next = { ...this.draft };
        if (to) next[id] = to;
        else delete next[id];
        this.draft = next;
        this.drafted = true;
        this.render();
      }),
    );
    body.querySelector('[data-clear]')?.addEventListener('click', () => {
      this.draft = {};
      this.drafted = true;
      this.render();
    });
    body.querySelector('[data-swear]')?.addEventListener('click', () => {
      this.drafted = false;
      this.onSwear({ ...this.draft });
      this.render();
    });
    body.querySelectorAll<HTMLButtonElement>('[data-open]').forEach((b) => b.addEventListener('click', () => this.onOpen(b.dataset.open!)));
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
