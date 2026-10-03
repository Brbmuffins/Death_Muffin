/**
 * The one load screen: shown when the world mounts (after picking a character) while the starting area and its neighbours are built and
 * warmed, then faded away. Nowhere else in normal play: door walks, waystones, recall and the Depths stream in the background instead.
 * Keys are held back while it is up so a hero cannot be steered blind; the co-op sim is untouched.
 */
import { dismissSplash, splashArtAttrs } from './splash';

/** Pure: the label for a progress fraction. */
export function veilLabel(f: number): string {
  if (f < 0.34) return 'Lighting the braziers';
  if (f < 0.67) return 'Raising the walls';
  if (f < 1) return 'Laying out the dead';
  return 'The Covenant is ready';
}

export class LoadVeil {
  private el: HTMLDivElement;
  private bar: HTMLDivElement;
  private label: HTMLDivElement;
  private blockKeys = (e: KeyboardEvent) => {
    e.stopImmediatePropagation();
    e.preventDefault();
  };
  private done = false;

  constructor() {
    this.el = document.createElement('div');
    this.el.className = 'dm-splash dm-loadveil';
    this.el.setAttribute('role', 'status');
    this.el.setAttribute('aria-live', 'polite');
    // Same markup as the index.html splash (classes live in its inline CSS) so the handoff is invisible.
    const art = document.createElement('img');
    art.className = 'dm-splash-art in';
    art.alt = '';
    const a = splashArtAttrs();
    art.srcset = a.srcset;
    art.sizes = '100vw';
    art.src = a.src;
    const shade = document.createElement('div');
    shade.className = 'dm-splash-shade';
    const copy = document.createElement('div');
    copy.className = 'dm-splash-copy';
    const title = document.createElement('div');
    title.className = 'dm-splash-title';
    title.textContent = 'Death Muffin';
    const tag = document.createElement('p');
    tag.className = 'dm-splash-tag';
    tag.textContent = veilLabel(0);
    this.label = tag; // the italic line under the title carries the progress wording
    const status = document.createElement('div');
    status.className = 'dm-splash-status';
    status.textContent = 'Opening the Covenant';
    const track = document.createElement('div');
    track.className = 'dm-splash-track';
    this.bar = document.createElement('div');
    this.bar.className = 'dm-splash-bar';
    track.appendChild(this.bar);
    copy.append(title, tag, track, status);
    this.el.append(art, shade, copy);
    document.body.appendChild(this.el);
    dismissSplash(); // the veil (same art) now covers the screen; the page splash, if still up, can go
    window.addEventListener('keydown', this.blockKeys, true);
    window.addEventListener('keyup', this.blockKeys, true);
  }

  progress(f: number) {
    if (this.done) return;
    const k = Math.max(0, Math.min(1, f));
    this.bar.style.transform = `scaleX(${k})`;
    this.label.textContent = veilLabel(k);
  }

  /** Fade out and remove. Safe to call twice. */
  finish() {
    if (this.done) return;
    this.done = true;
    this.bar.style.transform = 'scaleX(1)';
    window.removeEventListener('keydown', this.blockKeys, true);
    window.removeEventListener('keyup', this.blockKeys, true);
    this.el.classList.add('out');
    window.setTimeout(() => this.el.remove(), 450);
  }

  dispose() {
    this.done = true;
    window.removeEventListener('keydown', this.blockKeys, true);
    window.removeEventListener('keyup', this.blockKeys, true);
    this.el.remove();
  }
}
