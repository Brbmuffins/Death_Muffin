import type { InventorySlot } from '../net/types';
import { STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { formatDerived, type StatDeltaLine } from '../gameplay/characterStats';
import { compareEquip, effectText, itemStatEffects, itemVerdict, type StatContext } from '../gameplay/gearStats';
import './gear-stats.css';

/** Gets the Reliquary the numbers for the character looking at it; null before the player exists. */
export type StatContextSource = () => StatContext | null;

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

const ARROW = { upgrade: '\u25B2', downgrade: '\u25BC', same: '=' } as const;

/** One line leading the tooltip and the detail: "Upgrade for your Gravecaller: +12% (more thrall damage)". */
export function verdictHtml(ctx: StatContext | null, slot: InventorySlot): string {
  const v = ctx && itemVerdict(ctx, slot);
  if (!v) return '';
  return `<div class="gs-verdict ${v.kind}"><span class="ar" aria-hidden="true">${ARROW[v.kind]}</span> ${esc(v.text)}</div>`;
}

/** The small corner arrow on a bag cell; nothing for "about the same". */
export function badgeHtml(ctx: StatContext | null, slot: InventorySlot): string {
  const v = ctx && itemVerdict(ctx, slot);
  if (!v || v.kind === 'same') return '';
  return `<span class="gs-badge ${v.kind}" title="${esc(v.text)}">${ARROW[v.kind]}</span>`;
}

/** "+6 VIT → +48 health (+22 thrall health)" for each stat on the item, for THIS character. */
export function itemStatsHtml(ctx: StatContext | null, slot: InventorySlot): string {
  const lead = verdictHtml(ctx, slot);
  if (!slot.stat_bonus) return lead;
  if (!ctx) {
    return STAT_KEYS.filter((k) => slot.stat_bonus![k]).map((k) => `<div class="stat">+${slot.stat_bonus![k]} ${STAT_LABELS[k]}</div>`).join('');
  }
  return lead + itemStatEffects(ctx, slot)
    .map((e) => `<div class="stat gs-stat"><b>${esc(e.head)}</b><span class="fx">${e.lines.length ? esc(effectText(e.lines)) : 'no effect for you'}</span></div>`)
    .join('');
}

const chip = (l: StatDeltaLine) => `<span class="${l.tone}">${l.text} ${l.label}</span>`;

/** Compact one-line version for the hover tooltip. */
export function compareChipsHtml(ctx: StatContext | null, slot: InventorySlot): string {
  const c = ctx && compareEquip(ctx, slot);
  if (!c) return '';
  const rows = c.lines.map(chip).join('');
  const notes = [...c.gained.map((t) => `<div class="up">${esc(t)}</div>`), ...c.lost.map((t) => `<div class="down">Loses: ${esc(t)}</div>`)].join('');
  return `<div class="gs-cmp-mini"><div class="hd">${headline(c.replaced)}</div><div class="chips">${rows || '<span>no change to your numbers</span>'}</div>${notes}</div>`;
}

function headline(replaced: InventorySlot[]) {
  if (!replaced.length) return 'If you equip it (nothing worn there):';
  return `Instead of ${replaced.map((r) => esc(r.name)).join(' and ')}:`;
}

/** The full table for the detail strip: every derived number, before -> after, green gains and red losses. */
export function compareTableHtml(ctx: StatContext | null, slot: InventorySlot): string {
  const c = ctx && compareEquip(ctx, slot);
  if (!c) return '';
  const rows = c.lines
    .map((l) => `<span class="r ${l.tone}" title="${l.short}: ${formatDerived(l.key, l.before)} → ${formatDerived(l.key, l.after)}"><b>${l.text}</b> ${l.label}</span>`)
    .join('');
  const notes = [
    ...c.gained.map((t) => `<li class="up">${esc(t)}</li>`),
    ...c.lost.map((t) => `<li class="down">Loses: ${esc(t)}</li>`),
  ].join('');
  return `
    <div class="gs-cmp">
      <div class="hd">${headline(c.replaced)}</div>
      ${rows ? `<div class="rows">${rows}</div>` : '<div class="gs-note">No change to your numbers.</div>'}
      ${notes ? `<ul>${notes}</ul>` : ''}
    </div>`;
}
