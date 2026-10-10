# Known gaps

Open gaps, verified against the code on `main`. Priorities are in [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.

## Performance

- **No rendered (GPU) frame budget exists.** Every number is headless on a shared VPS (frame median about 7 ms). Phase 6
  graphics presets (Low/Medium/High/Ultra, brightness lift, interface size, resolution governor) are applied by
  `next/perf/dm_next_perf.gd`; what is missing is real-hardware measurement.
- **Mobile renderer / FSR not evaluated.** The default is `gl_compatibility`; Mobile (Vulkan) is an opt-in Settings row with an automatic
  fallback (root README "Renderer"), never rendered on the VPS. Making it the default needs the owner's and Helix's PCs and re-measured shaders and budgets.

## Disciplines

- **Only the four necromancer disciplines exist.** `next/rites/dm_rite_registry.gd` is necromancer-only; a non-necro rite is
  refused `unavailable`. Character select greys out the other five (`DmCharacterBuild.is_playable`) and the backend caps
  `MAX_DISCIPLINE_INDEX` at 4. Missing with them: kit rites, monk beat meter, wraith nova on a charged cast, Bulwark
  (`DmPlayerRules` already honours `bulwarkUntil`).

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
