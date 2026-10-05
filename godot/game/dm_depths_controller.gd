class_name DmDepthsController
extends RefCounted
## Port of src/scenes/DepthsController.ts: the Catacomb Depths as the scene sees them. Entering by the Warren's stair, the floor's picture, its
## stairs and chest as things you click, the rewards, the readout and ending the run. The rules live in the sim (start_depths / descend_depths /
## end_depths), DmDepthsFloor and DmDepthsRewards; this wires them to the game host (`game`, a DmGame).
##
## UI callbacks (game-ui track): stair_clicked() emits game_event "depths_stair_prompt" {resume: <deepest depth>} when a deeper floor is on
## record and no run is on. The two-button card calls `game.depths.enter(1)` ("Start at depth 1") or `game.depths.enter(resume)`
## ("Resume at deepest"). Nothing else needs to be called by the UI.

const DEPTHS_BANNER_MS := 3200
const MIN_LEVEL := 12
const NEAR_STAIR_TIP := 9.0
## The exit asks twice (a stray click beside the way in must not end a run).
const LEAVE_CONFIRM_MS := 5000.0

var g
var _chest_opened := false
var _leave_armed_until := 0.0
var _last_stair_open := false
var _over := false
var _end_note: Variant = null
var _now := 0.0
var _near_t := 0.0
var _disposed := false
var _stair_node: Node3D = null


func _init(game) -> void:
	g = game
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	g.nav.add_obstacle(DmNavObstacle.circle(float(s["x"]), float(s["z"]), 0.9))
	if g.visual and g.world_root != null:
		_stair_node = _make_warren_stair(float(s["x"]), float(s["z"]))
		g.world_root.add_child(_stair_node)


## Stand-in for StairView('warren'): a worn disc with an ember glow and a light.
func _make_warren_stair(x: float, z: float) -> Node3D:
	var root := Node3D.new()
	root.name = "WarrenStair"
	root.position = Vector3(x, 0, z)
	var cm := CylinderMesh.new()
	cm.top_radius = 0.9
	cm.bottom_radius = 0.9
	cm.height = 0.12
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.26, 0.18, 0.14)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.4, 0.12)
	mat.emission_energy_multiplier = 0.45
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.material_override = mat
	mi.position.y = 0.06
	root.add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color.hex(0xffb347ff)
	l.omni_range = 10.0
	l.light_energy = 1.2
	l.position.y = 1.4
	root.add_child(l)
	return root


# --- State -----------------------------------------------------------------------------------------------------------------------

func run() -> Variant:
	return g.sim.depths


func active() -> bool:
	return g.sim.depths != null


func floor_() -> Variant:
	return g.nav.depths_floor()


## Why the stair will not take you down right now, or "" if it will.
func can_enter() -> String:
	return "" if g.player.alive else "You are in no state to descend."


## The deepest floor this character has reached (0 = never below depth 1): what the stair offers to resume at.
func resume_at() -> int:
	var d := int(floorf(float(g.chronicle.view()["life"].get("peak.depth", 0.0))))
	return d if d >= 2 else 0


## The hover line for each stair, chest and exit.
func prompt(it: Dictionary) -> String:
	var r: Variant = run()
	match String(it["kind"]):
		"stair":
			var why := can_enter()
			if why != "":
				return why
			var resume := resume_at()
			var choose := " (start at depth 1 or resume at depth %d)" % resume if resume > 0 else ""
			return "Descend into the Catacomb Depths%s (you step out of your party until the run ends)" % choose if _in_party() else "Descend into the Catacomb Depths%s" % choose
		"depths_down":
			if r == null:
				return ""
			if bool(r["stairOpen"]):
				return "Descend to depth %d" % (int(r["depth"]) + 1)
			return "The stair is sealed: slay %d more" % int(maxf(0.0, float(r["need"]) - float(r["kills"])))
		"depths_up":
			return "Climb out (ends this run at depth %d)" % (int(r["depth"]) if r != null else 1)
		"depths_chest":
			return "Open the chest"
	return ""


## The stair, the way up and the chest of this floor as things to click.
func interactables() -> Array:
	var f: Variant = floor_()
	if f == null or run() == null or _over:
		return []
	var out: Array = [
		{"id": "depths_up", "kind": "depths_up", "label": "The Way Up", "x": f["stairUp"]["x"], "z": f["stairUp"]["z"]},
		{"id": "depths_down", "kind": "depths_down", "label": "The Stair Down", "x": f["stairDown"]["x"], "z": f["stairDown"]["z"]},
	]
	if f["chest"] != null and not _chest_opened:
		out.append({"id": "depths_chest", "kind": "depths_chest", "label": "A Chest", "x": f["chest"]["x"], "z": f["chest"]["z"]})
	return out


func hud_state() -> Variant:
	var r: Variant = run()
	if r == null:
		return null
	var f: Variant = floor_()
	return {"depth": int(r["depth"]), "kills": mini(int(r["kills"]), int(r["need"])), "need": int(r["need"]), "open": bool(r["stairOpen"]),
		"chest": f != null and f["chest"] != null and not _chest_opened}


## What the minimap draws instead of the whole Depths rectangle.
func map_floor() -> Variant:
	var f: Variant = floor_()
	var r: Variant = run()
	if f == null or r == null:
		return null
	var rooms: Array = []
	for rm in f["rooms"]:
		var rc: Dictionary = rm["rect"]
		rooms.append({"x0": rc["x0"], "z0": rc["z0"], "x1": rc["x1"], "z1": rc["z1"], "active": rm["active"]})
	var doors: Array = []
	for d in f["doors"]:
		doors.append({"x": d["x"], "z": d["z"], "wall": d["wall"]})
	return {
		"rooms": rooms, "doors": doors,
		"down": {"x": f["stairDown"]["x"], "z": f["stairDown"]["z"], "open": bool(r["stairOpen"])},
		"up": {"x": f["stairUp"]["x"], "z": f["stairUp"]["z"]},
		"chest": {"x": f["chest"]["x"], "z": f["chest"]["z"]} if (f["chest"] != null and not _chest_opened) else null,
	}


## A one-line status for the area line under the minimap.
func progress_line() -> String:
	var r: Variant = run()
	if r == null:
		return ""
	var lvl: float = g.sim.area_level("depths")
	var extras := DmSimDepthsRules.extra_affixes(float(r["depth"]))
	return "Level <b>%d</b> dead%s" % [int(lvl), " · elites bear <b>%d</b> affixes" % (extras + 1) if extras > 0 else ""]


# --- Entering, descending, leaving -----------------------------------------------------------------------------------------------

## Click the Warren's stair: with a deeper floor on record, offer the choice (game_event "depths_stair_prompt" {resume}; the card calls
## enter(depth)); otherwise start a run on depth 1. Returns the depth to offer a resume at, or 0 when the run simply began (or could not).
func stair_clicked() -> int:
	var resume := 0 if can_enter() != "" else resume_at()
	if resume > 0 and run() == null:
		g.emit_game_event("depths_stair_offer", {"deepest": resume})
		return resume
	enter(1)
	return 0


## Start a run on `depth` (1 or, from the stair's choice, the deepest floor on record). `seed_ < 0` = a fresh random seed.
func enter(depth: int = 1, seed_: int = -1) -> bool:
	depth = maxi(1, depth)
	if seed_ < 0:
		seed_ = int(randi())
	var why := can_enter()
	if why != "":
		g.toast(why, "err")
		g.play_sfx("error")
		return false
	# A party member goes down alone: step out of the party first.
	var party := _in_party()
	if party:
		_step_out_of_party()
		g.emit_game_event("depths_solo")
	if g.sim.depths != null:
		if party:
			_step_back_into_party()
		return false
	_chest_opened = false
	_over = false
	_end_note = null
	_last_stair_open = false
	_leave_armed_until = 0.0
	var floor_dict: Dictionary = g.sim.start_depths(g.self_id, seed_, depth)
	_load_view(floor_dict)
	g.chronicle.add("depths.runs")
	g.chronicle.max_("peak.depth", float(depth))
	_arrive(floor_dict, "You go down")
	g.emit_game_event("depths_floor")
	return true


## The stair down was clicked.
func descend() -> bool:
	var r: Variant = run()
	if r == null or _over:
		return false
	if not bool(r["stairOpen"]):
		g.toast("The stair is sealed: slay %d more of the dead." % int(maxf(0.0, float(r["need"]) - float(r["kills"]))), "err")
		g.play_sfx("error")
		return false
	var nf: Variant = g.sim.descend_depths()
	if nf == null:
		return false
	_chest_opened = false
	_last_stair_open = false
	_load_view(nf)
	g.chronicle.max_("peak.depth", float(g.sim.depths["depth"]))
	_arrive(nf, "You descend")
	return true


## The exit: asks twice, then ends the run and puts you back at the Warren's stair.
func leave() -> bool:
	var r: Variant = run()
	if r == null or _over:
		return false
	if _now > _leave_armed_until:
		_leave_armed_until = _now + LEAVE_CONFIRM_MS
		g.toast("Climbing out ends this run at depth %d (what you looted is yours). Click again to leave." % int(r["depth"]))
		g.play_sfx("click")
		return false
	_end("left")
	_clear_loot()   # what was left down there stays down there
	var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
	g.actions.teleport_to(float(s["x"]), float(s["z"]) + 2.3)
	return true


## Put the hero on a new floor with the legion, face north, say where they are.
func _arrive(floor_dict: Dictionary, verb: String) -> void:
	var r: Dictionary = run()
	# Every floor is built in the same space: anything left on the last one is gone, not waiting on the new one.
	_clear_loot()
	g.actions.teleport_to(float(floor_dict["start"]["x"]), float(floor_dict["start"]["z"]))
	g.player.facing = PI
	if g.camera != null:
		g.camera.snap(Vector3(float(floor_dict["start"]["x"]), 0, float(floor_dict["start"]["z"])))
	var lvl: float = g.sim.area_level("depths")
	var extras := DmSimDepthsRules.extra_affixes(float(r["depth"]))
	g.banner("Depth %d" % int(r["depth"]),
		"%s · slay %d · level %d dead%s%s" % [verb, int(r["need"]), int(lvl), " · elites bear %d affixes" % (extras + 1) if extras > 0 else "", " · a chest waits" if floor_dict["chest"] != null else ""],
		DEPTHS_BANNER_MS)
	g.play_sfx("gate", float(floor_dict["start"]["x"]), float(floor_dict["start"]["z"]))
	if g.visual:
		g.vfx.light_flash(Vector3(float(floor_dict["start"]["x"]), 3.0, float(floor_dict["start"]["z"])), Color.hex(0xffb347ff), 40.0, 1.2)
	if extras > 0:
		g.emit_game_event("depths_affix", {"extras": extras})


# --- Events and frame ------------------------------------------------------------------------------------------------------------

## Called with every sim event (the scene's handleEvent).
func on_event(ev: Dictionary) -> void:
	if String(ev.get("t", "")) == "depthsClear":
		_cleared(int(ev["depth"]), float(ev["x"]), float(ev["z"]))


## The floor's quota is met: the stair opens and the floor pays.
func _cleared(depth: int, x: float, z: float) -> void:
	if _over or not g.player.alive or g.sim.depths == null:
		return
	_set_stair_open(true)
	_last_stair_open = true
	var level: float = g.sim.area_level("depths")
	var mult := _reward_mult()
	var win: Dictionary = DmDepthsRewards.roll_floor_clear(float(depth), level, Callable(), String(g.discipline["id"]))
	var gold := DmMath.js_round(float(win["gold"]) * mult) + int(win["materialGold"])
	var xp := DmMath.js_round(float(win["xp"]) * mult)
	g.psync.report_floor({"depth": depth, "level": level, "clear": true, "chest": false, "mult": mult})
	_give_gold(x, z + 1.2, gold)
	g.rewards.gain_xp(float(xp), x, z)
	if win["drop"] != null:
		g.rewards.drop_items(x, z + 1.8, [win["drop"]], level, "surge")
	g.chronicle.add("depths.floors")
	g.banner("The stair opens", "Depth %d cleared · +%d gold%s" % [depth, gold, " · something waits on the steps" if win["drop"] != null else ""], DEPTHS_BANNER_MS)
	g.play_sfx("gate", x, z)
	if g.visual:
		g.vfx.emit({"x": x, "y": 0.4, "z": z, "count": 60, "color": 0xffb347, "spread": 1.1, "speed": 1.2, "up": 4, "life": 1.4, "size": 0.3})
		g.vfx.light_flash(Vector3(x, 3.0, z), Color.hex(0xffb347ff), 60.0, 1.4)
	if g.camera != null:
		g.camera.shake(0.2)


## The chest was clicked.
func open_chest() -> bool:
	var r: Variant = run()
	var f: Variant = floor_()
	if r == null or f == null or f["chest"] == null or _over or _chest_opened:
		return false
	_chest_opened = true
	g.play_sfx("chestOpen")
	_set_chest_opened(true)
	var level: float = g.sim.area_level("depths")
	var loot: Dictionary = DmDepthsRewards.roll_chest(float(r["depth"]), level, Callable(), String(g.discipline["id"]))
	var mult := _reward_mult()
	var gold := DmMath.js_round(float(loot["gold"]) * mult) + int(loot["materialGold"])
	var x := float(f["chest"]["x"])
	var z := float(f["chest"]["z"])
	g.psync.report_floor({"depth": int(r["depth"]), "level": level, "clear": false, "chest": true, "mult": mult})
	_give_gold(x, z + 1.2, gold)
	g.rewards.gain_xp(float(DmMath.js_round(float(loot["xp"]) * mult)), x, z)
	# Fan the drops out in front of the chest, the gear first.
	var drops: Array = loot["drops"]
	for i in drops.size():
		var a := PI * (0.25 + (0.5 * i) / float(maxi(1, drops.size() - 1)))
		g.rewards.drop_items(x + cos(a) * 1.6, z + sin(a) * 1.6 + 0.4, [drops[i]], level, "boss")
	var rune := false
	for d in drops:
		if String(DmLootData.item(String(d["item_id"])).get("type", "")) == "rune":
			rune = true
			break
	g.chronicle.add("depths.chests")
	g.banner("The chest opens", "+%d gold · %d finds%s" % [gold, drops.size(), " · a rune among them" if rune else ""], DEPTHS_BANNER_MS)
	g.play_sfx("levelUp")
	if g.visual:
		g.vfx.emit({"x": x, "y": 0.8, "z": z, "count": 80, "color": 0xf3d27a, "spread": 0.8, "speed": 1.6, "up": 4.5, "life": 1.5, "size": 0.3})
		g.vfx.light_flash(Vector3(x, 2.0, z), Color.hex(0xf3d27aff), 70.0, 1.3)
	if g.camera != null:
		g.camera.shake(0.18)
	g.emit_game_event("depths_chest")
	return true


## The kill's loot comes from the ground whose gear matches the depth. -> String or null
func loot_area(area: String) -> Variant:
	var r: Variant = run()
	return DmDepthsRewards.depth_loot_area(float(r["depth"])) if (area == "depths" and r != null) else null


## A kill on the floor: the Chronicle counts it.
func record_kill() -> void:
	g.chronicle.add("kills")
	g.chronicle.add("kills.depths")


## The hero fell. The run is over, but the floor stays up behind the death screen until they rise (finish_after_death).
func on_player_death() -> void:
	var r: Variant = run()
	if r == null or _over:
		return
	_over = true
	_end_note = _summary(r)
	g.chronicle.max_("peak.depth", float(r["peak"]))
	g.flush_chronicle()


## The hero rose in the Chapterhouse: the Depths close behind them.
func finish_after_death() -> void:
	if run() == null:
		return
	var note: Variant = _end_note
	_close()
	if note != null:
		g.toast(String(note), "good")


## Per frame. `in_depths` is whether the hero stands on the Depths ground.
func update(dt: float, now_ms: float, in_depths: bool) -> void:
	_now = now_ms
	var r: Variant = run()
	if r != null and not _over:
		if not in_depths:
			_end("recalled")
		elif g.remotes.size() > 0:
			g.toast("A friend appeared on the descent: a run is solo, so the stair closes behind you.", "err")
			_end("party")
			var s: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
			g.actions.teleport_to(float(s["x"]), float(s["z"]) + 2.3)
		elif bool(r["stairOpen"]) != _last_stair_open:
			_last_stair_open = bool(r["stairOpen"])
			_set_stair_open(_last_stair_open)
	# A calm word the first time the hero walks up to the stair.
	_near_t -= dt
	if _near_t <= 0.0:
		_near_t = 0.5
		var p = g.player
		var s2: Dictionary = DmContent.get_export("areas", "DEPTHS_STAIR")
		if run() == null and p.area == "warren" and DmSimMath.hypot(p.x - float(s2["x"]), p.z - float(s2["z"])) < NEAR_STAIR_TIP:
			g.emit_game_event("depths_stair_near")


# --- Ending ----------------------------------------------------------------------------------------------------------------------

func _summary(r: Dictionary) -> String:
	var fl := int(r["floors"])
	return "The descent ends at depth %d · %d slain · %d floor%s cleared. What you looted is yours." % [int(r["peak"]), int(r["totalKills"]), fl, "" if fl == 1 else "s"]


func _end(why: String) -> void:
	var r: Variant = run()
	if r == null:
		return
	var note := _summary(r)
	g.chronicle.max_("peak.depth", float(r["peak"]))
	g.flush_chronicle()
	_close()
	if why != "party":
		g.toast(note, "good")


## Tear the run down (sim, nav and picture).
func _close() -> void:
	var had_run := g.sim.depths != null
	g.sim.end_depths()
	_clear_view()
	_over = false
	_end_note = null
	_chest_opened = false
	_leave_armed_until = 0.0
	_last_stair_open = false
	if had_run and not _disposed:
		_step_back_into_party()


func dispose() -> void:
	_disposed = true
	if g.sim != null:
		_close()
	if _stair_node != null and is_instance_valid(_stair_node):
		_stair_node.queue_free()
	_stair_node = null


## Dev/QA: whether a chest is on this floor and whether it has been opened.
func debug() -> Dictionary:
	var r: Variant = run()
	return {"chest": r != null and int(r["depth"]) % 5 == 0, "opened": _chest_opened, "over": _over}


# --- host plumbing ---------------------------------------------------------------------------------------------------------------

func _in_party() -> bool:
	return String(g.party_code) != ""


func _step_out_of_party() -> void:
	if g.has_method("pause_coop"):
		g.pause_coop()


func _step_back_into_party() -> void:
	if g.has_method("resume_coop"):
		g.resume_coop()


func _reward_mult() -> float:
	return DmAscension.ascension_reward_mult(g.rewards.world_ascension()) * float(g.omen["rewardMult"])


func _give_gold(x: float, z: float, amount: int) -> void:
	if g.lootview != null:
		g.lootview.gold(Vector3(x, 0, z), amount)
	else:
		g.prog.add_gold(amount)


func _clear_loot() -> void:
	if g.lootview == null:
		return
	var rc: Dictionary = DmContent.area("depths")["rect"]
	g.lootview.clear_within(Rect2(float(rc["x0"]), float(rc["z0"]), float(rc["x1"]) - float(rc["x0"]), float(rc["z1"]) - float(rc["z0"])))


func _load_view(floor_dict: Dictionary) -> void:
	if g.builder == null:
		return
	g.builder.open_instance("depths", true)
	g.builder.build_depths_floor(floor_dict)
	_set_stair_open(false)
	_set_chest_opened(false)


func _clear_view() -> void:
	if g.builder == null:
		return
	g.builder.clear_depths_floor()
	g.builder.open_instance("depths", false)


func _set_stair_open(open: bool) -> void:
	if g.builder != null and g.builder.has_method("set_depths_stair_open"):
		g.builder.set_depths_stair_open(open)


func _set_chest_opened(opened: bool) -> void:
	if g.builder != null and g.builder.has_method("set_depths_chest_opened"):
		g.builder.set_depths_chest_opened(opened)
