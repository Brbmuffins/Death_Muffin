class_name DmInventory
extends RefCounted
## Port of the stateful `Inventory` class of archive/legacy-web:src/gameplay/loot.ts: owns the bag. Pickups merge immediately (optimistic) and flush to
## the server in debounced batches; failed saves keep the local state and retry with backoff. Server replies (load, equip, craft) are the
## source of truth (`replace`), with in-flight / pending local changes replayed on top.
## Timers are driven by `tick(dt)` (the host calls it each frame) so tests are deterministic. Slots are the DmBag/DmLoot row Dictionaries.

signal changed(slots: Array)
## A save was refused or failed. Emitted once per failure streak (not on every retry); `recovered` follows when a later save lands.
signal save_failed(message: String)
signal save_recovered

var api: DmApi
var character_id: int = 0
var slots: Array = []
var state: String = "saved"   # saved | saving | retrying
var last_error: String = ""

var _dirty := false
var _in_flight := false
var _retry_delay := 3.0
var _timer := -1.0
var _held := 0
var _pending: Array = []
var _in_flight_mutations: Array = []


func _init(api_: DmApi = null, character_id_: int = 0) -> void:
	api = api_
	character_id = character_id_


func all() -> Array:
	return slots


static func _item_count(rows: Array, item_id: String) -> int:
	var n := 0
	for s in rows:
		if s["item_id"] == item_id:
			n += int(s["quantity"])
	return n


static func _in_bag(s: Dictionary) -> bool:
	return int(s["slot_index"]) >= 0 and int(s["slot_index"]) < DmLoot.bag_size() and not bool(s.get("equipped", 0))


static func _apply_mutation(rows: Array, m: Dictionary) -> Variant:
	if m["kind"] == "add":
		return DmLoot.add_to_slots(rows, m["drop"])
	var found: Variant = null
	if m.has("slot"):
		for s in rows:
			if int(s["slot_index"]) == int(m["slot"]) and s["item_id"] == m["itemId"] and int(s["quantity"]) > 0 and _in_bag(s):
				found = s
				break
	if found == null:
		for s in rows:
			if s["item_id"] == m["itemId"] and int(s["quantity"]) > 0 and _in_bag(s):
				found = s
				break
	if found == null:
		return rows
	var out: Array = []
	for s in rows:
		if s == found:
			var c: Dictionary = s.duplicate(true)
			c["quantity"] = int(c["quantity"]) - 1
			if int(c["quantity"]) > 0:
				out.append(c)
		else:
			out.append(s)
	return out


static func _reconcile(rows: Array, m: Dictionary) -> Variant:
	var item_id: String = m["drop"]["item_id"] if m["kind"] == "add" else m["itemId"]
	var count := _item_count(rows, item_id)
	if m["kind"] == "add":
		var missing := mini(int(m["drop"]["quantity"]), maxi(0, int(m["countAfter"]) - count))
		if missing > 0:
			var d: Dictionary = m["drop"].duplicate(true)
			d["quantity"] = missing
			return DmLoot.add_to_slots(rows, d)
		return rows
	return _apply_mutation(rows, m) if count > int(m["countAfter"]) else rows


func _emit() -> void:
	changed.emit(slots)


func _schedule(seconds: float) -> void:
	_timer = seconds


## Drive the debounce timer. The host (DmNextUiHost) calls this every frame.
func tick(dt: float) -> void:
	if _timer < 0.0:
		return
	_timer -= dt
	if _timer <= 0.0:
		_timer = -1.0
		flush()


## Server responses (load, equip, craft) are the source of truth.
func replace(rows: Array) -> void:
	if _dirty or _in_flight:
		var merged: Array = rows
		for m in _in_flight_mutations:
			var nxt: Variant = _reconcile(merged, m)
			if nxt == null:
				_schedule(0.3)
				return
			merged = nxt
		for m in _pending:
			var nxt2: Variant = _apply_mutation(merged, m)
			if nxt2 == null:
				_schedule(0.3)
				return
			merged = nxt2
		slots = merged
		_dirty = true
		_schedule(0.3)
	else:
		slots = rows
	_emit()


func add(drop: Dictionary) -> bool:
	var nxt: Variant = DmLoot.add_to_slots(slots, drop)
	if nxt == null:
		return false
	slots = nxt
	_pending.append({"kind": "add", "drop": drop.duplicate(true), "countAfter": _item_count(nxt, drop["item_id"])})
	_dirty = true
	_emit()
	_schedule(1.5)
	return true


func count(item_id: String) -> int:
	return _item_count(slots, item_id)


func consume(item_id: String) -> bool:
	var hit: Variant = null
	for s in slots:
		if s["item_id"] == item_id and int(s["quantity"]) > 0:
			hit = s
			break
	if hit == null:
		return false
	var out: Array = []
	for s in slots:
		if s == hit:
			var c: Dictionary = s.duplicate(true)
			c["quantity"] = int(c["quantity"]) - 1
			if int(c["quantity"]) > 0:
				out.append(c)
		else:
			out.append(s)
	slots = out
	_pending.append({"kind": "consume", "itemId": item_id, "countAfter": count(item_id)})
	_dirty = true
	_emit()
	_schedule(1.5)
	return true


func consume_at(slot_index: int) -> bool:
	var hit: Variant = null
	for s in slots:
		if int(s["slot_index"]) == slot_index and int(s["quantity"]) > 0 and not bool(s.get("equipped", 0)):
			hit = s
			break
	if hit == null:
		return false
	var out: Array = []
	for s in slots:
		if s == hit:
			var c: Dictionary = s.duplicate(true)
			c["quantity"] = int(c["quantity"]) - 1
			if int(c["quantity"]) > 0:
				out.append(c)
		else:
			out.append(s)
	slots = out
	_pending.append({"kind": "consume", "itemId": hit["item_id"], "slot": slot_index, "countAfter": count(hit["item_id"])})
	_dirty = true
	_emit()
	_schedule(1.5)
	return true


## Take `n` of the item out of one bag slot (a sale): the stack shrinks, an emptied slot disappears, and the change is queued for the
## next save like any pickup. Returns how many were taken. A row is never edited in place (it is shared with saves in flight).
func remove_from_slot(slot_index: int, n: int) -> int:
	var taken := 0
	var item_id := ""
	for s in slots:
		if int(s["slot_index"]) == slot_index and _in_bag(s):
			item_id = String(s["item_id"])
			taken = mini(n, int(s["quantity"]))
			break
	if taken <= 0:
		return 0
	var out: Array = []
	for s in slots:
		if int(s["slot_index"]) == slot_index and _in_bag(s):
			var c: Dictionary = s.duplicate(true)
			c["quantity"] = int(c["quantity"]) - taken
			if int(c["quantity"]) > 0:
				out.append(c)
		else:
			out.append(s)
	slots = out
	# One queued mutation per unit keeps replace() able to replay the sale on top of a fresher server reply.
	var left := count(item_id)
	for i in taken:
		_pending.append({"kind": "consume", "itemId": item_id, "slot": slot_index, "countAfter": left + (taken - 1 - i)})
	_dirty = true
	_emit()
	_schedule(1.5)
	return taken


## Save right now and say how it went: "" when the server has the bag, otherwise the reason (also toasted through save_failed).
func commit() -> String:
	await _settle()
	await flush()
	await _settle()
	if _dirty or state == "retrying":
		return last_error if last_error != "" else "Your bag could not be saved."
	return ""


## The Reliquary's Sort button; `on_moves(moves: Dictionary)` runs before the emit (slot-keyed state follows).
func sort_bag(on_moves: Callable = Callable(), is_locked: Callable = Callable()) -> void:
	var moves := {}
	slots = DmLoot.sort_bag_slots(slots, moves, is_locked)
	if on_moves.is_valid():
		on_moves.call(moves)
	_dirty = true
	_emit()
	_schedule(0.6)


## Run a server-side bag change with no save in flight (see TS exclusive()). `fn` is a Callable returning (awaitable) anything.
func exclusive(fn: Callable) -> Variant:
	await _settle()
	await flush()
	await _settle()
	_held += 1
	var r: Variant = await fn.call()
	_held -= 1
	if _dirty and _held == 0:
		_schedule(0.3)
	return r


func _settle() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var waited := 0.0
	while _in_flight and tree != null and waited < 15.0:
		await tree.create_timer(0.05).timeout
		waited += 0.05


func flush(keepalive: bool = false) -> void:
	if not _dirty or _held > 0 or api == null:
		return
	if _in_flight:
		if not keepalive:
			return
		_dirty = false
		var r0 := await api.save_inventory(character_id, DmLoot.to_save_payload(slots), DmLoot.bag_size())
		if not r0.ok:
			_dirty = true
		return
	_in_flight = true
	_dirty = false
	state = "saving"
	var sent := slots
	var sent_mutations := _pending
	_pending = []
	_in_flight_mutations = sent_mutations
	var r := await api.save_inventory(character_id, DmLoot.to_save_payload(sent), DmLoot.bag_size())
	if r.ok:
		var was_failing := last_error != ""
		last_error = ""
		if was_failing:
			save_recovered.emit()
		if is_same(slots, sent):
			slots = r.data
		else:
			_dirty = true
		_retry_delay = 3.0
		state = "saved"
		_in_flight_mutations = []
	else:
		_dirty = true
		state = "retrying"
		if last_error == "":
			save_failed.emit(r.error if r.error != "" else "Your bag could not be saved.")
		last_error = r.error if r.error != "" else "Your bag could not be saved."
		_pending = sent_mutations + _pending
		_in_flight_mutations = []
		_retry_delay = minf(60.0, _retry_delay * 2.0)
	_in_flight = false
	_emit()
	if _dirty:
		_schedule(_retry_delay if state == "retrying" else 0.8)


func save_before_class_change() -> String:
	await flush()
	if _dirty or state == "retrying":
		return "Could not save your items. Please try again before changing class."
	return ""
