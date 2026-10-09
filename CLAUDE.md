# Death Muffin: agent rules

Death Muffin is one game: the Godot 4 client in `godot/`, played online against `server/death-muffin/`. Start with
[README.md](README.md) (layout, run, test, publish, deploy), [ROADMAP.md](ROADMAP.md), [DECISIONS.md](DECISIONS.md) and
[KNOWN-GAPS.md](KNOWN-GAPS.md). Each system under `godot/next/` has its own README; read it before changing that system.
The web game is gone from `main` (tag `archive/legacy-web`, history only): do not port from it or fix it.

## Branches and commits

- `main` is the game. Branch from it; ship from it. Never push or deploy unless the task says so.
- **No `Co-Authored-By` or other trailers on commits**, including subagents' commits. Squash-merge side branches.
- **Stage explicit paths.** Never `git add -A` or `git add .`; other agents edit the same tree. Review `git diff --cached`
  before committing. Never commit secrets: the repo is public (`.ai-keys.local`, `.env`, tokens, test accounts stay out).
- Deploy and publish from a committed revision in a clean checkout, never from a working tree.

## Checks before any deploy or publish

Never deploy, publish a client, or flip `set-online.sh` without passing checks for what you touched:

- Godot: `tools/godot/run-all-tests.sh` (long; run the relevant suite alone while developing:
  `/home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/<name>/run.gd`).
- Server: `npm run test:rules`, `npm run test:server`, `npm test --prefix server/death-muffin/lobby`, `npm run typecheck`.
- Launcher: `launcher/tests/run-local.sh`.
- Backend deploys only through `server/death-muffin/deploy-release.sh`; client only through `publish-godot-client.sh`.
  Migrations must be additive and idempotent; back up first.
- Shared VPS: run at most one rendered (software-GL) Godot or one headless browser at a time, and not the full suite in
  parallel with another agent's run.

## Owner principles (these decide ties)

- **Performance first.** Measure before and after; no regression, no per-frame allocation in hot paths, no work added to
  `_process` that an event or timer can do, warm first-use shaders/effects during loading. Perf-test budgets keep generous margins.
- **Polish over new content.** Finish and tune what exists (necromancer combat, loot and gear, the first hour) before adding.
- **Necromancer focus.** The four necromancer disciplines are the baseline; the other five are greyed out and come later.
  Anything you add must be easy to find and understand on screen. Immersive, not overwhelming; capped, not cluttered.
- **Loot never vacuums.** Loot does not fly to the player; walk over it or it expires. Do not add magnets or auto-pickup of items.
- **Assets: reuse first.** Reuse existing audio, models, animations and VFX (`Vfx` autoload, Binbun effects, current spell
  colours, which carry meaning). Generate only when nothing usable exists, and record it (see ASSET_PIPELINE.md); spend
  limits come from the owner.
- **Loot item ids** must be ids the live server knows (`server/rules/content/items.ts`; a unit test enforces it).
- **The backend owns value.** Gold, items, loot rolls, progression and the kill ledger are server-side (D1); a client or host
  never mints them. Server `error` strings are player-readable: show them verbatim.
- **AI changes are propose-then-approve.** Do not widen an approval boundary (deploy, push, spend) on your own.

## Working conventions

- Online is the default start. For tests and screenshots use `-- --dev-offline` (`--class=N` enters directly).
- Godot GDScript: `class_name Dm*`, one source of truth for content in `godot/data` and `godot/rules`; no speculative
  abstraction; remove temporary code. Commit the `.import` files and `.uid` files Godot generates for new assets/scripts.
- Rule sources are `server/rules/*.ts`; after editing run `npm run build:server-rules` and commit the regenerated `.cjs`.
- Docs are part of the change. If you change a system, update its README; if you close a gap, remove it from
  KNOWN-GAPS.md. Do not write status banners ("obsolete", "TODO later"): fix or delete the text. Dates are absolute.
- Discipline indices: the client and backend use 1 Ossuary, 2 Gravecaller, 3 Mourner, 4 Rotweaver for the playable set
  (`server/rules/content/disciplines.ts` and `backend/discipline.cjs` must agree).
