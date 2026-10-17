class_name DmDepths
extends Node
## The Catacomb Depths on the combat core (child "Depths" of DmNextGame, host only; solo, DECISIONS.md D5): entering by the Warren's stair, floors, stairs, the chest, the rewards,
## death ends the run, "death takes nothing", the summary. The run rules are DmDepthsRun (pure), the floor's picture / navmesh DmDepthsGround (made at run time, off the main
## thread where it is slow), the dead are bodies of the combat core made by DmWaveDirector.spawn(..., over) with the floor's level (this node counts the ones alive in `_living`
## from the core's spawned / died / removed events, and takes every body of the Depths out of the core with `remove_enemy` when a floor goes), kills and loot go
## through DmSessionRewards (the loot ground follows the depth: `rewards.loot_area_of`), floor / chest rewards through the rewards + progress nodes, the record through DmChronicle.
## The hub's `interacted(it)` (stair, depths_down, depths_up, depths_chest) is the entry point; the floor's own interactables are added to the hub's list while a run is on.
## See client/README.md "The Depths".

signal run_started(depth: int)
signal floor_loaded(depth: int)
signal floor_cleared(depth: int)
signal chest_opened(depth: int)
signal run_ended(why: String, summary: String)    ## why: left, recalled, died, party

const BANNER_MS := 3200
const NEAR_STAIR_TIP := 9.0
const LEAVE_CONFIRM_MS := 5000                    ## the exit asks twice
const FLUSH_S := 30.0
const AGGRO := 36.0                               ## DmSimConsts.DEPTHS_AGGRO
const LEASH := 90.0                               ## the floor is 40 x 36: never leash a hunter off it
const SHADOW_PASS_S := 0.25                       ## the builder's shadow-cell pass starts when its 0.25 s timer runs out: a new floor asks for one at once

var game: DmNextGame
var run: DmDepthsRun
var ground: DmDepthsGround
var chronicle: DmChronicle                        ## the shared one (DmNextChronicle, `game.chron`): kills, floors, chests and the deepest floor
var over := false                                 ## the hero fell: the floor stays up behind the death screen until they rise
var chest_done := false
var rng := RandomNumberGenerator.new()

var _busy := false
var _leave_until := 0
var _its: Array = []                              ## this floor's interactables (also in the hub's list)
var _end_note := ""
var _flush_t := 0.0
var _stair_node: Node3D
var _vfx: Node
var _audio: Node
var _hero_id := 0
var _living := {}                                 ## core id -> true: the Depths' bodies that are not dead (from the core's spawned / died / removed events: the floor's waves and the Risen its dead raise)
var _hud := {"depth": 1, "kills": 0, "need": 0, "open": false, "chest": false}   ## the HUD's readout, rewritten in place
var _map := {}                                    ## the minimap's floor, built once per floor (rooms, doors, stairs, chest) and kept current in place
var _map_chest := {}


func setup(game_: DmNextGame) -> void:
	game = game_
	_hero_id = int(game.character.get("id", 0))
	var visual: bool = game.opts.get("visual", true) and DisplayServer.get_name() != "headless"
	_vfx = get_node_or_null("/root/Vfx") if visual else null
	_audio = get_node_or_null("/root/AudioDirector") if visual and bool(game.opts.get("audio", true)) else null
	DmDepthsRun.generate(1, 1)   # the generator's data is read once here (a worker thread makes the floors later, and only reads it)
	ground = DmDepthsGround.new()
	ground.name = "Ground"
	add_child(ground)
	ground.setup(game)
	game.rewards.loot_area_of = Callable(self, "loot_area")
	game.chapterhouse.interacted.connect(_on_interacted)
	game.hero_died.connect(_on_hero_died)
	game.hero_respawned.connect(_on_hero_respawned)
	game.session.player_joined.connect(_on_player_joined)
	chronicle = game.chron.chronicle
	var warren := game.world.area_node("warren")
	if warren != null:
		var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
		_stair_node = _make_warren_stair(float(s["x"]), float(s["z"]))
		warren.add_child(_stair_node)
	# Nothing runs per frame outside a run: the stair's tip is a timer, and the run's own tick (waves, the exit check, the flush) and the core's events are connected while it lasts.
	set_physics_process(false)
	var tip := Timer.new()
	tip.name = "StairTip"
	tip.wait_time = 0.5
	tip.timeout.connect(_check_near_stair)
	add_child(tip)
	tip.start()


# ---- state ----------------------------------------------------------------------------------------------------------------------

func active() -> bool:
	return run != null


func floor_() -> Variant:
	return run.floor_data if run != null else null


## Why the stair will not take you down right now, or "".
func can_enter() -> String:
	var why := _refusal()
	if why != "":
		return why
	if run != null or _busy:
		return "You are already below."
	return ""


func _refusal() -> String:
	var b: DmHeroBody = game.local_body()
	if b == null or not b.alive:
		return "You are in no state to descend."
	if game.session.get_roster().size() > 1:
		return "The Depths are a solo descent: your party must stay behind."
	if not game.world.has_area("warren"):   # (a test's world with no Warren has no stair, and the core's grid does not cover the Depths there)
		return "There is no stair down here."
	return ""


## The deepest floor this character has reached (0 = never below depth 1): what the stair offers to resume at.
func resume_at() -> int:
	var d := int(floorf(float(chronicle.view()["life"].get("peak.depth", 0.0))))
	return d if d >= 2 else 0


## The loot ground of a kill: the hunting ground whose gear matches the depth (DmSessionRewards.loot_area_of). null = the kill's own area.
func loot_area(area: String) -> Variant:
	return DmDepthsRewards.depth_loot_area(float(run.depth)) if (area == "depths" and run != null) else null


## The HUD's Depths readout (one dictionary, rewritten in place: the HUD reads it and keeps nothing); null outside a run.
func hud_state() -> Variant:
	if run == null:
		return null
	_hud["depth"] = run.depth
	_hud["kills"] = mini(run.kills, int(run.need))
	_hud["need"] = int(run.need)
	_hud["open"] = run.stair_open
	_hud["chest"] = run.floor_data["chest"] != null and not chest_done
	return _hud


## What the minimap draws instead of the whole Depths rectangle (built once per floor; the stair's glow and the chest are kept current in place).
func map_floor() -> Variant:
	if run == null or _map.is_empty():   # (no map yet: the first floor is still baking)
		return null
	_map["down"]["open"] = run.stair_open
	_map["chest"] = null if (_map_chest.is_empty() or chest_done) else _map_chest
	return _map


func _build_map(f: Dictionary) -> void:
	var rooms: Array = []
	for rm in f["rooms"]:
		var rc: Dictionary = rm["rect"]
		rooms.append({"x0": rc["x0"], "z0": rc["z0"], "x1": rc["x1"], "z1": rc["z1"], "active": rm["active"]})
	var doors: Array = []
	for d in f["doors"]:
		doors.append({"x": d["x"], "z": d["z"], "wall": d["wall"]})
	_map = {"rooms": rooms, "doors": doors,
		"down": {"x": f["stairDown"]["x"], "z": f["stairDown"]["z"], "open": false},
		"up": {"x": f["stairUp"]["x"], "z": f["stairUp"]["z"]},
		"chest": null}
	_map_chest = {"x": f["chest"]["x"], "z": f["chest"]["z"]} if f["chest"] != null else {}


func progress_line() -> String:
	if run == null:
		return ""
	var lvl := run.enemy_level(float(game.character.get("level", 1)))
	var extras := DmSimDepthsRules.extra_affixes(float(run.depth))
	return "Level <b>%d</b> dead%s" % [int(lvl), " · elites bear <b>%d</b> affixes" % (extras + 1) if extras > 0 else ""]


## The hover line for each stair, chest and exit (the hub's interact_prompt).
func prompt(it: Dictionary) -> String:
	match String(it["kind"]):
		"stair":
			var why := can_enter()
			if why != "":
				return why
			var resume := resume_at()
			return "Descend into the Catacomb Depths%s" % (" (start at depth 1 or resume at depth %d)" % resume if resume > 0 else "")
		"depths_down":
			if run == null:
				return ""
			return "Descend to depth %d" % (run.depth + 1) if run.stair_open else "The stair is sealed: slay %d more" % run.still_needed()
		"depths_up":
			return "Climb out (ends this run at depth %d)" % (run.depth if run != null else 1)
		"depths_chest":
			return "Open the chest"
	return ""


# ---- entering, descending, leaving ----------------------------------------------------------------------------------------------

func _on_interacted(it: Dictionary) -> void:
	match String(it.get("kind", "")):
		"stair":
			stair_clicked()
		"depths_down":
			descend()
		"depths_up":
			leave()
		"depths_chest":
			open_chest()


## The Warren's stair: with a deeper floor on record offer the choice (game_event depths_stair_offer; the card calls enter_depths(depth)),
## otherwise start a run on depth 1. Returns the depth offered to resume at, or 0 when the run simply began (or could not).
func stair_clicked() -> int:
	var why := can_enter()
	if why != "":
		_toast(why, "err")
		_sfx("error")
		return 0
	var resume := resume_at()
	if resume > 0:
		_event("depths_stair_offer", {"deepest": resume})
		return resume
	enter(1)
	return 0


## Start a run on `depth` (1, or the deepest floor on record). `seed_ < 0` = a fresh random seed. Awaitable: returns once the floor stands.
func enter(depth: int = 1, seed_: int = -1) -> bool:
	var why := can_enter()
	if why != "":
		_toast(why, "err")
		_sfx("error")
		return false
	_busy = true
	if seed_ < 0:
		seed_ = int(randi())
	rng.seed = seed_ ^ 0x7e57
	var made := await _generate(seed_, maxi(1, depth))
	why = _refusal()   # (the hero may have fallen, or a friend joined, while the floor was made)
	if why != "":
		_busy = false
		_toast(why, "err")
		_sfx("error")
		return false
	run = DmDepthsRun.create(seed_, depth, made)
	_listen(true)
	over = false
	_end_note = ""
	_leave_until = 0
	chronicle.add("depths.runs")
	chronicle.max_("peak.depth", float(run.depth))
	run_started.emit(run.depth)
	await _load_floor("You go down")
	_busy = false
	return true


## The stair down was clicked.
func descend() -> bool:
	if run == null or over or _busy:
		return false
	if not run.stair_open:
		_toast("The stair is sealed: slay %d more of the dead." % run.still_needed(), "err")
		_sfx("error")
		return false
	_busy = true
	var made := await _generate(run.seed, run.depth + 1)
	if run == null or over:   # the run ended while the floor was made
		_busy = false
		return false
	run.descend(made)
	chronicle.max_("peak.depth", float(run.peak))
	await _load_floor("You descend")
	_busy = false
	return true


## The exit: asks twice, then ends the run and puts you back at the Warren's stair.
func leave() -> bool:
	if run == null or over or _busy:
		return false
	var now := Time.get_ticks_msec()
	if now > _leave_until:
		_leave_until = now + LEAVE_CONFIRM_MS
		_toast("Climbing out ends this run at depth %d (what you looted is yours). Click again to leave." % run.depth)
		_sfx("click")
		return false
	end("left")
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	_teleport(float(s["x"]), float(s["z"]) + 2.3)
	return true


## The floor of `depth` for a run seed, generated on a worker thread (the generator is pure and only reads data already loaded): the old floor goes on meanwhile. The worker
## computes a Dictionary and touches no node; the main thread takes it once the task has finished (client/README.md "Threads").
func _generate(seed_: int, depth: int) -> Dictionary:
	DmDbWarm.all()   # no dataset may be a first use (a write to DmDb's cache) while the worker reads
	DmSimData.ensure()
	var out := [{}]
	var task := WorkerThreadPool.add_task(func() -> void: out[0] = DmDepthsRun.generate(seed_, depth), false, "depths floor")
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().physics_frame
	WorkerThreadPool.wait_for_task_completion(task)
	DmThreadGuard.assert_main("the Depths floor taken from its worker")
	return out[0]


## Make the current floor and put the hero on it. The navmesh is baked on a worker thread while the old floor (or the Warren) still stands; then, in one frame, the old floor's
## dead, corpses and loot go, the new floor is drawn, the core is given its navmesh and the hero stands at the way in. The navigation server merges the region a few frames
## later (`ground.merged`): the floor counts as loaded once it has.
func _load_floor(verb: String) -> void:
	var f: Dictionary = run.floor_data
	if game.perf != null:
		game.perf.hold()   # a floor is a load: slow frames around it are not a GPU problem (as an area entry)
	await ground.prepare(f)
	if run == null or over:   # the run ended while the floor was baking: an old floor stays up behind the death screen
		return
	_wipe_ground()
	ground.show(f)
	_shadow_cells(f["start"]["x"], f["start"]["z"], SHADOW_PASS_S)   # the new floor's prop cells get the moon-shadow range from the way in, and the old floor's are pruned
	game.world.open_instance("depths", true)
	chest_done = false
	_build_map(f)
	_set_interactables(f)
	_set_stair_glow(false)
	_teleport(float(f["start"]["x"]), float(f["start"]["z"]))
	var b: DmHeroBody = game.local_body()
	if b != null:
		b.yaw = PI
	var lvl := run.enemy_level(float(game.character.get("level", 1)))
	var extras := DmSimDepthsRules.extra_affixes(float(run.depth))
	_event("banner", {"title": "Depth %d" % run.depth, "ms": BANNER_MS,
		"sub": "%s · slay %d · level %d dead%s%s" % [verb, int(run.need), int(lvl), " · elites bear %d affixes" % (extras + 1) if extras > 0 else "", " · a chest waits" if f["chest"] != null else ""]})
	_sfx("gate", float(f["start"]["x"]), float(f["start"]["z"]))
	if _vfx != null:
		_vfx.light_flash(Vector3(float(f["start"]["x"]), 3.0, float(f["start"]["z"])), Color.hex(0xffb347ff), 40.0, 1.2)
	await ground.merged()
	if run == null:   # the run ended while the navigation server merged the floor
		return
	floor_loaded.emit(run.depth)


# ---- the floor: the dead, the quota, the stair, the chest -----------------------------------------------------------------------

## A run's tick (on only while a run is): the waves, the check that the hero is still below, the flush of the record.
func _physics_process(dt: float) -> void:
	var b: DmHeroBody = game.local_body()
	if b == null or run == null:
		return
	if not over and not _busy:
		if game.area_of(game.session.get_my_id()) != "depths":
			end("recalled")   # waystone / recall: the Depths close behind them
			return
		_spawn(dt, b)
	if not _busy:
		_shadow_cells(b.position.x, b.position.z, dt)
	_flush_t += dt
	if _flush_t >= FLUSH_S:
		_flush_t = 0.0
		flush()


## Today's per-frame rule for a floor's tall props (the lights builder's `update_shadow_cells`): a 12 m cell further than the shadow range from the hero stops casting the moon's
## shadow, checked every 0.25 s and a few cells a frame; the builder drops the cells of freed floors from its list as it walks it (nothing else in the rebuild calls it).
func _shadow_cells(x: float, z: float, dt: float) -> void:
	if game.world.builder != null:
		game.world.builder.update_shadow_cells(x, z, dt)


## The Warren's stair says so when the hero is near it (twice a second, in the Warren, outside a run).
func _check_near_stair() -> void:
	var b: DmHeroBody = game.local_body()
	if b == null or run != null or game.area_id != "warren":
		return
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	if DmSimMath.hypot(b.position.x - float(s["x"]), b.position.z - float(s["z"])) < NEAR_STAIR_TIP:
		_event("depths_stair_near", {})


## The run's ears: the core's events of the Depths' bodies and the run's own tick, on while a run lasts.
func _listen(on: bool) -> void:
	var host := game.core_host
	for pair in [[host.enemy_spawned, _on_enemy_spawned], [host.enemy_died, _on_enemy_died], [host.enemy_removed, _on_enemy_removed]]:
		var sig: Signal = pair[0]
		if on and not sig.is_connected(pair[1]):
			sig.connect(pair[1])
		elif not on and sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	set_physics_process(on)
	_flush_t = 0.0


func _spawn(dt: float, b: DmHeroBody) -> void:
	if not b.alive or not game.world.nav_ready():
		return
	var elite_base := float(DmContent.area("depths").get("eliteChance", 0.0)) + float(DmContent.difficulty(game.rewards.difficulty)["eliteBonus"])
	var orders := run.plan_wave(dt, _living.size(), game.director.enemy_total(), [Vector2(b.position.x, b.position.z)], rng, elite_base)
	for o in orders:
		var at: Vector3 = game.world.nav_closest(Vector3(float(o["x"]), 0.0, float(o["z"])))
		game.director.spawn(String(o["def"]), at, [b], bool(o["elite"]), {},
			{"area": "depths", "depth": run.depth, "aggro": AGGRO, "leash": LEASH, "affix_list": _affixes_of(o)})
	if not orders.is_empty():
		game.director.wave_spawned.emit(orders.size())


## An elite's affixes: its roll, the week's Omen forcing the first one (the Tolling: Bell-Tolled) like the sim's spawn_at_breach; distinct.
func _affixes_of(o: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if not bool(o["elite"]):
		return out
	var forced: Variant = game.director.omen.get("affix")
	out.append(String(forced) if forced != null else String(o["affix"]))
	for a in o["extras"]:
		if not out.has(String(a)):
			out.append(String(a))
	return out


## The core's EV_ENEMY_SPAWNED: a body of the Depths stands (the next tick's buffer carries it; waves are planned a gap apart, so the count is current when it is read).
func _on_enemy_spawned(id: int, _def: String, _level: int, _elite: bool, area: String, _affixes: int, _x: float, _z: float, _hp: float) -> void:
	if area == "depths":
		_living[id] = true


## The core's EV_ENEMY_DIED: a body of this floor fell (any death counts, credited to a hero or not).
func _on_enemy_died(id: int, _def: String, _level: int, _elite: bool, area: String, _source: int, _x: float, _z: float) -> void:
	if area != "depths":
		return
	_living.erase(id)
	if run == null or over:
		return
	chronicle.add("kills")
	chronicle.add("kills.depths")
	if run.record_kill():
		var st: Dictionary = run.floor_data["stairDown"]
		_cleared(float(st["x"]), float(st["z"]))


func _on_enemy_removed(id: int) -> void:
	_living.erase(id)


## The floor's quota is met: the stair opens and the floor pays (gold, XP, most of the time an item).
func _cleared(x: float, z: float) -> void:
	_set_stair_glow(true)
	var depth := run.depth
	var level := run.enemy_level(float(game.character.get("level", 1)))
	var m := _member()
	var mult := _reward_mult(m)
	var win: Dictionary = DmDepthsRewards.roll_floor_clear(float(depth), level, Callable(), m.discipline["id"] if m != null else "")
	var items: Array = [] if win["drop"] == null else [win["drop"]]
	var rolled: Dictionary = game.rewards.roll_depths(m, "floor", depth, level) if m != null else {}   # server-decided drops (DECISIONS B20)
	if rolled.get("reward") != null:
		win = {"gold": rolled["reward"]["gold"], "xp": rolled["reward"]["xp"], "materialGold": rolled["reward"]["materialGold"], "drop": null}
	if rolled.has("items"):
		items = rolled["items"]
	var gold := DmMath.js_round(float(win["gold"]) * mult) + int(win["materialGold"])
	var xp := DmMath.js_round(float(win["xp"]) * mult)
	game.progress.psync.report_floor({"depth": depth, "level": level, "clear": true, "chest": false, "mult": mult})
	if m != null:
		m.loot_view.gold(Vector3(x, 0, z + 1.2), gold)
		if not items.is_empty():
			game.rewards.drop_items_for(m, Vector3(x, 0, z + 1.8), items, level, "surge")
	game.progress.grant_xp(float(xp))
	chronicle.add("depths.floors")
	_event("banner", {"title": "The stair opens", "ms": BANNER_MS,
		"sub": "Depth %d cleared · +%d gold%s" % [depth, gold, " · something waits on the steps" if not items.is_empty() else ""]})
	_sfx("gate", x, z)
	if _vfx != null:
		_vfx.emit({"x": x, "y": 0.4, "z": z, "count": 60, "color": 0xffb347, "spread": 1.1, "speed": 1.2, "up": 4, "life": 1.4, "size": 0.3})
		_vfx.light_flash(Vector3(x, 3.0, z), Color.hex(0xffb347ff), 60.0, 1.4)
	game.camera.shake(0.2)
	floor_cleared.emit(depth)


## The chest was clicked.
func open_chest() -> bool:
	if run == null or over or _busy or run.floor_data["chest"] == null or chest_done:
		return false
	chest_done = true
	_sfx("chestOpen")
	_set_chest_glow(true)
	var depth := run.depth
	var level := run.enemy_level(float(game.character.get("level", 1)))
	var m := _member()
	var loot: Dictionary = DmDepthsRewards.roll_chest(float(depth), level, Callable(), m.discipline["id"] if m != null else "")
	var rolled: Dictionary = game.rewards.roll_depths(m, "chest", depth, level) if m != null else {}   # server-decided drops (DECISIONS B20)
	if rolled.get("reward") != null:
		loot = rolled["reward"].duplicate()
	if rolled.has("items"):
		loot["drops"] = rolled["items"]
	var mult := _reward_mult(m)
	var gold := DmMath.js_round(float(loot["gold"]) * mult) + int(loot["materialGold"])
	var c: Dictionary = run.floor_data["chest"]
	var x := float(c["x"])
	var z := float(c["z"])
	game.progress.psync.report_floor({"depth": depth, "level": level, "clear": false, "chest": true, "mult": mult})
	var drops: Array = loot["drops"]
	if m != null:
		m.loot_view.gold(Vector3(x, 0, z + 1.2), gold)
		# Fan the drops out in front of the chest, the gear first.
		for i in drops.size():
			var a := PI * (0.25 + (0.5 * i) / float(maxi(1, drops.size() - 1)))
			game.rewards.drop_items_for(m, Vector3(x + cos(a) * 1.6, 0, z + sin(a) * 1.6 + 0.4), [drops[i]], level, "boss")
	game.progress.grant_xp(float(DmMath.js_round(float(loot["xp"]) * mult)))
	var rune := false
	for d in drops:
		if String(DmLootData.item(String(d["item_id"])).get("type", "")) == "rune":
			rune = true
			break
	chronicle.add("depths.chests")
	_event("banner", {"title": "The chest opens", "ms": BANNER_MS, "sub": "+%d gold · %d finds%s" % [gold, drops.size(), " · a rune among them" if rune else ""]})
	_sfx("levelUp")
	if _vfx != null:
		_vfx.emit({"x": x, "y": 0.8, "z": z, "count": 80, "color": 0xf3d27a, "spread": 0.8, "speed": 1.6, "up": 4.5, "life": 1.5, "size": 0.3})
		_vfx.light_flash(Vector3(x, 2.0, z), Color.hex(0xf3d27aff), 70.0, 1.3)
	game.camera.shake(0.18)
	_set_interactables(run.floor_data)
	chest_opened.emit(depth)
	return true


# ---- death, ending --------------------------------------------------------------------------------------------------------------

## The hero fell: the run is over, but the floor stays up behind the death screen until they rise.
func _on_hero_died(_b: DmHeroBody) -> void:
	if run == null or over:
		return
	over = true
	_end_note = run.summary()
	chronicle.max_("peak.depth", float(run.peak))
	_remove_interactables()
	flush()
	run_ended.emit("died", _end_note)


## The hero rose in the Chapterhouse: the Depths close behind them. (Death takes nothing: gold, bag and gear are as they were.)
func _on_hero_respawned(_b: DmHeroBody) -> void:
	if run == null:
		return
	var note := _end_note
	_close()
	if note != "":
		_toast(note, "good")


func _on_player_joined(_id: int) -> void:
	if run != null and not over and game.session.get_roster().size() > 1:
		_toast("A friend appeared on the descent: a run is solo, so the stair closes behind you.", "err")
		end("party")
		var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
		_teleport(float(s["x"]), float(s["z"]) + 2.3)


## End the run now (left, recalled, party): the record is saved, the floor torn down.
func end(why: String) -> void:
	if run == null:
		return
	var note := run.summary()
	chronicle.max_("peak.depth", float(run.peak))
	flush()
	_close()
	run_ended.emit(why, note)
	if why != "party":
		_toast(note, "good")


func _close() -> void:
	if run == null:
		return
	_wipe_ground()
	_remove_interactables()
	ground.clear()
	game.world.open_instance("depths", false)
	run = null
	_listen(false)
	over = false
	chest_done = false
	_end_note = ""
	_leave_until = 0


## The floor's dead, corpses and loot go with it (every floor is built in the same space). A living body leaves the core without a death or a credit (`remove_enemy`); one
## that fell within the last 4 s is already dying and sinks away by itself.
func _wipe_ground() -> void:
	for id in game.core_host.core.enemy_ids():   # by the core's table, not by what the events said so far: a Risen made this very tick is in it too
		if String(game.core_host.core.enemy_info(id)["area"]) == "depths":
			game.core_host.remove_enemy(id)
	_living.clear()
	game.director.clear_area("depths")   # the Depths make their bodies at once: nothing is queued, this is for a director that had
	var rc: Dictionary = DmContent.area("depths")["rect"]
	var w := float(rc["x1"]) - float(rc["x0"])
	var h := float(rc["z1"]) - float(rc["z0"])
	var mid := Vector3(float(rc["x0"]) + w * 0.5, 0.0, float(rc["z0"]) + h * 0.5)
	for c: DmCoreCorpse in game.corpses.corpses_in_radius(mid, DmSimMath.hypot(w, h) * 0.5 + 2.0, Callable(), "depths"):
		game.corpses.consume(c.id, 1, "expired")
	var m := _member()
	if m != null and m.loot_view != null:
		m.loot_view.clear_within(Rect2(float(rc["x0"]), float(rc["z0"]), w, h))


## Save the chronicle (the record of the deepest floor). Awaitable; DmNextGame.flush_all calls it.
func flush() -> void:
	await game.chron.flush()


# ---- plumbing -------------------------------------------------------------------------------------------------------------------

func _member() -> DmRewardsMember:
	return game.rewards.members.get(_hero_id) if game.rewards != null else null


func _reward_mult(m: DmRewardsMember) -> float:
	return DmAscension.ascension_reward_mult(game.rewards.ascension + (m.self_heat if m != null else 0)) * (m.omen_reward if m != null else 1.0)


## The stair, the way up and the chest of this floor as things to click (the hub's list, area "depths").
func _set_interactables(f: Dictionary) -> void:
	_remove_interactables()
	_its = [
		{"id": "depths_up", "kind": "depths_up", "label": "The Way Up", "x": f["stairUp"]["x"], "z": f["stairUp"]["z"], "area": "depths"},
		{"id": "depths_down", "kind": "depths_down", "label": "The Stair Down", "x": f["stairDown"]["x"], "z": f["stairDown"]["z"], "area": "depths"},
	]
	if f["chest"] != null and not chest_done:
		_its.append({"id": "depths_chest", "kind": "depths_chest", "label": "A Chest", "x": f["chest"]["x"], "z": f["chest"]["z"], "area": "depths"})
	game.chapterhouse.interactables.append_array(_its)


func _remove_interactables() -> void:
	for it in _its:
		game.chapterhouse.interactables.erase(it)
	_its = []


## Put the hero (and his thralls, recalled to his side) at a place, the camera with him; the same sequence as a waystone's jump without its show.
func _teleport(x: float, z: float) -> void:
	var b := game.local_body()
	if b == null:
		return
	b.teleport(Vector3(x, 0.0, z))
	var c := b.get_node_or_null("Rites") as DmRiteCaster
	if c != null and c.thralls() != null:
		c.thralls().recall()
	game.camera.snap(Vector3(x, 0.0, z))


func _set_stair_glow(open: bool) -> void:
	if game.world.builder != null:
		game.world.builder.set_depths_stair_open(open)


func _set_chest_glow(opened: bool) -> void:
	if game.world.builder != null:
		game.world.builder.set_depths_chest_opened(opened)


func _event(id: String, ctx: Dictionary) -> void:
	game.game_event(id, ctx)


func _toast(text: String, kind: String = "") -> void:
	_event("toast", {"text": text, "kind": kind})


func _sfx(id: String, x: float = NAN, z: float = NAN) -> void:
	if _audio != null:
		_audio.play_sfx(id, null if is_nan(x) else Vector2(x, z), 1.0)


## The Warren's StairView: the stairwell (DmStairMesh, the way down) with an ember glow and a light.
func _make_warren_stair(x: float, z: float) -> Node3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.26, 0.18, 0.14)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.4, 0.12)
	mat.emission_energy_multiplier = 0.45
	var root := DmStairMesh.make(false, mat)
	root.name = "WarrenStair"
	root.position = Vector3(x, 0, z)
	var l := OmniLight3D.new()
	l.light_color = Color.hex(0xffb347ff)
	l.omni_range = 10.0
	l.light_energy = 1.2
	l.position.y = 1.4
	root.add_child(l)
	return root
