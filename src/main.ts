import { SceneManager } from './scenes/SceneManager';
import { LoginScene } from './scenes/LoginScene';
import { CharacterSelectScene } from './scenes/CharacterSelectScene';
import { HubScene } from './scenes/HubScene';
import { ArenaScene } from './scenes/ArenaScene';
import { BossScene } from './scenes/BossScene';
import { ApiError, getCharacter, getToken, saveProgress, setToken } from './net/api';

const manager = new SceneManager();

function goLogin() {
  manager.goto(new LoginScene(resume));
}

function goCharacterSelect() {
  manager.goto(new CharacterSelectScene(goHub));
}

function goHub(character: any, toast?: string) {
  manager.goto(new HubScene(character, () => goArena(character), () => goBoss(character), toast));
}

function goBoss(character: any) {
  manager.goto(
    new BossScene(character, (xpEarned) => {
      const leveled = applyProgress(character, xpEarned);
      goHub(
        character,
        leveled
          ? `Level up! You are now level ${character.level}`
          : xpEarned > 0
            ? `+${xpEarned} XP — The Void Warden is defeated`
            : 'You escaped the Void Warden',
      );
    }),
  );
}

function goArena(character: any) {
  manager.goto(
    new ArenaScene(character, (xpEarned) => {
      const leveled = applyProgress(character, xpEarned);
      goHub(
        character,
        leveled
          ? `Level up! You are now level ${character.level}`
          : xpEarned > 0
            ? `+${xpEarned} XP`
            : undefined,
      );
    }),
  );
}

// XP-to-next-level = level × 100; `experience` is progress into the current
// level. Saved on level-up / hub return, not per kill (server design intent).
function applyProgress(character: any, xpEarned: number): boolean {
  if (xpEarned <= 0) return false;
  character.experience = (character.experience ?? 0) + xpEarned;
  let leveled = false;
  while (character.experience >= character.level * 100) {
    character.experience -= character.level * 100;
    character.level += 1;
    leveled = true;
  }
  saveProgress({
    characterId: character.id,
    level: character.level,
    xp: character.experience,
    gold: character.gold ?? 0,
    stat_str: character.stat_str ?? 5,
    stat_agi: character.stat_agi ?? 5,
    stat_int: character.stat_int ?? 5,
    stat_vit: character.stat_vit ?? 5,
  }).catch((err) => console.warn('[progress] save failed:', err));
  return leveled;
}

// Routes by account state: existing character → hub, none yet (404) →
// character select, invalid/expired token → login. Used both after a
// successful login and on page load, so the sessionStorage JWT survives
// a reload within the same tab.
async function resume() {
  try {
    const character = await getCharacter();
    goHub(character);
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) {
      goCharacterSelect();
    } else {
      setToken(null);
      goLogin();
    }
  }
}

if (getToken()) resume();
else goLogin();
