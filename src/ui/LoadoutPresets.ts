import { ABILITIES } from '../content/abilities';
import { RUNES, RUNE_RITES, type RuneId, type RuneRite } from '../content/runes';
import { MAX_PRESETS, NAME_MAX, cleanName, type ApplyReport, type LoadoutPreset } from '../gameplay/loadoutRules';
import './loadouts.css';

const esc = (x: string) => x.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

export interface LoadoutRow {
  slot: number;
  preset: LoadoutPreset;
}

/** The part of a preset the player can change by hand (the name is not part of "what is equipped"). */
export type LoadoutBody = Omit<LoadoutPreset, 'name'>;

/** Everything the section needs from the game: where presets live, what is equipped now, and how to put a preset on. */
export interface LoadoutHost {
  list(): Promise<LoadoutRow[]>;
  save(slot: number, preset: LoadoutPreset): Promise<LoadoutRow[]>;
  remove(slot: number): Promise<LoadoutRow[]>;
  current(): LoadoutBody;
  /** Put the preset on; resolves with player-readable lines about anything skipped (empty when everything went on). Rejects with a readable error. */
  apply(slot: number, preset: LoadoutPreset): Promise<string[]>;
  itemName(itemId: string): string;
  /** The hotkey bound to this slot ("Loadout N"), as the player reads it, or null. */
  keyFor?(slot: number): string | null;
  /** The "Next loadout" key, or null. */
  nextKey?(): string | null;
}

const riteName = (id: string) => (ABILITIES as Record<string, { name: string } | undefined>)[id]?.name ?? id;

/** Plain-language lines for a server report: what could not go on, and why. Exported for the tests. */
export function reportLines(report: ApplyReport, itemName: (id: string) => string): string[] {
  const lines: string[] = [];
  for (const s of report.skipped) {
    const what = s.itemId ? (s.part === 'rune' ? RUNES[s.itemId as RuneId]?.name ?? itemName(s.itemId) : itemName(s.itemId)) : '';
    const where = s.part === 'rune' && s.rite ? ` for ${riteName(s.rite)}` : '';
    if (s.part === 'rune' && !s.itemId) lines.push(`${riteName(s.rite!)} still holds its rune: your bag is full, so it has nowhere to go.`);
    else if (s.reason === 'missing') lines.push(`${what}${where} is not in your bag (sold, ground, or resting in the Vault), so it was left out.`);
    else if (s.reason === 'no_room') lines.push(s.part === 'rune' ? `${what}${where} was not set: the rune it replaces needs a free bag slot.` : `${what} was not worn: swapping it needs more free bag slots.`);
    else lines.push(`${what} does not fit that slot and was left out.`);
  }
  return lines;
}

/** Same rites, runes and worn pieces? Used to mark the loadout that is on right now. */
export function sameLoadout(a: LoadoutBody, b: LoadoutBody): boolean {
  const g = (x: LoadoutBody['weapon']) => (x ? `${x.itemId}#${x.instanceId ?? ''}` : '');
  if (a.rites.primary !== b.rites.primary || a.rites.keys.join() !== b.rites.keys.join()) return false;
  if (RUNE_RITES.some((r) => (a.runes[r] ?? null) !== (b.runes[r] ?? null))) return false;
  // A hand the preset left empty (null) does not count against it; the one it names must be the one worn.
  return (!a.weapon || g(a.weapon) === g(b.weapon)) && (!a.offhand || g(a.offhand) === g(b.offhand));
}

/**
 * The Loadouts strip of the Grimoire: up to six named presets of rites + runes + worn weapon and off-hand. Self-contained: GrimoirePanel only
 * hands it an element (`mount`) every time it redraws; the presets are cached here so a redraw is instant.
 */
export class LoadoutPresets {
  private rows: LoadoutRow[] | null = null;
  private loadError = '';
  private msg = '';
  private busy = false;
  private el: HTMLElement | null = null;
  /** The card being named: a new slot, or an existing one being renamed. */
  private naming: { slot: number; rename: boolean } | null = null;
  private confirmDelete: number | null = null;

  constructor(private host: LoadoutHost) {}

  /** Forget the cache (a different character, or a server round trip we should re-read). */
  reset() {
    this.rows = null;
  }

  count() {
    return this.rows?.length ?? 0;
  }

  mount(el: HTMLElement) {
    this.el = el;
    el.addEventListener('click', (e) => void this.onClick(e));
    el.addEventListener('submit', (e) => {
      e.preventDefault();
      void this.submitName();
    });
    this.draw();
    if (this.rows === null) void this.load();
  }

  private async load() {
    try {
      this.rows = await this.host.list();
      this.loadError = '';
    } catch (e) {
      this.rows = [];
      this.loadError = e instanceof Error ? e.message : 'Your loadouts could not be read.';
    }
    this.draw();
  }

  private draw() {
    const el = this.el;
    if (!el || !el.isConnected) return;
    const rows = this.rows;
    if (rows === null) {
      el.innerHTML = `<div class="cw-lo"><h3>Loadouts</h3><p class="cw-lo-note">Reading your loadouts…</p></div>`;
      return;
    }
    const now = this.host.current();
    const cards = rows.map((r) => this.card(r, now));
    const free = Array.from({ length: MAX_PRESETS }, (_, i) => i).find((i) => !rows.some((r) => r.slot === i));
    if (free !== undefined) cards.push(this.naming && this.naming.slot === free && !this.naming.rename ? this.nameForm(free, `Loadout ${free + 1}`) : `<div class="cw-lo-card empty"><button type="button" class="cw-button small" data-act="new" data-slot="${free}" ${this.busy ? 'disabled' : ''}>＋ Save what I have now</button></div>`);
    el.innerHTML = `<div class="cw-lo">
      <h3>Loadouts <small>rites, runes and weapons together · ${rows.length}/${MAX_PRESETS}${this.host.nextKey?.() ? ` · next: <kbd class="key">${esc(this.host.nextKey()!)}</kbd>` : ''}</small></h3>
      ${rows.length === 0 ? '<p class="cw-lo-note">Set up your five rites, your runes and your weapon, then save it here. One click brings it all back.</p>' : ''}
      <div class="cw-lo-grid">${cards.join('')}</div>
      <div class="cw-lo-msg" role="status" aria-live="polite">${esc(this.loadError || this.msg)}</div>
    </div>`;
    el.querySelector<HTMLInputElement>('input[name="n"]')?.focus();
  }

  private nameForm(slot: number, value: string) {
    return `<form class="cw-lo-card editing" data-slot="${slot}"><label>Name <input name="n" maxlength="${NAME_MAX}" value="${esc(value)}" autocomplete="off" spellcheck="false" /></label>
      <div class="act"><button type="submit" class="cw-button small">Save</button><button type="button" class="cw-button small" data-act="cancel">Cancel</button></div></form>`;
  }

  private card(r: LoadoutRow, now: LoadoutBody) {
    const p = r.preset;
    if (this.naming && this.naming.slot === r.slot && this.naming.rename) return this.nameForm(r.slot, p.name);
    const active = sameLoadout(p, now);
    const rites = [p.rites.primary, ...p.rites.keys].map((id) => `<img src="${ABILITIES[id as keyof typeof ABILITIES]?.icon ?? ''}" alt="${esc(riteName(id))}" title="${esc(riteName(id))}" draggable="false" />`).join('');
    const runes = RUNE_RITES.filter((rite) => p.runes[rite]).map((rite: RuneRite) => `<img class="rune" src="art/items/${p.runes[rite]}.webp" alt="${esc(RUNES[p.runes[rite]!].name)}" title="${esc(`${riteName(rite)}: ${RUNES[p.runes[rite]!].name}`)}" draggable="false" />`).join('');
    // A hand saved empty is left as it is on apply, and the card says so.
    const hand = (label: string, g: typeof p.weapon) => `${label}: ${g ? esc(this.host.itemName(g.itemId)) : '<i>keep current</i>'}`;
    const gear = `${hand('Main hand', p.weapon)} · ${hand('Off-hand', p.offhand)}`;
    const key = this.host.keyFor?.(r.slot);
    const dis = this.busy ? 'disabled' : '';
    const del = this.confirmDelete === r.slot;
    return `<div class="cw-lo-card${active ? ' active' : ''}" data-slot="${r.slot}">
      <div class="nm">${esc(p.name)}${active ? ' <span class="tag">on now</span>' : ''}${key ? ` <kbd class="key" title="Hotkey (change it in Settings)">${esc(key)}</kbd>` : ''}</div>
      <div class="ic">${rites}<span class="sep"></span>${runes || '<span class="none">no runes</span>'}</div>
      <div class="gear">${gear}</div>
      <div class="act">
        <button type="button" class="cw-button small primary" data-act="apply" data-slot="${r.slot}" ${dis || active ? 'disabled' : ''} aria-label="Apply ${esc(p.name)}">${active ? 'Applied' : 'Apply'}</button>
        <button type="button" class="cw-button small" data-act="update" data-slot="${r.slot}" ${dis} title="Overwrite it with what you have on now">Update</button>
        <button type="button" class="cw-button small" data-act="rename" data-slot="${r.slot}" ${dis}>Rename</button>
        <button type="button" class="cw-button small${del ? ' danger' : ''}" data-act="${del ? 'delete-yes' : 'delete'}" data-slot="${r.slot}" ${dis}>${del ? 'Really delete?' : 'Delete'}</button>
      </div></div>`;
  }

  private async onClick(e: Event) {
    const b = (e.target as HTMLElement).closest<HTMLButtonElement>('[data-act]');
    if (!b || b.disabled || this.busy) return;
    e.stopPropagation();
    const slot = Number(b.dataset.slot);
    const row = this.rows?.find((r) => r.slot === slot);
    this.msg = '';
    switch (b.dataset.act) {
      case 'new':
        this.naming = { slot, rename: false };
        this.confirmDelete = null;
        return this.draw();
      case 'rename':
        this.naming = { slot, rename: true };
        this.confirmDelete = null;
        return this.draw();
      case 'cancel':
        this.naming = null;
        return this.draw();
      case 'delete':
        this.confirmDelete = slot;
        return this.draw();
      case 'delete-yes':
        this.confirmDelete = null;
        return this.run(async () => {
          this.rows = await this.host.remove(slot);
          this.msg = 'Loadout deleted.';
        });
      case 'update':
        if (!row) return;
        return this.run(async () => {
          this.rows = await this.host.save(slot, { ...this.host.current(), name: row.preset.name });
          this.msg = `${row.preset.name} now holds what you have on.`;
        });
      case 'apply':
        if (!row) return;
        return this.run(async () => {
          const lines = await this.host.apply(slot, row.preset);
          this.msg = lines.length ? `${row.preset.name} is on, except: ${lines.join(' ')}` : `${row.preset.name} is on.`;
        });
    }
  }

  private async submitName() {
    const n = this.naming;
    const input = this.el?.querySelector<HTMLInputElement>('input[name="n"]');
    if (!n || !input) return;
    const name = cleanName(input.value);
    if (!name) {
      this.msg = 'Give the loadout a name.';
      return this.draw();
    }
    const row = this.rows?.find((r) => r.slot === n.slot);
    this.naming = null;
    await this.run(async () => {
      this.rows = await this.host.save(n.slot, n.rename && row ? { ...row.preset, name } : { ...this.host.current(), name });
      this.msg = n.rename ? 'Renamed.' : `${name} saved.`;
    });
  }

  private async run(fn: () => Promise<void>) {
    this.busy = true;
    this.draw();
    try {
      await fn();
    } catch (e) {
      this.msg = e instanceof Error ? e.message : 'That did not work.';
    } finally {
      this.busy = false;
      this.draw();
    }
  }
}
