extends SceneTree
## Headless tests for godot/loot_view (DmLootView). Fixtures come from the real TS LootView (the retired web game\'s fixtures-lootview exporter).
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/loot_view/run.gd

const DIR := "res://tests/loot_view/fixtures/"
var passed := 0
var failed := 0


func _initialize() -> void:
	if not FileAccess.file_exists(DIR + "scenarios.json"):
		print("fixtures missing: they are committed in git (restore with git checkout)")
		quit(1)
		return
	t_scenarios()
	t_rules()
	t_signals_and_misc()
	print("%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func ok(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		if failed <= 15:
			print("FAIL: ", msg)


func load_json(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(DIR + name + ".json"))


func t_scenarios() -> void:
	for sc in load_json("scenarios"):
		var v := DmLootView.new()
		root.add_child(v)
		var hero := Vector3.ZERO
		var bag := [true]
		v.try_take = func(_d): return bag[0]
		var n := 0
		for op in sc["ops"]:
			n += 1
			var tag := "%s#%d" % [sc["name"], n]
			match op["op"]:
				"hero":
					hero = Vector3(op["x"], 0, op["z"])
				"bag":
					bag[0] = op["open"]
				"gold":
					var p: Dictionary = op["placed"][0]
					v.gold(Vector3(p["x"], 0, p["z"]), int(op["amount"]), true)
				"shard":
					for p in op["placed"]:
						v.shard(Vector3(p["x"], 0, p["z"]), 1, true)
				"item":
					var p: Dictionary = op["placed"][0]
					v.item(Vector3(p["x"], 0, p["z"]), op["drop"], true)
				"tick":
					var ev := v.tick(op["dt"], hero)
					var g := 0
					var s := 0
					var items: Array = []
					for e in ev:
						match e["kind"]:
							"gold": g += int(e["amount"])
							"shard": s += int(e["amount"])
							"item": items.append(e["item"]["item_id"])
					ok(g == int(op["gold"]) and s == int(op["shards"]) and items == op["items"], "%s events got g%d s%d %s want g%d s%d %s" % [tag, g, s, items, op["gold"], op["shards"], op["items"]])
					ok(v.count() == int(op["count"]), "%s count %d want %d" % [tag, v.count(), op["count"]])
					var left: Array = []
					for d in v.debug_drops():
						left.append([d["kind"], d["id"], 1 if d["prize"] else 0, d["ttl"]])
					ok(str(left) == str(op["left"]).replace("1, ", "1, ") or _left_eq(left, op["left"]), "%s survivors differ" % tag)
				"clear":
					var n_rm := v.clear_within(Rect2(op["x0"], op["z0"], op["x1"] - op["x0"], op["z1"] - op["z0"]))
					ok(n_rm == int(op["n"]) and v.count() == int(op["count"]), "%s clear %d want %d" % [tag, n_rm, op["n"]])
		v.free()


func _left_eq(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var x: Array = a[i]
		var y: Array = b[i]
		if str(x[0]) != str(y[0]) or str(x[1]) != str(y[1]) or int(x[2]) != int(y[2]) or absf(float(x[3]) - float(y[3])) > 1e-9:
			return false
	return true


func t_rules() -> void:
	var v := DmLootView.new()
	root.add_child(v)
	var rows: Array = load_json("rules")
	for r in rows:
		v.rules = r["rules"]
		var keep: bool = r["keep"]
		v.keep = (func(_s): return true) if keep else Callable()
		var got := v.item_action(r["drop"])
		ok(got == r["action"], "rule %s %s keep=%s: got %s want %s" % [r["drop"]["item_id"], r["rules"], keep, got, r["action"]])
		# through drop(): 'gold' pays sell value (signal), 'auto' needs the bag, otherwise the item lies on the ground
		var paid := [-1]
		var cb := func(g: int, _d: Dictionary, _p: Vector3): paid[0] = g
		v.auto_sold.connect(cb)
		v.try_take = func(_d): return true
		var before := v.count()
		var res := v.drop(r["drop"], Vector3.ZERO)
		v.auto_sold.disconnect(cb)
		ok(res == r["action"], "drop() outcome %s want %s" % [res, r["action"]])
		ok((paid[0] == int(r["gold"])) if res == "gold" else (paid[0] == -1), "gold paid %d want %d" % [paid[0], r["gold"]])
		ok(v.count() == before + (1 if res == "ground" else 0), "ground count after %s" % res)
		if res == "auto":
			# bag full: auto-loot falls back to the ground
			v.try_take = func(_d): return false
			var b2 := v.count()
			ok(v.drop(r["drop"], Vector3.ZERO) == "ground" and v.count() == b2 + 1, "auto with full bag lands on the ground")
		v.clear_all()
	v.free()


func t_signals_and_misc() -> void:
	var v := DmLootView.new()
	root.add_child(v)
	v.rand = func(): return 0.5
	var exp := []
	v.expired.connect(func(d, reason): exp.append([d["kind"], reason]))
	var snd := []
	v.dropped_sound.connect(func(id, _p): snd.append(id))
	v.drop({"item_id": "leg_legion_unburied_head", "quantity": 1}, Vector3(5, 0, 5))
	v.drop({"item_id": "ore_copper", "quantity": 1}, Vector3(5, 0, 5))
	ok(snd == ["lootDropLegendary", "lootDrop"], "drop sounds %s" % [snd])
	# default scatter lands within 0.3..1.0 of the origin
	var d0 := v.debug_drops()[0]
	var dist := Vector2(d0["x"] - 5, d0["z"] - 5).length()
	ok(dist >= 0.3 and dist <= 1.0 + 1e-6, "scatter radius %f" % dist)
	v.tick(61.0, Vector3(99, 0, 99))
	ok(v.count() == 0 and exp.size() == 2 and exp[0][1] == "ttl", "ttl expiry signals %s" % [exp])
	# cap signal reason
	exp.clear()
	for i in 62:
		v.item(Vector3(0, 0, 0), {"item_id": "ore_copper", "quantity": 1})
	v.tick(0.01, Vector3(99, 0, 99))
	ok(v.count() == 60 and exp.size() == 2 and exp[0][1] == "cap", "cap signal %d" % exp.size())
	# prize flag + 60 s ttl for every kind
	v.clear_all()
	v.item(Vector3.ZERO, {"item_id": "leg_legion_unburied_head", "quantity": 1})
	ok(v.debug_drops()[0]["prize"] and v.debug_drops()[0]["ttl"] == 60.0, "prize ttl 60")
	# gold magnet pickup emits picked + pickup_fx
	v.clear_all()
	var got := []
	v.picked.connect(func(e): got.append(e["kind"]))
	v.gold(Vector3(1, 0, 0), 9, true)
	for i in 120:
		v.tick(1.0 / 60.0, Vector3.ZERO)
	ok(got == ["gold"], "gold picked signal %s" % [got])
	v.free()
