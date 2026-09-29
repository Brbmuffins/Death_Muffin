import { ABILITIES, ROLE_LABEL, rolesOf, unlockLevel, type AbilityId, type RiteRole } from '../content/abilities';
import type { Kit } from '../content/kits';
import { CODEX_RITES, riteSwatch } from '../content/codex';
import { LOADOUT_SLOTS, type Rites } from '../gameplay/loadout';
import { SimplePanel } from './MiscPanels';

const secs = (ms: number) => `${+(ms / 1000).toFixed(2)}s`;
type Socket = number | 'primary';
const ROLES = Object.keys(ROLE_LABEL) as RiteRole[];

/**
 * The Grimoire (L, the hotbar's Grimoire button, or right-click a slot): the
 * left-click primary plus four rite sockets on keys 1–4. Click a socket to
 * select it, then click a rite to place it (or use a rite's 1–4 buttons). A
 * rite already on another key swaps places. Cooldowns belong to the rite, so
 * swapping never resets one. Locked rites stay visible with their level.
 */
export class GrimoirePanel extends SimplePanel {
  private selected: Socket = 0;
  private role: RiteRole | 'all' = 'all';
  /** Unseen when this opening began (the NEW tags stay up while the panel is open). */
  private fresh = new Set<AbilityId>();

  constructor(
    root: HTMLElement,
    private state: () => { rites: Rites; level: number; unseen: AbilityId[]; kit: Kit },
    private assign: (slot: number, id: AbilityId) => void,
    private assignPrimary: (id: AbilityId) => void,
    private markSeen: (ids: AbilityId[]) => void,
  ) {
    super(root);
  }

  /** Open with a socket preselected (right-clicking a hotbar slot passes its key). */
  open(select?: Socket) {
    if (select !== undefined) this.selected = select;
    if (this.el) return this.render();
    this.mount('Grimoire', '<div data-body></div>');
    this.el!.classList.add('cw-grimoire');
    const { unseen } = this.state();
    this.fresh = new Set(unseen);
    if (this.selected !== 'primary' && unseen.some((id) => this.state().kit.primaries.includes(id))) this.selected = 'primary';
    this.render();
    this.markSeen(unseen);
  }

  /** Redraw after the loadout or level changes (no-op while closed). */
  render() {
    if (!this.el) return;
    const { rites, level, kit } = this.state();
    const body = this.el.querySelector<HTMLDivElement>('[data-body]')!;
    const socket = (id: AbilityId, key: Socket, label: string) => `
      <button type="button" class="cw-grim-socket${this.selected === key ? ' on' : ''}" data-socket="${key}" aria-pressed="${this.selected === key}" aria-label="Select ${label}: ${ABILITIES[id].name}">
        <img src="${ABILITIES[id].icon}" alt="" draggable="false" />
        <span class="key">${label}</span>
        <span class="nm">${ABILITIES[id].name}</span>
      </button>`;
    const primaryMode = this.selected === 'primary';
    const list = primaryMode ? kit.primaries : kit.grimoire.filter((id) => this.role === 'all' || rolesOf(id).includes(this.role));
    const choices = kit.grimoire.length > LOADOUT_SLOTS || kit.primaries.length > 1;
    body.innerHTML = `
      <p class="cw-settings-note">${choices ? 'Click a socket, then an unlocked rite to equip it.' : 'Your class has one primary and four rites; you can rearrange the rites on keys 1–4.'} <b>LMB</b> is your left-click attack. A rite already on another key swaps places, and cooldowns stay with the rite. Right-click a hotbar slot to jump here. ${ABILITIES[kit.rmb].name} and your signature rite stay where they are.</p>
      <div class="cw-grim-bar" aria-label="Current rotation">
        ${socket(rites.primary, 'primary', 'LMB')}
        ${rites.keys.map((id, i) => socket(id, i, String(i + 1))).join('')}
      </div>
      ${primaryMode ? '<p class="cw-settings-note">Primaries cost nothing and fire on left-click (and Auto combat).</p>' : `<div class="cw-grim-roles" role="group" aria-label="Filter by role">${['all', ...ROLES]
        .map((r) => `<button type="button" class="cw-chip${this.role === r ? ' on' : ''}" data-role="${r}" aria-pressed="${this.role === r}">${r === 'all' ? 'All' : ROLE_LABEL[r as RiteRole]}</button>`)
        .join('')}</div>`}
      <div class="cw-codex-body">${list.map((id) => this.entry(id, rites, level, primaryMode)).join('')}</div>`;
    body.querySelectorAll<HTMLButtonElement>('[data-socket]').forEach((b) =>
      b.addEventListener('click', () => {
        this.selected = b.dataset.socket === 'primary' ? 'primary' : Number(b.dataset.socket);
        this.render();
      }),
    );
    body.querySelectorAll<HTMLButtonElement>('[data-role]').forEach((b) =>
      b.addEventListener('click', () => {
        this.role = b.dataset.role as RiteRole | 'all';
        this.render();
      }),
    );
    body.querySelectorAll<HTMLButtonElement>('[data-put]').forEach((b) =>
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        this.selected = Number(b.dataset.slot);
        this.assign(Number(b.dataset.slot), b.dataset.put as AbilityId);
      }),
    );
    body.querySelectorAll<HTMLElement>('[data-pick]').forEach((card) =>
      card.addEventListener('click', () => {
        const id = card.dataset.pick as AbilityId;
        if (this.selected === 'primary') this.assignPrimary(id);
        else this.assign(this.selected, id);
      }),
    );
  }

  private entry(id: AbilityId, rites: Rites, level: number, primaryMode: boolean) {
    const a = ABILITIES[id];
    const need = unlockLevel(id);
    const locked = level < need;
    const on = primaryMode ? (rites.primary === id ? 0 : -1) : rites.keys.indexOf(id);
    const cost = a.essenceCost ? `${a.essenceCost} essence` : 'No cost';
    const roles = rolesOf(id).map((r) => ROLE_LABEL[r]).join(' · ');
    const keys = primaryMode
      ? `<span class="cw-grim-keys">${on === 0 ? '<b>Equipped</b>' : locked ? '' : '<span>Click to equip</span>'}</span>`
      : `<span class="cw-grim-keys" role="group" aria-label="Choose a key for ${a.name}">${Array.from({ length: LOADOUT_SLOTS }, (_, i) =>
          `<button type="button" class="cw-grim-key${on === i ? ' on' : ''}" data-put="${id}" data-slot="${i}" ${locked || on === i ? 'disabled' : ''} aria-label="Put ${a.name} on key ${i + 1}"${on === i ? ' aria-current="true"' : ''}>${i + 1}</button>`,
        ).join('')}</span>`;
    const isNew = this.fresh.has(id) && !locked;
    return `
      <article class="cw-codex-entry cw-grim-entry${locked ? ' sealed' : ' pickable'}${on >= 0 ? ' equipped' : ''}" ${locked ? '' : `data-pick="${id}" tabindex="0"`}>
        <img class="ico" src="${a.icon}" alt="" draggable="false" />
        <div class="txt">
          <div class="hd"><h3>${a.name}${isNew ? ' <span class="cw-new">NEW</span>' : ''}</h3><span class="meta">${locked ? `Level ${need}` : `${cost} · ${secs(a.cooldownMs)}`}</span></div>
          ${roles ? `<div class="cw-grim-role">${roles}</div>` : ''}
          <p>${a.description}</p>
          <div class="cw-grim-row">
            <span class="chips" title="${CODEX_RITES[id].colour}">${riteSwatch(id).map((c) => `<i style="background:${c}"></i>`).join('')}</span>
            ${keys}
          </div>
        </div>
      </article>`;
  }
}
