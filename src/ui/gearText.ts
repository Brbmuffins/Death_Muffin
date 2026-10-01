import type { InventorySlot } from '../net/types';
import { STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { formatDerived, type StatDeltaLine } from '../gameplay/characterStats';
import { compareEquip, effectText, itemStatEffects, type StatContext } from '../gameplay/gearStats';
import './gear-stats.css';

/** Gets the Reliquary the numbers for the character looking at it; null before the player exists. */
export type StatContextSource = () => StatContext | null;

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/** "+6 VIT → +48 health (+22 thrall health)" for each stat on the item, for THIS character. */
export function itemStatsHtml(ctx: StatContext | null, slot: InventorySlot): string {
  if (!slot.stat_bonus) return '';
  if (!ctx) {
    return STAT_KEYS.filter((k) => slot.stat_bonus![k]).map((k) => `<div class="stat">+${slot.stat_bonus![k]} ${STAT_LABELS[k]}</div>`).join('');
  }
  return itemStatEffects(ctx, slot)
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
    .map((l) => `<tr class="${l.tone}"><th>${l.short}</th><td>${formatDerived(l.key, l.before)} → ${formatDerived(l.key, l.after)}</td><td class="d">${l.text}</td></tr>`)
    .join('');
  const notes = [
    ...c.gained.map((t) => `<li class="up">${esc(t)}</li>`),
    ...c.lost.map((t) => `<li class="down">Loses: ${esc(t)}</li>`),
  ].join('');
  return `
    <div class="gs-cmp">
      <div class="hd">${headline(c.replaced)}</div>
      ${rows ? `<table>${rows}</table>` : '<div class="gs-note">No change to your numbers.</div>'}
      ${notes ? `<ul>${notes}</ul>` : ''}
    </div>`;
}
