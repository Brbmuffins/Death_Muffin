# Documentation map

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
| What is proposed? | [Future content](../FUTURE_CONTENT.md), [agent briefs](agent-briefs/README.md), [profession roadmap](PROFESSIONS-ROADMAP.md) | Designs; confirm implementation in source and HANDOFF |
| How are assets and browser checks made? | [Asset pipeline](../ASSET_PIPELINE.md), [QA guide](../tools/qa/README.md) | Procedures and test entry points |
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
