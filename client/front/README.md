# The server: login and character select

The front flow (`client/front/`): login, character select and what the client takes from the live server. The API rule: [net/README.md](../net/README.md).

`main/main.tscn` (`DmMain`) is the project's main scene: the boot and front flow (login, register, the online gate, character select, the discipline switch,
the saved login `user://dm_jwt.txt` in this project's own user folder), pointed at the **live server**, then the game scene with the chosen character:

```
/home/ubuntu/tools/godot/godot --path client            # login with a live account (never a real one in a test; tests run on the local mock); pick a discipline
```

- A character that already exists skips the select screen (`resume()`); one whose discipline is not playable goes to the discipline switch. The online gate reads the live
  manifest (`https://muffindevelopment.com/death-muffin/client/manifest.json`, its `online` block).
- **One character per account.** A discipline card selects the account's main character and switches its discipline (`DmApi.load_or_create_character`, server `POST /character`); only an account with no character gets a new one. Settings has **Log out** (final save, the token dropped,
  the login screen) and **Switch character** (final save, the party left, the select screen on the same token; the login screen only when the server refuses the token: `DmFrontFlow.switch_character`).
- **The character's build comes from the server**, read-only, before the game starts (`DmMain.load_build`): the bag's rows (worn gear, set bonuses, the weapon line) and the progression (damage and
  legion tier, boons, vows). `DmNextGame.build_for` builds the hero from them, so the hero's health, spell power and loadout follow the worn gear.
  A bag or progression the server fails to give sends the player back to the login screen with the server's words; nothing is written, created or imported.
- Server errors are shown in the player's words ("Cannot reach server — check your connection", the server's own `error`, "Request failed: 502"); a stored login with the server unreachable lands on
  the login screen saying "Online opens soon".
- **Value is the server's** ([Value on the server](../next/rewards/AUTHORITY.md)): the kill reports, the drops claimed into the bag, the progression's and the bag's saves all go to the live API with the logged-in character.
- **Crash report and update notice:** the automatic crash report (`DmMain._send_crash_report`, DmCrashWatch; with the combat core's crash note since
  2026-10-18: native/README.md "Crash notes") and the update notice (`DmNextGame._start_update_check`,
  DmUpdateCheck). Log out, Switch character and a discipline change (Settings, the class
  panel) save and hand over (`tests/front.gd` "hand-overs"). The four necromancer disciplines and the Reaper play (`tests/rites.gd` "the disciplines", "the Reaper").
