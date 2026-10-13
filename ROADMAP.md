# Roadmap

The game is the Godot online client, necromancers plus the Reaper (a scythe class with a soul bag, first pass: own portrait, placeholder model, first-tuned numbers). Order of work follows the owner's rules: performance first, polish
over new content, necromancer focus. Open gaps are listed once, in [KNOWN-GAPS.md](KNOWN-GAPS.md); decisions in
[DECISIONS.md](DECISIONS.md).

## Now: co-op and server authority (the next update, owner plan 2026-10-13)

Owner rule: **all player data is server-side.** A host never trusts a guest's client for level, gear, vows or progress, and
a client's own saves are paid only what the server can back. Steps 1-3 can be built side by side; enforcement ships last.

1. **Guests fight at their real power.** The guest only joins the backend party session with its own login; the host fetches
   each member's build from a new host-only backend endpoint (level, class, stats, equipped gear and affixes, boons, vows,
   upgrade tiers, runes) and refetches on a level-up or gear change. The guest level cap (`MAX_LEVEL` in
   `godot/next/party/dm_next_party.gd`) is removed. Guests' **self vows** (Frail Vessel, Famished, Brittle Thralls, Dry
   Cellar) apply to their own hero.
2. **Heat that adds up.** The session's heat is the host's world vows (it sets the world). Each player's reward heat is the
   session heat plus their own self vows, solo too (today the xp / gold multiplier counts world vows only); the backend's
   reward caps use the same total, including for party reports.
3. **Show the host's world, always.** "Heat N · Difficulty" (also "Heat 0 · Medium") in the friends list, the party invite,
   the Party window (session list and header) and the guest's HUD, which also shows its own self-vow part ("+3 yours").
   The lobby carries heat and difficulty on the session; it deploys first (manual restart with no sessions).
4. **Fix the authority rules** found by the audit-log review (KNOWN-GAPS: Server authority), check the Depths floor rule, and
   audit the bag save path for item minting.
5. **Enforce** (`AUTHORITY_KILLS` and `AUTHORITY_MODE`) after the old audit rows are cleared and a few days of real solo and
   co-op play log no new findings.

## Then: necromancer polish (no new content)

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
- Not planned: VPS-hosted sessions (headless Godot) and host migration; mobile.
