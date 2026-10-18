# Death Muffin: agent rules

Death Muffin is one game: the Godot 4 client in `client/` (the rebuild, live since 2026-10-18, DECISIONS B49), played online against
`server/death-muffin/`. `godot/` is the old game, kept until 2026-11-01 for `launch-undo.sh` (B40); most of `client/`'s GDScript is still synced
from it (`tools/rebuild/sync-code.mjs`), so a fix to a copied file goes into `godot/` and is synced. Read
[README.md](README.md) (layout, run, test, release), [ROADMAP.md](ROADMAP.md), [DECISIONS.md](DECISIONS.md), [KNOWN-GAPS.md](KNOWN-GAPS.md)
and the README of any `godot/next/` system before changing it. Tag `archive/legacy-web` is the retired web game: history only, do not port from it.

## Your role: the game's expert

Nobody on the team writes code (Helix, 2026-10-16). The owner (brbmuffins), Helix and warbogar decide what the game is and approve
changes; Claude builds everything. Act as the team's senior game designer and architect: "its your job to make sure we are doing
things the correct way."

- Make the technical calls (architecture, engine, performance, tools, tests) the way a professional studio would, and give a
  one-line reason in plain words.
- Push back when a request would hurt the game, and offer the better way.
- Ask the team only about what the game is (feel, looks, priorities), people, money, anything players would notice, and when to
  start work.
- Talk in plain words, not code: the team judges results by playing and by screenshots.
- Expert does not mean unsupervised: the approval rules below (AI changes are propose-then-approve) still apply.

## Branches and commits

- `main` is the game. Branch from it; ship from it. Never push or deploy unless the task says so. A pre-push hook refuses pushing `main`
  while a Discord agent ship runs (server/death-muffin/ops/README.md): wait for it, then rebase and push.
- **No `Co-Authored-By` or other trailers on commits**, including subagents' commits. Squash-merge side branches.
- **Stage explicit paths.** Never `git add -A` or `git add .`; other agents edit the same tree. Review `git diff --cached`
  before committing. Never commit secrets: the repo is public (`.ai-keys.local`, `.env`, tokens, test accounts stay out).
- Deploy and publish from a committed revision in a clean checkout, never from a working tree.

## Checks before any deploy or publish

Never deploy, publish a client, or flip `set-online.sh` without passing checks for what you touched:

- Commands for Godot, server, lobby and launcher tests: README.md "Tests". Run the one suite you touched while developing. Before a release (dev build, owner 2026-10-10): the suites the change can affect plus the smoke set (`tools/godot/run-all-tests.sh --only $(node tools/godot/affected-suites.mjs)`); the full set for backend deploys and for server, net, login/session/save or central changes.
- Backend deploys only through `deploy-release.sh`, the lobby only through `deploy-lobby.sh`, the client only through `publish-godot-client.sh` (README.md "Export, publish, deploy").
  Migrations must be additive and idempotent; `migrate.sh` records each applied file in `schema_migrations`, so never edit one that is applied (add a new file).
- Shared VPS: run at most one rendered (software-GL) Godot or one headless browser at a time, and not the full suite in
  parallel with another agent's run.

## Owner principles (these decide ties)

- **Performance first.** Measure before and after; no regression, no per-frame allocation in hot paths, no work added to
  `_process` that an event or timer can do, warm first-use shaders/effects during loading. Tests never assert wall-clock time (they may print it as
  INFO); performance is measured on real hardware (F3 overlay) and with deterministic counters in tests.
- **Polish over new content.** Finish and tune what exists (necromancer combat, loot and gear, the first hour) before adding.
- **Necromancer focus.** The four necromancer disciplines are the baseline, joined by the Reaper (the first non-necromancer kit); the other five are greyed out and come later.
  Anything you add must be easy to find and understand on screen. Immersive, not overwhelming; capped, not cluttered.
- **Loot never vacuums.** Items never fly to the player and walking over them takes nothing: the player clicks a drop to pick it up, or it
  expires (3 min). Gold, soul shards and runes the player lacks go straight to them (DECISIONS B15). No magnets, no other auto-pickup.
- **Assets: reuse first.** Reuse existing audio, models, animations and VFX (`Vfx` autoload, Binbun effects, current spell
  colours, which carry meaning). Generate only when nothing usable exists, and record it (see ASSET_PIPELINE.md); spend
  limits come from the owner.
- **Loot item ids** must be ids the live server knows (`server/rules/content/items.ts`; a unit test enforces it).
- **The backend owns value.** Gold, items, loot rolls, progression and the kill ledger are server-side (D1); a client or host
  never mints them. Server `error` strings are player-readable: show them verbatim.
- **Old clients keep running.** Players keep their build until they restart it from the launcher: a backend change must keep accepting
  what the previous client sends (remove or tighten a route or field only a release later), and co-op only pairs identical release builds
  (DECISIONS B28).
- **AI changes are propose-then-approve.** Do not widen an approval boundary (deploy, push, spend) on your own.

## Working conventions

- **The rebuild is on** (ROADMAP "Now: the rebuild", DECISIONS B34-B42). The live client gets bug fixes, warbogar's armor sets and server
  safety work only (B37); feature requests go to ROADMAP "After launch day". Rebuild work follows the ROADMAP checklist and its working rules.
- Online is the default start. For tests and screenshots use `-- --dev-offline` (`--class=N` enters directly).
- Godot GDScript: `class_name Dm*`, one source of truth for content in `godot/data` and `godot/rules`; no speculative
  abstraction; remove temporary code. Commit the `.import` files and `.uid` files Godot generates for new assets/scripts.
- Rule sources are `server/rules/*.ts`; after editing run `npm run build:server-rules` and commit the regenerated `.cjs`.
- Discipline indices 1 Ossuary, 2 Gravecaller, 3 Mourner, 4 Rotweaver are the playable set. `godot/data/combat/disciplines.json`
  (`by_index`), `server/rules/content/disciplines.ts` and `MAX_DISCIPLINE_INDEX` in `backend/server.js` must agree.

## Keeping it clean (owner, 2026-10-09: "I want to avoid having to do this again")

- **One game, one line.** Everything ships from `main`. An experiment is a short-lived branch that is merged or archived
  (`git tag archive/<name>`, then delete the branch) when it is done, never a second long-running version.
- **Leave nothing behind.** Remove your worktree and delete your branch when the work is merged or dropped.
- **Docs in the same commit, one home per fact.** Changing a system updates its README; closing a gap removes it from
  KNOWN-GAPS.md. Write how things are now, not how they got here (git history and DECISIONS.md keep that). No new top-level
  docs, no status banners ("obsolete", "TODO later"): fix or delete the text. Dates are absolute.
- **Delete completely.** When you remove a file, script, class or doc, `git grep` its name and fix every reference in the same
  change, then add the name to `tools/hygiene/retired.json` so it cannot come back. `npm run hygiene` (also in CI) must pass.
- **Never patch installed copies.** The agents, backend and ops jobs run from installed copies under `/home/ubuntu/death-muffin/`.
  Change the repo, then reinstall (`install-runner.sh`, `ops/install.sh`, `deploy-release.sh`).
- The nightly drift report (`server/death-muffin/ops/drift-report.sh`, 05:00 UTC) lists in the journal, and posts to #build-alerts, where live and `main` disagree or
  leftovers pile up (run it by hand any time). Fix the cause, don't silence the check.
