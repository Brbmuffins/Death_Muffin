# Roadmap

The game is the Godot online client, necromancers plus the Reaper (a scythe class with a soul bag, first pass: own portrait, placeholder model, first-tuned numbers). Order of work follows the owner's rules: performance first, polish
over new content, necromancer focus. Open gaps are listed once, in [KNOWN-GAPS.md](KNOWN-GAPS.md); decisions in
[DECISIONS.md](DECISIONS.md).

## Now: server authority and co-op (the next update, owner plan 2026-10-13)

Owner rule: **all player data is server-side; minimise ways to cheat.** Target model (the usual one for peer-hosted co-op
ARPGs): a player's PC may host and simulate combat, but everything with lasting value (levels, XP, gold, items, drops,
progression) is decided by the server, from player *intents* ("I killed X", "pick up drop 12", "sell slot 4"), never from
totals the client sends, and paid no faster than honest play could earn it. The authority audit of 2026-10-13 is kept
privately on the VPS (`~/vps-handoffs/DeathMuffin/audit/2026-10-13-authority/`), not in this public repo. Phases ship one by one.

**Phase 0: close the open doors.** Live 2026-10-13 (DECISIONS B19). Still open: pck encryption (needs export templates built with
an encryption key).

**Phase 1: the server decides drops.** Done, enforced since 2026-10-14 (DECISIONS B20): every drop (kills, elites, bosses, surges, the
Depths' floors and chests) rolls instantly from a server-dealt drop tape and its pickup is a server claim that grants the server's own
roll; a bag save cannot add a drop item; `/api/loot/roll-gear` is GM-mode only.

**Phase 2: intents instead of saved totals.** Live 2026-10-14 (DECISIONS B23, B24): saves carry XP and gold gains, not totals; gathering,
labor, contracts and selling pay their gold on the server; boss kills are backed by paid summons; a value ledger records every gold, XP
and shard change with its reason. Still to do: the bag changes through operations (move, split, drop, use) like the Vault, so a bag
save no longer carries non-drop items; area kills, shards and seals come only from accepted reports (the kill ledger's enforce).

**Phase 3: co-op on the same rules.**
1. **Guests fight at their real power.** Live 2026-10-14 (DECISIONS B22): the host builds each guest's hero from the server's record
   (level, gear, set bonuses, affixes, boons, vows including self vows, upgrade tiers) and reads it again when the guest's worn
   gear changes; a guest's party kills are judged in the host's world. Still to do: rune sockets reaching a guest's rites.
2. **Heat that adds up.** The session's heat is the host's world vows (it sets the world). Each player's reward heat is the
   session heat plus their own self vows, solo too (today the xp / gold multiplier counts world vows only); the backend's
   reward caps use the same total, with the host's level and heat taken from the server's record, not the report.
3. **Show the host's world, always.** "Heat N · Difficulty" (also "Heat 0 · Medium") in the friends list, the party invite,
   the Party window (session list and header) and the guest's HUD, which also shows its own self-vow part ("+3 yours").
   The lobby carries heat and difficulty on the session; it deploys first (manual restart with no sessions).
   Items 1-3 do not depend on Phases 1-2 and can be built alongside them.

**Phase 4: enforce and watch.** Fix the rule false positives (KNOWN-GAPS: Server authority), clear the old audit rows, then
after a few days of real solo and co-op play with no new findings set `AUTHORITY_KILLS` and `AUTHORITY_MODE` to enforce.
GM actions are logged; a Discord notice when a character trips a flag; a rollback runbook on `character_save_versions`.

Not planned now: full server-side combat simulation (headless sessions); revisit if the game goes public at scale.

## Then: necromancer polish (no new content)

- **Performance:** the in-game benchmark (character select -> Benchmark; every run lands on the site's Benchmarks page, DECISIONS B21) is the measuring stick. Next: HUD draw calls, then combat
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
