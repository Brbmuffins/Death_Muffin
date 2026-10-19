# Death Muffin

A dark-fantasy action RPG. You play a necromancer: raise corpses as thralls, fight waves and bosses across a connected
world (Chapterhouse, Sexton's Acre, Alchemist's Wing, Hollow Graves, Catacomb Warren, Marrow Ossuary, Drowned Nave, Bone
Coliseum, Bell Sanctum, Plague Cloister, Cinder Pyre, Mourning Fen, and the Catacomb Depths), gather and craft, and chase gear.

**One game, one client:** a Godot 4 client (`client/`, with a C++ combat core in `native/`), played online against the Death Muffin backend. Four necromancer
disciplines are playable (Ossuary, Gravecaller, Mourner, Rotweaver), and so is the Reaper, a scythe fighter with a soul bag; the other
five show greyed out as "Coming later".
Parties of up to 4 join through a lobby and relay. Players get the game through the Windows launcher at
https://muffindevelopment.com/death-muffin/. Offline play is not a player edition; `-- --dev-offline` exists for testing only (editor / debug builds; release exports ignore it).

Branch: `main` is the game (the only branch). The retired three.js web game is kept as tag `archive/legacy-web`, the first Godot game (DECISIONS B57) as tag `archive/old-game`; older work branches are `archive/*` tags.
Where to read next: [ROADMAP.md](ROADMAP.md), [DECISIONS.md](DECISIONS.md), [KNOWN-GAPS.md](KNOWN-GAPS.md), [CLAUDE.md](CLAUDE.md) (agent rules).

## Layout

| Path | What |
|---|---|
| `client/` | The game (DECISIONS B49): its own Godot 4.7.2 project on Forward+ with the C++ combat core ([client/README.md](client/README.md)). Entry `main/main.gd` (`DmMain`) -> front flow (`front/`) -> `DmNextGame` (`next/next_game.gd`). `next/` holds the game systems (each folder has a README), `rules/` and `data/` the game rules and content, `session/` + `net/relay/` multiplayer, `core/` and `crowd/` the combat core's host and the crowd, `tests/` the headless suites |
| `native/` | The game's C++ combat core (GDExtension): enemies, thralls, statuses and corpses; built into `client/bin/` by `native/build.sh` ([native/README.md](native/README.md)) |
| `server/death-muffin/backend/` | Auth and game API on 127.0.0.1:5190 (accounts, characters, bag, loot, kill ledger, sessions). Plain Node `.cjs` + MySQL, migrations in `migrations/` |
| `server/death-muffin/lobby/` | Lobby + packet relay (WebSocket), :5192 |
| `server/death-muffin/relay/` | UDP co-op relay (ENet), :5193/udp |
| `server/rules/` | Shared game rules in TypeScript. `npm run build:server-rules` compiles them to the `.cjs` files the backend loads |
| `server/death-muffin/site/` | The launcher download page |
| `server/death-muffin/` (scripts) | `publish-godot-client.sh`, `set-online.sh`, `deploy-release.sh`, `announce-release.sh`, nginx and systemd files |
| `launcher/windows/` | The Windows launcher (.NET Framework 4.8, version in `DeathMuffinLauncher.csproj`). See its README |
| `teamapp/` | The team app (DECISIONS B54, B55): a Windows tray app for the three team PCs that runs jobs needing a real graphics card (screenshots of a proposal on Low and Ultra first), with its own updates; `teamapp/windows/` the app, `teamapp/tests/` its tests ([teamapp/README.md](teamapp/README.md)) |
| `tools/` | `tools/rebuild/` the game's test runner, suite selector and area builder; `tools/godot/` the release's art pack tools; `tools/assets/` the model check; `tools/ai/` Gemini and Tripo generation; `tools/blender*`, `tools/audio/`, SQL generators |
| `public/`, `art-manifest/` | Source art, models and audio (the masters of what is in `client/assets/`); generation records |
| `PATCH_NOTES.json` | Player-facing patch notes, newest first; published to the launcher and site by `announce-release.sh` |
| `docs/` | Design notes and audits that are still referenced |

## Run the client

Godot 4.7.2 is at `/home/ubuntu/tools/godot/godot` (`GODOT` env var overrides it in the scripts). The renderer is Forward+.

```
bash client/setup.sh                              # first time and after switching branches: builds the combat core (Linux) and imports
bash client/tools/bake_crowd.sh                   # the crowd's baked models (not committed), to see enemies and thralls
godot --path client                               # normal start: online, needs the live server
godot --path client -- --dev-offline              # testing only: local accounts in user://dm_dev_offline_db.json, no server
godot --path client -- --dev-offline --class=2    # skip the front flow, enter as account "tester" (1 Ossuary ... 4 Rotweaver, 11 Reaper)
godot --path client -- --benchmark                # the in-game benchmark (also the Benchmark button on character select); offline, see client/next/perf/README.md
```

`--world-demo` is an alias of `--dev-offline --class=2`. Controls: WASD or click to move, LMB attacks (Shift+LMB fires at the cursor), 1-4 and
RMB cast rites, F3 performance overlay, T waystone travel in the Chapterhouse, G auto-combat. F9 breaks all seals, but only on a dev-access account.
`client/tools/qa_shots.sh <plan.json> <out>` renders screenshots of a shot plan (client/README.md "Screenshots for proposals"). A VPS has no GPU:
rendered runs use the software Vulkan driver and `xvfb-run`, one at a time.

## Tests

```
tools/rebuild/run-client-tests.sh                 # every game suite (client/tests: <name>.gd or a folder <name>/run.gd), 8 side by side (fewer on a busy machine), after client/setup.sh and client/tools/bake_crowd.sh; one line per suite
tools/rebuild/run-client-tests.sh --only surge,value   # just those
node tools/rebuild/affected-suites.mjs            # the suites a change can affect, plus the smoke set (the Discord agent's quick check; --explain says why)
npm run test:rules                                # shared rules (vitest, server/rules), with the client parity fixtures
npm run test:server                               # backend suites (node --test)
npm test --prefix server/death-muffin/lobby       # lobby + relay (run `npm ci --prefix server/death-muffin/lobby` once)
npm run typecheck                                 # tsc --noEmit
npm run hygiene                                   # stale docs and paths, retired terms, big files, texture imports
npm run check:models                              # every model's budget, materials, skeleton and clips
launcher/tests/run-local.sh                       # launcher logic tests
teamapp/tests/run-local.sh                        # team app logic tests (a local file server and a stand-in game; no Windows)
teamapp/tests/compile-check.sh                    # the whole team app, UI included, compiled against the .NET Framework 4.8 reference assemblies
```

Run one suite: `godot --headless --path client --script res://tests/<name>.gd`. CI (`.github/workflows/ci.yml`) runs the backend, lobby,
hygiene, model check and every game suite on `main`.
Tests never assert wall-clock time: timing figures print as `INFO perf:` lines. FPS is judged on real hardware (F3 overlay);
suites only check deterministic counters.

## Export, publish, deploy

Client publish, backend deploy and the online gate are separate; none runs on its own. Only from a committed revision with
checks passing. The full procedure (scripts, release notes, rollback, services) is in
[server/death-muffin/README.md](server/death-muffin/README.md).

- **Client:** `server/death-muffin/publish-godot-client.sh <git-rev>` exports the `Windows Desktop` preset of the game and publishes it for the launcher; the art pack (`tools/godot/assets-fp.sh`) is reused while nothing it is made of changes. A rollback publishes an earlier revision the same way.
- **Backend:** `server/death-muffin/deploy-release.sh [--if-changed] [rev] [migration.sql ...]`. Never edit the installed backend by hand. A Discord agent ship runs it with `--if-changed` before publishing the client, so a change that touches the server goes live on both sides (a no-op when the installed server files already match).
- **Release notes:** both scripts end with `announce-release.sh`, which posts the release in #build-alerts. Put a new top entry in `PATCH_NOTES.json` for a named release. A notice lists only the patch-note lines added since the last announced release; lines added to an existing entry (Discord ships) are titled with the job's proposal title, else its thread name (`RELEASE_TITLE`, passed by the Discord agent), else the newest commit subject.
- **Online gate:** `server/death-muffin/set-online.sh on|staff|off ["message"]`; live state is `on`.
- **Launcher:** version in `launcher/windows/DeathMuffinLauncher.csproj`; see [launcher/windows/README.md](launcher/windows/README.md).

## Assets

Generated art, audio and models: [ASSET_PIPELINE.md](ASSET_PIPELINE.md). Reuse what exists first (see [CLAUDE.md](CLAUDE.md)).
