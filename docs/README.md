# Documentation map

**Current (2026-10-09): Death Muffin is the Godot rebuild on `godot-next`; the web game and most of the files below describe the frozen web version.** Read these first:

| Question | Read |
| --- | --- |
| What is the plan and what is built? | [ROADMAP](../ROADMAP.md) (top section), [godot/REBUILD.md](../godot/REBUILD.md) (decisions D1-D13, phases, status, code audit) |
| What is still missing vs the web game? | [godot/PARITY.md](../godot/PARITY.md) (open gaps, ranked) |
| How do I run, test and export the Godot client? | [godot/README.md](../godot/README.md), `tools/godot/run-all-tests.sh` |
| Where does each rebuild system live? | [godot/next/README.md](../godot/next/README.md) and the READMEs beside each `godot/next/<system>/` |
| Rules the port follows, UI contract | [godot/PORTING.md](../godot/PORTING.md), [godot/GAME_CONTRACT.md](../godot/GAME_CONTRACT.md) |
| Working rules for edits | [CLAUDE.md](../CLAUDE.md) |

Everything below is the older web-era map. Treat its statuses and its dated snapshot paragraph as history; the backend (`server/death-muffin/`) docs are still current because the server is shared.

Start here when working with several contributors. The documents serve different
purposes; a dated design brief is not evidence that a feature is in the game or
on the public site.

| Question | Read | Status |
| --- | --- | --- |
| How does the game work for a player? | [Game README](../README.md) and the in-game Codex/Settings | Guide to completed behavior in the current source build; check HANDOFF for in-progress changes |
| What is being changed now? | [HANDOFF](../HANDOFF.md) and `git status --short` | Working-tree status; update at the end of a work session |
| What was last published to Death Muffin? | [VPS handoff](DEATH-MUFFIN-HANDOFF.md) | Dated deployment record, not a substitute for a live check |
| What rules apply to edits and checks? | [CLAUDE](../CLAUDE.md) | Repository working instructions |
| What was built in earlier phases? | [Phase reports](../PHASE_REPORTS.md) | Chronological history; older counts and next steps are historical |
| How are the systems balanced? | [BALANCE](../BALANCE.md) and source constants | Targets, samples and open balance risks |
| What do the necromancer weapons change, and how do I regenerate them? | [Necro weapons](NECRO-WEAPONS.md) | Built; mechanics, migration 013 and model pipeline |
| What does a brand-new player see in the first hour, and when? | [First-hour audit](FIRST-HOUR-AUDIT.md) | Dated play-through: timeline, clutter, contradictions, what was changed (counsel cadence, HUD layout) |
| How readable are the zones and boss telegraphs, and what was polished? | [Zone polish audit](ZONE-POLISH-AUDIT.md) | Per-zone readability, clutter, lighting, prop clipping and perf; before/after of the cone, corpse and prop fixes |
| What stops a modified browser from minting level, gold and items? | [Server authority](SERVER-AUTHORITY.md) | Built on `dm/server-authority` (not deployed): report-first plausibility guards, ceilings, switch to enforce, what is still trusted |
| What is proposed? | [Future content](../FUTURE_CONTENT.md), [agent briefs](agent-briefs/README.md), [profession roadmap](PROFESSIONS-ROADMAP.md) | Designs; confirm implementation in source and HANDOFF |
| What are the performance targets, and how far are we? | [Performance budget](PERF-BUDGET.md) | Per-tier targets (Desktop High / Low, Phone) vs measured, how each is measured, Phase 1 finish line |
| How are assets and browser checks made? | [Asset pipeline](../ASSET_PIPELINE.md), [QA guide](../tools/qa/README.md) | Procedures and test entry points |
| How do I make or fix an animation without paying Tripo? | [Blender pipeline](BLENDER-PIPELINE.md), [animation sources](ANIMATION-SOURCES.md) | Built on `dm/blender`: scripts, bone map, measurements, limits, CC0 sources |
| How is the separate hosted service operated? | [VPS handoff](DEATH-MUFFIN-HANDOFF.md), [server operations](../SERVER_OPERATIONS.md) | Deployment and service boundaries |
| What is `server/web-deploy/`? | [Legacy Crossworlds deploy README](../server/web-deploy/README.md) | A separate `/play/` site, not the Death Muffin deployment path |

## Status language

- **In source** means the code exists in the current checkout. Staged and
  unstaged changes may belong to different contributors; inspect both before
  editing or publishing.
- **Verified locally** means a named check passed on that checkout. Record the
  date and any failing checks; old test totals are not a current guarantee.
- **Published** means a dated deployment record identifies the release and its
  verification. Local source changes do not update the running game.
- **Planned** means a brief or roadmap describes work that may not be built.

The latest recorded class deployment is 2026-09-28 in the VPS handoff. On
2026-09-29 this checkout also contains staged audio/High-graphics changes and
separate unstaged area-boss work. Check `git status --short` for the actual state
before continuing; this paragraph is a dated snapshot.

## Contributor handoff

1. Read `CLAUDE.md`, then `HANDOFF.md`, then `git status --short` and the
   staged/unstaged diffs. Coordinate before changing a file another contributor
   is editing; stage only your own hunks in shared files.
2. Use source constants and behavior as the authority for current mechanics.
   Update the player README, relevant Codex entry, counsel tip, Settings key/help
   text and tooltip together when behavior changes. Add a dated phase/deploy
   record only when those actions actually happen.
3. Run the relevant checks from `CLAUDE.md`. Record failures with their cause
   instead of copying a past “all green” claim. Keep generated builds, secrets,
   private test accounts and database exports out of Git.
4. Update the top of `HANDOFF.md` with what is in source, what is published,
   test results and the next owner/action. Stage your changes; do not commit
   unless the user asks, per the repository workflow.

Older briefs and checkpoint records stay in place for provenance. Their branch
names, queues and test counts are historical unless the current handoff says
otherwise.
