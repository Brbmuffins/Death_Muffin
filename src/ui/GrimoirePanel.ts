import { ABILITIES, ROLE_LABEL, rolesOf, unlockLevel, type AbilityId, type RiteRole } from '../content/abilities';
import type { Kit } from '../content/kits';
import { CODEX_RITES, riteSwatch } from '../content/codex';
import { assignableRites, LOADOUT_SLOTS, type Rites } from '../gameplay/loadout';
import { SimplePanel } from './MiscPanels';
import { RUNES, isRuneRite, runeSources, runesFor, type RuneId, type RuneRite } from '../content/runes';
import type { RuneSockets } from '../gameplay/runeRules';
import './runes.css';

const esc = (x: string) => x.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const secs = (ms: number) => `${+(ms / 1000).toFixed(2)}s`;
type Socket = number | 'primary';
const ROLES = Object.keys(ROLE_LABEL) as RiteRole[];

/**
 * The Grimoire (L, the hotbar's Grimoire button, or right-click a slot): the
 * left-click primary plus five rite sockets on keys 1–5 / right-click. Click a socket to
 * select it, then click a rite to place it (or use a rite's slot buttons). A
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
    /** Relic runes: what sits in the sockets, how many of each rune the bag holds, and how to move one (returns a player-readable error, or null). */
    private runes?: {
      state: () => { sockets: RuneSockets; owned: Partial<Record<RuneId, number>> };
      socket: (rite: RuneRite, itemId: RuneId | null) => Promise<string | null>;
    },
  ) {
    super(root);
  }

  /** The last refusal from the server, shown under the rune box until the next move. */
  private runeError = '';
  private runeBusy = false;

  /** Open with a socket preselected (right-clicking a hotbar slot passes its key). */
  open(select?: Socket) {
    if (select !== undefined) this.selected = select;
    if (this.el) return this.render();
    this.mount('Grimoire', '<div data-body></div>');
    this.el!.classList.add('cw-grimoire');
    const { unseen } = this.state();
    this.fresh = new Set(unseen);
    if (select === undefined && this.selected !== 'primary' && unseen.some((id) => this.state().kit.primaries.includes(id))) this.selected = 'primary';
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
        <img src="${ABILITIES[id].icon}" alt="" draggable="false" />${this.pip(id)}
        <span class="key">${label}</span>
        <span class="nm">${ABILITIES[id].name}</span>
      </button>`;
    const primaryMode = this.selected === 'primary';
    const available = assignableRites(kit);
    const list = primaryMode ? kit.primaries : available.filter((id) => this.role === 'all' || rolesOf(id).includes(this.role));
    const choices = available.length > LOADOUT_SLOTS || kit.primaries.length > 1;
    body.innerHTML = `
      <p class="cw-settings-note">${choices ? 'Click a socket, then an unlocked rite to equip it.' : 'Your class has one primary and five rites; you can rearrange all five slots.'} <b>LMB</b> is your left-click attack. Slot <b>5</b> also casts on right-click. A rite already on another slot swaps places, and cooldowns stay with the rite. Right-click a hotbar slot to jump here. Your signature rite stays on <b>R</b>.</p>
      <div class="cw-grim-bar" aria-label="Current rotation">
        ${socket(rites.primary, 'primary', 'LMB')}
        ${rites.keys.map((id, i) => socket(id, i, i === 4 ? 'RMB · 5' : String(i + 1))).join('')}
      </div>
      ${this.runeSection(primaryMode ? rites.primary : rites.keys[this.selected as number])}
      ${primaryMode ? '<p class="cw-settings-note">Primaries cost nothing and fire on left-click.</p>' : `<div class="cw-grim-roles" role="group" aria-label="Filter by role">${['all', ...ROLES]
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
    const selectedRite = (primaryMode ? rites.primary : rites.keys[this.selected as number]) as AbilityId;
    body.querySelectorAll<HTMLButtonElement>('[data-rune]').forEach((b) =>
      b.addEventListener('click', () => {
        if (isRuneRite(selectedRite)) void this.moveRune(selectedRite, b.dataset.rune as RuneId);
      }),
    );
    body.querySelector<HTMLButtonElement>('[data-rune-out]')?.addEventListener('click', () => {
      if (isRuneRite(selectedRite)) void this.moveRune(selectedRite, null);
    });
    body.querySelectorAll<HTMLElement>('[data-pick]').forEach((card) =>
      card.addEventListener('click', () => {
        const id = card.dataset.pick as AbilityId;
        if (this.selected === 'primary') this.assignPrimary(id);
        else this.assign(this.selected, id);
      }),
    );
  }

  /** The badge of the rune socketed in a rite, on its socket button. */
  private pip(id: AbilityId): string {
    const r = this.runes && isRuneRite(id) ? this.runes.state().sockets[id as RuneRite] : undefined;
    return r ? `<img class="cw-rune-pip" src="art/items/${r}.png" alt="" draggable="false" />` : '';
  }

  /**
   * The rune box under the bar: what sits in the selected rite's socket, and the runes that fit it (owned ones are buttons, the rest show where
   * they drop). Rites without a rune family say so in one line.
   */
  private runeSection(rite: AbilityId): string {
    if (!this.runes) return '';
    const name = ABILITIES[rite].name;
    if (!isRuneRite(rite)) return `<div class="cw-rune-box" data-runebox><h3>Rune socket <small>${esc(name)}</small></h3><p class="cw-rune-none">${esc(name)} has no runes yet. Bone Needle, Marrow Spear, Exhume, Miasma Circle and Black Litany each take one.</p></div>`;
    const { sockets, owned } = this.runes.state();
    const cur = sockets[rite];
    const def = cur ? RUNES[cur] : null;
    const now = def
      ? `<div class="cw-rune-frame"><img src="art/items/${def.id}.png" alt="" /></div>
         <div class="txt"><b>${esc(def.name)}</b>${def.lines.map((l) => `<p>${esc(l)}</p>`).join('')}${def.cost ? `<p class="cost">${esc(def.cost)}</p>` : ''}
         <button type="button" class="cw-button small" data-rune-out ${this.runeBusy ? 'disabled' : ''}>Take the rune out</button></div>`
      : `<div class="cw-rune-frame empty" aria-hidden="true">◇</div>
         <div class="txt"><b>Empty socket</b><p>A rune changes how ${esc(name)} behaves, not how hard it hits. Choose one below.</p></div>`;
    const list = runesFor(rite).map((r) => {
      const n = owned[r.id] ?? 0;
      const on = cur === r.id;
      if (on) return `<div class="cw-rune-opt on"><img src="art/items/${r.id}.png" alt="" /><span><span class="nm">${esc(r.name)}<i>${r.rarity}</i></span><span class="sh">${esc(r.short)}</span></span><span class="go">Socketed</span></div>`;
      if (n > 0) {
        return `<button type="button" class="cw-rune-opt" data-rune="${r.id}" ${this.runeBusy ? 'disabled' : ''} aria-label="Socket ${esc(r.name)} into ${esc(name)}"><img src="art/items/${r.id}.png" alt="" /><span><span class="nm">${esc(r.name)}<i>${r.rarity} · you have ${n}</i></span><span class="sh">${esc(r.short)}</span></span><span class="go">${cur ? 'Swap in' : 'Socket'}</span></button>`;
      }
      return `<div class="cw-rune-opt sealed" title="${esc(runeSources(r.id))}"><img src="art/items/${r.id}.png" alt="" style="filter:grayscale(1) brightness(0.6)" /><span><span class="nm">${esc(r.name)}<i>${r.rarity}</i></span><span class="sh">${esc(r.short)}</span></span><span class="go">Not found yet</span></div>`;
    });
    return `<div class="cw-rune-box" data-runebox><h3>Rune socket <small>${esc(name)}</small></h3>
      <div class="cw-rune-now">${now}</div>
      <div class="cw-rune-list">${list.join('')}</div>
      <div class="cw-rune-err" role="status" data-rune-err>${esc(this.runeError)}</div></div>`;
  }

  /** Move a rune (or take it out); the server answers with a readable error when it refuses. */
  private async moveRune(rite: RuneRite, id: RuneId | null) {
    if (!this.runes || this.runeBusy) return;
    this.runeBusy = true;
    this.runeError = '';
    this.render();
    try {
      this.runeError = (await this.runes.socket(rite, id)) ?? '';
    } finally {
      this.runeBusy = false;
      this.render();
    }
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
          `<button type="button" class="cw-grim-key${on === i ? ' on' : ''}" data-put="${id}" data-slot="${i}" ${locked || on === i ? 'disabled' : ''} aria-label="Put ${a.name} on ${i === 4 ? 'right-click or key 5' : `key ${i + 1}`}"${on === i ? ' aria-current="true"' : ''}>${i + 1}</button>`,
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
