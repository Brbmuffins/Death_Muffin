import { AREAS } from '../content/areas';
import { DISCIPLINES, type DisciplineId } from '../content/disciplines';
import { EQUIP_SLOTS, type EquipSlot } from '../content/gear';
import { ITEMS, RARITY_COLOR, RARITY_MARK } from '../content/items';
import { legendarySetFor } from '../content/legendarySets';
import { RUNES, isRuneId } from '../content/runes';
import { ABILITIES } from '../content/abilities';
import { BREWS } from '../content/brews';
import { NECRO_WEAPONS } from '../content/necroWeapons';
import { STAT_LABELS } from '../gameplay/stats';
import { itemVerdict, STAT_PRIORITY, type StatContext } from '../gameplay/gearStats';
import { salvagePreview } from '../gameplay/salvageRules';
import { orderInfo, RELIC_PREMIUM } from '../gameplay/contractRules';
import {
  FIT_LABEL, SOURCE_LABEL, affixCountOdds, areaQuality, cosmeticsInfo, rollPotential, atlasSlot, fitBand, fitTable, fmtChance, fmtQty, getAtlas, gearForSlot, isRecommendedKind, itemLevelAt, oneIn,
  placesFor, skillName, sourcesFor, type AtlasItem, type DropSource, type FitBand, type RecipeInfo,
} from '../gameplay/atlas';
import type { InventorySlot } from '../net/types';
import { SimplePanel } from './MiscPanels';
import './atlas.css';

/**
 * The Gear Atlas (the . key): what drops where and how often, what makes it, and what suits you. Think AtlasLoot plus Pawn.
 * All numbers come from gameplay/atlas.ts (computed from the live loot tables; docs/LOOT-TABLES.md is the same data on paper).
 *
 * Cost: this whole file is a lazy chunk (ui/AtlasLauncher.ts imports it on first open), nothing here runs while the panel is shut,
 * rows are built only for the tab on screen (icons load lazily as they scroll into view) and there is no per-frame work at all.
 */

export interface AtlasDeps {
  statContext(): StatContext | null;
  slots(): readonly InventorySlot[];
  level(): number;
  area(): string;
}

type View = 'slot' | 'where' | 'set' | 'mats' | 'best';
type MatsKind = 'materials' | 'brews' | 'reagents' | 'cosmetics';

const VIEWS: { id: View; label: string }[] = [
  { id: 'best', label: 'Best for me' },
  { id: 'slot', label: 'By slot' },
  { id: 'where', label: 'By area & boss' },
  { id: 'set', label: 'By set' },
  { id: 'mats', label: 'Materials & brews' },
];

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const stripThe = (s: string) => s.replace(/^The /, '');
const SLOT_SHORT: Record<EquipSlot, string> = { head: 'Head', chest: 'Chest', legs: 'Legs', feet: 'Feet', hands: 'Hands', main_hand: 'Main hand', off_hand: 'Off hand', ring: 'Ring', trinket: 'Trinket' };
const TYPE_GLYPH: Record<string, string> = { weapon: '⚔', offhand: '◐', armor_head: '⛨', armor_chest: '⛊', armor_legs: '⛊', armor_feet: '◭', armor_hands: '✋', ring: '◎', trinket: '✦', rune: '✧', material: '◆' };

const EVENT_SHORT: [RegExp, string][] = [
  [/^Ordinary kill$/, 'kill'], [/^Elite kill$/, 'elite'], [/^Boss kill \(repeat\)$/, 'boss repeat'], [/^Boss kill$/, 'boss'], [/^First kill/, 'first kill'],
  [/^Grave Surge/, 'surge'], [/^Chest/, 'chest'], [/^Floor cleared/, 'stair'], [/^Salvage (.*)$/, 'salvage $1'],
];
const shortEvent = (e: string) => {
  for (const [re, to] of EVENT_SHORT) if (re.test(e)) return e.replace(re, to);
  return e.replace(/ \(.*\)$/, '').toLowerCase();
};
const shortPlace = (s: DropSource) => stripThe(s.place).replace('Catacomb Depths, ', 'Depths ').replace(' (Sexton’s Acre)', '');

const statText = (stats: Record<string, number>) => Object.entries(stats).filter(([, v]) => v).map(([k, v]) => `${v > 0 ? '+' : ''}${v} ${(STAT_LABELS as Record<string, string>)[k] ?? k.replace('stat_', '').toUpperCase()}`).join(' ');

const isBrewLike = (id: string) => id in BREWS || /^(flask_|elixir_|tonic_|meal_)/.test(id);
const isReagentLike = (id: string) => /^(reagent_|herb_|seed_|sapling_|ichor_)/.test(id) || ITEMS[id]?.type === 'rune';
const matsKindOf = (id: string): MatsKind => (id.startsWith('charm_') ? 'cosmetics' : isBrewLike(id) ? 'brews' : isReagentLike(id) ? 'reagents' : 'materials');

/** Remembered while the game runs, so reopening lands where you left off. */
const memory: { view: View; slot: EquipSlot; where: string; set: string; mats: MatsKind; reach: boolean; sel: string | null } = {
  view: 'best', slot: 'head', where: '', set: '', mats: 'materials', reach: true, sel: null,
};

export class AtlasPanel extends SimplePanel {
  private disc!: DisciplineId;
  private q = '';
  private owned = new Map<string, { n: number; worn: boolean }>();
  private trail: string[] = [];
  private verdicts = new Map<string, ReturnType<typeof itemVerdict>>();
  private allSources = false;

  constructor(root: HTMLElement, private deps: AtlasDeps) {
    super(root);
  }

  open() {
    if (this.el) return;
    const ctx = this.deps.statContext();
    this.disc = (ctx?.discipline.id ?? 'gravecaller') as DisciplineId;
    this.verdicts.clear();
    this.owned.clear();
    for (const s of this.deps.slots()) {
      const o = this.owned.get(s.item_id) ?? { n: 0, worn: false };
      o.n += s.quantity;
      o.worn ||= !!s.equipped;
      this.owned.set(s.item_id, o);
    }
    getAtlas();
    if (!memory.set) memory.set = legendarySetFor(this.disc) ?? getAtlas().sets.find((s) => s.disciplineId === this.disc && s.collection === 1)?.id ?? getAtlas().sets[0].id;
    if (!memory.where || !placesFor(this.disc).some((p) => p.id === memory.where)) memory.where = AREAS[this.deps.area() as keyof typeof AREAS]?.loot.length ? this.deps.area() : 'graves';
    const name = DISCIPLINES[this.disc].name;
    this.mount('Gear Atlas', `<div class="at-body"></div>`);
    this.el!.classList.add('cw-atlas');
    const body = this.el!.querySelector<HTMLDivElement>('.at-body')!;
    body.innerHTML = `
      <div class="at-top">
        <div class="at-who">For your <b>${esc(name)}</b> · prefers <b>${STAT_PRIORITY[this.disc].order.map((k) => k.replace('stat_', '').toUpperCase()).join(' > ')}</b></div>
        <label class="at-search"><span class="at-sr">Search items</span><input type="search" data-q placeholder="Search items" autocomplete="off" spellcheck="false" aria-label="Search items" /></label>
      </div>
      <div class="cw-tabs at-tabs" role="tablist">${VIEWS.map((v) => `<button role="tab" data-view="${v.id}">${v.label}</button>`).join('')}</div>
      <div class="at-sub" data-sub></div>
      <div class="at-cols">
        <div class="at-list" data-list tabindex="-1"></div>
        <div class="at-detail" data-detail></div>
      </div>`;
    const q = body.querySelector<HTMLInputElement>('[data-q]')!;
    q.value = this.q;
    q.addEventListener('input', () => {
      this.q = q.value.trim().toLowerCase();
      this.el!.classList.remove('detail-open');
      this.renderList();
    });
    q.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        if (q.value) { q.value = ''; this.q = ''; this.renderList(); } else q.blur();
      }
    });
    body.querySelectorAll<HTMLButtonElement>('[data-view]').forEach((b) => b.addEventListener('click', () => {
      memory.view = b.dataset.view as View;
      this.el!.classList.remove('detail-open');
      this.sel = null;
      this.trail = [];
      this.q = '';
      q.value = '';
      this.render();
      body.querySelector<HTMLElement>('[data-list]')!.scrollTop = 0;
    }));
    // One delegated listener for everything inside the lists and the detail pane.
    body.addEventListener('click', (e) => this.onClick(e));
    body.addEventListener('change', (e) => this.onChange(e));
    // A missing icon falls back to the type glyph (error does not bubble: capture it).
    body.addEventListener('error', (e) => {
      const img = e.target;
      if (img instanceof HTMLImageElement) img.replaceWith(Object.assign(document.createElement('span'), { className: 'at-glyph', textContent: img.dataset.glyph ?? '◆' }));
    }, true);
    this.render();
    if (memory.sel) this.select(memory.sel, false);
  }

  close() {
    if (this.el) memory.sel = this.sel;
    super.close();
  }

  private sel: string | null = null;

  // --- rendering ---------------------------------------------------------------------------------------------------------------

  private render() {
    if (!this.el) return;
    this.el.querySelectorAll<HTMLButtonElement>('[data-view]').forEach((b) => {
      const on = b.dataset.view === memory.view && !this.q;
      b.classList.toggle('on', on);
      b.setAttribute('aria-selected', String(on));
    });
    this.renderList();
    if (!this.sel) this.renderDetail();
  }

  private renderSub() {
    const sub = this.el!.querySelector<HTMLElement>('[data-sub]')!;
    const atlas = getAtlas();
    let html = '';
    if (memory.view === 'slot') {
      html = `<div class="at-chips" role="group" aria-label="Slot">${EQUIP_SLOTS.map((s) => `<button data-slot="${s.id}" class="${s.id === memory.slot ? 'on' : ''}">${SLOT_SHORT[s.id]}</button>`).join('')}</div>`;
    } else if (memory.view === 'where') {
      const places = placesFor(this.disc);
      const group = (label: string, kind: string) => `<optgroup label="${label}">${places.filter((p) => p.kind === kind).map((p) => `<option value="${p.id}" ${p.id === memory.where ? 'selected' : ''}>${esc(stripThe(p.name))}${p.kind === 'area' || p.kind === 'boss' ? ` (Lv ${p.level})` : ''}</option>`).join('')}</optgroup>`;
      html = `<label class="at-select">Where <select data-where aria-label="Area or boss">${group('Hunting grounds', 'area')}${group('Bosses', 'boss')}${group('Catacomb Depths', 'depths')}${group('Gathering', 'gather')}</select></label>${this.qualityHtml(memory.where)}`;
    } else if (memory.view === 'set') {
      const opt = (c: number, label: string) => `<optgroup label="${label}">${atlas.sets.filter((s) => s.collection === c).map((s) => `<option value="${s.id}" ${s.id === memory.set ? 'selected' : ''}>${esc(s.name)} (${DISCIPLINES[s.disciplineId as DisciplineId]?.name ?? s.disciplineId})</option>`).join('')}</optgroup>`;
      html = `<label class="at-select">Set <select data-set aria-label="Armor set">${opt(3, 'Legendary')}${opt(2, 'Ascended')}${opt(1, 'First collection')}</select></label>`;
    } else if (memory.view === 'mats') {
      const k: [MatsKind, string][] = [['materials', 'Materials'], ['brews', 'Brews & food'], ['reagents', 'Reagents, runes & seeds'], ['cosmetics', 'Capes & pets']];
      html = `<div class="at-chips" role="group" aria-label="Kind">${k.map(([id, l]) => `<button data-mats="${id}" class="${id === memory.mats ? 'on' : ''}">${l}</button>`).join('')}</div>`;
    } else {
      html = `<label class="at-check"><input type="checkbox" data-reach ${memory.reach ? 'checked' : ''}/> Only what is in reach of level ${this.deps.level()}</label><span class="at-note">Top upgrades per slot for your ${esc(DISCIPLINES[this.disc].name)} that you do not own yet, then the legendary chase.</span>`;
    }
    sub.innerHTML = this.q ? `<span class="at-note">Searching every item. Clear the box to go back.</span>` : html;
  }

  /** How good this ground's drops are and how it compares with the ones above it (areaQuality: a rung of the descent). */
  private qualityHtml(placeId: string): string {
    const q = AREAS[placeId as keyof typeof AREAS] ? areaQuality(placeId as keyof typeof AREAS, this.disc) : null;
    if (!q) return '';
    const bar = Array.from({ length: q.rungs }, (_, i) => `<i class="${i < q.rung ? 'on' : ''}"></i>`).join('');
    const per = (n: number) => (n >= 10 ? n.toFixed(0) : n >= 1 ? n.toFixed(1) : n.toFixed(2));
    const bits = [
      `of every 100 kills about <b>${per(q.dropsPer100)}</b> leave an item, <b>${per(q.gearPer100)}</b> of them gear${q.rarePer100 >= 0.05 ? `, <b>${per(q.rarePer100)}</b> rare or better` : ''}`,
      q.killsPerOwn ? `a piece of your own armour set about every <b>${Math.round(q.killsPerOwn)}</b> kills` : '',
      `gear drops at item level about <b>${q.ilvlKill}</b> (bosses <b>${q.ilvlBoss}</b>)`,
      q.runePerElite ? `an elite sheds a rune <b>${fmtChance(q.runePerElite)}</b> of the time` : '',
      q.bossLegendary ? `its boss leaves a legendary <b>${fmtChance(q.bossLegendary)}</b> of the time` : '',
      q.eliteLegendary ? `an elite, <b>${fmtChance(q.eliteLegendary)}</b>` : '',
    ].filter(Boolean);
    return `<div class="at-quality" title="Deeper grounds weight the pieces worth wearing higher, drop higher item levels and shed runes and legendaries more often."><span class="at-rungs" aria-label="Depth ${q.rung} of ${q.rungs}">${bar}</span><span class="at-qtext"><b>Drop quality ${q.rung} of ${q.rungs}</b> (Lv ${q.level}): ${bits.join('; ')}.</span></div>`;
  }

  /** The rows of the current view: [item id, optional place to read the drop chance at]. */
  private rows(): { head?: string; id?: string; place?: string }[] {
    const atlas = getAtlas();
    if (this.q) {
      const hits = [...atlas.items.values()].filter((i) => i.name.toLowerCase().includes(this.q) || i.id.includes(this.q.replace(/\s+/g, '_')));
      hits.sort((a, b) => Number(b.gear) - Number(a.gear) || a.name.localeCompare(b.name));
      return hits.slice(0, 80).map((i) => ({ id: i.id }));
    }
    if (memory.view === 'slot') return this.sortGear(gearForSlot(memory.slot)).map((i) => ({ id: i.id }));
    if (memory.view === 'where') {
      const place = placesFor(this.disc).find((p) => p.id === memory.where);
      if (!place) return [];
      const out: { head?: string; id?: string; place?: string }[] = [];
      const groups: [string, (i: AtlasItem) => boolean][] = [
        ['Gear', (i) => i.gear],
        ['Runes', (i) => i.type === 'rune'],
        ['Reagents and ichor', (i) => i.type !== 'rune' && !i.gear && isReagentLike(i.id)],
        ['Materials and supplies', (i) => !i.gear && i.type !== 'rune' && !isReagentLike(i.id)],
      ];
      for (const [label, pred] of groups) {
        const ids = place.items.filter((id) => atlas.items.get(id) && pred(atlas.items.get(id)!));
        if (!ids.length) continue;
        out.push({ head: `${label} (${ids.length})${label === 'Runes' ? ' · every necromancer rite already has a socket in the Grimoire (L)' : ''}` });
        for (const id of ids) out.push({ id, place: place.id });
      }
      return out;
    }
    if (memory.view === 'set') {
      const set = atlas.sets.find((s) => s.id === memory.set);
      return (set?.pieces ?? []).map((id) => ({ id }));
    }
    if (memory.view === 'mats') {
      return [...atlas.items.values()].filter((i) => !i.gear && matsKindOf(i.id) === memory.mats && (atlas.sources.get(i.id)?.length || atlas.madeBy.get(i.id)?.length))
        .sort((a, b) => ['common', 'uncommon', 'rare', 'epic', 'legendary'].indexOf(a.rarity) - ['common', 'uncommon', 'rare', 'epic', 'legendary'].indexOf(b.rarity) || a.name.localeCompare(b.name)).map((i) => ({ id: i.id }));
    }
    // Best for me: per slot, the biggest upgrades you do not own.
    const out: { head?: string; id?: string }[] = [];
    const level = this.deps.level();
    const ownSet = legendarySetFor(this.disc);
    const chase: { id: string; pct: number }[] = [];
    for (const { id: slot } of EQUIP_SLOTS) {
      for (const i of gearForSlot(slot)) {
        if (i.rarity !== 'legendary' || this.owned.has(i.id) || (ownSet && i.setId !== ownSet)) continue;
        const v = this.verdict(i.id);
        if (v && v.kind === 'upgrade') chase.push({ id: i.id, pct: v.pct });
      }
      const picks = gearForSlot(slot)
        .filter((i) => i.rarity !== 'legendary' && !this.owned.has(i.id) && (!memory.reach || i.level <= level + 10))
        .map((i) => ({ i, v: this.verdict(i.id) }))
        .filter((x) => x.v && x.v.kind === 'upgrade' && (x.v.pct > 0 || x.v.empty))
        .sort((a, b) => (b.v!.pct - a.v!.pct) || a.i.level - b.i.level)
        .slice(0, 3);
      if (!picks.length) continue;
      out.push({ head: SLOT_SHORT[slot] });
      for (const p of picks) out.push({ id: p.i.id });
    }
    // The legendary chase comes last: very rare, so it never crowds out what you can actually find this week.
    if (chase.length) {
      out.push({ head: 'The legendary chase (rare boss drops)' });
      for (const c of chase.sort((a, b) => b.pct - a.pct).slice(0, 5)) out.push({ id: c.id });
    }
    return out;
  }

  /** Gear of one slot, best for you first (by the same score the arrows use), then by level. */
  private sortGear(items: AtlasItem[]): AtlasItem[] {
    const score = (i: AtlasItem) => {
      const v = this.verdict(i.id);
      return this.owned.get(i.id)?.worn ? 1000 : v ? v.pct : -999;
    };
    return items.sort((a, b) => score(b) - score(a) || a.level - b.level || a.name.localeCompare(b.name));
  }

  private verdict(id: string) {
    if (this.verdicts.has(id)) return this.verdicts.get(id)!;
    const ctx = this.deps.statContext();
    const slot = atlasSlot(id);
    let v: ReturnType<typeof itemVerdict> = null;
    if (ctx && slot && !this.owned.get(id)?.worn) {
      // Judge it as a bag item: the same arrow the Reliquary shows, but for every item in the game.
      v = itemVerdict({ ...ctx, slots: [...ctx.slots, slot] }, slot);
    }
    this.verdicts.set(id, v);
    return v;
  }

  private renderList() {
    if (!this.el) return;
    this.renderSub();
    const list = this.el.querySelector<HTMLElement>('[data-list]')!;
    const rows = this.rows();
    this.el.querySelectorAll<HTMLButtonElement>('[data-view]').forEach((b) => b.classList.toggle('on', b.dataset.view === memory.view && !this.q));
    if (!rows.length) {
      list.innerHTML = `<p class="at-empty">${this.q ? 'Nothing by that name.' : memory.view === 'best' ? 'No upgrade in reach for any slot. Untick the level filter to see further ahead.' : 'Nothing here.'}</p>`;
      return;
    }
    const setHead = memory.view === 'set' && !this.q ? this.setHeader() : memory.view === 'mats' && memory.mats === 'cosmetics' && !this.q ? this.cosmeticsHeader() : '';
    list.innerHTML = setHead + rows.map((r) => (r.head ? `<h3 class="at-head">${esc(r.head)}</h3>` : this.rowHtml(r.id!, r.place))).join('');
  }

  private rowHtml(id: string, place?: string): string {
    const it = getAtlas().items.get(id)!;
    const m = ITEMS[id];
    const own = this.owned.get(id);
    const src = this.srcLine(id, place);
    const band = it.gear ? fitBand(id, this.disc) : null;
    const v = it.gear ? this.verdict(id) : null;
    const badges: string[] = [];
    if (own?.worn) badges.push('<span class="at-tag worn" title="You are wearing this">Worn</span>');
    else if (own && it.gear) badges.push('<span class="at-tag" title="In your bag or vault">Owned</span>');
    if (band) badges.push(`<span class="at-fit ${band}" title="${esc(this.fitTitle(id, band))}">${FIT_LABEL[band]}</span>`);
    if (v) badges.push(this.arrow(v));
    const rec = it.gear && isRecommendedKind(id, this.disc) ? '<span class="at-rec" title="The Character sheet recommends this weapon kind for you">★</span>' : '';
    const stats = it.gear ? statText(it.stats) : '';
    const craft = (getAtlas().madeBy.get(id) ?? []).length ? ' · craftable' : '';
    const meta = [it.slot ? SLOT_SHORT[it.slot] : this.typeName(it), `${m.rarity[0].toUpperCase()}${m.rarity.slice(1)} ${RARITY_MARK[m.rarity]}`, it.gear ? `Lv ~${it.level}` : ''].filter(Boolean).join(' · ');
    return `<button class="at-row${this.sel === id ? ' sel' : ''}${own ? ' own' : ''}" data-id="${id}" style="--rarity:${RARITY_COLOR[m.rarity]}" title="${esc(src.title)}">
      <span class="at-ico">${this.iconHtml(id)}</span>
      <span class="at-main">
        <span class="at-name">${esc(it.name)}${rec}</span>
        <span class="at-meta">${esc(meta)}${stats ? ` · <b>${esc(stats)}</b>` : ''}</span>
        <span class="at-src">${esc(src.text)}${craft}</span>
      </span>
      <span class="at-badges">${badges.join('')}</span>
    </button>`;
  }

  private typeName(it: AtlasItem) {
    return it.type === 'rune' ? 'Relic rune' : isBrewLike(it.id) ? 'Brew' : isReagentLike(it.id) ? 'Reagent' : 'Material';
  }

  private iconHtml(id: string, big = false) {
    const m = ITEMS[id];
    const src = m?.icon ?? `art/items/${id}.webp`;
    const px = big ? 56 : 40;
    return `<img src="${src}" alt="" width="${px}" height="${px}" loading="lazy" decoding="async" data-glyph="${TYPE_GLYPH[m?.type ?? 'material'] ?? '◆'}" />`;
  }

  private arrow(v: NonNullable<ReturnType<typeof itemVerdict>>): string {
    const t = esc(v.text);
    if (v.kind === 'upgrade') return `<span class="at-arrow up" title="${t}">▲ ${v.empty && v.pct < 1 ? 'new' : `+${Math.round(v.pct)}%`}</span>`;
    if (v.kind === 'downgrade') return `<span class="at-arrow down" title="${t}">▼ ${Math.round(v.pct)}%</span>`;
    return `<span class="at-arrow same" title="${t}">≈</span>`;
  }

  private fitTitle(id: string, band: FitBand) {
    const t = fitTable(id);
    const mine = t[this.disc];
    return `${FIT_LABEL[band]} fit for your ${DISCIPLINES[this.disc].name}: it would add about ${mine >= 0 ? '+' : ''}${mine}% power to an empty slot, compared with the other pieces of its slot and rarity.`;
  }

  /** The short "where" text of a row, and the hover text listing the best sources. */
  private srcLine(id: string, place?: string): { text: string; title: string } {
    const all = sourcesFor(id, this.disc);
    const atlas = getAtlas();
    const here = place ? all.filter((s) => s.placeId === place) : [];
    const drops = all.filter((s) => s.kind !== 'salvage' && s.kind !== 'garden');
    const pool = here.length ? here : drops.filter((s) => s.kind !== 'depths').length ? drops.filter((s) => s.kind !== 'depths') : drops;
    const top = pool[0];
    const title = [...all.filter((s) => s.kind !== 'salvage').slice(0, 6).map((s) => `${shortPlace(s)}: ${s.event.toLowerCase()} ${fmtChance(s.chance)}${oneIn(s.chance) ? ` (${oneIn(s.chance)})` : ''}`),
      ...(atlas.madeBy.get(id) ?? []).slice(0, 2).map((r) => `Craft: ${skillName(r.profession)} ${r.level} at the ${r.station}`)].join('\n') || 'No drop: see the detail.';
    if (!top) {
      const r = atlas.madeBy.get(id)?.[0];
      const sal = all.find((s) => s.kind === 'salvage');
      return { text: r ? `Craft: ${skillName(r.profession)} ${r.level}` : sal ? `${sal.place.replace(/ \(.*\)/, '')}` : 'No source', title };
    }
    const more = (here.length ? here.length : drops.length) - 1;
    return { text: `${shortPlace(top)} · ${shortEvent(top.event)} ${fmtChance(top.chance)}${more > 0 ? ` · +${more} more` : ''}`, title };
  }

  /** Capes and pets are not items: a card list above the pet charms (which are). */
  private cosmeticsHeader(): string {
    const c = cosmeticsInfo();
    return `<div class="at-set"><div class="at-set-hd"><b>Capes &amp; pets</b></div>${c.notes.map((n) => `<p class="at-faint">${esc(n)}</p>`).join('')}
      <h3 class="at-head">Capes</h3>${c.capes.map((x) => `<div class="at-bonus on"><span class="n">\u2740</span><span><b>${esc(x.name)}</b>: ${esc(x.requirement)}</span></div>`).join('')}
      <h3 class="at-head">Pet charms (click one for where it turns up)</h3></div>`;
  }

  private setHeader(): string {
    const set = getAtlas().sets.find((s) => s.id === memory.set);
    if (!set) return '';
    const worn = set.pieces.filter((p) => this.owned.get(p)?.worn).length;
    return `<div class="at-set"><div class="at-set-hd"><b>${esc(set.name)}</b> · ${worn}/5 worn</div>${set.bonuses.map((b) => `<div class="at-bonus${worn >= b.pieces ? ' on' : ''}"><span class="n">${b.pieces}</span><span>${b.name ? `<b>${esc(b.name)}</b>: ` : ''}${esc(b.lines.join('; '))}</span></div>`).join('')}</div>`;
  }

  // --- detail ---------------------------------------------------------------------------------------------------------------------

  private select(id: string, push = true) {
    if (!getAtlas().items.has(id)) return;
    if (push && this.sel && this.sel !== id) this.trail.push(this.sel);
    this.sel = id;
    this.el!.classList.add('detail-open');
    this.el!.querySelectorAll<HTMLElement>('.at-row.sel').forEach((r) => r.classList.remove('sel'));
    this.el!.querySelector<HTMLElement>(`.at-row[data-id="${id}"]`)?.classList.add('sel');
    this.renderDetail();
    const d = this.el!.querySelector<HTMLElement>('[data-detail]')!;
    d.scrollTop = 0;
  }

  private renderDetail() {
    const d = this.el?.querySelector<HTMLElement>('[data-detail]');
    if (!d) return;
    if (!this.sel) {
      d.innerHTML = `<div class="at-hint"><h3>How to read this</h3>
        <p><span class="at-fit ideal">Ideal</span> <span class="at-fit good">Good</span> <span class="at-fit okay">Okay</span> <span class="at-fit poor">Poor</span> says how well a piece suits your discipline against the other pieces of its slot and rarity, by the same gear score the Character sheet uses. The number under it is the base piece; an <b>ideal affix roll</b> adds a good deal more (see "For you" on any piece).</p>
        <p>Under <b>By area &amp; boss</b>, each hunting ground shows a <b>drop quality</b> rung: the deeper you go, the likelier the pieces worth wearing, runes and legendaries, and the higher their item level. Chances shown are for your own discipline (your set drops more often than the others).</p>
        <p><span class="at-arrow up">▲ +12%</span> <span class="at-arrow down">▼ 5%</span> compares it with what you wear in that slot (percent of your power).</p>
        <p>Percentages are per kill, at default settings (Medium, Wave Speed 0, no fortune tonic). Hover a row, or click it, for every source. Click a name in a recipe to follow it.</p></div>`;
      return;
    }
    const id = this.sel;
    const atlas = getAtlas();
    const it = atlas.items.get(id)!;
    const m = ITEMS[id];
    const own = this.owned.get(id);
    const all = sourcesFor(id, this.disc);
    const parts: string[] = [];
    parts.push(`<button class="at-back" data-back>‹ ${this.trail.length ? 'Back' : 'List'}</button>`);
    parts.push(`<div class="at-dhead" style="--rarity:${RARITY_COLOR[m.rarity]}"><span class="at-ico big">${this.iconHtml(id, true)}</span><div><h3 class="at-dname">${esc(it.name)}</h3>
      <div class="at-meta">${esc([it.slot ? SLOT_SHORT[it.slot] : this.typeName(it), `${m.rarity} ${RARITY_MARK[m.rarity]}`, it.gear ? `Lv ~${it.level}` : '', `sells ${m.sell}g`].filter(Boolean).join(' · '))}${own ? ` · <b>${own.worn ? 'worn' : `you have ${own.n}`}</b>` : ''}</div>
      ${it.gear ? `<div class="at-stats">${esc(statText(it.stats))}</div>` : ''}</div></div>`);
    if (m.lore) parts.push(`<p class="at-lore">${esc(m.lore)}</p>`);
    if (it.weaponKind) parts.push(`<p class="at-effect">${esc(this.weaponEffect(id))}</p>`);

    if (it.gear) {
      const band = fitBand(id, this.disc);
      const v = this.verdict(id);
      const dropAt = all.find((s) => s.area && s.ilvlSource);
      const pot = rollPotential(id, this.disc, dropAt?.area && dropAt.ilvlSource ? itemLevelAt(AREAS[dropAt.area].level, dropAt.ilvlSource) : 20);
      const roll = pot ? `<p class="at-roll">The roll matters more than the label: this piece alone adds about <b>+${pot.plain}%</b>; with two <b>ideal</b> affix rolls at item level ${pot.ilvl} (${pot.picks.map((p) => esc(p.text)).join(', ')}) it adds about <b>+${pot.ideal}%</b>. Affixes roll between the low and high end of their range (${pot.picks.map((p) => esc(p.range)).join(' and ')} here).</p>` : '';
      parts.push(`<section><h4>For you</h4>${band ? `<p><span class="at-fit ${band}">${FIT_LABEL[band]}</span> ${esc(this.fitTitle(id, band))}</p>` : ''}${v ? `<p>${this.arrow(v)} ${esc(v.text)}</p>` : own?.worn ? '<p>You are wearing this.</p>' : ''}${roll}${this.fitBars(id)}</section>`);
    }

    // Where it comes from.
    const drops = all.filter((s) => s.kind !== 'salvage');
    const srcRow = (s: DropSource) => `<tr><td>${esc(shortPlace(s))}</td><td>${esc(shortEvent(s.event))}${s.note ? ` <span class="at-faint">(${esc(s.note)})</span>` : ''}</td><td class="n">${fmtChance(s.chance)}${oneIn(s.chance) ? `<small>${oneIn(s.chance)}</small>` : ''}</td><td class="n">${fmtQty(s.qty)}</td></tr>`;
    if (drops.length) {
      const head = '<table class="at-table"><thead><tr><th>Where</th><th>When</th><th class="n">Chance</th><th class="n">Qty</th></tr></thead><tbody>';
      const shown = this.allSources ? drops : drops.slice(0, 8);
      parts.push(`<section><h4>Where it drops</h4>${head}${shown.map(srcRow).join('')}</tbody></table>${drops.length > 8 ? `<button class="at-more" data-more>${this.allSources ? 'Show fewer' : `Show all ${drops.length} sources`}</button>` : ''}${it.rarity === 'legendary' && it.setId ? `<p class="at-faint">Smart loot: your own discipline's set is ${this.disc && legendarySetFor(this.disc) ? 'the most likely to drop' : 'not made yet, so all four sets share the drops evenly'}.</p>` : ''}</section>`);
    } else if (!(atlas.madeBy.get(id)?.length)) {
      parts.push('<section><h4>Where it drops</h4><p class="at-faint">Not a drop. See salvage or crafting below.</p></section>');
    }

    if (isRuneId(id)) {
      const r = RUNES[id];
      parts.push(`<section><h4>Using it</h4><p>Open the Grimoire (<kbd>L</kbd>), pick <b>${esc(ABILITIES[r.rite].name)}</b> and socket it. Every necromancer rite already has its socket from the start: runes are what you hunt for, from elites, Grave Surges, bosses and Catacomb Depths chests. ${esc(r.short)}.</p></section>`);
    }

    // How to make it (one level deep).
    const made = atlas.madeBy.get(id) ?? [];
    if (made.length) parts.push(`<section><h4>How to make it</h4>${made.map((r) => this.recipeHtml(r)).join('')}</section>`);
    const used = atlas.usedIn.get(id) ?? [];
    if (used.length) parts.push(`<section><h4>Used in</h4><div class="at-links">${used.slice(0, 14).map((r) => `<button data-go="${r.result}">${esc(ITEMS[r.result]?.name ?? r.result)}</button>`).join('')}${used.length > 14 ? `<span class="at-faint">+${used.length - 14} more</span>` : ''}</div></section>`);

    // The Sexton's orders (Contracts, O): where gems, fragments, seals and smelted goods go.
    const order = !it.gear ? orderInfo(id) : null;
    if (order && (order.relicQty || id.startsWith('ingot_'))) {
      const what = order.relicQty ? `A relic order asks for ${order.relicQty} (about one hard order in five, from ${skillName(order.skill)} ${order.level}) and pays ${RELIC_PREMIUM}x the sell price.` : `Ordered like any smelted good, from ${skillName(order.skill)} ${order.level}.`;
      parts.push(`<section><h4>Sexton’s orders</h4><p>${esc(what)}</p></section>`);
    }

    // Salvage.
    if (it.gear || m.type === 'rune') {
      const p = salvagePreview({ id, item_type: m.type, rarity: m.rarity });
      parts.push(`<section><h4>If you salvage it</h4><p>${p.materials.length ? `${p.materials.map((x) => esc(ITEMS[x]?.name ?? x)).join(' or ')} x${fmtQty(p.materialQty)}; ` : ''}${p.reagents.map((r) => `${esc(ITEMS[r.id]?.name ?? r.id)} ${fmtChance(r.chance)}`).join(', ')}. ${p.xp} Salvaging XP.</p></section>`);
    }

    // Upgrading.
    if (it.gear) parts.push(this.upgradeHtml(id, drops));

    // Set.
    if (it.setId) {
      const set = atlas.sets.find((s) => s.id === it.setId)!;
      const worn = set.pieces.filter((p) => this.owned.get(p)?.worn).length;
      parts.push(`<section><h4>${esc(set.name)} set (${worn}/5 worn)</h4><div class="at-links">${set.pieces.map((p) => `<button data-go="${p}" class="${p === id ? 'on' : ''}${this.owned.get(p) ? ' have' : ''}">${esc(ITEMS[p].name)}${this.owned.get(p) ? ' ✓' : ''}</button>`).join('')}</div>${set.bonuses.map((b) => `<div class="at-bonus${worn >= b.pieces ? ' on' : ''}"><span class="n">${b.pieces}</span><span>${b.name ? `<b>${esc(b.name)}</b>: ` : ''}${esc(b.lines.join('; '))}</span></div>`).join('')}</section>`);
    }
    d.innerHTML = parts.join('');
  }

  private weaponEffect(id: string): string {
    return NECRO_WEAPONS.find((w) => w.id === id)?.effect ?? '';
  }

  private fitBars(id: string): string {
    const t = fitTable(id);
    const max = Math.max(1, ...Object.values(t));
    const rows = (Object.keys(DISCIPLINES) as DisciplineId[]).map((d) => `<div class="at-bar${d === this.disc ? ' me' : ''}"><span>${esc(DISCIPLINES[d].name)}</span><i style="width:${Math.max(0, Math.round((t[d] / max) * 100))}%"></i><b>${t[d] >= 0 ? '+' : ''}${t[d]}%</b></div>`).join('');
    return `<details class="at-fitbars"><summary>Fit by discipline (power added to an empty slot)</summary>${rows}</details>`;
  }

  private recipeHtml(r: RecipeInfo): string {
    const atlas = getAtlas();
    const ing = r.ings.map((i) => {
      const s = sourcesFor(i.item, this.disc).filter((x) => x.kind !== 'salvage' && x.kind !== 'depths').slice(0, 2).map((x) => `${shortPlace(x)} ${fmtChance(x.chance)}`);
      const via = (atlas.madeBy.get(i.item) ?? [])[0];
      const from = [...s, ...(via ? [`made: ${skillName(via.profession)} ${via.level}`] : [])].join(' · ') || 'see its page';
      return `<li><button data-go="${i.item}">${i.qty} x ${esc(ITEMS[i.item]?.name ?? i.item)}</button><span class="at-faint"> from ${esc(from)}</span></li>`;
    }).join('');
    return `<div class="at-recipe"><div><b>${esc(r.name)}</b> <span class="at-faint">${skillName(r.profession)} ${r.level} · ${esc(r.station)}${r.qty > 1 ? ` · makes ${r.qty}` : ''}</span></div><ul>${ing}</ul></div>`;
  }

  private upgradeHtml(id: string, drops: DropSource[]): string {
    const it = getAtlas().items.get(id)!;
    const top = drops.find((s) => s.area && s.ilvlSource);
    const lines: string[] = [];
    if (top?.area && top.ilvlSource) {
      lines.push(`Dropped from ${esc(shortPlace(top))} it is item level about <b>${itemLevelAt(AREAS[top.area].level, top.ilvlSource)}</b> (${SOURCE_LABEL[top.ilvlSource].toLowerCase()}). Higher level means bigger affix numbers.`);
    }
    const rows = (['elite', 'boss', 'first_kill'] as const).map((s) => {
      const o = affixCountOdds(it.rarity, s);
      return `<tr><td>${s === 'elite' ? 'Kill or elite' : s === 'boss' ? 'Boss kill' : 'First kill'}</td>${o.map((x) => `<td class="n">${fmtChance(x)}</td>`).join('')}</tr>`;
    }).join('');
    return `<section><h4>Upgrading it</h4><p>${lines.join(' ')} Each drop rolls up to three affixes; bosses always give one or more and a first kill two or more. Odds of 0 / 1 / 2 / 3 affixes for a ${it.rarity} base:</p>
      <table class="at-table"><thead><tr><th>Dropped as</th><th class="n">0</th><th class="n">1</th><th class="n">2</th><th class="n">3</th></tr></thead><tbody>${rows}</tbody></table>
      <p class="at-faint">Wear two, four or five pieces of a set for its bonuses. There is no upgrade bench: replace a piece when a better roll or set drops.</p></section>`;
  }

  // --- events ---------------------------------------------------------------------------------------------------------------------

  private onClick(e: Event) {
    const t = e.target as HTMLElement;
    const btn = t.closest<HTMLElement>('button');
    if (!btn) return;
    if (btn.dataset.id) { this.select(btn.dataset.id); return; }
    if (btn.dataset.go) { this.allSources = false; this.select(btn.dataset.go); return; }
    if (btn.dataset.back !== undefined) {
      const prev = this.trail.pop();
      if (prev) this.select(prev, false);
      else { this.sel = null; this.el!.classList.remove('detail-open'); this.el!.querySelectorAll('.at-row.sel').forEach((r) => r.classList.remove('sel')); this.renderDetail(); }
      return;
    }
    if (btn.dataset.more !== undefined) { this.allSources = !this.allSources; this.renderDetail(); return; }
    if (btn.dataset.slot) { memory.slot = btn.dataset.slot as EquipSlot; this.renderList(); return; }
    if (btn.dataset.mats) { memory.mats = btn.dataset.mats as MatsKind; this.renderList(); return; }
  }

  private onChange(e: Event) {
    const t = e.target as HTMLElement;
    if (t instanceof HTMLSelectElement && t.dataset.where !== undefined) { memory.where = t.value; this.renderList(); }
    else if (t instanceof HTMLSelectElement && t.dataset.set !== undefined) { memory.set = t.value; this.renderList(); }
    else if (t instanceof HTMLInputElement && t.dataset.reach !== undefined) { memory.reach = t.checked; this.renderList(); }
  }
}
