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
