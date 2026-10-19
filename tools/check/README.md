# The game's setup: tools/check/prep.sh

Every checkout of the game needs things git does not hold before a test, a screenshot or a build can run. `tools/check/prep.sh` is the one
script that makes them, for every caller: a session's worktree, the Discord agent's jobs (`server/death-muffin/discord-agent/README.md`),
GitHub CI and the client publish (`server/death-muffin/test-channel/prepare-rebuild.sh`).

```
bash tools/check/prep.sh                       # this checkout: run it in every new worktree and after switching branches (seconds when cached)
bash tools/check/prep.sh --windows             # also the Windows combat core and its symbols (exports, previews, releases)
bash tools/check/prep.sh --no-bake             # without the crowd's baked models
bash tools/check/prep.sh --keys                # the cache keys of this checkout, one per piece
bash tools/check/prep.sh --warm <rev>          # fill the cache for <rev> from a scratch worktree of it (nothing to do when it is all cached)
node --test tools/check/test/*.test.mjs        # its tests (a throwaway repository with stand-ins; also in CI)
```

## The pieces

| Piece | Where it goes (generated, git-ignored) | Made of (its key) | Built by |
|---|---|---|---|
| `core` | the Linux library in client/bin | `native/` | `native/build.sh linux` |
| `win` (with `--windows`) | the Windows library in client/bin, its symbols in native/build/symbols | `native/` | `native/build.sh windows` |
| `import` | client/.godot | `client/assets/`, `client/project.godot` | Godot's `--import` |
| `bake` | the crowd's baked folder under client/assets/crowd | the crowd baker's inputs (`client/crowd/`, the creature, model and animator code, the enemy table, the models) and `native/` | `client/tools/bake_crowd.sh` |
| `lobby` | the lobby's node_modules | the lobby's `package.json` and `package-lock.json`, the node version | `npm ci` |

A key is a hash of the git tree of those inputs at the checkout's HEAD (Markdown files left out, so a README edit costs nothing) and the Godot
version. The same inputs give the same key everywhere, so a piece is built once per change and copied after that. Godot's import always runs after
the copy: an import seeded from another key (the newest) only saves time and is never stale. A checkout remembers the keys it holds
(a small key file beside each piece: .prep-core and .prep-win in the core's build folder, .prep-bake in the baked folder, .prep-lobby in the
lobby's packages), so a second run skips what is current.

The last line says what happened, for scripts and logs:
`PREP core=<kept|cached|built> win=<…|-> import=<cached|seeded|kept|fresh> bake=<…|skipped> lobby=<…|installed|missing|-> stored=<kinds|-> seconds=<n>`.

## The cache

- **On the VPS:** `~/death-muffin/build-cache/<kind>-<key>` (`DM_BUILD_CACHE`), about 700 MB per full set; the newest 6 of each kind are kept. An
  entry appears whole (copied aside, then renamed), so a reader never sees half of one. Deleting the folder is always safe: the next run rebuilds.
- **In CI:** `actions/cache` keeps one folder per kind (`DM_PREP_SLOTS`, each holding its key in `.key`), restored by the keys `--keys` prints; the
  first shard saves what it had to build (`.github/workflows/ci.yml`). godot-cpp is only fetched when the combat core itself must be rebuilt.

## What is never stored

- **A piece made from uncommitted files.** It is built in the checkout and used there only.
- **Anything from the Discord agent's sandbox.** The runner fills the cache outside it with `--warm <base>` (the job's base revision on `main`,
  approved code, built with that revision's own copy of this script), and the sandbox runs `--read-only`: it copies what matches the job's own
  inputs and builds only what the job changed. A job can never plant a library, an import or a bake that another job or a release then loads. A job
  that changes the lobby's lockfile gets a plain line that its packages are not cached (the sandbox cannot download them).
- **An import made with the licensed flipbook sheets present** (copied into the effects' sheets folder by a publish,
  `tools/godot/fx-sheets-sync.sh`): the sheets stay out of the shared cache.

## CI is the gate

GitHub CI (`.github/workflows/ci.yml`) runs on every push to every branch: the backend and lobby tests, hygiene, the model check, this
script's tests, and every game suite split over six machines by their recorded times. A run on `main` is never cancelled; a newer push to a
branch replaces that branch's older run. Nothing is merged, deployed or published until CI passed it (DECISIONS B59, CLAUDE.md):

```
tools/check/ci.sh status <rev>                 # passed | failed | pending | none, and the run's link
tools/check/ci.sh wait <rev> [<minutes>]       # waits (default 60): exit 0 passed, 1 failed or cancelled, 2 no run or out of time
tools/check/ci.sh failed <rev>                 # the game suites that failed (one per line)
```

- **A verdict belongs to the files, not the commit.** A run of any commit with exactly the same tree counts, so a fast-forward of `main`, a
  re-push or a merge that changed nothing never waits for CI again.
- **One copy of the recent runs for the whole machine** (`~/death-muffin/ci-status/`), refreshed with conditional requests: once a minute
  without a token (GitHub allows 60 calls an hour), every 15 s with a read-only token in `~/death-muffin/private/github-api-token`.
- **`deploy-release.sh` and `publish-godot-client.sh` refuse a revision CI has not passed** (judged by that revision's own `ci.sh`; a revision
  from before the gate has none, so a rollback to an older build still works). While GitHub is down, `DM_CI_GATE=off` deploys or publishes
  anyway and says so, after the full set ran here (`tools/rebuild/run-client-tests.sh`).
- **The Discord agent** waits for CI on its proposal's branch instead of checking locally (1 to 3 suites that fail only there get one re-run
  here), and its ship waits for CI on the merged change before it takes the deploy lock. Approvals that wait for a ship go out with it: one
  merge, one CI run, one publish; a batch CI fails is shipped one change at a time, so the change that breaks it is the one that comes back.
  While GitHub is down its config's `ciGate: false` brings back the local check (server/death-muffin/discord-agent/README.md).
