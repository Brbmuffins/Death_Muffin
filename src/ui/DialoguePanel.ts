import { LABEL, TOPICS, adviceLines, farewell, greetingLines, topicLines } from '../content/dialogue';
import { NPCS, type NpcId } from '../content/npcs';
import type { Guidance, GuidanceState } from '../gameplay/guidance';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

type Node = { kind: 'greet' | 'advice' | 'menu' | 'about' | 'bye' } | { kind: 'topic'; id: string };

/**
 * The conversation card. Non-modal: it sits above the hotbar, never pauses or captures the game, and closes by Esc, by the X,
 * by "Goodbye", by pressing E again, or by walking away (WorldScene checks the distance). Text comes from content/dialogue.ts and
 * is escaped; the buttons are the whole interface, two to four at a time.
 */
export class DialoguePanel {
  private el: HTMLDivElement | null = null;
  private npc: NpcId | null = null;
  private node: Node = { kind: 'greet' };
  private lines: string[] = [];

  constructor(
    private root: HTMLElement,
    private guidance: Guidance,
    private stateNow: () => GuidanceState,
    private hooks: { onChange: (npc: NpcId | null) => void; sound: () => void },
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  get talkingTo() {
    return this.npc;
  }

  open(npc: NpcId) {
    if (this.npc === npc && this.el) return;
    this.close();
    this.npc = npc;
    const s = this.stateNow();
    // Words first (they depend on what was still unheard), then remember that they were said.
    this.lines = greetingLines(npc, s, this.guidance.unheard(npc, s), this.guidance.met(npc));
    this.guidance.told(npc, s);
    this.node = { kind: 'greet' };
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-dialogue';
    this.el.setAttribute('role', 'dialog');
    this.el.setAttribute('aria-label', `Talking with ${NPCS[npc].name}`);
    this.el.style.setProperty('--npc-accent', `#${NPCS[npc].accent.toString(16).padStart(6, '0')}`);
    // Enter / Space on a choice must not also reach the game (Enter opens chat).
    this.el.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') e.stopPropagation();
    });
    this.root.appendChild(this.el);
    this.hooks.onChange(npc);
    this.render();
  }

  close() {
    if (!this.el) return;
    this.el.remove();
    this.el = null;
    this.npc = null;
    this.hooks.onChange(null);
  }

  /** Refresh the words after the world changed under an open conversation (rare; keeps numbers honest). */
  refresh() {
    if (this.el && this.node.kind !== 'greet') this.go(this.node);
  }

  private go(node: Node) {
    const npc = this.npc;
    if (!npc) return;
    const s = this.stateNow();
    this.node = node;
    switch (node.kind) {
      case 'advice':
        this.lines = adviceLines(npc, s);
        break;
      case 'menu':
        this.lines = [{ prior: 'Ask, and I will answer as plainly as I can.', sexton: 'Go on, then. I have all the time the dead do.', apothecary: 'Quickly, before something boils over.' }[npc]];
        break;
      case 'about':
        this.lines = ['What shall I tell you of?'];
        break;
      case 'topic':
        this.lines = topicLines(npc, node.id, s);
        this.guidance.hearTopic(npc, node.id);
        break;
      case 'bye':
        this.lines = [farewell(npc, s)];
        break;
      default:
        break;
    }
    this.render();
  }

  private choices(): { label: string; fresh?: boolean; act: () => void }[] {
    const npc = this.npc!;
    const advice = { label: LABEL.advice[npc], act: () => this.go({ kind: 'advice' }) };
    const about = { label: LABEL.about, act: () => this.go({ kind: 'about' }) };
    const bye = { label: LABEL.bye, act: () => this.close() };
    switch (this.node.kind) {
      case 'greet':
      case 'menu':
        return [advice, about, bye];
      case 'advice':
        return [about, bye];
      case 'about':
        return [
          ...TOPICS[npc].map((t) => ({ label: t.label, fresh: !this.guidance.heardTopic(npc, t.id), act: () => this.go({ kind: 'topic', id: t.id }) })),
          { label: LABEL.back, act: () => this.go({ kind: 'menu' }) },
        ];
      case 'topic':
        return [advice, { label: 'Tell me of something else', act: () => this.go({ kind: 'about' }) }, bye];
      default:
        return [bye];
    }
  }

  private render() {
    if (!this.el || !this.npc) return;
    const def = NPCS[this.npc];
    const choices = this.choices();
    this.el.innerHTML = `
      <div class="hd"><div><div class="nm">${esc(def.name)}</div><div class="ti">${esc(def.title)}</div></div><button type="button" class="x" data-x aria-label="End conversation" title="End conversation (Esc)">×</button></div>
      <div class="say" aria-live="polite">${this.lines.map((l) => `<p>${esc(l)}</p>`).join('')}</div>
      <div class="ch">${choices.map((c, i) => `<button type="button" class="choice${c.fresh ? ' fresh' : ''}" data-c="${i}">${esc(c.label)}</button>`).join('')}</div>`;
    this.el.querySelector<HTMLButtonElement>('[data-x]')!.addEventListener('click', () => { this.hooks.sound(); this.close(); });
    this.el.querySelectorAll<HTMLButtonElement>('[data-c]').forEach((b) =>
      b.addEventListener('click', () => {
        this.hooks.sound();
        choices[Number(b.dataset.c)].act();
      }),
    );
  }
}
