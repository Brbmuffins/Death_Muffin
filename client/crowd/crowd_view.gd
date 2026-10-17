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
## Animation levels of detail (README "Crowd cost"): a body beyond `mid_m` metres from the camera works its pose out `mid_hz` times a second, beyond `far_m` `far_hz` times (0 = every frame).
## The distances are the first two mesh levels' (LOD_DISTANCES); a body in view near the hero is nearer than `mid_m`. A first guess for the test build, like the levels: the benchmark records them.
const ANIM_LOD := {"mid_m": 32.0, "mid_hz": 24.0, "far_m": 60.0, "far_hz": 10.0}
## Slots of the glow and rim palettes (DmCrowd's GLOW_SLOTS, the shader's array sizes): COLOR.a = slot * 2 + flash stays exact in a half float up to slot 127.
const SLOTS := 128

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
## Bodies outside the camera's view are not written (README "Crowd cost"). A casting body just outside stays while its shadow falls in.
var cull := true:
	set(v):
		cull = v
		if crowd != null:
			crowd.set_culling(v)
## Over the graphics preset: whether thralls cast shadows (-1 = the preset's, 0 = never, 1 = always). The benchmark's `--bench-crowd=thrall_shadows=off` sets it.
var thrall_shadows := -1

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
## are when they are not imported), lod_distances, reserve, champion_scale (LEGEND.championScale), and the crowd's cost (`apply_cost`): cull, anim_lod, thrall_shadows.
func setup(p_core: RefCounted, enemy_defs: Dictionary, area_min: Vector2, area_max: Vector2, opts := {}) -> void:
	core = p_core
	_enemy_defs = enemy_defs
	_baked_dir = String(opts.get("baked_dir", BAKED_DIR))
	_assets_dir = String(opts.get("assets_dir", CrowdBaker.default_assets_dir()))
	if opts.has("lod_distances"):
		lod_distances = opts.lod_distances
	_looks = JSON.parse_string(FileAccess.get_file_as_string(LOOKS_PATH))
	_aabb = AABB(Vector3(area_min.x, AREA_HEIGHT.x, area_min.y), Vector3(area_max.x - area_min.x, AREA_HEIGHT.y - AREA_HEIGHT.x, area_max.y - area_min.y))
	for slug in baked_models(_baked_dir):   # nothing baked yet (a fresh checkout): every def falls back, with its warning, and nothing is drawn
		_baked[slug] = true
	crowd = ClassDB.instantiate("DmCrowd")
	crowd.reserve(int(opts.get("reserve", RESERVE)))
	crowd.set_champion_scale(float(opts.get("champion_scale", 1.35)))
	apply_cost(opts)
	crowd.set_glows(_glow(_looks.enemy_glow.elite), float(_looks.thrall_glow.champion))
	var rim: Dictionary = _looks.thrall_rim
	crowd.set_thrall_rim(_color(rim.colour), _color(rim.champion_colour), float(rim.own), float(rim.ally), float(rim.champion))
	_register_enemies()
	_register_thralls()
	process_physics_priority = 1000   # after the nodes that step the core


## The crowd's cost settings (README "Crowd cost"), from a setup's options or a benchmark's: `cull` (bool), `anim_lod` (bool, or a dictionary with any of ANIM_LOD's keys),
## `thrall_shadows` (bool, over the graphics preset's). A key that is not there takes its default: culling on, the bands on at ANIM_LOD, the preset's thrall shadows.
func apply_cost(opts: Dictionary) -> void:
	cull = bool(opts.get("cull", true))
	var on := true
	var bands := ANIM_LOD.duplicate()
	var a: Variant = opts.get("anim_lod", true)
	if a is Dictionary:
		bands.merge(a, true)
	else:
		on = bool(a)
	crowd.set_anim_lod(on, float(bands.mid_m), float(bands.mid_hz), float(bands.far_m), float(bands.far_hz))
	thrall_shadows = (1 if bool(opts["thrall_shadows"]) else 0) if opts.has("thrall_shadows") else -1


## The graphics preset's crowd shadows (DmNextPerf.apply): the nearest `casters` enemies cast (`crowded` once the field is crowded), thralls when `thralls_cast`
## unless `thrall_shadows` says otherwise.
func set_shadow_policy(casters: int, crowded: int, thralls_cast: bool) -> void:
	crowd.set_shadow_policy(casters, crowded, thralls_cast if thrall_shadows < 0 else thrall_shadows == 1)


## The direction the moon's light travels, once the area's light is up (DmNextPerf.apply): a casting body just outside the view stays while its shadow falls in.
func set_light_direction(direction: Vector3) -> void:
	crowd.set_shadow_light(direction)


## Sets which discipline's legion a hero's thralls look like (a core hero id; "ossuary", "gravecaller", "rotweaver", "mourner", or "" for none).
func set_owner_legion(owner_id: int, legion: String) -> void:
	crowd.set_owner_legion(owner_id, _looks.legion_order.find(legion))


## Marks a hero's thralls as another player's (`ally`: their friend rim is weaker, as `_make_thrall`'s `own == false`); every hero is this player's until marked.
func set_owner_ally(owner_id: int, ally: bool) -> void:
	crowd.set_owner_ally(owner_id, ally)


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
	if cam == null:
		crowd.draw(delta, Engine.get_physics_interpolation_fraction(), Vector3(focus.x, 0.0, focus.y))
	elif cull:   # the view (the camera's projection times its inverse transform) goes in with the camera's place: one call, the culling is the core's
		crowd.draw(delta, Engine.get_physics_interpolation_fraction(), cam.global_position, cam.get_camera_projection() * Projection(cam.get_camera_transform().affine_inverse()))
	else:
		crowd.draw(delta, Engine.get_physics_interpolation_fraction(), cam.global_position)


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


## The palettes (DmCrowd.glow_palette and rim_palette) on every model's material: SLOTS slots, unused ones dark.
func _push_glows() -> void:
	_glow_version = crowd.glow_version()
	var glows := _palette(crowd.glow_palette())
	var rims := _palette(crowd.rim_palette())
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("glow_palette", glows)
		mat.set_shader_parameter("rim_palette", rims)


static func _palette(pal: PackedColorArray) -> PackedVector4Array:
	var v := PackedVector4Array()
	v.resize(SLOTS)
	for i in mini(pal.size(), SLOTS):
		v[i] = Vector4(pal[i].r, pal[i].g, pal[i].b, pal[i].a)
	return v


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
			"flyer": flying != null, "caster": _looks.casters.has(def), "inert": bool(d.get("inert", false)), "mist": _looks.mist.has(def), "wobble": _looks.wobble.has(def),
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
	if data.format != CrowdVatData.FORMAT:   # a bake of an older baker would be read as noise by the shader
		_warn("%s was baked in format %d, the shader reads %d: bash client/tools/bake_crowd.sh" % [slug, data.format, CrowdVatData.FORMAT])
	var albedo := _texture(data.albedo_path)
	if albedo == null:
		_warn("no colour texture for %s (%s): drawn white" % [slug, data.albedo_path])
	var spectral: bool = (_looks.get("spectral_models", []) as Array).has(slug)   # a ghost: see-through and never in the moon's shadow (DmCreature._spectral)
	var material := data.make_material(albedo, _texture(data.orm_path) if data.orm_path != "" else null, spectral, _texture(data.normal_path) if data.normal_path != "" else null)
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
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts and not spectral else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			(shadow if casts else plain).append(mm.get_rid())
	var slot: int = crowd.add_model(slug, data.crowd_data(), plain, shadow, lod_distances)
	_slots[slug] = slot
	_data[slug] = data
	return slot


## The models baked under `dir` (their slugs). Asks the resource loader, not the file system: an export stores `model.tres` converted, under
## another name (2026-10-17: a file check found none in the test build, which drew no enemy and no thrall). The export boot smoke counts them.
static func baked_models(dir: String = BAKED_DIR) -> PackedStringArray:
	var out := PackedStringArray()
	if DirAccess.dir_exists_absolute(dir):
		for d in DirAccess.get_directories_at(dir):
			if ResourceLoader.exists(dir.path_join(d).path_join("model.tres")):
				out.append(d)
	return out


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
