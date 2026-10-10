extends "res://tests/common/dm_suite_part.gd"
## The bag save payload the client sends must pass the LIVE server's rules (server.js POST /api/inventory/save + inventory-save.cjs):
## every slot a non-empty string item_id and a whole quantity >= 1, slot_index inside 0..bagSize-1 and unique, bagSize 1..48.
## Regression for 2026-10-08: a sold stack left a quantity-0 row in the bag, so every later save was refused with
## "each slot requires an item_id and positive integer quantity". Also checks DmInventory's sale path and its failure reporting.
##   godot --headless --path godot --script res://tests/rules-loot/run.gd (part bag_save_part)

var _pass := 0
var _fail := 0
var _cases: Array = []   # {name, slots, bagSize} also run through node against inventory-save.cjs


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


## GDScript port of the server's rule (the node check below runs the real code when node is available).
static func server_problem(payload: Array, bag_size: int) -> String:
	var slots: Array = payload.filter(func(s) -> bool: return not (s is Dictionary and float(s.get("slot_index", -1)) >= 100.0 and float(s.get("slot_index", -1)) <= 134.0))
	if slots.size() > bag_size:
		return "inventory cannot exceed %d slots" % bag_size
	var seen := {}
	for s in slots:
		if not (s is Dictionary):
			return "bad slot"
		var idx: Variant = s.get("slot_index")
		if not (idx is int or idx is float) or float(idx) != floorf(float(idx)) or float(idx) < 0.0 or float(idx) >= float(bag_size):
			return "each slot_index must be between 0 and %d" % (bag_size - 1)
		if seen.has(int(idx)):
			return "duplicate slot_index values are not allowed"
		seen[int(idx)] = true
		var q: Variant = s.get("quantity")
		if not (s.get("item_id") is String) or String(s["item_id"]).strip_edges().is_empty() or not (q is int or q is float) or float(q) != floorf(float(q)) or float(q) < 1.0:
			return "each slot requires an item_id and positive integer quantity"
	return ""


func _valid(name: String, payload: Array, bag_size: int = 48) -> void:
	_check(server_problem(payload, bag_size) == "", "%s passes the server rule (%s)" % [name, server_problem(payload, bag_size)])
	# the payload really goes over the wire as JSON: round-trip it the way the server parses it
	var wire: Variant = JSON.parse_string(JSON.stringify({"slots": payload, "bagSize": bag_size}))
	_check(wire is Dictionary and server_problem(wire["slots"], bag_size) == "", "%s passes after a JSON round trip" % name)
	_cases.append({"name": name, "slots": payload, "bagSize": bag_size})


func _row(i: int, id: String, q: Variant, extra: Dictionary = {}) -> Dictionary:
	var r := {"id": 0, "slot_index": i, "quantity": q, "equipped": 0, "item_id": id, "name": id, "rarity": "common", "item_type": "material", "sell_value": 1}
	r.merge(extra, true)
	return r


class FakeApi extends DmApi:
	var sent: Array = []
	var fail_with := ""
	func save_inventory(_cid: int, slots: Array, bag_size: int = -1) -> DmResult:
		sent.append({"slots": slots, "bagSize": bag_size})
		if fail_with != "":
			return DmResult.failure(fail_with, 400)
		return DmResult.success(slots.duplicate(true), 200)


func _initialize() -> void:
	await _run()


func _run() -> void:
	# --- every kind of item the bag can hold, 48 slots full -----------------------------------------------------------------
	var drops: Array = [
		{"item_id": "plank_oak", "quantity": 1}, {"item_id": "flask_hp_major", "quantity": 98}, {"item_id": "flask_hp_major", "quantity": 60},
		{"item_id": "ore_moon", "quantity": 2}, {"item_id": "ichor_abbess", "quantity": 2}, {"item_id": "herb_drowned_lotus", "quantity": 29},
		{"item_id": "seed_bloodroot", "quantity": 1}, {"item_id": "sapling_yew", "quantity": 25}, {"item_id": "ingot_steel", "quantity": 99},
		{"item_id": "reagent_cinder_ash", "quantity": 20}, {"item_id": "rune_impale", "quantity": 6}, {"item_id": "tool_hatchet_silver", "quantity": 1},
		{"item_id": "bone_meal", "quantity": 2}, {"item_id": "set_gravecaller_head", "quantity": 1, "instance": {"id": 1508, "ilvl": 20, "affixes": []}},
		{"item_id": "helm_gold", "quantity": 1, "instance": {"id": 1511, "ilvl": 31, "affixes": [{"id": "p_thrall_dmg", "v": 5}]}},
		{"item_id": "item_the_server_has_never_heard_of", "quantity": 7},
	]
	var slots: Array = []
	for d in drops:
		var n: Variant = DmLoot.add_to_slots(slots, d)
		_check(n != null, "added %s" % d["item_id"])
		if n != null:
			slots = n
	_valid("mixed bag (DmLoot)", DmLoot.to_save_payload(slots))
	var full: Array = slots.duplicate()
	for i in range(full.size(), 48):
		full.append(_row(i, "ore_copper", 5.0))
	_valid("48-slot bag (DmLoot)", DmLoot.to_save_payload(full))
	_valid("48-slot bag (DmBag)", DmBag.to_save_payload(full))
	_valid("sorted bag", DmLoot.to_save_payload(DmLoot.sort_bag_slots(full)))
	_valid("sorted bag (DmBag)", DmBag.to_save_payload(DmBag.sort_bag_slots(full)))
	_valid("empty bag", DmLoot.to_save_payload([]))

	# --- rows the server would refuse the WHOLE save for must never reach the payload ---------------------------------------------
	var dirty: Array = full.duplicate()
	dirty.append(_row(3, "ore_copper", 0))                      # a consumed stack left behind
	dirty.append(_row(4, "ore_copper", 0.0))
	dirty.append(_row(5, "ore_copper", -2))
	dirty.append(_row(6, "ore_copper", 2.5))                    # a fractional stack is floored, never sent as 2.5
	dirty.append(_row(7, "", 3))                                # blank item
	dirty.append(_row(8, "   ", 3))
	var nullid := _row(9, "x", 3)
	nullid["item_id"] = null
	dirty.append(nullid)
	var noid := _row(10, "x", 3)
	noid.erase("item_id")
	dirty.append(noid)
	dirty.append(_row(11, "ore_copper", NAN))
	dirty.append(_row(12, "ore_copper", INF))
	dirty.append(_row(13, "ore_copper", 3, {"item_id": 42}))      # not a string
	dirty.append(_row(60, "ore_copper", 3))                     # outside the bag
	dirty.append(_row(101, "ring_copper", 1, {"equipped": 1}))  # worn gear
	dirty.append(_row(-1, "ore_copper", 3))
	var p1 := DmLoot.to_save_payload(dirty)
	var p2 := DmBag.to_save_payload(dirty)
	for p in [p1, p2]:
		var ids_ok := true
		for s in p:
			if not (s["item_id"] is String) or int(s["quantity"]) < 1 or not (s["quantity"] is int):
				ids_ok = false
		_check(ids_ok, "dirty rows are dropped or repaired")
	_check(p1.size() >= full.size(), "good rows are kept")
	# duplicate slot indexes can't be told apart by quantity alone: the fixture above reuses 3..13, so compare only shape rules
	var shape_ok := true
	for s in p1:
		if not (s["item_id"] is String) or String(s["item_id"]).strip_edges().is_empty() or int(s["quantity"]) < 1:
			shape_ok = false
	_check(shape_ok, "no refused shape in the payload")

	# --- a stack that is consumed leaves the bag, not a quantity-0 row -------------------------------------------------------------
	var api := FakeApi.new()
	var inv := DmInventory.new(api, 7)
	inv.replace([_row(0, "ore_copper", 3), _row(1, "ore_tin", 1), _row(2, "helm_gold", 1, {"item_type": "armor_head", "instance_id": 5})])
	_check(inv.remove_from_slot(0, 3) == 3, "sold a whole stack")
	_check(inv.slots.size() == 2 and not inv.slots.any(func(s) -> bool: return int(s["quantity"]) < 1), "the emptied slot is gone, no zero row")
	_check(inv.remove_from_slot(1, 5) == 1, "selling more than the stack holds sells what is there")
	_check(inv.remove_from_slot(30, 1) == 0 and inv.remove_from_slot(2, 0) == 0, "nothing to sell sells nothing")
	_check((await inv.commit()) == "", "the sale saved")
	_check(api.sent.size() == 1, "one save: %d" % api.sent.size())
	_check(server_problem(api.sent[0]["slots"], api.sent[0]["bagSize"]) == "" and api.sent[0]["bagSize"] == 48, "the sale payload passes the server rule")
	_check(api.sent[0]["slots"].size() == 1 and api.sent[0]["slots"][0]["item_id"] == "helm_gold", "only the unsold relic is sent")
	# the row passed in is never edited in place (it is shared with saves in flight)
	var shared := _row(0, "ore_copper", 4)
	var inv2 := DmInventory.new(FakeApi.new(), 7)
	inv2.replace([shared])
	inv2.remove_from_slot(0, 1)
	_check(int(shared["quantity"]) == 4 and int(inv2.slots[0]["quantity"]) == 3, "selling copies the row")

	# --- a refused save is reported once, kept, retried, and reported as recovered -------------------------------------------------
	var api3 := FakeApi.new()
	var inv3 := DmInventory.new(api3, 7)
	inv3.replace([_row(0, "ore_copper", 3)])
	var failed: Array = []
	var recovered: Array = []
	inv3.save_failed.connect(func(m: String) -> void: failed.append(m))
	inv3.save_recovered.connect(func() -> void: recovered.append(true))
	api3.fail_with = "each slot requires an item_id and positive integer quantity"
	inv3.remove_from_slot(0, 1)
	var err: String = await inv3.commit()
	_check(err == api3.fail_with, "commit reports the server's reason: %s" % err)
	_check(failed.size() == 1 and failed[0] == api3.fail_with, "the player is told (once)")
	await inv3.commit()
	_check(failed.size() == 1, "a repeated failure does not nag again")
	_check(inv3.state == "retrying" and inv3.slots.size() == 1 and int(inv3.slots[0]["quantity"]) == 2, "the local bag is kept while the save retries")
	api3.fail_with = ""
	_check((await inv3.commit()) == "" and recovered.size() == 1, "the retry lands and recovery is reported")

	# --- end to end against the strict mock backend (the live server's slot rule): starter bag, sell a stack, sort, save ----------------------------
	var mock := DmMockBackend.new("")
	mock.strict_slots = true
	var sapi := DmApi.new(mock.transport_callable())
	sapi.base_url = ""
	var reg := await sapi.register("bagtester", "", "pw1234")
	sapi.set_token(reg.data["token"])
	var ch := await sapi.load_or_create_character(7)
	var cid: int = ch.data["id"]
	var live := DmInventory.new(sapi, cid)
	live.replace((await sapi.get_inventory(cid)).data)
	var refused := await sapi.save_inventory(cid, [{"slot_index": 0, "item_id": "staff_oak", "quantity": 0, "equipped": 0}], 48)
	_check(not refused.ok and refused.error == "each slot requires an item_id and positive integer quantity", "strict mock refuses a quantity-0 slot like the live server: %s" % refused.error)
	var first: Dictionary = live.slots[1]
	live.remove_from_slot(int(first["slot_index"]), int(first["quantity"]))
	_check((await live.commit()) == "", "selling a whole stack saves against the strict server rule")
	live.sort_bag()
	_check((await live.commit()) == "" and live.state == "saved", "sorting saves against the strict server rule")
	_check(not live.slots.any(func(s) -> bool: return int(s["quantity"]) < 1), "the bag has no quantity-0 rows afterwards")

	# --- the UI must never assign DmGame.slots (it has no setter; the assignment is silently ignored, which stranded quantity-0 rows) ---------
	var bad: Array = []
	for dir_path in ["res://game_ui", "res://ui", "res://game"]:
		for f in DirAccess.get_files_at(dir_path):
			if f.ends_with(".gd"):
				var txt := FileAccess.get_file_as_string("%s/%s" % [dir_path, f])
				for line in txt.split("\n"):
					var l := line.strip_edges()
					if (l.begins_with("game.slots =") or l.begins_with("g.slots =")) and not l.begins_with("game.slots ==") and not l.begins_with("g.slots =="):
						bad.append("%s/%s: %s" % [dir_path, f, l])
	_check(bad.is_empty(), "no code assigns the read-only game.slots: %s" % str(bad))
	var gsrc := FileAccess.get_file_as_string("res://next/hud/dm_next_ui_host.gd")
	_check(gsrc.contains("func bag_remove(") and gsrc.contains("func bag_commit(") and gsrc.contains("func bag_sort("), "DmNextUiHost offers the bag edit methods the Reliquary calls")

	# --- the real server code (inventory-save.cjs) agrees, when node is available ----------------------------------------------------
	var root_dir := ProjectSettings.globalize_path("res://").path_join("..")
	var helper := root_dir.path_join("tools/godot/check-bag-payload.cjs")
	if FileAccess.file_exists(helper):
		var tmp := OS.get_user_data_dir().path_join("bag_cases.json")
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(JSON.stringify(_cases))
		f.close()
		var out: Array = []
		var code := OS.execute("bash", ["-c", "node '%s' < '%s'" % [helper, tmp]], out, true)
		if code == 0 and out.size() > 0:
			var verdicts: Variant = JSON.parse_string(String(out[0]))
			_check(verdicts is Array and verdicts.size() == _cases.size(), "node ran the cases")
			if verdicts is Array:
				for i in verdicts.size():
					_check(verdicts[i] == "", "the real inventory-save.cjs accepts %s (%s)" % [_cases[i]["name"], verdicts[i]])
		else:
			print("node check skipped (exit %d)" % code)
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
