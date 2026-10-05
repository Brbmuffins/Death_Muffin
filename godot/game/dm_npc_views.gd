class_name DmNpcViews
extends Node3D
## Port of src/graphics/NpcViews.ts: the people of the Covenant standing in their halls: an idle figure, a nameplate, a turn toward you when
## you come close, and a gold "!" with a soft glow on the ground while they have something new to say. Looks come from content/npcs.ts
## (NPC_LOOKS). Figures load the first time the player is anywhere near.

const LOAD_RANGE := 70.0
const PLATE_RANGE := 20.0
const TURN_RATE := 4.0

var npcs: Dictionary = {}     # id -> {c: DmCreature|null, root, plate, bang, glow, yaw, head_y, talking, is_new, gesture_t}
var hover_id := ""
var reduce_motion := false
var _clock := 0.0
var _glow_tex: ImageTexture


func setup(parent: Node) -> void:
	name = "NpcViews"
	parent.add_child(self)
	var looks: Dictionary = DmContent.get_export("npcs", "NPC_LOOKS")
	var spots: Dictionary = DmContent.get_export("npcs", "NPCS")
	for id in DmContent.get_export("npcs", "NPC_IDS"):
		var def: Dictionary = spots[id]
		var look: Dictionary = looks[id]
		var entry: Dictionary = DmCreature.model_entry(String(look["slug"]))
		var head_y: float = float(entry.get("height", 1.8)) * float(look["scale"]) + 0.35
		var root := Node3D.new()
		root.name = "Npc_" + String(id)
		root.position = Vector3(float(def["x"]), 0, float(def["z"]))
		root.rotation.y = float(def["rest"])
		root.visible = false
		add_child(root)
		var plate := Label3D.new()
		plate.text = "%s\n%s" % [String(def["name"]).to_upper(), def["title"]]
		plate.font_size = 40
		plate.pixel_size = 0.0058
		plate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		plate.no_depth_test = true
		plate.modulate = Color("f0e9dc")
		plate.outline_size = 10
		plate.outline_modulate = Color(0.03, 0.02, 0.05, 0.9)
		plate.position.y = head_y + 0.15
		plate.render_priority = 7
		root.add_child(plate)
		var bang := Label3D.new()
		bang.text = "!"
		bang.font_size = 90
		bang.pixel_size = 0.0075
		bang.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		bang.no_depth_test = true
		bang.modulate = Color("f5dd8f")
		bang.outline_size = 14
		bang.outline_modulate = Color("2a1d0e")
		bang.visible = false
		bang.render_priority = 8
		root.add_child(bang)
		var glow := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(4.2, 4.2)
		qm.orientation = PlaneMesh.FACE_Y
		glow.mesh = qm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_texture = _glow_texture()
		m.albedo_color = Color(Color.html(String(def.get("accent_hex", "#e8c15a"))) if def.has("accent_hex") else Color.hex(int(def["accent"]) * 256 + 255), 0.0)
		m.no_depth_test = false
		glow.material_override = m
		glow.position.y = 0.06
		glow.visible = false
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(glow)
		npcs[id] = {"c": null, "root": root, "plate": plate, "bang": bang, "glow": glow, "yaw": float(def["rest"]), "head_y": head_y, "talking": false, "is_new": false, "gesture_t": 6.0, "def": def}


func _glow_texture() -> ImageTexture:
	if _glow_tex == null:
		var im := Image.create(128, 128, false, Image.FORMAT_RGBA8)
		for y in 128:
			for x in 128:
				var d := Vector2(x - 63.5, y - 63.5).length() / 62.0
				var a := 0.0
				if d < 1.0:
					a = lerpf(0.95, 0.4, clampf(d / 0.5, 0.0, 1.0)) if d < 0.5 else lerpf(0.4, 0.0, (d - 0.5) / 0.5)
				im.set_pixel(x, y, Color(1, 1, 1, a))
		_glow_tex = ImageTexture.create_from_image(im)
	return _glow_tex


func _load(id: String) -> void:
	var n: Dictionary = npcs[id]
	var look: Dictionary = DmContent.get_export("npcs", "NPC_LOOKS")[id]
	var c := DmCreature.new(String(look["slug"]), {"scale": float(look["scale"]), "tint": int(look["tint"]), "emissive": int(look["emissive"]), "emissive_intensity": float(look["glow"]), "fallback": String(look["fallback"])})
	n["c"] = c
	(n["root"] as Node3D).add_child(c.root)


## Who is talking to the player right now (they keep their eyes on you and use a `talk` clip if the model has one).
func set_talking(id: String) -> void:
	for k in npcs:
		var n: Dictionary = npcs[k]
		var t: bool = k == id
		if t == n["talking"]:
			continue
		n["talking"] = t
		n["gesture_t"] = 5.0 + randf() * 4.0
		var c: DmCreature = n["c"]
		if c != null and c.loaded and c.has("talk"):
			c.set_loop("talk" if t else "idle", 1.0)


func distance_to(id: String, px: float, pz: float) -> float:
	var d: Dictionary = npcs[id]["def"]
	return DmSimMath.hypot(float(d["x"]) - px, float(d["z"]) - pz)


## `is_new`: Callable(id) -> bool (the guidance says they have something new to say).
func update(dt: float, px: float, pz: float, is_new: Callable) -> void:
	_clock += dt
	for id in npcs:
		var n: Dictionary = npcs[id]
		var def: Dictionary = n["def"]
		var dist := distance_to(id, px, pz)
		var near := dist < LOAD_RANGE
		if near and n["c"] == null:
			_load(id)
		(n["root"] as Node3D).visible = near
		if not near:
			continue
		var c: DmCreature = n["c"]
		if n["talking"] and c != null and c.loaded and c.has("talk2"):
			n["gesture_t"] = float(n["gesture_t"]) - dt
			if float(n["gesture_t"]) <= 0.0:
				n["gesture_t"] = 9.0 + randf() * 6.0
				c.play_once("talk2")
		if c != null and c.loaded:
			c.set_loop("talk" if (n["talking"] and c.has("talk")) else "idle", 1.0)
			c.update(dt)
		var want: float = atan2(px - float(def["x"]), pz - float(def["z"])) if (n["talking"] or dist < float(DmContent.get_export("npcs", "NPC_LOOK_RANGE"))) else float(def["rest"])
		var diff := atan2(sin(want - n["yaw"]), cos(want - n["yaw"]))
		n["yaw"] = float(n["yaw"]) + diff * minf(1.0, dt * TURN_RATE)
		if c != null:
			c.root.rotation.y = n["yaw"]
			c.set_flash(0.2 if hover_id == id else 0.0)
		(n["plate"] as Label3D).visible = dist < PLATE_RANGE or hover_id == id
		var fresh: bool = bool(is_new.call(id)) and not n["talking"]
		n["is_new"] = fresh
		var bang: Label3D = n["bang"]
		bang.visible = fresh
		if fresh:
			var bob := 0.0 if reduce_motion else sin(_clock * 2.4 + float(def["x"])) * 0.07
			bang.position.y = float(n["head_y"]) + 0.75 + bob
		var pulse := 0.5 if reduce_motion else 0.5 + 0.5 * sin(_clock * 1.8 + float(def["z"]))
		var glow: MeshInstance3D = n["glow"]
		glow.visible = fresh
		var mat: StandardMaterial3D = glow.material_override
		mat.albedo_color.a = (0.5 + 0.3 * pulse) if fresh else 0.0


func dispose() -> void:
	for id in npcs:
		var c: DmCreature = npcs[id]["c"]
		if c != null:
			c.dispose()
	queue_free()
