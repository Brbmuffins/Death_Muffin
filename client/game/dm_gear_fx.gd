class_name DmGearFx
extends RefCounted
## What worn gear looks like beyond its model: the rarity glow and element motes on a weapon's tip (the motes stay where they were emitted, so a
## swing leaves a short streak), and the set-bonus aura around the body. Everything is built once when the gear changes and then runs on the GPU:
## one shared material, at most MAX_MOTES particles per weapon and AURA_MOTES per hero, no script per frame. Low graphics (`Vfx.quality`) keeps
## the halos and drops the particles. Colours are the game's own spell colours (`DmFxData.spell`), so an element reads like the rite it belongs to.

const RARITIES := ["common", "uncommon", "rare", "epic", "legendary"]
## Per rarity: strength of a worn body piece's tint, size of the weapon's tip halo (x its model's own), opacity of the rarity-coloured outer halo, motes.
const LOOK := [
	{"tint": 0.28, "halo": 1.0, "outer": 0.0, "motes": 0},
	{"tint": 0.30, "halo": 1.0, "outer": 0.0, "motes": 0},
	{"tint": 0.34, "halo": 1.3, "outer": 0.22, "motes": 5},
	{"tint": 0.38, "halo": 1.6, "outer": 0.34, "motes": 10},
	{"tint": 0.42, "halo": 1.8, "outer": 0.45, "motes": 16},
]
const MAX_MOTES := 16
const AURA_MOTES := [0, 6, 14]   ## by aura level (0 none, 1 = 2-3 pieces of one set, 2 = 4+)
## element -> [SPELL_FX group, key]
const ELEMENTS := {
	"bone": ["spear", "bone"], "rot": ["miasma", "rot"], "frost": ["frost", "frost"], "soul": ["souls", "jade"],
	"fire": ["detonate", "ember"], "void": ["litany", "core"], "gold": ["mantle", "gold"], "blood": ["step", "blood"],
}
## What a weapon's metal tier burns with when no rune says otherwise (iron = plain steel, nothing).
const TIER_ELEMENT := {"bone": "bone", "gold": "gold", "hell": "fire", "moon": "frost"}
## The element of a socketed rune (runes.json).
const RUNE_ELEMENT := {
	"rune_splinter": "bone", "rune_marrow_tap": "blood", "rune_volley": "bone", "rune_ossuary_ring": "bone", "rune_impale": "bone",
	"rune_mass_grave": "soul", "rune_bone_colossus": "bone", "rune_creeping_rot": "rot", "rune_contagion": "rot",
	"rune_hollow_choir": "frost", "rune_requiem": "void",
}

static var _mote_mat: StandardMaterial3D = null
static var _quads: Dictionary = {}


static func level_of(rarity: String) -> int:
	return maxi(0, RARITIES.find(rarity))


static func look_of(rarity: String) -> Dictionary:
	return LOOK[level_of(rarity)]


static func valid_element(el: Variant) -> bool:
	return el is String and ELEMENTS.has(el)


static func element_color(el: String) -> Color:
	var src: Array = ELEMENTS.get(el, [])
	return DmFxData.spell(src[0], src[1]) if not src.is_empty() else Color.WHITE


static func rarity_color(rarity: String) -> Color:
	return Color.html(String(DmContent.get_export("items", "RARITY_COLOR").get(rarity, "#b9b2a4")))


## The element a weapon shows: the socketed runes', else its metal tier's, else "".
static func element_for(item_id: String, rune_element := "") -> String:
	if rune_element != "":
		return rune_element
	var necro := DmGearProps.necro_by_id(item_id)
	return String(TIER_ELEMENT.get(String(necro.get("tier", "")), "")) if not necro.is_empty() else ""


## The element the socketed runes give the weapon (the first rune in rite order), "" when none. `sockets` = {rite: rune_id} (`DmRunes.sockets_of`).
static func element_of_runes(sockets: Dictionary) -> String:
	for rite: String in DmRunes.rites():
		var id: String = String(sockets.get(rite, ""))
		if RUNE_ELEMENT.has(id):
			return RUNE_ELEMENT[id]
	return ""


## Dress a weapon prop (its `tip` meta node): scale the tip halo by rarity, add the rarity-coloured outer halo and the element motes. Calling it
## again replaces the previous dressing. Returns the added "GearFx" node (null when there is nothing to show).
static func dress_weapon(prop: Node3D, rarity: String, element: String) -> Node3D:
	var tip: Variant = prop.get_meta("tip") if prop.has_meta("tip") else null
	if not (tip is Node3D):
		return null
	var old := (tip as Node3D).get_node_or_null("GearFx")
	if old != null:
		(tip as Node3D).remove_child(old)
		old.queue_free()
	var look := look_of(rarity)
	if tip is Sprite3D:
		var s := tip as Sprite3D
		if not s.has_meta("fx_base"):
			s.set_meta("fx_base", s.pixel_size)
		s.pixel_size = float(s.get_meta("fx_base")) * float(look.halo)
	var fx := Node3D.new()
	fx.name = "GearFx"
	var rc := rarity_color(rarity)
	if float(look.outer) > 0.0:
		fx.add_child(DmGearProps.glow_sprite(rc.to_rgba32() >> 8, 0.45 * float(look.halo), float(look.outer)))
	var motes := mini(int(look.motes), MAX_MOTES)
	if element != "":
		motes = maxi(motes, 4)   # an element always shows, even on a plain weapon
	if motes > 0 and not _low_quality():
		fx.add_child(_motes(element_color(element) if element != "" else rc, motes))
	if fx.get_child_count() == 0:
		fx.free()
		return null
	(tip as Node3D).add_child(fx)
	return fx


## The aura of a worn set: motes rising around the body in the set's accent colour. Level 1 = 2-3 pieces, 2 = 4+ (more, brighter).
static func build_aura(color: Color, level: int) -> CPUParticles3D:
	var n: int = AURA_MOTES[clampi(level, 0, 2)]
	# CPU-simulated on purpose: GPU-simulated motes are a suspect in the Phase B GPU crashes on the Compatibility renderer (DECISIONS B12).
	var p := CPUParticles3D.new()
	p.name = "SetAura"
	p.amount = maxi(n, 1)
	p.lifetime = 1.7
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-1.5, -0.3, -1.5), Vector3(3.0, 3.6, 3.0))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	p.emission_ring_axis = Vector3.UP
	p.emission_ring_radius = 0.5
	p.emission_ring_inner_radius = 0.35
	p.emission_ring_height = 0.05
	p.direction = Vector3.UP
	p.spread = 8.0
	p.initial_velocity_min = 0.35
	p.initial_velocity_max = 0.7
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	p.color_ramp = _fade_ramp(color, 0.6 if level >= 2 else 0.4)
	p.mesh = _quad(0.09)
	p.material_override = _material()
	p.emitting = n > 0 and not _low_quality()
	return p


static func _low_quality() -> bool:
	var loop := Engine.get_main_loop()
	var vfx: Node = (loop as SceneTree).root.get_node_or_null("Vfx") if loop is SceneTree else null
	return vfx != null and String(vfx.get("quality")) == "low"


static func _motes(color: Color, n: int) -> CPUParticles3D:
	var p := CPUParticles3D.new()   # CPU-simulated: see build_aura
	p.name = "Motes"
	p.amount = n
	p.lifetime = 0.55
	p.local_coords = false   # left behind where the tip was: a swing draws a short streak
	p.visibility_aabb = AABB(Vector3(-2.0, -2.0, -2.0), Vector3(4, 4, 4))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.06
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 0.05
	p.initial_velocity_max = 0.25
	p.gravity = Vector3(0, 0.25, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.1
	p.color_ramp = _fade_ramp(color, 0.9)
	p.mesh = _quad(0.07)
	p.material_override = _material()
	return p


static func _fade_ramp(color: Color, alpha: float) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(color, alpha))
	g.set_color(1, Color(color, 0.0))
	return g


static func _quad(size: float) -> QuadMesh:
	if not _quads.has(size):
		var q := QuadMesh.new()
		q.size = Vector2(size, size)
		_quads[size] = q
	return _quads[size]


static func _material() -> StandardMaterial3D:
	if _mote_mat == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true   # Compatibility reads vertex colours as sRGB, Forward+ as linear: without this the motes come out white blobs ("Graphics presets" in client/next/perf/README.md)
		m.albedo_texture = DmGearProps.glow_texture()
		m.disable_receive_shadows = true
		_mote_mat = m
	return _mote_mat
