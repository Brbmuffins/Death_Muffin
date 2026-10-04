/**
 * The instant splash lives in index.html (painted before any module loads). Scenes call dismissSplash() once their own UI is on screen:
 * the first one to do so fades it out. The in-game LoadVeil wears the same art and classes, so the world mount looks like the same screen.
 */
export function dismissSplash(): void {
  const el = document.getElementById('dm-splash');
  if (!el || el.classList.contains('out')) return;
  // Two frames: let the scene's first frame paint under the splash so the fade never reveals a blank canvas.
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      el.classList.add('out');
      window.setTimeout(() => el.remove(), 500);
    }),
  );
}

/** Same art as the splash, sized from the deploy base (works under /death-muffin/play/ and /death-muffin/offline/). */
export function splashArtAttrs(): { src: string; srcset: string } {
  const b = import.meta.env.BASE_URL;
  return { src: `${b}art/loading/keyart-1600.webp`, srcset: `${b}art/loading/keyart-960.webp 960w, ${b}art/loading/keyart-1600.webp 1600w` };
}
