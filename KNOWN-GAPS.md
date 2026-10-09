# Known gaps

Open gaps, verified against the code on `main`. Priorities are in [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.

## Performance

- **No rendered (GPU) frame budget exists.** Every number is headless on a shared VPS (frame median about 7 ms). Phase 6
  graphics presets (Low/Medium/High/Ultra, brightness lift, interface size, resolution governor) are applied by
  `next/perf/dm_next_perf.gd`; what is missing is real-hardware measurement.
- **Forward+ / FSR not evaluated.** The renderer is `gl_compatibility` (`project.godot`). A switch needs the owner's and Helix's
  PCs, a Compatibility fallback and re-measured shaders and budgets.

## Disciplines

- **Only the four necromancer disciplines exist.** `next/rites/dm_rite_registry.gd` is necromancer-only; a non-necro rite is
  refused `unavailable`. Character select greys out the other five (`DmCharacterBuild.is_playable`) and the backend caps
  `MAX_DISCIPLINE_INDEX` at 4. Missing with them: kit rites, monk beat meter, wraith nova on a charged cast, Bulwark
  (`DmPlayerRules` already honours `bulwarkUntil`).

## Combat and statuses

- **Shrouded suspension in the player's own Miasma** is not implemented (`next/status/README.md`). Barrier has no decay beyond
  its 6 s duration.
- A late joiner does not see boss pools that are already burning; the flood's hummock shrink is not eased by the world
  builder; pools of a boss that resets linger their remaining seconds (`next/bosses/README.md`).

## Party and online

- **No rejoin window** (D13). A dropped client returns to its own solo game, a dropped host ends the session (D6). The only
  "cannot rejoin" logic is the dev-offline session stub.
- **One area per session.** One wave director follows one area; party members in different areas do not get simultaneous waves
  (`next/areas/README.md`).
- **Depths are solo.** `can_enter` refuses with 2+ players (`next/depths/README.md`).
- **A joiner's own state does not reach the host's sim:** rune sockets, gear and upgrades; Colossus Mantle hooks are host-hero
  only; no flasks or brews; no Covenant Seal or Nightfall dim; a client cannot call Empowered bosses.
- Client (non-host) peers get no full HUD feed beyond what `next/party/` provides; hurt numbers for a client's own damage need
  a vitals diff (`next/hud/README.md`).
- Chat is party chat in a party and local-only when solo.

## UI

- **No in-game leaderboard panel.** `DmApi.get_leaderboard` exists; only the website shows it.
- A few counsel events are still unraised (`next/hud/README.md`); `loadout_check`, `necro_weapon_changed`,
  `set_bonus_gained` and `omen_told` are defined but nothing raises them.
- Hero: no friendly rim light; the hover ring follows hover only; online joiners' bag and cosmetics do not live-update
  (`next/hero/README.md`).

## Leftovers from the web era

- Bit-exact web math is still used by the Depths floor generator, auto-combat and the DB loader (`sim/fdlibm.gd`, `sim/sim_exact.gd`, `game/dm_fdlibm_x.gd`). New code does not need it; removing it changes golden fixtures.
- `tools/godot/sync-slice-assets.mjs` reads `godot/data/slice/assets_used.json`; the exporter that wrote it (`export-slice.ts`) is gone, so the list is now hand-maintained.
- `godot/export_presets.cfg` still names the product "Death Muffin (Godot slice)" and the export files `DeathMuffin-godot-slice`.
