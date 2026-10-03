import type { GameScene } from './SceneManager';
import { login, register, setToken, OFFLINE } from '../net/api';
import type { NecroBackdrop } from '../graphics/NecroBackdrop';
import { dismissSplash } from '../ui/splash';

type Mode = 'login' | 'register';
const STANDALONE = import.meta.env.VITE_OFFLINE_BUILD === '1';

export class LoginScene implements GameScene {
  private root = document.getElementById('ui-root')!;
  private el: HTMLDivElement | null = null;
  private panel: HTMLDivElement | null = null;
  private mode: Mode = 'login';

  constructor(
    private backdrop: NecroBackdrop,
    private onSuccess: () => void,
  ) {}

  mount() {
    this.backdrop.mount();
    this.el = document.createElement('div');
    this.el.className = 'cw-front cw-front-login';
    this.panel = document.createElement('div');
    this.panel.className = 'cw-plate cw-login';
    const shell = document.createElement('div');
    shell.className = 'cw-login-shell';
    shell.innerHTML = `
      <section class="cw-login-story" aria-label="The Ossuary Covenant">
        <div class="cw-login-logo" role="img" aria-label="Death Muffin"><span class="cw-login-brand-sigil" aria-hidden="true">✦</span><span>DEATH<br />MUFFIN</span></div>
        <p class="cw-login-kicker">THE OSSUARY COVENANT <span aria-hidden="true">✦</span> THE DIOCESE IS BURNING</p>
        <h1>The dead don't stay buried.<br /><em>Neither does the fire.</em></h1>
        <p class="cw-login-intro">Raise the fallen, face gargoyles and cinderhounds, and carry your legion into the Cinder Pyre.</p>
        <div class="cw-login-chapters" aria-label="The world beyond the gate">
          <div><span>01 / THE GRAVES</span><strong>Build your legion from the dead.</strong></div>
          <div><span>02 / THE NAVE</span><strong>Face deacons, gargoyles, and worse.</strong></div>
          <div><span>03 / THE PYRE</span><strong>Survive cinderhounds and burning ground.</strong></div>
        </div>
      </section>
    `;
    shell.appendChild(this.panel);
    this.el.appendChild(shell);
    this.root.appendChild(this.el);
    this.render();
    dismissSplash();
  }

  private render() {
    const isLogin = this.mode === 'login';
    this.panel!.innerHTML = `
      <p class="cw-login-card-kicker">${STANDALONE ? 'OFFLINE EDITION' : isLogin ? 'THE GATE IS OPEN' : 'A NEW OATH'}</p>
      <h2>${STANDALONE ? (isLogin ? 'Continue local game' : 'Create local player') : (isLogin ? 'Return to the Covenant' : 'Join the Covenant')}</h2>
      <p class="cw-tagline">${STANDALONE ? 'Your character is saved on this device.' : (isLogin ? 'The dead are waiting to be counted.' : 'Your first descent begins here.')}</p>
      <form novalidate>
        <div class="cw-field">
          <label for="cw-user">${STANDALONE ? 'Local player name' : 'Name'}</label>
          <input id="cw-user" type="text" autocomplete="username" required />
        </div>
        ${isLogin || STANDALONE ? '' : `
        <div class="cw-field">
          <label for="cw-email">Email</label>
          <input id="cw-email" type="email" autocomplete="email" required />
        </div>`}
        ${STANDALONE ? '' : `<div class="cw-field">
          <label for="cw-pass">Password</label>
          <input id="cw-pass" type="password" autocomplete="${isLogin ? 'current-password' : 'new-password'}" required />
        </div>`}
        <button class="cw-button primary" type="submit" id="cw-login-btn">${STANDALONE ? (isLogin ? 'Continue' : 'Create player') : (isLogin ? 'Descend' : 'Take the Oath')}</button>
      </form>
      <div class="cw-error" id="cw-login-error" role="alert"></div>
      <button class="cw-link" id="cw-mode-toggle" type="button">${STANDALONE ? (isLogin ? 'Create a local player' : 'Use an existing local player') : (isLogin ? 'New to the Covenant? Create an account' : 'Already sworn? Sign in')}</button>
      ${STANDALONE ? '<div class="cw-offline-note">Local players are separate from online accounts. This device stores the save; clearing site data deletes it.</div>' : OFFLINE ? '<div class="cw-offline-note">Offline dev mode — accounts live only in this browser</div>' : ''}
    `;
    const form = this.panel!.querySelector('form')!;
    const btn = this.panel!.querySelector<HTMLButtonElement>('#cw-login-btn')!;
    const user = this.panel!.querySelector<HTMLInputElement>('#cw-user')!;
    const email = this.panel!.querySelector<HTMLInputElement>('#cw-email');
    const pass = this.panel!.querySelector<HTMLInputElement>('#cw-pass');
    const errorEl = this.panel!.querySelector<HTMLDivElement>('#cw-login-error')!;

    const fail = (message: string) => {
      // Server strings are shown as sent; only the first letter is capitalised ("username must be at least 3 characters").
      errorEl.textContent = message.charAt(0).toUpperCase() + message.slice(1);
      this.panel!.classList.remove('shake');
      void this.panel!.offsetWidth;
      this.panel!.classList.add('shake');
    };

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errorEl.textContent = '';
      btn.disabled = true;
      btn.textContent = STANDALONE ? 'Opening…' : isLogin ? 'Descending…' : 'Swearing…';
      try {
        const { token } = isLogin
          ? await login(user.value.trim(), pass?.value ?? 'local-only')
          : await register(user.value.trim(), email?.value.trim() ?? '', pass?.value ?? 'local-only');
        setToken(token);
        this.onSuccess();
      } catch (err) {
        // Server error strings are player-readable — shown verbatim.
        fail(err instanceof Error ? err.message : 'The gate would not open — try again');
      } finally {
        btn.disabled = false;
        btn.textContent = STANDALONE ? (isLogin ? 'Continue' : 'Create player') : (isLogin ? 'Descend' : 'Take the Oath');
      }
    });
    this.panel!.querySelector('#cw-mode-toggle')!.addEventListener('click', () => {
      this.mode = isLogin ? 'register' : 'login';
      this.render();
    });
    user.focus();
  }

  unmount() {
    this.el?.remove();
    this.el = null;
  }
}
