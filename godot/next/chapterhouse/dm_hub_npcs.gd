class_name DmHubNpcs
extends DmNpcViews
## The people of the Covenant in the slice: the existing DmNpcViews figures (same models, nameplates, "!" and glow) with a cheaper update.
## DmNpcViews.update walks every NPC every frame; here `refresh()` (5 Hz, called by DmChapterhouse) sorts each NPC into a tier and
## `animate()` (every frame) only touches the ones that need it:
##   far  (beyond PLATE_RANGE)             nothing: frozen idle pose, no per-frame cost
##   mid  (in view, not looking at you)    the idle animation advances at MID_HZ with the accumulated dt
##   near (look range, talking, hovered)   every frame, plus the turn toward you and the talk clips
## Models are loaded in warm() (under the loading cover), never mid-play.

const MID_HZ := 15.0

var _near: Array = []      ## npc ids animated every frame
var _mid: Array = []       ## npc ids animated at MID_HZ
var _mid_acc: float = 0.0
var _px: float = 0.0
var _pz: float = 0.0
var _turning: Dictionary = {}   ## npc id -> true while its yaw has not settled on the wanted heading


func warm() -> void:
	for id in npcs:
		if npcs[id]["c"] == null:
			_load(id)


## 5 Hz: tiers, nameplates, "!" markers, who the player looks at. `is_new`: Callable(id) -> bool.
func refresh(px: float, pz: float, is_new: Callable) -> void:
	_px = px
	_pz = pz
	_near.clear()
	_mid.clear()
	var look: float = float(DmContent.get_export("npcs", "NPC_LOOK_RANGE"))
	for id in npcs:
		var n: Dictionary = npcs[id]
		var dist := distance_to(id, px, pz)
		var root: Node3D = n["root"]
		var shown := dist < LOAD_RANGE
		if root.visible != shown:
			root.visible = shown
		if not shown:
			continue
		var plate: Label3D = n["plate"]
		plate.visible = dist < PLATE_RANGE or hover_id == id
		var fresh: bool = bool(is_new.call(id)) and not n["talking"]
		n["is_new"] = fresh
		(n["bang"] as Label3D).visible = fresh
		var glow: MeshInstance3D = n["glow"]
		glow.visible = fresh
		if not fresh:
			(glow.material_override as StandardMaterial3D).albedo_color.a = 0.0
		var c: DmCreature = n["c"]
		if c != null:
			c.set_flash(0.2 if hover_id == id else 0.0)
		if dist >= PLATE_RANGE and not n["talking"]:
			_turning.erase(id)
		elif dist < look or n["talking"] or hover_id == id or _turning.has(id) or fresh:
			_near.append(id)
		else:
			_mid.append(id)


## Every frame; the lists are empty (no work) when nobody is near or in view.
func animate(dt: float) -> void:
	if _near.is_empty() and _mid.is_empty():
		return
	_clock += dt
	for id in _near:
		_step(id, dt, true)
	if not _mid.is_empty():
		_mid_acc += dt
		if _mid_acc >= 1.0 / MID_HZ:
			for id in _mid:
				_step(id, _mid_acc, false)
			_mid_acc = 0.0


func _step(id: String, dt: float, full: bool) -> void:
	var n: Dictionary = npcs[id]
	var def: Dictionary = n["def"]
	var c: DmCreature = n["c"]
	if c != null and c.loaded:
		c.set_loop("talk" if (n["talking"] and c.has("talk")) else "idle", 1.0)
		c.update(dt)
	if not full:
		return
	if n["talking"] and c != null and c.loaded and c.has("talk2"):
		n["gesture_t"] = float(n["gesture_t"]) - dt
		if float(n["gesture_t"]) <= 0.0:
			n["gesture_t"] = 9.0 + randf() * 6.0
			c.play_once("talk2")
	var dist := distance_to(id, _px, _pz)
	var want: float = atan2(_px - float(def["x"]), _pz - float(def["z"])) if (n["talking"] or dist < float(DmContent.get_export("npcs", "NPC_LOOK_RANGE"))) else float(def["rest"])
	var diff := atan2(sin(want - n["yaw"]), cos(want - n["yaw"]))
	n["yaw"] = float(n["yaw"]) + diff * minf(1.0, dt * TURN_RATE)
	if absf(diff) > 0.02:
		_turning[id] = true
	else:
		_turning.erase(id)
	if c != null:
		c.root.rotation.y = n["yaw"]
	if bool(n["is_new"]):
		var bob := 0.0 if reduce_motion else sin(_clock * 2.4 + float(def["x"])) * 0.07
		(n["bang"] as Label3D).position.y = float(n["head_y"]) + 0.75 + bob
		var pulse := 0.5 if reduce_motion else 0.5 + 0.5 * sin(_clock * 1.8 + float(def["z"]))
		((n["glow"] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = 0.5 + 0.3 * pulse
