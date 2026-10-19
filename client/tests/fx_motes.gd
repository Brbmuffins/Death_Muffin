extends SceneTree
## The particle ring's loop in C++ (DmMotes, client/fx/dm_fx_ring.gd ported) against TODAY'S ring: the reference is the old game's fx/dm_fx_ring.gd itself, kept
## as text (tests/fixtures/old_game/fx/dm_fx_ring.gd.txt, so Godot never parses it) and compiled at run time (its class_name line dropped). Both rings get the same bursts (the same randf stream:
## the global seed is set before each emit on each side) and the same frame times (60 Hz, 144 Hz, hitches), through the ring's wrap-around and the switch
## between the small and the full MultiMesh; after every update the live count, the drawn count and every float of the drawn buffer must be EQUAL.
## Run: godot --headless --path client --script res://tests/fx_motes.gd

const TODAY := "res://tests/fixtures/old_game/fx/dm_fx_ring.gd.txt"   ## the old game's ring, kept as text

var fails := 0
var checks := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL fx_motes: " + what)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	var src := FileAccess.get_file_as_string(TODAY)
	check(src != "", "today's ring is readable at %s" % TODAY)
	if src == "":
		_end()
		return
	var today := GDScript.new()
	today.source_code = src.replace("class_name DmFxRing\n", "")
	check(today.reload() == OK, "today's ring compiles in this project")
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	for cfg in [[3500, true, "the additive ring (3,500)"], [900, false, "the smoke ring (900)"]]:
		_compare(today, int(cfg[0]), bool(cfg[1]), tex, String(cfg[2]))
	_end()


func _end() -> void:
	print("%s fx_motes %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


## The buffer a ring drew last: today's swaps its two buffers around a small-ring update (the drawn one ends in `_buf_other`); the port's lives in DmMotes.
static func _drawn_today(r: Object, small: bool) -> PackedFloat32Array:
	return r.get("_buf_other") if small else r.get("_buf")


func _compare(today: GDScript, cap: int, additive: bool, tex: Texture2D, label: String) -> void:
	var ref: Object = today.new(cap, tex, additive)
	var port := DmFxRing.new(cap, tex, additive)
	var opts := RandomNumberGenerator.new()
	opts.seed = 20261016
	var dts := [1.0 / 60.0, 1.0 / 144.0, 1.0 / 60.0, 0.05, 1.0 / 60.0, 1.0 / 30.0]
	var first_bad := ""
	var frames := 0
	var saw_small := false
	var saw_full := false
	var wrapped := false
	var emitted := 0
	for f in 900:
		if f % 3 == 0 and f < 700:
			var o := {"x": opts.randf_range(-20, 20), "y": opts.randf_range(0, 2), "z": opts.randf_range(-20, 20), "count": opts.randi_range(1, 140 if f > 200 else 30),
				"color": _color(opts, f / 3), "spread": opts.randf_range(0.0, 2.0), "speed": opts.randf_range(0.0, 6.0), "up": opts.randf_range(-1.0, 3.0),
				"life": opts.randf_range(0.2, 2.5), "size": opts.randf_range(0.05, 0.6), "gravity": opts.randf_range(-2.0, 9.0), "drag": opts.randf_range(0.0, 4.0),
				"shrink": opts.randf_range(-1.0, 1.0), "inward": opts.randf() < 0.3}
			seed(1000 + f)
			ref.call("emit", o)
			seed(1000 + f)
			port.emit(o)
			emitted += int(o["count"])
			wrapped = wrapped or emitted > cap
		var dt: float = dts[f % dts.size()]
		var small: bool = port.node_small != null and port.active() <= DmFxRing.SMALL_CAP
		ref.call("update", dt)
		port.update(dt)
		frames += 1
		if port.active() == 0:
			continue
		saw_small = saw_small or small
		saw_full = saw_full or not small
		var n_ref: int = (ref.get("mm_small") if small else ref.get("mm")).visible_instance_count
		var n_port: int = (port.mm_small if small else port.mm).visible_instance_count
		if int(ref.call("active")) != port.active() or n_ref != n_port:
			first_bad = "frame %d: live %d / %d, drawn %d / %d" % [f, int(ref.call("active")), port.active(), n_ref, n_port]
			break
		var a := _drawn_today(ref, small)
		var b := port._m.buffer(small)
		for j in n_port * 16:
			if a[j] != b[j]:
				first_bad = "frame %d: float %d (mote %d) %.9f / %.9f" % [f, j, j / 16, a[j], b[j]]
				break
		if first_bad != "":
			break
	check(first_bad == "", "%s: the port's live count, drawn count and buffer equal today's every frame (%d frames)%s" % [label, frames, "" if first_bad == "" else ": " + first_bad])
	check(wrapped, "%s: the bursts wrapped the ring (%d motes emitted)" % [label, emitted])
	if cap > DmFxRing.SMALL_CAP:
		check(saw_small and saw_full, "%s: both the small and the full MultiMesh were drawn" % label)
	check(port.active() == 0 and not port.node.visible, "%s: every mote faded and the ring hid" % label)
	_free(ref)
	_free(port)


## A burst's colour in the three forms `DmFxData.to_color` takes: a Color, a 0xRRGGBB int (most of the game's bursts), a list of three or four numbers.
static func _color(opts: RandomNumberGenerator, f: int) -> Variant:
	match f % 5:
		0, 1:
			return opts.randi_range(0, 0xffffff)
		2:
			return [opts.randf(), opts.randf(), opts.randf()]
		3:
			return [opts.randf(), opts.randf(), opts.randf(), opts.randf()]
	return Color(opts.randf(), opts.randf(), opts.randf())


static func _free(r: Object) -> void:
	for k in ["node", "node_small"]:
		var n: Node = r.get(k)
		if n != null:
			n.free()
