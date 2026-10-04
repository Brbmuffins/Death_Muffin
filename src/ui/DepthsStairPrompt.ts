import { wrapPanelBody } from './panelBody';

/**
 * The Warren stair's choice once the hero has been below depth 1: go down from the start, or resume at the deepest floor on record.
 * One click either way. The depth is offered by DepthsController.resumeAt (the Chronicle's `peak.depth`); this card only asks.
 */
export class DepthsStairPrompt {
  private el: HTMLDivElement | null = null;

  constructor(
    private root: HTMLElement,
    private onPick: (depth: number) => void,
  ) {}

  get isOpen() {
    return this.el !== null;
  }

  open(deepest: number) {
    this.close();
    const el = (this.el = document.createElement('div'));
    el.className = 'cw-plate cw-panel-float cw-depthsstair';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-label', 'Descend into the Catacomb Depths');
    el.innerHTML = `
      <div class="cw-panel-head">
        <h2 class="cw-title">The Stair Down</h2>
        <button class="cw-icon-btn" data-close aria-label="Close">✕</button>
      </div>
      <p class="cw-hint-text">Your deepest descent is <b>depth ${deepest}</b>. Where do you go down?</p>
      <button class="cw-button primary cw-depthsstair-go" data-pick="${deepest}">Resume at depth ${deepest} <small>Pick up where you left off; floors past it beat your record.</small></button>
      <button class="cw-button cw-depthsstair-go" data-pick="1">Descend from depth 1 <small>A fresh run from the first floor.</small></button>`;
    wrapPanelBody(el);
    this.root.appendChild(el);
    el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    el.querySelectorAll<HTMLElement>('[data-pick]').forEach((b) =>
      b.addEventListener('click', () => {
        const depth = Number(b.dataset.pick) || 1;
        this.close();
        this.onPick(depth);
      }),
    );
  }

  close() {
    this.el?.remove();
    this.el = null;
  }
}
