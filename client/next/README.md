# client/next: DmNextGame, the game scene

`next_game.tscn` / `DmNextGame` is the one in-world game scene (entry from `client/main/main.gd` through the front flow). It composes child nodes and
owns little logic. Solo is a 1-player `DmSession` hosted on an `OfflineMultiplayerPeer`; a party is the same code with more peers
(no `if solo` in gameplay). It runs on the combat core: enemies, thralls, corpses and their statuses are the core's (native/README.md), drawn by the crowd
(client/crowd/README.md), and no node and no script exists per creature: an enemy is an id. How the scene is put together, with the dev entry and its controls:
client/README.md "The game scene and the dev entry". One README per system folder below; `client/next/look/` (`DmCompatAlbedo`, the area converter's tint table) is the client's own and is
explained in client/README.md "The look against today's game".

## Launch
- Players: the launcher starts the game; `DmMain` runs the front flow (`client/front/`) then `DmNextGame`. Launch arguments and the dev entry: client/README.md.
- Code: `var g: DmNextGame = load("res://next/next_game.tscn").instantiate(); add_child(g); await g.start(character, api, opts)`.
  opts: `hud` (true = the real HUD and panels, false = none, the default for a bare scene), `waves`, `areas` (the area ids to load, default every one), `audio`, `visual`, `warmup`, `persist`,
  `settings`, `name`, `slots` and `local` (the character's bag rows and progression from the server), `peer` / `host` / `lobby` / `join` (a party guest), `seed`, `data_dir` and the crowd's cost options
  (`baked_dir`, `assets_dir`, `lod_distances`, `reserve`, `cull`, `anim_lod`, `thrall_shadows`).
- Test: `client/tests/game_scene.gd` (60 s of an offline run in the Graves: the director, the event signals, no node per creature); each system below has its own suite (client/README.md "Set up and test").

## Structure
| node | script | job |
|---|---|---|
| Session | `DmSession` (`client/session/`) | host/join, bodies (MultiplayerSpawner), move intents. Hooks: `body_factory`, `spawn_origin` |
| World | `next_world.gd` | loads the area scenes (`client/areas/<id>.tscn`), their navigation, the lights-only `DmWorldBuilder` and the world dressing; `area_at`, seals and gates, the core's copy of the navmesh |
| Core | `client/core/dm_core_host.gd` (`DmCoreHost`) | the one owner of the combat core and the crowd: the 60 Hz tick, the core's events as typed signals, the queries (client/README.md "The game scene and the dev entry") |
| Waves | `spawn/dm_wave_director.gd` | host waves spawned through the core (`spawn/README.md`) |
| Net | `next_net.gd` | the core's snapshot, reliable batches and baseline, hero vitals, 20 Hz, only when peers exist (client/README.md "Co-op on the core") |
| Input | `next_input.gd` | click-to-move, WASD, hotbar seam, hover pick through the core |
| Camera | `DmCameraRig` | existing rig |
| EnemyFx | `enemy_fx/dm_enemy_fx.gd` | the core's telegraphs, strikes, deaths, zones and affix moments as effects (`enemy_fx/README.md`) |
| Rites | `rites/dm_rite_caster.gd` | a `Rites` node on every hero body; `DmNextGame` is its `DmRiteWorld` (`rites/README.md`) |
| Feel | `feel/dm_combat_input.gd`, `feel/dm_next_auto.gd` | attack-target chase, hold repeat, queued casts, Shift, Easy auto combat (`feel/README.md`) |
| Bosses, BossMeta | `bosses/dm_boss_host.gd`, `bosses/dm_boss_meta.gd` | the seven bosses and the Covenant Seal's altar choice (`bosses/README.md`) |
| Rewards, Loot | `rewards/dm_session_rewards.gd`, `rewards/dm_next_loot.gd` | host: kill credit, the backend's party session, loot rolls; this player's drops and bag (`rewards/README.md`) |
| Progress, Chronicle, Codex | `progress/dm_next_progress.gd` and its siblings | host: levels, upgrade tiers, the belt, saves, the Chronicle and first-kill trophies, the Codex's journal (`progress/README.md`) |
| Meta, Milestones | `meta/dm_next_meta.gd`, `areas/dm_wave_milestones.gd` | host: difficulty, the Omen, Soul Harvest, the Kill Chain; the Wave Speed milestones' banners and the Nightfall light (`meta/README.md`, `areas/README.md`) |
| Areas | `areas/dm_area_flow.gd`, `areas/dm_grave_surge.gd` | entry banners, Codex facts, processions; the Grave Surge's banner and crypt (host), the surge itself is the director's (`areas/README.md`) |
| Gather, Acre | `gathering/dm_next_gather.gd`, `gathering/dm_next_acre.gd` | nodes, the gather loop (host), skills, AFK, node replication; host with the HUD: the Grave Laborers, labor, garden and contract notices (`gathering/README.md`) |
| UiHost, Ui | `hud/dm_next_ui_host.gd`, `DmGameUi` | the real HUD and panels on the core (`hud/README.md`, `client/ui/hud/README.md`) |
| Perf | `perf/dm_next_perf.gd`, `perf/dm_next_warmup.gd` | `DmNextPerf`: settings `graphics` / `fps` / `auto_res` applied live. `DmNextWarmup.run(game)` at the end of `start()`: the first-use warm-up under a cover (`perf/README.md`) |
| Look | `hero/dm_hero_look.gd` | every peer: worn gear, cape, pet, hero ring, replicated look descriptor (`hero/README.md`) |
| Party, Friends, Joiner | `party/dm_next_party.gd`, `party/dm_next_friends.gd`, `party/dm_next_joiner.gd` | the lobby link, hosting a running solo session / joining one, party chat, a joiner's own backend session, XP and loot (`party/README.md`) |
| Chapterhouse | `chapterhouse/dm_chapterhouse.gd` | NPCs (`DmHubNpcs`), stations, waystone travel / recall (T), seals + doors, interactable hover / click / prompts (`chapterhouse/README.md`) |
| Depths | `depths/dm_depths.gd` | the procedural descent (solo): Warren stair -> floors, quota, stairs, chests, rewards, death ends the run (`depths/README.md`) |
| AudioHooks | `client/main/audio_hooks.gd` | the listener, the area bed and score, footsteps, the gate sound (client/audio/README.md) |
Players are `hero/dm_hero_body.gd` (`DmHeroBody`, a `DmSessionBody`): `DmAvatar` model for the discipline, `DmPlayerRules` vitals, navmesh-clamped mover (walls slide), group `dm_target`,
`take_damage(amount, source)` where `source` is the core's id of the enemy or boss, death -> respawn in the Chapterhouse after 4 s. The hero has no collider: he is an external entity of the core (a circle the core pushes bodies out of).
Audio/music/footsteps: `AudioDirector` + `DmAudioHooks` (`DmNextGame` exposes `ready_/area_id/player/avatar/builder`; `builder` is null: the area is a scene).

## Physics interpolation
`physics/common/physics_interpolation` is on (`client/project.godot`), so bodies simulated at 60 Hz draw smoothly at any display rate. It is opt-in:
`DmMain` turns the whole tree OFF, and only what is moved in `_physics_process` turns itself ON: the host's `DmSessionBody` (set by `simulated`) and a `DmBoss` that has authority.
Puppets, remote bodies (snapshot-eased in `_process`) and `DmCameraRig` stay OFF. The core's creatures are not nodes: `CrowdView._process` draws them with `Engine.get_physics_interpolation_fraction()`.
- Anything that follows a body from `_process` (camera, avatar, pets, follow decals and shot targets) reads the drawn position:
  `DmSessionBody.visual_position()` / `node.get_global_transform_interpolated().origin`, never `position`.
- Every instant move calls `reset_physics_interpolation()` after the write (teleports, respawn, Grave/Veil Step fallbacks, boss relocation > `DmBoss.JUMP_M`); spawns reset in `_ready` / `_enter_tree`.
  A reset takes effect when the tick ends.
- Visual children moved in `_process` under an interpolated body (the hover bob on `$Visual`) are sampled once per tick, which is invisible for a bob; do not add larger motion there.
- Not covered in the client: smoothness between ticks, no smear after a teleport, which nodes interpolate (the old game's interpolation suite).

## Seams (all on `DmNextGame`)
Rites (`DmRiteCaster`, `rites/`): attached as `Rites` to every body on every peer via `attach_caster(body)` (the host delays a joiner's by 0.8 s). `DmNextGame` is its `DmRiteWorld`:
- `enemies_in_radius(pos: Vector3, r: float) -> PackedInt32Array` (living, flat, measured to the enemy's edge, spawn order), `enemy_position(id) -> Vector3` (`Vector3.INF` when gone), `enemy_alive(id) -> bool`
- `aim_point() -> Vector3`, `aim_target_id() -> int` (local cursor), `rite_build(peer_id: int) -> Dictionary`
- Input: runtime InputMap actions (`DmNextInput.ensure_actions()`: LMB is handled by the click handler, not `rite_primary`; keys 1-4 / RMB reach the caster through `DmRiteHotbar.wire(self)`, `rites/dm_rite_hotbar.gd`, when there is no full HUD), plus `dm_primary`, `dm_secondary` (RMB), `dm_hotbar_1..6`, `dm_move_*`;
  signal `input.hotbar(slot: int, aim: Vector3, enemy_id: int)` (0 = LMB, 1-4, 5 = RMB, 6 = R) for UI/other casters.
Rewards (`DmSessionRewards`, host only): created in `_start_value`; the host's member at once, a joiner's (`remote`, no api: its own client rolls and saves) when its profile arrives (`DmNextParty`).
- `signal enemy_spawned(id: int)` (every peer, once per body the core made); `signal kill_credited(enemy_id, def, level, elite, area, killer_peer, x, z)` (host, once per kill); `rite_hit` (a rite's or a Withered DoT's blow)
- `roster() -> Array` of `{peer_id, name, discipline, character_id, body}` (a remote body's character_id is its profile's, 0 before it arrives)
- `body_of(peer_id) -> DmHeroBody`, `body_position(peer_id) -> Vector3`, `area_of(peer_id) -> String`, `area_id`
- `api` (DmApi online / offline backend) and `is_offline`
