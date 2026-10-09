class_name DmMockGame
extends Node
## A stand-in for DmGame (godot/game/dm_game.gd, built by game-core) that implements godot/GAME_CONTRACT.md on top of DmApi with a RECORDING
## mock transport (never the live server). Used by tests/game_ui and by shoot.sh. `calls` logs every request as {method, path, body}.
## `replies` maps a path (query stripped) to the `data` of a {success:true} reply, or a Callable(body)->Variant; `fail` maps a path to an error string.

signal character_changed
signal inventory_changed
signal progress_changed
signal area_changed(id: String)
signal hero_died
signal hero_respawned
signal game_event(event_id: String, ctx: Dictionary)
signal npc_interact(npc_id: String)
signal station_interact(station_id: String)

var api: DmApi
var character: Dictionary = {"id": 7, "class_index": 1, "class_name": "Gravecaller", "level": 12, "experience": 4200, "gold": 1500, "shards": 3,
	"stat_str": 5, "stat_agi": 5, "stat_int": 9, "stat_vit": 6, "auto_combat_allowed": false}
var slots: Array = []
var progress: Dictionary = {}
var dev_access := false
var settings: Dictionary = {}
var sim: Object = null
var hero_id := 1
var area_id := "chapterhouse"
var in_depths := false
var lootview: Object = null
var camera: Camera3D = null
var loadout: Dictionary = {}

var calls: Array = []
var replies: Dictionary = {}
var fail: Dictionary = {}
var casts: Array = []
var belt_uses: Array = []
var auto_combat := false
var applied_settings: Array = []
var refreshes := {"character": 0, "inventory": 0, "progress": 0}
var hud: Dictionary = {}
var set_rites_calls: Array = []
var hero_pos := Vector2(0, 20)
var party_code := ""
var party_calls: Array = []
var chats: Array = []
var psync := MockPsync.new()   ## spend_on_server passthrough (the real one also adopts the server gold)


class MockPsync:
	func spend_on_server(call: Callable) -> DmResult:
		return await call.call()


func _init() -> void:
	api = DmApi.new(Callable(self, "_transport"))
	api.base_url = ""
	api.set_token("offline:test")
	progress = DmProgression.blank()
	settings = DmMockGame.default_settings()
	slots = DmMockGame.sample_slots()
	hud = {"hp": 900, "max_hp": 1200, "essence": 40, "max_essence": 100, "level": 12, "xp": 4200, "xp_next": 6000, "gold": 1500, "shards": 3,
		"area_name": "Chapterhouse", "slots": [], "souls": 0, "souls_max": 10, "thralls": 0, "thrall_cap": 8, "raises_thralls": true,
		"damage": {"tier": 0, "pct": 0, "cost": 100}, "wave": {"owned": 0, "active": 0, "pct": 0, "cost": 200}}


static func default_settings() -> Dictionary:
	return {"difficulty": "medium", "auto_combat": false, "auto_gather": false, "loot_common": "ground", "loot_uncommon": "ground", "loot_rare": "ground",
		"loot_epic": "ground", "loot_legendary": "ground", "graphics": "high", "fps": 0, "auto_res": true, "brightness": 1.0, "vol_master": 0.7, "vol_combat": 0.8,
		"vol_amb": 0.6, "vol_music": 0.5, "vol_ui": 0.8, "reduce_motion": false, "damage_numbers": true, "hide_helm": false, "no_tips": false,
		"guidance": true, "guide_ping": true, "dev_access": false}


static func sample_slots() -> Array:
	var rows: Array = []
	var add := func(i: int, id: String, nm: String, rar: String, typ: String, q: int, eq: int, sv: int, extra: Dictionary) -> void:
		var r := {"id": 100 + i, "slot_index": i, "item_id": id, "name": nm, "rarity": rar, "item_type": typ, "quantity": q, "equipped": eq, "sell_value": sv, "stat_bonus": null}
		r.merge(extra, true)
		rows.append(r)
	add.call(0, "staff_oak", "Oak Staff", "common", "weapon", 1, 0, 12, {"stat_bonus": {"stat_int": 2}})
	add.call(1, "flask_hp_minor", "Minor Mending Flask", "common", "consumable", 3, 0, 4, {})
	add.call(2, "tool_pickaxe_iron", "Iron Pickaxe", "uncommon", "weapon", 1, 0, 20, {})
	add.call(3, "ring_copper", "Copper Ring", "uncommon", "ring", 1, 0, 30, {"stat_bonus": {"stat_vit": 1}})
	add.call(4, "material_copper_shard", "Copper Shard", "common", "material", 14, 0, 2, {})
	add.call(5, "elixir_moonlight", "Moonlight Elixir", "rare", "consumable", 2, 0, 40, {})
	add.call(6, "helm_copper", "Copper Helm", "common", "armor_head", 1, 0, 8, {"stat_bonus": {"stat_vit": 2}})
	add.call(105, "staff_bone", "Bone Staff", "common", "weapon", 1, 1, 90, {"stat_bonus": {"stat_int": 5}})
	return rows


## A scripted API: records the request, answers from `replies` / `fail`, else an empty success.
func _transport(req: Dictionary) -> Dictionary:
	var url := String(req["url"])
	var q := url.find("?")
	var path := url if q < 0 else url.substr(0, q)
	var body: Variant = DmJson.parse(String(req.get("body", "")))
	calls.append({"method": String(req["method"]), "path": path, "body": body if body is Dictionary else {}})
	if fail.has(path):
		return {"status": 400, "text": JSON.stringify({"success": false, "error": fail[path]}), "network_error": false}
	var data: Variant = {}
	if path.begins_with("/api/professions/") or path.begins_with("/api/recipes") or path.begins_with("/api/loadouts/") and not path.ends_with("/save"):
		data = []
	if path.begins_with("/api/labor/"):
		data = {"now": 0, "capMs": 28800000, "totalLevel": 10, "levelsPerSlot": 30, "slots": []}
	elif path.begins_with("/api/contracts/"):
		data = {"day": "2026-10-04", "resetsAt": "2026-10-05T00:00:00Z", "contracts": [], "bonus": {"gold": 0, "claimed": false}, "streak": 0}
	elif path.begins_with("/api/cosmetics/"):
		data = {"totalLevel": 10, "selected": {"cape": null, "pet": null}, "capes": [], "pets": []}
	if replies.has(path):
		var r: Variant = replies[path]
		data = r.call(body) if r is Callable else r
	elif path.begins_with("/api/inventory/") and String(req["method"]) == "GET":
		data = slots
	return {"status": 200, "text": JSON.stringify({"success": true, "data": data}), "network_error": false}


func calls_to(path: String) -> Array:
	return calls.filter(func(c: Dictionary) -> bool: return c["path"] == path)


func clear_calls() -> void:
	calls.clear()


# --- contract methods ---
func party_create() -> void:
	party_calls.append(["create"])


func party_join(code: String) -> void:
	party_calls.append(["join", code])


func party_leave() -> void:
	party_calls.append(["leave"])


func send_chat(text: String) -> void:
	chats.append(text)


func cast(slot: int) -> void:
	casts.append(slot)


func use_belt(slot: String) -> void:
	belt_uses.append(slot)


func navigate(_x: float, _z: float) -> void:
	pass


func set_auto_combat(on: bool) -> void:
	auto_combat = on


func buy_upgrade(kind: String) -> void:
	casts.append("buy:" + kind)


func set_rites(primary: String, keys: Array) -> void:
	loadout = {"primary": primary, "keys": keys}
	set_rites_calls.append(loadout)


func refresh_character() -> void:
	refreshes["character"] += 1
	character_changed.emit()


func bag_remove(slot_index: int, _item_id: String, n: int) -> int:
	var taken := 0
	var out: Array = []
	for s in slots:
		if int(s["slot_index"]) == slot_index and int(s.get("equipped", 0)) == 0 and taken == 0:
			taken = mini(n, int(s["quantity"]))
			var c: Dictionary = s.duplicate(true)
			c["quantity"] = int(c["quantity"]) - taken
			if int(c["quantity"]) > 0:
				out.append(c)
		else:
			out.append(s)
	slots = out
	inventory_changed.emit()
	return taken


func bag_sort(on_moves: Callable = Callable(), is_locked: Callable = Callable()) -> void:
	var moves := {}
	slots = DmBag.sort_bag_slots(slots, moves, is_locked)
	if on_moves.is_valid():
		on_moves.call(moves)
	inventory_changed.emit()


func bag_commit() -> String:
	var r: DmResult = await api.save_inventory(int(character["id"]), DmBag.to_save_payload(slots), DmBag.BAG_SIZE)
	return "" if r.ok else r.error


func refresh_inventory() -> void:
	refreshes["inventory"] += 1
	var r: DmResult = await api.get_inventory(int(character["id"]))
	if r.ok and r.data is Array:
		slots = r.data
	inventory_changed.emit()


func refresh_progress() -> void:
	refreshes["progress"] += 1
	progress_changed.emit()


func apply_settings(s: Dictionary) -> void:
	settings = s.duplicate(true)
	applied_settings.append(settings)


func hud_state() -> Dictionary:
	return hud.duplicate(true)
