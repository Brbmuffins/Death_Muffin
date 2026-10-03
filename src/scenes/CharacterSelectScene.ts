import type { GameScene } from './SceneManager';
import { PLAYABLE_DISCIPLINES } from '../content/disciplines';
import { loadOrCreateCharacter } from '../net/api';
import type { Character } from '../net/types';
import type { NecroBackdrop } from '../graphics/NecroBackdrop';
import { dismissSplash } from '../ui/splash';
import { recommendedForFirstRun } from '../ui/firstHourRules';

/** Choose a playable discipline. New families retain a legacy character slot. */
export class CharacterSelectScene implements GameScene {
  private root = document.getElementById('ui-root')!;
  private el: HTMLDivElement | null = null;

  constructor(
    private backdrop: NecroBackdrop,
    private onSelected: (character: Character) => void,
  ) {}

  mount() {
    this.backdrop.mount();
    this.el = document.createElement('div');
    this.el.className = 'cw-front';
    this.el.innerHTML = `
      <div class="cw-plate cw-select" role="dialog" aria-label="Choose your discipline">
        <h1 class="cw-title">Choose Your Discipline</h1>
        <p class="sub">Choose from nine disciplines, each with its own resource, rites, and way through the dead.</p>
        <div class="cw-disc-grid" data-grid></div>
        <div class="cw-error" data-error role="alert"></div>
      </div>`;
    this.root.appendChild(this.el);
    const grid = this.el.querySelector<HTMLDivElement>('[data-grid]')!;
    const errorEl = this.el.querySelector<HTMLDivElement>('[data-error]')!;

    for (const d of PLAYABLE_DISCIPLINES) {
      const btn = document.createElement('button');
      btn.className = 'cw-disc';
      btn.style.setProperty('--disc-color', d.color);
      // This screen is only reached by an account with no character yet (main.ts resume(): 404 -> select).
      const recommended = recommendedForFirstRun(d.id, false);
      if (recommended) btn.classList.add('recommended');
      btn.innerHTML = `
        ${recommended ? '<span class="rec-badge">Recommended for your first run</span>' : ''}
        ${d.family === 'necromancer' ? '<span class="legacy">Necromancer</span>' : ''}
        <img class="portrait" src="art/portraits/${d.id}.webp" alt="" onerror="this.src='${d.portrait}'" />
        <span class="body">
          <span class="name">${d.name}</span>
          <span class="epithet">${d.epithet}</span>
          <span class="desc">${d.description}</span>
          <span class="passive"><b>${d.passive.name}.</b> ${d.passive.text}</span>
        </span>`;
      btn.addEventListener('click', async () => {
        errorEl.textContent = '';
        grid.querySelectorAll('button').forEach((b) => ((b as HTMLButtonElement).disabled = true));
        try {
          this.onSelected(await loadOrCreateCharacter(d.classIndex));
        } catch (err) {
          errorEl.textContent = err instanceof Error ? err.message : 'Could not bind you to that discipline';
          grid.querySelectorAll('button').forEach((b) => ((b as HTMLButtonElement).disabled = false));
        }
      });
      grid.appendChild(btn);
    }
    dismissSplash();
  }

  unmount() {
    this.el?.remove();
    this.el = null;
  }
}
