class_name DmFxRing
extends RefCounted
## Port of Effects.ts ParticleSystem: a CPU-simulated ring buffer of motes drawn as one MultiMesh of billboards per blend mode
## (additive "glow" ring of 3500, normal-blend "smoke" ring of 900). Same emit options, same alpha/size curves.
## The rebuild's port (client/code.list "Ported"): the motes and the per-frame loop are the combat core's `DmMotes` (C++, the same arithmetic: client/tests/fx_motes.gd
## compares the buffers with today's loop); `emit` still makes each mote's random start here, from the same randf stream.

## While at most SMALL_CAP motes are live only a small MultiMesh is drawn and uploaded (a full-ring buffer is 224 KB for the additive ring, and
## `MultiMesh.buffer` must always be the whole buffer). Both MultiMeshes are allocated once here and never resized; only visibility switches.
const SMALL_CAP := 256

var node: MultiMeshInstance3D        # full-size ring
var mm: MultiMesh
var node_small: MultiMeshInstance3D  # SMALL_CAP ring, sibling of `node` (visibility is not inherited)
var mm_small: MultiMesh
var capacity: int

var _m := DmMotes.new()              # the motes and their loop (the core's C++)
var _shown := false
var _mode := 0   # 0 neither ring shown yet, 1 full ring, 2 small ring


func _init(cap: int, tex: Texture2D, additive: bool) -> void:
	capacity = cap
	_m.setup(cap, SMALL_CAP if cap > SMALL_CAP else 0)
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	var mat := DmFxTex.material("particle", additive, tex, 5)
	mm = _make_mm(q, cap)
	node = _make_node(mm, mat)
	if cap > SMALL_CAP:
		mm_small = _make_mm(q, SMALL_CAP)
		node_small = _make_node(mm_small, mat)


static func _make_mm(q: Mesh, cap: int) -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	m.use_colors = true
	m.mesh = q
	m.instance_count = cap
	m.visible_instance_count = 0
	return m


static func _make_node(m: MultiMesh, mat: Material) -> MultiMeshInstance3D:
	var nd := MultiMeshInstance3D.new()
	nd.multimesh = m
	nd.material_override = mat
	nd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	nd.custom_aabb = AABB(Vector3(-500, -500, -500), Vector3(1000, 1000, 1000))
	nd.visible = false
	return nd


## o: x y z count color(Color/int) spread speed up life size gravity drag shrink inward (Effects.ts EmitOptions).
func emit(o: Dictionary) -> void:
	var count := int(o.get("count", 0))
	if count <= 0:
		return
	# sRGB as given: the Compatibility renderer linearises MultiMesh instance colours itself (converting here too drew every mote
	# ~3x too dark and dark ones pure black, e.g. the Grave Surge's crypt dust).
	var c := DmFxData.to_color(o.get("color", Color.WHITE))
	var spread := float(o.get("spread", 0.2))
	var speed := float(o.get("speed", 1.0))
	var up := float(o.get("up", 0.5))
	var life := float(o.get("life", 0.8))
	var size := float(o.get("size", 0.3))
	var gravity := float(o.get("gravity", 0.0))
	var drag := float(o.get("drag", 1.5))
	var shrink := float(o.get("shrink", 1.0))
	var inward: bool = o.get("inward", false)
	var ox := float(o.get("x", 0.0))
	var oy := float(o.get("y", 0.0))
	var oz := float(o.get("z", 0.0))
	for n in count:
		var a := randf() * TAU
		var r := spread * sqrt(randf())
		var px := ox + cos(a) * r
		var py := oy + (randf() - 0.5) * spread * 0.5
		var pz := oz + sin(a) * r
		var sp := speed * (0.4 + randf() * 0.8)
		var va := (a + PI) if inward else randf() * TAU
		var vy := up * (0.5 + randf())
		var l := life * (0.7 + randf() * 0.6)
		_m.put(Vector3(px, py, pz), Vector3(cos(va) * sp, vy, sin(va) * sp), c, l, size * (0.7 + randf() * 0.6), gravity, drag, shrink)
	_shown = true   # update() picks which of the two rings is visible


func active() -> int:
	return _m.active()


func update(dt: float) -> void:
	if _m.active() == 0:
		if _shown:   # once, not on every idle frame
			_shown = false
			_mode = 0
			node.visible = false
			mm.visible_instance_count = 0
			if node_small != null:
				node_small.visible = false
				mm_small.visible_instance_count = 0
		return
	# The live count bounds the packed count n, so a small ring is safe whenever it fits.
	var small := node_small != null and _m.active() <= SMALL_CAP
	var n := _m.step(dt, small)
	_shown = _m.active() > 0
	var mode := 2 if small else 1
	if mode != _mode:   # switching rings: the other one stops drawing (once, not every frame)
		_mode = mode
		node.visible = not small
		mm.visible_instance_count = 0
		if node_small != null:
			node_small.visible = small
			mm_small.visible_instance_count = 0
	var draw_mm := mm_small if small else mm
	draw_mm.visible_instance_count = n
	if n > 0:
		_m.upload(draw_mm.get_rid(), small)
