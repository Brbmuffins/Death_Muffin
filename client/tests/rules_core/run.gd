extends SceneTree
## Headless: godot --headless --path client --script res://tests/rules_core/run.gd

var pass_n := 0
var fail_n := 0

const FX := "res://tests/rules_core/fixtures/"
# preload so the test runs even before the global class cache exists (fresh checkout, no editor import)
const Rng := preload("res://rules/core/rng.gd")
const M := preload("res://rules/core/math.gd")
const C := preload("res://rules/core/content.gd")


func _init() -> void:
	_test_rng()
	_test_math()
	_test_content()
	print("rules_core: %d passed, %d failed" % [pass_n, fail_n])
	print("%s rules_core %d checks%s" % ["PASS" if fail_n == 0 else "FAIL", pass_n + fail_n, "" if fail_n == 0 else " (%d failed)" % fail_n])
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


## A file of data/content, parsed straight from disk (the accessors under test read it through DmDb).
func _content_file(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/content/%s.json" % name))


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
	# The manifest's own counts (keys, counts, summary) are written by the converter and no game code reads them, so a count typed there pins nothing the game does:
	# the check is that every file the manifest lists is there, and that every table the typed accessors read is not empty.
	var n_files := 0
	for name in C.file_names():
		ok(FileAccess.file_exists("res://data/content/%s.json" % name), "%s is a file of data/content" % name)
		n_files += 1
	ok(n_files == (man["files"] as Dictionary).size() and n_files > 0, "every file the manifest lists was read (%d)" % n_files)
	ok(not C.items().is_empty() and not C.enemies().is_empty() and not C.areas().is_empty() and not C.abilities().is_empty() and not C.disciplines().is_empty(), "the item, enemy, area, ability and discipline tables are not empty")
	# typed accessors: each one answers what the file under data/content holds (read here straight from the file, not through the accessor)
	var items_file := _content_file("items")["ITEMS"] as Dictionary
	var bad := []
	for id in items_file:
		if C.item(id) != items_file[id]:
			bad.append(id)
	ok(not items_file.is_empty() and C.items().size() == items_file.size() and bad.is_empty(), "item lookup: every item as the file has it %s" % [bad.slice(0, 5)])
	ok(C.item("nope_x")["name"] == "nope x" and int(C.item("nope_x")["sell"]) == 0, "item fallback")
	var enemies_file := _content_file("enemies")["ENEMIES"] as Dictionary
	bad = []
	for id in enemies_file:
		if C.enemy(id) != enemies_file[id]:
			bad.append(id)
	ok(not enemies_file.is_empty() and C.enemies().size() == enemies_file.size() and bad.is_empty(), "enemy lookup: every enemy as the file has it %s" % [bad.slice(0, 5)])
	var areas_file := _content_file("areas")
	bad = []
	for id in areas_file["AREAS"]:
		if C.area(id) != areas_file["AREAS"][id] or not C.area(id).has("rect"):
			bad.append(id)
	ok(not (areas_file["AREAS"] as Dictionary).is_empty() and bad.is_empty(), "area lookup: every area as the file has it, with a rect %s" % [bad])
	ok(C.area_order() == areas_file["AREA_ORDER"] and not C.area_order().is_empty(), "area_order")
	var costs_file := _content_file("computed")["upgradeCosts"] as Dictionary
	bad = []
	for kind in costs_file:
		for tier in costs_file[kind].size():
			if C.upgrade_cost(kind, tier) != int(costs_file[kind][tier]):
				bad.append("%s %d" % [kind, tier])
		if C.upgrade_cost(kind, -1) != -1 or C.upgrade_cost(kind, costs_file[kind].size()) != -1:
			bad.append("%s out of range" % kind)
	ok(not costs_file.is_empty() and bad.is_empty(), "upgrade_cost: each kind's cost per tier from computed, -1 past the ends %s" % [bad.slice(0, 5)])
	var rows_file: Array = _content_file("recipes")["ALL_RECIPE_ROWS"]
	ok(C.recipes().size() == C.get_export("recipes", "ALL_RECIPE_ROWS").size() and C.recipes().size() == rows_file.size(), "recipes parsed")
	bad = []
	for row in rows_file:
		var r := C.recipe(row[0])
		var inputs_ok: bool = r.get("inputs", []).size() == row[6].size()
		for i in row[6].size() if inputs_ok else 0:
			inputs_ok = inputs_ok and r["inputs"][i]["item"] == row[6][i][0] and r["inputs"][i]["qty"] == int(row[6][i][1])
		if r.get("name") != row[1] or r.get("skill") != row[2] or r.get("level") != int(row[3]) or r.get("result") != row[4] or r.get("qty") != int(row[5]) or not inputs_ok:
			bad.append(row[0])
	ok(not rows_file.is_empty() and bad.is_empty(), "recipe lookup: every recipe's name, skill, level, result, quantity and inputs as the file has them %s" % [bad.slice(0, 5)])
	var ranges_file := _content_file("computed")["affixRanges"] as Dictionary
	bad = []
	for a in C.affixes():
		var id := str(a["id"])
		var rows: Array = ranges_file.get(id, [])
		if rows.is_empty() or C.affix_range(id, 1).size() != 2 or C.affix_range(id, 1) != rows[0] or C.affix_range(id, rows.size() + 50) != rows[rows.size() - 1]:
			bad.append(id)
	ok(not C.affixes().is_empty() and bad.is_empty(), "affix_range: [min, max] from computed, the last row past the end %s" % [bad])
	var tables_file := _content_file("computed")["smartTables"] as Dictionary
	bad = []
	for aid in tables_file:
		for did in tables_file[aid]:
			if C.smart_loot_table(aid, did) != tables_file[aid][did] or C.smart_loot_table(aid, did).size() != C.area(aid)["loot"].size():
				bad.append("%s/%s" % [aid, did])
	ok(not tables_file.is_empty() and bad.is_empty(), "smart table: from computed, one row per drop of the area %s" % [bad.slice(0, 5)])
	ok(not C.tips().is_empty() and C.tips().size() == (_content_file("onboarding")["TIPS"] as Dictionary).size(), "tips")
	# every item reference in area loot tables exists
	for aid in C.areas():
		for e in C.area(aid)["loot"]:
			ok(C.has_item(e["item"]), "area %s loot item %s exists" % [aid, e["item"]])
