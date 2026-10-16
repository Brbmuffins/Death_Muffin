# The rebuilt client

The rebuilt Death Muffin client (ROADMAP "Now: the rebuild", DECISIONS B34-B42): its own Godot 4.7.2 project, next to the live game in
`godot/`, which it never changes. The live game keeps shipping from `godot/` until launch day; this project ships only to the launcher's
Test build channel until then.

- Renderer: Forward+ (`project.godot`), Compatibility only as the automatic fallback, the Mobile renderer for phones (B35). Textures also
  import in phone formats (B40).
- Its own user:// folder (`config/name` "Death Muffin (rebuild)"), so it never shares saved logins or settings with the live game.
- It talks to the **test server** only (DECISIONS B38), never the live one before launch day: [The test server](#the-test-server-login-and-character-select).
- The combat core is a C++ GDExtension built from [native/](../native/README.md) into `bin/` (built files are not committed;
  `bin/dmcore.gdextension` is).
- Crowds are drawn from baked vertex-animation textures, one MultiMesh per creature model and level of detail, driven by the combat core through `CrowdView`:
  [crowd/README.md](crowd/README.md).

## Set up and test

```
bash client/setup.sh                                                       # builds the core for Linux, imports, runs the smoke test
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/core_smoke.gd   # the core loads and answers
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_bake.gd    # the crowd baker and shader (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/code_load.gd      # every copied script, scene and resource loads; no copy names a per-creature class
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/crowd_view.gd    # the crowd's views against today's view code, and a Full Party (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/game_scene.gd     # the game scene on the core: 60 s of an offline run in the Graves (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/rites.gd          # the Gravecaller's rites on the core: all 25 necromancer rites against today's rules, a fight (bakes into a scratch folder; 90 s of game time, --fixed-fps 60 makes it faster)
/home/ubuntu/tools/godot/godot --headless --path client --script res://tests/boss.gd           # the Gravedigger King on the core: his brain replayed against today's scenarios, his fight, the thralls, the rites, his defeat and a new summon (bakes into a scratch folder; add --fixed-fps 60 before --path to run it faster than real time)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/front.gd   # boot, login, character select and the game scene with the chosen character on the mock; the API rule; the real test server's health (bakes into a scratch folder)
/home/ubuntu/tools/godot/godot --headless --fixed-fps 60 --path client --script res://tests/hud.gd     # the HUD on the core: target frame, minimap dots, hotbar and cooldowns, thrall pips, floating number caps, pools, pieces, z layers, the draw-call model (bakes into a scratch folder)
bash client/tools/bake_crowd.sh                                                                # bakes the crowd models (the roster's robber and hound, the thralls) into client/crowd/baked (not committed)
```

Run `bash client/setup.sh` once in every new checkout or worktree (it lists the extension before the first import; see the script).

## Code from today's game

The client runs today's scripts, scenes and data (DECISIONS B43) at the same paths as in `godot/`, so `res://` paths, class names and script
uids keep working:
- **Copies:** `client/code.list` names what is copied (globs relative to `godot/`, `!glob` leaves files out; a script's `.uid` goes with it).
  `node tools/rebuild/sync-code.mjs` brings the copies up to date (adds, replaces, deletes copies whose original is gone); `--check` changes
  nothing and fails when anything is out of date. A copy is never edited in `client/`: the hygiene check fails when one is.
- **Ports:** a file that has to change to run on the core (a rite, the director, a boss, a view) is ported: `node tools/rebuild/sync-code.mjs
  --port <path>` marks it and records the version of its original. From then on the sync tool leaves it alone and lists it under PORTS BEHIND
  when the live original changes (a live bug fix), with the `git diff` that shows the change; carry it over, then `--port` the file again.
- `client/code.lock.json` (written by the tool, committed) records every copy and every port. Only files it lists as copies are ever replaced or
  deleted, so the client's own files (`core/`, `crowd/`, `areas/`, `tests/`, ...) are never touched; a copy that would land on one is refused.
- **Proof:** `tests/code_load.gd` loads every copy through `ResourceLoader` (scripts must be able to instantiate, scenes and resources load with
  every dependency present, JSON parses, a class name must not collide with another script) and fails when a copy names a per-creature class or
  path in code (comments do not count). It prints the counts. A new file in a copied folder of `godot/` is copied by the next sync; if the test
  then fails on it, it is a new seam: add it to the right section of `code.list`.
- **`project.godot` is the client's own, not a copy.** From `godot/project.godot` it takes by hand what the copies need: the autoloads of copied
  scripts (`Packs`, `AudioDirector`, `Vfx`; not `Qa`, which is left out with its seam), the display and theme settings the UI layout assumes
  (1600x900 viewport, `canvas_items` stretch, `dm_theme.tres`) and the 60 Hz physics settings (3 steps per frame, physics interpolation). The
  renderer, name, features, main scene (the boot, `main/main.tscn`), layer names and import defaults stay the client's. Input actions are registered at run time by the copied code, and
  the only `ProjectSettings` read, `application/config/version`, has a default.

### What is left out

`client/code.list` says why, section by section; its comments are the list:
- **Per-creature systems** (`enemies/`, `sim/sim_enemy|thrall|corpse|zone.gd`, `next/thralls|corpses|affixes`, `game/dm_entity_views.gd`): the combat core and the crowd view
  replace them (native/README.md "Design").
- **Seams** (55 files at the start): a file outside those systems that names one of their classes or scenes: the rites, the bosses, the HUD's enemy reads, auto combat input, the benchmark
  fight. Each line names what it uses. They are ported to the core in the later steps of the ROADMAP's client layer, and `--port` then moves them from the list into `code.lock.json`.
  Ported already: the game scene, the director, the hero body and look, the input, the enemy fx, the avatar and the event fx; the Gravecaller's rites (the caster, the module base, the legends, the
  registry, 24 of the necromancer's 25 rites, the rite fx, the combat input; "The Gravecaller's rites"); and the boss host, body, world, fx and view ("The Gravedigger King").
- **Left out with a seam**: a file that cannot load without a seam, grouped under the seam it follows. The biggest chains now: `DmReaperRites` (the Reaper's nine rites) and the party
  (`DmNextFriends` reads the game scene's `party`: the friends and party panes, the social window and `game_ui/dm_game_ui.gd`).
  Freed by the game scene's port and copied again: `next/status` (`DmStatusSet`, for the status sets of heroes and bosses only),
  the chronicle, the event fx's telegraph and boss halves, the area flow, gathering and the joiner. Freed by the rites' ports: the hotbar (`dm_rite_hotbar.gd`), Veil Step, the belt and the progress node.
  Freed by the boss ports: `next/bosses/dm_boss_meta.gd` (the Covenant Seal altar choice; it needs rewards and the backend, so nothing creates it yet).
- **Ported for the test server** (not seams): the boot `main/main.gd` and `main/main.tscn` (freed from the left-out list by the front flow's port), `net/dm_config.gd` and
  `net/dm_http_transport.gd` (below).

## The game scene and the dev entry

`next/next_game.tscn` (`DmNextGame`, a port of today's) is the game on the combat core: a **solo run in the Hollow Graves**, with the character the front flow chose on the test server
(below) or, from `dev/dm_dev_entry.tscn`, a dev character on the local mock backend, the way today's `--dev-offline --class=2` does. **The dev entry reaches no server**: the backend is
`DmOffline.make_mock` (accounts in this project's own `user://dm_dev_offline_db.json`) and has no base url. `DmNextGame.start` refuses any api whose base url is not the test server's.

```
bash client/setup.sh                                   # once per checkout: builds the core, imports
bash client/tools/bake_crowd.sh                        # once: bakes the robber, the hound and the thralls (without them nothing is drawn; the other defs borrow these)
/home/ubuntu/tools/godot/godot --path client            # the boot: login and character select on the TEST server, then the game (below)
/home/ubuntu/tools/godot/godot --path client -- --dev-offline --class=1             # the same boot with the local mock backend and no network at all: straight into the game as `tester` (--seed=N --no-waves --baked=<dir> too)
/home/ubuntu/tools/godot/godot --path client res://dev/dm_dev_entry.tscn           # the dev entry: the Gravecaller at level 10, the HUD, waves. He fights with the rites (controls below)
/home/ubuntu/tools/godot/godot --path client res://dev/dm_dev_entry.tscn -- --class=1 --seed=7 --crowd=70      # options after `--`: --class=N --level=N (default 10) --seed=N --no-waves --crowd=N (a first wave of N bodies 6 to 12 m around the hero) --boss (the hero starts at the King's grave and wakes him) --baked=<dir> --shot=<png> [--shot-after=<game s>] (rendered runs only)
```

**Controls of the dev entry** (today's input and hotbar code): **LMB** on the ground walks there, on an enemy walks into range and casts the primary (Bone Needle; hold to repeat, Shift+LMB casts in place);
**1-4** are the kit's default loadout (Marrow Spear, Exhume, Miasma, Black Litany; hold a key to repeat), **RMB** is Corpse Explosion, **R** the signature from level 10 (Command: Rend), **WASD** walks, the wheel
zooms. The other rites cast through `DmNextInput.cast_at(slot, aim, enemy_id, true)` or the caster's `request_cast(rite, aim)` until the loadout panel comes with the panels. `--level=N` sets the level the mock
character is made at (R needs 10, Bone Mantle 12, Bone Storm 14; all rites unlock by 14).

**`DmCoreHost`** (`core/dm_core_host.gd`, the scene's `Core` node) is the one owner of the `DmCore` and the `CrowdView`. It loads the data (`DmCoreData.load_all`: this project's `data/`; the
three constants files of the creature systems are not here, so the core keeps its compiled-in defaults, which `core_thralls` checks against the live files), seeds the core and
gives it the area's navigation map and bounds, and registers each hero body as an external (position and alive flag written before every step). Its tick runs at
`process_physics_priority` 100: after the session (which moves the hero bodies) and the director (which spawns), before the crowd's own 1000. A tick is `core.step`, `CrowdView.sync()`, then
`core.take_events()` once, decoded in order into one typed signal per event kind (`enemy_spawned`, `enemy_state`, `enemy_damaged`, `enemy_died`, `enemy_attack`, `telegraph`,
`target_hit`, `zone*`, `corpse_*`, `thrall_*`, `status_*`, `affix_moment`; `core/dm_core_events.gd` has the numbers). Systems connect to the signals; nothing polls per creature, and
**no node and no script exists per creature**: an enemy is an id (an int) everywhere, and `enemies_in_radius`, `enemy_position`, `damage` and `apply_status` are thin queries on the core.
`CrowdView._process` draws the rendered frames with `Engine.get_physics_interpolation_fraction()`.

The pieces around it (all ports, `code.list` "Ported"): the **world** (`next/next_world.gd`) loads `areas/graves.tscn` with the same small API as today's world object (`area_at`, the
navigation helpers, `spawn_point`) and keeps a `DmWorldBuilder` for the area's lights only; the **director** (`next/spawn/dm_wave_director.gd`) spawns through `core_host.spawn_enemy` with the affix
roll of today (`core/dm_affix_roll.gd`), counting from the core; the **hero** (`next/hero/dm_hero_body.gd`) takes the enemies' blows from `EV_TARGET_HIT` with the enemy's id as the source;
**input** (`next/next_input.gd`) picks the hovered enemy by asking the core for the bodies near the cursor's ray; **enemy effects** (`next/enemy_fx/dm_enemy_fx.gd`) play the telegraphs, strikes (timed from the
wind-up), deaths, voices, dust clouds and the affixes' bell, meal and burst from the host's signals, through the same router and the `Vfx` and `AudioDirector` autoloads.

Off in this step, each until its ROADMAP item: party and co-op, gathering, the Chapterhouse
(the hero starts and gets up at the Graves' door), the Depths, rewards and progression (no XP, loot or saves; `DmNextGame.rite_hit` carries every blow of a rite for them), the panels (the HUD is there, "The HUD on the core"; its menu row, chat, Empower panel
and loadout wait for theirs), Easy auto combat, the Reaper's rites, the graphics governor, Grave Surges. `native/README.md` "Differences from today's game" lists what behaves differently from today.

## The Gravecaller's rites

Today's rites (`godot/next/rites`, DECISIONS B42) run in this project as GDScript and call the core synchronously: a rite damages with `core.damage(id, amount, source)` and reads `{dealt, killed}` at once, so Wailing Skull's
extra leap on a kill, Bone Prison skipping the dead, and the Litany's loops work as they do today. `next/rites/` has the necromancer's 25 rites (the Reaper's nine wait for the Reaper: the registry does not list them
and a cast of one is refused `unavailable`); 24 are ports, Veil Step is a copy. `DmNextGame.attach_caster` gives the hero his `Rites` node (a `DmRiteCaster`, the game scene is its `DmRiteWorld`) and `DmRiteHotbar.wire`
connects the input. The numbers (spell power, cooldowns, costs, runes) are still `DmAbilities`, `DmSimData` and `abilities.json`; the thralls' stats `DmThralls.raise_stats / colossus_stats`.

What a rite uses where it used nodes (all on the caster `c`; the adapters belong to the game scene's `DmCoreHost` and live in `core/`):

| today | on the core |
|---|---|
| `c.world.enemies_in_radius`, `enemy_by_id`, an enemy's `global_position`, `radius`, `hp` | `c.foes_in_radius(pos, r)`, `c.foe(id)`: `DmFoe` snapshots (id, x, z, radius, hp, state, def, area), living, spawn order, edge distance (`core/dm_foe.gd`) |
| `DmStatusSet.hit(e, amount, c.body)`, then `e.hp <= 0` | `c.deal(id, amount)` returns `{dealt, killed}` (`c.hit` the bool); the hero is the source |
| `DmStatusSet.ensure(e).apply / has / stacks / remove`, `c.watch_dots(ss)` | `c.apply_status / has_status / status_stacks / remove_status`; the DoT credit and Withered's hand-on are the core's events, connected once per caster |
| `DmCorpseField`, `DmSimCorpse` | `c.corpses()` (`DmCoreCorpses`, `core/dm_core_corpses.gd`): `pick_corpse`, `corpses_in_radius`, atomic `consume`, `add_corpse`, `notes(id)`; records are `DmCoreCorpse` snapshots |
| `DmThrallHost` (`raise`, `rally`, `command_rend`, `near`, `list`, a `DmThrall` node) | `c.thralls()` (`DmCoreLegion`, `core/dm_core_legion.gd`): the same calls, a thrall is an id and `info(id)` is the core's record; cap, formation, swing and death are the core's |
| lane, cone, circle, `pick_enemy` of `DmRiteModule` | the same functions, answering from the core's radius query with today's rules (edge distance, strict comparisons, spawn order, caps) |
| `e.set_meta` (contagious, the Chain Plague gap, the shroud's cover) | by enemy id in the rite's memory; the shroud's cover is `core.cover_miasma` |

Timers stay the caster's (`c.after(ms, fn)` on the body's clock, a physics tick). Events and fx are today's: `broadcast` -> `play` -> `DmRiteFx` through the copied `Vfx` and `AudioDirector`. The hero's own statuses stay
`DmStatusSet`. The cast flow (owner, cooldown, essence and cast lock through `DmAbilities.cast_check / apply_cast_cost`, refund on a lost corpse race) is unchanged. `client/tests/rites.gd` casts every rite
(table-driven against the copied rules code), the refusals, the synchronous-kill cases, the kit's hotbar and the click-to-attack chase, and plays a fight; `native/README.md` "Differences from today's game" lists what differs.

## The Gravedigger King

The Hollow Graves' boss (`next/bosses`, `sim/bosses`, `game/dm_boss_view.gd`) runs in the game scene as DECISIONS B42 says: **an external entity of the core (kind 1) whose brain stays GDScript.** The brains of `sim/bosses` are
copies, unchanged (the brain does not know what a core is: it asks its `DmBossWorld`); five files are ports (`code.list` "Ported"). `DmBossHost` (child `Bosses` of the game scene, `g.bosses`) has today's summon rules, spawner,
event routing, fx and music; `DmBoss` is the body; `DmBossNodeWorld` is the brain's view of the world, answered from the core. Only the King wakes in this build (`served_areas` is the Graves): the other six bosses' brains are
copied but need their areas, adds and pools.

| today | on the core |
|---|---|
| `DmBoss extends DmEnemy` (a `CharacterBody3D` in the `dm_enemy` group, with a collider, a navigation agent, a state machine) | a plain `Node3D` that registers with `DmCoreHost.register_boss` (its `core_id` is an **external of kind 1**) and keeps what it took from `DmEnemy` as fields: `hp`, `max_hp`, `radius` 1.6, `damaged`, `died`, `is_hittable()` |
| thralls scan and hit it as an enemy (group order, boss edge rule) | the host writes `set_external(id, place, is_hittable())` before every `core.step`: `alive` is false while it cannot be hurt or is not awake. Thralls scan it after the enemies by the core's boss edge rule; their blows come back as `EV_THRALL_HIT_EXTERNAL` (`thrall_hit_external`) and `DmBossHost._on_thrall_hit` gives them to `DmBoss.take_damage` with the owner as the credit |
| `world.enemies_in_radius` appends living bosses; `enemy_by_id`; `DmStatusSet.hit(e, ...)` | `DmCoreHost.enemies_in_radius / foes_in_radius / foe / enemy_info / enemy_position / enemy_alive / enemy_radius / damage / apply_status / status_stacks / remove_status` answer for a boss id too: the living boss comes after the enemies, measured to its edge, as a `DmFoe` with `boss` true (so the caster's `c.foe`, `c.foes_in_radius`, `c.deal`, `c.apply_status` and the lane, cone and circle helpers of `DmRiteModule` reach it with no change), the hover pick finds it, and a blow on its id is `take_damage` into the brain |
| its `DmStatusSet` | the same: statuses on a boss are the boss's GDScript set (B42); slow, root and chill show and the brain ignores them; a stun staggers it at most 0.5 s every 8 s |
| the brain's `world.spawn_enemy / remove_enemy` | the adds are the director's spawn through the core, in the boss's area and at its level (`DmWaveDirector.spawn` returns the core id); they leave with the boss (defeat or wipe) through `DmCore.remove_enemy`: out of the table at once, no death, no corpse, no credit |
| its blows: `hero.take_damage(dmg, boss)`; `thrall.take_damage(dmg, boss)` | `hero.take_damage(dmg, boss.core_id)` (the id is the source, like any enemy's: the hero's body finds where the blow came from, and Colossus Mantle's reflect finds him by it); `core.damage(thrall id, dmg, boss.core_id)` |
| the Scythe's arc and the needle's range treat a `DmBoss` apart | `DmFoe.boss`: the arc counts it separately with its own reach and one of the arc's hits, the needle's range counts its radius, and the click-to-attack chase does too |

What the host's `DmCoreHost.tick` does with it, in the tick's order: the boss's `_physics_process` (priority 0, with the session and the director) pumps the brain and mirrors its position, then the host writes the external and steps the core; the
core's thralls act on the place it wrote, and their blows on it are given to the brain as the tick's events are dispatched.

**Summoning** is today's: key E within 4 m of the King's grave (or `bosses.request_summon`), the refusals `far`, `unknown`, `busy`, `dead`. **Shards are not charged in this step** (there is no progression to take them from: `g.rewards` is null), so the summon is free.
**His defeat** is the host's `defeated` signal (a real kill; `reset` for a wipe), the brain's events (`brain_event`), `DmBoss.died` and the boss sounds; `DmSessionRewards.on_boss_defeated` is called when the rewards item brings `g.rewards`. The dev entry's `--boss` starts the hero at the grave and wakes him.

`client/tests/boss.gd` is the proof: the six recorded Gravedigger scenarios of `godot/tests/bosses` replayed tick by tick through this project's copy of the brain, the summon rules, the awaken numbers, his attacks and phases stepped by hand with today's numbers and
timing (sweep, Burial, phases, ghouls on the rim, the elite, the pits, the double sweep, the blows on the hero and on a thrall), the wipe (adds leave silently), thralls (the edge rule, `thrall_hit_external`, credit, `alive` false while he cannot be hurt),
the rites (edge distance, order, lane, cone, circle, the needle's range, the Scythe's arc, the Spear's rally, Fan, Lance, statuses, stun), the defeat events, a second summon, a fight on the real clock and the net state round trip.
Not in it: the other six bosses; their pools, niches and hooks (the core makes no zone for a boss, has no call that sets a body's health, and the Veilwalker's echoes are not ported); shards and rewards; the boss bar and banners (the full HUD); Easy auto combat's use of the
boss (`dm_next_auto.gd`); replicating him to guests (the co-op step).

## The HUD on the core

Today's HUD (`DmHud`: orbs, hotbar with cooldowns and the cast state, target frame, minimap, thrall pips, XP and level, area line, banners, toasts, floating numbers, death veil) runs in the game scene
(`opts.hud = true`) with the same layout and look, fed from the combat core. `DmNextHud` (`next/next_hud.gd`, a CanvasLayer) owns a `DmHud` and a `DmNextHudVm` (`next/hud/dm_next_hud_vm.gd`); both are
ports (`client/code.list`). Nothing runs per creature per frame:

| piece | where it reads |
|---|---|
| view-model refresh | a timer of 50 ms counted from the core's ticks (`DmCoreHost.ticked`), as `DmGameUi.HUD_INTERVAL_MS`; ~0.2 ms with a Full Party crowd, 0.06 ms per frame at 60 fps |
| orbs, XP, level, area | the hero body (`hp`, `resource`), the character, `DmContent` |
| hotbar, cooldowns, cast state | the hero's `DmRiteCaster` (`cooldown_left`, essence, souls); the kit's mapping (`DmRiteHotbar`) |
| "no corpse" / "no legion" dimming | one `core.corpses_in_radius` (13 m around the hero) and `core.thrall_count` per refresh |
| target frame | `core.enemy_info(id)`, `core.statuses(id)` (4 bytes a status: id, stacks, tenths of a second) for the one enemy under the cursor or last aimed at (held 4 s); chips from its affix list |
| minimap dots | `enemy_ids / enemy_positions / enemy_states`, `thrall_positions / thrall_states`, `corpse_positions`: flat arrays, filtered in one pass into the packed lists the minimap takes; an elite is flagged from `enemy_spawned` |
| thrall count, pips, red pips | `core.thrall_places`, `thrall_owners / thrall_hp / thrall_states` (under 35 % health) |
| floating numbers | the caster's `hit_number` (the rites' own events, with the impact point), the host's `enemy_damaged` of a thrall and `status_dot`, the hero's `hurt`; `DmFloatBudget` caps them (14 hit, 5 dot, 6 thrall, 22 in all, a crit 4 past) |
| boss plate, minimap dot | `g.bosses.active_boss()` (name, phase, hp; the King's dot on the map) |
| notices | the first entry into an area (banner), a themed wave (banner once per area), a refused cast (an "info" number over the hero), the boss fx's banners and the summon refusals (`DmNextHud.game_event`, the sink of `bosses.fx.host`) |

Not in the game scene yet, each until its ROADMAP item (the panels' host `DmNextUiHost`, `DmGameUi` and the party chain stay out, `client/code.list`): the menu row, chat and the report button, the Empower / Quicken panel and
the wave dial, the Spellbook, party frames of other players and the social window, the belt, the Kill Chain, the Omen, the Depths readout, interaction prompts and the Next line, the counsel's
tips, the loadout (the hotbar is the kit's). The pieces whose systems are not in the scene take their data from `DmNextHud.feeds`, which a test or a later system fills with the same view-model keys
(`tests/hud_feeds.gd` fills all of them).

**Pieces (DECISIONS B40).** Every readout group is a Control of its own with its own anchors and offsets, listed in `DmHud.pieces` (`party omen ward chain belt target boss map toasts banner prompt hint chat xp altar
upgrades`). `set_piece(id, offset, scale)` moves one by `offset` logical pixels and scales it (0.5 to 2) around the corner its anchor holds (a piece anchored to the top right grows left and down, the hotbar up and
sideways); `set_layout({id: {offset, scale}})` applies a saved layout (a piece it does not name goes home); `show_piece(id, false)` hides one for good; `set_hud_scale(0.75 to 1.3)` scales them all at once, as
Settings did. The game scene takes `opts.hud_scale` and `opts.hud_layout`. There is no editor: this is the structure it will need.

### The HUD's budget

DECISIONS B39: the HUD at most 0.5 ms and 150 draw calls on Helix's PC. Today's HUD was about 550 draw calls (the benchmark's Compatibility numbers: ROADMAP "Before numbers"). In Godot 4.7's canvas renderer
(`RendererCanvasRenderRD`) consecutive commands that share a texture and a kind are ONE draw call, and a rendered run measured what is not (Forward+ on lavapipe, 2026-10-16; `tools/hud_measure.gd --micro`):

| drawn with | draw calls |
|---|---|
| rectangles (`draw_rect` filled), any number, in any items; lines (`draw_line`, thick or anti-aliased too) | 1 together |
| icons of one texture or of regions of one atlas, with any colour; 9-patches (`StyleBoxTexture`) of one texture, other regions and colours | 1 together (a different texture, or a rectangle between icons of another texture, starts a new one) |
| glyphs of one font and size, with or without a shadow; a Label with an outline: its outline and its fill | 1 together; 2 for every outlined label (the outline has an atlas of its own) |
| `StyleBoxFlat` panel (fill, border, radius, shadow: any) | 1 each |
| `draw_circle`, `draw_colored_polygon`, `draw_polyline` (3 when anti-aliased), `draw_arc` (3), `draw_rect(filled = false)`, a RichTextLabel, an item with `clip_contents` | 1 each |
| `clip_children` (the minimap's disc) | +2 and its inside as above |
| items with different `z_index` | sorted by z first, then tree order: the same kinds of drawing on one z layer batch even when their controls are far apart in the tree |

What the HUD does with that (`ui/hud/dm_hud_kit.gd` has the layers, `next/hud/dm_hud_atlas.gd` the atlases; all of it keeps the look):
- **Layers.** Panels (9-patches) z 0, rectangles and icons 1, vector art 2, rectangles over the art 3, text from 4 up (one layer for each font and size), toasts, banner and prompt +100, the floating numbers 200.
  A HUD label is put on its layer when it is made; `DmHudKit.layer_tree` does the rest of a subtree.
- **One atlas.** A runtime atlas holds every icon (ability art is kept at 128 px, shown at 62), a white block (any rectangle), the bars' gradients and, on a page of its own, every panel's 9-patch (`DmHudKit.plate`
  makes a `StyleBoxTexture` of the picture of a `StyleBoxFlat`; `style` still gives the StyleBoxFlat the copied panels ask for). A greyed slot icon is a baked variant, not a shader.
- **One mesh per widget.** The orbs (2 draws), cooldown sweeps (5 triangles at most), thrall pips and gems (one mesh for the row), the level badge, the minimap's frame, disc and edge fade, its marks and arrow, and the
  death veil are triangle bags (`DmHudMesh`); the minimap's dots are one MultiMesh.
- **Floating numbers are a pool** (`DmHudFloats`): 48 entries of two canvas items made once; a frame only moves them; the numbers of a kind are two draw calls.

*Measuring.* `tools/hud_measure.gd` starts the game scene with the full HUD in a Full Party-like crowd (72 enemies, 32 thralls, numbers kept at their caps), reads
`RenderingServer.get_rendering_info(RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)` and the canvas share of it with the HUD hidden and shown, as the game scene shows it and with every piece on, prints the HUD's CPU cost, and
(`--micro`, `--fidelity`, the breakdown) the cost of each drawing primitive, the pixel difference of each replacement against the original, and each piece alone. It writes one JSON line per measurement as it goes:
```
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1600x900x24" \
  timeout 55 /home/ubuntu/tools/godot/godot --path client --rendering-driver vulkan --resolution 1280x720 --fixed-fps 60 --script res://tools/hud_measure.gd -- --out=<file.jsonl> [--shot=<png>] [--micro] [--fidelity] [--3d]
```
**Status (2026-10-16): the budget is modelled, not yet measured in the game scene.** On this VPS a Forward+ process needs ~21 s to reach its first script line and then ~23 s inside the first main-loop iteration (software
Vulkan pipelines; it did not shrink with drawing switched off), so a 55 s run has about ten seconds left. The three runs allowed for this item produced the table above (the first, a bare scene) and nothing from the game scene
(the later two reached the end of the scene's build at 50 s). Run the harness once with a longer limit (`timeout 180 ... --budget=170`) or on Helix's PC to close it.

*The model.* `tests/hud_cost.gd` is a model of the batching rules in the table; `tests/hud.gd` first checks that it reproduces the 18 numbers the rendered run counted for the same trees, then asks it about the HUD in a Full Party fight
(72 enemies, 12 thralls, casts on cooldown, a target with four statuses, toasts, numbers at their caps): 63 draw calls as the game scene shows it (26 text, 10 vector art, 8 floating numbers, 6 toasts and banner, 3 panels, 1 rectangles
and icons, 1 borders) and 81 with every piece on and fed (41 text, 13 art). The test fails above 150, so a control left on the wrong layer or a new polygon per thing shows up in CI. Asked about logged copies of today's widgets in the same
fight the model said about 500 for the game scene's HUD (the hotbar 188, the minimap column 160, the floating numbers 104, the target frame 18) and 630 with every piece on; the benchmark counted 544 to 564 for it in Compatibility. What looks different from today's HUD, piece by piece: native/README.md "Differences from today's game", "The HUD".

*CPU.* `tests/hud.gd` prints the refresh (view-model build and apply) and a frame with the HUD against one without; `DmNextHud.refresh_us` counts the live refreshes. With 72 enemies and 32 thralls on this VPS: build 0.19 ms + apply 0.05 ms
every 50 ms; a headless frame with the HUD costs ~0.1 to 0.2 ms more than without (no drawing: every `_process`, tween and `_draw` callback runs).

## The test server: login and character select

`main/main.tscn` (`DmMain`, a port of today's) is the project's main scene. It is today's boot and front flow (login, register, the online gate, character select, the discipline switch,
the saved login `user://dm_jwt.txt` in this project's own user folder), pointed at the **test server** (`server/death-muffin/test-server/README.md`: copies of the team's accounts, its own
database and signing key, so nothing played here can touch a live character), then the ported game scene with the chosen character:

```
/home/ubuntu/tools/godot/godot --path client            # login (the team's accounts were copied to the test server) or register a throwaway account there; pick a discipline
```

- A character that already exists skips the select screen (today's `resume()`); one whose discipline is not playable goes to the discipline switch. The online gate reads the test channel's
  manifest (`https://muffindevelopment.com/death-muffin/client-test/manifest.json`, its `online` block).
- **The character's build comes from the server**, read-only, before the game starts (`DmMain.load_build`): the bag's rows (worn gear, set bonuses, the weapon line) and the progression (damage and
  legion tier, boons, vows). `DmNextGame.build_for` builds the hero from them as today's does from the progress node and the bag, so the hero's health, spell power and loadout follow the worn gear.
  A bag or progression the server fails to give sends the player back to the login screen with the server's words; nothing is written, created or imported.
- Server errors are shown as today shows them ("Cannot reach server — check your connection", the server's own `error`, "Request failed: 502"); a stored login with the server unreachable lands on
  the login screen saying "Online opens soon", as today.
- **Off until their items:** rewards and the kill ledger (no kill report), progress and bag saves, party, friends, chat, gathering, the Chapterhouse, the panels (so no Log out or Switch character:
  close the game to sign in again), the benchmark (the select screen's button says it comes with the Full Party fight), the lobby join, the automatic crash report and the update notice. A hero of a
  discipline other than the Gravecaller has no hero model yet (`client/assets.list` carries `hero_gravecaller` only) and the rites are not ported for any of them.

### The API rule (DECISIONS B38)

The rebuilt client **never talks to the live server before launch day.** Where it may talk is set in **one place**, `net/dm_config.gd` (a port of the live game's config), and enforced twice:
- `DmConfig.API_BASE` is the test API (`https://muffindevelopment.com/death-muffin/test-api`), `SITE_BASE` the test channel's folder (`.../client-test/`, the manifest), `LOBBY_URL` empty (the test lobby comes with 2-player co-op). A dev run, a
  test run and an exported build all read these constants: there is no publish-time swap to miss.
- `DmHttpTransport.send` (the one door to the network, a port) refuses any URL `DmConfig.allows_url` does not accept: under the test API or the test channel's folder, nothing with a `/..` that a
  server would resolve elsewhere. It logs an error and answers like an unreachable server. `DmNextGame.start` refuses any api whose base url is not the test API or empty (the local mock).
- `client/tests/front.gd` fails if any of it moves: the constants are the test server's and not the live API, lobby or manifest (read from `godot/net/dm_config.gd`), the allow-list refuses the live
  addresses and lookalikes, every request the flows made stayed on the test server, and a scan of every shipped file finds no address outside `net/dm_config.gd` and no live path anywhere.

**Launch day flips it** (the day `client/` becomes the game, B38/B40): in one commit, set `API_BASE` to `https://muffindevelopment.com/death-muffin/api`, `SITE_BASE` to `https://muffindevelopment.com/death-muffin/`,
`CLIENT_MANIFEST_URL` to `SITE_BASE + "client/manifest.json"` and `LOBBY_URL` to the live lobby (the values in `godot/net/dm_config.gd` that day). The allow-list is written in those constants, so it
follows. Then change `tests/front.gd` to pin the live addresses instead (its `TEST_API` and `LIVE_API` constants and the "never the live API" checks). Until that commit the test fails on any live
address; after it the same test pins the live ones.

## Assets

The client keeps its own copies of the assets it uses, at the same relative paths as under `godot/assets/` (DECISIONS B41). `client/assets.list`
names them, one path or glob per line (relative to `godot/assets/`, `#` comments, `*` inside a folder, `**` across folders, a folder name
copies it whole). A line starting with `@` names art that lives next to the code in `godot/` instead (`@ui/fonts`, `@ui/hud/art`, `@front/art`,
`@world_fx/assets`): its path is relative to `godot/` and it lands at the same path in `client/`. Each rebuild item adds its block to the list;
nothing else is copied.

```
node tools/rebuild/sync-assets.mjs [--dry-run] [--list <file>]     # copy what the list names into client/assets
```

- Idempotent: only missing or changed files are copied. It prints what it added and changed, **flags list lines that match nothing** (exit 1) and
  lists files in `client/assets` that no line names any more (it never deletes; delete them by hand).
- Asset files only. Godot's `*.import` and `*.uid` files of `godot/` are never copied: the client imports with its own settings and commits its
  own `.import` files (and the `*.unwrap_cache` files Godot writes next to models it gives lightmap UV2: commit them, they keep UV2 identical on every machine). A new 3D texture (under `slice/models/`, `slice/art/textures/`, `fx/art/` and the other 3D folders in the tool) gets a seed
  `.import` first (VRAM compressed, mipmaps, normal maps flagged), so even a headless first import is right; `npm run hygiene` checks them like
  the live game's. Models import with lightmap UV2 (`importer_defaults` in `project.godot`); a model that never gets a lightmap (creatures, the
  hero) may set `meshes/light_baking=1` in its `.import`.
- Scenes and resources in `godot/` name assets by path, never by uid, so a client asset's new uid raises no "invalid UID" warning (0 in the
  imports and in `code_load`). If a copied scene ever carries `uid=` references, seed the `.import` of new assets with the live asset's uid here.
- **Licensed flipbook sheets** (`fx/sheets/`) are not in git (`godot/fx/README.md`). A list line under `fx/sheets/` (for example `fx/sheets/hit_flash.png`)
  is read from `$FX_SHEETS` (default `~/death-muffin/private/fx-sheets/`, the source of `tools/godot/fx-sheets-sync.sh`) and copied to
  `client/assets/fx/sheets/`, which the root `.gitignore` keeps out of git; the tool refuses to copy them anywhere git does not ignore.

## Areas

An area is a scene built once, offline, from `godot/data/slice/world.json`: the layout `godot/world/world_builder.gd` builds at start-up today.

```
bash tools/rebuild/build-areas.sh [area id ...]                     # sync assets, import, convert; default graves
godot --headless --path client --script res://tests/area_graves.gd   # the Graves scene equals what world_builder.gd makes from world.json
```

`client/tools/build_area.gd` is the one converter for every area (`--lenient` skips models not synced yet, for a smoke run; the Depths' floors are
generated at runtime and are not converted). Output is deterministic, so regenerating changes nothing unless the data or the converter did:

- `client/areas/<id>.tscn`: groups `Floor`, `Walls`, `Props`, `GatherNodes`, `Decals`, `Water`, `Doors`, `Lights`, `Occluders`, one static `Colliders` body
  on the `world` physics layer (walls, prop and node obstacles, deep ponds; 3 m tall as today), and `Navigation` with a **baked** `NavigationRegion3D`
  for the area, one per door touching it (starts enabled only for the always-open door) and the two `NavigationLink3D` per door. Settings and obstruction
  rules are `world_builder._nav_mesh` / `_all_obstacles`. Gates start closed: each `Doors/<id>/gate/bars` rises when the door opens, and the
  runtime enables the door's region and links and disables `gate/body/collider`, as `set_door_open` does.
- `client/areas/props/<model>.tscn`: one prefab per prop or gathering-node model: the glTF instanced with the height normalisation of `DmModels.analyze`.
  Props up to 1.5 m (the height `world_builder` stops casting shadows at) also get a 70 m visibility range.
- `client/areas/common/ring.png`, `glow.png`: the two decal textures the live game paints at start-up.
- `Lightmap`: the area's `LightmapGI`. Walls, gate stone and floors carry UV2, prop meshes get UV2 on import, everything solid is `gi_mode` static
  and the prop lights are `BAKE_STATIC` (positions, colours and ranges as today), so the bake takes their direct and bounced light; the area's
  ambient (`DmWorldBuilder.set_area`'s colour, same constants) is baked in too, since a lightmapped surface ignores the environment's. When
  `client/areas/<id>.lmbake` exists (a bake from `client/addons/dm_bake/README.md`) the converter points the node at it. Occluders: tall walls (3 m, 4 m long) and large solid
  box props (the mausoleums), shrunk so they never hide what is visible past them.

Not the same as today's runtime, on purpose: props are single instances of a prefab (not one MultiMesh per 12 m cell; MultiMesh cannot take
lightmaps); each floor is one quad (not 12 m tiles, which only limited per-object lights on Compatibility); there is no per-area light switching
(the lights stay on; the bake takes over) and no see-through cutout shader yet (`apply_occlusion`). Not in an area scene (a later world scene
owns them): the dark ground beyond the walls, the environment, fog, moon and rim lights, streaming. A door between two areas is in both scenes
with the same id and place (nodes carry `door_id`); the area loader keeps one copy.

