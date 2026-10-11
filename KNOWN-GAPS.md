# Known gaps

Open gaps, verified against the code on `main`. Priorities are in [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.

## Performance

- **No rendered (GPU) frame budget exists.** Every number is headless on a shared VPS (frame median about 7 ms). Phase 6
  graphics presets (Low/Medium/High/Ultra, brightness lift, interface size, resolution governor) are applied by
  `next/perf/dm_next_perf.gd`; what is missing is real-hardware measurement.
- **Forward+ / FSR not evaluated.** The renderer is `gl_compatibility` (`project.godot`). A switch needs the owner's and Helix's
  PCs, a Compatibility fallback and re-measured shaders and budgets.

## Disciplines

- **Only the four necromancer disciplines and the Reaper exist.** `next/rites/dm_rite_registry.gd` holds the necromancer rites and the
  Reaper's six; any other non-necro rite is refused `unavailable`. Character select greys out the other five
  (`DmCharacterBuild.is_playable`) and the backend only accepts classes 1-4 and 11 (`PLAYABLE_DISCIPLINE_INDICES`). Missing with them:
  kit rites, monk beat meter, wraith nova on a charged cast, Bulwark (`DmPlayerRules` already honours `bulwarkUntil`).
- **The Reaper is a first pass.** It borrows the Mourner's hero model, portrait and rite icons (art to be generated), has no armor set of its
  own, no runes, no signature (R) rite, and Auto combat does not play it. Its soul wisps are drawn on the host only; a party member's soul
  count reaches their HUD by the caster state. Numbers (REAPER in `data/combat/abilities.json`) are untuned.

## Combat and statuses

Shrouded suspension in the player's own Miasma, the Barrier decay, and boss-pool gaps for late joiners: see `godot/next/status/README.md` and `godot/next/bosses/README.md`.

## Party and online

- **No rejoin window** (D13). A dropped client returns to its own solo game, a dropped host ends the session (D6).
- **One area per session, Depths solo:** `godot/next/areas/README.md`, `godot/next/depths/README.md`.
- **A joiner's own state does not reach the host's sim:** rune sockets, gear and upgrades; Colossus Mantle hooks are host-hero
  only; no flasks or brews; no Covenant Seal or Nightfall dim; a client cannot call Empowered bosses.
- Client (non-host) peers get no full HUD feed beyond what `next/party/` provides (`next/hud/README.md`).
- Chat is party chat in a party and local-only when solo.

## UI

- **No in-game leaderboard panel.** `DmApi.get_leaderboard` exists; only the website shows it.
- Unraised counsel events: `godot/ui/onboarding/README.md`. Hero gaps: `godot/next/hero/README.md`.

## Leftovers from the web era

- Bit-exact web math (fdlibm, exact-double loading) is still used by the Depths floor generator, auto-combat and the DB loader: `godot/sim/README.md`.
- `tools/godot/sync-slice-assets.mjs` reads `godot/data/slice/assets_used.json`; the exporter that wrote it (`export-slice.ts`) is gone, so the list is now hand-maintained.
- `godot/export_presets.cfg` still names the product "Death Muffin (Godot slice)" and the export files `DeathMuffin-godot-slice`.
