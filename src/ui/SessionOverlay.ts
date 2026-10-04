import { onSessionReplaced } from '../net/session';

/**
 * Blocking notice for a window whose account was opened somewhere else. It covers the game (so nothing more can be played into a save
 * that is refused) and offers one button, "Play here", which claims the session again; the caller reloads so the window starts from
 * what the newer session saved.
 */
export function installSessionOverlay(claim: () => Promise<boolean>) {
  let el: HTMLDivElement | null = null;
  onSessionReplaced(() => {
    if (el) return;
    el = document.createElement('div');
    el.className = 'dm-session-overlay';
    el.setAttribute('role', 'alertdialog');
    el.setAttribute('aria-modal', 'true');
    el.setAttribute('aria-labelledby', 'dm-session-title');
    el.style.cssText = 'position:fixed;inset:0;z-index:100000;display:flex;align-items:center;justify-content:center;background:rgba(6,4,10,.92);color:#e9e2f3;font-family:inherit;text-align:center;padding:24px';
    const box = document.createElement('div');
    box.style.cssText = 'max-width:420px;border:1px solid #6b5a8f;border-radius:10px;padding:28px 32px;background:#14101c';
    const title = document.createElement('h2');
    title.id = 'dm-session-title';
    title.textContent = 'Logged in elsewhere';
    title.style.cssText = 'margin:0 0 10px;font-size:22px;color:#e3c46b';
    const text = document.createElement('p');
    text.textContent = 'Logged in elsewhere — this window stopped saving. Your progress is safe in the newer window.';
    text.style.cssText = 'margin:0 0 20px;line-height:1.5';
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = 'Play here';
    btn.style.cssText = 'font:inherit;font-size:16px;padding:10px 28px;border-radius:6px;border:1px solid #e3c46b;background:#2a2140;color:#fff;cursor:pointer';
    const note = document.createElement('p');
    note.style.cssText = 'margin:14px 0 0;min-height:1em;color:#d98a8a;font-size:14px';
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      note.textContent = '';
      const ok = await claim();
      if (!ok) {
        btn.disabled = false;
        note.textContent = 'Could not take over the account. Check your connection or log in again.';
      }
    });
    box.append(title, text, btn, note);
    el.appendChild(box);
    document.body.appendChild(el);
    btn.focus();
  });
}
