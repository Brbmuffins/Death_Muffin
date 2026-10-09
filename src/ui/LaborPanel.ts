import { assignLabor, collectLabor, getInventory, getLabor, type LaborResult, type LaborView } from '../net/api';
import { RARITY_COLOR, itemMeta } from '../../server/rules/content/items';
import type { GatherReport } from '../gameplay/gatherReport';
import { NODES, SKILLS, type SkillId } from '../../server/rules/gameplay/gatheringRules';
import { LABOR, assignBlocker, estimate, postsFor } from '../../server/rules/gameplay/laborRules';
import { durationText } from '../gameplay/gatherReport';
import type { Inventory } from '../gameplay/loot';
import { preserveScroll } from './preserveScroll';
import { wrapPanelBody } from './panelBody';

/** Collections kept in the "Brought home" list (each is one laborer's trip). */
const MAX_LOOT = 12;
const iconOf = (itemId: string) => itemMeta(itemId).icon ?? `art/items/${itemId}.webp`;
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/**
 * Grave Laborers (H): the raised dead work a gathering post for you, slowly, on the server's clock, up to eight hours between
 * collections, whether or not you are playing. Collecting rolls their finds into your bag (and a quarter of the XP into the skill).
 * Sending, recalling and collecting are server actions, so they run under Inventory.exclusive like a craft.
 */
export class LaborPanel {
  private el: HTMLDivElement | null = null;
  private view: LaborView | null = null;
  private skew = 0;
  private error = '';
  private busy = false;
  private tick = 0;
  private off: (() => void) | null = null;
  private pick = new Map<number, string>();
  /** What each collection brought home, newest first. Shown under the laborers so nothing needs a second window; cleared with the window. */
  private loot: { slot: number; report: GatherReport }[] = [];
  /** Told whenever the panel learns a fresh labor view, so the laborers standing in the Acre can follow it. */
  onView: ((v: LaborView) => void) | null = null;

  constructor(
    private root: HTMLElement,
    private characterId: number,
    private inventory: Inventory,
    private levelOf: (skill: SkillId) => number,
    private onCollected: (r: LaborResult, slot: number) => void,
  ) {}

  /** A laborer's collection, as the Ledger would have shown it: listed under the laborers, so the window stays put for the next one. */
  addLoot(slot: number, report: GatherReport) {
    this.loot.unshift({ slot, report });
    this.loot.length = Math.min(this.loot.length, MAX_LOOT);
    this.render();
  }

  get isOpen() {
    return this.el !== null;
  }

  async open() {
    if (this.el) return;
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float wide cw-labor';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', 'Grave Laborers');
    this.root.appendChild(this.el);
    this.off = this.inventory.onChange(() => this.render());
    this.tick = window.setInterval(() => this.tickRender(), 1000);
    this.render();
    await this.refresh();
  }

  private async refresh() {
    try {
      this.set(await getLabor(this.characterId));
      this.error = '';
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'Could not reach the laborers.';
    }
    this.render();
  }

  private set(v: LaborView) {
    this.view = v;
    this.skew = v.now - Date.now();
    this.onView?.(v);
  }

  close() {
    this.off?.();
    this.off = null;
    window.clearInterval(this.tick);
    this.loot = [];
    this.el?.remove();
    this.el = null;
  }

  private levels() {
    const out: Record<string, number> = {};
    for (const s of Object.keys(SKILLS) as SkillId[]) out[s] = this.levelOf(s);
    return out;
  }

  /**
   * The countdown tick. Redrawing replaces the buttons, so a click that starts on one while a redraw lands is lost: skip the redraw
   * while the pointer is over a control or a dropdown is open, and catch up on the next tick.
   */
  private tickRender() {
    if (!this.el || this.el.querySelector('button:hover, select:hover, select:focus, input:hover, input:focus')) return;
    this.render();
  }

  private render() {
    if (!this.el) return;
    const v = this.view;
    const now = Date.now() + this.skew;
    const levels = this.levels();
    const cards = !v
      ? `<p class="cw-hint-text">${this.error ? esc(this.error) : 'Calling the dead…'}</p>`
      : v.slots
          .map((s) => {
            const head = `<div class="hd"><b>Laborer ${s.slot + 1}</b><span class="meta">${s.unlocked ? (s.nodeName ? 'Working' : 'Idle') : 'Locked'}</span></div>`;
            if (!s.unlocked) {
              const need = s.slot * v.levelsPerSlot;
              return `<article class="cw-lab locked">${head}<div class="rw">Raised when your gathering levels total ${need} (now ${v.totalLevel}).</div></article>`;
            }
            if (!s.nodeType) {
              const posts = postsFor(levels);
              const cur = this.pick.get(s.slot) && posts.some((p) => p.id === this.pick.get(s.slot)) ? this.pick.get(s.slot)! : posts[0]?.id ?? '';
              this.pick.set(s.slot, cur);
              const groups = (Object.keys(SKILLS) as SkillId[])
                .filter((k) => posts.some((p) => p.skill === k))
                .map((k) => `<optgroup label="${esc(SKILLS[k].name)}">${posts.filter((p) => p.skill === k).map((p) => `<option value="${p.id}" ${p.id === cur ? 'selected' : ''}>${esc(p.name)} (Lv ${p.level})</option>`).join('')}</optgroup>`)
                .join('');
              const def = NODES[cur];
              const per = def ? estimate(def, levels[def.skill] ?? 1, 3_600_000) : null;
              return `<article class="cw-lab idle">${head}
                <div class="row"><select data-post="${s.slot}" aria-label="Post for laborer ${s.slot + 1}">${groups}</select>
                <button class="cw-button small" data-send="${s.slot}" ${this.busy || !cur ? 'disabled' : ''}>Send to work</button></div>
                ${per ? `<div class="rw">About ${per.items.toLocaleString()} ${esc(itemMeta(def.item).name)} an hour, up to ${LABOR.capMs / 3_600_000} hours.</div>` : ''}</article>`;
            }
            const def = NODES[s.nodeType];
            const elapsed = Math.max(0, Math.min(now - s.startedAt, v.capMs));
            const est = estimate(def, levels[def.skill] ?? 1, elapsed);
            const pct = Math.round((elapsed / v.capMs) * 100);
            const ready = est.actions >= 1;
            return `<article class="cw-lab working ${ready ? 'ready' : ''}">${head}
              <div class="row"><div class="grow"><div class="bar" aria-hidden="true"><i style="width:${pct}%"></i></div>
                <div class="rw">${esc(s.nodeName ?? def.name)} · ${durationText(Math.floor(elapsed / 1000))}${elapsed >= v.capMs ? ' (full)' : ''} · about <b>${est.items.toLocaleString()} ${esc(itemMeta(def.item).name)}</b>, ${est.xp.toLocaleString()} xp</div></div>
                <button class="cw-button small" data-collect="${s.slot}" ${!ready || this.busy ? 'disabled' : ''}>Collect</button>
                <button class="cw-button small" data-recall="${s.slot}" ${this.busy ? 'disabled' : ''} title="Bring them home">Recall</button></div>
            </article>`;
          })
          .join('');
    const panel = this.el;
    preserveScroll(panel, () => { panel.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">Grave Laborers</h2>
        ${v ? `<span class="cw-skill-total">Gathering levels <b>${v.totalLevel}</b></span>` : ''}
        <button class="cw-icon-btn" data-close aria-label="Close laborers">✕</button>
      </div>
      <p class="cw-codex-note">Send the dead to work a post and they keep at it, slowly, for up to eight hours, even while you are away. They gather a fraction of what you would and earn a quarter of the XP. Collect when you like.</p>
      <div class="cw-labs">${cards}</div>
      ${this.lootHtml()}
      <div class="cw-error" data-error>${this.error && v ? esc(this.error) : ''}</div>`; wrapPanelBody(panel); });
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.el.querySelector('[data-clear-loot]')?.addEventListener('click', () => {
      this.loot = [];
      this.render();
    });
    this.el.querySelectorAll<HTMLSelectElement>('[data-post]').forEach((sel) => sel.addEventListener('change', () => {
      this.pick.set(Number(sel.dataset.post), sel.value);
      this.render();
    }));
    this.el.querySelectorAll<HTMLButtonElement>('[data-send]').forEach((b) => b.addEventListener('click', () => void this.act('assign', Number(b.dataset.send))));
    this.el.querySelectorAll<HTMLButtonElement>('[data-recall]').forEach((b) => b.addEventListener('click', () => void this.act('recall', Number(b.dataset.recall))));
    this.el.querySelectorAll<HTMLButtonElement>('[data-collect]').forEach((b) => b.addEventListener('click', () => void this.act('collect', Number(b.dataset.collect))));
  }

  /** The "Brought home" section under the laborers: one card per collection, newest first. */
  private lootHtml(): string {
    if (!this.loot.length) return '';
    const cards = this.loot
      .map(({ slot, report: r }) => {
        const sk = r.skills[0];
        const wins = [...r.milestones, ...r.records].map((w) => `<div class="win">★ ${esc(w)}</div>`).join('');
        const rows = r.items
          .map((i) => `<div class="row"><span style="color:${RARITY_COLOR[i.rarity]}"><img src="${iconOf(i.itemId)}" alt="" onerror="this.style.display='none'" /> ${esc(i.name)}</span><b>×${i.qty.toLocaleString()}</b></div>`)
          .join('');
        const xp = sk ? ` · +${sk.xp.toLocaleString()} ${esc(sk.name)} xp${sk.toLevel > sk.fromLevel ? ` <i>(Lv ${sk.fromLevel} → ${sk.toLevel})</i>` : ''}` : '';
        const gold = r.gold > 0 ? ` · +${r.gold.toLocaleString()}g` : '';
        return `<div class="cw-chron-grp"><h4>Laborer ${slot + 1} · ${r.totalItems.toLocaleString()} finds${xp}${gold}</h4>${wins}${rows}</div>`;
      })
      .join('');
    return `<section class="cw-lab-loot" aria-label="Brought home">
      <div class="cw-lab-loot-head"><h3 class="cw-panel-section-title">Brought home</h3><button class="cw-button small" data-clear-loot>Clear</button></div>
      ${cards}</section>`;
  }

  private async act(kind: 'assign' | 'recall' | 'collect', slot: number) {
    if (this.busy) return;
    this.busy = true;
    this.error = '';
    this.render();
    try {
      let result: LaborResult;
      let staleBag = false;
      if (kind === 'collect') {
        const out = await this.inventory.exclusiveAction(() => collectLabor(this.characterId, slot), () => getInventory(this.characterId));
        result = out.reply;
        if (out.bagStale) staleBag = true;
      } else {
        const post = kind === 'assign' ? this.pick.get(slot) ?? null : null;
        const blocked = post ? assignBlocker(post, this.levels()) : null;
        if (blocked) throw new Error(blocked);
        result = await assignLabor(this.characterId, slot, post);
      }
      this.set(result);
      if (result.collected) this.onCollected(result, slot);
      if (staleBag) this.error = 'Collected, but your bag could not be refreshed. Close and reopen your bag to see it.';
    } catch (err) {
      this.error = err instanceof Error ? err.message : 'The dead do not answer.';
    } finally {
      this.busy = false;
      this.render();
    }
  }
}
