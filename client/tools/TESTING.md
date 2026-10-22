# Testing the client

Setting up a checkout, running the client's suites, and what a suite must do. Each suite and what it checks: [TEST-SUITES.md](TEST-SUITES.md); setup and the CI gate: [tools/check/README.md](../../tools/check/README.md); the client's index: [client/README.md](../README.md).

```
bash tools/check/prep.sh                               # in every new checkout or worktree, and after switching branches: the core for Linux, the import, the crowd's baked models, the lobby's packages (tools/check/README.md)
tools/rebuild/run-client-tests.sh                      # every suite, 8 side by side, one line each (GitHub CI's "Game client tests" jobs run them split over six machines, `--shard 1/6` to `6/6`, 3 at once each)
tools/rebuild/run-client-tests.sh --only surge,value   # just those
node tools/rebuild/affected-suites.mjs                 # the suites a change can affect, plus the smoke set (--explain says why)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/<suite>.gd   # one suite by hand
bash client/tools/coop_local.sh                        # a local lobby and relay for a trial with two game windows (prints the commands; client/next/party/TESTING.md)
```

**Numbers in tests.** A test reads the game's numbers from the data (`DmAbilities`, `DmCombatData`, the content tables) and never types a
total or a tuning value, so adding content or retuning never breaks it (AGENTS.md, DECISIONS B59). A scenario whose outcome depends on a
number (how many casts fit in a clip, how many hits kill, how much gold a run pays) either computes its expectation from the data or makes
the number its own input: `DmQaTune.apply({"combat/abilities": {"abilities": {"<rite>": {"cooldownMs": 300.0}}}})` before the scene is built,
the old value put back (or `DmDb.reset()`) after. Server tests do the same with the rules' exported tables and constants. Fixed design rules
(loot expires in 3 minutes, a party of 4), protocol constants, the parity fixtures and the performance targets (DECISIONS B71) stay typed.

**Suite names.** A suite is named after the system it protects, in snake_case, as a player or the code would call that system: `<system>` (`hud`, `gathering`, `spells`), `<system>_<part>` when one system has several suites (`boss_mire`, `benchmark_rooms`), `core_<part>` for the combat core's own suites and `rules_<area>` for the shared rules' fixtures. A suite with more than one runner is a folder, and each runner is named after what it runs (`lobby/ui`, `relay/udp`). Names carry no history (no `next_`, `game/` or `perf/`, which came from the first game's folders): a renamed or deleted suite's old name is retired in `tools/hygiene/retired.json`.

A new suite goes into `SUITES` in `tools/rebuild/run-client-tests.sh` (and into `PACED` if it plays game time): `npm run hygiene` fails on a suite file the list does not name, a listed name with no file, and a `PACED`, `LANE` or `WAITING` name that is not a suite; a helper that is not a suite goes in `notSuites` in `tools/hygiene/retired.json`.

A suite passes with exit 0, a `PASS` line and no `SCRIPT ERROR` in its log. The runner gives every suite its own user folders, so suites can run side by side, and runs up to five failures again alone at the end. The paced suites
(`PACED` in the runner) play game time faster than real time: by hand they take `--fixed-fps 60` before `--path` (`game_scene`, `rites` and `boss` run faster that way too). Most suites that draw creatures bake the models they need into a scratch folder.
Run `tools/check/prep.sh` in every new checkout or worktree (it lists the extension before the first import; see the script): a script run in a project that was never imported hangs.

`tools/rebuild/run-client-tests.sh` sets `DM_SYNC_NAV=1` for every suite it runs under `--fixed-fps`; a suite that asks for paths in a region enabled moments before (a seal broken, a floor baked) also sets it itself (`OS.set_environment("DM_SYNC_NAV", "1")` in `_initialize`, as `tests/world.gd` does), so it holds when run by hand:
the navigation server merges a new region on a worker thread of its own and a game under `--fixed-fps` outruns it on a loaded machine, so a path asked before the merge ends on the nearest ground
that is merged and a body walks away from where it was sent. The variable makes the merges synchronous, in step with game time (never set in the game).
