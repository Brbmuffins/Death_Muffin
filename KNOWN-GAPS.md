# Known gaps

Open gaps, verified against the code on `main`. Priorities are in [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.

## Performance

- **The main thread is the limit in big fights.** Measured on Helix's PC (Ryzen 5950X, RTX 4070 SUPER, 1440p Ultra) with the in-game
  benchmark (`next/perf/README.md`): about 87 fps in the Bell Sanctum stress fight, render CPU about 4 ms of which the HUD is more than half
  (about 600 of 900 draw calls), scripts and physics about 10 ms; everything runs on one thread (Godot's default). The breakdown's ms
  columns jitter on that PC (GPU / driver state), only its draw-call counts are steady. Next: HUD draw calls (minimap dots and mask, shadowed
  labels, the tip card), then splitting combat work over cores.
- **Forward+ / FSR not evaluated.** The renderer is `gl_compatibility` (`project.godot`). A switch needs the owner's and Helix's
  PCs, a Compatibility fallback and re-measured shaders and budgets.

## Server authority

Live runs `AUTHORITY_KILLS=audit` (findings in `progress_audit`, nothing clamped). The 2026-10-13 review found no cheating, but
these rules would cut honest players under enforce:
- **Depths floors:** one new player's floors 3-4 were rejected (`floor_invalid` "skipped floors", 1 proven); not yet known
  whether the rule or the run is wrong.
- **Client-claimed saves:** progress totals (level, XP, gold, area kills, shards) and the bag's non-drop items are still the client's
  claim, bounded only by the report-mode guards (ROADMAP: Phase 2). Drops are the server's (DECISIONS B20).

## Disciplines

- **Only the four necromancer disciplines and the Reaper exist.** `next/rites/dm_rite_registry.gd` holds the necromancer rites and the
  Reaper's six; any other non-necro rite is refused `unavailable`. Character select greys out the other five
  (`DmCharacterBuild.is_playable`) and the backend only accepts classes 1-4 and 11 (`PLAYABLE_DISCIPLINE_INDICES`). Missing with them:
  kit rites, monk beat meter, wraith nova on a charged cast, Bulwark (`DmPlayerRules` already honours `bulwarkUntil`).
- **The Reaper is a first pass.** It has its own portrait but borrows the Mourner's hero model and existing rite icons, has no armor set of its
  own, no runes and no signature (R) rite. Its soul wisps are drawn on the host only; a party member's soul
  count reaches their HUD by the caster state. Numbers (REAPER in `data/combat/abilities.json`) are a first tuning (2026-10-11 headless probe with Auto combat, level 20, no thralls: Scythe Sweep 52 damage a second on one foe and 276 on a pack of six, against the Mourner's 88 and 379; she makes up for it with 30% more health, 15% less damage taken and her leech), not yet playtested by a person.

## Combat and statuses

Shrouded suspension in the player's own Miasma, the Barrier decay, and boss-pool gaps for late joiners: see `godot/next/status/README.md` and `godot/next/bosses/README.md`.

## Party and online

- **No rejoin window** (D13). A dropped client returns to its own solo game, a dropped host ends the session (D6).
- **One area per session, Depths solo:** `godot/next/areas/README.md`, `godot/next/depths/README.md`.
- **Part of a joiner's state does not reach the host's sim:** the host builds the joiner's hero from the server's record (level, gear,
  set bonuses, affixes, boons, vows, upgrade tiers), but its rune sockets do not reach its rites; Colossus Mantle hooks are host-hero
  only; no flasks or brews; no Covenant Seal or Nightfall dim; a client cannot call Empowered bosses.
- Client (non-host) peers get no full HUD feed beyond what `next/party/` provides (`next/hud/README.md`).
- Chat is party chat in a party and local-only when solo.
- **Friends show online only in the world:** character select and the launcher count as offline (the lobby link starts after loading).

## UI

- **No in-game leaderboard panel.** `DmApi.get_leaderboard` exists; only the website shows it.
- Unraised counsel events: `godot/ui/onboarding/README.md`. Hero gaps: `godot/next/hero/README.md`.

## Leftovers from the web era

- Bit-exact web math (fdlibm, exact-double loading) is still used by the Depths floor generator, auto-combat and the DB loader: `godot/sim/README.md`.
- `tools/godot/sync-slice-assets.mjs` reads `godot/data/slice/assets_used.json`; the exporter that wrote it (`export-slice.ts`) is gone, so the list is now hand-maintained.
- `config/name` in `godot/project.godot` is still "Death Muffin (Godot slice)": Godot names the user:// folder after it (saved login, settings), so it stays until a migration copies that folder. Players see "Death Muffin" (`main.gd` sets the window title; the exe product name is "Death Muffin").
