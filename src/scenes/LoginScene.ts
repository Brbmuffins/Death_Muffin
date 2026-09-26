import type { GameScene } from './SceneManager';
import { login, register, setToken, OFFLINE } from '../net/api';
import type { NecroBackdrop } from '../graphics/NecroBackdrop';

type Mode = 'login' | 'register';

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
    this.el.className = 'cw-front';
    this.panel = document.createElement('div');
    this.panel.className = 'cw-plate cw-login';
    this.el.appendChild(this.panel);
    this.root.appendChild(this.el);
    this.render();
  }

  private render() {
    const isLogin = this.mode === 'login';
    this.panel!.innerHTML = `
      <img class="cw-logo" src="art/crossworlds-logo.png" alt="Crossworlds" draggable="false" />
      <p class="cw-tagline">${isLogin ? 'The dead are waiting to be counted.' : 'Swear yourself to the Ossuary Covenant.'}</p>
      <form novalidate>
        <div class="cw-field">
          <label for="cw-user">Name</label>
          <input id="cw-user" type="text" autocomplete="username" required />
        </div>
        ${isLogin ? '' : `
        <div class="cw-field">
          <label for="cw-email">Email</label>
          <input id="cw-email" type="email" autocomplete="email" required />
        </div>`}
        <div class="cw-field">
          <label for="cw-pass">Password</label>
          <input id="cw-pass" type="password" autocomplete="${isLogin ? 'current-password' : 'new-password'}" required />
        </div>
        <button class="cw-button primary" type="submit" id="cw-login-btn">${isLogin ? 'Descend' : 'Take the Oath'}</button>
      </form>
      <div class="cw-error" id="cw-login-error" role="alert"></div>
      <button class="cw-link" id="cw-mode-toggle" type="button">${isLogin ? 'New to the Covenant? Create an account' : 'Already sworn? Sign in'}</button>
      ${OFFLINE ? '<div class="cw-offline-note">Offline dev mode — accounts live only in this browser</div>' : ''}
    `;
    const form = this.panel!.querySelector('form')!;
    const btn = this.panel!.querySelector<HTMLButtonElement>('#cw-login-btn')!;
    const user = this.panel!.querySelector<HTMLInputElement>('#cw-user')!;
    const email = this.panel!.querySelector<HTMLInputElement>('#cw-email');
    const pass = this.panel!.querySelector<HTMLInputElement>('#cw-pass')!;
    const errorEl = this.panel!.querySelector<HTMLDivElement>('#cw-login-error')!;

    const fail = (message: string) => {
      errorEl.textContent = message;
      this.panel!.classList.remove('shake');
      void this.panel!.offsetWidth;
      this.panel!.classList.add('shake');
    };

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errorEl.textContent = '';
      btn.disabled = true;
      btn.textContent = isLogin ? 'Descending…' : 'Swearing…';
      try {
        const { token } = isLogin
          ? await login(user.value.trim(), pass.value)
          : await register(user.value.trim(), email!.value.trim(), pass.value);
        setToken(token);
        this.onSuccess();
      } catch (err) {
        // Server error strings are player-readable — shown verbatim.
        fail(err instanceof Error ? err.message : 'The gate would not open — try again');
      } finally {
        btn.disabled = false;
        btn.textContent = isLogin ? 'Descend' : 'Take the Oath';
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
