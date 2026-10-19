extends "res://tests/common/dm_suite_part.gd"
## Client / server loot parity (server authority Phase 1): replays fixtures/loot_parity.json, written by the server's rolls
## (server/rules/gameplay/__tests__/lootRules.test.ts), through DmLoot + DmDropStream. Every case must roll exactly the same drop from
## the same seed words, or a drop the client shows would not be the one the server grants.

var passed := 0
var failed := 0
var _shown := 0


func _initialize() -> void:
	var f := FileAccess.open("res://tests/rules_loot/fixtures/loot_parity.json", FileAccess.READ)
	if f == null:
		print("FAIL loot_parity.json missing (committed in git)")
		failed += 1
		quit(1)
		return
	var fx: Dictionary = JSON.parse_string(f.get_as_text())
	var raw := DmDropStream.new(fx["stream"]["seed"])
	var got: Array = []
	for i in 16:
		got.append(raw.next())
	check("stream", got, fx["stream"]["first"], "sfc32")
	for c: Dictionary in fx["cases"]:
		check(String(c["kind"]), roll(c), c["out"], c["in"])
	print("--- loot_parity: %d / %d passed, %d failed ---" % [passed, passed + failed, failed])
	quit(0 if failed == 0 else 1)


static func stream(words: Variant) -> Callable:
	return DmDropStream.rand(words)


static func roll(c: Dictionary) -> Variant:
	var k: Dictionary = c["in"]
	var s: Dictionary = c["seeds"]
	match String(c["kind"]):
		"kill":
			var owned: Array = k["owned"]
			return DmLoot.roll_kill(String(k["def"]), String(k["area"]), float(k["level"]), bool(k["elite"]), float(k["waveTier"]), stream(s["rand"]),
				String(k["difficulty"]), float(k["itemChanceMult"]), stream(s["reagent"]), stream(s["rune"]), String(k["disciplineId"]),
				func() -> Array: return owned, float(k["runePity"]))
		"boss":
			var owned2: Array = k["owned"]
			return DmLoot.roll_boss(float(k["waveTier"]), stream(s["rand"]), String(k["difficulty"]), String(k["area"]), float(k["costShards"]),
				String(k["boss"]), String(k["disciplineId"]), func() -> Array: return owned2)
		"surge":
			return DmLoot.roll_surge_item(String(k["area"]), stream(s["rand"]), String(k["disciplineId"]))
		"first_kill":
			return DmLoot.roll_first_kill_item(String(k["area"]), stream(s["rand"]), String(k["disciplineId"]))
		"boss_rune":
			return DmLoot.roll_boss_rune(String(k["boss"]), bool(k["first"]), stream(s["rand"]))
		"event":
			var streams := {}
			for n in s:
				streams[n] = stream(s[n])
			return DmLoot.roll_event(String(k["kind"]), k["facts"], streams)
		"tape_event":
			return DmLoot.roll_event(String(k["kind"]), k["facts"], DmLoot.event_streams(String(k["kind"]), s["tape"]))
		"gear":
			return DmLoot.roll_gear_instances(k["items"], float(k["level"]), float(k["characterLevel"]), String(k["source"]), stream(s["gear"]))
	return "unknown kind"


func eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return absf(float(a) - float(b)) <= 1e-9
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
		for key in a:
			if not b.has(key) or not eq(a[key], b[key]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func check(kind: String, got: Variant, want: Variant, ctx: Variant) -> void:
	if eq(got, want):
		passed += 1
		return
	failed += 1
	if _shown < 10:
		_shown += 1
		print("FAIL [%s]\n  in  : %s\n  got : %s\n  want: %s" % [kind, str(ctx).left(500), str(got).left(700), str(want).left(700)])
