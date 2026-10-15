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

## Performance (the owner's first priority)

**Where it stands** (Helix's PC: Ryzen 5950X, RTX 4070 SUPER, 1440p Ultra, Compatibility renderer). About 170 fps in calm play and about 87 fps
in the benchmark's Bell Sanctum stress fight. In that fight render CPU is about 4 ms, more than half of it the HUD (about 600 of 900 draw calls), and
scripts plus physics about 10 ms, all on the main thread (Godot's default; only audio has its own thread). GPU time is low: the GPU is not the limit.
Script costs measured headless on 2026-10-15 (`tools/godot/profile.py` on `tests/perf/fight_breakdown.gd`, Standard 30 enemies / 20 thralls, about
9.9 ms CPU a frame): `DmCreature.update` 1.1-1.3 ms, enemy and thrall brains about 0.85 / 0.9 ms, enemy and thrall `_move` about 0.8 ms,
`DmFxRuntime` about 0.7 ms, the HUD view model 0.36 ms on average but rebuilt whole four times a second (a ~1.4 ms spike each time), native
physics about 0.3 ms, enemy queries (`enemies_in_radius`, `DmThrall._scan`) about 0.1 ms.

**Rules for every change.**
- Measure before and after, the same way: frame rate and render cost with the in-game benchmark on Helix's PC (Standard setup, character select ->
  Benchmark; runs land on the site's Benchmarks page, DECISIONS B21); script cost headless with `profile.py` and the knock-out table of
  `fight_breakdown.gd` at Standard and Heavy (60 / 30). `profile.py` sometimes reports an impossible row (one function above the whole frame):
  cross-check a single row with the knock-out table before acting on it.
- One change per release, so a result (or a crash) points at one thing. A change that does not move its number is reverted; nothing may make
  another number worse. Tests never assert wall-clock time (B11).
- Anything threaded or GPU-side ships behind a setting that turns it off without a new build: headless tests cannot see driver or threading
  trouble on real PCs (Phase B crashed players' GPUs, B12).
- Off the table: Godot's separate render thread (crashes this game at the first UI frame, B14). Combat LOD by lowering AI rate (thralls lost
  half their hits).

**Steps, in order of execution.** One step per release; the next starts when the previous one is measured and kept or reverted.

1. **HUD draw calls** (render). The minimap (one draw per dot and its clip mask), shadowed labels (each shadow is a second draw), the tip
   card's RichTextLabel. Measured by the HUD's share of the 900 draws in the benchmark's breakdown.
2. **Physics on its own thread** (`physics/3d/run_on_separate_thread`, one project setting).
3. **Creature visual update** (`DmCreature.update`, the largest script cost): skip work for bodies off screen or far from the camera, touch only
   what changed this frame.
4. **Jolt physics** instead of Godot Physics (built into 4.7, uses several cores), with capsule shapes for creatures.
5. **HUD view model:** rebuild only the parts that changed instead of the whole model four times a second.
6. **Navigation off the main thread** (async path queries and map updates).
7. **Movement and FX runtime** (`DmEnemy._move`, `DmThrall._move`, `DmFxRuntime`): per-frame allocation and repeated lookups.
8. **Spatial enemy queries:** one grid rebuilt per tick for `enemies_in_radius` (about 35 rites call it, each scanning every enemy and building
   a new list) and the thralls' target scan. Small on its own today; step 9 and 10 need it as the shared, thread-safe lookup.
9. **Enemies and thralls in their own process thread groups** (`process_thread_group`), so their per-frame logic runs in parallel. Needs
   thread-safe code: no scene edits from a thread, deferred calls back to the main thread.
10. **Batch work on `WorkerThreadPool`:** creature visual updates, steering and movement math, the spatial grid.
11. **Phase B on the GPU**, one part per owner-approved release from tag `archive/perf-phase-b` (B12), in this order: creature instance
    uniforms (bdcfad67), GPU motes (c62e407a, 91f23b20), prop MultiMesh (9cb53d8b, 37c94978, 8f475f65), the resolution governor and the
    Mobile renderer (b89317ad, then its threading part f6715cc2).
12. **Forward+ / FSR** behind a flag. The game runs `gl_compatibility` (`project.godot`); a switch needs the owner's and Helix's PCs, a
    Compatibility fallback and re-measured shaders and budgets.

## Then: necromancer polish (no new content)

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
