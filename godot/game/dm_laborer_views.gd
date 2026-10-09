class_name DmLaborerViews
extends Node3D
## Port of archive/legacy-web:src/graphics/LaborerViews.ts + the pure rules of archive/legacy-web:src/graphics/laborerLayout.ts. Visible Grave Laborers: while the player is in the
## Sexton's Acre each assigned laborer (H panel, up to four) stands beside a node of its post and works it: chop strokes for wood and ore,
## digging for graves, standing at the pond with a rod to fish. Idle everywhere else (models are made on the first Acre visit, nothing
## updates or fetches elsewhere). The labor view is the one the H panel reads (`game.api.get_labor`); refreshed on entering, when the panel
## changes it (`apply`) and every REFRESH_S.
## Hooks (the host, DmNextAcre): set_active(area == "acre") / apply(view) / update(dt, px, pz) / pick_list() / set_hover(slot) / tip(slot).
## The hand tools: tool_*.glb are NOT in godot/assets/slice/models/props (nor are they used by DmAvatar), so code-built stand-ins show.

const REFRESH_S := 60.0
const ANIMATE_RANGE := 48.0
const PUFF_RANGE := 16.0
const SOUND_RANGE := 11.0
const SOUND_GAP := 1.1
const SOUND_LEVEL := 0.18
const GRIP := Vector3(0, 1, 0.1)
const ROD_GRIP := Vector3(0, 1, 1.1)
const LABORER_MODELS := ["skeleton_thrall", "thrall_legionnaire", "thrall_sentinel", "thrall_plague"]
const LABORER_TOOLS := {
	"woodcutting": {"id": "tool_hatchet", "length": 0.95},
	"mining": {"id": "tool_pickaxe", "length": 1.2},
	"fishing": {"id": "tool_fishing_rod", "length": 1.45},
	"gravedigging": {"id": "tool_spade", "length": 1.2},
}
const LOOKS := [
	{"emissive": 0x1f8f86, "glow": 0.18},
	{"emissive": 0x6a3fc0, "glow": 0.16},
	{"emissive": 0x6b4a1f, "glow": 0.12},
	{"emissive": 0x5a6a18, "glow": 0.16},
]
const DEBRIS := {
	"woodcutting": {"color": 0xb9925a, "up": 1.3, "count": 5},
	"mining": {"color": 0xffd78a, "up": 1.6, "count": 5},
	"gravedigging": {"color": 0x5b4733, "up": 1.1, "count": 5},
}
const CHOP_RANGE := [0.7, 3.0]
const CHOP_IMPACT := 2.1
const NODE_COLLIDER := {"tree": 0.6, "seam": 0.75, "geode": 0.9, "pool": 0.0, "grave": 0.7, "herb": 0.4}
const FOOTPRINT := {"grave_crypt": 1.35, "grave_barrow_king": 2.25}


class Laborer extends RefCounted:
	var slot := 0
	var c: DmCreature
	var node_type := ""
	var node: Dictionary = {}
	var spot: Dictionary = {"x": 0.0, "z": 0.0, "facing": 0.0}
	var skill := "woodcutting"
	var work: Dictionary = {}
	var tools: Dictionary = {}        # tool id -> Node3D
	var hold := 0.0                   # idle seconds so a freshly attached tool calibrates its grip before work starts
	var mode := ""
	var ready := false
	var full := false
	var marker: Sprite3D
	var last_head := 0.0
	var beat_t := 0.0
	var seen := false
	var picked := false
	var slot_view: Variant = null


var game
var reduce_motion := false
var acre_rect: Dictionary = {}
var acre_nodes: Array = []
var ponds: Array = []
var blockers: Array = []
var byslot: Dictionary = {}           # slot -> Laborer
var list: Array = []
var view: Variant = null              # the LaborView dictionary
var view_at := 0.0
var active := false
var fetching := false
var refresh_t := 0.0
var sound_t := 0.0
var hover_slot := -1
var clock := 0.0
var seen_fired := false
var picks: Array = []                 # [{slot, x, z}]
## Callable(view) -> void, the TS hooks.fetch tap (noteLabor); set by DmGameLabor (null = none).
var on_view: Callable = Callable()
## Callable() -> int, unix ms; replaced by tests.
var clock_ms: Callable = func() -> float: return Time.get_unix_time_from_system() * 1000.0

static var _marker_tex: ImageTexture


func setup(game_) -> void:
	game = game_
	name = "LaborerViews"
	var world: Dictionary = game.builder.world
	for n in world["nodes"]:
		if n["area"] == "acre":
			acre_nodes.append(n)
	ponds = world["ponds"]
	for p in world["props"]:
		if p["area"] == "acre":
			blockers.append({"x": float(p["x"]), "z": float(p["z"]), "r": 0.7})
	for a in world["areas"] if world["areas"] is Array else []:
		if a["id"] == "acre":
			acre_rect = a["rect"]
	if acre_rect.is_empty() and world["areas"] is Dictionary:
		acre_rect = world["areas"]["acre"]["rect"]
	visible = false
	game.world_root.add_child(self)


func _in(r: Dictionary, x: float, z: float, pad: float = 0.0) -> bool:
	return x >= float(r["x0"]) - pad and x <= float(r["x1"]) + pad and z >= float(r["z0"]) - pad and z <= float(r["z1"]) + pad


static func _nodes_def() -> Dictionary:
	return DmContent.get_export("gameplay_gatheringRules", "NODES")


# --- laborerLayout.ts -------------------------------------------------------------------------------------------------------------

## What a laborer of this skill does: chop strokes, steady digging, or standing at the water.
static func work_for(skill: Variant) -> Dictionary:
	match skill:
		"woodcutting", "mining":
			return {"anim": "chop", "range": CHOP_RANGE, "impact": CHOP_IMPACT, "beatEvery": 0.0}
		"gravedigging", "gardening":
			return {"anim": "dig", "range": null, "impact": null, "beatEvery": 2.6}
	return {"anim": "idle", "range": null, "impact": null, "beatEvery": 0.0}


## The Acre node a post is worked at: that exact node type, else the lowest-tier node of the same skill. {} when none.
static func post_node(nodes: Array, node_type: String, slot: int = 0) -> Dictionary:
	var defs := _nodes_def()
	if not defs.has(node_type):
		return {}
	var def: Dictionary = defs[node_type]
	var same: Array = []
	for n in nodes:
		if n["type"] == node_type:
			same.append(n)
	if not same.is_empty():
		return same[slot % same.size()]
	var skill: Array = []
	for n in nodes:
		if defs.has(n["type"]) and defs[n["type"]]["skill"] == def["skill"]:
			skill.append(n)
	if skill.is_empty():
		return {}
	skill.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(defs[a["type"]]["level"]) < int(defs[b["type"]]["level"]))
	return skill[0]


static func _preferred_angle(n: Dictionary, slot: int) -> float:
	var kind: String = _nodes_def()[n["type"]]["kind"]
	if kind == "seam" or kind == "geode":
		return PI / 2.0
	if kind == "grave" or kind == "pool":
		return -PI / 2.0
	return PI * 0.75 + float(slot) * 1.1


## Where a laborer stands to work `node` (see the TS comment): {x, z, facing}. `world` = {rect, nodes, ponds, blockers}; `taken` = spots.
static func laborer_spot(node: Dictionary, slot: int, world: Dictionary, taken: Array = []) -> Dictionary:
	var defs := _nodes_def()
	var base := _preferred_angle(node, slot)
	var kind: String = defs[node["type"]]["kind"]
	var r0 := maxf(1.35, float(FOOTPRINT.get(node["type"], NODE_COLLIDER[kind])) + 0.85)
	var first: Variant = null
	var rect: Dictionary = world["rect"]
	for radius in [r0, r0 + 0.5, r0 + 1.1, r0 + 1.8]:
		for i in 12:
			var step := 0 if i == 0 else int(ceil(float(i) / 2.0)) * (1 if i % 2 == 1 else -1)
			var a := base + float(step) * (PI / 6.0)
			var x: float = float(node["x"]) + cos(a) * radius
			var z: float = float(node["z"]) + sin(a) * radius
			var spot := {"x": x, "z": z, "facing": atan2(float(node["x"]) - x, float(node["z"]) - z)}
			if first == null:
				first = spot
			if not (x >= float(rect["x0"]) + 2.2 and x <= float(rect["x1"]) - 2.2 and z >= float(rect["z0"]) + 2.2 and z <= float(rect["z1"]) - 2.2):
				continue
			var bad := false
			for p in world["ponds"]:
				if x >= float(p["x0"]) - 0.5 and x <= float(p["x1"]) + 0.5 and z >= float(p["z0"]) - 0.5 and z <= float(p["z1"]) + 0.5:
					bad = true
					break
			if bad:
				continue
			for o in world["nodes"]:
				if o["id"] != node["id"] and DmSimMath.hypot(float(o["x"]) - x, float(o["z"]) - z) < float(NODE_COLLIDER[defs[o["type"]]["kind"]]) + 0.8:
					bad = true
					break
			if bad:
				continue
			for b in world["blockers"]:
				if DmSimMath.hypot(float(b["x"]) - x, float(b["z"]) - z) < float(b["r"]):
					bad = true
					break
			if bad:
				continue
			for t in taken:
				if DmSimMath.hypot(float(t["x"]) - x, float(t["z"]) - z) < 1.3:
					bad = true
					break
			if bad:
				continue
			return spot
	return first


## "3 h 12 m" / "45 m" / "under 1 m" (non-breaking spaces).
static func worked_text(ms: float) -> String:
	var m := int(floor(maxf(0.0, ms) / 60000.0))
	if m < 1:
		return "under 1 m"
	var h := m / 60
	return "%d h %d m" % [h, m % 60] if h > 0 else "%d m" % m


static func laborer_tip(skill_name: String, worked_ms: float, ready: bool, full: bool) -> String:
	var state := "full, collect them" if full else ("ready to collect" if ready else "working")
	return "Grave Laborer · %s · %s · %s" % [skill_name, worked_text(worked_ms), state]


# --- the view -----------------------------------------------------------------------------------------------------------------------

## True while the player is in the Acre. Entering fetches the laborers (and builds their models the first time).
func set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	visible = on
	if not on:
		hover_slot = -1
		return
	refresh_t = REFRESH_S
	if view != null:
		_sync()
	refresh()


## Re-read the labor view (after the panel assigned or collected, on a timer). Quiet on failure.
func refresh() -> void:
	if not active or fetching or game == null or game.api == null:
		return
	fetching = true
	var r: DmResult = await game.api.get_labor(game.hero_id)
	fetching = false
	if not is_instance_valid(self):
		return
	if r != null and r.ok and r.data is Dictionary and r.data.has("slots"):
		if on_view.is_valid():
			on_view.call(r.data)
		apply(r.data)


## Take a labor view someone else already fetched (the panel, the arrival check).
func apply(v: Dictionary) -> void:
	view = v
	view_at = float(clock_ms.call())
	if active:
		_sync()


func _now() -> float:
	return float(view["now"]) + (float(clock_ms.call()) - view_at) if view != null else float(clock_ms.call())


func _worked_ms(l: Laborer) -> float:
	var s: Variant = l.slot_view
	if s != null and view != null:
		return maxf(0.0, minf(_now() - float(s["startedAt"]), float(view["capMs"])))
	return 0.0


func _world() -> Dictionary:
	return {"rect": acre_rect, "nodes": acre_nodes, "ponds": ponds, "blockers": blockers}


## Match the laborers on screen to the view: create, move, retool or hide each slot.
func _sync() -> void:
	if view == null:
		return
	var taken: Array = []
	var defs := _nodes_def()
	for s in view["slots"]:
		var nt: Variant = s.get("nodeType")
		var def: Variant = defs.get(nt) if (DmCombatData.truthy(s.get("unlocked")) and nt != null and String(nt) != "") else null
		var node: Dictionary = post_node(acre_nodes, String(nt), int(s["slot"])) if def != null else {}
		var l: Laborer = byslot.get(int(s["slot"]))
		if def == null or node.is_empty() or def["skill"] == "gardening":
			if l != null:
				l.c.root.visible = false
				l.marker.visible = false
			continue
		if l == null:
			l = _create(int(s["slot"]))
			byslot[l.slot] = l
			list.append(l)
		if l.node_type != String(nt) or l.node.get("id") != node["id"] or not l.c.root.visible:
			l.node_type = String(nt)
			l.node = node
			l.skill = String(def["skill"])
			l.work = work_for(def["skill"])
			l.spot = laborer_spot(node, l.slot, _world(), taken)
			l.c.root.position = Vector3(float(l.spot["x"]), 0.0, float(l.spot["z"]))
			l.c.root.rotation.y = float(l.spot["facing"])
			l.mode = ""
			l.hold = 0.0
			_ensure_tool(l)
		taken.append(l.spot)
		l.c.root.visible = true
		l.slot_view = s
		l.full = DmCombatData.truthy(s.get("capped"))
		l.ready = DmLabor.labor_actions(def, _worked_ms(l)) >= 1
	_rebuild_picks()


func _create(slot: int) -> Laborer:
	var look: Dictionary = LOOKS[slot % LOOKS.size()]
	var l := Laborer.new()
	l.slot = slot
	l.c = DmCreature.new(LABORER_MODELS[slot % LABORER_MODELS.size()], {"tint": 0xf4ecff, "emissive": int(look["emissive"]), "emissive_intensity": float(look["glow"])})
	l.c.root.visible = false
	add_child(l.c.root)
	var m := Sprite3D.new()
	m.texture = _marker_texture()
	m.pixel_size = 0.5 / 64.0
	m.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	m.shaded = false
	m.transparent = true
	m.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	m.render_priority = 6
	m.position.y = 2.3
	m.visible = false
	l.c.root.add_child(m)
	l.marker = m
	l.work = work_for(null)
	return l


## One shared "work is ready" badge: a gold coin with a check, drawn once.
static func _marker_texture() -> ImageTexture:
	if _marker_tex != null:
		return _marker_tex
	var im := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var pts := [Vector2(19, 33), Vector2(28, 42), Vector2(46, 22)]
	for y in 64:
		for x in 64:
			var p := Vector2(x + 0.5, y + 0.5)
			var d := p.distance_to(Vector2(32, 32))
			var col := Color(0, 0, 0, 0)
			if d <= 28.0:
				col = Color("2a1d0e")
			if d <= 30.0 and d >= 26.0:
				col = Color("e8c15a")
			for i in 2:
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				var ab := b - a
				var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
				if p.distance_to(a + ab * t) <= 3.0:
					col = Color("f5dd8f")
			im.set_pixel(x, y, col)
	_marker_tex = ImageTexture.create_from_image(im)
	return _marker_tex


# Code-built tool stand-ins: +Y is the long axis, the grip near the origin.
static func _box(parent: Node3D, size: Vector3, pos: Vector3, color: int, metal: float, rough: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = DmGearProps.col(color)
	m.metallic = metal
	m.roughness = rough
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)


static func make_tool(id: String, length: float) -> Node3D:
	var root := Node3D.new()
	root.name = id
	var wood := 0x4a3626
	var iron := 0x7a7d86
	var l := length
	match id:
		"tool_hatchet":
			_box(root, Vector3(0.05, l * 0.9, 0.05), Vector3(0, l * 0.35, 0), wood, 0.05, 0.85)
			_box(root, Vector3(0.05, l * 0.26, l * 0.26), Vector3(0, l * 0.74, l * 0.13), iron, 0.8, 0.42)
		"tool_pickaxe":
			_box(root, Vector3(0.055, l * 0.9, 0.055), Vector3(0, l * 0.35, 0), wood, 0.05, 0.85)
			_box(root, Vector3(0.06, 0.07, l * 0.62), Vector3(0, l * 0.78, 0), iron, 0.8, 0.42)
		"tool_spade":
			_box(root, Vector3(0.05, l * 0.7, 0.05), Vector3(0, l * 0.3, 0), wood, 0.05, 0.85)
			_box(root, Vector3(0.22, l * 0.3, 0.03), Vector3(0, l * 0.78, 0), iron, 0.8, 0.42)
		_:
			_box(root, Vector3(0.03, l, 0.03), Vector3(0, l * 0.4, 0), wood, 0.05, 0.85)
	return root


## Make sure the matching hand tool is in the laborer's hand (built once, hidden when the post changes).
func _ensure_tool(l: Laborer) -> void:
	var spec: Variant = LABORER_TOOLS.get(l.skill)
	for id in l.tools:
		(l.tools[id] as Node3D).visible = spec != null and id == spec["id"]
	if spec == null or l.tools.has(spec["id"]):
		return
	var obj := make_tool(String(spec["id"]), float(spec["length"]))
	obj.visible = true
	l.c.attach("R_Hand", obj, ROD_GRIP if l.skill == "fishing" else GRIP)
	l.tools[spec["id"]] = obj
	# Let the grip calibrate in idle before the work clip takes over.
	l.hold = 0.9
	l.mode = ""


func _rebuild_picks() -> void:
	picks.clear()
	for l: Laborer in byslot.values():
		l.picked = l.c.root.visible and l.c.loaded
		if l.picked:
			picks.append({"slot": l.slot, "x": float(l.spot["x"]), "z": float(l.spot["z"])})


## [{slot, x, z}]: loaded, visible laborers only (the world picker adds each as a hit target ~1.0 tall, with a small bonus).
func pick_list() -> Array:
	return picks


## Hover: the slot under the cursor (or -1). Brightens that laborer.
func set_hover(slot: int) -> void:
	hover_slot = slot


## Hover card text for a laborer slot ("" when none): the headline, then "<node name> · click to open the Laborers (H)".
func tip(slot: int) -> String:
	var l: Laborer = byslot.get(slot)
	if l == null or l.slot_view == null:
		return ""
	var def: Dictionary = _nodes_def()[l.node_type]
	var sk: Dictionary = DmContent.get_export("gameplay_gatheringRules", "SKILLS")[def["skill"]]
	var line := laborer_tip(String(sk["name"]), _worked_ms(l), l.ready, l.full)
	return "<b>%s</b><div>%s · click to open the Laborers (H)</div>" % [line, def["name"]]


func _set_mode(l: Laborer, mode: String) -> void:
	if l.mode == mode:
		return
	l.mode = mode
	if mode == "work" and l.work["anim"] == "chop" and l.work["range"] != null:
		l.c.set_loop("chop", 1.0)
		l.last_head = 0.0
		return
	if mode == "work" and l.work["anim"] == "dig":
		l.c.set_loop("dig", 1.0)
	else:
		l.c.set_loop("idle", 1.0)
	l.last_head = 0.0


## The clip second of the running work action (0 when nothing plays), for timing impact puffs.
func _playhead(l: Laborer) -> float:
	var ap: AnimationPlayer = l.c.ap
	return ap.current_animation_position if (ap != null and ap.is_playing()) else 0.0


## LOOP_NONE clips: repeat the chop segment (wrapRange) / the whole dig clip while working.
func _keep_loop(l: Laborer) -> void:
	var ap: AnimationPlayer = l.c.ap
	if ap == null or l.mode != "work" or l.c.busy():
		return
	var nm := ap.assigned_animation
	if nm == "" or nm == "idle" or nm == "walk":
		return
	var rng: Variant = l.work["range"]
	var length := ap.get_animation(nm).length
	if not ap.is_playing():
		ap.play(nm)
		ap.seek(float(rng[0]) if rng != null else 0.0, true)
		return
	if rng != null and l.work["anim"] == "chop":
		var t := ap.current_animation_position
		var s: float = rng[0]
		var e: float = rng[1]
		if t < s:
			ap.seek(s, true)
		elif t >= e:
			ap.seek(s + fmod(t - s, e - s), true)
	elif ap.current_animation_position >= length - 0.001:
		ap.seek(0.0, true)


func update(dt: float, px: float, pz: float) -> void:
	if not active or view == null:
		return
	clock += dt
	sound_t -= dt
	refresh_t -= dt
	if refresh_t <= 0.0:
		refresh_t = REFRESH_S
		refresh()
	var calm: bool = reduce_motion
	if game != null and game.get("settings") is Dictionary:
		calm = bool(game.settings.get("reduce_motion", false))
	for l: Laborer in list:
		if not l.c.root.visible:
			continue
		var dist := DmSimMath.hypot(float(l.spot["x"]) - px, float(l.spot["z"]) - pz)
		if dist > ANIMATE_RANGE:
			continue
		if l.hold > 0.0:
			l.hold -= dt
		var mode := "hold" if l.hold > 0.0 else ("rest" if l.full else "work")
		_set_mode(l, mode)
		l.c.update(dt)
		_keep_loop(l)
		if l.c.loaded and not l.picked:
			_rebuild_picks()
		# Fishers sway very gently at the water; the rod rides the hand.
		l.c.root.rotation.z = sin(clock * 1.3 + float(l.slot)) * 0.02 if (l.skill == "fishing" and l.mode == "work" and not calm) else 0.0
		l.c.set_flash(0.2 if hover_slot == l.slot else 0.0)
		var show_marker := l.ready and l.c.loaded
		if l.marker.visible != show_marker:
			l.marker.visible = show_marker
		if show_marker:
			l.marker.position.y = 2.3 + (0.0 if calm else sin(clock * 2.2 + float(l.slot)) * 0.06)
		if mode == "work" and l.c.loaded:
			_beats(l, dt, dist, calm)
			if not l.seen and dist < PUFF_RANGE and l.hold <= 0.0:
				l.seen = true
				if not seen_fired:
					seen_fired = true
					game.emit_game_event("laborers_seen")


## Impact puff + (very quiet, throttled) sound on each stroke, only near the player.
func _beats(l: Laborer, dt: float, dist: float, calm: bool) -> void:
	var beat := false
	if l.work["impact"] != null:
		var head := _playhead(l)
		beat = l.last_head < float(l.work["impact"]) and head >= float(l.work["impact"])
		l.last_head = head
	elif float(l.work["beatEvery"]) > 0.0:
		l.beat_t += dt
		if l.beat_t >= float(l.work["beatEvery"]):
			l.beat_t -= float(l.work["beatEvery"])
			beat = true
	if not beat or dist > PUFF_RANGE:
		return
	var d: Variant = DEBRIS.get(l.skill)
	if d != null and not calm and game.get("vfx") != null:
		var k := 0.55 if l.skill == "gravedigging" else 0.8
		var x: float = float(l.spot["x"]) + (float(l.node["x"]) - float(l.spot["x"])) * k
		var z: float = float(l.spot["z"]) + (float(l.node["z"]) - float(l.spot["z"])) * k
		game.vfx.emit({"x": x, "y": 0.15 if l.skill == "gravedigging" else 0.7, "z": z, "count": d["count"], "color": d["color"], "spread": 0.25, "speed": 1.1, "up": d["up"], "life": 0.5, "size": 0.14, "gravity": 5})
	# The one laborer sound call site: the skill's own gather sound, quiet, one at a time.
	if dist < SOUND_RANGE and sound_t <= 0.0 and l.skill != "fishing":
		sound_t = SOUND_GAP
		if game.get("audio") != null:
			var def: Dictionary = _nodes_def().get(l.node["type"], {})
			game.audio.play_sfx(DmGatherSfx.gather_sfx(l.skill, String(def.get("kind", ""))), Vector2(float(l.node["x"]), float(l.node["z"])), SOUND_LEVEL)


## QA: what is where, in what mode.
func debug() -> Array:
	var out: Array = []
	for l: Laborer in byslot.values():
		out.append({"slot": l.slot, "model": l.c.slug, "node": l.node.get("id"), "type": l.node_type, "x": snappedf(float(l.spot["x"]), 0.01), "z": snappedf(float(l.spot["z"]), 0.01),
			"visible": l.c.root.visible, "loaded": l.c.loaded, "mode": l.mode, "ready": l.ready, "full": l.full, "tools": l.tools.keys(), "head": snappedf(_playhead(l), 0.01)})
	return out


func dispose() -> void:
	for l: Laborer in byslot.values():
		l.c.dispose()
	byslot.clear()
	list.clear()
	queue_free()
