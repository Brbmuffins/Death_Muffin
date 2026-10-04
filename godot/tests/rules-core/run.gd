extends SceneTree
## Headless: godot --headless --path godot --script res://tests/rules-core/run.gd

var pass_n := 0
var fail_n := 0

const FX := "res://tests/rules-core/fixtures/"
# preload so the test runs even before the global class cache exists (fresh checkout, no editor import)
const Rng := preload("res://rules/core/rng.gd")
const M := preload("res://rules/core/math.gd")


func _init() -> void:
	_test_rng()
	_test_math()
	_test_content()
	print("rules-core: %d passed, %d failed" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)


func ok(cond: bool, msg: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		if fail_n < 40:
			printerr("FAIL: " + msg)


func load_fx(name: String) -> Variant:
	var f := FileAccess.open(FX + name + ".json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func _test_rng() -> void:
	for c in load_fx("rng_mulberry32"):
		var r := Rng.new(c["seed"])
		var bad := 0
		for i in c["u32"].size():
			if int(r.next() * 4294967296.0) != int(c["u32"][i]):
				bad += 1
		ok(bad == 0, "mulberry32 seed %s: %d mismatches" % [c["seed"], bad])
	var pw: Dictionary = load_fx("rng_pick_weighted")
	for c in pw["cases"]:
		var it: Variant = Rng.pick_weighted(pw["items"], c["r"])
		ok(it != null and it["id"] == c["id"], "pick_weighted r=%s" % c["r"])
	ok(Rng.pick_weighted([], 0.5) == null, "pick_weighted empty")
	for c in load_fx("rng_helpers"):
		var a := Rng.new(c["seed"])
		var b := Rng.new(c["seed"])
		var d := Rng.new(c["seed"])
		for i in 50:
			ok(absf(a.range_f(-3.5, 12.25) - float(c["range"][i])) < 1e-12, "range_f")
			ok(b.range_i(2, 9) == int(c["int"][i]), "range_i")
			ok(Rng.rand_int(d.as_callable(), -5, 5) == int(c["int_neg"][i]), "rand_int neg")


func _test_math() -> void:
	for c in load_fx("math_round"):
		ok(M.js_round(c["x"]) == int(c["round"]), "js_round %s -> %s got %s" % [c["x"], c["round"], M.js_round(c["x"])])
		ok(int(floorf(c["x"])) == int(c["floor"]), "floor %s" % c["x"])
		ok(M.trunc(c["x"]) == int(c["trunc"]), "trunc %s" % c["x"])
	for c in load_fx("math_round_dec"):
		ok(absf(M.round_dec(c["x"], c["d"]) - float(c["v"])) < 1e-12, "round_dec %s %s" % [c["x"], c["d"]])
	for c in load_fx("math_clamp_lerp"):
		ok(absf(M.clamp_f(c["x"], c["lo"], c["hi"]) - float(c["clamp"])) < 1e-9, "clamp")
		ok(absf(M.lerp_f(c["lo"], c["hi"], c["t"]) - float(c["lerp"])) < 1e-9, "lerp")
		ok(absf(M.clamp01(c["t"]) - float(c["clamp01"])) < 1e-9, "clamp01")
		ok(absf(M.inv_lerp(c["lo"], c["hi"], c["x"]) - float(c["inv"])) < 1e-6, "inv_lerp")
	for c in load_fx("math_int32"):
		ok(M.u32(c["x"]) == int(c["u32"]), "u32 %s" % c["x"])
		ok(M.i32(c["x"]) == int(c["i32"]), "i32 %s" % c["x"])
		ok(M.imul(int(c["x"]), 0x9e3779b1) == int(c["imul3"]), "imul %s" % c["x"])


func _test_content() -> void:
	pass
