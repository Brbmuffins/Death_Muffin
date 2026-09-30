import { RARITY_COLOR, RARITY_MARK, itemMeta } from '../content/items';
import { durationText, type GatherReport } from '../gameplay/gatherReport';

const WHY: Record<string, string> = {
  bagFull: 'Your bag filled up. Make room, then start AFK again.',
  moved: 'You took over the controls.',
  panel: 'You opened another panel.',
  hurt: 'Something hurt you.',
  dead: 'You fell.',
  left: 'You left the Sexton’s Acre.',
  blocked: 'The node was spent.',
  unreachable: 'The node could not be reached.',
  labor: 'Your laborers came home with this.',
};

const iconOf = (itemId: string) => itemMeta(itemId).icon ?? `art/items/${itemId}.png`;

/**
 * "The Sexton's Ledger": what an AFK session brought back. Shown when work stops, with the things worth feeling good about
 * (milestones, records, the rarest find) before the plain list of items.
 */
export class GatherReportPanel {
  private el: HTMLDivElement | null = null;

  constructor(
    private root: HTMLElement,
    private onOpenBag: () => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  show(r: GatherReport) {
    this.close();
    const el = document.createElement('div');
    el.className = 'cw-plate cw-panel-float wide cw-gather-report';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-label', 'While you were away');
    const totalXp = r.skills.reduce((n, s) => n + s.xp, 0);
    const wins = [...r.milestones, ...r.records];
    const escape = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
    el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">The Sexton’s Ledger</h2>
        <button class="cw-icon-btn" data-close aria-label="Close ledger">✕</button>
      </div>
      <p class="cw-codex-note">Worked for <b>${durationText(r.seconds)}</b>. ${escape(WHY[r.reason] ?? 'Work stopped.')}</p>
      <div class="cw-gr-big">
        <div><b>${r.totalItems.toLocaleString()}</b><span>finds</span></div>
        <div><b>${r.goldValue.toLocaleString()}g</b><span>worth</span></div>
        <div><b>${totalXp.toLocaleString()}</b><span>skill xp</span></div>
      </div>
      ${
        wins.length || r.best
          ? `<div class="cw-gr-wins">
              ${r.best ? `<div class="win rare" style="--rarity:${RARITY_COLOR[r.best.rarity]}">${RARITY_MARK[r.best.rarity]} Best find: <b>${escape(r.best.name)}</b>${r.best.qty > 1 ? ` ×${r.best.qty}` : ''}</div>` : ''}
              ${wins.map((w) => `<div class="win">★ ${escape(w)}</div>`).join('')}
            </div>`
          : ''
      }
      <div class="cw-chron">
        <div class="cw-chron-grp"><h4>Skills</h4>${r.skills
          .map(
            (s) =>
              `<div class="row"><span>${escape(s.name)} ${s.toLevel > s.fromLevel ? `<i>Lv ${s.fromLevel} → ${s.toLevel}</i>` : `Lv ${s.toLevel}`}</span><b>+${s.xp.toLocaleString()} xp</b></div>`,
          )
          .join('')}</div>
        <div class="cw-chron-grp"><h4>Brought back</h4>${r.items
          .map((i) => `<div class="row"><span style="color:${RARITY_COLOR[i.rarity]}"><img src="${iconOf(i.itemId)}" alt="" onerror="this.style.display='none'" /> ${escape(i.name)}</span><b>×${i.qty.toLocaleString()}</b></div>`)
          .join('')}</div>
      </div>
      <div class="cw-afk-controls">
        <button class="cw-button small" data-bag>Open Reliquary</button>
        <button class="cw-button small" data-close>Close</button>
      </div>`;
    el.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => this.close()));
    el.querySelector('[data-bag]')!.addEventListener('click', () => {
      this.close();
      this.onOpenBag();
    });
    this.root.appendChild(el);
    this.el = el;
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
