class_name CrowdView
extends Node3D
## Draws the combat core's enemies and thralls as MultiMesh crowds (client/crowd/README.md "Driving the crowd"). One MultiMeshInstance3D per model, level
## of detail and shadow group, built from the baked models (CrowdVatData); no node and no script per creature. The core's `DmCrowd` does the work: this
## node maps defs and thrall kinds to models like today's DmEntityViews (client/crowd/crowd_looks.json), calls `DmCrowd.sync(core)` right after each core
## step and `DmCrowd.draw` every rendered frame.
##   var view := CrowdView.new()
##   world.add_child(view)
##   view.setup(core, DmContent.enemies(), Vector2(-60, -60), Vector2(60, 60))
##   view.focus = hero_xz                        # every tick: the hero (the knock pushes away from it, shadows go to the nearest to it)
##   view.set_owner_legion(hero_core_id, "gravecaller")

const LOOKS_PATH := "res://crowd/crowd_looks.json"
const BAKED_DIR := "res://assets/crowd/baked"   # generated, not in git: ships in the assets pack (publish-godot-client.sh)
## Camera distances (metres) where a model's level of detail 1, 2 ... start. The camera sits about 22 m up and back, so a creature in view is 20 to 45 m away.
const LOD_DISTANCES := [32.0, 60.0]
## Instances every group (model, level of detail, shadow) is sized for at loading: a wave of one model then never grows a MultiMesh.
const RESERVE := 128
## How far above and below the ground a creature (a hover, a sinking corpse, a tall elite) can be drawn.
const AREA_HEIGHT := Vector2(-4.0, 14.0)

var core: RefCounted
var crowd: RefCounted   # DmCrowd
## The hero's ground position, written every tick by the game layer.
var focus := Vector2.ZERO
## The picture clock of a struck enemy (Vfx.hitstop_scale), written by the game layer.
var hitstop_scale := 1.0
## Call `sync()` for each core step by itself (from `_physics_process`, after the nodes that step the core); off when the game layer calls it.
var auto_sync := true
## Models the bake did not have, with what drew instead (each listed once).
var warnings := PackedStringArray()
var lod_distances := PackedFloat32Array(LOD_DISTANCES)

var _looks: Dictionary
var _baked_dir := BAKED_DIR
var _assets_dir := ""
var _aabb := AABB()
var _slots := {}          # model slug -> DmCrowd model slot
var _data := {}           # model slug -> CrowdVatData
var _baked := {}          # model slug -> true, found on disk
var _enemy_defs: Dictionary
var _last_clock := -1.0
var _materials: Array[ShaderMaterial] = []   # every model's material (the glow palette goes to each)
var _glow_version := -1


## `enemy_defs`: the ENEMIES dictionary of data/content/enemies.json (flying, inert, rig per def). `area_min`, `area_max`: the area's bounds, for the MultiMeshes'
## custom_aabb (the game layer sets the core's own with `core.set_area_bounds`). `opts`: baked_dir, assets_dir (where the models' textures
## are when they are not imported), lod_distances, reserve, champion_scale (LEGEND.championScale).
func setup(p_core: RefCounted, enemy_defs: Dictionary, area_min: Vector2, area_max: Vector2, opts := {}) -> void:
	core = p_core
	_enemy_defs = enemy_defs
	_baked_dir = String(opts.get("baked_dir", BAKED_DIR))
	_assets_dir = String(opts.get("assets_dir", CrowdBaker.default_assets_dir()))
	if opts.has("lod_distances"):
		lod_distances = opts.lod_distances
	_looks = JSON.parse_string(FileAccess.get_file_as_string(LOOKS_PATH))
	_aabb = AABB(Vector3(area_min.x, AREA_HEIGHT.x, area_min.y), Vector3(area_max.x - area_min.x, AREA_HEIGHT.y - AREA_HEIGHT.x, area_max.y - area_min.y))
	if DirAccess.dir_exists_absolute(_baked_dir):   # nothing baked yet (a fresh checkout): every def falls back, with its warning, and nothing is drawn
		for dir in DirAccess.get_directories_at(_baked_dir):
			if FileAccess.file_exists(_baked_dir.path_join(dir).path_join("model.tres")):
				_baked[dir] = true
	crowd = ClassDB.instantiate("DmCrowd")
	crowd.reserve(int(opts.get("reserve", RESERVE)))
	crowd.set_champion_scale(float(opts.get("champion_scale", 1.35)))
	crowd.set_glows(_glow(_looks.enemy_glow.elite), float(_looks.thrall_glow.champion))
	_register_enemies()
	_register_thralls()
	process_physics_priority = 1000   # after the nodes that step the core


## Sets which discipline's legion a hero's thralls look like (a core hero id; "ossuary", "gravecaller", "rotweaver", "mourner", or "" for none).
func set_owner_legion(owner_id: int, legion: String) -> void:
	crowd.set_owner_legion(owner_id, _looks.legion_order.find(legion))


## Reads the core into the crowd: right after `core.step()`, before `core.take_events()`.
func sync() -> void:
	crowd.set_focus(focus)
	crowd.sync(core)
	_last_clock = core.clock()


## Forgets every creature: a new core or a new area (the models and looks stay).
func clear() -> void:
	crowd.clear()


func stats() -> Dictionary:
	return crowd.stats()


## The models in use: slug -> DmCrowd slot. `data_of(slug)` is the baked CrowdVatData behind one.
func model_slots() -> Dictionary:
	return _slots.duplicate()


func data_of(slug: String) -> CrowdVatData:
	return _data[slug]


func _physics_process(_delta: float) -> void:
	if auto_sync and core != null and core.clock() != _last_clock:
		sync()


func _process(delta: float) -> void:
	if crowd == null:
		return
	if crowd.glow_version() != _glow_version:   # a new glow came into play (an elite, a champion...): every material learns the palette
		_push_glows()
	crowd.set_hitstop_scale(hitstop_scale)
	var cam := get_viewport().get_camera_3d()
	crowd.draw(delta, Engine.get_physics_interpolation_fraction(), cam.global_position if cam != null else Vector3(focus.x, 0.0, focus.y))


# ----------------------------------------------------------------------------------------------------------------------------------- looks

static func _color(hex: String) -> Color:
	var v := hex.hex_to_int()
	return Color(float((v >> 16) & 255) / 255.0, float((v >> 8) & 255) / 255.0, float(v & 255) / 255.0).srgb_to_linear()


## A glow for DmCrowd: [sRGB hex, strength] -> the linear colour with the strength in alpha (DmCreature's emissive x emissive_intensity).
static func _glow(pair: Variant) -> Color:
	if not pair is Array:
		return Color(0, 0, 0, 0)
	var c := _color(String(pair[0]))
	c.a = float(pair[1])
	return c


## The palette (DmCrowd.glow_palette) on every model's material: 64 slots, unused ones dark.
func _push_glows() -> void:
	_glow_version = crowd.glow_version()
	var pal: PackedColorArray = crowd.glow_palette()
	var v := PackedVector4Array()
	v.resize(64)
	for i in mini(pal.size(), 64):
		v[i] = Vector4(pal[i].r, pal[i].g, pal[i].b, pal[i].a)
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("glow_palette", v)


func _register_enemies() -> void:
	for def in _looks.enemy_model:
		if not _enemy_defs.has(def):
			continue
		var d: Dictionary = _enemy_defs[def]
		var slug := _model_for(String(_looks.enemy_model[def]), def)
		if slug == "":
			continue
		var flying: Variant = d.get("flying")
		var tint := Color.WHITE
		var tint_fen := Color.WHITE
		if def == "risen":   # DmEntityViews._enemy_opts: the risen are grey, the drowned ones teal
			tint = _color(_looks.enemy_tint.risen)
			tint_fen = _color(_looks.enemy_tint.risen_fen)
		var look := {"model": _slot(slug), "hover": float(flying) if flying != null else float(_looks.hover.get(def, 0.0)),
			"flyer": flying != null, "caster": _looks.casters.has(def), "inert": bool(d.get("inert", false)), "mist": _looks.mist.has(def),
			"tint": tint, "tint_fen": tint_fen, "glow": _glow(_looks.enemy_glow.get(def))}
		if def == "risen":   # the drowned risen of the Fen glow teal
			look["glow_fen"] = _glow(_looks.enemy_glow.risen_fen)
		crowd.set_enemy_look(def, look)


## The look of every thrall kind under every legion (DmEntityViews._make_thrall): THRALL_LOOK first, else the owner's legion, else THRALL_SLUG.
func _register_thralls() -> void:
	for kind in _looks.thrall_model:
		for li in range(-1, _looks.legion_order.size()):
			var look: Variant = _looks.thrall_look.get(kind)
			if look != null and li >= 0:
				continue   # a look of its own does not depend on the legion
			var legion: Variant = null
			if look == null:
				var lid := "mourner" if kind == "wraith" else (String(_looks.legion_order[li]) if li >= 0 else "")
				legion = _looks.legion.get(lid)
			var wanted := String(legion.slug) if legion != null else String(_looks.thrall_model[kind])
			# The hand props (DmEntityViews._make_thrall): a warrior or shieldbearer under an armed legion (or none), any archer or bone mage, drawn
			# with the "<model>+<kind>" variant the baker made; without it, the plain body and a warning.
			var armed: bool = legion == null or bool(legion.get("armed", false))
			if _looks.get("thrall_props", {}).has(kind) and (kind == "archer" or kind == "bonemage" or armed):
				var variant: String = wanted + "+" + String(kind)
				if _baked.has(variant):
					wanted = variant
				elif _baked.has(wanted):
					_warn("no baked variant %s: drawn without its hand props" % variant)
			var slug := _model_for(wanted, "")
			if slug == "":
				continue
			var tint_hex := String(look.tint) if look != null else (String(legion.tint) if legion != null and legion.has("tint") else
				String(_looks.thrall_tint.wraith if kind == "wraith" else _looks.thrall_tint.default))
			var scale := float(look.scale) if look != null and look.has("scale") else float(_looks.thrall_scale.get(kind, 1.0))
			# DmEntityViews._make_thrall: the wraith's own glow; else the look's, the legion's, or the default; + empowered (not the wraith)
			var tg: Dictionary = _looks.thrall_glow
			var glow := _glow(tg.wraith) if kind == "wraith" else (_glow([look.emissive, look.glow]) if look != null and look.has("emissive")
				else (_glow([legion.emissive, legion.get("glow", tg.default[1])]) if legion != null and legion.has("emissive") else _glow(tg.default)))
			crowd.set_thrall_look(kind, li, {"model": _slot(slug), "hover": float(_looks.thrall_hover.get(kind, 0.0)), "scale": scale, "tint": _color(tint_hex),
				"glow": glow, "glow_empowered": 0.0 if kind == "wraith" else float(tg.empowered)})


## The model to draw `wanted` with: itself, else the rig fallback of today's game, else a baked model of the same rig, else any baked one.
## Each substitution is listed once in `warnings`. Returns "" when nothing is baked at all.
func _model_for(wanted: String, def: String) -> String:
	if _baked.has(wanted):
		return wanted
	var fallback := ""
	var chain: Array = []
	if def != "" and _looks.enemy_fallback.has(def):
		chain.append(String(_looks.enemy_fallback[def]))   # the rig today's game draws it with when its own model is missing
	if def != "":
		var rig := String(_enemy_defs.get(def, {}).get("rig", ""))
		for other in _looks.enemy_model:
			if rig != "" and String(_enemy_defs.get(other, {}).get("rig", "")) == rig:
				chain.append(String(_looks.enemy_model[other]))
	chain.append("skeleton_thrall")
	var all := _baked.keys().filter(func(k: String) -> bool: return not k.contains("+"))   # a thrall variant carries props: never a stand-in
	all.sort()
	chain.append_array(all)
	for c in chain:
		if _baked.has(c):
			fallback = c
			break
	if fallback == "":
		_warn("no baked model for %s and none to stand in (bash client/tools/bake_crowd.sh)" % wanted)
		return ""
	_warn("no baked model for %s: drawn as %s" % [wanted, fallback])
	return fallback


func _warn(msg: String) -> void:
	if not warnings.has(msg):
		warnings.append(msg)
		push_warning("CrowdView: " + msg)


# ----------------------------------------------------------------------------------------------------------------------------------- models

## The DmCrowd slot of a baked model, made on first use: its CrowdVatData, a material, and per level of detail two MultiMeshInstance3D nodes (without
## and with shadows) whose MultiMeshes DmCrowd fills.
func _slot(slug: String) -> int:
	if _slots.has(slug):
		return _slots[slug]
	var data: CrowdVatData = ResourceLoader.load(_baked_dir.path_join(slug).path_join("model.tres"), "", ResourceLoader.CACHE_MODE_REUSE)
	var albedo := _texture(data.albedo_path)
	if albedo == null:
		_warn("no colour texture for %s (%s): drawn white" % [slug, data.albedo_path])
	var material := data.make_material(albedo, _texture(data.orm_path) if data.orm_path != "" else null)
	_materials.append(material)
	_glow_version = -1   # the new material needs the palette too
	var plain: Array = []
	var shadow: Array = []
	for lod in data.meshes.size():
		for casts in [false, true]:
			var mm := data.make_multimesh(0, lod)   # DmCrowd allocates its instances
			mm.custom_aabb = _aabb                  # the whole area: the engine never re-measures instances
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_lod%d%s" % [slug, lod, "_shadow" if casts else ""]
			mmi.multimesh = mm
			mmi.material_override = material
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			(shadow if casts else plain).append(mm.get_rid())
	var slot: int = crowd.add_model(slug, data.crowd_data(), plain, shadow, lod_distances)
	_slots[slug] = slot
	_data[slug] = data
	return slot


## The model's colour (or ORM) texture: the imported asset when there is one, else the file next to the glTF.
func _texture(rel: String) -> Texture2D:
	if rel == "":
		return null
	var imported := "res://assets/" + rel
	if ResourceLoader.exists(imported):
		return load(imported)
	if not FileAccess.file_exists(_assets_dir.path_join(rel)):
		return null
	var img := Image.load_from_file(_assets_dir.path_join(rel))
	if img == null:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
