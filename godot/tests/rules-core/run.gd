extends SceneTree
## Headless: godot --headless --path godot --script res://tests/rules-core/run.gd

var pass_n := 0
var fail_n := 0

const FX := "res://tests/rules-core/fixtures/"
# preload so the test runs even before the global class cache exists (fresh checkout, no editor import)
const Rng := preload("res://rules/core/rng.gd")
const M := preload("res://rules/core/math.gd")
const C := preload("res://rules/core/content.gd")


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
	C.reset()
	var man: Dictionary = C.manifest()
	ok(man.has("sourceSha") and String(man["sourceSha"]).length() == 40, "manifest sha")
	var n_files := 0
	for name in C.file_names():
		var d: Dictionary = C.file(name)
		var entry: Dictionary = man["files"][name]
		ok(d.size() == int(entry["keys"]), "%s key count" % name)
		for k in d:
			var v: Variant = d[k]
			var cnt := 1
			if typeof(v) == TYPE_ARRAY or typeof(v) == TYPE_DICTIONARY:
				cnt = v.size()
			if cnt != int(entry["counts"][k]):
				ok(false, "%s.%s count %d != manifest %d" % [name, k, cnt, int(entry["counts"][k])])
			else:
				pass_n += 1
		n_files += 1
	ok(n_files >= 70, "file count %d" % n_files)
	var sm: Dictionary = man["summary"]
	ok(C.items().size() == int(sm["items"]), "items count")
	ok(C.enemies().size() == int(sm["enemies"]), "enemies count")
	ok(C.areas().size() == int(sm["areas"]), "areas count")
	ok(C.abilities().size() == int(sm["abilities"]), "abilities count")
	ok(C.disciplines().size() == int(sm["disciplines"]), "disciplines count")
	# typed accessors
	ok(C.item("material_copper_shard")["name"] == "Copper Shard", "item lookup")
	ok(C.item("nope_x")["name"] == "nope x" and int(C.item("nope_x")["sell"]) == 0, "item fallback")
	ok(C.enemy("robber")["name"] == "Grave Robber" and int(C.enemy("robber")["hp"]) == 68, "enemy lookup")
	ok(C.area("graves").has("rect") and C.area("graves")["loot"].size() > 0, "area lookup")
	ok(C.area_order().size() > 5, "area_order")
	ok(C.upgrade_cost("damage", 0) == 40 and C.upgrade_cost("damage", 1) == 60, "upgrade_cost")
	ok(C.recipes().size() == C.get_export("recipes", "ALL_RECIPE_ROWS").size(), "recipes parsed")
	ok(C.recipe("smelt_copper_ingot")["inputs"][0]["item"] == "ore_copper", "recipe lookup")
	ok(C.affix_range(str(C.affixes()[0]["id"]), 1).size() == 2, "affix_range")
	ok(C.smart_loot_table("graves", "gravecaller").size() == C.area("graves")["loot"].size(), "smart table")
	ok(C.tips().size() > 20, "tips")
	# every item reference in area loot tables exists
	for aid in C.areas():
		for e in C.area(aid)["loot"]:
			ok(C.has_item(e["item"]), "area %s loot item %s exists" % [aid, e["item"]])
