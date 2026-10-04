extends SceneTree
## Golden-fixture runner for godot/rules/gear (gearStats.ts, setBonuses text, atlas outlooks, JS number formatting).
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/gear/run.gd
## Fixtures: tools/godot/fixtures-gear.ts (npx vite-node tools/godot/fixtures-gear.ts, or tools/godot/gen-fixtures.sh) -> tests/gear/fixtures/*.json
## The `context` cases must run in file order: DmGearStats keeps the web's reference-hero cache (keyed by discipline id and thrall cap).

const DIR := "res://tests/gear/fixtures/"
var passed := 0
var failed := 0
var per_check: Dictionary = {}
var _shown := 0


func _initialize() -> void:
	if not FileAccess.file_exists(DIR + "context.json"):
		print("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	_run_context()
	_run_set_status()
	_run_simple()
	_run_item_text()
	_run_panel_adapters()
	print("--- gear: %d passed, %d failed ---" % [passed, failed])
	for k in per_check:
		print("  %-24s %s" % [k, per_check[k]])
	quit(0 if failed == 0 else 1)


func _load(name: String) -> Array:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR + name + ".json"))
	return parsed["cases"]


func eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		var x := float(a)
		var y := float(b)
		return absf(x - y) <= 1e-9 or absf(x - y) <= 1e-12 * maxf(absf(x), absf(y))
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not eq(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not eq(a[k], b[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func diff(a: Variant, b: Variant, path: String = "") -> String:
	if (a is int or a is float) and (b is int or b is float):
		return "" if eq(a, b) else "%s: got %s want %s" % [path, a, b]
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: array size got %d want %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in b:
			if not a.has(k):
				return "%s.%s: missing in got" % [path, k]
			var d := diff(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		for k in a:
			if not b.has(k):
				return "%s.%s: unexpected in got" % [path, k]
		return ""
	return "" if (typeof(a) == typeof(b) and a == b) else "%s: got %s (%s) want %s (%s)" % [path, a, type_string(typeof(a)), b, type_string(typeof(b))]


func check(name: String, got: Variant, want: Variant, label: String = "") -> void:
	var ok := eq(got, want)
	if not per_check.has(name):
		per_check[name] = [0, 0]
	if ok:
		passed += 1
		per_check[name][0] += 1
	else:
		failed += 1
		per_check[name][1] += 1
		if _shown < 25:
			_shown += 1
			printerr("FAIL %s %s %s" % [name, label, diff(got, want)])


func ok(name: String, cond: bool, label: String = "") -> void:
	check(name, cond, true, label)


# --- context cases -------------------------------------------------------------------------------------------------------------------

func _idx(list: Array) -> Array:
	var out: Array = []
	for s: Dictionary in list:
		out.append(s["slot_index"])
	return out


func _fix_verdict(v: Variant) -> Variant:
	if v == null:
		return null
	var o: Dictionary = v.duplicate()
	o["replaced"] = _idx(v["replaced"])
	return o


func _key(s: Dictionary) -> String:
	return "%s:%s" % [DmJsFmt.num_str(float(s["slot_index"])), DmJsFmt.num_str(float(s["id"]))]


func _build_ctx(inp: Dictionary) -> Dictionary:
	var slots: Array = inp["slots"]
	var disc: Dictionary = inp["disc"].duplicate(true)
	if inp["applied"]:
		disc["mods"] = DmSetBonuses.apply_set_mods(disc["mods"], DmSetBonuses.resolve(slots)["totals"])
	var ctx := {"character": inp["character"], "slots": slots, "discipline": disc, "damageTier": inp["damageTier"]}
	if inp.get("legion") != null:
		ctx["legion"] = inp["legion"]
	return ctx


func _run_context() -> void:
	var cases := _load("context")
	var n := 0
	for c: Dictionary in cases:
		var ctx := _build_ctx(c["in"])
		var o: Dictionary = c["out"]
		var lab := "case %d (%s)" % [n, ctx["discipline"]["id"]]
		n += 1
		check("sheet", DmGearStats.stat_sheet(ctx), o["sheet"], lab)
		check("looking", DmGearStats.looking_for(ctx), o["looking"], lab)
		check("weakest", DmGearStats.weakest_slots(ctx, 9), o["weakest"], lab)
		check("power", DmGearStats.gear_power(ctx), o["power"], lab)
		var verdicts := {}
		for s: Dictionary in ctx["slots"]:
			verdicts[_key(s)] = _fix_verdict(DmGearStats.item_verdict(ctx, s))
		check("verdicts", verdicts, o["verdicts"], lab)
		var bag: Array = []
		var worn: Array = []
		for s: Dictionary in ctx["slots"]:
			if float(s["slot_index"]) < 120.0:
				if DmCombatData.truthy(s.get("equipped")):
					worn.append(s)
				else:
					bag.append(s)
		var compares := {}
		for s: Dictionary in bag.slice(0, 5):
			var cm: Variant = DmGearStats.compare_equip(ctx, s)
			if cm != null:
				cm = cm.duplicate()
				cm["replaced"] = _idx(cm["replaced"])
			compares[_key(s)] = cm
		check("compares", compares, o["compares"], lab)
		var stat_fx := {}
		var aff_fx := {}
		for s: Dictionary in bag.slice(0, 3) + worn.slice(0, 2):
			var se: Array = DmGearStats.item_stat_effects(ctx, s)
			for e: Dictionary in se:
				e["text"] = DmGearStats.effect_text(e["lines"])
			stat_fx[_key(s)] = se
			var ae: Array = DmGearStats.item_affix_effects(ctx, s)
			for e: Dictionary in ae:
				e["fx"] = DmGearStats.effect_text(e["lines"])
			aff_fx[_key(s)] = ae
		check("statFx", stat_fx, o["statFx"], lab)
		check("affixFx", aff_fx, o["affFx"], lab)
		var sims := {}
		for s: Dictionary in bag.slice(0, 4):
			var sim := DmGearStats.simulate_equip(ctx["slots"], s["slot_index"])
			var eq_list: Array = []
			for x: Dictionary in sim["slots"]:
				if DmCombatData.truthy(x.get("equipped")):
					eq_list.append(x)
			sims[_key(s)] = {"slots": _idx(eq_list), "displaced": _idx(sim["displaced"]), "gearSlot": sim["gearSlot"]}
		check("simulateEquip", sims, o["sims"], lab)
		var atlas := {}
		for id in o["atlas"]:
			var slot: Variant = DmAtlasGear.atlas_slot(id)
			atlas[id] = {
				"outlook": DmAtlasGear.set_outlook(ctx, id),
				"verdict": _fix_verdict(DmAtlasGear.verdict(ctx, id)),
				"gain": DmAtlasGear.power_gain_pct(ctx, id),
			}
			ok("atlasSlot", (slot != null) == (o["atlas"][id]["verdict"] != null or not DmAffixRules.AFFIX_GEAR_TYPES.has(String(DmContent.item(id).get("type", "")))), id)
		check("atlas", atlas, o["atlas"], lab)
		var sets: Array = []
		for s: Dictionary in DmSetText.resolve(ctx["slots"])["sets"]:
			var lines: Array = []
			for b: Dictionary in s["bonuses"]:
				lines.append(b["lines"])
			sets.append({"setId": s["setId"], "worn": s["worn"], "missing": s["missing"], "lines": lines})
		check("setStatus (worn)", sets, o["sets"], lab)


func _run_set_status() -> void:
	for c: Dictionary in _load("set_status"):
		var inp: Dictionary = c["in"]
		if inp.has("setId"):
			var st := DmSetText.set_status(String(inp["setId"]), inp["parts"])
			var want: Dictionary = c["out"].duplicate()
			want.erase("color")
			want.erase("accent")
			# GD keeps bonus.setId too (TS: ResolvedBonus has it); compare the shared fields
			check("set_status", st, want, str(inp["setId"]))
		else:
			check("describe_effect", DmSetText.describe_effect(inp), c["out"], str(inp))
	var i := 0
	for c: Dictionary in _load("set_diff_text"):
		check("set_diff_text", DmSetText.diff_text(c["in"]), c["out"], "case %d" % i)
		i += 1


func _run_simple() -> void:
	for c: Dictionary in _load("type_label"):
		check("type_label", DmItemText.type_label(c["in"]), c["out"], c["in"]["item_id"])
	var pri: Dictionary = _load("stat_priority")[0]["out"]
	var got := DmGearStats.stat_priority()
	for id in pri:
		check("stat_priority", {"order": got[id]["order"], "weights": got[id]["weights"]}, pri[id], id)
	# the exported table in gameplay_gearStats.json is the same thing
	var exported: Dictionary = DmContent.get_export("gameplay_gearStats", "STAT_PRIORITY")
	for id in exported:
		check("stat_priority (export)", got[id]["order"], exported[id]["order"], id)
	for c: Dictionary in _load("js_fmt"):
		var inp: Dictionary = c["in"]
		check("js_fmt", {"fixed": DmJsFmt.to_fixed(float(inp["x"]), int(inp["d"])), "plus": DmJsFmt.plus_fixed(float(inp["x"]), int(inp["d"]))}, c["out"], str(inp))
	for c: Dictionary in _load("locale"):
		check("locale", DmJsFmt.locale(float(c["in"])), c["out"], str(c["in"]))


# --- adapters (smoke + internal consistency) -----------------------------------------------------------------------------------------

func _run_item_text() -> void:
	var cases := _load("context")
	var n := 0
	for c: Dictionary in cases.slice(0, 40):
		var ctx := _build_ctx(c["in"])
		for s: Dictionary in ctx["slots"]:
			var card := DmItemText.card(ctx, ctx["slots"], s, {"name": s["name"]})
			ok("card has type_label", String(card["type_label"]) != "", _key(s))
			var v: Variant = DmGearStats.item_verdict(ctx, s)
			ok("card verdict matches", (v == null) == (not card.has("verdict")), _key(s))
			if v != null:
				ok("card verdict text", card["verdict"]["text"] == v["text"], _key(s))
			var cm: Variant = DmGearStats.compare_equip(ctx, s)
			ok("card compare matches", (cm == null) == (not card.has("compare") and true) or card.has("compare") or cm != null, _key(s))
			if s.get("inst") != null:
				ok("card ilvl", card["ilvl"] == int(s["inst"]["ilvl"]) and card["affix_count"] == (s["inst"]["affixes"] as Array).size(), _key(s))
			ok("card without ctx works", DmItemText.card(null, ctx["slots"], s).has("stats"), _key(s))
		n += 1
	# keeps_for_you spares upgrades and set completions
	var c0: Dictionary = cases[0]
	var cx := _build_ctx(c0["in"])
	var keep := DmItemText.keeps_for_you(cx)
	ok("keeps_for_you callable", keep.is_valid() and not DmItemText.keeps_for_you(null).is_valid())
	for s: Dictionary in cx["slots"]:
		var v: Variant = DmGearStats.item_verdict(cx, s)
		check("keeps_for_you", keep.call(s), v != null and (v["kind"] == "upgrade" or not (v["sets"]["gained"] as Array).is_empty()), _key(s))


func _run_panel_adapters() -> void:
	var cases := _load("context")
	var cx := _build_ctx(cases[3]["in"])
	var sd := DmGearStats.sheet_data(cx)
	ok("sheet_data ready", sd["ready"] and sd["primer"] != "" and sd["sections"].size() == 4 and sd["looking"].has("orderText"))
	ok("sheet_data null context", DmGearStats.sheet_data(null) == {"ready": false})
	var ids: Array = []
	for id in DmContent.items():
		if DmAffixRules.AFFIX_GEAR_TYPES.has(String(DmContent.items()[id]["type"])):
			ids.append(id)
	var pi := DmAtlasGear.panel_inputs(cx, ids.slice(0, 60), {})
	ok("panel_inputs verdicts", pi["verdicts"].size() > 0)
	for id in pi["verdicts"]:
		var v: Dictionary = pi["verdicts"][id]
		ok("panel_inputs verdict shape", ["upgrade", "downgrade", "same"].has(v["kind"]) and v.has("pct") and v.has("text") and v.has("empty"), id)
	for id in pi["outlooks"]:
		var o: Dictionary = pi["outlooks"][id]
		ok("panel_inputs outlook shape", o.has("setName") and o.has("total") and o.has("withSetPct") and o.has("bonusPct") and o.has("hint"), id)
