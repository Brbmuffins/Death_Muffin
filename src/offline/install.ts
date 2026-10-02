/** Installable asset download for the standalone offline edition. */
import { getToken, setToken } from '../net/api';

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
      <summary>Sync complete save</summary>
      <p>Reconnect and compare your local and online characters. Both versions are kept while you choose which one to load. Close any open online game tab first.</p>
      <form data-offline-sync>
        <label>Online account <input name="username" autocomplete="username" required /></label>
        <label>Password <input name="password" type="password" autocomplete="current-password" required /></label>
        <button class="cw-button" type="submit">Compare saves</button>
      </form>
      <span data-sync-status role="status"></span>
      <div data-save-choices hidden>
        <p data-save-compare></p>
        <button class="cw-button" type="button" data-load-online>Load online save on this device</button>
        <button class="cw-button" type="button" data-load-offline>Load offline save online</button>
        <div data-saved-versions></div>
      </div>
    </details>`;
  document.body.appendChild(panel);
  const status = panel.querySelector<HTMLElement>('[data-offline-status]')!;
  const download = panel.querySelector<HTMLButtonElement>('[data-offline-download]')!;
  const install = panel.querySelector<HTMLButtonElement>('[data-offline-install]')!;
  const syncForm = panel.querySelector<HTMLFormElement>('[data-offline-sync]')!;
  const syncStatus = panel.querySelector<HTMLElement>('[data-sync-status]')!;
  const choices = panel.querySelector<HTMLElement>('[data-save-choices]')!;
  const compare = panel.querySelector<HTMLElement>('[data-save-compare]')!;
  const loadOnline = panel.querySelector<HTMLButtonElement>('[data-load-online]')!;
  const loadOffline = panel.querySelector<HTMLButtonElement>('[data-load-offline]')!;
  const versions = panel.querySelector<HTMLElement>('[data-saved-versions]')!;
  const api = `${location.origin}/death-muffin/api`;
  let onlineToken: string | null = null;
  let onlineSnapshot: any = null;
  let onlineFingerprint = '';
  let localSnapshot: any = null;
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

  const onlineRequest = async (path: string, options: RequestInit = {}) => {
    if (!onlineToken) throw new Error('Compare saves again to sign in.');
    const response = await fetch(`${api}${path}`, {
      ...options,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${onlineToken}`, ...options.headers },
    });
    const body = await response.json();
    if (!response.ok) throw Object.assign(new Error(body.error || `Online request failed (${response.status}).`), { implausible: body.implausible === true });
    return body;
  };
  const label = (s: any) => `Level ${s.level}, ${s.experience} XP, ${s.gold} gold, ${s.items} inventory slots, ${s.professions} professions, Ascension ${s.ascension}`;

  syncForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = syncForm.querySelector<HTMLButtonElement>('button')!;
    const username = syncForm.elements.namedItem('username') as HTMLInputElement;
    const password = syncForm.elements.namedItem('password') as HTMLInputElement;
    button.disabled = true;
    choices.hidden = true;
    syncStatus.textContent = 'Comparing complete saves…';
    try {
      const login = await fetch(`${api}/login`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: username.value.trim(), password: password.value }),
      });
      const auth = await login.json();
      if (!login.ok || !auth.token) throw new Error(auth.error || 'Online login failed.');
      password.value = '';
      onlineToken = auth.token;
      const online = await onlineRequest('/api/offline/snapshot');
      onlineSnapshot = online.snapshot;
      onlineFingerprint = online.fingerprint;
      const localToken = getToken();
      localSnapshot = localToken?.startsWith('offline:')
        ? (await import('../net/mockBackend')).exportLocalSave(localToken) : null;
      const localSummary = localSnapshot ? {
        level: localSnapshot.character.level, experience: localSnapshot.character.experience,
        gold: localSnapshot.character.gold, items: localSnapshot.slots.length,
        professions: localSnapshot.professions.length, ascension: localSnapshot.necro?.ascension ?? 0,
      } : null;
      compare.textContent = `Online: ${label(online.summary)}. ${localSummary ? `Local: ${label(localSummary)}.` : 'No local character is open yet.'}`;
      loadOffline.disabled = !localSnapshot || localSnapshot.character.class_index !== onlineSnapshot.character.class_index;
      if (localSnapshot && loadOffline.disabled) syncStatus.textContent = 'The saves use different disciplines. You can still import the online save as another local player.';
      else syncStatus.textContent = 'Choose which complete save to load. The other version is kept.';
      const history = await onlineRequest('/api/offline/versions');
      versions.replaceChildren();
      if (history.versions?.length) {
        const title = document.createElement('p');
        title.textContent = 'Previous online versions:';
        versions.appendChild(title);
        for (const saved of history.versions.slice(0, 10)) {
          const restore = document.createElement('button');
          restore.className = 'cw-button';
          restore.type = 'button';
          restore.textContent = `Restore ${saved.source} save from ${new Date(saved.createdAt).toLocaleString()} — ${label(saved.summary)}`;
          restore.addEventListener('click', async () => {
            restore.disabled = true;
            try {
              const result = await onlineRequest('/api/offline/restore', { method: 'POST', body: JSON.stringify({ versionId: saved.id, expectedFingerprint: onlineFingerprint }) });
              onlineFingerprint = result.fingerprint;
              syncStatus.textContent = `Previous version loaded online: ${label(result.summary)}. Reopen the online game.`;
            } catch (error) { syncStatus.textContent = error instanceof Error ? error.message : 'Restore failed.'; }
            finally { restore.disabled = false; }
          });
          versions.appendChild(restore);
        }
      }
      choices.hidden = false;
    } catch (error) {
      password.value = '';
      syncStatus.textContent = error instanceof Error ? error.message : 'Could not compare saves.';
    } finally { button.disabled = false; }
  });

  loadOnline.addEventListener('click', async () => {
    if (!onlineSnapshot) return;
    loadOnline.disabled = true;
    try {
      const token = (await import('../net/mockBackend')).importOnlineSave(onlineSnapshot);
      setToken(token);
      location.reload();
    } catch (error) {
      syncStatus.textContent = error instanceof Error ? error.message : 'Could not import online save.';
      loadOnline.disabled = false;
    }
  });

  loadOffline.addEventListener('click', async () => {
    if (!localSnapshot || !onlineFingerprint) return;
    if (!window.confirm('Replace your ONLINE character with this offline save? The current online save is kept as a version you can restore.')) return;
    loadOffline.disabled = true;
    syncStatus.textContent = 'Saving both versions and loading the offline character online…';
    try {
      const token = getToken();
      const current = token?.startsWith('offline:') ? (await import('../net/mockBackend')).exportLocalSave(token) : localSnapshot;
      const load = (confirmImplausible: boolean) => onlineRequest('/api/offline/load', { method: 'POST', body: JSON.stringify({ snapshot: current, expectedFingerprint: onlineFingerprint, confirmImplausible }) });
      let result;
      try { result = await load(false); }
      catch (error) {
        // Server authority: a save far ahead of the online one for the time it claims needs an explicit yes (the online save is kept either way).
        if (!(error as { implausible?: boolean }).implausible || !window.confirm((error as Error).message)) throw error;
        result = await load(true);
      }
      onlineFingerprint = result.fingerprint;
      syncStatus.textContent = `Offline save loaded online: ${label(result.summary)}. Reopen the online game.`;
    } catch (error) { syncStatus.textContent = error instanceof Error ? error.message : 'Could not load offline save online.'; }
    finally { loadOffline.disabled = false; }
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
