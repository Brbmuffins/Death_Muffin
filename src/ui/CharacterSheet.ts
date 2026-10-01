import { SimplePanel } from './MiscPanels';
import { STAT_PRIMER, statSheet, type SheetLine, type SheetSection, type StatContext } from '../gameplay/gearStats';
import './gear-stats.css';

/**
 * The Character sheet (J): the numbers your gear and level actually produce, and where each one comes from.
 * Every line expands to its breakdown (base, level, each worn item, discipline, damage tiers, weapon line, boons).
 * Sections come from gameplay/gearStats.ts statSheet(), so armor set bonuses can later be one more section there.
 */
export class CharacterSheetPanel extends SimplePanel {
  private openLines = new Set<string>(['maxHp']);

  constructor(
    root: HTMLElement,
    private context: () => StatContext | null,
    private onOpen?: () => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    this.mount('Character sheet', '<div class="gs-body"></div>');
    this.el!.classList.add('gs-sheet');
    this.render();
    this.onOpen?.();
  }

  /** Refresh in place (gear changed while the sheet is open). */
  render() {
    const body = this.el?.querySelector<HTMLDivElement>('.gs-body');
    if (!body) return;
    const ctx = this.context();
    if (!ctx) {
      body.innerHTML = '<p class="gs-primer">Your character is not ready yet.</p>';
      return;
    }
    const section = (s: SheetSection) => `<h3>${s.title}</h3>${s.lines.map((l) => this.line(l)).join('')}`;
    body.innerHTML = `
      <p class="gs-primer">${STAT_PRIMER}</p>
      ${statSheet(ctx).map(section).join('')}
      <div class="gs-hint">Click a line to see where its number comes from. Brews and other timed effects are not included.</div>`;
    body.querySelectorAll<HTMLButtonElement>('[data-line]').forEach((b) =>
      b.addEventListener('click', () => {
        const id = b.dataset.line!;
        if (this.openLines.has(id)) this.openLines.delete(id);
        else this.openLines.add(id);
        const wrap = b.parentElement!;
        wrap.classList.toggle('open', this.openLines.has(id));
        b.setAttribute('aria-expanded', String(this.openLines.has(id)));
      }),
    );
  }

  private line(l: SheetLine) {
    const open = this.openLines.has(l.id);
    const rows = l.rows.map((r) => `<div class="r ${r.tone ?? ''} ${r.total ? 'total' : ''}"><span>${r.label}</span><b>${r.value}</b></div>`).join('');
    return `<div class="gs-line${open ? ' open' : ''}">
      <button type="button" data-line="${l.id}" aria-expanded="${open}"><span class="chev">▸</span><span class="lbl">${l.label}</span><span class="val">${l.value}</span><span class="help">${l.help}</span></button>
      <div class="gs-rows">${rows}</div>
    </div>`;
  }
}
