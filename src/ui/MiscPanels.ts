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
    private onChangeClass?: () => void,
    /** Only for dev accounts: the dev-access overlay toggle (per character, never saved to the server). */
    private dev?: { get(): boolean; set(on: boolean): void },
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
        ${this.dev ? '<label class="row">Dev access (preview as a normal player when off)<input type="checkbox" data-dev aria-label="Dev access" /></label>' : ''}
        <label class="row">Auto combat (Easy only, G)<input type="checkbox" data-auto aria-label="Auto combat" /></label>
        <label class="row">Auto gathering<input type="checkbox" data-autogather aria-label="Auto gathering: move on to the next node of the same kind" /></label>
        <p class="cw-settings-note">While standing, fight nearby enemies and use basic rites automatically. Click to move; hold 1–4 to repeat a rite. Signature rites stay under your control.</p>
        ${this.onResetTips ? '<label class="row">New to the Covenant?<button type="button" class="cw-button" data-resettips>Show tips again</button></label>' : ''}
        ${this.onChangeClass ? '<label class="row">Class<button type="button" class="cw-button" aria-label="Change class" data-changeclass>Change class</button></label>' : ''}
        ${code ? `<label class="row">Party world code<b style="font-family:var(--cw-font-numeric)">${code}</b></label>` : ''}
        <div class="cw-keys">
          <kbd>Click</kbd><span>Move · attack target (Bone Needle) · use</span>
          <kbd>Minimap</kbd><span>Click a walkable spot to travel there</span>
          <kbd>Hover / focus</kbd><span>Spell icon: cost, targeting, effects and combat counsel</span>
          <kbd>Shift+Click</kbd><span>Cast Bone Needle without moving</span>
          <kbd>1–4 (hold)</kbd><span>Your four Grimoire rites, at the cursor (start: Marrow Spear · Exhume · Miasma · Black Litany)</span>
          <kbd>L</kbd><span>Grimoire (also the hotbar's Grimoire button, or right-click a slot) · choose your left-click primary and the rites on 1–4</span>
          <kbd>RMB · 5</kbd><span>Corpse Explosion (corpse nearest the cursor)</span>
          <kbd>R · 6</kbd><span>Signature rite (unlocks at level 10)</span>
          <kbd>Q</kbd><span>Drink a healing flask</span>
          <kbd>T</kbd><span>Return to the Chapterhouse</span>
          <kbd>Click a node</kbd><span>Gather: chop a tree, mine a seam, fish a pool, dig a grave (it keeps working until the node is spent)</span>
          <kbd>I C P M</kbd><span>Reliquary · Workbench · Skills · Waystones</span>
          <kbd>K</kbd><span>Codex</span>
          <kbd>G</kbd><span>Toggle auto combat on Easy · stand near enemies to grind</span>
          <kbd>Counsel header</kbd><span>Drag to move · arrow keys while focused · remembers its position</span>
          <kbd>Settings</kbd><span>Change class · keeps your character and progress</span>
          <kbd>WASD</kbd><span>Walk (fallback)</span>
          <kbd>Wheel</kbd><span>Zoom</span>
          <kbd>Enter</kbd><span>Chat</span>
          <kbd>Altar</kbd><span>Click the Altar in the Chapterhouse to Ascend and buy Boons</span>
        </div>
        <hr class="cw-rule" />
        <button class="cw-button" data-leave>Leave the world</button>
      </div>`,
    );
    const diff = this.el!.querySelector<HTMLSelectElement>('[data-diff]')!;
    const note = this.el!.querySelector<HTMLElement>('[data-diffnote]')!;
    const auto = this.el!.querySelector<HTMLInputElement>('[data-auto]')!;
    const syncAuto = () => {
      auto.checked = settings.autoCombat;
      auto.disabled = settings.difficulty !== 'easy';
    };
    const showNote = () => (note.textContent = `${DIFFICULTIES[settings.difficulty].blurb} ${settings.difficulty === 'easy' ? 'Auto combat turns on with Easy.' : 'Auto combat turns off with Medium and Hard.'} In co-op, the world keeper sets enemy difficulty; your auto combat choice stays yours.`);
    diff.value = settings.difficulty;
    showNote();
    syncAuto();
    diff.addEventListener('change', () => {
      if (isDifficulty(diff.value)) updateSettings({ difficulty: diff.value });
      showNote();
      syncAuto();
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
    const dev = this.el!.querySelector<HTMLInputElement>('[data-dev]');
    if (dev && this.dev) {
      dev.checked = this.dev.get();
      dev.addEventListener('change', () => this.dev?.set(dev.checked));
    }
    auto.addEventListener('change', () => updateSettings({ autoCombat: auto.checked }));
    const autoGather = this.el!.querySelector<HTMLInputElement>('[data-autogather]')!;
    autoGather.checked = settings.autoGather;
    autoGather.addEventListener('change', () => updateSettings({ autoGather: autoGather.checked }));
    this.el!.querySelector<HTMLButtonElement>('[data-resettips]')?.addEventListener('click', () => {
      updateSettings({ tips: true });
      tips.checked = false;
      this.onResetTips?.();
    });
    this.el!.querySelector('[data-leave]')!.addEventListener('click', () => this.onLeave());
    this.el!.querySelector('[data-changeclass]')?.addEventListener('click', () => this.onChangeClass?.());
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
