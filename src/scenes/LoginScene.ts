import type { GameScene } from './SceneManager';
import { login, register, setToken, OFFLINE } from '../net/api';
import type { NecroBackdrop } from '../graphics/NecroBackdrop';
import { dismissSplash } from '../ui/splash';
import { signIn, setNotice } from '../offline/accountSync';
import { mountChooser } from '../offline/chooserUi';
import { lastAccount } from '../offline/accountStore';

type Mode = 'login' | 'register';
const esc = (t: string) => t.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
const STANDALONE = import.meta.env.VITE_OFFLINE_BUILD === '1';

export class LoginScene implements GameScene {
  private root = document.getElementById('ui-root')!;
  private el: HTMLDivElement | null = null;
  private panel: HTMLDivElement | null = null;
  private mode: Mode = 'login';
  /** Offline edition: the unlinked local player being linked to an account (set by "Link to my account"). */
  private linkKey: string | null = null;
  /** Keys of the saves in this browser (read once at mount; the Continue-as button needs a synchronous answer). */
  private localKeys = new Set<string>();

  constructor(
    private backdrop: NecroBackdrop,
    private onSuccess: () => void,
  ) {}

  mount() {
    this.backdrop.mount();
    if (STANDALONE) {
      try { const raw = JSON.parse(localStorage.getItem('dm_offline_db_v1') ?? 'null'); this.localKeys = new Set(Object.keys(raw?.accounts ?? {})); } catch { /* none */ }
    }
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
    const account = STANDALONE && isLogin && !this.linkKey ? lastAccount() : null;
    const linking = STANDALONE && isLogin ? this.linkKey : null;
    // "Sign in" is the account sign-in; register mode in the offline edition is the older local-only player.
    const accountMode = STANDALONE && isLogin;
    this.panel!.innerHTML = `
      <p class="cw-login-card-kicker">${STANDALONE ? 'OFFLINE EDITION' : isLogin ? 'THE GATE IS OPEN' : 'A NEW OATH'}</p>
      <h2>${STANDALONE ? (isLogin ? (linking ? 'Link to your account' : 'Sign in') : 'Create local player') : (isLogin ? 'Return to the Covenant' : 'Join the Covenant')}</h2>
      <p class="cw-tagline">${STANDALONE ? (isLogin ? (linking ? `Sign in with your Death Muffin account to compare it with the local player "${linking}".` : 'Use your Death Muffin account. Your character plays here with or without a network and syncs when you are online.') : 'A local player lives only on this device and is not your online account.') : (isLogin ? 'The dead are waiting to be counted.' : 'Your first descent begins here.')}</p>
      ${account && this.hasSave(account.key) ? `<button class="cw-button primary" type="button" id="cw-continue-as">Continue as ${esc(account.account)}</button><p class="cw-login-sync-hint">Plays your copy on this device. No network needed.</p>` : ''}
      <form novalidate>
        <div class="cw-field">
          <label for="cw-user">${accountMode ? 'Account name' : STANDALONE ? 'Local player name' : 'Name'}</label>
          <input id="cw-user" type="text" autocomplete="username" required />
        </div>
        ${isLogin || STANDALONE ? '' : `
        <div class="cw-field">
          <label for="cw-email">Email</label>
          <input id="cw-email" type="email" autocomplete="email" required />
        </div>`}
        ${STANDALONE && !isLogin ? '' : `<div class="cw-field">
          <label for="cw-pass">Password</label>
          <input id="cw-pass" type="password" autocomplete="${isLogin ? 'current-password' : 'new-password'}" required />
        </div>`}
        <button class="cw-button primary" type="submit" id="cw-login-btn">${STANDALONE ? (isLogin ? (linking ? 'Link and compare' : 'Sign in') : 'Create player') : (isLogin ? 'Descend' : 'Take the Oath')}</button>
      </form>
      <div class="cw-error" id="cw-login-error" role="alert"></div>
      ${STANDALONE ? '<div class="cw-login-help" id="cw-login-help" aria-live="polite" hidden></div>' : ''}
      ${STANDALONE && isLogin ? '<div class="cw-login-players" id="cw-login-players" hidden></div>' : ''}
      ${linking ? '<button class="cw-link" id="cw-cancel-link" type="button">Cancel linking</button>' : ''}
      <button class="cw-link" id="cw-mode-toggle" type="button">${STANDALONE ? (isLogin ? 'Play without an account (this device only)' : 'Back to account sign-in') : (isLogin ? 'New to the Covenant? Create an account' : 'Already sworn? Sign in')}</button>
      ${STANDALONE ? (isLogin ? '<div class="cw-offline-note">Same name and password as the online game. Signing in here takes over your online session, so close the online game first. Never signed in on this device? Connect once; after that you can play offline.</div>' : '<div class="cw-offline-note">Local players are separate from your online account. This device stores the save; clearing site data deletes it.</div>') : OFFLINE ? '<div class="cw-offline-note">Offline dev mode — accounts live only in this browser</div>' : ''}
    `;
    const form = this.panel!.querySelector('form')!;
    const btn = this.panel!.querySelector<HTMLButtonElement>('#cw-login-btn')!;
    const user = this.panel!.querySelector<HTMLInputElement>('#cw-user')!;
    const email = this.panel!.querySelector<HTMLInputElement>('#cw-email');
    const pass = this.panel!.querySelector<HTMLInputElement>('#cw-pass');
    const errorEl = this.panel!.querySelector<HTMLDivElement>('#cw-login-error')!;

    const helpEl = this.panel!.querySelector<HTMLDivElement>('#cw-login-help');
    const playersEl = this.panel!.querySelector<HTMLDivElement>('#cw-login-players');
    const fail = (message: string) => {
      // Server strings are shown as sent; only the first letter is capitalised ("username must be at least 3 characters").
      errorEl.textContent = message.charAt(0).toUpperCase() + message.slice(1);
      pass?.focus();
      pass?.select();
      btn.classList.remove('shake');
      void btn.offsetWidth;
      btn.classList.add('shake');
    };
    const enter = (key: string, notice: string) => {
      setToken(`offline:${key}`);
      if (notice) setNotice(notice);
      this.onSuccess();
    };

    if (STANDALONE && isLogin) {
      this.panel!.querySelector('#cw-continue-as')?.addEventListener('click', () => {
        const known = lastAccount();
        if (known) enter(known.key, `Playing ${known.account} from this device. Use Sync now to bring your online progress here.`);
      });
      if (playersEl) void this.listPlayers(playersEl, user, errorEl, enter);
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      errorEl.textContent = '';
      if (helpEl) { helpEl.hidden = true; helpEl.replaceChildren(); }
      btn.disabled = true;
      btn.textContent = STANDALONE ? (isLogin ? 'Signing in…' : 'Opening…') : isLogin ? 'Descending…' : 'Swearing…';
      try {
        if (accountMode) {
          if (!user.value.trim() || !pass?.value) throw new Error('Type your account name and password.');
          const r = await signIn(user.value.trim(), pass.value, {}, this.linkKey);
          pass.value = '';
          if (r.kind === 'ready') { enter(r.key, r.notice); return; }
          mountChooser(helpEl!, r.choice, (d) => enter(d.key, d.notice), (m) => fail(m));
          return;
        }
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
        btn.textContent = STANDALONE ? (isLogin ? (this.linkKey ? 'Link and compare' : 'Sign in') : 'Create player') : (isLogin ? 'Descend' : 'Take the Oath');
      }
    });
    this.panel!.querySelector('#cw-cancel-link')?.addEventListener('click', () => { this.linkKey = null; this.render(); });
    this.panel!.querySelector('#cw-mode-toggle')!.addEventListener('click', () => {
      this.mode = isLogin ? 'register' : 'login';
      this.linkKey = null;
      this.render();
    });
    user.focus();
  }

  private hasSave(key: string): boolean {
    return this.localKeys.has(key);
  }

  /** Offline edition: the unlinked local players on this device, each with Play and "Link to my account". */
  private async listPlayers(host: HTMLElement, user: HTMLInputElement, errorEl: HTMLElement, enter: (key: string, notice: string) => void) {
    const { listLocalPlayers } = await import('../net/mockBackend');
    const players = listLocalPlayers().filter((p) => !p.linkedAccount);
    if (!players.length || !host.isConnected) return;
    host.hidden = false;
    host.innerHTML = '<span class="cw-login-players-label">Local players on this device</span>';
    for (const p of players) {
      const row = document.createElement('div');
      row.className = 'cw-login-player-row';
      const name = document.createElement('span');
      name.className = 'cw-login-player-name';
      name.textContent = p.level ? `${p.key} (level ${p.level})` : p.key;
      const play = document.createElement('button');
      play.type = 'button';
      play.className = 'cw-link cw-login-player';
      play.textContent = 'Play';
      play.addEventListener('click', () => enter(p.key, ''));
      const link = document.createElement('button');
      link.type = 'button';
      link.className = 'cw-link cw-login-player';
      link.dataset.linkPlayer = p.key;
      link.textContent = 'Link to my account';
      link.addEventListener('click', () => { this.linkKey = p.key; errorEl.textContent = ''; this.render(); });
      row.append(name, play, link);
      host.appendChild(row);
    }
    void user;
  }

  unmount() {
    this.el?.remove();
    this.el = null;
  }
}
