# godot/next: the rebuild's vertical-slice game scene

`next_game.tscn` / `DmNextGame` is a slim, scene-first replacement for the `DmGame` hub (the current game is untouched). Solo (default) is a
1-player `DmSession` hosted on an `OfflineMultiplayerPeer`; a 2-player session is the same code with another peer (no `if solo` in gameplay).

## Launch
- Game: `godot --path godot -- --next [--class=N]` (offline backend, account `tester`; default path without the flag is unchanged).
- Code: `var g: DmNextGame = load("res://next/next_game.tscn").instantiate(); add_child(g); await g.start(character, api, opts)`.
  opts: `peer` (default Offline), `host` (true; false = join), `offline`, `dressing`, `world` (false = headless client), `waves`, `hud`, `audio`.
- Tests: `godot --headless --path godot --script res://tests/next/run.gd` (picked up by `tools/godot/run-all-tests.sh`).
  Rendered perf + screenshots: `tests/next/render_probe.gd` (see its header).

## Structure
| node | script | job |
|---|---|---|
| Session | `DmSession` | host/join, bodies (MultiplayerSpawner), move intents. Hooks added: `body_factory`, `spawn_origin` |
| World | `next_world.gd` | `DmWorldBuilder` world + `DmWorldDressing`; its per-area navmesh regions (baked at build, ~130 ms) and nav helpers |
| Waves | `spawn/dm_wave_director.gd` | host waves for the Graves, any kind with `res://enemies/<id>.tscn`, packs, elites, metas; MultiplayerSpawner |
| Net | `next_net.gd` | enemy `get/apply_net_state` + hero vitals, 20 Hz, only when peers exist |
| Input | `next_input.gd` | click-to-move, WASD, hotbar seam, hover pick (10 Hz) |
| Camera | `DmCameraRig` | existing rig |
| Hud | `next_hud.gd` | health + resource `DmHudOrb`, area name, death veil |
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
Graves (other areas load but have no spawner), hero VFX decals (hero ring) from `DmGame._dress_hero`, GPU shader warm-up (models and scenes are
preloaded in `start()`; a first-draw shader compile can still hitch once), Depths, bosses, NPCs, gathering.

## Measured (this VPS, shared, noisy)
Load: world build ~1.3 s (navmesh bake ~130 ms of it) + first nav-map sync ~120 ms headless. Headless 25 chasing enemies: ~5-6 ms/frame
(process+physics monitors), vs the current game's combat_perf (12 enemies + 3 thralls) 3.1 ms tick. Rendered (llvmpipe) numbers are software-GL bound.
