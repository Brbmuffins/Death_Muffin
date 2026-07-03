import type { GameScene } from './SceneManager';
import { CLASSES, PORTRAITS } from '../gameplay/classes';
import { loadOrCreateCharacter } from '../net/api';
import { LoginBackdrop } from '../graphics/loginBackdrop';

export class CharacterSelectScene implements GameScene {
  private root = document.getElementById('ui-root')!;
  private canvas = document.getElementById('scene') as HTMLCanvasElement;
  private el: HTMLDivElement | null = null;
  private backdrop = new LoginBackdrop();

  constructor(private onSelected: (character: any) => void) {}

  mount() {
    this.backdrop.mount(this.canvas);
    this.el = document.createElement('div');
    this.el.className = 'cw-panel cw-select';
    this.el.innerHTML = `
      <h1 class="cw-title">Choose Your Class</h1>
      <div id="cw-class-grid" class="cw-class-grid"></div>
      <div class="cw-error" id="cw-select-error"></div>
    `;
    this.root.appendChild(this.el);

    const grid = this.el.querySelector<HTMLDivElement>('#cw-class-grid')!;
    const errorEl = this.el.querySelector<HTMLDivElement>('#cw-select-error')!;

    CLASSES.filter((c) => c.index !== 0).forEach((c) => {
      const btn = document.createElement('button');
      btn.className = 'cw-class-card';
      const portrait = PORTRAITS[c.index];
      const color = c.color;
      btn.innerHTML = `
        <div class="portrait" style="--class-color:${color}">
          ${portrait ? `<img src="${portrait}" alt="${c.name}" />` : `<span class="mono">${c.name[0]}</span>`}
        </div>
        <div class="label">
          <span class="name">${c.name}</span>
          <span class="role">${c.role}</span>
        </div>
      `;
      btn.addEventListener('click', async () => {
        errorEl.textContent = '';
        btn.disabled = true;
        try {
          const character = await loadOrCreateCharacter(c.index);
          this.onSelected(character);
        } catch (err) {
          errorEl.textContent = err instanceof Error ? err.message : 'Could not create character';
          btn.disabled = false;
        }
      });
      grid.appendChild(btn);
    });
  }

  unmount() {
    this.el?.remove();
    this.el = null;
    this.backdrop.unmount();
  }
}
