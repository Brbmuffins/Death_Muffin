# Known gaps

Open gaps, verified against the code on `main`. The order they are worked in is [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.
A path below without a folder is under `client/`.

## Missing since launch day

- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on purpose (B36; ROADMAP Phase 3).
- **Ascension leftovers still on screen** (the suite audit, 2026-10-19). Decide: the Chapterhouse's Altar still opens the Ascension panel
  (`client/tests/chapterhouse/run.gd` checks that it does) and the party and friends rows still show Heat (`client/tests/next_lobby/ui_run.gd`),
  although B36 leaves Ascension out until its redesign. Claude's recommendation: hide both until Phase 3 brings the new Ascension.

## Performance

The numbers are the VPS's headless Full Party fight (2026-10-17) unless they say otherwise.
- **Weaker PCs are not measured:** no GTX 970-class PC or laptop has run the game's benchmark, so B39's floors are unproven.
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

- **An armor set touches about five files** (`server/rules/content/legendarySets.ts` or armorSets.ts, setBonuses.json, necro_gear.json,
  view_models.json, assets_used.json; `tools/generate-armor-assets.mjs` writes the rest) and moves the tests that pin counts and loot digests,
  which the agent updates by hand.
- The gear props' attachment rules (axes, size, grip point, anchor bone) live in the `_doc` of `client/data/slice/necro_gear.json`, not on a
  standards page.

## Operations

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
  Reaper's nine; any other non-necro rite is refused `unavailable`. Character select greys out the other five
  (`DmCharacterBuild.is_playable`) and the backend only accepts classes 1-4 and 11 (`PLAYABLE_DISCIPLINE_INDICES`). Missing with them:
  kit rites, monk beat meter, Bulwark (`DmPlayerRules` already honours `bulwarkUntil`).
- **The Reaper is a first pass.** It has its own portrait but borrows the Mourner's hero model and existing rite icons, has no armor set but the legendary Soul Harbinger's Raiment
  and no runes. Its soul wisps are drawn on the host only; a party member's soul
  count reaches their HUD by the caster state. Numbers (REAPER in `data/combat/abilities.json`) are a first tuning (2026-10-11 headless probe with Auto combat, level 20, no thralls: Scythe Sweep 52 damage a second on one foe and 276 on a pack of six, against the Mourner's 88 and 379; she makes up for it with 30% more health, 15% less damage taken and her leech), not yet playtested by a person.

## Combat and statuses

- **Found while building the core, approved to fix** (Helix, 2026-10-16; the core already emits each one; ROADMAP polish list): toxic corpse pools
  always hit as at level 1 (nothing sets the area level); a fallen plague bearer's pool never appears and the Mourning Bell wraith's ally heal
  never happens (signals nobody listens to); statuses never change the blows a boss takes (`DmBoss.take_damage` skips the status set's
  damage-taken multiplier, and the brain's own Fracture is never fed: a Marrow Spear's Fracture or a Sanctify on the King does nothing).
- **Reduce motion no longer turns off the hitstop:** `client/next/next_game.gd` never sets `hitstopper.disabled` (the old game's did, from Settings' `reduce_motion`), so an elite's death still freezes the frame with it on (found porting the `next_feel` suite).
- **Easy auto combat parks the hero in pockets of tombstones:** it steers straight at the nearest enemy, with no path round the graves (found
  when the core was compared with the old game, DECISIONS B50).
- Barrier has no decay (`client/next/status/README.md`), and the pools of a boss that resets linger their remaining seconds (`client/next/bosses/README.md`).

## Built but never shown

Looks and effects that exist in the code but no game scene wires up (the old game never showed them either); they stay out until each is decided
(ROADMAP polish list).
- A thrall never wears its Legion kit (the kit's armour tint on its chest and hands, the kit weapon's tier colour): the old per-creature view
  asked its host for `legion_kit_for`, which no host had.
- A thrall never wears its discipline's legion look either (the Ossuary's sentinel, the Gravecaller's legionnaire, the Rotweaver's plague
  thrall, their tints and glows): no host gave `discipline_id_for`; the crowd keeps `CrowdView.set_owner_legion` and crowd_looks.json
  `legion` for it.
- The water's ripples (under the hero, the Mire Mother's rings, the Wisp's pulse) and the Prelate's candle groups: `DmEventFx.add_ripple` and
  `set_candle_group` call a `game.dressing` that no game scene sets (client/README.md "World dressing").
- The Plague Doctor's flask leaves a 5 s toxic pool that hurts but is not drawn (`DmEnemyFx` draws only dust and ember zones).

## Look

What still differs from the old game's look is in client/README.md "The look on Forward+" ("Still different": effects on Low and
Medium, the lifts, the Depths' walls, the hero's robe area by area, emission not converted, the Fen's bake); it is the look pass (ROADMAP
polish list). Also:
- Nightfall dims only the real-time ambient: lightmapped ground, walls and props keep their full ambient (a per-area dimming of the lightmaps
  would be a decision).
- The crowd's shader changes are checked in text, not in a rendered frame: run `client/tests/crowd_look_smoke.gd` (Forward+, about two
  minutes) in the look pass; the aim ring showed about 3 m above the hero in the look probe's frames (no mouse there).

## Party and online

- **Handing a solo game's lobby connection to a guest game logs "Lambda capture at index 0 was freed" twice** (found 2026-10-19 by the
  lobby UI suite, which lets that one message through): a signal connection that captures the old game outlives it, probably in
  `client/next/party/dm_next_party.gd`. Nothing visible breaks today.
- **No automatic rejoin** (D13). A dropped client returns to its own solo game and has to join again by hand (an Open party: Join; a Closed one: a new invite or Ask to join); a dropped host ends the session (D6).
- **One area per session, Depths solo:** `client/next/areas/README.md`, `client/next/depths/README.md`.
- **Part of a joiner's state does not reach the host's sim:** the host builds the joiner's hero from the server's record (level, gear,
  set bonuses, affixes, boons, vows, upgrade tiers, rune sockets), but Colossus Mantle hooks are host-hero only; no Covenant Seal or Nightfall dim; a client cannot call Empowered bosses.
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
- A guest sees a Grave Surge only as the bodies that climb out of the crypt (the core's snapshot) and, once the host quells it, its offering: the
  banner, the cracked crypt, the sounds and the tip are the host's window only (`DmAreaFlow` listens to the host's director).

## Gathering

- Cycles gathered in the last 8 s before the player leaves or closes the window are never sent (`flush_all` does not flush the gather loop).

## UI

- **The Next-step box no longer pings the minimap:** `client/next/hud/dm_next_hud_vm.gd` sets `_map["ping"] = null` where the old game pointed it at the suggestion's target (elsewhere, or marked pingInPlace), yet Settings still offers "Point to it on the minimap" (found porting the Acre's tests).
- **No in-game leaderboard panel.** `DmApi.get_leaderboard` exists; only the website shows it.
- Unraised counsel events: `client/ui/onboarding/README.md`. Hero gaps: `client/next/hero/README.md`.
- **The item card squeezes the stat name of a long affix row:** the card of an affixed staff (the Reliquary's tooltip, seen in the screenshot tool's picture of 2026-10-18) lays a row such as `+30 INT` beside
  `+42.9 spell power, +60 essence, +3.0 essence/s (+19.4 thrall damage)` out with the name 1 px wide, so it shows a letter a line (`client/ui/widgets/dm_item_card.gd`: a row is an HBox of two labels, the first wraps and the second
  does not; the layout is the same in any renderer).

## Tools and tests

- **Game code that nothing in the game calls** (found by the suite consolidation, 2026-10-19; their tests are gone): 17 of
  `DmAudioHooks`' static one-liners in `client/main/audio_hooks.gd` (`click`, `error`, `panel_open`, `panel_close`, `needle_cast`,
  `needle_hit`, `enemy_windup`, `enemy_strike`, `enemy_died`, `hero_hurt`, `thrall_raised`, `thrall_hit`, `thrall_died`, `loot_drop`,
  `loot_collected`, `gather_cycle`, `boss_music`; the class itself is used), `DmHudMinimap.world_point` (the click handler computes the
  point itself) and `DmGameUi._can_ascend`. Delete them with the next change in those files.
- **A team app test fails now and then** (2026-10-19, 1 run in 3 on the VPS): `teamapp/tests/LogCancelTests.cs` "and the exit report is not", which reads a real
  process's filtered output right after it exits; the next two runs passed.
- **Typed lists in game code that a new boss or area must be added to by hand** (found by the content-count pass, 2026-10-19): `DmBossHost`'s
  `served_areas` and `LIVE` (a new boss in the boss data does not wake until both are edited; `client/tests/boss.gd` now fails on the mismatch)
  and `DmBenchmark.ROOMS` (`client/tests/benchmark.gd` fails on a mismatch with the world's combat areas).
- **`disciplines.json` `by_index` maps the unused class indices 0, 10 and 12 to the fallback Gravecaller**, so `DmCharacterBuild.is_playable`
  answers true for them. Nothing shows it today (character select and the benchmark list from `PLAYABLE_DISCIPLINES`).
- `launcher/tests/LauncherTests.csproj` does not load in `dotnet build`: its XML comment contains `--project` ("XML comment cannot contain '--'"); CI does not
  build it, so `launcher/tests/run-local.sh` is the only way its tests run (found 2026-10-19).
- `discord-agent/preview-godot.sh --team` still carries its own copy of the newest-6 clean-up of the preview folders in `team-files`; `server/death-muffin/team-files-prune.sh` is the shared rule it
  should call (found 2026-10-19).
- `npm run typecheck` fails on six errors in the rules' parity tests (`server/rules/gameplay/__tests__/legionRules.parity.test.ts`, `necroRules.parity.test.ts`, `vaultRules.parity.test.ts`: fixture rows typed looser than the rule functions take); CI does not run it, so it went unnoticed (found 2026-10-19).
- The Windows launcher workflow (`.github/workflows/launcher-windows.yml`) rebuilds and re-uploads the launcher zip of the current release for any
  change under `launcher/`, a README included (same version, so no launcher update and no notice; it happened on 2026-10-18).
- `client/tests/game_scene.gd`'s node checks pass about every other run under load: the counsel's tip card (16 nodes, shown at the first
  Barrow Ghoul and dismissed on a wall-clock timer) is in the scene tree for part of the run.
- The warm-up's residency (what `DmWarmup.hold` keeps, the hero kits it lets go) and its cold-load checks cannot run headless: `client/next/perf/dm_next_warmup.gd` skips its threaded loads there, so the ported `next_perfctl` leaves them out; judge them on a real window.
- The benchmark: a level-up during the fight refreshes the god-mode hero from the throwaway character's real level, so the held fight changes
  as that character levels; the held Full Party keeps the pack in view and within 32 m, so the crowd's culling and animation bands barely
  engage (1 of 148 bodies culled); its report's budget section is labelled "Budgets (ROADMAP", but the budgets are in CLAUDE.md (B39).
- The draw model counts the rendered Graves a few draws under the engine, but Helix's World row is about 40 over the same stage: the real
  fight draws what the model's stage does not (the hero's place, the effects, the boss).
- `--tune=` (`client/README.md` "Clips and tune") changes only numbers the data files hold, and most rites keep some in their scripts (Miasma's flight speed, Unleash Souls' three speeds, the Haunting Wraith's damage tick, ...), so a team PC cannot show variants of those until each moves into its rite's row of
  `client/data/combat/abilities.json`, as the Haunting Wraith's `speed` did (found 2026-10-19).
- `--boot-check --quit-while-loading` quits with the art pack's models loading on worker threads, not during the pack's own mount: that is synchronous in the first autoload (`client/main/dm_packs.gd`), before any script of the game can quit, so the step cannot reproduce a quit
  in the middle of it (found 2026-10-19).
- The old HUD suite (its checks are in `hud` since 2026-10-19) failed one check when it ran beside other suites at load 9 (twice on 2026-10-19) and passed alone; the test runner
  re-runs a failed suite alone, so nothing fails, but the check (the 20 Hz refresh count in `hud`, or the key cast beside it) may still be load-sensitive.

## Stability

- **The release build crashes while closing after the benchmark on Windows** (Helix's RTX 4070 SUPER PC, 2026-10-19, release checks of
  20261019.090501-1852fe7, job d9be0824dd0b): the benchmark finishes and saves, then the game exits with 0xC0000374 (heap corruption). The
  earlier runs that night end the same way (the dying process was what the team app took for "Death Muffin was started"). The debug build
  quits cleanly after 30 minutes of the soak, the stutter and the screenshot runs; the release build quits cleanly from its first screen; the
  Linux headless benchmark exits 0. Not known whether a player's own quit after a session hits it: the crash watch's lock is cleared in
  `main.gd` `_exit_tree`, before the engine's last teardown, so such a crash is never reported. Team app 0.3.9 keeps such a run's numbers and
  names the crash and Windows' faulting module in the bench step: ntdll.dll at the same offset every time (where the heap check fired, not the
  culprit). Narrowed on Helix's PC with the same benchmark: the debug engine with the debug pack, the release's core library and art pack closes
  cleanly (job f1b7b90ed70d); the release engine with that unbaked debug pack still crashes (job a85b67e925ff). So it is the release engine
  build's teardown, not the baked shaders, the pack or the core library alone. Next: a Windows crash dump (WER LocalDumps, needs admin on the PC).
- The Windows half of the combat core's crash note (the unhandled-exception filter and its stack walk, native/README.md "Crash notes") has
  not crashed on a real Windows PC yet; the Linux half is tested on every run. The team app's release crash check will cover it (ROADMAP Phase 1).
- Quitting while models still load in the background aborted the old game on a 4-core PC (the CI runner, 2026-10-16); the release checks'
  quit-loading step passes on Helix's 16-core PC (2026-10-19), not yet checked on a 4-core one.

## Assets and effects

Notes for the asset and effects work (ROADMAP):
- The baked crowd is 234 MB (positions 140, normals 70, level-of-detail meshes 23); each level of detail's mesh repeats the vertex arrays,
  where one array with Godot's own mesh LODs would share them.
- The Bone Colossus's rim reads fuller than the old game's (a pose that differs, or the baked normals at its hard edges).
- The owner's licensed effect pack's VESPER and REEBOO 3D scenes were ruled out because they need Forward+ or GPU particles while players
  ran Compatibility (ASSET_PIPELINE.md "Flipbook sheets", B12); the game is Forward+ since launch day, so they could be used once their cost
  is measured (ROADMAP Phase 2, the effects standard).

## Leftovers from the web era

- Bit-exact web math (fdlibm, exact-double loading) is still used by the Depths floor generator, auto-combat and the DB loader: `client/sim/README.md`.
- `client/data/slice/assets_used.json` (the models the game loads) is kept by hand: the exporter that wrote it (`export-slice.ts`) is gone.
- A comment in `server/death-muffin/lobby/src/server.js` still names the relay script by the old game's path (`client/net/relay/dm_udp_relay.gd`
  now): fix it with the next real lobby change (a comment edit alone would make the next release wait for a lobby restart).
- The user:// folder (saved login and settings) is named after `config/name`: "Death Muffin (rebuild)" in `client/project.godot` (the old
  game's was "Death Muffin (Godot slice)"). Renaming it needs a migration that copies the folder. Players see "Death Muffin" (`main.gd` sets
  the window title; the exe product name is "Death Muffin").
