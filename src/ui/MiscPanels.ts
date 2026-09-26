import { settings, updateSettings, type Quality } from '../app/settings';
import { AREAS, type AreaId } from '../content/areas';
import { DIFFICULTIES, DIFFICULTY_ORDER, isDifficulty } from '../content/difficulty';

export abstract class SimplePanel {
  protected el: HTMLDivElement | null = null;
  constructor(protected root: HTMLElement) {}
  get isOpen() {
    return this.el !== null;
  }
  protected mount(title: string, body: string) {
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', title);
    this.el.innerHTML = `
      <div class="cw-panel-head"><h2 class="cw-title">${title}</h2><button class="cw-icon-btn" data-close aria-label="Close">✕</button></div>
      ${body}`;
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.root.appendChild(this.el);
  }
  close() {
    this.el?.remove();
    this.el = null;
  }
}

/** Graphics / motion / feedback options + key reference. */
export class SettingsPanel extends SimplePanel {
  constructor(
    root: HTMLElement,
    private onLeave: () => void,
    private instanceCode: () => string | null,
    private onResetTips?: () => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    const code = this.instanceCode();
    this.mount(
      'Settings',
      `<div class="cw-settings">
        <label class="row">Difficulty
          <select data-diff>${DIFFICULTY_ORDER.map((d) => `<option value="${d}">${DIFFICULTIES[d].name}</option>`).join('')}</select></label>
        <p class="cw-settings-note" data-diffnote></p>
        <label class="row">Graphics
          <select data-q><option value="high">High (bloom, shadows)</option><option value="low">Low (fast)</option></select></label>
        <label class="row">Volume<input type="range" min="0" max="1" step="0.05" data-vol aria-label="Master volume" /></label>
        <label class="row">Reduce motion (no camera shake)<input type="checkbox" data-rm /></label>
        <label class="row">Damage numbers<input type="checkbox" data-dn /></label>
        <label class="row">Don't show tips<input type="checkbox" data-tips /></label>
        ${this.onResetTips ? '<label class="row">New to the Covenant?<button type="button" class="cw-button" data-resettips>Show tips again</button></label>' : ''}
        ${code ? `<label class="row">Party world code<b style="font-family:var(--cw-font-numeric)">${code}</b></label>` : ''}
        <div class="cw-keys">
          <kbd>Click</kbd><span>Move · attack target (Bone Needle) · use</span>
          <kbd>Shift+Click</kbd><span>Cast Bone Needle without moving</span>
          <kbd>1–4</kbd><span>Marrow Spear · Exhume · Miasma · Black Litany (at cursor)</span>
          <kbd>RMB · 5</kbd><span>Corpse Explosion (corpse nearest the cursor)</span>
          <kbd>Q</kbd><span>Drink a healing flask</span>
          <kbd>T</kbd><span>Return to the Chapterhouse</span>
          <kbd>I C P M</kbd><span>Reliquary · Workbench · Rites · Waystones</span>
          <kbd>K</kbd><span>Codex</span>
          <kbd>WASD</kbd><span>Walk (fallback)</span>
          <kbd>Wheel</kbd><span>Zoom</span>
          <kbd>Enter</kbd><span>Chat</span>
        </div>
        <hr class="cw-rule" />
        <button class="cw-button" data-leave>Leave the world</button>
      </div>`,
    );
    const diff = this.el!.querySelector<HTMLSelectElement>('[data-diff]')!;
    const note = this.el!.querySelector<HTMLElement>('[data-diffnote]')!;
    const showNote = () => (note.textContent = `${DIFFICULTIES[settings.difficulty].blurb} In co-op, the world keeper's difficulty applies.`);
    diff.value = settings.difficulty;
    showNote();
    diff.addEventListener('change', () => {
      if (isDifficulty(diff.value)) updateSettings({ difficulty: diff.value });
      showNote();
    });
    const q = this.el!.querySelector<HTMLSelectElement>('[data-q]')!;
    q.value = settings.quality;
    q.addEventListener('change', () => updateSettings({ quality: q.value as Quality }));
    const vol = this.el!.querySelector<HTMLInputElement>('[data-vol]')!;
    vol.value = String(settings.volume);
    vol.addEventListener('input', () => updateSettings({ volume: Number(vol.value) }));
    const rm = this.el!.querySelector<HTMLInputElement>('[data-rm]')!;
    rm.checked = settings.reducedMotion;
    rm.addEventListener('change', () => updateSettings({ reducedMotion: rm.checked }));
    const dn = this.el!.querySelector<HTMLInputElement>('[data-dn]')!;
    dn.checked = settings.damageNumbers;
    dn.addEventListener('change', () => updateSettings({ damageNumbers: dn.checked }));
    const tips = this.el!.querySelector<HTMLInputElement>('[data-tips]')!;
    tips.checked = !settings.tips;
    tips.addEventListener('change', () => updateSettings({ tips: !tips.checked }));
    this.el!.querySelector<HTMLButtonElement>('[data-resettips]')?.addEventListener('click', () => {
      updateSettings({ tips: true });
      tips.checked = false;
      this.onResetTips?.();
    });
    this.el!.querySelector('[data-leave]')!.addEventListener('click', () => this.onLeave());
  }
}

/** Fast travel between unlocked waystones. */
export class WaystonePanel extends SimplePanel {
  constructor(
    root: HTMLElement,
    private unlocked: () => AreaId[],
    private travel: (area: AreaId) => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    const areas = this.unlocked();
    this.mount(
      'Waystones',
      `<div class="cw-waystones">${areas
        .map((a) => `<button class="cw-button small" data-go="${a}"><span>${AREAS[a].name}</span><span class="cw-hint-text">Lv ${AREAS[a].level}</span></button>`)
        .join('')}</div>
      <p class="cw-hint-text" style="margin-top:10px">Waystones answer only in the Chapterhouse or beside another waystone.</p>`,
    );
    this.el!.querySelectorAll<HTMLButtonElement>('[data-go]').forEach((b) =>
      b.addEventListener('click', () => {
        this.close();
        this.travel(b.dataset.go as AreaId);
      }),
    );
  }
}
