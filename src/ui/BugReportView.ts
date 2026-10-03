import { getMyBugReports, sendBugReport, type BugCategory, type MyBugReport } from '../net/api';
import { recentClientErrors } from '../net/errorRing';

/** What the report form attaches on its own, so a player only has to describe what happened. */
export interface BugReportContext {
  characterId: number;
  area: string;
  level: number;
  discipline: string;
  release: string | null;
  coop: boolean;
}

const CATEGORIES: [BugCategory, string][] = [
  ['bug', 'Something broke'],
  ['combat', 'Combat or thralls'],
  ['ui', 'Menus and interface'],
  ['performance', 'Lag or stutter'],
  ['balance', 'Too hard / too easy'],
  ['other', 'Something else'],
];
const MIN = 10;
const MAX = 2000;

/**
 * Settings → Report a bug. Renders into the Settings panel body (so the panel's open/close and key handling stay as they are),
 * sends the report with its context, and lists the player's recent reports with the status the bug-report agent gave them.
 */
export class BugReportView {
  constructor(
    private host: HTMLElement,
    private context: () => BugReportContext,
    private onBack: () => void,
  ) {}

  render() {
    this.host.innerHTML = `
      <div class="cw-settings cw-bugreport">
        <section class="cw-settings-section"><h3>Report a bug</h3>
        <p class="cw-settings-note">Tell us what went wrong, where you were and what you expected. Your area, level, discipline and game version are attached for you. Reports are read every day.</p>
        <label class="row">Kind of problem
          <select data-cat>${CATEGORIES.map(([v, label]) => `<option value="${v}">${label}</option>`).join('')}</select></label>
        <textarea data-msg rows="6" maxlength="${MAX}" aria-label="Describe the problem" placeholder="e.g. After I travelled to the Graves my thralls stopped following me until I relogged."></textarea>
        <div class="cw-bugreport-actions">
          <span class="cw-hint-text" data-count>0 / ${MAX}</span>
          <button type="button" class="cw-button" data-back>Back</button>
          <button type="button" class="cw-button" data-send disabled>Send report</button>
        </div>
        <p class="cw-settings-note" data-result role="status" aria-live="polite"></p>
        </section>
        <section class="cw-settings-section"><h3>Your reports</h3>
        <ul class="cw-bugreport-list" data-list><li class="cw-hint-text">Loading…</li></ul>
        </section>
      </div>`;
    const msg = this.host.querySelector<HTMLTextAreaElement>('[data-msg]')!;
    const cat = this.host.querySelector<HTMLSelectElement>('[data-cat]')!;
    const send = this.host.querySelector<HTMLButtonElement>('[data-send]')!;
    const count = this.host.querySelector<HTMLElement>('[data-count]')!;
    const result = this.host.querySelector<HTMLElement>('[data-result]')!;
    const sync = () => {
      const n = msg.value.trim().length;
      count.textContent = `${msg.value.length} / ${MAX}`;
      send.disabled = n < MIN;
    };
    msg.addEventListener('input', sync);
    this.host.querySelector('[data-back]')!.addEventListener('click', () => this.onBack());
    send.addEventListener('click', async () => {
      send.disabled = true;
      result.textContent = 'Sending…';
      const c = this.context();
      try {
        await sendBugReport({
          category: cat.value as BugCategory,
          message: msg.value.trim(),
          characterId: c.characterId,
          context: {
            area: c.area,
            level: c.level,
            discipline: c.discipline,
            release: c.release ?? 'unknown',
            coop: c.coop,
            viewport: `${window.innerWidth}x${window.innerHeight}@${window.devicePixelRatio}`,
            userAgent: navigator.userAgent,
            errors: recentClientErrors(),
          },
        });
        msg.value = '';
        sync();
        result.textContent = 'Thank you — your report was sent. Check back here for its status.';
        void this.loadList();
      } catch (err) {
        result.textContent = err instanceof Error ? err.message : 'The report could not be sent.';
        sync();
      }
    });
    void this.loadList();
    msg.focus();
  }

  private async loadList() {
    const list = this.host.querySelector<HTMLUListElement>('[data-list]');
    if (!list) return;
    let reports: MyBugReport[];
    try {
      reports = await getMyBugReports();
    } catch {
      list.innerHTML = '<li class="cw-hint-text">Your reports could not be loaded.</li>';
      return;
    }
    if (!list.isConnected) return;
    list.replaceChildren();
    if (!reports.length) {
      list.innerHTML = '<li class="cw-hint-text">No reports yet.</li>';
      return;
    }
    // Player text and agent notes go in as textContent, never as HTML.
    for (const r of reports) {
      const li = document.createElement('li');
      const head = document.createElement('div');
      const status = document.createElement('b');
      status.textContent = r.status;
      const date = document.createElement('span');
      date.className = 'cw-hint-text';
      date.textContent = ` · ${new Date(r.createdAt).toLocaleDateString()}`;
      head.append(status, date);
      const text = document.createElement('p');
      text.textContent = r.message;
      li.append(head, text);
      if (r.note) {
        const note = document.createElement('p');
        note.className = 'cw-bugreport-note';
        note.textContent = r.note;
        li.append(note);
      }
      list.append(li);
    }
  }
}
