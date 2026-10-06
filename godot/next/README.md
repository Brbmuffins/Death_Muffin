# godot/next: the rebuild's vertical-slice game scene

`next_game.tscn` / `DmNextGame` is a slim, scene-first replacement for the `DmGame` hub (the current game is untouched). Solo (default) is a
1-player `DmSession` hosted on an `OfflineMultiplayerPeer`; a 2-player session is the same code with another peer (no `if solo` in gameplay).

## Launch
- Game: `godot --path godot -- --next` boots through the normal front screens (login / offline entry / discipline select / log out) into DmNextGame behind the key-art loading screen (`--online` = VPS backend, default offline = local backend); `-- --next --class=N` skips the front (account `tester`). `DmMain.USE_NEXT` (main.gd) flips the default to the rebuild (D7); `-- --old` forces DmGame. Test: `tests/next_front/run.gd` (incl. 3 enter/leave cycles: +0 nodes, ~+1.5 MB static).
- Code: `var g: DmNextGame = load("res://next/next_game.tscn").instantiate(); add_child(g); await g.start(character, api, opts)`.
  opts: `peer` (default Offline), `host` (true; false = join), `offline`, `dressing`, `world` (false = headless client), `waves`, `hud`, `audio`.
- Tests: `godot --headless --path godot --script res://tests/next/run.gd` (picked up by `tools/godot/run-all-tests.sh`).
  Rendered perf + screenshots: `tests/next/render_probe.gd` (see its header).

## Structure
| node | script | job |
|---|---|---|
| Session | `DmSession` | host/join, bodies (MultiplayerSpawner), move intents. Hooks added: `body_factory`, `spawn_origin` |
| World | `next_world.gd` | `DmWorldBuilder` world + `DmWorldDressing`; its per-area navmesh regions (baked at build, ~130 ms) and nav helpers |
| Waves | `spawn/dm_wave_director.gd` | host waves for the Graves, any kind with `res://enemies/<id>.tscn`, packs, elites, metas; MultiplayerSpawner. `spawn(def, pos, heroes, elite, mult{level,hp,dmg}) -> DmEnemy`; answers the acolyte's `unbind_rise` (+ `adopt`) and the deacon's `raised` with a `risen` scaled like its raiser |
| Net | `next_net.gd` | enemy `get/apply_net_state` + hero vitals, 20 Hz, only when peers exist |
| Input | `next_input.gd` | click-to-move, WASD, hotbar seam, hover pick (10 Hz) |
| Camera | `DmCameraRig` | existing rig |
| Feel | `feel/dm_combat_input.gd` (+ `rites/dm_rite_gestures.gd`, `hitstopper`, rune sockets) | attack-target chase, hold repeat, queued casts, Shift, held keys, cast gestures, hitstop, runes (`feel/README.md`) |
| Progress | `progress/dm_next_progress.gd` | host: DmProgression + DmProgressSync persistence, upgrades -> rites / waves, level-ups, milestones, belt (`progress/README.md`) |
| Areas | `areas/dm_area_flow.gd`, `areas/dm_grave_surge.gd` | every area live: entry banners + Codex, the director follows the hero's area (rosters, 1.3x first wave, processions), Grave Surges; `areas/README.md` |
| Gathering | `gathering/dm_next_gather.gd` | nodes, gather loop (host), skills, AFK, node replication (`gathering/README.md`; test `tests/next_gathering/run.gd`) |
| Hud | `next_hud.gd` | health + resource `DmHudOrb`, area name, death veil |
| Acre | `gathering/dm_next_acre.gd` | host with the HUD: visible Grave Laborers (`DmLaborerViews`), labor / garden / contract notices and panel results (`DmGameLabor`), the first-hour guidance feeds (skills, trophies, labor, contracts) (`gathering/README.md`; test `tests/next_acre_guide/run.gd`) |
| Meta | `meta/dm_next_meta.gd` | host: difficulty (Settings), the sworn world vows, the weekly Omen, Soul Harvest, the Kill Chain, Bonded Dead; `sync()` pushes them to the director, bosses, corpses and rewards (`meta/README.md`) |
| Perf | `perf/dm_next_perf.gd`, `perf/dm_next_warmup.gd` | `DmNextPerf`: settings `graphics` / `fps` / `auto_res` applied live (governor on `scaling_3d_scale`, held on area entry). `DmNextWarmup.run(game)` at the end of `start()` (real renderer, or `opts.warmup`): GPU warm-up of every body / effect / area lighting under a cover (`perf/README.md`) |
| Look | `hero/dm_hero_look.gd` | every peer: worn gear, cape, pet, hero ring, replicated look descriptor (`hero/README.md`; test `tests/next_hero_look/run.gd`) |
| Chapterhouse | `chapterhouse/dm_chapterhouse.gd` | NPCs (`DmHubNpcs`), stations, waystone travel / recall (T), seals + doors, interactable hover / click / prompts; emits `npc_interact` / `station_interact` (forwarded by `DmNextUiHost`) and `interacted(it)` for boss altars / stairs (bosses + depths tracks hook it). Tick 10 Hz, NPC refresh 5 Hz, per-frame animation only for NPCs near you. Test `tests/chapterhouse/run.gd` |
| Depths | `depths/dm_depths.gd` | the procedural descent (solo): Warren stair -> floors, quota, stairs, chests, rewards, death ends the run, chronicle (`depths/README.md`). Test `tests/next_depths/run.gd` |
Players are `hero/dm_hero_body.gd` (`DmHeroBody`, a `DmSessionBody`): `DmAvatar` model for the discipline, `DmPlayerRules` vitals,
navmesh-clamped mover (walls slide), collider on the player layer, group `dm_target`, `take_damage(amount, source)`, death -> respawn in the
Chapterhouse after 4 s. Audio/music/footsteps: the existing `AudioDirector` + `DmAudioHooks` (`DmNextGame` exposes `ready_/area_id/player/avatar/builder`).

## Seams (exact signatures, all on `DmNextGame`)
Rites (`DmRiteCaster`, `next/rites/`): attached as `Rites` to every body on every peer via `attach_caster(body)` (the host delays a joiner's by 0.8 s).
`DmNextGame` is its `DmRiteWorld`:
- `enemies_in_radius(pos: Vector3, r: float) -> Array[DmEnemy]` (living, flat, measured to the enemy's edge)
- `enemy_by_id(id: int) -> DmEnemy`, `enemy_id(enemy: Node) -> int`
- `aim_point() -> Vector3`, `aim_target_id() -> int` (local cursor), `rite_build(peer_id: int) -> Dictionary`
- Input: runtime InputMap actions (LMB is handled by the click handler, not `rite_primary`; keys 1-4 / RMB reach the caster through `DmRiteHotbar.wire(self)`, `next/rites/dm_rite_hotbar.gd`), plus `dm_primary`, `dm_secondary` (RMB), `dm_hotbar_1..4`, `dm_move_*`;
  signal `input.hotbar(slot: int, aim: Vector3, enemy_id: int)` (0 = LMB, 1-4, 5 = RMB) for UI/other casters.
Rewards (`DmSessionRewards`, host only): created in `start()` with one `DmRewardsMember` per player (`_on_player_joined` adds joiners with no api yet).
- `signal enemy_spawned(enemy: DmEnemy)` (every peer, once in tree); enemy metas `dm_id`, `dm_level`, `dm_elite`, `dm_area`
- `roster() -> Array` of `{peer_id, name, discipline, character_id, body}` (remote character_id is 0 until the handshake carries it)
- `body_of(peer_id) -> DmHeroBody`, `body_position(peer_id) -> Vector3`, `area_of(peer_id) -> String`, `area_id`
- `api` (DmApi online / offline backend) and `is_offline`

## Needed in project.godot (not edited here)
Nothing required: input actions are registered at runtime by `DmNextInput.ensure_actions()`. Physics layer names already exist (world/player/enemy).

## Stubbed / left
Hotbar UI and DmGameUi, loot view for non-host peers, remote members' real characters (join handshake), area transitions beyond the Chapterhouse and
Graves (done: `areas/README.md`), bosses (the altars emit `Chapterhouse.interacted`), gathering (done: `gathering/README.md`). Hub gaps: travel/recall teleport on the host only; the Acre/Wing stations open but gold/XP/progress persistence to the backend is the progression track's.

## Measured (this VPS, shared, noisy)
Load: world build ~1.3 s (navmesh bake ~130 ms of it) + first nav-map sync ~120 ms headless. Headless 25 chasing enemies: ~5-6 ms/frame
(process+physics monitors), vs the current game's combat_perf (12 enemies + 3 thralls) 3.1 ms tick. Rendered (llvmpipe) numbers are software-GL bound.
