# Death Muffin

A dark-fantasy action RPG. You play a necromancer: raise corpses as thralls, fight waves and bosses across a connected
world (Chapterhouse, Sexton's Acre, Alchemist's Wing, Hollow Graves, Catacomb Warren, Marrow Ossuary, Drowned Nave, Bone
Coliseum, Bell Sanctum, Plague Cloister, Cinder Pyre, Mourning Fen, and the Catacomb Depths), gather and craft, and chase gear.

**One game, one client:** a Godot 4 client (`godot/`), played online against the Death Muffin backend. Four necromancer
disciplines are playable (Ossuary, Gravecaller, Mourner, Rotweaver); the other five show greyed out as "Coming later".
Parties of up to 4 join through a lobby and relay. Players get the game through the Windows launcher at
https://muffindevelopment.com/death-muffin/. Offline play is not a player edition; `-- --dev-offline` exists for testing only.

Branch: `main` is the game (the only branch). The retired three.js web game is kept as tag `archive/legacy-web`; older work branches are `archive/*` tags.
Where to read next: [ROADMAP.md](ROADMAP.md), [DECISIONS.md](DECISIONS.md), [KNOWN-GAPS.md](KNOWN-GAPS.md), [CLAUDE.md](CLAUDE.md) (agent rules).

## Layout

| Path | What |
|---|---|
| `godot/` | The Godot 4.7 project. Entry `main/main.gd` (`DmMain`) -> front flow (`front/`) -> `DmNextGame` (`next/next_game.gd`). `next/` holds the game systems (each folder has a README), `rules/` and `data/` the game rules and content, `session/` + `net/relay/` multiplayer, `enemies/` enemy scenes, `tests/` the headless suites |
| `server/death-muffin/backend/` | Auth and game API on 127.0.0.1:5190 (accounts, characters, bag, loot, kill ledger, sessions). Plain Node `.cjs` + MySQL, migrations in `migrations/` |
| `server/death-muffin/lobby/` | Lobby + packet relay (WebSocket), :5192 |
| `server/rules/` | Shared game rules in TypeScript. `npm run build:server-rules` compiles them to the `.cjs` files the backend loads |
| `server/death-muffin/site/` | The launcher download page |
| `server/death-muffin/` (scripts) | `publish-godot-client.sh`, `set-online.sh`, `deploy-release.sh`, `announce-release.sh`, nginx and systemd files |
| `launcher/windows/` | The Windows launcher (.NET Framework 4.8, version in `DeathMuffinLauncher.csproj`). See its README |
| `tools/` | `tools/godot/` test runner, asset sync and playtest scripts; `tools/ai/` Gemini and Tripo generation; `tools/blender*`, `tools/audio/`, SQL generators |
| `public/`, `art-manifest/` | Source art, models and audio (synced into `godot/assets/`); generation records |
| `PATCH_NOTES.json` | Player-facing patch notes, newest first; published to the launcher and site by `announce-release.sh` |
| `docs/` | Design notes and audits that are still referenced |

## Run the client

Godot 4.7.2 is at `/home/ubuntu/tools/godot/godot` (`GODOT` env var overrides it in the scripts). The default renderer is
`gl_compatibility`; players can opt into Mobile (Vulkan), see "Renderer" below.

```
godot --headless --path godot --import          # first time, and after adding assets
godot --path godot                              # normal start: online, needs the live server
godot --path godot -- --dev-offline             # testing only: local accounts in user://dm_dev_offline_db.json, no server
godot --path godot -- --dev-offline --class=2   # skip the front flow, enter as account "tester" (1 Ossuary ... 4 Rotweaver)
```

`--world-demo` is an alias of `--dev-offline --class=2`. Older launch args (`--online`, `--offline`, `--next`) are accepted and
ignored. Controls: WASD or click to move, LMB attacks (Shift+LMB fires at the cursor), 1-4 and RMB cast rites, F3 performance
overlay, T waystone travel in the Chapterhouse, G auto-combat. F9 breaks all seals, but only on a dev-access account.
`godot/tests/world/tour.sh` takes one screenshot per area. A VPS has no GPU: rendered runs use software GL and
`xvfb-run`, one at a time.

## Tests

```
tools/godot/run-all-tests.sh        # every godot/tests/*/ suite headless, --jobs N at once (default $DM_TEST_JOBS or 6, keep <= 8); one line per suite as it finishes, non-zero exit on any failure
tools/godot/run-all-tests.sh --only enemies,next_hud/run.gd   # just those dirs/files (--list prints the selection, unknown name exits 2); --jobs 1 = strictly serial
npm run test:rules                  # shared rules (vitest, server/rules)
npm run test:server                 # backend suites (node --test)
npm test --prefix server/death-muffin/lobby     # lobby + relay (run `npm ci --prefix server/death-muffin/lobby` once)
npm run typecheck                   # tsc --noEmit
launcher/tests/run-local.sh         # launcher logic tests
```

Run one Godot suite: `godot --headless --path godot --script res://tests/<name>/run.gd`. `tests/online_live` needs the live
backend and is opt-in. `tools/godot/playtest.sh` runs the scripted bot playtest. CI (`.github/workflows/ci.yml`) runs the
backend, lobby and a subset of Godot suites on `main`.
Tests never assert wall-clock time: timing figures print as `INFO perf:` lines. FPS is judged on real hardware (F3 overlay);
suites only check deterministic counters.

## Renderer

Settings > Graphics > Renderer picks Compatibility (OpenGL 3.3, the default) or Mobile (Vulkan, experimental); it applies after a restart (the
row has a Restart now button). The choice is `user://dm_renderer.cfg` (Windows: `%APPDATA%\Godot\app_userdata\Death Muffin (Godot slice)\dm_renderer.cfg`),
a project-settings override named by `application/config/project_settings_override` in `godot/project.godot`, which the engine reads before the
renderer starts, so no launcher change is needed. No file means Compatibility. Safety nets: if Vulkan cannot start the engine falls back to
OpenGL 3 (`rendering/rendering_device/fallback_to_opengl3`) and the game runs on Compatibility; a Mobile run that dies in its first 25 s
(`user://dm_renderer.guard` survives) puts the choice back to Compatibility on the next launch and says so in Settings. A crash before the first
script runs is the one case the game cannot see: delete the cfg file. The F3 overlay's last line and every bug report (`renderer`) show the renderer
actually running. Other ways back: `DeathMuffin.exe -- --renderer=compat` (rewrites the file, relaunches), or `--rendering-method gl_compatibility` for one run.
**Threading options (A/B, experimental, restart required, default off).** Two more checkboxes under the Renderer row write into the SAME override file:
"Physics on a separate thread" (`physics/3d/run_on_separate_thread=true`) and "Separate render thread" (`rendering/driver/threads/thread_model=2`,
offered only while Mobile is the chosen renderer; the engine itself calls it experimental and it crashed at startup with OpenGL here, so Compatibility
is not offered it, and choosing Compatibility drops it). All our space queries (`intersect_ray` in `DmPfUtil.wall_between`, `DmEnemyGargoyle.clear_line_to`)
run inside the enemy brain tick in `_physics_process`, bodies are only moved there, and the headless suites (enemies, thralls, bosses, interp, session,
world, next) pass with the physics thread forced on; real-GPU stability is what the A/B tells. The crash guard covers all three (Mobile, physics thread,
render thread): a run that dies in its first 25 s puts ALL back to defaults and says so in Settings. `DeathMuffin.exe -- --safe-graphics` (or
`--renderer=compat`) also resets all of them and relaunches. The F3 renderer line and bug reports (`renderer`) end with `, physics thread` /
`, render thread` for what is running.
**Owner A/B on your PC:** (1) pick one fixed fight (same area, same class, same wave) and note F3 `avg`/`p50`/`worst` frame ms for ~30 s; compare
frame ms, not core usage: with the Frame rate setting on Max (`Engine.max_fps` 0) one pegged main core is expected. Repeat the whole test with Frame rate
at your monitor's rate as well. (2) Change ONE toggle (physics thread; then, on Mobile, render thread; then Mobile alone), Restart now, repeat the same
fight, compare. (3) Anything odd (stutter, enemies jittering, crash): untick it, or launch with `-- --safe-graphics`, and send a bug report.

Code branches on `DmRenderer.active()` / `is_mobile()`, never on the setting. Shaders cannot be compiled for Mobile headless (the VPS has no Vulkan);
Compatibility-specific spots to compare by eye on a Mobile run: Binbun `depth_texture` effects (18 shaders) assume Vulkan depth, so under Mobile their
proximity fade is the intended one; the water shader's `GL_COMPATIBILITY` define is 0; `DmFxRing` motes pass sRGB colours (Compatibility linearises
MultiMesh instance colours itself); `world_builder.gd` uses a plain-colour ambient and tiled floors for Compatibility's light handling; ubershaders and
pipeline precompile exist only on Mobile.

## Export, publish, deploy

Client publish, backend deploy and the online gate are separate; none runs on its own. Only from a committed revision with
checks passing. The full procedure (scripts, release notes, rollback, services) is in
[server/death-muffin/README.md](server/death-muffin/README.md).

- **Client:** `server/death-muffin/publish-godot-client.sh <git-rev>` exports the `Windows Desktop` preset (`godot/export_presets.cfg`) and publishes it for the launcher.
- **Backend:** `server/death-muffin/deploy-release.sh [rev] [migration.sql ...]`. Never edit the installed backend by hand.
- **Release notes:** both scripts end with `announce-release.sh`. Put a new top entry in `PATCH_NOTES.json` for a named release.
- **Online gate:** `server/death-muffin/set-online.sh on|staff|off ["message"]`; live state is `on`.
- **Launcher:** version in `launcher/windows/DeathMuffinLauncher.csproj`; see [launcher/windows/README.md](launcher/windows/README.md).

## Assets

Generated art, audio and models: [ASSET_PIPELINE.md](ASSET_PIPELINE.md). Reuse what exists first (see [CLAUDE.md](CLAUDE.md)).
