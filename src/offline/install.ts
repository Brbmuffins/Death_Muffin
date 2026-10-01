/** Installable asset download and explicit stats upload for the offline edition. */
import { getCharacter, getToken } from '../net/api';

export async function setupOfflineInstall() {
  const panel = document.createElement('aside');
  panel.className = 'dm-offline-install cw-plate';
  panel.setAttribute('aria-label', 'Offline game download');
  panel.innerHTML = `
    <strong>Death Muffin Offline</strong>
    <span data-offline-status role="status">Preparing offline download…</span>
    <button class="cw-button" type="button" data-offline-download>Download for offline play</button>
    <button class="cw-button" type="button" data-offline-install hidden>Install app</button>
    <details class="dm-offline-sync">
      <summary>Upload level and XP</summary>
      <p>Reconnect to upload this local player's level and XP to an online character of the same discipline. Items, gold and professions stay here. Your higher online progress is kept. Close any online game tab first, then reopen it after uploading.</p>
      <form data-offline-sync>
        <label>Online account <input name="username" autocomplete="username" required /></label>
        <label>Password <input name="password" type="password" autocomplete="current-password" required /></label>
        <button class="cw-button" type="submit">Upload stats</button>
      </form>
      <span data-sync-status role="status"></span>
    </details>`;
  document.body.appendChild(panel);
  const status = panel.querySelector<HTMLElement>('[data-offline-status]')!;
  const download = panel.querySelector<HTMLButtonElement>('[data-offline-download]')!;
  const install = panel.querySelector<HTMLButtonElement>('[data-offline-install]')!;
  const syncForm = panel.querySelector<HTMLFormElement>('[data-offline-sync]')!;
  const syncStatus = panel.querySelector<HTMLElement>('[data-sync-status]')!;
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

  syncForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = syncForm.querySelector<HTMLButtonElement>('button')!;
    const username = syncForm.elements.namedItem('username') as HTMLInputElement;
    const password = syncForm.elements.namedItem('password') as HTMLInputElement;
    button.disabled = true;
    syncStatus.textContent = 'Connecting to your online character…';
    try {
      if (!getToken()?.startsWith('offline:')) throw new Error('Open a local player before uploading stats.');
      const local = await getCharacter();
      const api = `${location.origin}/death-muffin/api`;
      const login = await fetch(`${api}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: username.value.trim(), password: password.value }),
      });
      const auth = await login.json();
      if (!login.ok || !auth.token) throw new Error(auth.error || 'Online login failed.');
      password.value = '';
      const synced = await fetch(`${api}/api/offline/sync-stats`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${auth.token}` },
        body: JSON.stringify({ classIndex: local.class_index, level: local.level, experience: local.experience }),
      });
      const result = await synced.json();
      if (!synced.ok) throw new Error(result.error || 'Upload failed.');
      syncStatus.textContent = result.improved
        ? `Uploaded. Your online character is now level ${result.level} with ${result.experience} XP.`
        : `Your online character is already ahead at level ${result.level} with ${result.experience} XP.`;
    } catch (error) {
      password.value = '';
      syncStatus.textContent = error instanceof Error ? error.message : 'Could not upload stats.';
    } finally { button.disabled = false; }
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
    const onMessage = (event: MessageEvent<{ type: string; ready?: boolean; done?: number; total?: number; message?: string }>) => {
      const data = event.data;
      if (data.type === 'status') {
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
    download.addEventListener('click', async () => {
      download.disabled = true;
      status.textContent = 'Downloading game assets…';
      try { await navigator.storage?.persist?.(); } catch { /* optional */ }
      send('DOWNLOAD');
    });
  } catch (error) {
    status.textContent = `Offline download unavailable: ${error instanceof Error ? error.message : 'unknown error'}`;
    download.disabled = true;
  }
}
