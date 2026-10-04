class_name DmItemLocks
extends RefCounted
## Port of src/gameplay/itemLocks.ts: Reliquary item locks + the bulk-action selectors (Sell all junk, Salvage all below rare).
## A lock is the pair slot + item id: if the slot's item changes the lock lapses (prune). Per character; persistence is injected:
## `storage` = any object with get_item(key) -> String ("" / null if absent) and set_item(key, value) (duck-typed; null = in-memory
## only). Stored format matches the web: JSON [[slot, itemId], ...] under "dm_locks_v1_<characterId>".

signal changed

const Salvage := preload("res://rules/gathering/salvage_rules.gd")

const SELL_JUNK_RARITIES: Array = ["common", "uncommon"]

var _locked: Dictionary = {}  # slot_index -> item_id
var _key: String
var _storage: Object


static func locks_storage_key(character_id: int) -> String:
	return "dm_locks_v1_%d" % character_id


func _init(character_id: int = 0, storage: Object = null) -> void:
	_key = locks_storage_key(character_id)
	_storage = storage
	if _storage == null:
		return
	var raw: Variant = _storage.get_item(_key)
	if raw == null or str(raw) == "":
		return
	var parsed: Variant = JSON.parse_string(str(raw))
	if parsed is Array:
		for e in parsed:
			if e is Array and e.size() >= 2 and (e[0] is int or (e[0] is float and e[0] == floorf(e[0]))) and e[1] is String:
				_locked[int(e[0])] = e[1]


func is_locked(slot: Dictionary) -> bool:
	return _locked.get(int(slot["slot_index"]), null) == slot["item_id"]


## Slot indexes of the locked items (the server's exceptSlots).
func slots_of(slots: Array) -> Array:
	var out: Array = []
	for s in slots:
		if is_locked(s):
			out.append(int(s["slot_index"]))
	return out


## Returns the new locked state.
func toggle(slot: Dictionary) -> bool:
	var now := not is_locked(slot)
	if now:
		_locked[int(slot["slot_index"])] = slot["item_id"]
	else:
		_locked.erase(int(slot["slot_index"]))
	_save()
	return now


## Follow items that changed slot: moves = {old_index: new_index}.
func remap(moves: Dictionary) -> void:
	var nxt: Dictionary = {}
	for index in _locked:
		if moves.has(index):
			nxt[int(moves[index])] = _locked[index]
	_locked = nxt
	_save()


## Drop locks whose slot no longer holds that item (call on every bag change).
func prune(slots: Array) -> void:
	var changed_any := false
	for index in _locked.keys():
		var found := false
		for s in slots:
			if int(s["slot_index"]) == index and s["item_id"] == _locked[index]:
				found = true
				break
		if not found:
			_locked.erase(index)
			changed_any = true
	if changed_any:
		_save()


func to_json() -> String:
	var arr: Array = []
	for k in _locked:
		arr.append([k, _locked[k]])
	return JSON.stringify(arr)


func _save() -> void:
	if _storage != null:
		_storage.set_item(_key, to_json())
	changed.emit()


# ── Bulk selectors (static; `locks` is anything with is_locked(slot), `keep` an optional Callable(slot) -> bool,
#    `affix_is_necro` an optional Callable(affix {id, v}) -> bool from the loot track's affix rules) ──

static func _has_necro_affix(s: Dictionary, affix_is_necro: Callable) -> bool:
	if not s.has("inst") or s["inst"] == null or not affix_is_necro.is_valid():
		return false
	for a in s["inst"]["affixes"]:
		if affix_is_necro.call(a):
			return true
	return false


static func _bulk_ok(s: Dictionary, locks: Object, keep: Callable, affix_is_necro: Callable) -> bool:
	return int(s["equipped"]) == 0 and int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 100 \
		and Salvage.is_salvage_gear(s["item_type"]) and SELL_JUNK_RARITIES.has(s["rarity"]) \
		and not locks.is_locked(s) and not _has_necro_affix(s, affix_is_necro) and not (keep.is_valid() and keep.call(s))


## Bag slots "Sell all junk" would sell: unlocked, unequipped common/uncommon gear with a sell value (and no necromancer affix).
static func junk_slots(slots: Array, locks: Object, keep: Callable = Callable(), affix_is_necro: Callable = Callable()) -> Array:
	var out: Array = []
	for s in slots:
		if _bulk_ok(s, locks, keep, affix_is_necro) and float(s["sell_value"]) > 0.0:
			out.append(s)
	return out


## Gear the Bone Grinder's "Salvage all below rare" takes.
static func salvage_below_rare(slots: Array, locks: Object, keep: Callable = Callable(), affix_is_necro: Callable = Callable()) -> Array:
	var out: Array = []
	for s in slots:
		if _bulk_ok(s, locks, keep, affix_is_necro):
			out.append(s)
	return out
