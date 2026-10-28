# Known gaps

Open gaps, verified against the code on `main`. The order they are worked in is [ROADMAP.md](ROADMAP.md). Remove an entry when it is closed.
A path below without a folder is under `client/`.

## Missing since launch day

- Ascension (the Altar, vows and heat, Ashes, Covenant Boons) left on purpose (B36; ROADMAP Phase 3).

## Performance

The numbers are the VPS's headless Full Party fight (2026-10-17) unless they say otherwise.
- **Weaker PCs are not measured:** no weaker PC or laptop has run the game's benchmark yet, so B39's floors are unproven; the play reports and more team PCs will show.
- **Spikes:** a rite's cast takes 2 to 4 ms in the tick it is cast (1.2 to 1.9 ms of it its effects: `DmRiteCaster._play_event`, the `Vfx`
  nodes); a big kill's event handlers 2 to 9 ms (`DmCoreHost._dispatch`: rewards, loot, the counsel); Bone Fan's pick in Easy auto combat
  (`DmAutoCombat._primary_target`) tests every pair of targets, up to 4,000 calls, about 6 ms (the Gravecaller's default loadout does not use it).
- **Per-frame waste:** `DmCore.enemy_info` builds a 25-entry Dictionary (7 us) and is still called several times a frame by the HUD's target
  frame and the effect handlers (`DmEnemyFx`, some for one field); the host's `enemy_alive`, `enemy_position` and `enemy_radius` read one field
  of the core since 2026-10-19 (`DmCore.enemy_state` / `enemy_pos` / `enemy_radius`, 0.3 us); Easy auto combat's gather (`DmNextAutoCombat._gather`, ten times a second, 0.4 to 0.75 ms) copies
  every body in range into a row that `select_action` copies again; `DmFxBinbun.update` walks every live effect every frame (the Pyre's 56:
  about 0.2 ms).
- **Draw calls:** `Vfx` (`DmFxRuntime`) leaves some pooled MultiMeshes visible with no instance (4 of its 20 in a Full Party fight), a draw
  call each: the spikes, grave hands and bone shards of `DmFxPrims` (the decal layers and the particle rings hide when empty). Their being drawn
  empty is also what builds their pipelines on the loading screen, as the warm-up never shows them: hiding them needs the warm-up to draw each
  once first, or the first Bone Prison or Bone Mantle compiles in a fight; the area scenes' props always cast the moon's shadow (the old game stopped beyond 32 m of the hero); decals are unique quads, one
  draw call each (the Graves: 23); a crowd body outside the view that casts a shadow is drawn in the main pass too (a shadows-only MultiMesh
  would send it to the shadow map alone; worth it only if Helix's PC shows a cost).

## Content pipelines

- **An armor set touches about five files** (`server/rules/content/legendarySets.ts` or armorSets.ts, setBonuses.json, necro_gear.json,
  view_models.json, assets_used.json; `tools/generate-armor-assets.mjs` writes the rest).
- The gear props' attachment rules (axes, size, grip point, anchor bone) live in the `_doc` of `client/data/slice/necro_gear.json`, not on a
  standards page.
- **A new weapon's Atlas row is written by hand** (War's Scythe of Undeath, 2026-10-20): `tools/generate-armor-assets.mjs` copies items.json
  and computed.json for every item but adds `client/data/panels_a/atlas.json` rows for armor pieces only, so the `data` suite catches a
  missing weapon row late (the agent's job lost a check run and a session handoff to it).
- **A Pixal biped's long robe stretches between its legs** (2026-10-27): `build_rig.py` skins cloth below the knee to the legs, so a long robe
  or skirt spreads into a sheet between them on a stride (the test body's long robe did; docs/BLENDER-PIPELINE.md "Biped to biped").
  The agent asks for a concept whose robe stops at the knee or is split (`guides/models.md` step 5) until cloth gets its own bones.
- **The Discord agent's detailed models go with its worktree** (2026-10-27): the tries and `work/` files in `art-src/comfy/<id>/` are not
  committed, so a later change to an agent-made model's steps needs its run made again on a team PC (same picture, settings and seed: the
  same model, recorded in `art-manifest/comfy/<id>.json`) before `make-model.sh build`.

## Operations

- **Backups stay on this server.** `server/death-muffin/ops/backup-db.sh` writes the nightly dumps to `~/death-muffin/backups/db/` on the
  same VPS; the raw art sources (`art-src/`, gitignored), the private effect sheets and keys (`~/death-muffin/private/`), the licensed packs
  and the services' `.env` files exist only here. ROADMAP Later: a cloud storage bucket (B51).
- **Two install checks list the agent's files by hand, and both miss some.** The drift report (`server/death-muffin/ops/drift-report.sh`, check 1)
  does not compare the installed `build-picture.sh` or `blender-job.sh`; the practice run (`discord-agent/runner/canary.cjs`, step "installed") compares only the
  runner, the core scripts, the prompt and its guides, not `label-shot.py`, `render-model.*`, `art-run.sh`, `build-art.sh`, `build-sound.sh`,
  `sound-*.mjs`, `build-picture.sh`, `blender-job.sh`, `make-model.sh`, `model-run.sh`, `model-gen.sh`, `wait-for-ship.sh` or `reports-cli.cjs`. A file `install-runner.sh` copies can differ from `main` unnoticed
  (found 2026-10-21).
- **The agent can stage an ignored file.** `agit add -f <path>` is allowed, so the git-excluded job files (`.dm-inbox/` attachments, `.dm-shot.json`,
  `.dm-shots/`) could be committed; only `.dm-guides/` is in the runner's forbidden paths (found 2026-10-21).

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
- **The Reaper is a first pass.** It has its own portrait but borrows the Mourner's hero model and two other classes' rite icons (Haunting Wraith and Scythe Weave:
  `STILL_BORROWING` in `tools/pictures/pictures.test.mjs`), has no armor set but the legendary Soul Harbinger's Raiment
  and no runes. Its soul wisps are drawn on the host only; a party member's soul
  count reaches their HUD by the caster state. Numbers (REAPER in `data/combat/abilities.json`) are a first tuning (2026-10-11 headless probe with Auto combat, level 20, no thralls: Scythe Sweep 52 damage a second on one foe and 276 on a pack of six, against the Mourner's 88 and 379; she makes up for it with 30% more health, 15% less damage taken and her leech), not yet playtested by a person.

## Combat and statuses

- The status set's `barrier` (`client/next/status/README.md`) has no decay, only its 6 s hold; nothing applies it today (the hero's own barrier decays), so no data says how it should wear off.

## Look

What still differs from the old game's look is in client/next/look/README.md ("Still different": effects on Low and
Medium, the lifts, the Depths' walls, the hero's robe area by area, emission not converted, the Fen's bake); it is the look pass (ROADMAP
polish list). Also:
- Nightfall dims only the real-time ambient: lightmapped ground, walls and props keep their full ambient (a per-area dimming of the lightmaps
  would be a decision).
- **The legendary set bodies still swing the staff** (`hero_leg_*`, worn from 3 pieces): they have no staff clips, so they play the plain
  clips, made for an empty hand, with the old grip (in `run` the staff swings flat twice a stride; in the casts its head points behind the
  hero or at the floor). The four discipline heroes have them (client/game/README.md "Held props and gear look"); a body gets them from its
  slug in the recipe's `heroes` and a Blender job step `{"kind": "staff"}`. The scythe, wand and sickle were not looked at.
- **A hero slides about 25 cm to its left when a spell clip starts**: `DmCreature.prep_clips` pins a combat clip's Hip to idle's first Hip
  key, but idle (like every other hero clip) has its Hip track removed and stands at the Hip's rest position, 0.13 rig units (about 25 cm on
  the Gravecaller) away. Anchoring to the Hip's rest position would remove the slide.
- Hero `walk` and `run` lose their vertical bob (about 7 cm in `run`): `prep_clips` removes the whole Hip position track from non-combat
  hero clips, while its comment says the vertical bob is kept.
- The Gravecaller's cloak stretches into a flat sheet behind the legs in the `flick` crouch (skin weights on the cloak).
- The crowd's shader changes are checked in text, not in a rendered frame: run `client/tests/crowd_look_smoke.gd` (Forward+, about two
  minutes) in the look pass; the aim ring showed about 3 m above the hero in the look probe's frames (no mouse there).

## Party and online

- **A dropped player's seat is not held:** the rejoin offer lasts 5 minutes, but a party that filled up in that time answers `full` (the lobby reserves nothing; a held seat would show a party as full while it lists a free one).
- Chat is party chat in a party and local-only when solo.
- **Friends show offline while the launcher is open:** the launcher has no login and no lobby link. They show online from the sign-in (character select, loading, the world).
- A guest's core lists no zones (`DmCore.zones`): its zones arrive as events for its effects. Nothing reads them on a guest today.
- A guest sees a Grave Surge only as the bodies that climb out of the crypt (the core's snapshot) and, once the host quells it, its offering: the
  banner, the cracked crypt, the sounds and the tip are the host's window only (`DmAreaFlow` listens to the host's director).
- A Grave Surge opens in one area at a time, the director's own: a party member fighting in another combat area gets that area's ordinary waves but no surge (client/next/areas/SURGES.md).

## UI

- **No in-game leaderboard panel.** `DmApi.get_leaderboard` exists; only the website shows it.
- Counsel and hero gaps: the "Known gaps" sections of `client/ui/onboarding/README.md` and `client/next/hero/README.md`.

## Tools and tests

- Two checks fail in a Windows checkout (found 2026-10-25; CI's Linux checkout is unaffected): `npm run hygiene` with `core.autocrlf=true`
  (`tools/context/navigation.mjs` looks for `## Documentation map\n` and README.md has CRLF there), and the command test of
  `tools/assets/check-models.test.mjs` (the script runs `main()` only when `import.meta.url` equals `file://` + its argv path, never true for
  `E:\...`, so it exits 0 without checking).
- The Blender pipeline's `procedural`, `rigfix`, `cleanup`, `retarget` and `selftest` fail on Blender 5.x: `tools/blender/common.py` uses
  `action.fcurves`, which 5.0 removed (slotted actions: `staff.py`'s `fcurves()` reads both). They run on the VPS's 4.5; the owner's
  workstation has 5.2 (found 2026-10-25).
- `server/death-muffin/model-view.sh` queues a plan without checking it against the game's plan limits (`client/main/qa_clips.gd`,
  `qa_ui_shots.gd`) or the model's clip names: a plan that breaks one fails on the team PC, after the build and the upload (found 2026-10-26).
- A model view plays a hero's combat clips as the file holds them, where the game lifts them by the idle's hip height, so a hero sinks into
  the floor there in clips that look right in the game (found 2026-10-26).
- **The agent's sandbox test can leave a folder in `wt/`** (found 2026-10-21, context Stage 4). `world()` in
  `server/death-muffin/discord-agent/test/sandbox.test.cjs` makes `wt/dm-sbx-test-*` and runs `git init` before the cleanup exists, so a run
  whose next write fails (seen in reviews run under a restricted sandbox) leaves the folder behind: 16 were left on 2026-10-20 and 2026-10-21,
  which the drift report lists. Fix: clean up when `world()` itself fails; the folders are for the owner to remove.
- **Numbers the tests cannot read yet** (the test audit, 2026-10-20: every suite now reads the game's numbers from its data or sets them
  itself, B59). Where the game keeps a number as an inline literal, the test carries a named copy, so a retune there still needs a test edit:
  the combat core's compiled-in values that `DmCore.tuning()` does not expose (elite radius, windup and cooldown multipliers, the 1.1 s rise,
  the 4 s body linger, aggro and leash ranges, the default slam radius, the thralls' brain constants; `client/sim/sim_consts.gd` `RISE_TIME`
  and `AGGRO_RANGE` look unused by the core); every number of the Prelate (literals in `client/sim/bosses/prelate_brain.gd`, while the other six
  bosses' live in the boss data) and every boss's 60 % / 30 % phase lines, rims and phase speed-ups; HUD and counsel thresholds (low health
  0.3, toast and chat caps, the counsel's distances and kill counts), the mixer's levels, the surge offering's gold, the first-kill +2
  shards, the gathering loop's 10 s retry; shared-rules values that are not exported (contract quantities and bonus, the boss shard formula,
  `RUNE_DUST`, `MAX_FORTUNE`, `SOURCE_COUNT.min`) and the offline-sync check's typed level 100 and 12 professions; the mock backend's bag of 48
  and starter kit (`client/net/dm_mock_backend.gd`). Moving each into data or a named constant lets its test read it.
- **Goldens with no command to remake them**: `gear`, `sim`, `auto_combat_fixtures` and the audio suites' fixtures came from the retired web
  game's generators, so a gear, stat or mixer retune breaks them with nothing to regenerate them; the brew-of-the-day cases in `panel_data`
  need re-recording when a brew is added. (The loot rules' answers and the boss replays are remade or data-independent since 2026-10-20.)
- `server/death-muffin/backend/bag-fake-db.cjs` lists the salvage materials by hand, so a salvage retune fails in the fake rather than the rules.
- **Game code that nothing in the game calls** (found by the suite consolidation, 2026-10-19; their tests are gone): 17 of
  `DmAudioHooks`' static one-liners in `client/main/audio_hooks.gd` (`click`, `error`, `panel_open`, `panel_close`, `needle_cast`,
  `needle_hit`, `enemy_windup`, `enemy_strike`, `enemy_died`, `hero_hurt`, `thrall_raised`, `thrall_hit`, `thrall_died`, `loot_drop`,
  `loot_collected`, `gather_cycle`, `boss_music`; the class itself is used), `DmHudMinimap.world_point` (the click handler computes the
  point itself), `DmGameUi._can_ascend`, the mixer's `music_gain` and the director's `set_combat`, `DmApi`'s `offline_snapshot`,
  `offline_load`, `offline_versions`, `offline_restore`, `offline_sync_stats` and `get_patch_notes`, `DmGatherLoop.api_post`, the forge
  panel's `set_bonus_claimed`, `DmStatusSet.is_stunned` and `is_silenced`, and the creature's `set_rise` (only tests use `recycle_reset`).
  Delete them with the next change in those files.
- **A branch that changes `native/` cannot get team PC pictures or checks on its own** (2026-10-20): `preview-godot.sh --team` warms the shared cache from the
  merge base and builds read-only in its sandbox, so a changed combat core has no Windows build there ("prep: building the Windows combat core failed").
  Today: run `tools/check/prep.sh --windows` in the branch's worktree first (it stores the build), then the team check. The Discord agent never changes `native/`.
- **The pre-release check is skipped while the team PC runs a long check** (B61, 2026-10-19): a shipper's checks (`team-check.sh`, B62) can
  hold the PC for minutes, and with Helix's PC the only one signed in, a release then goes live without a PC starting it first (the publish
  says so); in the app's "Ask" mode it needs a click within 2.5 minutes (AFK mode and "Run without asking" take it at once). The app's offer
  box describes every `release` job with the full checks' note (benchmark and soak), whatever steps it has.
- **The lobby suite failed once in a full run on the VPS** (2026-10-19): it expected "the host ended the party" and got "Co-op data mismatch:
  the host's enemy and status tables differ"; it passes alone and in CI. Likely two suites reaching each other's local lobby at the same time.
- **A team app test fails now and then** (2026-10-19, 1 run in 3 on the VPS; 2026-10-26, 1 in 5): `teamapp/tests/LogCancelTests.cs` "and the exit report is not", which reads a real
  process's filtered output right after it exits. The cause: `OutputBuffer` (GameHost.cs) takes standard output and standard error on two threads with one "drop the next `at:` line"
  flag, so an output line arriving between a leak warning and its `at:` line keeps the `at:` line (in a real job's log too, where it is only noise).
- **Typed lists in game code that a new boss or area must be added to by hand** (found by the content-count pass, 2026-10-19): `DmBossHost`'s
  `served_areas` and `LIVE` (a new boss in the boss data does not wake until both are edited; `client/tests/boss.gd` now fails on the mismatch)
  and `DmBenchmark.ROOMS` (`client/tests/benchmark.gd` fails on a mismatch with the world's combat areas).
- **`disciplines.json` `by_index` maps the unused class indices 0, 10 and 12 to the fallback Gravecaller**, so `DmCharacterBuild.is_playable`
  answers true for them. Nothing shows it today (character select and the benchmark list from `PLAYABLE_DISCIPLINES`).
- `launcher/tests/LauncherTests.csproj` does not load in `dotnet build`: its XML comment contains `--project` ("XML comment cannot contain '--'"); CI does not
  build it, so `launcher/tests/run-local.sh` is the only way its tests run (found 2026-10-19).
- `server/death-muffin/discord-agent/preview-godot.sh --team` still carries its own copy of the newest-6 clean-up of the preview folders in `team-files`; `server/death-muffin/team-files-prune.sh` is the shared rule it
  should call (found 2026-10-19).
- `npm run typecheck` fails on six errors in the rules' parity tests (`server/rules/gameplay/__tests__/legionRules.parity.test.ts`, `necroRules.parity.test.ts`, `vaultRules.parity.test.ts`: fixture rows typed looser than the rule functions take); CI does not run it, so it went unnoticed (found 2026-10-19).
- The Windows launcher workflow (`.github/workflows/launcher-windows.yml`) rebuilds and re-uploads the launcher zip of the current release for any
  change under `launcher/`, a README included (same version, so no launcher update and no notice; it happened on 2026-10-18).
- `client/tests/game_scene.gd`'s node checks pass about every other run under load: the counsel's tip card (16 nodes, shown at the first
  Barrow Ghoul and dismissed on a wall-clock timer) is in the scene tree for part of the run.
- The warm-up's residency (what `DmWarmup.hold` keeps, the hero kits it lets go) and its cold-load checks cannot run headless: `client/next/perf/dm_next_warmup.gd` skips its threaded loads there, so the ported `perf_controls` leaves them out; judge them on a real window.
- The benchmark: a level-up during the fight refreshes the god-mode hero from the throwaway character's real level, so the held fight changes
  as that character levels; the held Full Party keeps the pack in view and within 32 m, so the crowd's culling and animation bands barely
  engage (1 of 148 bodies culled); its report's budget section is labelled "Budgets (ROADMAP", but the budgets are in DECISIONS B71.
- The draw model counts the rendered Graves a few draws under the engine, but Helix's World row is about 40 over the same stage: the real
  fight draws what the model's stage does not (the hero's place, the effects, the boss).
- `--tune=` (`client/main/CLIPS.md`) changes only numbers the data files hold, and most rites keep some in their scripts (Miasma's flight speed, Unleash Souls' three speeds, the Haunting Wraith's damage tick, ...), so a team PC cannot show variants of those until each moves into its rite's row of
  `client/data/combat/abilities.json`, as the Haunting Wraith's `speed` did (found 2026-10-19).
- `--boot-check --quit-while-loading` quits with the art pack's models loading on worker threads, not during the pack's own mount: that is synchronous in the first autoload (`client/main/dm_packs.gd`), before any script of the game can quit, so the step cannot reproduce a quit
  in the middle of it (found 2026-10-19).
- The old HUD suite (its checks are in `hud` since 2026-10-19) failed one check when it ran beside other suites at load 9 (twice on 2026-10-19) and passed alone; the test runner
  re-runs a failed suite alone, so nothing fails, but the check (the 20 Hz refresh count in `hud`, or the key cast beside it) may still be load-sensitive.
- `server/death-muffin/team-gate.test.cjs` "a stop from the publish's timeout cancels the job and removes the folder" failed twice on GitHub CI
  (runs 39633431669 and 40058679851: the gate's folder was still there when the test looked, after a 2 s `timeout`) and passes locally every time
  (found 2026-10-21, again 2026-10-24): the folder removal races the check on a slow machine.

## Stability

- **The Windows release engine crashes in its last teardown, after every quit** (Helix's RTX 4070 SUPER PC, 2026-10-19; Windows crash files
  of a benchmark run and of a player's quit: 0xC0000374 heap corruption at ntdll+0x118095, and 0xC0000005 at DeathMuffin.exe+0x3f8832f, beside
  +0x3f88433 on the first one's stack). The debug engine with the same pack, core and art closes cleanly; the release engine with an unbaked
  pack still crashes; the combat core is not on the stack and Godot publishes no Windows symbols. Worked around by B60 (the release build ends
  its own process after its shutdown); the cause inside the engine is not known. Team app 0.3.9 still names any crash code in the bench step.
- The Windows half of the combat core's crash note (the unhandled-exception filter and its stack walk, native/README.md "Crash notes") has
  not crashed on a real Windows PC yet; the Linux half is tested on every run. The team app's release crash check will cover it (ROADMAP Phase 1).
- Quitting while models still load in the background aborted the old game on a 4-core PC (the CI runner, 2026-10-16); the release checks'
  quit-loading step passes on Helix's 16-core PC (2026-10-19), not yet checked on a 4-core one.

## Assets and effects

Notes for the asset and effects work (ROADMAP):
- The twelve floor and wall textures (`client/assets/slice/art/textures`) were made seamless with the old two-way blend, which leaves a faint
  seam in the middle of each tile edge (measured 2026-10-20: about twice the usual pixel step on `fen_floor`, hard to see on the others). The
  picture builder's blend has none; remaking a texture needs a new concept through the `floor_texture` or `wall_texture` kind.
- The baked crowd is 234 MB (positions 140, normals 70, level-of-detail meshes 23); each level of detail's mesh repeats the vertex arrays,
  where one array with Godot's own mesh LODs would share them.
- The Bone Colossus's rim reads fuller than the old game's (a pose that differs, or the baked normals at its hard edges).
- The Weeping Seraph's wings stretch and tear in its `cast`: the shipped model's own skin weights at the wing roots (seen while testing
  Pixal3D remakes, 2026-10-26); a weight fix is a Blender job.
- The skull rat's `idle` dips its tail tip up to 2 cm below the floor (its `run` lifts the tail chain for the same reason; found 2026-10-26).
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
