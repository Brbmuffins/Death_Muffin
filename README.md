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

Godot 4.7.2 is at `/home/ubuntu/tools/godot/godot` (`GODOT` env var overrides it in the scripts). The renderer is
`gl_compatibility`.

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
