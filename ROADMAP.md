# Roadmap

Updated 2026-10-09. The game is the Godot online client, necromancer-only. Order of work follows the owner's rules:
performance first, polish over new content, necromancer focus. Real gaps are in [KNOWN-GAPS.md](KNOWN-GAPS.md);
decisions are in [DECISIONS.md](DECISIONS.md).

## Now: baseline (phase 5 of the 2026-10-09 plan)

1. Full Godot suite green on the clean tree (`tools/godot/run-all-tests.sh`), plus `test:rules`, `test:server`, lobby and
   launcher tests. CI suite list updated to match the suites that remain.
2. Publish the client from `main` (`publish-godot-client.sh`), release the launcher, deploy the backend if it changed.
3. Tag `baseline-2026-10-xx`. Delete the stale `godot-next`, `master` and `godot-port` branches (keep `main`, `legacy-web`).
4. Announce in #deathmuffin; restart the Discord dev agent and the daily bug agent against the new docs.
5. Close the leftovers: dead `DmReleaseWatch` / `get_release`, the stale lines listed under "Cleanup" in KNOWN-GAPS.md, `docs/` size (108 MB).

## Next: necromancer polish (no new content)

- **Rendered performance.** All frame numbers so far are headless on a shared VPS. Measure a real-GPU frame budget on the
  owner's and Helix's PCs (Hollow Graves with 20+ enemies and a boss, 1080p and 1440p, Low and High), including first-frame
  and shader hitches. Forward+/FSR is only evaluated after that, on a separate branch behind a flag.
- **Combat feel and loot** for the four disciplines: tuning from playtests, readability of rites and statuses, gear and
  affix legibility, the first hour (Next-step box, counsel tips, guide NPCs).
- **Rejoin window** (D13): a dropped party member can return for a short window. Needs host and relay work and a test.
- **Party gaps**: a joiner's own rune sockets, gear and upgrades reaching the host's sim; flasks and brews for a joiner;
  Depths for parties; a client's Covenant Seal and Nightfall dim.
- Remove the remaining stale text in system READMEs under `godot/next/` as each is touched.

## Later

- **The other five disciplines** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker), rebuilt on the
  Godot kit and rite system. Their data exists in `godot/data/content/` but `next/rites/dm_rite_registry.gd` is necromancer-only.
  Shrouded suspension, monk beat meter and Bulwark come with them.
- **New content after polish:** new zones (the Hollow Court), more bosses with summoning keys, new enemy archetypes,
  replay and endgame depth (weekly Omen variants, deeper Depths rewards). Ideas are in git history (`FUTURE_CONTENT.md`).
- **In-game leaderboard panel** (the website shows it; `DmApi.get_leaderboard` exists).
- **Server authority:** the kill ledger (`backend/kills.cjs`) has `AUTHORITY_KILLS=off|audit|enforce`; the code default is `off`; live runs `audit` (checked 2026-10-09). Next step: review the audit log, then enforce.
- **VPS-hosted sessions** (headless Godot) and host migration. Not planned.
- **Mobile:** not in scope for the Godot game.
