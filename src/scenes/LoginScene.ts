import type { GameScene } from './SceneManager';
import { login, register, setToken } from '../net/api';
import { LoginBackdrop } from '../graphics/loginBackdrop';

type Mode = 'login' | 'register';

export class LoginScene implements GameScene {
  private root = document.getElementById('ui-root')!;
  private canvas = document.getElementById('scene') as HTMLCanvasElement;
  private el: HTMLDivElement | null = null;
  private backdrop = new LoginBackdrop();
  private mode: Mode = 'login';

  constructor(private onSuccess: () => void) {}

  mount() {
    this.backdrop.mount(this.canvas);
    this.el = document.createElement('div');
    this.el.className = 'cw-panel cw-login';
    this.root.appendChild(this.el);
    this.render();
  }

  private render() {
    const isLogin = this.mode === 'login';
    this.el!.innerHTML = `
      <img class="cw-logo" src="art/crossworlds-logo.png" alt="Crossworlds" draggable="false" />
      <div class="cw-field">
        <label for="cw-user">Hero Name</label>
        <input id="cw-user" type="text" autocomplete="username" />
      </div>
      ${
        isLogin
          ? ''
          : `
      <div class="cw-field">
        <label for="cw-email">Raven Address (email)</label>
        <input id="cw-email" type="email" autocomplete="email" />
      </div>`
      }
      <div class="cw-field">
        <label for="cw-pass">Secret Word</label>
        <input id="cw-pass" type="password" autocomplete="${isLogin ? 'current-password' : 'new-password'}" />
      </div>
      <button class="cw-button cw-enter" id="cw-login-btn">${isLogin ? 'Enter the World' : 'Forge Your Legend'}</button>
      <div class="cw-error" id="cw-login-error"></div>
      <button class="cw-link" id="cw-mode-toggle">${
        isLogin ? 'No legend yet? Forge a new hero' : 'Already sworn in? Enter the World'
      }</button>
    `;

    const btn = this.el!.querySelector<HTMLButtonElement>('#cw-login-btn')!;
    const userInput = this.el!.querySelector<HTMLInputElement>('#cw-user')!;
    const emailInput = this.el!.querySelector<HTMLInputElement>('#cw-email');
    const passInput = this.el!.querySelector<HTMLInputElement>('#cw-pass')!;
    const errorEl = this.el!.querySelector<HTMLDivElement>('#cw-login-error')!;

    const fail = (message: string) => {
      errorEl.textContent = message;
      this.el!.classList.remove('shake');
      // restart the shake animation
      void this.el!.offsetWidth;
      this.el!.classList.add('shake');
    };

    const submit = async () => {
      errorEl.textContent = '';
      btn.disabled = true;
      btn.textContent = isLogin ? 'Crossing over…' : 'Forging…';
      try {
        const { token } = isLogin
          ? await login(userInput.value.trim(), passInput.value)
          : await register(userInput.value.trim(), emailInput!.value.trim(), passInput.value);
        setToken(token);
        this.onSuccess();
      } catch (err) {
        fail(err instanceof Error ? err.message : 'The portal rejected you — try again');
      } finally {
        btn.disabled = false;
        btn.textContent = isLogin ? 'Enter the World' : 'Forge Your Legend';
      }
    };

    btn.addEventListener('click', submit);
    this.el!.querySelectorAll<HTMLInputElement>('input').forEach((input) => {
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') submit();
      });
    });
    this.el!.querySelector('#cw-mode-toggle')!.addEventListener('click', () => {
      this.mode = isLogin ? 'register' : 'login';
      this.render();
    });
    userInput.focus();
  }

  unmount() {
    this.el?.remove();
    this.el = null;
    this.backdrop.unmount();
  }
}
