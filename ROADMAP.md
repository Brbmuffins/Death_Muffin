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

**Phase 2: intents instead of saved totals.** Done 2026-10-14 (DECISIONS B23, B24, B25): saves carry XP and gold gains, not totals;
gathering, labor, contracts and selling pay their gold on the server; boss kills are backed by paid summons; a value ledger records every
gold, XP and shard change with its reason; only the server writes a bag (every bag change is a server operation, the whole-bag save is
GM-mode only).

**Phase 3: co-op on the same rules.** Done 2026-10-14 (DECISIONS B22, B26): the host builds each guest's hero from the server's record
(level, gear, set bonuses, affixes, boons, vows, upgrade tiers, rune sockets); each player's rewards run at the session's heat (the host's
world vows) plus their own self vows, and the backend caps them the same way from the host's record; "Heat N · Difficulty" shows in the
friends list, invites, the Party window and over the HUD's party list ("+N yours" for one's own self vows).

**Phase 4: enforce and watch.** Enforce is on since 2026-10-15 (DECISIONS B32): a save pays only the XP and gold the kill ledger and the
per-minute ceilings back, stats never change by save, and saves without gains are refused. Still to do: watch `progress_audit` for rule false
positives (they now hold back an honest player's gain), make area kills, shards and seals in the necromancer save come only from accepted
reports, clear the old audit rows, a Discord notice when a character trips a flag, and a rollback runbook on `character_save_versions`.
GM actions are logged.

The model is the hybrid one (Warframe-style; owner 2026-10-15): a player's PC hosts the combat, the server owns everything of value.
Not planned now: full server-side combat simulation (headless sessions); revisit if the game goes public at scale.

## Then: necromancer polish (no new content)

- **Performance** (owner: first priority; plan of 2026-10-15, costs measured in KNOWN-GAPS: Performance). Every step is measured before and
  after: render cost with the in-game benchmark on Helix's PC (Standard setup; runs land on the site's Benchmarks page, DECISIONS B21), script
  cost headless with `tools/godot/profile.py` on `tests/perf/fight_breakdown.gd` (Standard 30 enemies / 20 thralls and Heavy 60 / 30). A step
  that does not move its number is reverted. In order:
  1. **HUD draw calls** (render CPU; the HUD is about 600 of 900 draws): minimap dots and mask, shadowed labels, the tip card.
  2. **Creature visual update** (`DmCreature.update`, the largest script cost): skip work for bodies off screen or far from the camera, and
     only touch what changed this frame.
  3. **HUD view model:** rebuild only what changed instead of the whole model four times a second (a ~1.4 ms spike each time).
  4. **Movement and FX runtime** (`DmEnemy._move`, `DmThrall._move`, `DmFxRuntime`): per-frame allocation and repeated lookups.
  5. **Spatial enemy queries** (`DmWaveDirector.enemies_in_radius`, `DmThrall._scan`): a grid rebuilt once per tick. Measured small today
     (about 1% of a Standard fight); do it when Heavy fights or new rites make it grow, or as part of step 6.
  6. **Combat work over several cores** (creature update, movement and queries in `WorkerThreadPool` batches), once steps 2-5 have made
     that work lean.
  7. Then Forward+ / FSR behind a flag. Phase B stays pulled (DECISIONS B12): its parts come back one per owner-approved build from tag
     `archive/perf-phase-b`.
  Tooling: `profile.py` sometimes reports an impossible row (one function above the whole frame); cross-check with `fight_breakdown.gd`'s
  knock-out table before acting on a single row.
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
