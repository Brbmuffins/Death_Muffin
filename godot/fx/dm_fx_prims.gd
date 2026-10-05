class_name DmFxPrims
extends RefCounted
## Port of the procedural half of Effects.ts: particle rings (emit / emit_smoke), pooled transients (decal, flash, orbit, beam),
## projectiles, bone spikes, Bone Mantle orbit shards, Grave Hands fields. Same options, same curves, same caps (160 combat
## transients). Coordinates are the world's (x, z ground plane, y up), exactly as in the web.

const GRAVE_HAND_URL := "res://assets/fx/models/grave_hand.glb"
const BONE_SHARD_URLS := ["res://assets/fx/models/mantle_rib.glb", "res://assets/fx/models/mantle_vertebra.glb", "res://assets/fx/models/mantle_skullchip.glb"]
const DECAL_ORDER := {"friendly": 2, "hero": 3, "danger": 4}

var group: Node3D
var quality := "high"
## Share of each particle burst drawn (the scene lowers it for another player's cast).
var particle_scale := 1.0
## "self" | "other": whose ground effects are drawn (another player's: faint and outline only).
var role := "self"
var emitted := 0

var additive: DmFxRing
var smoke: DmFxRing
var combat_transients := 0

var _caps := DmFxData.caps()
var _transients: Array = []
var _decal_layers: Dictionary = {}
var _sprite_layers: Dictionary = {}
var _beam_layer: DmFxLayer
var _glow_layer: DmFxLayer
var _projectiles: Array = []
var _spikes: Array = []
var _spike_mesh: MultiMeshInstance3D
var _bone_shards: Array = []   # [MultiMeshInstance3D x3] (null until loaded)
var _bone_pre: Array = []
var _bone_orbits: Array = []
var _hand_mesh: MultiMeshInstance3D
var _hand_pre := Transform3D.IDENTITY
var _hand_fields: Array = []
var _own_areas: Array = []
var _danger_depth := 0
var _time := 0.0
var _needle_pool: Array = []
var _orb_pool: Array = []
var _sprite_pool: Array = []
var _needle_mat: StandardMaterial3D
var _needle_mesh: Mesh
var _orb_mesh: SphereMesh


class Tr:
	var t := 0.0
	var duration := 1.0
	var persistent := false
	var layer_item: DmFxLayer.Item
	var layer: DmFxLayer
	var released := false

	func update(_t: float, _k: float, _dt: float) -> void:
		pass

	func release() -> void:
		released = true
		if layer != null and layer_item != null:
			layer.remove(layer_item)


class TrHandle:
	extends DmFxHandle
	var tr: Tr

	func is_alive() -> bool:
		return tr.t < tr.duration

	func kill() -> void:
		tr.t = tr.duration


class GroupHandle:
	extends DmFxHandle
	var handles: Array = []

	func is_alive() -> bool:
		for h in handles:
			if h.is_alive():
				return true
		return false

	func kill() -> void:
		for h in handles:
			h.kill()


class Projectile:
	var mesh: Node3D
	var pool: Array
	var from := Vector3.ZERO
	var to: Callable
	var last_to := Vector3.ZERO
	var speed := 1.0
	var color := Color.WHITE
	var trail := 0.0
	var on_arrive: Callable
	var on_trail: Callable
	var trail_at := 0.0
	var arc := 0.0
	var t := 0.0
	var dist := 0.1
	var kind := "orb"


class ProjectileRef:
	extends RefCounted
	var _p: Projectile
	var _owner: DmFxPrims

	## World position of the shot, or null once it has landed.
	func pos() -> Variant:
		if _owner._projectiles.has(_p):
			return _p.mesh.position
		return null


func _init(parent: Node3D) -> void:
	group = parent
	additive = DmFxRing.new(int(_caps.get("additive_particles", 3500)), DmFxTex.get_tex("glow"), true)
	smoke = DmFxRing.new(int(_caps.get("smoke_particles", 900)), DmFxTex.get_tex("smoke"), false)
	group.add_child(additive.node)
	group.add_child(smoke.node)
	_beam_layer = DmFxLayer.new(group, DmFxLayer.Kind.BEAM, null, true, "quad", 6, null)
	_glow_layer = _sprite_layer(DmFxTex.get_tex("glow"))
	_build_spikes()
	_needle_mat = StandardMaterial3D.new()
	_needle_mat.albedo_color = Color("e8dfcc")
	_needle_mat.emission_enabled = true
	_needle_mat.emission = Color("e9c98f")
	_needle_mat.emission_energy_multiplier = 1.3
	_needle_mat.roughness = 0.5
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.085
	cone.height = 0.95
	cone.radial_segments = 5
	cone.rings = 1
	_needle_mesh = cone
	_orb_mesh = SphereMesh.new()
	_orb_mesh.radius = 0.16
	_orb_mesh.height = 0.32
	_orb_mesh.radial_segments = 10
	_orb_mesh.rings = 8
	_load_props()


# --- budgets / roles ------------------------------------------------------------------------------------------------

func transient_load() -> int:
	return combat_transients


func active_hand_fields() -> int:
	return _hand_fields.size()


## Everything decal()-ed inside `fn` is a danger telegraph: drawn above all friendly ground effects and never faded.
func danger(fn: Callable, when := true) -> Variant:
	if not when:
		return fn.call()
	_danger_depth += 1
	var r: Variant = fn.call()
	_danger_depth -= 1
	return r


func dims_binbun() -> bool:
	return role == "other" and _danger_depth == 0


## `o` as a partner's Binbun spawn: dimmed and smaller while a partner's event is handled, untouched otherwise.
func partner_binbun(o: Dictionary) -> Dictionary:
	if not dims_binbun():
		return o
	var r := o.duplicate()
	r["alpha"] = float(o.get("alpha", 1.0)) * float(_caps.get("other_binbun_alpha", 0.35))
	r["scale"] = float(o.get("scale", 1.0)) * float(_caps.get("other_binbun_scale", 0.75))
	return r


func _scaled(o: Dictionary) -> Dictionary:
	var k := particle_scale * (float(_caps.get("low_particle_scale", 0.75)) if quality == "low" else 1.0)
	var count := int(o.get("count", 0))
	if k >= 1.0 or count <= 0:
		return o
	var r := o.duplicate()
	r["count"] = maxi(1, DmMath.js_round(float(count) * k))
	return r


func emit(o: Dictionary) -> void:
	o = _scaled(o)
	emitted += int(o.get("count", 0))
	additive.emit(o)


func emit_smoke(o: Dictionary) -> void:
	o = _scaled(o)
	emitted += int(o.get("count", 0))
	smoke.emit(o)


# --- transients -----------------------------------------------------------------------------------------------------

func _add(tr: Tr) -> DmFxHandle:
	if not tr.persistent and combat_transients >= int(_caps.get("combat_transients", 160)):
		for i in _transients.size():
			if not _transients[i].persistent:
				var old: Tr = _transients[i]
				_transients.remove_at(i)
				combat_transients -= 1
				old.t = old.duration
				old.release()
				break
	tr.update(tr.t, tr.t / tr.duration, 0.0)
	_transients.append(tr)
	if not tr.persistent:
		combat_transients += 1
	var h := TrHandle.new()
	h.tr = tr
	return h


func _outline_of(tex_name: String) -> Variant:
	match tex_name:
		"disc":
			return {"edge": 0.86, "floor": 0.0}
		"sigil":
			return {"edge": 0.8, "floor": 0.0}
		"cracks":
			return {"edge": 2.0, "floor": 0.25}
		"glow":
			return {"edge": 2.0, "floor": 0.12}
	return null


func _footprint_of(tex_name: String) -> String:
	if tex_name == "ring":
		return "ring"
	return "disc" if tex_name in ["disc", "glow", "sigil", "cracks"] else "quad"


## Loading screen (DmWarmup): one short decal per texture x blend x order, and one flash per texture, at `at`, so every decal/sprite
## layer and its material exists and is drawn (compiled) before the first fight instead of on the first wave's cracks and rings.
func warm_layers(at: Vector3) -> Array:
	# Long-lived on purpose: warm-up frames take seconds while shaders compile, and a short decal expired before it was ever drawn.
	# The caller kills the returned handles when the loading screen ends.
	var out: Array = []
	var names: Array = DmFxTex.PROCEDURAL.duplicate()
	names.append_array(DmFxTex.IMAGES.keys())
	for nm in names:
		for blend in ["add", "mix"]:
			for kind in ["friendly", "hero", "danger"]:
				out.append(decal({"tex": nm, "x": at.x, "z": at.z, "r": 1.0, "duration": 600.0, "opacity": 0.5, "blending": blend, "danger": kind == "danger", "hero": kind == "hero"}))
		out.append(flash({"tex": nm, "x": at.x, "y": at.y + 1.0, "z": at.z, "size": 1.0, "duration": 600.0}))
	emit({"x": at.x, "y": at.y + 1.0, "z": at.z, "count": 4, "color": 0xffffff, "life": 30.0})
	emit_smoke({"x": at.x, "y": at.y + 1.0, "z": at.z, "count": 4, "color": 0x888888, "life": 30.0})
	return out


func _decal_layer(tex: Texture2D, additive_blend: bool, order: int, outline: Variant) -> DmFxLayer:
	var tname := DmFxTex.name_of(tex)
	var key := "%s|%s|%d" % [tname, additive_blend, order]
	var l: DmFxLayer = _decal_layers.get(key)
	if l == null:
		l = DmFxLayer.new(group, DmFxLayer.Kind.DECAL, tex, additive_blend, _footprint_of(tname), order, outline)
		_decal_layers[key] = l
	return l


func _sprite_layer(tex: Texture2D) -> DmFxLayer:
	var key := DmFxTex.name_of(tex)
	var l: DmFxLayer = _sprite_layers.get(key)
	if l == null:
		l = DmFxLayer.new(group, DmFxLayer.Kind.SPRITE, tex, true, "disc" if key == "glow" else "quad", 6, null)
		_sprite_layers[key] = l
	return l


## three.js Color.getHSL / setHSL work in the (linear) working space; the same maths on a linear colour.
static func _hsl(c: Color) -> Vector3:
	var mx := maxf(c.r, maxf(c.g, c.b))
	var mn := minf(c.r, minf(c.g, c.b))
	var l := (mx + mn) / 2.0
	var h := 0.0
	var s := 0.0
	if mx != mn:
		var d := mx - mn
		s = d / (mx + mn) if l <= 0.5 else d / (2.0 - mx - mn)
		if mx == c.r:
			h = (c.g - c.b) / d + (6.0 if c.g < c.b else 0.0)
		elif mx == c.g:
			h = (c.b - c.r) / d + 2.0
		else:
			h = (c.r - c.g) / d + 4.0
		h /= 6.0
	return Vector3(h, s, l)


static func _hue_to_rgb(p: float, q: float, t: float) -> float:
	if t < 0.0:
		t += 1.0
	if t > 1.0:
		t -= 1.0
	if t < 1.0 / 6.0:
		return p + (q - p) * 6.0 * t
	if t < 0.5:
		return q
	if t < 2.0 / 3.0:
		return p + (q - p) * 6.0 * (2.0 / 3.0 - t)
	return p


static func _from_hsl(h: float, s: float, l: float) -> Color:
	if s == 0.0:
		return Color(l, l, l)
	var q := l * (1.0 + s) if l <= 0.5 else l + s - l * s
	var p := 2.0 * l - q
	return Color(_hue_to_rgb(p, q, h + 1.0 / 3.0), _hue_to_rgb(p, q, h), _hue_to_rgb(p, q, h - 1.0 / 3.0))


class DecalTr:
	extends Tr
	var o: Dictionary
	var d: DmFxLayer.Item
	var ring_item: DmFxLayer.Item
	var ring_layer: DmFxLayer
	var owner: DmFxPrims
	var via_ring := false
	var other := false
	var settles := false
	var outline: Variant
	var base := 1.0
	var fade_in := 0.12
	var fade_out := 0.25
	var anchor := 0.0
	var hidden := false
	var outline_at := 0.6
	var outline_fade := 0.7
	var t_now := 0.0
	var ended := false
	var entry: Dictionary
	var ring_for_disc := 1.32

	func place() -> void:
		var f: Variant = null
		if o.has("follow") and (o["follow"] as Callable).is_valid():
			f = (o["follow"] as Callable).call()
		hidden = o.has("follow") and f == null
		var x := float(o.get("x", 0.0))
		var z := float(o.get("z", 0.0))
		if f is Vector3:
			x = f.x
			z = f.z
		var rot := float(o.get("rot", 0.0))
		d.x = x + sin(rot) * anchor * float(o["r"])
		d.y = float(o.get("y", 0.04))
		d.z = z + cos(rot) * anchor * float(o["r"])

	func release() -> void:
		ended = true
		if not entry.is_empty():
			entry["alive"] = false
		layer.remove(d)
		if ring_item != null:
			ring_layer.remove(ring_item)
		released = true

	func update(t_: float, k: float, _dt: float) -> void:
		if t_ < 0.0:
			d.opacity = 0.0
			return
		t_now = t_
		if ended:
			return
		if o.has("follow"):
			place()
		var grow := 1.0
		if o.has("growFrom"):
			grow = float(o["growFrom"]) + (1.0 - float(o["growFrom"])) * minf(1.0, k * 1.2)
		var s := float(o["r"]) * 2.0 * grow
		d.sx = s * float(o.get("sx", 1.0))
		d.sz = s * float(o.get("sz", 1.0))
		var rs := ring_for_disc if (via_ring and other) else 1.0
		if rs != 1.0:
			d.sx *= rs
			d.sz *= rs
		if o.has("spin") and float(o["spin"]) != 0.0:
			d.rot_y = float(o.get("rot", 0.0)) + float(o["spin"]) * t_
		var in_a := minf(1.0, t_ / fade_in) if fade_in > 0.0 else 1.0
		var out_a := minf(1.0, (duration - t_) / fade_out) if fade_out > 0.0 else 1.0
		var pulse := 1.0
		if o.has("pulse") and float(o["pulse"]) != 0.0:
			pulse = 0.75 + 0.25 * sin(t_ * float(o["pulse"]))
		var op := 0.0 if hidden else base * maxf(0.0, minf(in_a, out_a)) * pulse
		if other and outline != null:
			d.rim = 1.0
		elif settles:
			var rim := maxf(0.0, minf(1.0, (t_ - outline_at) / outline_fade))
			d.rim = rim
			if not (o.has("pulse") and float(o["pulse"]) != 0.0) and rim > 0.0:
				pulse *= 1.0 - 0.18 * rim * (0.5 + 0.5 * sin(t_ * 2.2 + float(o.get("x", 0.0))))
			op = 0.0 if hidden else base * maxf(0.0, minf(in_a, out_a)) * pulse
			if rim > 0.0 and via_ring:
				if ring_item == null:
					ring_layer = owner._decal_layer(DmFxTex.get_tex("ring"), true, DECAL_ORDER["friendly"], null)
					ring_item = DmFxLayer.Item.new()
					ring_item.x = d.x
					ring_item.y = d.y
					ring_item.z = d.z
					ring_item.color = d.color
					ring_layer.add(ring_item)
				ring_item.x = d.x
				ring_item.y = d.y
				ring_item.z = d.z
				ring_item.sx = d.sx * ring_for_disc
				ring_item.sz = d.sz * ring_for_disc
				ring_item.opacity = op * rim
				d.opacity = op * (1.0 - rim)
				return
		d.opacity = op

	func force_outline() -> void:
		outline_at = minf(outline_at, t_now)
		outline_fade = minf(outline_fade, 0.4)


## o: tex (Texture2D or name), color, x, z, r, y, rot, duration, opacity, fadeIn, fadeOut, growFrom, spin, blending ("add"|"mix"),
## sx, sz, anchor, follow (Callable -> Vector3|null), pulse, delay, persistent, danger, hero, other.
func decal(o: Dictionary) -> DmFxHandle:
	var tex: Texture2D = null
	var tv: Variant = o.get("tex", "disc")
	tex = DmFxTex.get_tex(tv) if tv is String else tv as Texture2D
	var tname := DmFxTex.name_of(tex)
	var additive_blend: bool = String(o.get("blending", "add")) == "add"
	var danger_ := bool(o.get("danger", false)) or _danger_depth > 0
	var hero := (not danger_) and bool(o.get("hero", false))
	var order: int = DECAL_ORDER["danger"] if danger_ else (DECAL_ORDER["hero"] if (hero and not additive_blend) else DECAL_ORDER["friendly"])
	var outline: Variant = _outline_of(tname)
	var other := (role == "other" or bool(o.get("other", false))) and not danger_ and not bool(o.get("persistent", false)) and not hero
	var via_ring := outline != null and tname == "disc"
	var layer: DmFxLayer
	if via_ring and other:
		layer = _decal_layer(DmFxTex.get_tex("ring"), additive_blend, order, null)
	else:
		layer = _decal_layer(tex, additive_blend, order, outline)
	var tr := DecalTr.new()
	tr.o = o
	tr.owner = self
	tr.layer = layer
	tr.d = DmFxLayer.Item.new()
	tr.layer_item = tr.d
	tr.d.rot_y = float(o.get("rot", 0.0))
	var col := DmFxData.to_color(o.get("color", Color.WHITE))
	tr.d.color = col
	layer.add(tr.d)
	if other:
		var hsl := _hsl(col)
		if hsl.y > 0.08 and hsl.z > 0.55:
			tr.d.color = _from_hsl(hsl.x, maxf(hsl.y, 0.6), 0.5)
	tr.via_ring = via_ring
	tr.other = other
	tr.outline = outline
	tr.ring_for_disc = float(_caps.get("ring_for_disc", 1.32))
	var dur := float(o["duration"])
	tr.duration = dur
	tr.settles = (not danger_) and (not other) and (not bool(o.get("persistent", false))) and (not hero) and outline != null and dur > float(_caps.get("long_decal_s", 1.5))
	tr.base = float(o.get("opacity", 1.0)) * (float(_caps.get("other_decal_alpha", 0.28)) if other else 1.0)
	tr.fade_in = float(o.get("fadeIn", 0.12))
	tr.fade_out = float(o.get("fadeOut", 0.25))
	tr.anchor = float(o.get("anchor", 0.0))
	tr.outline_at = float(_caps.get("outline_after_s", 0.6))
	tr.outline_fade = float(_caps.get("outline_fade_s", 0.7))
	tr.persistent = bool(o.get("persistent", false))
	tr.place()
	if tr.settles:
		var r := float(o["r"])
		_own_areas = _own_areas.filter(func(a): return a["alive"])
		for a in _own_areas:
			if a["tex"] == tname and Vector2(a["x"] - tr.d.x, a["z"] - tr.d.z).length() < maxf(a["r"], r):
				(a["tr"] as DecalTr).force_outline()
		tr.entry = {"tex": tname, "x": tr.d.x, "z": tr.d.z, "r": r, "alive": true, "tr": tr}
		_own_areas.append(tr.entry)
	tr.t = -float(o.get("delay", 0.0))
	return _add(tr)


class FlashTr:
	extends Tr
	var o: Dictionary
	var s: DmFxLayer.Item

	func update(_t: float, k: float, _dt: float) -> void:
		s.sx = float(o["size"]) * (0.35 + 0.65 * sin(minf(1.0, k * 1.4) * PI * 0.5))
		if o.has("rise") and float(o["rise"]) != 0.0:
			s.y = float(o["y"]) + float(o["rise"]) * k
		s.opacity = float(o.get("opacity", 1.0)) * (1.0 if k < 0.3 else 1.0 - (k - 0.3) / 0.7)


## A short-lived tinted billboard; `rise` lifts it that many units over its life. o: x y z color size duration tex rise opacity.
func flash(o: Dictionary) -> DmFxHandle:
	var tv: Variant = o.get("tex", "glow")
	var tex: Texture2D = DmFxTex.get_tex(tv) if tv is String else tv as Texture2D
	var layer := _sprite_layer(tex)
	var tr := FlashTr.new()
	tr.o = o
	tr.s = DmFxLayer.Item.new()
	tr.s.x = float(o["x"])
	tr.s.y = float(o["y"])
	tr.s.z = float(o["z"])
	tr.s.color = DmFxData.to_color(o.get("color", Color.WHITE))
	tr.layer = layer
	tr.layer_item = tr.s
	layer.add(tr.s)
	tr.duration = float(o["duration"])
	return _add(tr)


class OrbitTr:
	extends Tr
	var o: Dictionary
	var s: DmFxLayer.Item
	var phase := 0.0
	var lift := 0.0
	var cx := 0.0
	var cz := 0.0
	var shared: Array  # [cx, cz] shared among the orbit's sprites

	func update(t_: float, _k: float, _dt: float) -> void:
		var f: Variant = (o["follow"] as Callable).call()
		if f is Vector3:
			shared[0] = f.x
			shared[1] = f.z
		var a := phase + t_ * float(o["speed"])
		var r := float(o["radius"]) * minf(1.0, 0.25 + t_ * 3.0)
		s.x = shared[0] + cos(a) * r
		s.y = float(o["y"]) + lift + sin(t_ * 3.1 + phase) * 0.12
		s.z = shared[1] + sin(a) * r
		s.rot_y = a * 1.7
		s.opacity = maxf(0.0, minf(1.0, minf(t_ / 0.15, (duration - t_) / 0.35)))


## Tinted sprites circling a moving point (Bone Mantle's shards). o: tex color count radius y size duration speed follow.
func orbit(o: Dictionary) -> DmFxHandle:
	var tv: Variant = o.get("tex", "glow")
	var tex: Texture2D = DmFxTex.get_tex(tv) if tv is String else tv as Texture2D
	var shared := [0.0, 0.0]
	var first: Variant = (o["follow"] as Callable).call()
	if first is Vector3:
		shared = [first.x, first.z]
	var layer := _sprite_layer(tex)
	var gh := GroupHandle.new()
	var count := int(o["count"])
	var col := DmFxData.to_color(o.get("color", Color.WHITE))
	for i in count:
		var tr := OrbitTr.new()
		tr.o = o
		tr.shared = shared
		tr.s = DmFxLayer.Item.new()
		tr.s.x = shared[0]
		tr.s.y = float(o["y"])
		tr.s.z = shared[1]
		tr.s.sx = float(o["size"])
		tr.s.color = col
		tr.layer = layer
		tr.layer_item = tr.s
		layer.add(tr.s)
		tr.phase = float(i) / float(count) * TAU
		tr.lift = float(i % 3) * 0.28
		tr.duration = float(o["duration"])
		gh.handles.append(_add(tr))
	return gh


class BeamTr:
	extends Tr
	var b: DmFxLayer.Item
	var a_src: Variant
	var b_src: Callable
	var width := 0.1

	func update(t_: float, k: float, _dt: float) -> void:
		var end: Variant = b_src.call()
		var start: Variant = (a_src as Callable).call() if a_src is Callable else a_src
		if not (end is Vector3) or not (start is Vector3):
			b.opacity = 0.0
			return
		var e: Vector3 = end
		var s: Vector3 = start
		b.x = (s.x + e.x) / 2.0
		b.y = (s.y + e.y) / 2.0
		b.z = (s.z + e.z) / 2.0
		b.tx = e.x
		b.ty = e.y
		b.tz = e.z
		b.sz = s.distance_to(e)
		b.sx = width * (0.7 + 0.3 * sin(t_ * 30.0))
		b.opacity = minf(1.0, (1.0 - k) * 2.0)


## Glowing tether from A to B (litany tethers, deacon raise beams). `a` is a Vector3 or a Callable -> Vector3|null; `b` a Callable.
func beam(a: Variant, b: Callable, color: Variant, width: float, duration: float) -> DmFxHandle:
	var tr := BeamTr.new()
	tr.b = DmFxLayer.Item.new()
	tr.b.color = DmFxData.to_color(color)
	tr.b.sx = width
	tr.b.sz = 1.0
	tr.a_src = a
	tr.b_src = b
	tr.width = width
	tr.layer = _beam_layer
	tr.layer_item = tr.b
	_beam_layer.add(tr.b)
	tr.duration = duration
	return _add(tr)


# --- projectiles ----------------------------------------------------------------------------------------------------

## o: from (Vector3), to (Callable -> Vector3|null), speed, color, kind ("needle"|"orb"|"sprite"), tex, size, arc, on_arrive
## (Callable(Vector3)), on_trail (Callable(Vector3), ~every 70 ms). Returns a ref whose pos() is null once landed.
func projectile(o: Dictionary) -> ProjectileRef:
	var kind := String(o.get("kind", "orb"))
	var from: Vector3 = o["from"]
	var mesh: Node3D
	var pool: Array
	var col := DmFxData.to_color(o.get("color", Color.WHITE))
	if kind == "sprite":
		var holder: MeshInstance3D = _sprite_pool.pop_back() if not _sprite_pool.is_empty() else _new_sprite_shot()
		var size := float(o.get("size", 0.8))
		var tv: Variant = o.get("tex", "glow")
		var tex: Texture2D = DmFxTex.get_tex(tv) if tv is String else tv as Texture2D
		var m := holder.material_override as ShaderMaterial
		m.set_shader_parameter("tex", tex)
		m.set_shader_parameter("tint", col)
		holder.scale = Vector3(size, size, size)
		mesh = holder
		pool = _sprite_pool
	elif kind == "needle":
		mesh = _needle_pool.pop_back() if not _needle_pool.is_empty() else _new_needle()
		pool = _needle_pool
	else:
		var orb: MeshInstance3D = _orb_pool.pop_back() if not _orb_pool.is_empty() else _new_orb()
		(orb.material_override as StandardMaterial3D).albedo_color = col
		mesh = orb
		pool = _orb_pool
	mesh.visible = true
	mesh.position = from
	group.add_child(mesh)
	var first: Variant = (o["to"] as Callable).call()
	var rec := Projectile.new()
	rec.mesh = mesh
	rec.pool = pool
	rec.from = from
	rec.to = o["to"]
	rec.last_to = first if first is Vector3 else from
	rec.speed = float(o["speed"])
	rec.color = col
	rec.on_arrive = o.get("on_arrive", Callable())
	rec.on_trail = o.get("on_trail", Callable())
	rec.arc = float(o.get("arc", 0.0))
	rec.kind = kind
	rec.dist = maxf(0.1, rec.last_to.distance_to(from))
	_projectiles.append(rec)
	var ref := ProjectileRef.new()
	ref._p = rec
	ref._owner = self
	return ref


func _new_needle() -> Node3D:
	var holder := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _needle_mesh
	mi.material_override = _needle_mat
	mi.rotation = Vector3(-PI / 2.0, 0.0, 0.0)  # cone tip along -Z; look_at aims -Z at the target
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mi)
	return holder


func _new_orb() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _orb_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.no_depth_test = false
	m.disable_fog = true
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


const _SPRITE_SHOT := """
shader_type spatial;
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear;
uniform vec4 tint : source_color = vec4(1.0);
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = tint.rgb * t.rgb;
	ALPHA = t.a;
}
"""
static var _sprite_shot_shader: Shader


func _new_sprite_shot() -> MeshInstance3D:
	if _sprite_shot_shader == null:
		_sprite_shot_shader = Shader.new()
		_sprite_shot_shader.code = _SPRITE_SHOT
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mi.mesh = q
	var m := ShaderMaterial.new()
	m.shader = _sprite_shot_shader
	m.render_priority = 6
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# --- spikes ---------------------------------------------------------------------------------------------------------

func _build_spikes() -> void:
	# ConeGeometry(0.2, 1, 4) translated up 0.5: base at the origin, tip at y = 1.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base: Array[Vector3] = []
	for i in 4:
		var a := float(i) / 4.0 * TAU
		base.append(Vector3(cos(a) * 0.2, 0.0, sin(a) * 0.2))
	var tip := Vector3(0, 1, 0)
	for i in 4:
		var b0 := base[i]
		var b1 := base[(i + 1) % 4]
		st.add_vertex(b0)
		st.add_vertex(tip)
		st.add_vertex(b1)
		st.add_vertex(Vector3.ZERO)
		st.add_vertex(b0)
		st.add_vertex(b1)
	st.generate_normals()
	var mesh := st.commit()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 320
	mm.visible_instance_count = 0
	_spike_mesh = MultiMeshInstance3D.new()
	_spike_mesh.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("c9b99a")
	mat.roughness = 0.85
	mat.metallic = 0.0
	mat.emission_enabled = true
	mat.emission = Color("3a0e10")
	mat.emission_energy_multiplier = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_spike_mesh.material_override = mat
	_spike_mesh.custom_aabb = AABB(Vector3(-500, -10, -500), Vector3(1000, 50, 1000))
	group.add_child(_spike_mesh)


## Bone Prison: a ring of bone spikes bursting up around a point, leaning inward like a cage.
func spike_ring(x: float, z: float, r: float, count: int, life := 1.9) -> void:
	for i in count:
		var a := float(i) / float(count) * TAU + randf() * 0.2
		_spikes.append({
			"x": x + sin(a) * r, "z": z + cos(a) * r, "yaw": a + PI / 2.0, "tilt": -0.35 - randf() * 0.15,
			"h": 0.75 + randf() * 0.45, "born": _time + float(i) * 0.012, "life": life,
		})
	if _spikes.size() > 300:
		_spikes = _spikes.slice(_spikes.size() - 300)


## A line of bone spikes erupting sequentially (Marrow Spear).
func spike_line(x: float, z: float, dir_x: float, dir_z: float, length: float, width: float, sequential := true) -> void:
	var yaw := atan2(dir_x, dir_z)
	var n := DmMath.js_round(length / 0.55)
	for i in n:
		var d := 0.8 + float(i) * 0.55
		for j in 2:
			var side := (randf() - 0.5) * width
			_spikes.append({
				"x": x + dir_x * d + cos(yaw) * side, "z": z + dir_z * d - sin(yaw) * side, "yaw": randf() * PI,
				"tilt": (randf() - 0.5) * 0.7, "h": 0.8 + randf() * 0.9 + float(i) / float(n) * 0.4,
				"born": _time + (float(i) * 0.018 if sequential else 0.0), "life": 0.7,
			})
	if _spikes.size() > 300:
		_spikes = _spikes.slice(_spikes.size() - 300)


func _update_spikes() -> void:
	var mm := _spike_mesh.multimesh
	var n := 0
	for i in range(_spikes.size() - 1, -1, -1):
		var s: Dictionary = _spikes[i]
		var age := _time - float(s["born"])
		if age > float(s["life"]):
			_spikes.remove_at(i)
			continue
		if age < 0.0:
			continue
		if n >= 320:
			continue
		var life := float(s["life"])
		var rise := age / 0.08 if age < 0.08 else ((life - age) / 0.25 if age > life - 0.25 else 1.0)
		var b := Basis.from_euler(Vector3(float(s["tilt"]), float(s["yaw"]), float(s["tilt"]) * 0.5), EULER_ORDER_XYZ)
		b = b.scaled_local(Vector3(1.0, maxf(0.01, float(s["h"]) * rise), 1.0))
		mm.set_instance_transform(n, Transform3D(b, Vector3(float(s["x"]), -0.1, float(s["z"]))))
		n += 1
	mm.visible_instance_count = n


# --- props: bone shards (mantle), grave hands ---------------------------------------------------------------------

func _load_props() -> void:
	# instancedProp(): node transform baked, fitted to a unit box (centred, or base at y = 0), matte, faintly warm.
	for i in BONE_SHARD_URLS.size():
		var inst: Variant = _instanced_prop(BONE_SHARD_URLS[i], int(_caps.get("bone_shard_cap", 96)), false, 0.6)
		_bone_shards.append(inst[0] if inst != null else null)
		_bone_pre.append(inst[1] if inst != null else Transform3D.IDENTITY)
	var h: Variant = _instanced_prop(GRAVE_HAND_URL, int(_caps.get("grave_hand_cap", 64)), true, 1.1)
	if h != null:
		_hand_mesh = h[0]
		_hand_pre = h[1]


func _instanced_prop(url: String, cap: int, base: bool, emissive: float) -> Variant:
	if not ResourceLoader.exists(url):
		return null
	var scene := load(url) as PackedScene
	if scene == null:
		return null
	var root := scene.instantiate()
	var src: MeshInstance3D = null
	var stack: Array = [root]
	while not stack.is_empty() and src == null:
		var n: Node = stack.pop_front()
		if n is MeshInstance3D:
			src = n
		else:
			stack.append_array(n.get_children())
	if src == null:
		root.free()
		return null
	# World transform of the mesh node within its scene.
	var world := Transform3D.IDENTITY
	var cur: Node = src
	while cur != null and cur != root:
		world = (cur as Node3D).transform * world
		cur = cur.get_parent()
	var aabb := world * src.mesh.get_aabb()
	var c := aabb.get_center()
	var size := aabb.size
	var k := 1.0 / maxf(size.y if base else maxf(size.x, maxf(size.y, size.z)), 1e-4)
	var shift := Vector3(-c.x, -aabb.position.y if base else -c.y, -c.z)
	var pre := Transform3D(Basis.IDENTITY.scaled(Vector3(k, k, k)), Vector3.ZERO) * Transform3D(Basis.IDENTITY, shift) * world
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = src.mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat: StandardMaterial3D = null
	var sm: Material = src.mesh.surface_get_material(0) if src.mesh.get_surface_count() > 0 else null
	if sm is StandardMaterial3D:
		mat = (sm as StandardMaterial3D).duplicate()
	else:
		mat = StandardMaterial3D.new()
	mat.metallic = 0.02
	mat.roughness = 0.85
	mat.emission_enabled = true
	mat.emission = Color("2a2118")
	mat.emission_energy_multiplier = emissive
	mmi.material_override = mat
	mmi.custom_aabb = AABB(Vector3(-500, -10, -500), Vector3(1000, 50, 1000))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.add_child(mmi)
	root.free()
	return [mmi, pre]


## Grave Hands: skeletal hands claw up out of the field, grasp, and sink. Falls back to short bone spikes until the prop loaded.
func grave_hands(x: float, z: float, r: float, count: int, duration: float) -> DmFxHandle:
	if _hand_mesh == null:
		for i in mini(count, 12):
			var a := randf() * TAU
			var d := sqrt(randf()) * r
			_spikes.append({"x": x + sin(a) * d, "z": z + cos(a) * d, "yaw": randf() * 3.0, "tilt": (randf() - 0.5) * 0.5, "h": 0.6, "born": _time + float(i) * 0.05, "life": duration})
		return DmFxHandle.new()
	var field := {"x": x, "z": z, "r": r, "count": mini(count, int(_caps.get("grave_hand_cap", 64))), "duration": duration, "t": 0.0, "seed": randf() * 100.0}
	_hand_fields.append(field)
	var h := FieldHandle.new()
	h.field = field
	return h


class FieldHandle:
	extends DmFxHandle
	var field: Dictionary

	func is_alive() -> bool:
		return float(field["t"]) < float(field["duration"])

	func kill() -> void:
		field["t"] = maxf(float(field["t"]), float(field["duration"]) - 0.3)


func _update_hands(dt: float) -> void:
	if _hand_mesh == null:
		return
	var mm := _hand_mesh.multimesh
	var cap := mm.instance_count
	var n := 0
	for k in range(_hand_fields.size() - 1, -1, -1):
		var f: Dictionary = _hand_fields[k]
		f["t"] = float(f["t"]) + dt
		if float(f["t"]) >= float(f["duration"]):
			_hand_fields.remove_at(k)
			continue
		var cnt := int(f["count"])
		for i in cnt:
			if n >= cap:
				break
			var a := float(i) * 2.39996 + float(f["seed"])
			var dist := float(f["r"]) * sqrt((float(i) + 0.5) / float(cnt)) * 0.92
			var born := float(i % 6) * 0.07
			var age := float(f["t"]) - born
			if age <= 0.0:
				continue
			var rise := minf(1.0, age / 0.25) * minf(1.0, (float(f["duration"]) - float(f["t"])) / 0.35)
			var grasp := sin(age * 5.0 + float(i)) * 0.18
			var pos := Vector3(float(f["x"]) + sin(a) * dist, -0.75 * (1.0 - rise), float(f["z"]) + cos(a) * dist)
			var b := Basis.from_euler(Vector3(grasp + 0.12 * sin(float(i)), a * 1.7, grasp * 0.6), EULER_ORDER_XYZ)
			b = b.scaled(Vector3.ONE * (0.95 + float(i % 3) * 0.12))
			mm.set_instance_transform(n, Transform3D(b, pos) * _hand_pre)
			n += 1
	mm.visible_instance_count = n


## Bone Mantle's orbit: real bone fragments tumbling around a moving point; falls back to the sprite orbit until loaded.
## o: count radius y size duration speed follow fallbackTex fallbackColor funnel.
func bone_orbit(o: Dictionary) -> DmFxHandle:
	if _bone_shards.is_empty() or _bone_shards.has(null):
		var o2 := o.duplicate()
		o2["tex"] = o.get("fallbackTex", "glow")
		o2["color"] = o.get("fallbackColor", Color.WHITE)
		return orbit(o2)
	var first: Variant = (o["follow"] as Callable).call()
	var orb := {
		"count": int(o["count"]), "radius": float(o["radius"]), "y": float(o["y"]), "size": float(o["size"]), "duration": float(o["duration"]),
		"speed": float(o["speed"]), "follow": o["follow"], "t": 0.0, "cx": first.x if first is Vector3 else 0.0,
		"cz": first.z if first is Vector3 else 0.0, "seed": randf() * 100.0, "funnel": bool(o.get("funnel", false)),
	}
	_bone_orbits.append(orb)
	var h := FieldHandle.new()
	h.field = orb
	return h


func _update_bone_orbits(dt: float) -> void:
	if _bone_shards.is_empty() or _bone_shards.has(null):
		return
	var cap := int(_caps.get("bone_shard_cap", 96))
	var n := [0, 0, 0]
	for k in range(_bone_orbits.size() - 1, -1, -1):
		var o: Dictionary = _bone_orbits[k]
		o["t"] = float(o["t"]) + dt
		var t := float(o["t"])
		if t >= float(o["duration"]):
			_bone_orbits.remove_at(k)
			continue
		var f: Variant = (o["follow"] as Callable).call()
		if f is Vector3:
			o["cx"] = f.x
			o["cz"] = f.z
		var r := float(o["radius"]) * minf(1.0, 0.25 + t * 3.0)
		var grow := maxf(0.0, minf(1.0, minf(t / 0.15, (float(o["duration"]) - t) / 0.35)))
		var funnel: bool = o["funnel"]
		var count := int(o["count"])
		for i in count:
			var type := i % 3
			if n[type] >= cap:
				continue
			var phase := float(i) / float(count) * TAU
			var s := float(o["seed"]) + float(i) * 1.7
			var tier := float(i % 5) / 4.0 if funnel else 0.0
			var a := phase * (2.3 if funnel else 1.0) + t * float(o["speed"]) * ((1.4 - tier * 0.6) if funnel else 1.0)
			var rr := r * (0.35 + tier * 0.75) if funnel else r
			var y := (float(o["y"]) + tier * 2.1) if funnel else (float(o["y"]) + float(i % 3) * 0.28)
			var pos := Vector3(float(o["cx"]) + cos(a) * rr, y + sin(t * 3.1 + phase) * 0.12, float(o["cz"]) + sin(a) * rr)
			var b := Basis.from_euler(Vector3(s + t * (1.3 + float(i % 4) * 0.4), -a, s * 0.7 + t * 0.9), EULER_ORDER_XYZ)
			b = b.scaled(Vector3.ONE * (float(o["size"]) * (1.15 if type == 0 else 0.8) * grow))
			var mm: MultiMesh = (_bone_shards[type] as MultiMeshInstance3D).multimesh
			mm.set_instance_transform(n[type], Transform3D(b, pos) * (_bone_pre[type] as Transform3D))
			n[type] += 1
	for i in 3:
		(_bone_shards[i] as MultiMeshInstance3D).multimesh.visible_instance_count = n[i]


# --- frame ----------------------------------------------------------------------------------------------------------

func update(dt: float, real_dt: float) -> void:
	_time += dt
	additive.update(dt)
	smoke.update(dt)
	for i in range(_transients.size() - 1, -1, -1):
		var tr: Tr = _transients[i]
		tr.t += dt
		if tr.t >= tr.duration:
			tr.release()
			_transients.remove_at(i)
			if not tr.persistent:
				combat_transients -= 1
			continue
		tr.update(tr.t, tr.t / tr.duration, dt)
	for key in _decal_layers.keys():
		var l: DmFxLayer = _decal_layers[key]
		l.flush()
		# Idle layers are kept (hidden while empty, see DmFxLayer.flush): disposing them after 5 s idle meant the next wave
		# rebuilt each one (new MultiMesh + material) on its first frame, undoing the loading-screen warm-up.
	for key in _sprite_layers.keys():
		var l2: DmFxLayer = _sprite_layers[key]
		l2.flush()

	_beam_layer.flush()
	_update_projectiles(dt)
	_update_spikes()
	_update_bone_orbits(dt)
	_update_hands(dt)


func _update_projectiles(dt: float) -> void:
	for i in range(_projectiles.size() - 1, -1, -1):
		var p: Projectile = _projectiles[i]
		var target: Variant = p.to.call()
		if target is Vector3:
			p.last_to = target
		var pos := p.mesh.position
		var to_vec := p.last_to - pos
		var d := to_vec.length()
		var step := p.speed * dt
		p.t += dt
		var arc_progress := minf(1.0, p.t * p.speed / p.dist)
		if (arc_progress >= 1.0 if p.arc != 0.0 else d <= step) or p.t > 3.0:
			p.mesh.position = p.last_to
			group.remove_child(p.mesh)
			if p.pool.size() < 64:
				p.pool.append(p.mesh)
			else:
				p.mesh.queue_free()
			_projectiles.remove_at(i)
			if p.on_arrive.is_valid():
				p.on_arrive.call(p.last_to)
			continue
		if p.arc != 0.0:
			var np := p.from.lerp(p.last_to, arc_progress)
			np.y += sin(arc_progress * PI) * p.arc * 0.1
			p.mesh.position = np
		else:
			p.mesh.position = pos + to_vec * (step / maxf(0.001, d))
		if p.kind != "sprite" and (p.last_to - p.mesh.position).length_squared() > 1e-8:
			var dir := (p.last_to - p.mesh.position).normalized()
			var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.999 else Vector3.RIGHT
			p.mesh.look_at_from_position(p.mesh.position, p.last_to, up)
		p.trail += dt
		if p.trail > 0.024:
			p.trail = 0.0
			var mp := p.mesh.position
			additive.emit({"x": mp.x, "y": mp.y, "z": mp.z, "count": 1, "color": p.color, "spread": 0.05, "speed": 0.15, "up": 0.1, "life": 0.28, "size": 0.32})
		if p.on_trail.is_valid() and p.t - p.trail_at >= 0.07:
			p.trail_at = p.t
			p.on_trail.call(p.mesh.position)


## Drop every transient (decals, flashes, orbits...) now, including persistent/hero ones. Their `follow` closures may capture a
## game that is about to be freed.
func clear() -> void:
	for tr in _transients:
		tr.release()
	_transients.clear()
	combat_transients = 0


func dispose() -> void:
	for l in _decal_layers.values():
		l.dispose()
	for l in _sprite_layers.values():
		l.dispose()
	_beam_layer.dispose()
	_decal_layers.clear()
	_sprite_layers.clear()
	for p in _projectiles:
		if is_instance_valid(p.mesh):
			p.mesh.queue_free()
	_projectiles.clear()
	_transients.clear()
