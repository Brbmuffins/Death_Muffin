# Roadmap

The game is the Godot online client, necromancers plus the Reaper (a scythe class with a soul bag, first pass: own portrait, placeholder model, first-tuned numbers). Order of work follows the owner's rules: performance first, polish
over new content, necromancer focus. Open gaps are listed once, in [KNOWN-GAPS.md](KNOWN-GAPS.md); decisions in
[DECISIONS.md](DECISIONS.md).

## Now: necromancer polish (no new content)

- **Performance:** the in-game benchmark (character select -> Benchmark) is the measuring stick. Next: HUD draw calls, then combat
  work over several cores (KNOWN-GAPS: Performance).
  Forward+/FSR only after that, behind a flag. Phase B is pulled (DECISIONS B12): bring it back one part per owner-approved test build
  from tag `archive/perf-phase-b`.
- **Combat feel and loot** for the four disciplines: tuning from playtests, readability of rites and statuses, gear and
  affix legibility, the first hour (Next-step box, counsel tips, guide NPCs).
- **Rejoin window** (D13) and the **party gaps** (KNOWN-GAPS: Party and online).
- Fix stale text in the `godot/next/*/README.md` files as each system is touched.

## Later

- **The other five disciplines** (Grave Warden, Bell Monk, Carrion Witch, Hollow Knight, Veilwalker) on the Godot kit and rite
  system; their data is in `godot/data/content/`. Shrouded suspension, monk beat meter and Bulwark come with them.
- **New content after polish:** new zones (the Hollow Court), more bosses with summoning keys, new enemy archetypes, replay and
  endgame depth (weekly Omen variants, deeper Depths rewards).
- **In-game leaderboard panel** (KNOWN-GAPS: UI).
- **Server authority:** the kill ledger (`backend/kills.cjs`) runs `AUTHORITY_KILLS=audit` live (code default `off`). Next: review the audit log, then enforce.
- Not planned: VPS-hosted sessions (headless Godot) and host migration; mobile.
