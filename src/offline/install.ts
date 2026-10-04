/** Installable asset download for the standalone offline edition, plus the account sync panel. */
import { getToken, setToken } from '../net/api';
import * as mock from '../net/mockBackend';
import * as store from './accountStore';
import {
  describeSave, fetchOnlineSave, onlineJson, onlineLogin, reconcile, currentSession, setCurrentSession, onNotice, getNotice, setNotice,
  type OnlineSession,
} from './accountSync';
import { mountChooser } from './chooserUi';

const NOTICE_KEY = 'dm_offline_notice';

export async function setupOfflineInstall() {
  const panel = document.createElement('aside');
  panel.className = 'dm-offline-install cw-plate';
  panel.setAttribute('aria-label', 'Offline game download');
  panel.innerHTML = `
    <strong>Death Muffin Offline</strong>
    <span data-offline-status role="status">Preparing offline download…</span>
    <button class="cw-button" type="button" data-offline-download>Download for offline play</button>
    <button class="cw-button" type="button" data-offline-install hidden>Install app</button>
    <details class="dm-offline-sync" data-sync-box hidden>
      <summary data-sync-title>Account and sync</summary>
      <p data-sync-who></p>
      <form data-offline-sync>
        <label data-name-label>Account name <input name="username" autocomplete="username" required /></label>
        <label data-pass-label>Password <input name="password" type="password" autocomplete="current-password" /></label>
        <button class="cw-button" type="submit" data-sync-button>Sync now</button>
      </form>
      <span data-sync-status role="status"></span>
      <div data-save-choices hidden></div>
      <div data-saved-versions></div>
    </details>`;
  document.body.appendChild(panel);
  const status = panel.querySelector<HTMLElement>('[data-offline-status]')!;
  const download = panel.querySelector<HTMLButtonElement>('[data-offline-download]')!;
  const install = panel.querySelector<HTMLButtonElement>('[data-offline-install]')!;
  const box = panel.querySelector<HTMLDetailsElement>('[data-sync-box]')!;
  const who = panel.querySelector<HTMLElement>('[data-sync-who]')!;
  const syncForm = panel.querySelector<HTMLFormElement>('[data-offline-sync]')!;
  const nameLabel = panel.querySelector<HTMLElement>('[data-name-label]')!;
  const passLabel = panel.querySelector<HTMLElement>('[data-pass-label]')!;
  const syncButton = panel.querySelector<HTMLButtonElement>('[data-sync-button]')!;
  const syncStatus = panel.querySelector<HTMLElement>('[data-sync-status]')!;
  const choices = panel.querySelector<HTMLElement>('[data-save-choices]')!;
  const versions = panel.querySelector<HTMLElement>('[data-saved-versions]')!;
  const nameInput = syncForm.elements.namedItem('username') as HTMLInputElement;
  const passInput = syncForm.elements.namedItem('password') as HTMLInputElement;
  let installPrompt: (Event & { prompt(): Promise<void>; userChoice: Promise<{ outcome: string }> }) | null = null;

  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    installPrompt = event as typeof installPrompt;
    install.hidden = false;
  });
  install.addEventListener('click', async () => {
    if (!installPrompt) return;
    await installPrompt.prompt();
    await installPrompt.userChoice;
    installPrompt = null;
    install.hidden = true;
  });

  // A notice left by the page that reloaded after a sync, then live notices from sign-in and Sync now.
  try {
    const left = sessionStorage.getItem(NOTICE_KEY);
    if (left) { sessionStorage.removeItem(NOTICE_KEY); setNotice(left); }
  } catch { /* optional */ }
  const showNotice = (text: string) => { syncStatus.textContent = text; if (text) box.open = true; };
  onNotice(showNotice);
  if (getNotice()) showNotice(getNotice());

  const currentKey = () => { const t = getToken(); return t?.startsWith('offline:') ? t.slice('offline:'.length) : null; };
  const ago = (t: number) => { const m = Math.round((Date.now() - t) / 60000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 2880 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`; };

  /** What the panel offers depends on who is playing: a linked account, an unlinked local player, or nobody yet (login screen). */
  const refresh = () => {
    const key = currentKey();
    const info = key ? mock.localPlayer(key)?.info ?? null : null;
    box.hidden = !info;
    if (!info) return;
    const linked = info.linkedAccount;
    const session = currentSession();
    const haveSession = !!linked && !!session && session.account.toLowerCase() === linked.toLowerCase();
    if (linked) {
      who.textContent = `Playing as ${linked}. ${info.syncedAt ? `Last synced ${ago(info.syncedAt)}.` : 'Not synced yet.'}${info.changedSinceSync ? ' This device has changes not yet synced.' : ''}`;
      nameInput.value = linked; nameInput.readOnly = true;
      syncButton.textContent = 'Sync now';
    } else {
      who.textContent = `"${key}" is a local player, not your online account. Link it to compare and keep both.`;
      nameInput.readOnly = false;
      syncButton.textContent = 'Link to my account';
    }
    passLabel.hidden = haveSession;
    passInput.required = !haveSession;
    nameLabel.hidden = false;
  };
  refresh();
  setInterval(refresh, 1500);

  const loadVersions = async (session: OnlineSession, fingerprint: string) => {
    versions.replaceChildren();
    try {
      const history = await onlineJson(session, '/api/offline/versions');
      if (!history.versions?.length) return;
      const title = document.createElement('p');
      title.textContent = 'Previous online versions:';
      versions.appendChild(title);
      let fp = fingerprint;
      for (const saved of history.versions.slice(0, 10)) {
        const restore = document.createElement('button');
        restore.className = 'cw-button';
        restore.type = 'button';
        restore.textContent = `Restore ${saved.source} save from ${new Date(saved.createdAt).toLocaleString()} — ${describeSave(saved.summary)}`;
        restore.addEventListener('click', async () => {
          restore.disabled = true;
          try {
            const result = await onlineJson(session, '/api/offline/restore', { method: 'POST', body: { versionId: saved.id, expectedFingerprint: fp } });
            fp = result.fingerprint;
            syncStatus.textContent = `Previous version loaded online: ${describeSave(result.summary)}. Press Sync now to bring it onto this device.`;
          } catch (error) { syncStatus.textContent = error instanceof Error ? error.message : 'Restore failed.'; }
          finally { restore.disabled = false; }
        });
        versions.appendChild(restore);
      }
    } catch { /* the list is a convenience */ }
  };

  const finish = (key: string, notice: string, replaced: boolean) => {
    syncStatus.textContent = notice;
    choices.hidden = true;
    if (replaced || key !== currentKey()) {
      // The local copy changed under the running game: reopen it from the store.
      setToken(`offline:${key}`);
      try { sessionStorage.setItem(NOTICE_KEY, notice); } catch { /* optional */ }
      location.reload();
    }
  };

  syncForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const key = currentKey();
    const info = key ? mock.localPlayer(key)?.info : null;
    if (!key || !info) return;
    syncButton.disabled = true;
    choices.hidden = true;
    versions.replaceChildren();
    syncStatus.textContent = 'Comparing your saves…';
    const typed = passInput.value;
    try {
      const account = info.linkedAccount ?? nameInput.value.trim();
      let session = currentSession();
      if (!session || session.account.toLowerCase() !== account.toLowerCase()) {
        if (!typed) throw new Error('Type your account password to sign in for the sync.');
        session = await onlineLogin(account, typed);
        setCurrentSession(session);
      }
      passInput.value = '';
      const save = await fetchOnlineSave(session);
      if (save?.snapshot?.username) session.account = String(save.snapshot.username);
      const outcome = await reconcile(session, save, key);
      const remember = async (k: string) => { if (typed) await store.rememberAccount(session!.account, typed, k); else store.setAccountKey(session!.account, k); };
      if (outcome.kind === 'ready') {
        await remember(outcome.done.key);
        finish(outcome.done.key, outcome.done.notice, outcome.done.replaced);
      } else {
        syncStatus.textContent = 'Choose which complete save to keep.';
        mountChooser(choices, outcome.choice, async (d) => { await remember(d.key); finish(d.key, d.notice, d.replaced); }, (m) => { syncStatus.textContent = m; });
      }
      if (save) await loadVersions(session, save.fingerprint);
    } catch (error) {
      passInput.value = '';
      syncStatus.textContent = error instanceof Error ? error.message : 'Could not sync.';
    } finally { syncButton.disabled = false; refresh(); }
  });

  if (!('serviceWorker' in navigator) || !('caches' in window)) {
    status.textContent = 'Offline install needs a browser with service worker support.';
    download.disabled = true;
    return;
  }

  try {
    const base = import.meta.env.BASE_URL;
    const registration = await navigator.serviceWorker.register(`${base}sw.js`, { scope: base });
    const ready = await navigator.serviceWorker.ready;
    const worker = ready.active ?? registration.active;
    if (!worker) throw new Error('Offline worker did not start');
    // `?download=1` (the Windows launcher's "Download Offline") asks this page to start the download itself; no text scraping or button clicking.
    let autoDownload = false;
    try {
      const params = new URLSearchParams(location.search);
      autoDownload = params.get('download') === '1';
      if (autoDownload) {
        params.delete('download');
        const rest = params.toString();
        history.replaceState(null, '', `${location.pathname}${rest ? `?${rest}` : ''}${location.hash}`);
      }
    } catch { /* optional */ }
    const startDownload = async () => {
      download.disabled = true;
      status.textContent = 'Downloading game assets…';
      try { await navigator.storage?.persist?.(); } catch { /* optional */ }
      send('DOWNLOAD');
    };
    const onMessage = (event: MessageEvent<{ type: string; ready?: boolean; done?: number; total?: number; message?: string }>) => {
      const data = event.data;
      if (data.type === 'status') {
        if (autoDownload) {
          autoDownload = false;
          if (data.ready) {
            status.textContent = 'Already downloaded. Ready to play without a network.';
            download.hidden = true;
            return;
          }
          void startDownload();
          return;
        }
        status.textContent = data.ready ? 'Ready to play without a network.' : `Download the game assets (${data.total} files) before disconnecting.`;
        download.hidden = !!data.ready;
      } else if (data.type === 'progress') {
        status.textContent = `Downloading game assets: ${data.done} / ${data.total}`;
      } else if (data.type === 'ready') {
        status.textContent = 'Ready to play without a network. Use your browser menu to install the app.';
        download.hidden = true;
      } else if (data.type === 'error') {
        status.textContent = `Download paused: ${data.message}. Tap to retry.`;
        download.disabled = false;
      }
    };
    const send = (type: 'STATUS' | 'DOWNLOAD') => {
      const channel = new MessageChannel();
      channel.port1.onmessage = onMessage;
      worker.postMessage({ type }, [channel.port2]);
    };
    send('STATUS');
    download.addEventListener('click', () => { void startDownload(); });
  } catch (error) {
    status.textContent = `Offline download unavailable: ${error instanceof Error ? error.message : 'unknown error'}`;
    download.disabled = true;
  }
}
