import type { InventorySlot } from '../net/types';
import { STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { formatDerived, type StatDeltaLine } from '../gameplay/characterStats';
import { compareEquip, effectText, itemAffixEffects, itemStatEffects, itemVerdict, simulateEquip, type StatContext } from '../gameplay/gearStats';
import { affixLines } from '../gameplay/affixes';
import { ARMOR_BY_ID } from '../content/armorSets';
import type { SetDiff } from '../gameplay/setBonuses';
import { effectRelevant, setDiffText, setStatus, wornArmor } from '../gameplay/setBonuses';
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

/** "Item level 22 · 2 affixes" under the type line of a rolled piece; nothing for plain gear. */
export function itemLevelHtml(slot: InventorySlot, inline = false): string {
  const inst = slot.inst;
  if (!inst) return '';
  const n = inst.affixes.length;
  const text = `Item level <b>${inst.ilvl}</b> \u00B7 ${n ? `${n} ${n === 1 ? 'affix' : 'affixes'}` : 'no affixes'}`;
  return inline ? ` <span class="gs-ilvl-inline">\u00B7 ${text}</span>` : `<div class="gs-ilvl">${text}</div>`;
}

/** The affix lines: what each rolled line says, and (for you) what it does. Necromancer levers are marked and tinted. */
export function affixesHtml(ctx: StatContext | null, slot: InventorySlot): string {
  if (!slot.inst) return '';
  if (!ctx) return affixLines(slot).map((l) => `<div class="stat gs-affix${l.necro ? ' necro' : ''}"><b>${esc(l.text)}</b></div>`).join('');
  return itemAffixEffects(ctx, slot)
    .map((e) => {
      const fx = e.lines.length ? effectText(e.lines) : e.relevant ? '' : 'no effect for you';
      return `<div class="stat gs-stat gs-affix${e.necro ? ' necro' : ''}${e.relevant ? '' : ' idle'}"><b>${e.necro ? '<i class="mk" aria-hidden="true">\u2020</i>' : ''}${esc(e.text)}</b>${fx ? `<span class="fx" title="${esc(fx)}">${esc(fx)}</span>` : ''}</div>`;
    })
    .join('');
}

/** "+6 VIT → +48 health (+22 thrall health)" for each stat on the item, for THIS character; then the item's affixes. */
export function itemStatsHtml(ctx: StatContext | null, slot: InventorySlot, withVerdict = true): string {
  const lead = withVerdict ? verdictHtml(ctx, slot) : '';
  const extra = affixesHtml(ctx, slot);
  if (!slot.stat_bonus) return lead + extra;
  if (!ctx) {
    return STAT_KEYS.filter((k) => slot.stat_bonus![k]).map((k) => `<div class="stat">+${slot.stat_bonus![k]} ${STAT_LABELS[k]}</div>`).join('') + extra;
  }
  return lead + itemStatEffects(ctx, slot)
    .map((e) => `<div class="stat gs-stat"><b>${esc(e.head)}</b><span class="fx" title="${e.lines.length ? esc(effectText(e.lines)) : 'no effect for you'}">${e.lines.length ? esc(effectText(e.lines)) : 'no effect for you'}</span></div>`)
    .join('') + extra;
}

const chip = (l: StatDeltaLine) => `<span class="${l.tone}">${l.text} ${l.label}</span>`;

/** Compact one-line version for the hover tooltip. */
export function compareChipsHtml(ctx: StatContext | null, slot: InventorySlot): string {
  const c = ctx && compareEquip(ctx, slot);
  if (!c) return '';
  const rows = c.lines.map(chip).join('');
  const notes = [...setNotes(c.sets, 'div'), ...c.gained.map((t) => `<div class="up">${esc(t)}</div>`), ...c.lost.map((t) => `<div class="down">Loses: ${esc(t)}</div>`)].join('');
  return `<div class="gs-cmp-mini"><div class="hd">${headline(c.replaced)}</div><div class="chips">${rows || '<span>no change to your numbers</span>'}</div>${notes}</div>`;
}

/** "Completes Ivory Reliquary 4-piece" (green) and "Breaks your Gravecall 2-piece" (red), one line each. */
function setNotes(sets: SetDiff, tag: 'div' | 'li'): string[] {
  const out: string[] = [];
  const g = setDiffText({ gained: sets.gained, lost: [] });
  const l = setDiffText({ gained: [], lost: sets.lost });
  if (g) out.push(`<${tag} class="up">Set: ${esc(g)}</${tag}>`);
  if (l) out.push(`<${tag} class="down">Set: ${esc(l)}</${tag}>`);
  return out;
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
    ...setNotes(c.sets, 'li'),
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

/**
 * An armor piece's set block for tooltips: "Ivory Reliquary  3 / 5 worn", then each bonus, green when active and
 * grey until then. For a bag piece it also says what wearing it would do ("4 / 5 with this", gold lines).
 */
export function setTooltipHtml(ctx: StatContext | null, slots: readonly InventorySlot[], slot: InventorySlot): string {
  const piece = ARMOR_BY_ID[slot.item_id];
  if (!piece) return '';
  const partsOf = (list: readonly InventorySlot[]) => wornArmor(list).filter((p) => p.setId === piece.setId).map((p) => p.part);
  const now = setStatus(piece.setId, partsOf(slots));
  const after = !slot.equipped && ctx ? setStatus(piece.setId, partsOf(simulateEquip(slots, slot.slot_index).slots)) : now;
  const gain = after.worn !== now.worn;
  const family = ctx?.discipline ?? { family: 'necromancer' as const };
  const lines = now.bonuses.map((b, i) => {
    const soon = !b.active && after.bonuses[i].active;
    const cls = b.active ? 'on' : soon ? 'soon' : 'off';
    const mark = b.active ? '\u2713' : soon ? '\u25B2' : '\u00B7';
    const note = effectRelevant(b.effect, family) ? '' : ' <i>(no effect for your class)</i>';
    return `<div class="b ${cls}"><span class="n">${b.pieces}</span><span class="t">${mark} ${b.name ? `<b>${esc(b.name)}</b>: ` : ''}${esc(b.lines.join(' \u00B7 '))}${note}</span></div>`;
  }).join('');
  return `<div class="gs-set"><div class="hd"><span class="nm">${esc(now.setName)}</span><span class="ct${now.worn >= 2 ? ' on' : ''}">${now.worn} / 5 worn${gain ? ` <em>\u2192 ${after.worn} with this</em>` : ''}</span></div>${lines}</div>`;
}

/**
 * "Sell all junk" and "Salvage all below rare" must never take a piece you would be glad to wear: one that is an upgrade for this
 * character (an empty slot counts) or completes a set bonus. Without a character context nothing is spared.
 */
export function keepsForYou(ctx: StatContext | null): ((slot: InventorySlot) => boolean) | undefined {
  if (!ctx) return undefined;
  return (slot) => {
    const v = itemVerdict(ctx, slot);
    return !!v && (v.kind === 'upgrade' || v.sets.gained.length > 0);
  };
}
