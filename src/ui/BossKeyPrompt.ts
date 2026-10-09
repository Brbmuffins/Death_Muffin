import { BOSSES, type BossId } from '../../server/rules/content/bosses';
import { EMPOWER, empowerGold, empoweredLegendaryChance } from '../../server/rules/gameplay/goldSinkRules';
import { wrapPanelBody } from './panelBody';

export interface BossKeyOffer {
  boss: BossId;
  seals: number;
  gold: number;
  shards: number;
  /** A summon already paid for (a wiped fight): calling again is free. */
  bound: boolean;
}

/**
 * The boss altar's choice when the hero carries a Covenant Seal: wake the boss the usual way (soul shards), or call it Empowered
 * (a Seal and gold). Server-priced and server-rolled; this card only shows the price and the stakes before anything is spent.
 */
export class BossKeyPrompt {
  private el: HTMLDivElement | null = null;

  constructor(
    private root: HTMLElement,
    private onNormal: (boss: BossId) => void,
    private onEmpowered: (boss: BossId) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  open(o: BossKeyOffer) {
    this.close();
    const def = BOSSES[o.boss];
    const cost = empowerGold(o.boss);
    const canNormal = o.shards >= def.shards;
    const why = o.bound ? '' : o.seals < 1 ? 'You have no Covenant Seal.' : o.gold < cost ? `You need ${cost.toLocaleString()} gold (you have ${o.gold.toLocaleString()}).` : '';
    const el = (this.el = document.createElement('div'));
    el.className = 'cw-plate cw-panel-float cw-bosskey';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-label', `Wake ${def.name}`);
    el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">${def.summonLabel}</h2>
        <button class="cw-icon-btn" data-close aria-label="Close">✕</button>
      </div>
      <p class="cw-hint-text">Wake <b>${def.name}</b>.</p>
      <button class="cw-button primary cw-bosskey-go" data-normal ${canNormal ? '' : 'disabled'}>Wake it · ${def.shards} soul shards <small>(you have ${o.shards})</small></button>
      <button class="cw-button primary cw-bosskey-go emp" data-emp ${why ? 'disabled' : ''}>Call it Empowered · ${o.bound ? 'your summon is bound: free' : `1 Covenant Seal + ${cost.toLocaleString()} gold`}${why ? ` <small>${why}</small>` : ''}</button>
      <p class="cw-hint-text">Empowered: ${EMPOWER.levelsFlat}+ levels stronger, ${Math.round((EMPOWER.hpMult - 1) * 100)}% more health and a red-gold glow. Its kill pays one guaranteed epic-or-better piece, a legendary ${Math.round(empoweredLegendaryChance(o.boss) * 1000) / 10}% of the time. The Seal and gold are taken now; a fight you lose can be tried again free.</p>`;
    wrapPanelBody(el);
    this.root.appendChild(el);
    el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    el.querySelector('[data-normal]')!.addEventListener('click', () => { this.close(); this.onNormal(o.boss); });
    el.querySelector('[data-emp]')!.addEventListener('click', () => { this.close(); this.onEmpowered(o.boss); });
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
