/**
 * Collects teardown callbacks so a scene can't leak listeners, timers, or
 * subscriptions. Every scene owns one Scope and disposes it on unmount.
 */
export class Scope {
  private disposers: (() => void)[] = [];
  private disposed = false;

  add(fn: () => void) {
    if (this.disposed) {
      fn();
      return;
    }
    this.disposers.push(fn);
  }

  on<E extends Event>(
    target: EventTarget,
    type: string,
    fn: (e: E) => void,
    opts?: AddEventListenerOptions,
  ) {
    target.addEventListener(type, fn as EventListener, opts);
    this.add(() => target.removeEventListener(type, fn as EventListener, opts));
  }

  timeout(fn: () => void, ms: number) {
    const id = window.setTimeout(fn, ms);
    this.add(() => window.clearTimeout(id));
    return id;
  }

  interval(fn: () => void, ms: number) {
    const id = window.setInterval(fn, ms);
    this.add(() => window.clearInterval(id));
    return id;
  }

  get isDisposed() {
    return this.disposed;
  }

  dispose() {
    this.disposed = true;
    for (const d of this.disposers.splice(0).reverse()) {
      try {
        d();
      } catch (err) {
        console.warn('[scope] disposer failed', err);
      }
    }
  }
}
