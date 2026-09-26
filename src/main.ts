import './theme/fonts';
import { initRuntime } from './app/GameRuntime';
import { SceneManager } from './scenes/SceneManager';
import { LoginScene } from './scenes/LoginScene';
import { CharacterSelectScene } from './scenes/CharacterSelectScene';
import { WorldScene } from './scenes/WorldScene';
import { NecroBackdrop } from './graphics/NecroBackdrop';
import { ApiError, getCharacter, getToken, setToken } from './net/api';
import type { Character } from './net/types';

const runtime = initRuntime(document.getElementById('scene') as HTMLCanvasElement);

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
const manager = new SceneManager();
let backdrop: NecroBackdrop | null = null;
const getBackdrop = () => (backdrop ??= new NecroBackdrop());
const dropBackdrop = () => {
  backdrop?.dispose();
  backdrop = null;
};

function goLogin() {
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
    }),
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

if (getToken()) void resume();
else goLogin();
