class_name DmInventory
extends RefCounted
## The bag as the server has it (DECISIONS B25). The client never saves its bag: every change is an operation the server applies and
## answers with its bag (`replace`). Consumables the hero uses (flasks, brews, meals) leave the shown bag at once and reach the server in
## debounced batches (POST /api/inventory/use); failed batches retry with backoff and are replayed on top of any server answer that lands
## first. Pickups, gathering and crafting are written by the server's own routes; `add` only shows an item until the next server answer.
## Timers are driven by `tick(dt)` (the host calls it each frame) so tests are deterministic. Slots are the DmBag/DmLoot row Dictionaries.

signal changed(slots: Array)
## A batch of uses was refused or failed. Emitted once per failure streak (not on every retry); `recovered` follows when a later batch lands.
signal save_failed(message: String)
signal save_recovered

var api: DmApi
var character_id: int = 0
var slots: Array = []
var state: String = "saved"   # saved | saving | retrying
var last_error: String = ""

var _uses: Array = []        # not sent yet: {item_id, slot_index, quantity, count_after}
var _sending: Array = []     # in flight
var _in_flight := false
var _retry_delay := 3.0
var _timer := -1.0
var _held := 0

const MAX_BATCH := 40   # bag-ops.cjs takes at most 40 uses a request (vaultRules.MAX_USES)


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


## Take `n` of the item out of `rows` (the named slot first, then its other bag stacks). A row is never edited in place: it may be shared.
static func _take(rows: Array, item_id: String, slot_index: int, n: int) -> Array:
	var left := n
	var order: Array = rows.filter(func(s: Dictionary) -> bool: return s["item_id"] == item_id and int(s["quantity"]) > 0 and _in_bag(s))
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var am := int(a["slot_index"]) == slot_index
		var bm := int(b["slot_index"]) == slot_index
		return am if am != bm else int(a["slot_index"]) < int(b["slot_index"]))
	var cut := {}
	for s in order:
		if left <= 0:
			break
		var t := mini(left, int(s["quantity"]))
		cut[int(s["slot_index"])] = t
		left -= t
	var out: Array = []
	for s in rows:
		var t := int(cut.get(int(s["slot_index"]), 0)) if _in_bag(s) else 0
		if t <= 0:
			out.append(s)
			continue
		var c: Dictionary = s.duplicate(true)
		c["quantity"] = int(c["quantity"]) - t
		if int(c["quantity"]) > 0:
			out.append(c)
	return out


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


## A server answer (load, a claim, equip, the Vault, a sale, a craft): the truth. Uses not yet in it are applied on top: an in-flight one only
## while the answer still shows more than the hero had left after it, a queued one always.
func replace(rows: Array) -> void:
	var merged: Array = rows
	for u in _sending:
		var extra := _item_count(merged, u["item_id"]) - int(u["count_after"])
		if extra > 0:
			merged = _take(merged, u["item_id"], int(u["slot_index"]), mini(extra, int(u["quantity"])))
	for u in _uses:
		merged = _take(merged, u["item_id"], int(u["slot_index"]), int(u["quantity"]))
	slots = merged
	_emit()


## Show an item in the bag until the next server answer (the server's own route wrote it). False when it does not fit.
func add(drop: Dictionary) -> bool:
	var nxt: Variant = DmLoot.add_to_slots(slots, drop)
	if nxt == null:
		return false
	slots = nxt
	_emit()
	return true


func count(item_id: String) -> int:
	return _item_count(slots, item_id)


## Use one of the item (a flask, brew or meal): it leaves the bag now and the server hears of it in the next batch.
func consume(item_id: String) -> bool:
	for s in slots:
		if s["item_id"] == item_id and int(s["quantity"]) > 0 and _in_bag(s):
			return consume_at(int(s["slot_index"]))
	return false


func consume_at(slot_index: int) -> bool:
	var hit: Variant = null
	for s in slots:
		if int(s["slot_index"]) == slot_index and int(s["quantity"]) > 0 and _in_bag(s):
			hit = s
			break
	if hit == null:
		return false
	var item_id := String(hit["item_id"])
	slots = _take(slots, item_id, slot_index, 1)
	_uses.append({"item_id": item_id, "slot_index": slot_index, "quantity": 1, "count_after": count(item_id)})
	_emit()
	if _timer < 0.0:
		_schedule(1.5)
	return true


## Send the queued uses now and say how it went: "" when the server has them, otherwise the reason (also toasted through save_failed).
func commit() -> String:
	await _settle()
	await flush()
	await _settle()
	if not _uses.is_empty() or state == "retrying":
		return last_error if last_error != "" else "Your bag could not be saved."
	return ""


## The Reliquary's Sort: the server sorts its bag (`locked` slots move but never merge) and answers {error, moves: {old slot: new slot}}.
func sort(locked: Array) -> Dictionary:
	var out: Dictionary = await exclusive(func() -> Dictionary:
		var r: DmResult = await api.sort_bag(character_id, locked)
		if not r.ok:
			return {"error": r.error if r.error != "" else "The bag could not be sorted.", "moves": {}}
		replace(r.data["bag"])
		return {"error": "", "moves": r.data["moves"]})
	return out


## Run a server-side bag change with no batch in flight. `fn` is a Callable returning (awaitable) anything.
func exclusive(fn: Callable) -> Variant:
	await _settle()
	await flush()
	await _settle()
	_held += 1
	var r: Variant = await fn.call()
	_held -= 1
	if not _uses.is_empty() and _held == 0:
		_schedule(0.3)
	return r


func _settle() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var waited := 0.0
	while _in_flight and tree != null and waited < 15.0:
		await tree.create_timer(0.05).timeout
		waited += 0.05


## `keepalive` (quitting): send what is queued even while a batch is in flight.
func flush(keepalive: bool = false) -> void:
	if _uses.is_empty() or _held > 0 or api == null:
		return
	if _in_flight:
		if keepalive:
			var extra := _uses
			_uses = []
			var r0 := await api.use_items(character_id, _wire(extra))
			if not r0.ok:
				_uses = extra + _uses
		return
	_in_flight = true
	state = "saving"
	_sending = _uses.slice(0, MAX_BATCH)
	_uses = _uses.slice(MAX_BATCH)
	var r := await api.use_items(character_id, _wire(_sending))
	var sent := _sending
	_sending = []
	if r.ok:
		var was_failing := last_error != ""
		last_error = ""
		if was_failing:
			save_recovered.emit()
		_retry_delay = 3.0
		state = "saved"
		replace(r.data["bag"])
	elif r.status > 0 and r.status < 500 and r.status != 429:
		# The server answered and will never take this batch (not this character, malformed): its next answer is the truth.
		state = "saved"
		last_error = ""
	else:
		state = "retrying"
		var msg := r.error if r.error != "" else "Your bag could not be saved."
		if last_error == "":
			save_failed.emit(msg)
		last_error = msg
		_uses = sent + _uses
		_retry_delay = minf(60.0, _retry_delay * 2.0)
	_in_flight = false
	_emit()
	if not _uses.is_empty():
		_schedule(_retry_delay if state == "retrying" else 0.8)


## One line per item and slot (a batch of sips of the same flask is one line).
static func _wire(uses: Array) -> Array:
	var by := {}
	var out: Array = []
	for u in uses:
		var key := "%s|%d" % [u["item_id"], int(u["slot_index"])]
		if by.has(key):
			by[key]["quantity"] = int(by[key]["quantity"]) + int(u["quantity"])
		else:
			by[key] = {"item_id": u["item_id"], "slot_index": int(u["slot_index"]), "quantity": int(u["quantity"])}
			out.append(by[key])
	return out


func save_before_class_change() -> String:
	await flush()
	if not _uses.is_empty() or state == "retrying":
		return "Could not save your items. Please try again before changing class."
	return ""
