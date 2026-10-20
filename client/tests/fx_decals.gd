extends SceneTree
## The ground decals in C++ (DmDecals, client/fx/dm_fx_prims.gd's `decal`) against TODAY'S: the reference is the old game's fx/dm_fx_prims.gd itself (its DecalTr and the DECAL half of
## DmFxLayer.flush), kept as text (tests/fixtures/old_game/fx/dm_fx_prims.gd.txt, so Godot never parses it) and compiled at run time with its class_name line dropped. Both effect layers get the same decals (every texture,
## blend, role and order, delays, spin, pulse, growth, anchors, sheets, followers that vanish, persistent ones, settling ones that overlap and bring each other's outline forward,
## kills, and more than the cap of combat transients) and the same frame times (60 Hz, 144 Hz, hitches); after every frame each layer's drawn count and every float of its drawn buffer must be EQUAL,
## and so must the number of combat transients and whether each handle is alive.
## Run: godot --headless --path client --script res://tests/fx_decals.gd

const TODAY := "res://tests/fixtures/old_game/fx/dm_fx_prims.gd.txt"   ## the old game's effects layer, kept as text

var fails := 0
var checks := 0
var clock := 0.0   # what the followers read, set by the test before each frame


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL fx_decals: " + what)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	var src := FileAccess.get_file_as_string(TODAY)
	check(src != "", "today's effects layer is readable at %s" % TODAY)
	if src == "":
		_end()
		return
	var today := GDScript.new()
	today.source_code = src.replace("class_name DmFxPrims\n", "").replace("var _owner: DmFxPrims", "var _owner").replace("var owner: DmFxPrims", "var owner")
	check(today.reload() == OK, "today's effects layer compiles in this project")
	if today.reload() == OK:
		_compare(today, 1)
		_compare(today, 2)
		_cap(today)
	_end()


func _end() -> void:
	print("%s fx_decals %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


## A follower: where it is is a function of the test's clock; it is gone (null) for a while, and a body that is not a Vector3 at all counts as "not found" too.
func _follower(seed_: int) -> Callable:
	return func() -> Variant:
		var a := float(seed_) * 0.7 + clock * (0.4 + float(seed_ % 5) * 0.1)
		if seed_ % 7 == 3 and fmod(clock, 4.0) > 3.0:
			return null
		return Vector3(sin(a) * 6.0 + float(seed_ % 11), 0.0, cos(a) * 5.0 - float(seed_ % 13))


func _options(rng: RandomNumberGenerator, i: int, at_cap := false) -> Dictionary:
	var texes := ["disc", "ring", "cracks", "glow", "sigil", "cone", "smoke", "spark", "hit_flash", "summon_circle", "crush_slam"]
	var o := {"tex": texes[rng.randi() % texes.size()], "x": rng.randf_range(-12, 12), "z": rng.randf_range(-12, 12), "r": rng.randf_range(0.3, 6.0),
		"duration": rng.randf_range(0.2, 9.0) if not at_cap else 40.0, "color": rng.randi_range(0, 0xffffff) if i % 3 != 0 else Color(rng.randf(), rng.randf(), rng.randf())}
	if i % 2 == 0:
		o["opacity"] = rng.randf_range(0.1, 1.0)
	if i % 5 == 0:
		o["growFrom"] = rng.randf_range(0.1, 0.9)
	if i % 4 == 1:
		o["spin"] = rng.randf_range(-3.0, 3.0)
	if i % 3 == 1:
		o["pulse"] = rng.randf_range(0.5, 7.0)
	if i % 6 == 2:
		o["delay"] = rng.randf_range(0.0, 1.0)
	if i % 8 == 3:
		o["anchor"] = rng.randf_range(-1.0, 1.0)
		o["rot"] = rng.randf_range(0.0, TAU)
	if i % 9 == 4:
		o["sx"] = rng.randf_range(0.2, 2.0)
		o["sz"] = rng.randf_range(0.2, 2.0)
	if i % 6 == 5:
		o["blending"] = "mix"
	if i % 10 == 6:
		o["fadeIn"] = rng.randf_range(0.0, 0.5)
		o["fadeOut"] = rng.randf_range(0.0, 0.8)
	if i % 11 == 7:
		o["persistent"] = true
	if i % 12 == 8:
		o["hero"] = true
	if i % 13 == 9:
		o["danger"] = true
	if i % 4 == 2:
		o["follow"] = _follower(i)
	if i % 14 == 10:
		o["y"] = rng.randf_range(0.0, 0.3)
	return o


func _compare(today: GDScript, which: int) -> void:
	var refg := Node3D.new()
	var portg := Node3D.new()
	root.add_child(refg)
	root.add_child(portg)
	var ref: Object = today.new(refg)
	var port := DmFxPrims.new(portg)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261017 + which
	var dts := [1.0 / 60.0, 1.0 / 144.0, 1.0 / 60.0, 0.05, 1.0 / 60.0, 1.0 / 30.0]
	var handles: Array = []   # [reference handle, port handle]
	var first_bad := ""
	var frames := 0
	var made := 0
	var ring_seen := false
	var rim_seen := false
	var max_alive := 0
	for f in 900:
		clock = float(f) / 60.0
		if f % 2 == 0 and f < 600:
			for k in rng.randi_range(1, 5):
				var o := _options(rng, made)
				if made % 17 == 0:
					ref.set("role", "other")
					port.role = "other"
				var hr: Object = ref.call("decal", o)
				var hp: Object = port.decal(o)
				ref.set("role", "self")
				port.role = "self"
				handles.append([hr, hp])
				made += 1
		if f % 37 == 36 and not handles.is_empty():
			var j := rng.randi() % handles.size()
			handles[j][0].call("kill")
			handles[j][1].kill()
		var dt: float = dts[f % dts.size()]
		ref.call("update", dt, dt)
		port.update(dt, dt)
		frames += 1
		if int(ref.get("combat_transients")) != port.transient_load():
			first_bad = "frame %d: combat transients %d / %d" % [f, int(ref.get("combat_transients")), port.transient_load()]
			break
		var alive_n := 0
		for h in handles:
			if bool(h[0].call("is_alive")) != h[1].is_alive():
				first_bad = "frame %d: a handle's liveness differs (%s / %s)" % [f, str(h[0].call("is_alive")), str(h[1].is_alive())]
				break
			alive_n += 1 if h[1].is_alive() else 0
		max_alive = maxi(max_alive, alive_n)
		if first_bad != "":
			break
		var ref_layers: Dictionary = ref.get("_decal_layers")
		var port_layers: Dictionary = port._decal_layers
		for key in port_layers:   # (the port makes a settling decal's ring layer with the decal, today's when the ring first shows: it may hold a layer the other lacks, empty)
			if not ref_layers.has(key) and port._dec.drawn(port_layers[key].native_index) != 0:
				first_bad = "frame %d: the port draws layer %s, today's has none" % [f, str(key)]
		for key in ref_layers:
			if not port_layers.has(key):
				first_bad = "frame %d: the port lacks layer %s" % [f, str(key)]
				break
			var rl: DmFxLayer = ref_layers[key]
			var pl: DmFxLayer = port_layers[key]
			var n_ref: int = rl.mm.visible_instance_count if rl.node.visible else 0
			var n_port: int = port._dec.drawn(pl.native_index)
			if n_ref != n_port:
				first_bad = "frame %d, layer %s: drawn %d / %d" % [f, str(key), n_ref, n_port]
				break
			if n_port == 0:
				continue
			var a: PackedFloat32Array = rl._buf
			var b: PackedFloat32Array = port._dec.buffer(pl.native_index)
			for j in n_port * 20:
				if a[j] != b[j]:
					first_bad = "frame %d, layer %s: float %d (instance %d, slot %d) %.9f / %.9f" % [f, str(key), j, j / 20, j % 20, a[j], b[j]]
					break
			if first_bad != "":
				break
			ring_seen = ring_seen or String(key).begins_with("ring|")
			for j in range(0, n_port * 20, 20):
				rim_seen = rim_seen or b[j + 17] > 0.0
		if first_bad != "":
			break
	check(first_bad == "", "run %d: the port's counts, handles and every drawn buffer equal today's every frame (%d frames, %d decals)%s" % [which, frames, made, "" if first_bad == "" else ": " + first_bad])
	check(max_alive > 60, "run %d: many decals were alive together (%d)" % [which, max_alive])
	check(ring_seen and rim_seen, "run %d: settling decals drew their outline and their rings (ring layer %s, rim %s)" % [which, str(ring_seen), str(rim_seen)])
	for h in handles:
		h[0].call("kill")
		h[1].kill()
	ref.call("update", 1.0, 1.0)
	port.update(1.0, 1.0)
	check(port.transient_load() == int(ref.call("transient_load")), "run %d: after every handle was killed and a second passed, the same number of transients is counted (%d)" % [which, port.transient_load()])
	port.clear()
	port.dispose()
	ref.call("clear")
	ref.call("dispose")
	refg.free()
	portg.free()


## More decals than the cap of combat transients (fx_data.json `caps`): the oldest leave, the persistent ones stay, and the count stays where today's does.
func _cap(today: GDScript) -> void:
	var cap := int(DmFxData.caps()["combat_transients"])
	var refg := Node3D.new()
	var portg := Node3D.new()
	root.add_child(refg)
	root.add_child(portg)
	var ref: Object = today.new(refg)
	var port := DmFxPrims.new(portg)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var bad := ""
	var handles: Array = []
	var decals := cap * 2 + 100   # (well past the cap)
	for i in decals:
		var o := _options(rng, i, true)
		o.erase("delay")
		var hr: Object = ref.call("decal", o)
		var hp: Object = port.decal(o)
		handles.append([hr, hp])
		if i % 7 == 0:
			var fl := {"tex": "glow", "x": 1.0, "y": 1.0, "z": 1.0, "size": 1.0, "duration": 30.0}   # a flash is a transient of another kind: it ages with the decals under the same cap
			ref.call("flash", fl)
			port.flash(fl)
		if int(ref.call("transient_load")) != port.transient_load():
			bad = "decal %d: transients %d / %d" % [i, int(ref.call("transient_load")), port.transient_load()]
			break
		for h in handles:
			if bool(h[0].call("is_alive")) != h[1].is_alive():
				bad = "decal %d: a handle's liveness differs" % i
				break
		if bad != "":
			break
		if i % 40 == 39:
			ref.call("update", 1.0 / 60.0, 1.0 / 60.0)
			port.update(1.0 / 60.0, 1.0 / 60.0)
	check(bad == "", "the cap: %d decals and %d flashes leave the same ones alive as today's%s" % [decals, int(ceil(float(decals) / 7.0)), "" if bad == "" else ": " + bad])
	check(port.transient_load() <= cap + 1 + 20, "the cap holds the combat transients near %d (%d, persistent ones are outside it)" % [cap, port.transient_load()])
	port.clear()
	port.dispose()
	ref.call("clear")
	ref.call("dispose")
	refg.free()
	portg.free()
