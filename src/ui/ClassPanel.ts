import { PLAYABLE_DISCIPLINES } from '../../server/rules/content/disciplines';
import { SimplePanel } from './MiscPanels';

/** Uses the same portraits, cards and engraved panels as initial class selection. */
export class ClassPanel extends SimplePanel {
  private busy = false;
  constructor(root: HTMLElement, private current: () => number, private choose: (index: number) => Promise<void>) {
    super(root);
  }

  open() {
    if (this.el) return;
    this.mount('Change class', `
      <p class="cw-settings-note">Change class whenever you want, at no cost. Your level, gold, items, upgrades and progress stay with this character. Changing class returns you to the Chapterhouse.</p>
      <div class="cw-disc-grid">${PLAYABLE_DISCIPLINES.map(d => `
        <button type="button" class="cw-disc" style="--disc-color:${d.color}" data-class="${d.classIndex}" aria-label="${d.name}" ${d.classIndex === this.current() ? 'disabled aria-current="true"' : ''}>
          <img class="portrait" src="art/portraits/${d.id}.webp" alt="" />
          <span class="body"><span class="name">${d.name}</span><span class="epithet">${d.epithet}</span>
          <span class="desc">${d.description}</span><span class="passive"><b>${d.passive.name}.</b> ${d.passive.text}</span>
          ${d.classIndex === this.current() ? '<span class="passive">Current class</span>' : ''}</span>
        </button>`).join('')}</div>
      <p class="cw-settings-note" data-status role="status"></p>
      <div class="cw-error" data-error role="alert"></div>`);
    this.el!.classList.add('cw-class-panel');
    const panel = this.el!;
    panel.querySelectorAll<HTMLButtonElement>('[data-class]').forEach(button => {
      button.addEventListener('click', async () => {
        if (this.busy) return;
        this.busy = true;
        panel.querySelector<HTMLElement>('[data-error]')!.textContent = '';
        panel.querySelector<HTMLElement>('[data-status]')!.textContent = 'Saving your character and changing class…';
        panel.querySelectorAll<HTMLButtonElement>('button').forEach(b => { b.disabled = true; });
        try {
          await this.choose(Number(button.dataset.class));
        } catch (err) {
          panel.querySelector<HTMLElement>('[data-error]')!.textContent = err instanceof Error ? err.message : 'Could not change class. Please try again.';
          panel.querySelector<HTMLElement>('[data-status]')!.textContent = '';
        } finally {
          this.busy = false;
          if (panel.isConnected) panel.querySelectorAll<HTMLButtonElement>('button').forEach(b => {
            b.disabled = Number(b.dataset.class) === this.current();
          });
        }
      });
    });
  }

  close() {
    if (!this.busy) super.close();
  }

  dispose() {
    this.busy = false;
    super.close();
  }
}
