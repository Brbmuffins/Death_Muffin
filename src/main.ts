import './theme/fonts';
import { initRuntime } from './app/GameRuntime';
import { SceneManager } from './scenes/SceneManager';
import { LoginScene } from './scenes/LoginScene';
import { CharacterSelectScene } from './scenes/CharacterSelectScene';
import { WorldScene } from './scenes/WorldScene';
import { NecroBackdrop } from './graphics/NecroBackdrop';
import { ApiError, getCharacter, getToken, OFFLINE, setToken } from './net/api';
import { claimSession, consumeAutoReload, probeSessionNow, startSessionProbe } from './net/session';
import { installSessionOverlay } from './ui/SessionOverlay';
import type { Character } from './net/types';
import { startReleaseBaseline } from './net/releaseWatch';
import { installErrorRing } from './net/errorRing';

// iOS Safari ignores user-scalable=no: cancel its page pinch/double-tap zoom gestures (the game zooms its own camera).
for (const type of ['gesturestart', 'gesturechange', 'gestureend']) document.addEventListener(type, (e) => e.preventDefault(), { passive: false });
document.addEventListener('dblclick', (e) => e.preventDefault(), { passive: false });

const runtime = initRuntime(document.getElementById('scene') as HTMLCanvasElement);
if (import.meta.env.VITE_OFFLINE_BUILD === '1') void import('./offline/install').then(({ setupOfflineInstall }) => setupOfflineInstall());

// DEV: README/QA screenshots — __cwShot('name') saves the current WebGL frame
// to docs/screenshots/ via the dev-only tools/qa-shots-plugin.ts endpoint.
if (import.meta.env.DEV) {
  void import('./audio/Audio').then(({ audio }) => ((window as unknown as { __cwAudio: typeof audio }).__cwAudio = audio));
  (window as unknown as { __cwShot: (name: string) => Promise<string> }).__cwShot = async (name) => {
    const url = runtime.capture();
    const res = await fetch(`/__qa/shot?name=${encodeURIComponent(name)}`, { method: 'POST', body: url });
    return res.text();
  };
}
installErrorRing(); // the last few uncaught errors ride along with a bug report (Settings → Report a bug)
startReleaseBaseline(); // remembers which release this page was loaded from (play build only)
const manager = new SceneManager();
let backdrop: NecroBackdrop | null = null;
const getBackdrop = () => (backdrop ??= new NecroBackdrop());
const dropBackdrop = () => {
  backdrop?.dispose();
  backdrop = null;
};

function goLogin() {
  if (import.meta.env.PROD && !OFFLINE) {
    window.location.replace('/death-muffin/');
    return;
  }
  manager.goto(new LoginScene(getBackdrop(), resume));
}

function goCharacterSelect() {
  manager.goto(new CharacterSelectScene(getBackdrop(), goWorld));
}

function goWorld(character: Character) {
  dropBackdrop();
  manager.goto(
    new WorldScene(character, () => {
      setToken(null);
      goLogin();
    }, goWorld),
  );
}

// Routes by account state: existing character → world, none yet (404) →
// discipline select, invalid/expired token → login. Used after login and on
// page load, so the sessionStorage JWT survives a reload within the tab.
async function resume() {
  try {
    goWorld(await getCharacter());
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) goCharacterSelect();
    else {
      setToken(null);
      goLogin();
    }
  }
}

// One active session per account, newest wins (net/session.ts). "Play here" trades the token for one on a new session, then reloads so this
// window starts from what the other one saved.
if (!OFFLINE) {
  installSessionOverlay(async () => {
    const token = getToken();
    const fresh = token ? await claimSession(token) : null;
    if (!fresh) return false;
    setToken(fresh);
    window.location.reload();
    return true;
  });
  startSessionProbe(getToken);
}

// Opening or refreshing the game is "opening the account": it claims the session, so a reload takes it back from any other window.
async function boot() {
  const token = getToken();
  if (token && !OFFLINE) {
    // A programmatic reload (update notice / release watch) is not "opening the account": it must not take the session back from a newer window.
    if (consumeAutoReload()) void probeSessionNow(token);
    else {
      const fresh = await claimSession(token);
      if (fresh) setToken(fresh);
    }
  }
  void resume();
}

if (getToken()) void boot();
else goLogin();
