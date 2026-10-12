class_name DmGearModels
extends RefCounted
## The real (Tripo) models of necromancer gear and the table that says which item shows which one (godot/data/slice/necro_gear.json): the seven weapon
## kinds, the set mantles, the tier helms (and set helms), set weapons (`weapon_by_set_id`) and the legendary-set hero bodies. Every prop is one mesh with one
## material (one draw call). Weapon metal tiers (bone / iron / gold / hell / moon) are tint + glow variants of the one model, each built once and
## shared by every instance (`_mats`); nothing is allocated per frame.
##
## Prop GLBs: +Y up, +X forward (the way the wearer faces), +Z the left-right axis, mesh centred on the origin. A model is scaled uniformly from its
## measured bounds (`bounds_of`) and seated so a chosen point of it sits at the holder's origin: a weapon's grip, a helm's / mantle's centre.

## Metal tier -> how the one weapon model is dressed: a colour multiplier on its texture and the glow (the texture itself, lit by `glow`).
const TIER_DRESS := {
	"bone": {},
	"iron": {"tint": Color(0.9, 0.92, 0.97)},
	"gold": {"tint": Color(1.06, 1.0, 0.9), "glow": Color(0.5, 0.34, 0.08), "k": 0.35},
	"hell": {"tint": Color(1.0, 0.9, 0.86), "glow": Color(0.6, 0.1, 0.03), "k": 0.22},
	"moon": {"tint": Color(0.92, 0.97, 1.06), "glow": Color(0.2, 0.3, 0.7), "k": 0.35},
	"bright": {"tint": Color(1.3, 1.3, 1.45), "glow": Color(0.12, 0.16, 0.3), "k": 0.5},   # low-contrast mantles (the Mourner's pale cloth)
}
## Mantle sets given the "bright" dress.
const BRIGHT_MANTLES := ["mourner", "mourner_ascended"]
## Armour set rarity collection -> helm tier when an item id names none (class sets: iron, ascended: silver, legendary: hellsteel).
const HELM_OF_COLLECTION := {1: "iron", 2: "silver", 3: "hellsteel"}
const HELM_OF_RARITY := {"epic": "silver", "rare": "steel", "uncommon": "iron"}
const HELM_WORDS := ["moonsilver", "hellsteel", "silver", "steel", "iron", "copper"]

static var _table: Dictionary = {}
static var _bounds: Dictionary = {}   ## prop id -> AABB of its meshes (node transforms applied)
static var _shafts: Dictionary = {}   ## "prop|grip_t" -> the (x, z) centre of the mesh at the grip height
static var _mats: Dictionary = {}     ## "prop|tier" -> the shared dressed material
static var _scenes: Dictionary = {}   ## prop id -> its PackedScene, held once loaded (the resource cache would drop it between two equips)
## Models read from disk because nothing had loaded them yet (tests: a prefetched swap must not count here).
static var cold_loads := 0


static func table() -> Dictionary:
	if _table.is_empty():
		_table = DmDb.slice("necro_gear")
	return _table


static func path_of(prop_id: String) -> String:
	return DmModels.BASE + "models/props/%s.glb" % prop_id


## The AABB of a prop's meshes in the scene's own space (cached per prop).
static func bounds_of(prop_id: String) -> AABB:
	if _bounds.has(prop_id):
		return _bounds[prop_id]
	var ps := _scene(prop_id)
	if ps == null:
		return AABB()
	var inst: Node3D = ps.instantiate()
	var bb := AABB()
	var first := true
	for m in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = _rel(inst, mi) * mi.mesh.get_aabb()
		bb = box if first else bb.merge(box)
		first = false
	inst.free()
	_bounds[prop_id] = bb
	return bb


## Where the shaft actually is at the grip height (fraction `t` up the prop's Y extent): the mean x / z of the vertices in a thin band there. A scythe or
## a sickle is far wider than its handle, so the middle of its bounds is not where a hand holds it.
static func shaft_at(prop_id: String, t: float) -> Vector2:
	var key := "%s|%.3f" % [prop_id, t]
	if _shafts.has(key):
		return _shafts[key]
	var bb := bounds_of(prop_id)
	var ps := _scene(prop_id)
	var out := Vector2(bb.position.x + bb.size.x * 0.5, bb.position.z + bb.size.z * 0.5)
	if ps != null and bb.size.y > 0.0:
		var inst: Node3D = ps.instantiate()
		var y := bb.position.y + bb.size.y * t
		var half := bb.size.y * 0.02
		var sum := Vector2.ZERO
		var n := 0
		for m in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := m as MeshInstance3D
			if mi.mesh == null:
				continue
			var xf := _rel(inst, mi)
			for sidx in mi.mesh.get_surface_count():
				for v: Vector3 in mi.mesh.surface_get_arrays(sidx)[Mesh.ARRAY_VERTEX]:
					var p := xf * v
					if absf(p.y - y) <= half:
						sum += Vector2(p.x, p.z)
						n += 1
		inst.free()
		if n >= 6:
			out = sum / float(n)
	_shafts[key] = out
	return out


static func _rel(root: Node, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


static func _scene(prop_id: String) -> PackedScene:
	if _scenes.has(prop_id):
		return _scenes[prop_id]
	var path := path_of(prop_id)
	if not ResourceLoader.exists(path):
		return null
	if not ResourceLoader.has_cached(path):
		cold_loads += 1
	var ps: PackedScene = load(path)
	_scenes[prop_id] = ps
	return ps


## `model` holder: the prop scaled by `s` with the point `at` (fractions 0..1 of its bounds) on the holder's origin; null when the asset is absent.
static func _seat(prop_id: String, s: float, at: Vector3, tier := "", axis := Vector2(NAN, NAN)) -> Node3D:
	var ps := _scene(prop_id)
	if ps == null:
		return null
	var bb := bounds_of(prop_id)
	var inst: Node3D = ps.instantiate()
	inst.scale = Vector3.ONE * s
	var anchor := bb.position + bb.size * at
	if not is_nan(axis.x):
		anchor.x = axis.x
		anchor.z = axis.y
	inst.position = -s * anchor
	var dress := _material(prop_id, inst, tier)
	for m in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if dress != null:
			mi.material_override = dress
	var holder := Node3D.new()
	holder.add_child(inst)
	return holder


## The shared dressed material of a (prop, metal tier); null = the model's own (bone, helms, mantles).
static func _material(prop_id: String, inst: Node3D, tier: String) -> Material:
	var dress: Dictionary = TIER_DRESS.get(tier, {})
	if dress.is_empty():
		return null
	var key := prop_id + "|" + tier
	if _mats.has(key):
		return _mats[key]
	var mat: StandardMaterial3D = null
	for m in inst.find_children("*", "MeshInstance3D", true, false):
		var src := (m as MeshInstance3D).mesh.surface_get_material(0)
		if src is StandardMaterial3D:
			mat = (src as StandardMaterial3D).duplicate()
			break
	if mat == null:
		return null
	mat.albedo_color = dress.tint
	if dress.has("glow"):
		mat.emission_enabled = true
		mat.emission = dress.glow
		mat.emission_energy_multiplier = float(dress.k)
		mat.emission_texture = mat.albedo_texture   # the glow follows the model's own bright detail, not a flat wash
	_mats[key] = mat
	return mat


# ----------------------------------------------------------------------------------------------------------------- weapons

## A weapon or off-hand piece of `kind` (staff, scythe, wand, sickle, skull_focus, mourning_bell, grimoire) in metal `tier`: grip at the origin, blade / head
## up (+Y), `tip` meta at the top end. Null when the kind has no model.
static func weapon(kind: String, tier := "bone") -> Node3D:
	var row: Dictionary = table().get("weapon_kind_prop", {}).get(kind, {})
	if row.is_empty():
		return null
	var length := float(row.length_m)
	var grip_t := float(row.grip_t)
	var bb := bounds_of(String(row.prop))
	if bb.size.y <= 0.0:
		return null
	var s := length / bb.size.y
	var g := _seat(String(row.prop), s, Vector3(0.5, grip_t, 0.5), tier, shaft_at(String(row.prop), grip_t))
	if g == null:
		return null
	var tip := Node3D.new()
	tip.name = "Tip"
	tip.position.y = length * (1.0 - grip_t) - 0.04 * length
	g.add_child(tip)
	g.set_meta("tip", tip)
	g.set_meta("model_kind", kind)
	return g


# ----------------------------------------------------------------------------------------------------------------- helms and mantles

## The tier a head item shows: its set's collection (class sets iron, ascended silver, legendary hellsteel), else its own metal (helm_copper, helm_iron,
## helm_gold = silver), else its rarity.
static func helm_tier_of(item_id: String, rarity := "") -> String:
	var armor := DmGearProps.armor_by_id(item_id)
	if not armor.is_empty():
		if table().get("helm_by_tier", {}).has(String(armor.setId)):
			return String(armor.setId)   # a set with its own helm model (a `helm_by_tier` row keyed by its set id)
		return String(HELM_OF_COLLECTION.get(int(armor.collection), "iron"))
	for w: String in HELM_WORDS:
		if item_id.contains(w):
			return w
	var alias: Dictionary = table().get("helm_tier_alias", {})
	for k: String in alias:
		if item_id.contains(k):
			return String(alias[k])
	return String(HELM_OF_RARITY.get(rarity, "copper"))


## A helm model of `tier`, its centre on the origin, `height` metres tall (uniform scale). Null when there is none.
static func helm(tier: String, height: float) -> Node3D:
	var row: Dictionary = table().get("helm_by_tier", {}).get(tier, {})
	if row.is_empty():
		return null
	var bb := bounds_of(String(row.prop))
	if bb.size.y <= 0.0:
		return null
	return _seat(String(row.prop), height / bb.size.y, Vector3(0.5, 0.5, 0.5))


## The set whose mantle a worn chest piece brings (any set with a `mantle_by_set_id` row); "" when it brings none.
static func mantle_set_of(item_id: String) -> String:
	var armor := DmGearProps.armor_by_id(item_id)
	if armor.is_empty() or String(armor.part) != "chest":
		return ""
	return String(armor.setId) if table().get("mantle_by_set_id", {}).has(String(armor.setId)) else ""


## The props/ GLB a worn set gives weapons of `kind` from `pieces` worn (`weapon_by_set_id`), "" when it gives none.
static func set_weapon_prop(set_id: String, pieces: int, kind: String) -> String:
	var row: Dictionary = table().get("weapon_by_set_id", {}).get(set_id, {})
	if row.is_empty() or String(row.get("kind", "")) != kind or pieces < int(row.get("pieces", 3)):
		return ""
	return String(row.prop)


## A set's mantle model, its centre on the origin, `width` metres across (its +Z axis, the wearer's shoulders).
static func mantle(set_id: String, width: float) -> Node3D:
	var row: Dictionary = table().get("mantle_by_set_id", {}).get(set_id, {})
	if row.is_empty():
		return null
	var bb := bounds_of(String(row.prop))
	if bb.size.z <= 0.0:
		return null
	return _seat(String(row.prop), width / bb.size.z, Vector3(0.5, 0.5, 0.5), "bright" if BRIGHT_MANTLES.has(set_id) else "")


# ----------------------------------------------------------------------------------------------------------------- legendary bodies

## The hero body slug a legendary set turns the wearer into ("" = not a legendary set / no model shipped).
static func legendary_slug(set_id: String) -> String:
	var row: Dictionary = table().get("legendary_hero_by_set_id", {}).get(set_id, {})
	if row.is_empty() or not ResourceLoader.exists(DmModels.BASE + String(row.url)):
		return ""
	return String(row.model)


## The discipline a legendary set belongs to ("" = none): its body is the one kept resident for that class.
static func legendary_of_discipline(discipline_id: String) -> String:
	for set_id: String in table().get("legendary_hero_by_set_id", {}):
		if String(table()["legendary_hero_by_set_id"][set_id].disciplineId) == discipline_id:
			return String(table()["legendary_hero_by_set_id"][set_id].model)
	return ""


## Start loading a legendary body on a worker thread (the swap at three pieces then finds it cached). A no-op when it is loaded or loading.
static func prefetch(slug: String) -> void:
	var path: String = DmModels.BASE + String(DmCreature.model_entry(slug).get("url", ""))
	if path == DmModels.BASE or ResourceLoader.has_cached(path):
		return
	ResourceLoader.load_threaded_request(path, "", true)
