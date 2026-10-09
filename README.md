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
| `PATCH_NOTES.json` | Player-facing patch notes, newest first; every client publish and backend deploy publishes them to the launcher and the site (`announce-release.sh`) |
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
tools/godot/run-all-tests.sh        # every godot/tests/*/ suite headless; prints one line per suite, non-zero exit on any failure (long)
npm run test:rules                  # shared rules (vitest, server/rules)
npm run test:server                 # backend suites (node --test)
npm test --prefix server/death-muffin/lobby     # lobby + relay (run `npm ci --prefix server/death-muffin/lobby` once)
npm run typecheck                   # tsc --noEmit
launcher/tests/run-local.sh         # launcher logic tests
```

Run one Godot suite: `godot --headless --path godot --script res://tests/<name>/run.gd`. `tests/online_live` needs the live
backend and is opt-in. `tools/godot/playtest.sh` runs the scripted bot playtest. CI (`.github/workflows/ci.yml`) runs the
backend, lobby and a subset of Godot suites on `main`.

## Export, publish, deploy

All three are separate and none runs on its own. Only deploy or publish with checks passing, from a committed revision.

- **Client export:** `godot --headless --path godot --export-release "Windows Desktop" build/win64/DeathMuffin-godot-slice.exe`
  (presets in `godot/export_presets.cfg`, templates in `~/.local/share/godot/export_templates/4.7.2.stable/`; `godot/build/` is gitignored).
- **Publish the client:** `server/death-muffin/publish-godot-client.sh <git-rev>`. Exports that revision in a scratch worktree,
  hashes the files, copies them to `/var/www/death-muffin/client/<version>/` and writes `manifest.json` last. It carries the
  `online` block over from the live manifest, so publishing never opens or closes online play. The launcher downloads from there.
  Then `announce-release.sh` updates the launcher/site patch notes, posts the update in #deathmuffin and marks fixed bug reports
  released (put a new top entry in `PATCH_NOTES.json` first for a named release; otherwise the commit subjects are used).
- **Online gate:** `server/death-muffin/set-online.sh on|staff|off ["message"]` edits only the manifest's `online` block
  (`on` = everyone, `staff` = staff accounts only, `off` = nobody; the game reads it about once a minute). Online is `on`
  since 2026-10-09.
- **Deploy the backend:** `server/death-muffin/deploy-release.sh [rev] [migration.sql ...]`. Backend plus release notes only. It
  exports the revision with `git archive`, runs the rules and server tests, backs up the DB and runtime and writes a
  `ROLLBACK.sh`, applies the named migrations from `backend/migrations/` (additive and idempotent only), installs the code,
  restarts `death-muffin-auth`, checks health, publishes release/patch notes, and refuses a revision that does not contain
  `origin/main` (`ALLOW_BEHIND_MAIN=1` for a deliberate rollback). Do not edit the installed backend files by hand.
- **Launcher:** version in `launcher/windows/DeathMuffinLauncher.csproj`; the "Windows launcher" GitHub workflow builds and releases it.
- **Services (systemd):** `death-muffin-auth` (:5190), `deathmuffin-lobby` (:5192). The Socket.IO realtime service (:5191) is retired.

## Assets

Generated art, audio and models: [ASSET_PIPELINE.md](ASSET_PIPELINE.md). Reuse what exists first (see [CLAUDE.md](CLAUDE.md)).
