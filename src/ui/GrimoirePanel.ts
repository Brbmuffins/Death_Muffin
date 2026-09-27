import { ABILITIES, GRIMOIRE, unlockLevel, type AbilityId } from '../content/abilities';
import { CODEX_RITES, riteSwatch } from '../content/codex';
import { LOADOUT_SLOTS } from '../gameplay/loadout';
import { SimplePanel } from './MiscPanels';

const secs = (ms: number) => `${+(ms / 1000).toFixed(2)}s`;

/**
 * The Grimoire (L): four static rite slots on keys 1–4, filled from every rite
 * the character has unlocked. Picking a key for a rite that already sits on
 * another key swaps the two. Cooldowns belong to the rite, so swapping never
 * resets one.
 */
export class GrimoirePanel extends SimplePanel {
  constructor(
    root: HTMLElement,
    private state: () => { loadout: AbilityId[]; level: number },
    private assign: (slot: number, id: AbilityId) => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    this.mount('Grimoire', '<div data-body></div>');
    this.el!.classList.add('cw-grimoire');
    this.render();
  }

  /** Redraw after the loadout or level changes (no-op while closed). */
  render() {
    if (!this.el) return;
    const { loadout, level } = this.state();
    const body = this.el.querySelector<HTMLDivElement>('[data-body]')!;
    body.innerHTML = `
      <p class="cw-settings-note">Keys <kbd>1</kbd>–<kbd>4</kbd> hold any four of your rites. Pick a key on a rite to place it there; a rite already on another key swaps places. Bone Needle, Corpse Explosion and your signature rite stay where they are.</p>
      <div class="cw-grim-bar" aria-label="Current rotation">${loadout
        .map((id, i) => `
          <div class="cw-grim-socket" title="${ABILITIES[id].name}">
            <img src="${ABILITIES[id].icon}" alt="" draggable="false" />
            <span class="key">${i + 1}</span>
            <span class="nm">${ABILITIES[id].name}</span>
          </div>`)
        .join('')}</div>
      <div class="cw-codex-body">${GRIMOIRE.map((id) => this.entry(id, loadout, level)).join('')}</div>`;
    body.querySelectorAll<HTMLButtonElement>('[data-put]').forEach((b) =>
      b.addEventListener('click', () => this.assign(Number(b.dataset.slot), b.dataset.put as AbilityId)),
    );
  }

  private entry(id: AbilityId, loadout: AbilityId[], level: number) {
    const a = ABILITIES[id];
    const need = unlockLevel(id);
    const locked = level < need;
    const on = loadout.indexOf(id);
    const cost = a.essenceCost ? `${a.essenceCost} essence` : 'No cost';
    const keys = Array.from({ length: LOADOUT_SLOTS }, (_, i) =>
      `<button type="button" class="cw-grim-key${on === i ? ' on' : ''}" data-put="${id}" data-slot="${i}" ${locked || on === i ? 'disabled' : ''} aria-label="Put ${a.name} on key ${i + 1}"${on === i ? ' aria-current="true"' : ''}>${i + 1}</button>`,
    ).join('');
    return `
      <article class="cw-codex-entry cw-grim-entry${locked ? ' sealed' : ''}${on >= 0 ? ' equipped' : ''}">
        <img class="ico" src="${a.icon}" alt="" draggable="false" />
        <div class="txt">
          <div class="hd"><h3>${a.name}</h3><span class="meta">${locked ? `Unlocks at level ${need}` : `${cost} · ${secs(a.cooldownMs)}`}</span></div>
          <p>${a.description}</p>
          <div class="cw-grim-row">
            <span class="chips" title="${CODEX_RITES[id].colour}">${riteSwatch(id).map((c) => `<i style="background:${c}"></i>`).join('')}</span>
            <span class="cw-grim-keys" role="group" aria-label="Choose a key for ${a.name}">${keys}</span>
          </div>
        </div>
      </article>`;
  }
}
