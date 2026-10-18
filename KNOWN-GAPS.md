# Known gaps

Open gaps, verified against the code on `main`. The order they are worked in is [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.
Since launch day (2026-10-18) the game is `client/`; a path below without a folder is the same in `client/` and in the old `godot/` (kept until
2026-11-01).

## Missing since launch day

- **Grave Surges are not in the rebuilt game.** `client/next/spawn/dm_wave_director.gd` never starts one: `godot/next/areas/dm_grave_surge.gd`
  was left out of the rebuild (it drives the old game's enemies), so there is no surge, surge reward or surge tip (ROADMAP Phase 1).
- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on purpose (B36; ROADMAP Phase 3).

## Performance

The numbers are the VPS's headless Full Party fight (2026-10-17) unless they say otherwise.
- **Weaker PCs are not measured:** no GTX 970-class PC or laptop has run the rebuilt game's benchmark, so B39's floors are unproven.
- **Spikes:** a rite's cast takes 2 to 4 ms in the tick it is cast (1.2 to 1.9 ms of it its effects: `DmRiteCaster._play_event`, the `Vfx`
  nodes); a big kill's event handlers 2 to 9 ms (`DmCoreHost._dispatch`: rewards, loot, the counsel); Bone Fan's pick in Easy auto combat
  (`DmAutoCombat._primary_target`) tests every pair of targets, up to 4,000 calls, about 6 ms (the Gravecaller's default loadout does not use it).
- **Per-frame waste:** `DmCore.enemy_info` builds a 25-entry Dictionary (8 us) and is called 14 times a frame (the HUD's target frame, the
  event handlers, the rites' single reads); Easy auto combat's gather (`DmNextAutoCombat._gather`, ten times a second, 0.4 to 0.75 ms) copies
  every body in range into a row that `select_action` copies again; `DmFxBinbun.update` walks every live effect every frame (the Pyre's 56:
  about 0.2 ms); the Gear Atlas verdicts (`DmUiPanelsA.tick`, about 0.3 s of a worker) are worked out again after every quiet 0.8 s of the bag,
  so loot keeps a core busy through a fight even with the Atlas closed.
- **Draw calls:** `Vfx` (`DmFxRuntime`) leaves some pooled MultiMeshes visible with no instance (4 of its 20 in a Full Party fight), a draw
  call each; the area scenes' props always cast the moon's shadow (the old game stopped beyond 32 m of the hero); decals are unique quads, one
  draw call each (the Graves: 23); a crowd body outside the view that casts a shadow is drawn in the main pass too (a shadows-only MultiMesh
  would send it to the shadow map alone; worth it only if Helix's PC shows a cost).

## Content pipelines

- **Nothing checks a new model.** The Discord agent asks Tripo for 300 to 14,000 triangles (`face_limit`) whatever the model is; the results so
  far fit ASSET_PIPELINE.md's budgets (24 gear props at 3,488 triangles or fewer with one material each; nine hero bodies at 8,780 to 12,056
  triangles, one material and the shared 41-bone biped skeleton; measured 2026-10-18) because the agent follows its prompt, not because of a
  check. A hero body also needs the combat clips (`tools/build-characters.mjs`: `NECRO_HEROES` and `hero_leg_*`); `hero_reaper` once shipped
  without them.
- **New sounds are not loudness-matched or recorded.** `server/death-muffin/discord-agent/build-sound.sh` converts a take to mono 16-bit
  44.1 kHz WAV with no loudness normalization; the Discord agent's sounds (chat_ding, chat_ping, chat_toll) are missing from
  `docs/AUDIO-SOURCES.md`, the licence record (their specs are in audio-manifest/eleven/).
- **An armor set touches about five files** (`server/rules/content/legendarySets.ts` or armorSets.ts, setBonuses.json, necro_gear.json,
  view_models.json, assets_used.json; `tools/generate-armor-assets.mjs` writes the rest) and moves the tests that pin counts and loot digests,
  which the agent updates by hand.
- The gear props' attachment rules (axes, size, grip point, anchor bone) live in the `_doc` of `godot/data/slice/necro_gear.json`, not on a
  standards page.

## Operations

- **The game's services are not watched.** Uptime Kuma watches only the database's port (monitor 7, MySQL); `death-muffin-auth` (:5190),
  `deathmuffin-lobby` (:5192) and `deathmuffin-relay` (udp 5193) have no monitor, so a stopped service raises no alert (the nightly drift
  report lists services once a day). ROADMAP Phase 1.
- **Backups stay on this server.** `server/death-muffin/ops/backup-db.sh` writes the nightly dumps to `~/death-muffin/backups/db/` on the
  same VPS; the raw art sources (`art-src/`, gitignored), the private effect sheets and keys (`~/death-muffin/private/`), the licensed packs
  and the services' `.env` files exist only here. ROADMAP Later: a cloud storage bucket (B51).

## Server authority

Live runs `AUTHORITY_KILLS=enforce` and `AUTHORITY_MODE=enforce` since 2026-10-15 (DECISIONS B32): XP and gold beyond what the kill ledger
and ceilings back are held back with a message to the player (findings in `progress_audit`). A rule false positive therefore costs an honest
player part of a gain until it is fixed; few real sessions ran on the gains saves before the switch.
- **Client-claimed saves:** area kills and shards in the necromancer save are still the client's claim (ROADMAP Phase 2).

## Disciplines

- **Only the four necromancer disciplines and the Reaper exist.** `next/rites/dm_rite_registry.gd` holds the necromancer rites and the
  Reaper's six; any other non-necro rite is refused `unavailable`. Character select greys out the other five
  (`DmCharacterBuild.is_playable`) and the backend only accepts classes 1-4 and 11 (`PLAYABLE_DISCIPLINE_INDICES`). Missing with them:
  kit rites, monk beat meter, wraith nova on a charged cast, Bulwark (`DmPlayerRules` already honours `bulwarkUntil`).
- **The Reaper is a first pass.** It has its own portrait but borrows the Mourner's hero model and existing rite icons, has no armor set of its
  own, no runes and no signature (R) rite. Its soul wisps are drawn on the host only; a party member's soul
  count reaches their HUD by the caster state. Numbers (REAPER in `data/combat/abilities.json`) are a first tuning (2026-10-11 headless probe with Auto combat, level 20, no thralls: Scythe Sweep 52 damage a second on one foe and 276 on a pack of six, against the Mourner's 88 and 379; she makes up for it with 30% more health, 15% less damage taken and her leech), not yet playtested by a person.

## Combat and statuses

- **Found by the rebuild, approved to fix** (Helix, 2026-10-16; the core already emits each one; ROADMAP polish list): toxic corpse pools
  always hit as at level 1 (nothing sets the area level); a fallen plague bearer's pool never appears and the Mourning Bell wraith's ally heal
  never happens (signals nobody listens to); statuses never change the blows a boss takes (`DmBoss.take_damage` skips the status set's
  damage-taken multiplier, and the brain's own Fracture is never fed: a Marrow Spear's Fracture or a Sanctify on the King does nothing).
- **Easy auto combat parks the hero in pockets of tombstones:** it steers straight at the nearest enemy, with no path round the graves (found
  by the seeded comparison, native/README.md "Proof of same game").
- Shrouded suspension in the player's own Miasma, the Barrier decay, and boss-pool gaps for late joiners: see `godot/next/status/README.md` and `godot/next/bosses/README.md`.

## Built but never shown

Looks and effects that exist in the code but no game scene wires up; the rebuilt game draws what the old one did until each is decided
(ROADMAP polish list).
- A thrall never wears its Legion kit (the kit's armour tint on its chest and hands, the kit weapon's tier colour): the old `DmEntityViews`
  asked its host for `legion_kit_for`, which no host had.
- A thrall never wears its discipline's legion look either (the Ossuary's sentinel, the Gravecaller's legionnaire, the Rotweaver's plague
  thrall, their tints and glows): no host gave `discipline_id_for`; the crowd keeps `CrowdView.set_owner_legion` and crowd_looks.json
  `legions` for it.
- The water's ripples (under the hero, the Mire Mother's rings, the Wisp's pulse) and the Prelate's candle groups: `DmEventFx.add_ripple` and
  `set_candle_group` call a `game.dressing` that no game scene sets (client/README.md "World dressing").
- The Plague Doctor's flask leaves a 5 s toxic pool that hurts but is not drawn (`DmEnemyFx` draws only dust and ember zones).

## Look

What still differs from the old game's look is in client/README.md "The look against today's game" ("Still not today's": effects on Low and
Medium, the lifts, the Depths' walls, the hero's robe area by area, emission not converted, the Fen's bake); it is the look pass (ROADMAP
polish list). Also:
- Nightfall dims only the real-time ambient: lightmapped ground, walls and props keep their full ambient (a per-area dimming of the lightmaps
  would be a decision).
- The crowd's shader changes are checked in text, not in a rendered frame: run `client/tests/crowd_look_smoke.gd` (Forward+, about two
  minutes) in the look pass; the aim ring showed about 3 m above the hero in the look probe's frames (no mouse there).

## Party and online

- **No automatic rejoin** (D13). A dropped client returns to its own solo game and has to join again by hand (an Open party: Join; a Closed one: a new invite or Ask to join); a dropped host ends the session (D6).
- **One area per session, Depths solo:** `godot/next/areas/README.md`, `godot/next/depths/README.md`.
- **Part of a joiner's state does not reach the host's sim:** the host builds the joiner's hero from the server's record (level, gear,
  set bonuses, affixes, boons, vows, upgrade tiers, rune sockets), but Colossus Mantle hooks are host-hero only; no Covenant Seal or Nightfall dim; a client cannot call Empowered bosses.
- Client (non-host) peers get no full HUD feed beyond what `next/party/` provides (`next/hud/README.md`).
- Chat is party chat in a party and local-only when solo.
- **Friends show online only in the world:** character select and the launcher count as offline (the lobby link starts after loading).
- A guest's waystone map lists its own account's open areas, not the host's world's (a jump to a sealed one is refused with the reason).
- A guest sees no number over an enemy for a blow of its thralls, except the killing one: a guest's core gets no source with a blow, so the
  host would have to send each one.
- A guest whose own account has a boss's area sealed wakes the host's boss for nothing: its shards are refused and given back, and the toast
  comes after the boss is awake (whether a guest may wake what only the host has opened is a co-op rule to decide).
- A guest's Prelate kill counts for the host (the Prelate tally and `can_ascend`), and a guest never gets a boss's first-kill bonus or trophy.
- Suspected, read from the code, not seen: after a baseline a guest's thralls may fall back to the plain look and the strong rim until the
  heroes are adopted again (`DmCrowd.clear` forgets `owner_legion` and `owner_ally`).
- A guest's core lists no zones (`DmCore.zones`): its zones arrive as events for its effects. Nothing reads them on a guest today.

## Gathering

- Cycles gathered in the last 8 s before the player leaves or closes the window are never sent (`flush_all` does not flush the gather loop).

## UI

- **No in-game leaderboard panel.** `DmApi.get_leaderboard` exists; only the website shows it.
- Unraised counsel events: `godot/ui/onboarding/README.md`. Hero gaps: `godot/next/hero/README.md`.

## Tools and tests

- **The Discord agent's checks and screenshots use the old game:** its checks run `tools/godot/run-all-tests.sh` and its screenshots
  `server/death-muffin/discord-agent/shot-godot.sh` (the QA driver is not in `client/`); the live game's suites run in GitHub CI after a ship
  is pushed and published (ROADMAP Phase 1).
- `client/tests/game_scene.gd`'s node checks pass about every other run under load: the counsel's tip card (16 nodes, shown at the first
  Barrow Ghoul and dismissed on a wall-clock timer) is in the scene tree for part of the run.
- The client's suites other than `world.gd` do not set `DM_SYNC_NAV`: under `--fixed-fps` a suite that enables a region (a seal, a baked
  Depths floor) and then relies on bodies walking may get a path from a navigation map that has not merged it yet.
- The benchmark: a level-up during the fight refreshes the god-mode hero from the throwaway character's real level, so the held fight changes
  as that character levels; the held Full Party keeps the pack in view and within 32 m, so the crowd's culling and animation bands barely
  engage (1 of 148 bodies culled); its report's budget section is labelled "Budgets (ROADMAP", but the budgets are in CLAUDE.md (B39).
- The draw model counts the rendered Graves a few draws under the engine, but Helix's World row is about 40 over the same stage: the real
  fight draws what the model's stage does not (the hero's place, the effects, the boss).

## Stability

- Quitting while models still load in the background aborted the old game on a 4-core PC (the CI runner, 2026-10-16); not checked in the
  rebuilt game.

## Assets and effects

Notes for the asset and effects rebuild (ROADMAP Phase 4):
- The baked crowd is 234 MB (positions 140, normals 70, level-of-detail meshes 23); each level of detail's mesh repeats the vertex arrays,
  where one array with Godot's own mesh LODs would share them.
- The Bone Colossus's rim reads fuller than the old game's (a pose that differs, or the baked normals at its hard edges).
- The owner's licensed effect pack's VESPER and REEBOO 3D scenes were ruled out because they need Forward+ or GPU particles while players
  ran Compatibility (ASSET_PIPELINE.md "Flipbook sheets", B12); the game is Forward+ since launch day, so they could be used once their cost
  is measured (ROADMAP Phase 2, the effects standard).

## Leftovers from the web era

- Bit-exact web math (fdlibm, exact-double loading) is still used by the Depths floor generator, auto-combat and the DB loader: `godot/sim/README.md`.
- `tools/godot/sync-slice-assets.mjs` reads `godot/data/slice/assets_used.json`; the exporter that wrote it (`export-slice.ts`) is gone, so the list is now hand-maintained.
- The user:// folder (saved login and settings) is named after `config/name`: "Death Muffin (rebuild)" in `client/project.godot` (the old
  game's was "Death Muffin (Godot slice)"). Renaming it needs a migration that copies the folder. Players see "Death Muffin" (`main.gd` sets
  the window title; the exe product name is "Death Muffin").
