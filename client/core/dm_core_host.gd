class_name DmCoreHost
extends Node
## The one owner of the combat core (`DmCore`) and of the crowd that draws it (`CrowdView`) in the game scene (DECISIONS B42, native/README.md "Design").
## No node and no script per creature exists anywhere: an enemy or a thrall is a number (its id) in the core's tables, and everything the game layer
## does about one comes from the typed signals below or from the thin queries at the end.
##
## One tick (a `_physics_process` at `process_physics_priority` 100, so after the nodes that move the hero bodies and send the director's spawns:
## the session's `Session` node and `Waves`, priority 0, and before the crowd's own priority 1000):
##   1. every registered hero's position and alive flag go into the core (`set_external`);
##   2. `core.step(dt)`;
##   3. `CrowdView.sync()` reads the core's tables and the damage in the event buffer (without consuming it);
##   4. `core.take_events()` is read ONCE and dispatched in order, one signal per event.
## Per rendered frame `CrowdView._process` draws, interpolated with `Engine.get_physics_interpolation_fraction()`.
## Ids are the core's: enemies, thralls, heroes (externals) and bosses share one counter. A corpse's id and a zone's id are their own numbers.

const PRIORITY := 100
const DEFAULT_DATA := "res://"

# ---- enemies (EV_ENEMY_*)
signal enemy_spawned(id: int, def: String, level: int, elite: bool, area: String, affixes: int, x: float, z: float, max_hp: float)   ## `affixes` is a mask: DmCoreEvents.affix_list
signal enemy_state(id: int, prev: int, next: int)                                              ## DmCoreEvents.State
signal enemy_damaged(id: int, source: int, amount: float, hp: float)
signal enemy_died(id: int, def: String, level: int, elite: bool, area: String, source: int, x: float, z: float)
signal enemy_removed(id: int)                                                                  ## the body is gone, 4 s after it died
signal enemy_attack(id: int, blow: int, aim_x: float, aim_z: float, windup_s: float)           ## a swing began; its blow lands when the wind-up ends
signal telegraph(id: int, tell: int, from_x: float, from_z: float, aim_x: float, aim_z: float, radius: float, seconds: float)
signal cue(id: int, cue_kind: int, x: float, z: float, radius: float)
signal target_hit(id: int, target: int, kind: int, damage: float)                              ## enemy `id` hit external `target` (a hero) with a DmCoreEvents.HIT_KINDS blow
signal zone(id: int, kind: int, source: int, x: float, z: float, radius: float, seconds: float)
signal zone_pulse(id: int)
signal zone_gone(id: int)
signal statuses_cleared(id: int)
signal status_changed(id: int)
signal status_dot(id: int, status: int, source: int, killed: bool, amount: float)
signal status_expired(id: int, status: int)
signal withered_died(id: int, source: int, stacks: float, dps: float)
signal affix_moment(id: int, moment: int, at_x: float, at_z: float, to_x: float, to_z: float, amount: float)   ## DmCoreEvents.AFFIX_MOMENTS
# ---- corpses (their own numbers)
signal corpse_added(id: int, kind: int, def: String, elite: bool, area: String, x: float, z: float, facing: float, scale: float)
signal corpse_consumed(id: int, by: int, reason: String)
signal corpse_gone(id: int, reason: String)
signal corpse_ruptured(id: int, zone_id: int, x: float, z: float, radius: float)
# ---- thralls (EV_THRALL_*)
signal thrall_raised(id: int, kind: String, owner: int, slot: int, empowered: bool, champion: bool, x: float, z: float, yaw: float, max_hp: float)
signal thrall_state(id: int, prev: int, next: int)                                             ## DmCoreEvents.ThrallState
signal thrall_swing(id: int, swing: int, target: int, aim_x: float, aim_z: float, damage: float)
signal thrall_damaged(id: int, source: int, amount: float, hp: float)
signal thrall_died(id: int, reason: String, owner: int, kind: String, source: int, x: float, z: float)
signal thrall_removed(id: int)
signal thrall_status(id: int, target: int, status: int, seconds: float)
signal thrall_bell_heal(x: float, z: float, fraction: float)
signal thrall_plague_pool(x: float, z: float, radius: float, seconds: float, dps: float)
signal thrall_hit_external(id: int, target: int, kind: String, damage: float)                  ## a thrall's blow on a boss: the boss brain takes it
## After a tick's events: the tick's length. For listeners that only care that a tick happened (the HUD's refresh timer, the benchmark).
signal ticked(dt: float)

var core: RefCounted                 ## DmCore
var view: CrowdView                  ## draws the core's creatures
var data_dir := DEFAULT_DATA         ## where data/ (the JSON the core reads) is: this project, or the live game's folder in tests
var enemy_defs: Dictionary = {}      ## ENEMIES of data/content/enemies.json
## Counters for tests and the F3 overlay: events dispatched, ticks stepped.
var ticks := 0
var events_total := 0
## Timing (microseconds, summed over `ticks`) when `measure` is on: the core's step, the crowd's sync, the event dispatch.
var measure := false
var step_us := 0
var sync_us := 0
var dispatch_us := 0

var _heroes: Array[Node3D] = []      ## registered hero bodies, parallel to _hero_ids (heroes are few: a handful, never per creature)
var _hero_ids := PackedInt32Array()
var _dying := 0                      ## bodies that died and are not removed yet: they count toward the global cap, not toward the living
var _names := {}                     ## int -> String, the core's def and area names, fetched once


func _init() -> void:
	process_physics_priority = PRIORITY


## Builds the core and the crowd. `opts`: `data_dir` (res:// : this project's data/), `seed` (default: from the clock, like today's randomize()),
## `nav_map` (RID of the area's navigation map), `bounds` (Rect2: the area, with its door corridors), `view_parent` (Node3D the crowd's nodes go under),
## `baked_dir` / `assets_dir` (where the baked crowd models and their textures are; CrowdView's defaults otherwise), `wander` (idle wander, default on).
func setup(opts: Dictionary) -> void:
	data_dir = String(opts.get("data_dir", DEFAULT_DATA))
	core = ClassDB.instantiate("DmCore")
	core.set_seed(int(opts["seed"]) if opts.has("seed") else randi())
	DmCoreData.load_all(core, data_dir)
	core.set_wander(bool(opts.get("wander", true)))
	if opts.has("nav_map"):
		core.set_nav_map(opts["nav_map"])
	var bounds: Rect2 = opts.get("bounds", Rect2(-60.0, -60.0, 120.0, 120.0))
	core.set_area_bounds(bounds.position, bounds.end)
	enemy_defs = DmCoreData.json(data_dir.path_join("data/content/enemies.json"))["ENEMIES"]
	view = CrowdView.new()
	view.name = "Crowd"
	view.auto_sync = false                 # sync() comes from tick(), between the step and the events
	var parent: Node = opts.get("view_parent", self)
	parent.add_child(view)
	var vopts := {}
	for k in ["baked_dir", "assets_dir", "lod_distances", "reserve"]:
		if opts.has(k):
			vopts[k] = opts[k]
	view.setup(core, enemy_defs, bounds.position, bounds.end, vopts)


# ---- heroes ------------------------------------------------------------------------------------------------------------------------

## Registers a hero body (a Node3D with `alive` and `discipline_id`) as an external of kind 0 and returns its core id. From now on its position and
## alive flag are written every tick before the step. Its thralls look like its discipline's legion.
func register_hero(body: Node3D, radius := 0.4, weight := 1.0) -> int:
	var id := int(core.add_external(0, radius, weight))
	_heroes.append(body)
	_hero_ids.append(id)
	var disc: Variant = body.get("discipline_id")
	if disc is String:
		view.set_owner_legion(id, disc)
	return id


func unregister_hero(body: Node3D) -> void:
	var i := _heroes.find(body)
	if i < 0:
		return
	core.remove_external(_hero_ids[i])
	_heroes.remove_at(i)
	_hero_ids.remove_at(i)


## The hero body behind a core id (the target of an EV_TARGET_HIT), null when it is not registered.
func hero_for(core_id: int) -> Node3D:
	var i := _hero_ids.find(core_id)
	return _heroes[i] if i >= 0 else null


# ---- the tick ------------------------------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	tick(delta)


## One 60 Hz tick (the physics callback calls it; tests may call it themselves).
func tick(delta: float) -> void:
	if core == null:
		return
	for i in _heroes.size():
		var b := _heroes[i]
		core.set_external(_hero_ids[i], Vector2(b.position.x, b.position.z), bool(b.get("alive")))
	if not _heroes.is_empty():
		view.focus = Vector2(_heroes[0].position.x, _heroes[0].position.z)
	var t0 := Time.get_ticks_usec() if measure else 0
	core.step(delta)
	var t1 := Time.get_ticks_usec() if measure else 0
	view.sync()
	var t2 := Time.get_ticks_usec() if measure else 0
	_dispatch(core.take_events())
	ticks += 1
	if measure:
		step_us += t1 - t0
		sync_us += t2 - t1
		dispatch_us += Time.get_ticks_usec() - t2
	ticked.emit(delta)


## Reads the event buffer in order and emits one signal per event. Nothing is allocated per event but the signal's own arguments.
func _dispatch(raw: Array) -> void:
	var ints: PackedInt32Array = raw[0]
	var floats: PackedFloat32Array = raw[1]
	var n := ints.size()
	var i := 0
	var f := 0
	while i < n:
		var type := ints[i]
		var id := ints[i + 1]
		var ni := ints[i + 2]
		var nf := ints[i + 3]
		var b := i + 4                       # the event's first int
		match type:
			DmCoreEvents.ENEMY_SPAWNED:
				enemy_spawned.emit(id, _def(ints[b]), ints[b + 1], ints[b + 2] != 0, _area(ints[b + 3]), ints[b + 4], floats[f], floats[f + 1], floats[f + 2])
			DmCoreEvents.ENEMY_STATE:
				enemy_state.emit(id, ints[b], ints[b + 1])
			DmCoreEvents.ENEMY_DAMAGED:
				enemy_damaged.emit(id, ints[b], floats[f], floats[f + 1])
			DmCoreEvents.ENEMY_DIED:
				_dying += 1
				enemy_died.emit(id, _def(ints[b]), ints[b + 1], ints[b + 2] != 0, _area(ints[b + 3]), ints[b + 4], floats[f], floats[f + 1])
			DmCoreEvents.ENEMY_REMOVED:
				_dying -= 1
				enemy_removed.emit(id)
			DmCoreEvents.ENEMY_ATTACK:
				enemy_attack.emit(id, ints[b], floats[f], floats[f + 1], floats[f + 2])
			DmCoreEvents.TELEGRAPH:
				telegraph.emit(id, ints[b], floats[f], floats[f + 1], floats[f + 2], floats[f + 3], floats[f + 4], floats[f + 5])
			DmCoreEvents.CUE:
				cue.emit(id, ints[b], floats[f], floats[f + 1], floats[f + 2])
			DmCoreEvents.TARGET_HIT:
				target_hit.emit(id, ints[b], ints[b + 1], floats[f])
			DmCoreEvents.ZONE:
				zone.emit(id, ints[b], ints[b + 1], floats[f], floats[f + 1], floats[f + 2], floats[f + 3])
			DmCoreEvents.ZONE_PULSE:
				zone_pulse.emit(id)
			DmCoreEvents.ZONE_GONE:
				zone_gone.emit(id)
			DmCoreEvents.STATUSES_CLEARED:
				statuses_cleared.emit(id)
			DmCoreEvents.STATUS_CHANGED:
				status_changed.emit(id)
			DmCoreEvents.STATUS_DOT:
				status_dot.emit(id, ints[b], ints[b + 1], ints[b + 2] != 0, floats[f])
			DmCoreEvents.STATUS_EXPIRED:
				status_expired.emit(id, ints[b])
			DmCoreEvents.WITHERED_DIED:
				withered_died.emit(id, ints[b], floats[f], floats[f + 1])
			DmCoreEvents.CORPSE_ADDED:
				corpse_added.emit(id, ints[b], _def(ints[b + 1]), ints[b + 2] != 0, _area(ints[b + 3]), floats[f], floats[f + 1], floats[f + 2], floats[f + 3])
			DmCoreEvents.CORPSE_CONSUMED:
				corpse_consumed.emit(id, ints[b], core.reason_name(ints[b + 1]))
			DmCoreEvents.CORPSE_GONE:
				corpse_gone.emit(id, core.reason_name(ints[b]))
			DmCoreEvents.CORPSE_RUPTURED:
				corpse_ruptured.emit(id, ints[b], floats[f], floats[f + 1], floats[f + 2])
			DmCoreEvents.THRALL_RAISED:
				thrall_raised.emit(id, core.thrall_kind_name(ints[b]), ints[b + 1], ints[b + 2], ints[b + 3] != 0, ints[b + 4] != 0, floats[f], floats[f + 1], floats[f + 2], floats[f + 3])
			DmCoreEvents.THRALL_STATE:
				thrall_state.emit(id, ints[b], ints[b + 1])
			DmCoreEvents.THRALL_SWING:
				thrall_swing.emit(id, ints[b], ints[b + 1], floats[f], floats[f + 1], floats[f + 2])
			DmCoreEvents.THRALL_DAMAGED:
				thrall_damaged.emit(id, ints[b], floats[f], floats[f + 1])
			DmCoreEvents.THRALL_DIED:
				thrall_died.emit(id, core.death_reason_name(ints[b]), ints[b + 1], core.thrall_kind_name(ints[b + 2]), ints[b + 3], floats[f], floats[f + 1])
			DmCoreEvents.THRALL_REMOVED:
				thrall_removed.emit(id)
			DmCoreEvents.THRALL_STATUS:
				thrall_status.emit(id, ints[b], ints[b + 1], floats[f])
			DmCoreEvents.THRALL_BELL_HEAL:
				thrall_bell_heal.emit(floats[f], floats[f + 1], floats[f + 2])
			DmCoreEvents.THRALL_PLAGUE_POOL:
				thrall_plague_pool.emit(floats[f], floats[f + 1], floats[f + 2], floats[f + 3], floats[f + 4])
			DmCoreEvents.THRALL_HIT_EXTERNAL:
				thrall_hit_external.emit(id, ints[b], core.thrall_kind_name(ints[b + 1]), floats[f])
			DmCoreEvents.AFFIX_MOMENT:
				affix_moment.emit(id, ints[b], floats[f], floats[f + 1], floats[f + 2], floats[f + 3], floats[f + 4])
		i = b + ni
		f += nf
		events_total += 1


## The def's or area's name for the core's number, fetched once.
func _def(n: int) -> String:
	if n < 0:
		return "risen"                       # a corpse of an extra "risen" body (the core's -1)
	var key := n
	if not _names.has(key):
		_names[key] = core.def_name(n)
	return _names[key]


func _area(n: int) -> String:
	var key := -1 - n                        # areas and defs are separate numberings: area keys are negative
	if not _names.has(key):
		_names[key] = core.area_name(n)
	return _names[key]


# ---- queries the ported code needs (Vector3 on the ground plane <-> the core's Vector2; the core's API stays the source of truth) ----------

## Living enemies whose edge is within `r` of `pos` (flat), in spawn order: ids.
func enemies_in_radius(pos: Vector3, r: float) -> PackedInt32Array:
	return core.enemies_in_radius(Vector2(pos.x, pos.z), r)


## An enemy's record (empty when it is gone). Allocates a Dictionary: for casts, the HUD and tests, not for every creature every tick.
func enemy_info(id: int) -> Dictionary:
	return core.enemy_info(id)


## True while the enemy exists and is not dead.
func enemy_alive(id: int) -> bool:
	var info: Dictionary = core.enemy_info(id)
	return not info.is_empty() and int(info["state"]) != DmCoreEvents.State.DEAD


## Where the enemy stands (the sim position, not the drawn one); Vector3.INF when it is gone.
func enemy_position(id: int) -> Vector3:
	var info: Dictionary = core.enemy_info(id)
	if info.is_empty():
		return Vector3.INF
	var p: Vector2 = info["pos"]
	return Vector3(p.x, 0.0, p.y)


func enemy_radius(id: int) -> float:
	var info: Dictionary = core.enemy_info(id)
	return float(info["radius"]) if not info.is_empty() else 0.0


## Enemy damage from a cast or a test: a kill resolves inside the call (native/README.md "Design"). {dealt, killed}.
func damage(id: int, amount: float, source: int, allow_stagger := true) -> Dictionary:
	return core.damage(id, amount, source, allow_stagger)


## DmStatusSet.apply on a core body (enemy or thrall): the only way to put a status on one. Never call DmStatusSet on an enemy or thrall.
func apply_status(id: int, status: String, source: int, stacks := 1.0, duration := -1.0, params := {}) -> void:
	core.apply_status(id, status, source, stacks, duration, params)


## The director's spawn: the core makes the body at once, the event comes with the next tick's buffer.
func spawn_enemy(def: String, pos: Vector3, level: int, hp_mult: float, damage_mult: float, elite: bool, area: String, rising: bool, affixes := PackedStringArray()) -> int:
	return int(core.spawn_enemy(def, Vector2(pos.x, pos.z), level, hp_mult, damage_mult, elite, area, rising, affixes))


## Bodies in the core's enemy table, the dead ones included until they are removed 4 s after (the global cap counts them: DmSimData.GLOBAL_ENEMY_CAP).
func enemy_total() -> int:
	return int(core.enemy_count())


## Bodies that are not dead.
func alive_count() -> int:
	return int(core.enemy_count()) - _dying


func thrall_count(owner_id: int = 0) -> int:
	return int(core.thrall_count(owner_id))
