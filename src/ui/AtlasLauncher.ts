import type { AtlasDeps } from './AtlasPanel';

/**
 * The Gear Atlas's doorway, the only part of it in the main bundle: a few lines that fetch the panel's own chunk (code, CSS and the
 * atlas data) the first time it is opened. Nothing of the Atlas exists, runs or is parsed until then, and nothing runs per frame.
 */
interface Opened {
  isOpen: boolean;
  open(): void;
  close(): void;
}

export class AtlasLauncher {
  private panel: Opened | null = null;
  private loading = false;

  constructor(
    private root: HTMLElement,
    private deps: AtlasDeps,
    private onFail?: () => void,
  ) {}

  get isOpen(): boolean {
    return this.loading || !!this.panel?.isOpen;
  }

  open() {
    if (this.isOpen) return;
    this.loading = true;
    import('./AtlasPanel')
      .then((m) => {
        if (!this.loading) return; // closed again before it arrived
        this.loading = false;
        this.panel ??= new m.AtlasPanel(this.root, this.deps);
        this.panel.open();
      })
      .catch(() => {
        this.loading = false;
        this.onFail?.();
      });
  }

  close() {
    this.loading = false;
    this.panel?.close();
  }
}
