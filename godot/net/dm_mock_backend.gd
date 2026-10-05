class_name DmMockBackend
extends RefCounted
## The offline edition's backend (port of src/net/mockBackend.ts, plus the server rules it delegates to): the in-process stand-in for the
## Death Muffin server. Plug it in as the transport:   var mock := DmMockBackend.new();  var api := DmApi.new(mock.transport_callable());  api.base_url = ""
## State lives in one JSON file (user://dm_offline_db.json by default; "" = memory only), written atomically (tmp file + rename) after every
## request that changed it, so a relaunch finds exactly what the last reply promised. Tokens are "offline:<username>".
##
## Every route the game calls works: auth, character, inventory (save/equip/belt/kit/rune), loot roll, loadouts (save/delete/apply), professions,
## recipes, craft, gather (+afk), salvage, reforge, boss-key, Ossuary Vault, labor, garden, cosmetics, contracts, chronicle, necro progression
## (save/purchase/summons/ascend/vows/unlock/boon/import), bug reports, prefs, session, offline snapshot/versions, leaderboard, kills/report.
## Rules come from the already-ported modules (rules/gathering, rules/inventory, rules/loot, rules/progression, rules/combat); the wording of every
## refusal is the web mock's / the server's. One deliberate difference: a failure after items were already taken (full bag on craft output,
## contract reward, labor/garden placement) restores the bag, as the server's transaction does; the web mock keeps the half-done state.
## Item definitions come from `catalog` (item_id -> {name, rarity, item_type, stat_bonus, sell_value, stack}); empty = built from the game content.
## Randomness: `rng` (Callable -> float in [0,1), default randf) and the clock `now_ms` are injectable for tests.

const BAG := 48
const DEFAULT_BAG_SAVE := 24
const CLASS_NAMES := ["Engineer", "Guardian", "Shadowblade", "Cleric", "Arcanist", "Necromancer"]
const DISCIPLINE_NAMES := {5: "Grave Warden", 6: "Bell Monk", 7: "Carrion Witch", 8: "Hollow Knight", 9: "Veilwalker"}
const MAX_DISCIPLINE_INDEX := 9
const RESERVED := {"head": 100, "chest": 101, "legs": 102, "feet": 103, "hands": 104, "main_hand": 105, "off_hand": 106, "ring": 107, "trinket": 108}
const TYPE_TO_SLOT := {"weapon": "main_hand", "armor_head": "head", "armor_chest": "chest", "armor_legs": "legs", "armor_feet": "feet", "armor_hands": "hands", "offhand": "off_hand", "ring": "ring", "trinket": "trinket"}
const MAX_PRESETS := 6
const FIRST_CHARACTER_ID := 9000
const DROP_SOURCES := ["kill", "elite", "boss", "first_kill", "surge"]
const CANT_VERIFY := "One of your relics could not be verified. Reload the game to refresh your Reliquary."
const SESSION_FREE := ["/api/health", "/health", "/login", "/register", "/leaderboard", "/api/recipes"]

var catalog: Dictionary = {}
var persist_path: String = "user://dm_offline_db.json"
var db: Dictionary = {"next_character_id": FIRST_CHARACTER_ID, "accounts": {}}
## Wall clock source (ms), injectable for tests.
var now_ms: Callable = Callable()
## Random source for every roll (loot, gather, salvage, reforge, harvest...), injectable for tests.
var rng: Callable = Callable()
var _last_saved := ""
var _recipes_cache: Array = []

func _init(path: String = "user://dm_offline_db.json") -> void:
	persist_path = path
	_load()

func transport_callable() -> Callable:
	return Callable(self, "transport")

## Transport adapter (see DmHttpTransport for the contract).
func transport(req: Dictionary) -> Dictionary:
	var url := String(req["url"])
	var qpos := url.find("?")
	var path := url if qpos < 0 else url.substr(0, qpos)
	var query := "" if qpos < 0 else url.substr(qpos + 1)
	var body: Variant = DmJson.parse(String(req.get("body", "")))
	var auth := String(req.get("headers", {}).get("Authorization", ""))
	var token: Variant = auth.substr(7) if auth.begins_with("Bearer ") else null
	var res := handle(String(req["method"]).to_upper(), path, query, body if body is Dictionary else {}, token)
	return {"status": res["status"], "text": JSON.stringify(res["body"]), "network_error": false}

# --- persistence -------------------------------------------------------------------------------------------------------------------

func _load() -> void:
	if persist_path.is_empty() or not FileAccess.file_exists(persist_path):
		return
	var v: Variant = DmJson.parse(FileAccess.get_file_as_string(persist_path))
	if v is Dictionary and v.has("accounts"):
		db = v
		if not db.has("next_character_id"):
			db["next_character_id"] = FIRST_CHARACTER_ID
		_last_saved = JSON.stringify(db)

## Atomic: write a sibling tmp file, then rename it over the real one. Unchanged state is not rewritten.
func _save() -> void:
	if persist_path.is_empty():
		return
	var text := JSON.stringify(db)
	if text == _last_saved:
		return
	var tmp := persist_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.flush()
	f.close()
	stat_writes += 1
	if DirAccess.rename_absolute(tmp, persist_path) == OK:
		_last_saved = text

func _now() -> int:
	return int(now_ms.call()) if now_ms.is_valid() else int(Time.get_unix_time_from_system() * 1000.0)

func _rand() -> float:
	return float(rng.call()) if rng.is_valid() else randf()

func _rand_callable() -> Callable:
	return Callable(self, "_rand")

## JS Date#toISOString.
func _iso(ms: int) -> String:
	return "%s.%03dZ" % [Time.get_datetime_string_from_unix_time(ms / 1000, false), ms % 1000]

# --- JS-style value helpers --------------------------------------------------------------------------------------------------------

## JS Number(v): null/false -> 0, true -> 1, numeric strings parse, anything else NaN.
static func _to_num(v: Variant) -> float:
	match typeof(v):
		TYPE_NIL: return 0.0
		TYPE_BOOL: return 1.0 if v else 0.0
		TYPE_INT, TYPE_FLOAT: return float(v)
		TYPE_STRING:
			var s := String(v).strip_edges()
			if s.is_empty():
				return 0.0
			return s.to_float() if s.is_valid_float() else NAN
	return NAN

## Number(body[k]); NaN when the key is absent (undefined).
static func _num(d: Dictionary, k: String) -> float:
	return _to_num(d[k]) if d.has(k) else NAN

static func _is_int(f: float) -> bool:
	return not is_nan(f) and not is_inf(f) and f == floorf(f)

## Number.isInteger(v) on a raw JSON value (no coercion).
static func _is_integer_val(v: Variant) -> bool:
	return (v is int) or ((v is float) and _is_int(v))

## JS truthiness.
static func _truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL: return false
		TYPE_BOOL: return v
		TYPE_INT, TYPE_FLOAT: return float(v) != 0.0 and not is_nan(float(v))
		TYPE_STRING: return not String(v).is_empty()
	return true

## `Number(x) || fallback`.
static func _num_or(v: Variant, fallback: float) -> float:
	var f := _to_num(v)
	return fallback if (f == 0.0 or is_nan(f)) else f

## A whole-number float as int, otherwise the float (keeps JSON integral).
static func _tidy(f: float) -> Variant:
	return int(f) if _is_int(f) and absf(f) < 9.0e15 else f

# --- reply helpers -----------------------------------------------------------------------------------------------------------------

static func _ok(data: Variant) -> Dictionary:
	return {"status": 200, "body": {"success": true, "data": data}}

static func _fail(msg: String) -> Dictionary:
	return {"status": 200, "body": {"success": false, "error": msg}}

static func _err(msg: String, status: int) -> Dictionary:
	return {"status": status, "body": {"success": false, "error": msg}}

# --- item catalogue ----------------------------------------------------------------------------------------------------------------

## The web's MOCK_ITEMS, from the shared game content (content/items.ts).
static func catalog_from_content() -> Dictionary:
	var cat := {}
	var items: Dictionary = DmContent.items()
	for id in items:
		var m: Dictionary = items[id]
		cat[id] = {"name": m.get("name", id), "item_type": m.get("type", "material"), "rarity": m.get("rarity", "common"),
			"stat_bonus": m.get("offlineStats"), "sell_value": int(m.get("sell", 0)), "stack": m.get("stack")}
	return cat

func _cat() -> Dictionary:
	if catalog.is_empty():
		catalog = catalog_from_content()
	return catalog

func _def(item_id: String) -> Dictionary:
	return _cat().get(item_id, {})

func _has_def(item_id: String) -> bool:
	return _cat().has(item_id)

func _type_of(item_id: String) -> String:
	return String(_def(item_id).get("item_type", "material"))

func _is_gear_item(item_id: String) -> bool:
	return _has_def(item_id) and DmSalvage.is_salvage_gear(_type_of(item_id))

## ITEMS[id]?.stack ?? fallback
func _stack_of(item_id: String, fallback: int) -> int:
	var d := _def(item_id)
	# a catalogue filled without stack sizes (DmOffline.make_mock) reads them from the game content
	var s: Variant = d.get("stack") if d.has("stack") else DmContent.items().get(item_id, {}).get("stack")
	return fallback if s == null else int(s)

## The server's max_stack_size: gear never stacks, everything else uses the catalogue cap (99 by default).
func _stack_cap(item_id: String) -> int:
	return 1 if _is_gear_item(item_id) else _stack_of(item_id, 99)

func _is_two_handed(item_id: String) -> bool:
	return bool(_def(item_id).get("two_handed", false)) or DmWeaponLine.is_two_handed(item_id)

## "" when the item cannot be worn.
func _equip_slot(item_id: String) -> String:
	var d := _def(item_id)
	if d.get("equipment_slot", "") is String and RESERVED.has(d.get("equipment_slot", "")):
		return d["equipment_slot"]
	if not _has_def(item_id):
		return ""
	return String(TYPE_TO_SLOT.get(d.get("item_type", "material"), ""))

## The vault/salvage rules' view of an item.
func _vault_info(item_id: String) -> Dictionary:
	var gear := _is_gear_item(item_id)
	return {"maxStack": 1 if gear else _stack_of(item_id, 9999), "itemType": _type_of(item_id), "rarity": String(_def(item_id).get("rarity", "common"))}

func _join(acc: Dictionary, s: Dictionary, i: int) -> Dictionary:
	var d := _def(String(s["item_id"]))
	var out := {"id": i + 1, "slot_index": int(s["slot_index"]), "quantity": int(s["quantity"]), "equipped": 1 if s.get("equipped", 0) else 0,
		"item_id": s["item_id"], "name": d.get("name", s["item_id"]), "rarity": d.get("rarity", "common"), "item_type": d.get("item_type", "material"),
		"stat_bonus": d.get("stat_bonus"), "icon_id": null, "sell_value": int(d.get("sell_value", 0)), "crafted": 0}
	var iid: Variant = s.get("instance_id")
	if iid != null and _truthy(iid):
		var roll: Variant = acc.get("instances", {}).get(str(int(iid)))
		if roll != null:
			out["instance_id"] = int(iid)
			out["ilvl"] = roll["ilvl"]
			out["affixes"] = roll["affixes"]
	return out

func _rows(acc: Dictionary) -> Array:
	var out: Array = []
	var slots: Array = acc["slots"]
	for i in slots.size():
		out.append(_join(acc, slots[i], i))
	return out

func _instances(acc: Dictionary) -> Dictionary:
	if not acc.has("instances"):
		acc["instances"] = {}
	return acc["instances"]

func _mint_instance(acc: Dictionary, item_id: String, ilvl: int, affixes: Array) -> int:
	var id: int = int(acc.get("nextInstance", 1))
	acc["nextInstance"] = id + 1
	_instances(acc)[str(id)] = {"item_id": item_id, "ilvl": ilvl, "affixes": affixes}
	return id

func _slot_at(acc: Dictionary, index: int) -> Variant:
	for s in acc["slots"]:
		if int(s["slot_index"]) == index:
			return s
	return null

func _free_bag_slot(acc: Dictionary, ignore: Variant = null) -> int:
	for i in BAG:
		var used := false
		for s in acc["slots"]:
			if not (ignore != null and is_same(s, ignore)) and int(s["slot_index"]) == i:
				used = true
				break
		if not used:
			return i
	return -1

func _clone_slots(acc: Dictionary) -> Array:
	return acc["slots"].duplicate(true)

# --- routing -----------------------------------------------------------------------------------------------------------------------

## Perf counters (QA): requests served, time spent routing and saving.
var stat_requests := 0
var stat_route_us := 0
var stat_save_us := 0
var stat_writes := 0

func handle(method: String, path: String, query: String, body: Dictionary, token: Variant) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var res := _route(method, path, query, body, token)
	var t1 := Time.get_ticks_usec()
	_save()
	stat_requests += 1
	stat_route_us += t1 - t0
	stat_save_us += Time.get_ticks_usec() - t1
	return res

func _account_for(token: Variant) -> Variant:
	if not (token is String) or not String(token).begins_with("offline:"):
		return null
	return db["accounts"].get(String(token).substr(8))

func _own(acc: Dictionary, character_id: Variant) -> bool:
	return acc["character"] != null and _to_num(character_id) == float(acc["character"]["id"])

func _character_view(acc: Dictionary) -> Dictionary:
	var c: Dictionary = acc["character"].duplicate()
	c["auto_combat_allowed"] = false
	return c

func _recipes() -> Array:
	if _recipes_cache.is_empty():
		for r in DmRecipes.all():
			var ings: Array = []
			for i in r["ingredients"]:
				ings.append({"item_id": i["item_id"], "quantity": i["quantity"], "name": _def(i["item_id"]).get("name", i["item_id"])})
			_recipes_cache.append({"id": r["id"], "name": r["name"], "profession_id": r["skill"], "skill_level_required": r["skill_level_required"],
				"result_item_id": r["result_item_id"], "result_quantity": r["result_quantity"], "ingredients": ings})
	return _recipes_cache

func _new_account(username: String) -> Dictionary:
	return {"username": username, "character": null, "slots": [], "prefs": {}, "bug_reports": [], "versions": [], "loadouts": {}, "next_version": 1,
		"professions": [{"profession_id": "mining", "skill_level": 1, "skill_xp": 0}, {"profession_id": "fishing", "skill_level": 1, "skill_xp": 0}, {"profession_id": "woodcutting", "skill_level": 1, "skill_xp": 0}]}

func _route(method: String, p: String, query: String, body: Dictionary, token: Variant) -> Dictionary:
	if p == "/api/health" or p == "/health":
		return {"status": 200, "body": {"status": "ok", "uptime": 1, "db": "offline"}}
	if p == "/login" and method == "POST":
		var username := String(body.get("username", "")).strip_edges()
		if username.is_empty() or String(body.get("password", "")).is_empty():
			return {"status": 400, "body": {"error": "Username and password are required."}}
		if not db["accounts"].has(username):
			return {"status": 401, "body": {"error": "Invalid username or password."}}
		return {"status": 200, "body": {"token": "offline:" + username}}
	if p == "/register" and method == "POST":
		var username := String(body.get("username", "")).strip_edges()
		var pw := String(body.get("password", ""))
		if username.length() < 3 or pw.length() < 4:
			return {"status": 400, "body": {"error": "Use a username of at least 3 characters and a password of at least 4."}}
		if db["accounts"].has(username):
			return {"status": 409, "body": {"error": "Username or email is already registered."}}
		db["accounts"][username] = _new_account(username)
		return {"status": 201, "body": {"token": "offline:" + username}}
	if p == "/leaderboard" and method == "GET":
		return _leaderboard()
	if p == "/api/recipes" and method == "GET":
		var want := ""
		for kv in query.split("&", false):
			if kv.begins_with("profession="):
				want = kv.substr(11).uri_decode()
		var recipes: Array = []
		for r in _recipes():
			if want.is_empty() or r["profession_id"] == want:
				recipes.append(r)
		return _ok(recipes)

	var acc_v: Variant = _account_for(token)
	if acc_v == null:
		return {"status": 401, "body": {"success": false, "error": "invalid or expired token"}}
	var acc: Dictionary = acc_v

	if p == "/api/session" and method == "GET":
		return {"status": 200, "body": {"success": true, "active": true}}
	if p == "/api/session/claim" and method == "POST":
		return {"status": 200, "body": {"token": token}}

	if p == "/character" and method == "GET":
		if acc["character"] == null:
			return _err("No character", 404)
		return {"status": 200, "body": _character_view(acc)}
	if p == "/character/discipline" and method == "POST":
		var index: Variant = body.get("class_index")
		if not _is_integer_val(index) or index < 1 or index > MAX_DISCIPLINE_INDEX:
			return _err("Choose one of the %d classes." % MAX_DISCIPLINE_INDEX, 400)
		if not _own(acc, body.get("characterId")):
			return _err("Character not found", 404)
		acc["character"]["class_index"] = int(index)
		acc["character"]["class_name"] = DISCIPLINE_NAMES.get(int(index), CLASS_NAMES[int(index)] if int(index) < CLASS_NAMES.size() else acc["character"]["class_name"])
		return {"status": 200, "body": _character_view(acc)}
	if p == "/character" and method == "POST":
		if acc["character"] != null:
			return {"status": 200, "body": _character_view(acc)}
		var idxf := _num(body, "class_index")
		if not _is_int(idxf) or idxf < 0 or idxf >= CLASS_NAMES.size():
			return _err("class_index must be 0–5", 400)
		var idx := int(idxf)
		acc["character"] = {"id": int(db["next_character_id"]), "class_index": idx, "class_name": CLASS_NAMES[idx], "level": 1, "experience": 0, "gold": 0,
			"stat_str": 7 if idx == 1 else 5, "stat_agi": 7 if idx == 2 else 5, "stat_int": 7 if idx == 3 or idx == 4 else 5, "stat_vit": 7 if idx == 1 else 5}
		db["next_character_id"] = int(db["next_character_id"]) + 1
		# Starter kit so the reliquary isn't empty offline.
		acc["slots"] = [{"slot_index": 0, "item_id": "staff_oak", "quantity": 1, "equipped": 0}, {"slot_index": 1, "item_id": "flask_hp_minor", "quantity": 3, "equipped": 0}]
		return {"status": 200, "body": _character_view(acc)}

	if method == "GET":
		return _route_get(acc, p)
	if method == "POST":
		return _route_post(acc, p, body)
	return _err("Offline backend: no route for %s %s" % [method, p], 404)

var _get_re: RegEx = RegEx.create_from_string("^/api/(inventory|professions|chronicle|necro-progress|loadouts|vault|labor|garden|cosmetics|contracts)/(\\d+)$")

func _route_get(acc: Dictionary, p: String) -> Dictionary:
	var m := _get_re.search(p)
	if m != null:
		if not _own(acc, m.get_string(2)):
			return _err("Character not found", 404)
		match m.get_string(1):
			"inventory": return _ok(_rows(acc))
			"professions": return _ok(acc["professions"])
			"chronicle":
				var c := _chron(acc)
				var runs: Array = c["runs"].duplicate()
				runs.reverse()
				return _ok({"life": c["life"], "run": c["run"], "runNo": c["runNo"], "runStartedAt": c["runStartedAt"], "runs": runs})
			"necro-progress":
				acc["necro"] = DmNecroRules.normalise(acc.get("necro", DmNecroRules.blank_state()))
				return _ok({"progress": acc["necro"], "gold": acc["character"]["gold"]})
			"loadouts": return _ok(_loadout_list(acc))
			"vault": return _ok(_vault_view(acc))
			"labor": return _ok(_labor_view(acc, _now()))
			"garden": return _ok(_garden_view(acc, _now()))
			"cosmetics": return _ok(_cos_view(acc))
			"contracts": return _ok(_contract_view(acc)["view"])
	match p:
		"/api/prefs": return _ok(acc["prefs"])
		"/api/bug-reports/mine":
			var mine: Array = []
			var list: Array = acc["bug_reports"].duplicate(true)
			list.reverse()
			for r in list.slice(0, 10):
				r["status"] = "Saved on this device"
				r["note"] = null
				mine.append(r)
			return _ok(mine)
		"/api/offline/snapshot":
			if acc["character"] == null:
				return _err("Create an online character before syncing.", 404)
			var snap := _capture(acc)
			return {"status": 200, "body": {"snapshot": snap, "fingerprint": _fingerprint(snap), "summary": _summary(snap)}}
		"/api/offline/versions":
			if acc["character"] == null:
				return _err("Online character not found.", 404)
			var vs: Array = []
			var all: Array = acc["versions"].duplicate()
			all.reverse()
			for v in all.slice(0, 20):
				vs.append({"id": v["id"], "source": v["source"], "createdAt": v["createdAt"], "summary": _summary(v["snapshot"])})
			return {"status": 200, "body": {"versions": vs}}
	return _err("Offline backend: no route for GET %s" % p, 404)

func _route_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	if p.begins_with("/api/offline/"):
		return _offline_post(acc, p, body)
	if p == "/api/professions/award-xp":
		return _err("Skill XP is earned by gathering and crafting now.", 410)
	if p == "/api/prefs":
		var prefs: Variant = body.get("prefs")
		if not (prefs is Dictionary):
			return _fail("prefs must be an object")
		for k in prefs:
			var t := typeof(prefs[k])
			if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_STRING:
				acc["prefs"][k] = prefs[k]
		return _ok(acc["prefs"])
	if p == "/api/bug-reports":
		var message := String(body.get("message", "")).strip_edges()
		if message.length() < 10:
			return _fail("Please describe the problem in at least 10 characters.")
		var list: Array = acc["bug_reports"]
		list.append({"id": list.size() + 1, "category": String(body.get("category", "bug")), "message": message.left(2000), "createdAt": _iso(_now())})
		return _ok({"id": list.size()})
	# Server authority step 2: the mock keeps no ledger (there is no authority to enforce offline); it just acknowledges.
	if p == "/api/kills/report":
		return _ok({"mode": "off"})
	# everything below needs the character id
	if not _own(acc, body.get("characterId")):
		return _err("Character not found", 404)
	if p.begins_with("/api/necro-progress/"):
		return _necro_post(acc, p.substr(20), body)
	if p.begins_with("/api/loadouts/"):
		return _loadouts_post(acc, p, body)
	if p.begins_with("/api/vault/"):
		return _vault_post(acc, p, body)
	if p.begins_with("/api/labor/"):
		return _labor_post(acc, p, body)
	if p.begins_with("/api/garden/"):
		return _garden_post(acc, p, body)
	if p.begins_with("/api/cosmetics/"):
		return _cosmetics_post(acc, p, body)
	if p.begins_with("/api/contracts/"):
		return _contracts_post(acc, p, body)
	if p.begins_with("/api/boss-key/"):
		return _boss_key_post(acc, p, body)
	if p.begins_with("/api/gather"):
		return _gather_post(acc, p, body)
	if p.begins_with("/api/reforge"):
		return _reforge_post(acc, p, body)
	if p.begins_with("/api/chronicle/"):
		return _chronicle_post(acc, p, body)
	match p:
		"/api/character/save-progress": return _save_progress(acc, body)
		"/api/inventory/save": return _inventory_save(acc, body)
		"/api/inventory/equip": return _equip(acc, body)
		"/api/inventory/belt": return _belt(acc, body)
		"/api/inventory/kit": return _kit(acc, body)
		"/api/inventory/rune": return _rune(acc, body)
		"/api/loot/roll-gear": return _roll_gear(acc, body)
		"/api/craft": return _craft(acc, body)
		"/api/salvage": return _salvage(acc, body)
	return _err("Offline backend: no route for POST %s" % p, 404)

# --- character progress ------------------------------------------------------------------------------------------------------------

func _save_progress(acc: Dictionary, body: Dictionary) -> Dictionary:
	var c: Dictionary = acc["character"]
	c["level"] = _tidy(_num_or(body.get("level"), float(c["level"])))
	c["experience"] = _tidy(_num_or(body.get("xp"), 0.0))
	c["gold"] = _tidy(maxf(0.0, _num_or(body.get("gold"), 0.0)))
	for k in ["stat_str", "stat_agi", "stat_int", "stat_vit"]:
		if body.has(k):
			c[k] = _tidy(_to_num(body[k]))
	return _ok({"saved": true})

# --- inventory ---------------------------------------------------------------------------------------------------------------------

func _inventory_save(acc: Dictionary, body: Dictionary) -> Dictionary:
	# Same rule as the server (inventory-save.cjs): a save only speaks for slots 0..bagSize-1, 24 when bagSize is absent.
	var bag_size_f: float = float(DEFAULT_BAG_SAVE) if body.get("bagSize") == null else _to_num(body["bagSize"])
	if not _is_int(bag_size_f) or bag_size_f < 1 or bag_size_f > BAG:
		return _fail("bagSize must be a whole number from 1 to %d" % BAG)
	var bag_size := int(bag_size_f)
	var next: Array = []
	var claimed: Dictionary = {}
	var instances := _instances(acc)
	var slots: Array = acc["slots"]
	var raw_slots: Variant = body.get("slots", [])
	if not (raw_slots is Array):
		raw_slots = []
	for s in raw_slots:
		if not (s is Dictionary):
			continue
		if _num(s, "slot_index") >= 100:
			continue
		var item_id := String(s.get("item_id", ""))
		if not _has_def(item_id):
			return _fail("Unknown item: %s" % item_id)
		var index_f := _num(s, "slot_index")
		if not _is_int(index_f) or index_f < 0 or index_f >= bag_size:
			return _fail("each slot_index must be between 0 and %d" % (bag_size - 1))
		var index := int(index_f)
		var qty_f := floorf(_num(s, "quantity"))
		if is_nan(qty_f) or qty_f <= 0:
			continue
		var qty := int(qty_f)
		# The live server refuses a stack over the item's cap (client stack caps that drift from the server's loop on this 400).
		if qty > _stack_cap(item_id):
			return _fail("%s exceeds its maximum stack size of %d" % [item_id, _stack_cap(item_id)])
		# A save may only NAME a roll the mock minted for this account (same rule as inventory-save.cjs); an omitted id keeps the slot's own.
		var instance_id: Variant = null
		if not s.has("instance_id"):
			for x in slots:
				if int(x["slot_index"]) == index and x["item_id"] == item_id:
					instance_id = x.get("instance_id")
					break
		elif s["instance_id"] != null:
			var idf := _to_num(s["instance_id"])
			var ok_id := _is_int(idf) and qty == 1 and not claimed.has(int(idf))
			if ok_id:
				var roll: Variant = instances.get(str(int(idf)))
				ok_id = roll != null and roll["item_id"] == item_id and not _held(acc, int(idf), bag_size)
			if not ok_id:
				return _fail(CANT_VERIFY)
			instance_id = int(idf)
		if instance_id != null:
			claimed[int(instance_id)] = true
		var row := {"slot_index": index, "item_id": item_id, "quantity": qty, "equipped": 1 if _truthy(s.get("equipped")) else 0}
		if instance_id != null:
			row["instance_id"] = int(instance_id)
		next.append(row)
	# A relic the save no longer names is gone (sold, thrown away).
	for x in slots:
		var xi: Variant = x.get("instance_id")
		if xi != null and _truthy(xi) and int(x["slot_index"]) >= 0 and int(x["slot_index"]) < bag_size and not claimed.has(int(xi)):
			instances.erase(str(int(xi)))
	var kept: Array = slots.filter(func(x): return int(x["slot_index"]) >= 100 or int(x["slot_index"]) >= bag_size)
	acc["slots"] = kept + next
	return _ok(_rows(acc))

func _held(acc: Dictionary, id: int, bag_size: int) -> bool:
	for x in acc["slots"]:
		var xi: Variant = x.get("instance_id")
		if xi != null and int(xi) == id and not (int(x["slot_index"]) >= 0 and int(x["slot_index"]) < bag_size):
			return true
	for v in acc.get("vault", []):
		var vi: Variant = v.get("instance_id")
		if vi != null and int(vi) == id:
			return true
	return false

## Item level and affixes: the only place loot is rolled (the same rules as server loot.cjs).
func _roll_gear(acc: Dictionary, body: Dictionary) -> Dictionary:
	var drops: Variant = body.get("drops")
	if not (drops is Array) or drops.is_empty() or drops.size() > 12:
		return _fail("Roll between 1 and 12 drops at a time.")
	var out: Array = []
	for d in drops:
		var item_id := ""
		var has_def := false
		if d is Dictionary and d.get("item_id") is String:
			item_id = d["item_id"]
			has_def = _has_def(item_id)
		var source: Variant = d.get("source") if d is Dictionary else null
		if not has_def or not (source is String) or not DROP_SOURCES.has(source):
			return _fail("That drop could not be rolled." if has_def else "Unknown item.")
		var def := _def(item_id)
		if not DmAffixRules.is_affix_gear(String(def.get("item_type", "material"))):
			out.append({"item_id": item_id, "instance_id": null, "ilvl": 0, "affixes": []})
			continue
		var level := DmAffixRules.clamp_drop_level(d.get("level"), _num_or(acc["character"]["level"], 1.0))
		var inst: Dictionary = DmAffixRules.roll_instance(String(def.get("rarity", "common")), level, source, _rand_callable())
		var id := _mint_instance(acc, item_id, int(inst["ilvl"]), inst["affixes"])
		out.append({"item_id": item_id, "instance_id": id, "ilvl": inst["ilvl"], "affixes": inst["affixes"]})
	return _ok(out)

## Same rules as the server: one item per gear slot, two-handers displace the off-hand and vice versa.
func _equip(acc: Dictionary, body: Dictionary) -> Dictionary:
	var slots: Array = acc["slots"]
	var slot: Variant = null
	var want := _num(body, "slot_index")
	for s in slots:
		if float(s["slot_index"]) == want:
			slot = s
			break
	if slot == null:
		return _fail("Slot is empty")
	var gear := _equip_slot(String(slot["item_id"]))
	if gear.is_empty():
		return _fail("That item cannot be equipped")
	var reserved: int = RESERVED[gear]
	if _truthy(body.get("equipped")):
		var two := _is_two_handed(String(slot["item_id"]))
		var displaced: Array = []
		for s in slots:
			if is_same(s, slot):
				continue
			var si := int(s["slot_index"])
			if si == reserved or (two and si == 106) or (gear == "off_hand" and si == 105 and _is_two_handed(String(s["item_id"]))):
				displaced.append(s)
		var free_bag: Array = []
		for i in BAG:
			var used := false
			for s in slots:
				if not is_same(s, slot) and not _contains_ref(displaced, s) and int(s["slot_index"]) == i:
					used = true
					break
			if not used:
				free_bag.append(i)
		# The equipped item's own bag slot is vacated, so it can hold the first displaced piece.
		if displaced.size() > free_bag.size() + 1:
			return _fail("Not enough inventory space to swap equipment")
		var bag_index := int(slot["slot_index"])
		slot["slot_index"] = reserved
		slot["equipped"] = 1
		for i in displaced.size():
			displaced[i]["slot_index"] = bag_index if i == 0 else free_bag[i - 1]
			displaced[i]["equipped"] = 0
	else:
		var free := _free_bag_slot(acc, slot)
		if free < 0:
			return _fail("Inventory full")
		slot["slot_index"] = free
		slot["equipped"] = 0
	return _ok(_rows(acc))

static func _contains_ref(arr: Array, x: Variant) -> bool:
	for a in arr:
		if is_same(a, x):
			return true
	return false

## The gathering tool belt: the same moves as server tool-belt.cjs.
func _belt(acc: Dictionary, body: Dictionary) -> Dictionary:
	var index_f := _num(body, "slot_index")
	var slot: Variant = null
	for s in acc["slots"]:
		if float(s["slot_index"]) == index_f:
			slot = s
			break
	if _truthy(body.get("equipped")):
		if slot == null or not (index_f >= 0 and index_f < BAG):
			return _fail("There is nothing in that slot.")
		var target := DmGathering.belt_slot_of(String(slot["item_id"]))
		if target < 0:
			return _fail("Only gathering tools fit on the belt.")
		var other: Variant = _slot_at(acc, target)
		var index := int(index_f)
		slot["slot_index"] = target
		slot["equipped"] = 1
		if other != null:
			other["slot_index"] = index
			other["equipped"] = 0
	else:
		if not _is_int(index_f) or not DmGathering.is_belt_slot(int(index_f)):
			return _fail("That is not a belt slot.")
		if slot == null:
			return _fail("The belt slot is empty.")
		var bag_index := _free_bag_slot(acc)
		if bag_index < 0:
			return _fail("Your bag is full. Make room, then take the tool off the belt.")
		slot["slot_index"] = bag_index
		slot["equipped"] = 0
	return _ok(_rows(acc))

## The Legion kit (thrall gear): the same moves as server thrall-kit.cjs.
func _kit(acc: Dictionary, body: Dictionary) -> Dictionary:
	var index_f := _num(body, "slot_index")
	var slot: Variant = null
	for s in acc["slots"]:
		if float(s["slot_index"]) == index_f:
			slot = s
			break
	if _truthy(body.get("equipped")):
		if not (index_f >= 0 and index_f < BAG):
			return _fail("Pick a piece from your bag.")
		if slot == null:
			return _fail("There is nothing in that slot.")
		var kit_id: Variant = DmLegion.kit_id_for_type(_type_of(String(slot["item_id"])) if _has_def(String(slot["item_id"])) else null)
		if kit_id == null:
			return _fail("The legion wears weapons and armour only.")
		var target: int = DmGear.KIT_BASE + DmLegion.KIT_IDS.find(kit_id)
		var other: Variant = _slot_at(acc, target)
		var index := int(index_f)
		slot["slot_index"] = target
		slot["equipped"] = 1
		if other != null:
			other["slot_index"] = index
			other["equipped"] = 0
	else:
		if not DmGear.is_kit_slot(index_f):
			return _fail("That is not a legion slot.")
		if slot == null:
			return _fail("The legion slot is empty.")
		var bag_index := _free_bag_slot(acc)
		if bag_index < 0:
			return _fail("Your bag is full. Make room, then take the piece off the legion.")
		slot["slot_index"] = bag_index
		slot["equipped"] = 0
	return _ok(_rows(acc))

## Put one unit of an item back in the bag (onto a stack with room, else a free slot). False when there is no room.
func _give_back_rune(acc: Dictionary, id: String) -> bool:
	var cap := _stack_of(id, 99)
	for s in acc["slots"]:
		if int(s["slot_index"]) < BAG and s["item_id"] == id and not _truthy(s.get("equipped")) and s.get("instance_id") == null and int(s["quantity"]) < cap:
			s["quantity"] = int(s["quantity"]) + 1
			return true
	var free := _free_bag_slot(acc)
	if free < 0:
		return false
	acc["slots"].append({"slot_index": free, "item_id": id, "quantity": 1, "equipped": 0})
	return true

## Relic rune sockets: the same moves as server runes.cjs.
func _rune(acc: Dictionary, body: Dictionary) -> Dictionary:
	var rite := String(body.get("rite", "")) if body.get("rite") != null else ""
	var item_id: Variant = null if body.get("itemId") == null else String(body["itemId"])
	if not DmRunes.is_rune_rite(rite):
		return _fail("That is not a rite that takes a rune.")
	if item_id != null and not DmRunes.rune_fits(item_id, rite):
		return _fail("That rune doesn't fit this rite." if DmRunes.is_rune_id(item_id) else "That is not a rune.")
	var socket_slot := DmRunes.rune_slot_index(rite)
	var current: Variant = _slot_at(acc, socket_slot)
	if item_id == null:
		if current == null:
			return _fail("That socket is empty.")
		acc["slots"] = acc["slots"].filter(func(s): return not is_same(s, current))
		if not _give_back_rune(acc, current["item_id"]):
			acc["slots"].append(current)
			return _fail("Your bag is full. Make room, then take the rune out.")
		return _ok(_rows(acc))
	if current != null and current["item_id"] == item_id:
		return _ok(_rows(acc))
	var from: Variant = null
	for s in acc["slots"]:
		if int(s["slot_index"]) < BAG and s["item_id"] == item_id and not _truthy(s.get("equipped")) and s.get("instance_id") == null and int(s["quantity"]) > 0:
			from = s
			break
	if from == null:
		return _fail("You don't have that rune.")
	var before := _clone_slots(acc)
	if int(from["quantity"]) > 1:
		from["quantity"] = int(from["quantity"]) - 1
	else:
		acc["slots"] = acc["slots"].filter(func(s): return not is_same(s, from))
	if current != null:
		acc["slots"] = acc["slots"].filter(func(s): return not is_same(s, current))
		if not _give_back_rune(acc, current["item_id"]):
			acc["slots"] = before
			return _fail("Your bag is full. Make room, then take the rune out.")
	acc["slots"].append({"slot_index": socket_slot, "item_id": item_id, "quantity": 1, "equipped": 1})
	return _ok(_rows(acc))

# --- loadouts ----------------------------------------------------------------------------------------------------------------------

func _loadout_list(acc: Dictionary) -> Array:
	var out: Array = []
	for k in acc["loadouts"]:
		out.append({"slot": int(k), "preset": acc["loadouts"][k]})
	out.sort_custom(func(a, b): return a["slot"] < b["slot"])
	return out

func _loadouts_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	if not (p in ["/api/loadouts/save", "/api/loadouts/delete", "/api/loadouts/apply"]):
		return _err("Offline backend: no route for POST %s" % p, 404)
	var slot: Variant = body.get("slot")
	if not _is_integer_val(slot) or slot < 0 or slot >= MAX_PRESETS:
		return _err("slot must be 0 to %d" % (MAX_PRESETS - 1), 400)
	var key := str(int(slot))
	var store: Dictionary = acc["loadouts"]
	if p == "/api/loadouts/save":
		var v := DmOfflineLoadout.normalize_preset(body.get("preset"))
		if not v["ok"]:
			return _fail(v["error"])
		store[key] = v["preset"]
		return _ok(_loadout_list(acc))
	if p == "/api/loadouts/delete":
		store.erase(key)
		return _ok(_loadout_list(acc))
	var preset: Variant = store.get(key)
	if preset == null:
		return _fail("That loadout is empty.")
	var rows: Array = []
	for x in acc["slots"]:
		rows.append(x.duplicate())
	var info := func(id: String) -> Dictionary:
		var es: Variant = null
		if _has_def(id):
			var e := _equip_slot(id)
			es = null if e.is_empty() else e
		return {"maxStack": _stack_cap(id), "equipSlot": es, "twoHanded": _is_two_handed(id)}
	var res := DmOfflineLoadout.apply_loadout(rows, info, preset)
	var after: Array = []
	for x in res["rows"]:
		var out := {"slot_index": int(x["slot_index"]), "item_id": x["item_id"], "quantity": int(x["quantity"]), "equipped": 1 if _truthy(x.get("equipped")) else 0}
		if x.get("instance_id") != null:
			out["instance_id"] = int(x["instance_id"])
		after.append(out)
	acc["slots"] = after
	return {"status": 200, "body": {"success": true, "data": _rows(acc), "report": res["report"], "preset": preset}}

# --- crafting ----------------------------------------------------------------------------------------------------------------------

func _find_prof(acc: Dictionary, id: String) -> Variant:
	for pr in acc["professions"]:
		if pr["profession_id"] == id:
			return pr
	return null

func _craft(acc: Dictionary, body: Dictionary) -> Dictionary:
	var recipe: Dictionary = {}
	for r in _recipes():
		if r["id"] == body.get("recipeId"):
			recipe = r
			break
	if recipe.is_empty():
		return _fail("Unknown recipe")
	var prof: Variant = _find_prof(acc, recipe["profession_id"])
	var lvl := 1 if prof == null else int(prof["skill_level"])
	if lvl < int(recipe["skill_level_required"]):
		return _fail("requires %s level %d (you have %d)" % [recipe["profession_id"], int(recipe["skill_level_required"]), lvl])
	var slots: Array = acc["slots"]
	for ing in recipe["ingredients"]:
		var have := 0
		for s in slots:
			if s["item_id"] == ing["item_id"]:
				have += int(s["quantity"])
		if have < int(ing["quantity"]):
			return _fail("not enough %s (%d/%d)" % [ing["name"], have, int(ing["quantity"])])
	var before := _clone_slots(acc)
	for ing in recipe["ingredients"]:
		var left := int(ing["quantity"])
		for s in slots:
			if s["item_id"] != ing["item_id"] or left <= 0:
				continue
			var take := mini(left, int(s["quantity"]))
			s["quantity"] = int(s["quantity"]) - take
			left -= take
	acc["slots"] = slots.filter(func(s): return int(s["quantity"]) > 0)
	slots = acc["slots"]
	# Like the live server: top up stacks below the item's cap, then open new slots for the rest ('Inventory is full' when none is free).
	var result_id: String = recipe["result_item_id"]
	var cap := _stack_cap(result_id)
	var remaining := int(recipe["result_quantity"])
	if cap > 1:
		var stacks: Array = slots.filter(func(x): return x["item_id"] == result_id and not _truthy(x.get("equipped")) and int(x["slot_index"]) < BAG and int(x["quantity"]) < cap)
		stacks = DmStableSort.sorted(stacks, func(a, b): return int(a["slot_index"]) < int(b["slot_index"]))
		for s in stacks:
			var add := mini(remaining, cap - int(s["quantity"]))
			s["quantity"] = int(s["quantity"]) + add
			remaining -= add
	while remaining > 0:
		var used: Dictionary = {}
		for s in slots:
			used[int(s["slot_index"])] = true
		var free := 0
		while used.has(free):
			free += 1
		if free >= BAG:
			acc["slots"] = before
			return _fail("Inventory is full")
		var add2 := mini(remaining, cap)
		slots.append({"slot_index": free, "item_id": result_id, "quantity": add2, "equipped": 0})
		remaining -= add2
	# Like the live server: a missing profession row is created on the first craft, and XP is 5 per required level.
	var earner: Dictionary
	if prof == null:
		earner = {"profession_id": recipe["profession_id"], "skill_level": 1, "skill_xp": 0}
		acc["professions"].append(earner)
	else:
		earner = prof
	earner["skill_xp"] = int(earner["skill_xp"]) + maxi(1, int(recipe["skill_level_required"])) * 5
	while int(earner["skill_xp"]) >= int(earner["skill_level"]) * 50:
		earner["skill_xp"] = int(earner["skill_xp"]) - int(earner["skill_level"]) * 50
		earner["skill_level"] = int(earner["skill_level"]) + 1
	return _ok({"updatedInventory": _rows(acc), "updatedProfession": earner})

# --- the Ossuary Vault and Salvaging -----------------------------------------------------------------------------------------------

func _inst_row(acc: Dictionary, iid: Variant) -> Dictionary:
	if iid == null or not _truthy(iid):
		return {}
	var roll: Variant = acc.get("instances", {}).get(str(int(iid)))
	if roll == null:
		return {}
	return {"inst": int(iid), "power": DmAffixRules.instance_power(roll), "ilvl": roll["ilvl"], "nAffix": roll["affixes"].size()}

func _bag_rows(acc: Dictionary) -> Array:
	var out: Array = []
	for x in acc["slots"]:
		if int(x["slot_index"]) >= BAG:
			continue
		var r := {"slot": int(x["slot_index"]), "itemId": x["item_id"], "qty": int(x["quantity"])}
		if _truthy(x.get("equipped")):
			r["fixed"] = true
		r.merge(_inst_row(acc, x.get("instance_id")))
		out.append(r)
	return out

func _vault_rows(acc: Dictionary) -> Array:
	var out: Array = []
	for x in acc.get("vault", []):
		var r := {"slot": int(x["slot_index"]), "itemId": x["item_id"], "qty": int(x["quantity"])}
		r.merge(_inst_row(acc, x.get("instance_id")))
		out.append(r)
	return out

func _store_bag(acc: Dictionary, rows: Array) -> void:
	var kept_eq: Dictionary = {}
	for x in acc["slots"]:
		if int(x["slot_index"]) < BAG and _truthy(x.get("equipped")):
			kept_eq[int(x["slot_index"])] = x
	var next: Array = acc["slots"].filter(func(x): return int(x["slot_index"]) >= BAG)
	for r in rows:
		if kept_eq.has(int(r["slot"])):
			next.append(kept_eq[int(r["slot"])])
		else:
			var row := {"slot_index": int(r["slot"]), "item_id": r["itemId"], "quantity": int(r["qty"]), "equipped": 0}
			if r.get("inst") != null:
				row["instance_id"] = int(r["inst"])
			next.append(row)
	acc["slots"] = next

func _vault_view(acc: Dictionary) -> Dictionary:
	var v: Array = acc.get("vault", []).duplicate()
	v = DmStableSort.sorted(v, func(a, b): return int(a["slot_index"]) < int(b["slot_index"]))
	var vout: Array = []
	for i in v.size():
		var x: Dictionary = v[i].duplicate()
		x["equipped"] = 0
		vout.append(_join(acc, x, i))
	return {"bag": _rows(acc), "vault": vout}

func _vault_store(acc: Dictionary, rows: Array) -> void:
	var out: Array = []
	for x in rows:
		var row := {"slot_index": int(x["slot"]), "item_id": x["itemId"], "quantity": int(x["qty"])}
		if x.get("inst") != null:
			row["instance_id"] = int(x["inst"])
		out.append(row)
	acc["vault"] = out

func _apply_vault(acc: Dictionary, r: Dictionary) -> Dictionary:
	if not r["ok"]:
		return _fail(r["error"])
	_store_bag(acc, r["bag"])
	_vault_store(acc, r["vault"])
	return _ok(_vault_view(acc))

func _vault_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var info := Callable(self, "_vault_info")
	var qty: Variant = null if body.get("quantity") == null else _to_num(body["quantity"])
	match p:
		"/api/vault/deposit":
			var slot_f := _num(body, "bagSlot")
			if not _is_int(slot_f) or slot_f < 0 or slot_f >= BAG:
				return _fail("Choose a bag slot between 0 and %d." % (BAG - 1))
			return _apply_vault(acc, DmVault.deposit_stack(_bag_rows(acc), _vault_rows(acc), int(slot_f), qty, info))
		"/api/vault/withdraw":
			var vs_f := _num(body, "vaultSlot")
			if not _is_int(vs_f) or vs_f < 0 or vs_f >= DmVault.VAULT_SLOTS:
				return _fail("Choose a Vault slot between 0 and %d." % (DmVault.VAULT_SLOTS - 1))
			return _apply_vault(acc, DmVault.withdraw_stack(_bag_rows(acc), _vault_rows(acc), int(vs_f), qty, info))
		"/api/vault/deposit-all":
			var kind: Variant = body.get("kind")
			if kind != "materials" and kind != "all":
				return _fail("Choose what to deposit: materials or everything.")
			var except: Array = []
			if body.get("exceptSlots") is Array:
				for n in body["exceptSlots"]:
					var nf := _to_num(n)
					if _is_int(nf):
						except.append(int(nf))
			return _apply_vault(acc, DmVault.deposit_many(_bag_rows(acc), _vault_rows(acc), kind, except, info))
		"/api/vault/sort":
			_vault_store(acc, DmVault.sort_vault(_vault_rows(acc), info))
			return _ok(_vault_view(acc))
	return _err("Offline backend: no route for POST %s" % p, 404)

func _salvage(acc: Dictionary, body: Dictionary) -> Dictionary:
	var slots: Array = []
	if body.get("slots") is Array:
		for n in body["slots"]:
			slots.append(_to_num(n))
	if slots.is_empty():
		return _fail("Choose some gear to salvage.")
	var uniq: Dictionary = {}
	var bad := slots.size() > BAG
	for n in slots:
		uniq[n] = true
		if not _is_int(n) or n < 0 or n >= BAG:
			bad = true
	if bad or uniq.size() != slots.size():
		return _fail("Choose gear in your bag (slots 0 to %d), each once." % (BAG - 1))
	var bag := _bag_rows(acc)
	var prof: Variant = _find_prof(acc, DmSalvage.SALVAGE_SKILL)
	var level := 1 if prof == null else int(prof["skill_level"])
	var salvaged: Array = []
	var partial: Dictionary = {}
	var yields: Array = []
	var spent: Array = []
	var xp := 0
	for sf in slots:
		var slot := int(sf)
		var row: Variant = null
		for r in bag:
			if int(r["slot"]) == slot:
				row = r
				break
		if row == null:
			return _fail("One of those slots is empty. Nothing was salvaged.")
		if row.get("fixed", false):
			return _fail("Equipped gear cannot be salvaged. Unequip it first.")
		var info := _vault_info(row["itemId"])
		if not DmSalvage.is_salvageable(info["itemType"]):
			return _fail("Only weapons, armor, rings, trinkets and runes can be salvaged.")
		if row.get("inst") != null:
			spent.append(row["inst"])
		# A rune stack is ground one rune at a time (the rest stay in the bag).
		var is_rune := DmSalvage.is_salvage_rune(info["itemType"])
		if is_rune and int(row["qty"]) > 1:
			var rest: Dictionary = row.duplicate()
			rest["qty"] = int(row["qty"]) - 1
			partial[slot] = rest
		var times := 1 if is_rune else int(row["qty"])
		for n in times:
			var item := {"id": row["itemId"], "item_type": info["itemType"], "rarity": info["rarity"]}
			if row.get("inst") != null:
				item["ilvl"] = row["ilvl"]
				item["affixes"] = row["nAffix"]
			var out: Dictionary = DmSalvage.yield_for(item, level, _rand_callable())
			salvaged.append({"item_id": row["itemId"]})
			yields.append(out["items"])
			xp += int(out["xp"])
	var gained: Array = DmSalvage.merge_grants(yields)
	var taken: Dictionary = {}
	for sf in slots:
		taken[int(sf)] = true
	var rest_rows: Array = []
	for r in bag:
		var rs := int(r["slot"])
		if taken.has(rs) and not partial.has(rs):
			continue
		rest_rows.append(partial[rs] if partial.has(rs) else r)
	var grants: Array = []
	for g in gained:
		grants.append({"itemId": g["item_id"], "qty": g["quantity"]})
	var after: Variant = DmVault.add_grants(rest_rows, grants, Callable(self, "_vault_info"))
	if after == null:
		return _fail("Make room in your bag first: the salvage will not fit. Nothing was salvaged.")
	_store_bag(acc, after)
	for id in spent:
		acc.get("instances", {}).erase(str(int(id)))
	if prof == null:
		prof = {"profession_id": DmSalvage.SALVAGE_SKILL, "skill_level": 1, "skill_xp": 0}
		acc["professions"].append(prof)
	var nxt: Dictionary = DmGathering.add_skill_xp({"level": prof["skill_level"], "xp": prof["skill_xp"]}, xp)
	prof["skill_level"] = nxt["level"]
	prof["skill_xp"] = nxt["xp"]
	return _ok({"bag": _rows(acc), "salvaged": salvaged, "gained": gained, "xp": xp, "level": nxt["level"], "leveledUp": int(nxt["leveled"]) > 0, "skillXp": nxt["xp"], "xpToNext": DmGathering.xp_to_next(int(nxt["level"]))})

# --- gold sinks: reforge, boss key -------------------------------------------------------------------------------------------------

func _gold_now(acc: Dictionary) -> int:
	return maxi(0, DmMath.js_round(_num_or(acc["character"].get("gold"), 0.0)))

func _set_gold(acc: Dictionary, g: int) -> void:
	acc["character"]["gold"] = g

func _fmt_n(n: int) -> String:
	return DmJsFmt.locale(float(n))

func _reforge_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	if p == "/api/reforge/quote":
		var pieces: Array = []
		for x in acc["slots"]:
			if x.get("instance_id") != null:
				pieces.append({"slot_index": x["slot_index"], "instance_id": x["instance_id"], "rerolls": int(acc.get("reforges", {}).get(str(int(x["instance_id"])), 0))})
		return _ok({"gold": _gold_now(acc), "pieces": pieces})
	if p != "/api/reforge":
		return _err("Offline backend: no route for POST %s" % p, 404)
	var slot_f := _num(body, "slot_index")
	var slot: Variant = null
	for x in acc["slots"]:
		if float(x["slot_index"]) == slot_f:
			slot = x
			break
	var index_f := _num(body, "affix_index")
	if not _is_int(slot_f) or not _is_int(index_f):
		return _fail("Choose a piece and one of its affixes.")
	if slot == null:
		return _fail("There is nothing in that slot.")
	var iid: Variant = slot.get("instance_id")
	var roll: Variant = acc.get("instances", {}).get(str(int(iid))) if iid != null else null
	if roll == null:
		return _fail("Only rolled gear (a piece with affixes) can be reforged.")
	if roll["affixes"].is_empty():
		return _fail("This piece has no affixes to reforge.")
	var index := int(index_f)
	var problem := DmGoldSink.reforge_problem(roll, index, Callable(DmAffixRules, "affix_range"))
	if problem != "":
		return _fail(problem)
	var rerolls := int(acc.get("reforges", {}).get(str(int(iid)), 0))
	var cost := DmGoldSink.reforge_cost(float(roll["ilvl"]), String(_def(slot["item_id"]).get("rarity", "common")), roll["affixes"].size(), rerolls)
	if body.has("expect_cost") and _to_num(body["expect_cost"]) != float(cost):
		return _fail("The price is now %s gold. Check it and try again." % _fmt_n(cost))
	if _gold_now(acc) < cost:
		return _fail("Reforging this piece costs %s gold (you have %s)." % [_fmt_n(cost), _fmt_n(_gold_now(acc))])
	var from_v: Variant = roll["affixes"][index]["v"]
	var to_v := DmGoldSink.reforge_value(roll["affixes"][index]["id"], int(roll["ilvl"]), _rand_callable(), Callable(DmAffixRules, "affix_range"))
	roll["affixes"][index] = {"id": roll["affixes"][index]["id"], "v": to_v}
	if not acc.has("reforges"):
		acc["reforges"] = {}
	acc["reforges"][str(int(iid))] = rerolls + 1
	_set_gold(acc, _gold_now(acc) - cost)
	return _ok({"gold": _gold_now(acc), "cost": cost, "from": from_v, "to": to_v, "rerolls": rerolls + 1, "bag": _rows(acc)})

func _open_summons(acc: Dictionary, boss: Variant = null) -> Array:
	var out: Array = []
	var window := int(DmGoldSink.EMPOWER["claimWindowMs"])
	for x in acc.get("empowered", []):
		if (boss == null or x["boss"] == boss) and x["status"] == "open" and _now() - int(x["made"]) < window:
			out.append(x)
	return out

func _boss_key_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	if p == "/api/boss-key/status":
		var live := _open_summons(acc)
		var bound: Array = []
		var summons: Array = []
		for x in live:
			if not bound.has(x["boss"]):
				bound.append(x["boss"])
			summons.append({"id": x["id"], "boss": x["boss"]})
		return _ok({"bound": bound, "summons": summons})
	var action := p.get_slice("/", 3)
	if not (p.count("/") == 3 and action in ["summon", "refund", "claim"]):
		return _err("Offline backend: no route for POST %s" % p, 404)
	var boss_v: Variant = body.get("boss")
	if not (boss_v is String) or not DmGoldSink.can_empower(boss_v):
		return _fail("That boss cannot be called with a Seal.")
	var boss: String = boss_v
	if not acc.has("empowered"):
		acc["empowered"] = []
	var list: Array = acc["empowered"]
	var open := _open_summons(acc, boss)
	if action == "summon":
		if not open.is_empty():
			return _ok({"gold": _gold_now(acc), "cost": 0, "reused": true, "summon_id": open[0]["id"], "bag": _rows(acc)})
		var cost := DmOfflineEmpower.empower_gold(boss)
		var bag := _bag_rows(acc)
		var seal: Variant = null
		for r in bag:
			if r["itemId"] == DmGoldSink.COVENANT_SEAL and not r.get("fixed", false) and int(r["qty"]) > 0:
				seal = r
				break
		if seal == null:
			return _fail("You need a Covenant Seal in your bag to call an Empowered boss.")
		if _gold_now(acc) < cost:
			return _fail("The Seal demands %s gold (you have %s)." % [_fmt_n(cost), _fmt_n(_gold_now(acc))])
		var rest: Array = []
		for r in bag:
			if is_same(r, seal):
				var c: Dictionary = r.duplicate()
				c["qty"] = int(c["qty"]) - 1
				if int(c["qty"]) > 0:
					rest.append(c)
			elif int(r["qty"]) > 0:
				rest.append(r)
		_store_bag(acc, rest)
		_set_gold(acc, _gold_now(acc) - cost)
		var made := {"id": list.size() + 1, "boss": boss, "gold": cost, "status": "open", "made": _now()}
		list.append(made)
		return _ok({"gold": _gold_now(acc), "cost": cost, "reused": false, "summon_id": made["id"], "bag": _rows(acc)})
	if action == "refund":
		var row: Variant = open[open.size() - 1] if not open.is_empty() else null
		if row == null or _now() - int(row["made"]) > int(DmGoldSink.EMPOWER["refundWindowMs"]):
			return _fail("There is no recent summon to take back.")
		var after: Variant = DmVault.add_grants(_bag_rows(acc), [{"itemId": DmGoldSink.COVENANT_SEAL, "qty": 1}], Callable(self, "_vault_info"))
		if after == null:
			return _fail("Make room in your bag for the Seal, then try again.")
		_store_bag(acc, after)
		_set_gold(acc, _gold_now(acc) + int(row["gold"]))
		row["status"] = "refunded"
		return _ok({"gold": _gold_now(acc), "bag": _rows(acc)})
	var crow: Variant = open[0] if not open.is_empty() else null
	if crow == null:
		return _fail("No Empowered summon of that boss is waiting for a prize.")
	if _now() - int(crow["made"]) < 10000:
		return _fail("The boss has barely woken. Finish the fight first.")
	var owned: Dictionary = {}
	for x in acc["slots"]:
		owned[x["item_id"]] = true
	var prize := DmOfflineEmpower.roll_prize(boss, String(body["discipline"]) if body.get("discipline") is String else "", _rand_callable(), owned)
	var def := _def(prize["item_id"])
	if def.is_empty() or not DmAffixRules.is_affix_gear(String(def.get("item_type", "material"))):
		return _fail("The prize could not be rolled. Try again.")
	var level := DmAffixRules.clamp_drop_level(body.get("level"), _num_or(acc["character"]["level"], 1.0))
	var inst := DmOfflineEmpower.roll_instance(prize, String(def.get("rarity", "common")), level, _rand_callable())
	var id := _mint_instance(acc, prize["item_id"], int(inst["ilvl"]), inst["affixes"])
	crow["status"] = "claimed"
	return _ok({"item_id": prize["item_id"], "instance_id": id, "ilvl": inst["ilvl"], "affixes": inst["affixes"], "legendary": prize["legendary"]})

# --- gathering ---------------------------------------------------------------------------------------------------------------------

func _gather_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var node_id := String(body["nodeType"]) if body.get("nodeType") != null else ""
	var def := DmGathering.node_def(node_id)
	if p == "/api/gather/afk-start":
		if def.is_empty():
			return _err("Unknown gathering node", 400)
		var pr: Variant = _find_prof(acc, def["skill"])
		var level := 1 if pr == null else int(pr["skill_level"])
		if level < int(def["level"]):
			return _err(DmGathering.gather_blocker(node_id, level), 400)
		var ledger: Dictionary = acc.get("gatherLedger", DmGathering.blank_ledger()).duplicate()
		ledger["lastAt"] = _now()
		acc["gatherLedger"] = ledger
		return _ok({"node": def["id"]})
	if p != "/api/gather":
		return _err("Offline backend: no route for POST %s" % p, 404)
	if def.is_empty():
		return _err("Unknown gathering node", 400)
	var prof: Variant = _find_prof(acc, def["skill"])
	var new_prof := prof == null
	if new_prof:
		prof = {"profession_id": def["skill"], "skill_level": 1, "skill_xp": 0}
	# Offline profiles are user-made and can never be staff (the web build's isDevAccount is false for offline tokens).
	if int(prof["skill_level"]) < int(def["level"]):
		return _err(DmGathering.gather_blocker(node_id, int(prof["skill_level"])), 400)
	var claimed: float = _num(body, "actions")
	var budget := DmGathering.check_budget(def, acc.get("gatherLedger", DmGathering.blank_ledger()), 0 if is_nan(claimed) else claimed, _now(), body.get("afk") is bool and body["afk"])
	if not budget["ok"]:
		return _err(budget["error"], 400)
	if new_prof:
		acc["professions"].append(prof)
	var bag: Array = []
	var held: Array = []
	for x in acc["slots"]:
		var si := int(x["slot_index"])
		if si < BAG:
			bag.append({"slot": si, "itemId": "" if _truthy(x.get("equipped")) else x["item_id"], "qty": int(x["quantity"])})
			held.append("" if _truthy(x.get("equipped")) else x["item_id"])
	# The tool belt (slots 110-113) counts like the bag, as on the server.
	for x in acc["slots"]:
		if DmGathering.is_belt_slot(int(x["slot_index"])):
			held.append(x["item_id"])
	var tool_tier := DmGathering.tool_tier_for(def["skill"], held)
	var batch := DmGathering.roll_batch(def, {"level": prof["skill_level"], "xp": prof["skill_xp"]}, int(budget["accepted"]), _rand_callable(), tool_tier, 0)
	var placed := DmGathering.place_items(bag, batch["items"], func(id: String) -> int: return _stack_of(id, 9999) if _type_of(id) == "material" and _has_def(id) else 1)
	_apply_placed(acc, placed)
	prof["skill_level"] = batch["progress"]["level"]
	prof["skill_xp"] = batch["progress"]["xp"]
	if int(batch["gold"]) > 0:
		acc["character"]["gold"] = _tidy(_num_or(acc["character"].get("gold"), 0.0) + float(batch["gold"]))
	acc["gatherLedger"] = budget["ledger"]
	return _ok({"node": def["id"], "skill": def["skill"], "accepted": budget["accepted"], "successes": batch["successes"], "xp": batch["xp"], "gold": batch["gold"],
		"items": placed["stored"], "rejected": placed["rejected"], "leveledUp": int(batch["leveled"]) > 0, "toolTier": tool_tier, "skills": [prof.duplicate()]})

## Write a DmGathering.place_items result back into the stored slots.
func _apply_placed(acc: Dictionary, placed: Dictionary) -> void:
	for u in placed["updates"]:
		var s: Variant = _slot_at(acc, int(u["slot"]))
		if s != null:
			s["quantity"] = int(u["qty"])
	for r in placed["inserts"]:
		acc["slots"].append({"slot_index": int(r["slot"]), "item_id": r["itemId"], "quantity": int(r["qty"]), "equipped": 0})

func _placement_rows(acc: Dictionary) -> Array:
	var out: Array = []
	for s in acc["slots"]:
		out.append({"slot": int(s["slot_index"]), "itemId": "" if _truthy(s.get("equipped")) else s["item_id"], "qty": int(s["quantity"])})
	return out

# --- chronicle ---------------------------------------------------------------------------------------------------------------------

func _chron(acc: Dictionary) -> Dictionary:
	if not acc.has("chronicle"):
		acc["chronicle"] = {"life": {}, "run": {}, "runNo": 1, "runStartedAt": _iso(_now()), "runs": []}
	return acc["chronicle"]

func _chronicle_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var ch := _chron(acc)
	if p == "/api/chronicle/add":
		var deltas: Variant = body.get("deltas")
		if deltas is Dictionary:
			for k in deltas:
				var add := maxf(0.0, floorf(_num_or(deltas[k], 0.0)))
				for t in [ch["life"], ch["run"]]:
					t[k] = _tidy(_num_or(t.get(k, 0), 0.0) + add)
		var maxes: Variant = body.get("maxes")
		if maxes is Dictionary:
			for k in maxes:
				var m := floorf(_num_or(maxes[k], 0.0))
				for t in [ch["life"], ch["run"]]:
					t[k] = _tidy(maxf(_num_or(t.get(k, 0), 0.0), m))
		return _ok({})
	if p == "/api/chronicle/ascend":
		if ch["run"].is_empty():
			return _ok({"archived": false})
		ch["runs"].append({"runNo": ch["runNo"], "startedAt": ch["runStartedAt"], "endedAt": _iso(_now()), "ascensionAfter": _tidy(_num_or(body.get("ascension"), 0.0)), "stats": ch["run"]})
		ch["run"] = {}
		ch["runNo"] = int(ch["runNo"]) + 1
		ch["runStartedAt"] = _iso(_now())
		return _ok({"archived": true})
	return _err("Offline backend: no route for POST %s" % p, 404)

# --- Grave Laborers ----------------------------------------------------------------------------------------------------------------

func _levels(acc: Dictionary) -> Dictionary:
	var out := {}
	for pr in acc["professions"]:
		out[pr["profession_id"]] = int(pr["skill_level"])
	return out

func _posts(acc: Dictionary) -> Dictionary:
	if not acc.has("labor"):
		acc["labor"] = {}
	return acc["labor"]

func _labor_view(acc: Dictionary, now: int) -> Dictionary:
	var levels := _levels(acc)
	var total := DmLabor.total_gather_level(levels)
	var unlocked := DmLabor.labor_slots(total)
	var slots: Array = []
	for slot in DmLabor.MAX_SLOTS:
		var row: Variant = _posts(acc).get(str(slot))
		var def: Dictionary = {}
		if row != null and _truthy(row.get("nodeType")):
			def = DmGathering.node_def(String(row["nodeType"]))
		var has := not def.is_empty()
		var elapsed := 0
		var est := {"actions": 0, "items": 0, "xp": 0}
		if has:
			elapsed = maxi(0, mini(now - int(row["startedAt"]), DmLabor.CAP_MS))
			est = DmLabor.estimate(def, int(levels.get(def["skill"], 1)), elapsed)
		slots.append({"slot": slot, "unlocked": slot < unlocked, "nodeType": def["id"] if has else null, "nodeName": def["name"] if has else null,
			"skill": def["skill"] if has else null, "item": def["item"] if has else null, "startedAt": int(row["startedAt"]) if has else 0, "elapsedMs": elapsed,
			"capped": has and now - int(row["startedAt"]) >= DmLabor.CAP_MS, "pendingActions": est["actions"], "estItems": est["items"], "estXp": est["xp"]})
	return {"now": now, "capMs": DmLabor.CAP_MS, "totalLevel": total, "levelsPerSlot": DmLabor.LEVELS_PER_SLOT, "slots": slots}

func _labor_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var now := _now()
	var slot_f := _num(body, "slot")
	if p == "/api/labor/assign":
		var levels := _levels(acc)
		if not (_is_int(slot_f) and slot_f >= 0 and slot_f < DmLabor.labor_slots(DmLabor.total_gather_level(levels))):
			return _fail("You do not command that many laborers yet.")
		var key := str(int(slot_f))
		var row: Variant = _posts(acc).get(key)
		var cur: Dictionary = {}
		if row != null and _truthy(row.get("nodeType")):
			cur = DmGathering.node_def(String(row["nodeType"]))
		if not cur.is_empty() and DmLabor.labor_actions(cur, float(now - int(row["startedAt"]))) >= 1:
			return _fail("Collect what they have gathered first.")
		var node: Variant = body.get("nodeType")
		if _truthy(node):
			var blocked := DmLabor.assign_blocker(String(node), levels)
			if blocked != "":
				return _fail(blocked)
		_posts(acc)[key] = {"nodeType": node if _truthy(node) else null, "startedAt": now if _truthy(node) else 0}
		return _ok(_labor_view(acc, now))
	if p != "/api/labor/collect":
		return _err("Offline backend: no route for POST %s" % p, 404)
	var row2: Variant = _posts(acc).get(str(int(slot_f))) if _is_int(slot_f) else null
	var def: Dictionary = {}
	if row2 != null and _truthy(row2.get("nodeType")):
		def = DmGathering.node_def(String(row2["nodeType"]))
	if def.is_empty():
		return _fail("That laborer has no post.")
	var elapsed := mini(now - int(row2["startedAt"]), DmLabor.CAP_MS)
	var actions := DmLabor.labor_actions(def, float(elapsed))
	if actions < 1:
		return _fail("They have barely started.")
	var pr: Variant = _find_prof(acc, def["skill"])
	if pr == null:
		pr = {"profession_id": def["skill"], "skill_level": 1, "skill_xp": 0}
		acc["professions"].append(pr)
	var seed_rng: Object = DmLabor.claim_rng(DmLabor.hash_seed([acc["character"]["id"], int(slot_f), row2["startedAt"], actions]))
	var roll := DmLabor.roll_labor(def, {"level": pr["skill_level"], "xp": pr["skill_xp"]}, float(elapsed), seed_rng.as_callable())
	var before := _clone_slots(acc)
	var placed := DmGathering.place_items(_placement_rows(acc), roll["items"], func(_id: String) -> int: return 250)
	if not placed["rejected"].is_empty():
		var n := 0
		for g in placed["rejected"]:
			n += int(g["qty"])
		acc["slots"] = before
		return _fail("Make room in your bag: %d of their finds would not fit." % n)
	_apply_placed(acc, placed)
	pr["skill_level"] = roll["progress"]["level"]
	pr["skill_xp"] = roll["progress"]["xp"]
	row2["startedAt"] = now
	var view := _labor_view(acc, now)
	view["collected"] = {"slot": int(slot_f), "node": def["id"], "skill": def["skill"], "hours": float(elapsed) / 3600000.0, "actions": actions, "items": placed["stored"], "gold": roll["gold"], "xp": roll["xp"], "leveledUp": int(roll["leveled"]) > 0}
	return _ok(view)

# --- Grave Gardening ---------------------------------------------------------------------------------------------------------------

func _plots(acc: Dictionary) -> Dictionary:
	if not acc.has("garden"):
		acc["garden"] = {}
	return acc["garden"]

func _garden_view(acc: Dictionary, now: int) -> Dictionary:
	var pr: Variant = _find_prof(acc, "gardening")
	var level := 1 if pr == null else int(pr["skill_level"])
	var plots: Array = []
	for d in DmGarden.plots():
		var row: Variant = _plots(acc).get(d["id"])
		plots.append({"plot": d["id"], "kind": d["kind"], "label": d["label"], "seedId": row.get("seedId") if row != null else null,
			"plantedAt": int(row.get("plantedAt", 0)) if row != null else 0, "readyAt": int(row.get("readyAt", 0)) if row != null else 0,
			"composted": row != null and _truthy(row.get("composted")), "state": DmGarden.state_of(row, now)})
	return {"now": now, "level": level, "xp": 0 if pr == null else int(pr["skill_xp"]), "xpToNext": DmGathering.xp_to_next(level), "plots": plots}

func _garden_xp(acc: Dictionary, xp: int) -> bool:
	var pr: Variant = _find_prof(acc, "gardening")
	if pr == null:
		pr = {"profession_id": "gardening", "skill_level": 1, "skill_xp": 0}
		acc["professions"].append(pr)
	var nxt: Dictionary = DmGathering.add_skill_xp({"level": pr["skill_level"], "xp": pr["skill_xp"]}, xp)
	pr["skill_level"] = nxt["level"]
	pr["skill_xp"] = nxt["xp"]
	return int(nxt["leveled"]) > 0

func _bag_has(acc: Dictionary, item_id: String, n: int) -> bool:
	var t := 0
	for s in acc["slots"]:
		if s["item_id"] == item_id and not _truthy(s.get("equipped")) and int(s["slot_index"]) < BAG:
			t += int(s["quantity"])
	return t >= n

func _take_from_bag(acc: Dictionary, item_id: String, n: int) -> bool:
	if not _bag_has(acc, item_id, n):
		return false
	var left := n
	for s in acc["slots"]:
		if s["item_id"] == item_id and not _truthy(s.get("equipped")) and int(s["slot_index"]) < BAG:
			var t := mini(left, int(s["quantity"]))
			s["quantity"] = int(s["quantity"]) - t
			left -= t
	acc["slots"] = acc["slots"].filter(func(s): return int(s["quantity"]) > 0)
	return true

func _garden_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var now := _now()
	var plot_id := String(body["plot"]) if body.get("plot") is String else ""
	if p == "/api/garden/plant":
		var view := _garden_view(acc, now)
		var seed_id := String(body["seedId"]) if body.get("seedId") is String else ""
		var blocked := DmGarden.plant_blocker(DmGarden.plot_def(plot_id), seed_id, int(view["level"]), _plots(acc).get(plot_id), now)
		if blocked != "":
			return _fail(blocked)
		var compost := _truthy(body.get("compost"))
		if not _bag_has(acc, seed_id, 1):
			return _fail("You have no such seed in your bag.")
		if compost and not _bag_has(acc, DmGarden.compost_item(), 1):
			return _fail("You have no bone meal in your bag.")
		_take_from_bag(acc, seed_id, 1)
		if compost:
			_take_from_bag(acc, DmGarden.compost_item(), 1)
		var seed := DmGarden.seed_def(seed_id)
		_plots(acc)[plot_id] = {"plot": plot_id, "seedId": seed["id"], "plantedAt": now, "readyAt": now + DmGarden.grow_ms(seed, compost), "composted": compost}
		var leveled := _garden_xp(acc, int(seed["plantXp"]))
		var out := _garden_view(acc, now)
		out["gainedXp"] = seed["plantXp"]
		out["leveledUp"] = leveled
		return _ok(out)
	if p != "/api/garden/harvest":
		return _err("Offline backend: no route for POST %s" % p, 404)
	var row: Variant = _plots(acc).get(plot_id)
	if DmGarden.state_of(row, now) == "empty":
		return _fail("Nothing is growing there.")
	if DmGarden.state_of(row, now) != "ready":
		return _fail("It is not ready yet.")
	var crop := DmGarden.roll_harvest(DmGarden.seed_def(String(row["seedId"])), _rand_callable())
	var grants: Array = [{"itemId": crop["itemId"], "qty": crop["qty"]}]
	if crop["seedBack"] != null:
		grants.append({"itemId": crop["seedBack"], "qty": 1})
	var placed := DmGathering.place_items(_placement_rows(acc), grants, func(_id: String) -> int: return 250)
	if not placed["rejected"].is_empty():
		return _fail("Make room in your bag before you harvest.")
	_apply_placed(acc, placed)
	_plots(acc).erase(plot_id)
	var leveled2 := _garden_xp(acc, int(crop["xp"]))
	var out2 := _garden_view(acc, now)
	out2["items"] = grants
	out2["gainedXp"] = crop["xp"]
	out2["leveledUp"] = leveled2
	return _ok(out2)

# --- capes and pets ----------------------------------------------------------------------------------------------------------------

func _cos(acc: Dictionary) -> Dictionary:
	if not acc.has("cosmetics"):
		acc["cosmetics"] = {"cape": null, "pet": null, "pets": []}
	return acc["cosmetics"]

func _cos_view(acc: Dictionary) -> Dictionary:
	var levels := _levels(acc)
	var c := _cos(acc)
	var capes: Array = []
	for cape in DmOfflineCosmetics.capes():
		var pr := DmOfflineCosmetics.cape_progress(cape, levels)
		capes.append({"id": cape["id"], "name": cape["name"], "lore": cape["lore"], "color": cape["color"], "trim": cape["trim"], "unlocked": pr["unlocked"], "have": pr["have"], "need": pr["need"]})
	var pets: Array = []
	for pt in DmOfflineCosmetics.pets():
		pets.append({"id": pt["id"], "name": pt["name"], "charm": pt["charm"], "skill": pt["skill"], "lore": pt["lore"], "adopted": c["pets"].has(pt["id"])})
	return {"totalLevel": DmOfflineCosmetics.total_level(levels), "capes": capes, "pets": pets, "selected": {"cape": c["cape"], "pet": c["pet"]}}

func _cosmetics_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var c := _cos(acc)
	if p == "/api/cosmetics/select":
		if body.has("cape"):
			if body["cape"] == null:
				c["cape"] = null
			elif not DmOfflineCosmetics.cape_unlocked(str(body["cape"]), _levels(acc)):
				return _fail("You have not earned that cape yet.")
			else:
				c["cape"] = str(body["cape"])
		if body.has("pet"):
			if body["pet"] == null:
				c["pet"] = null
			elif not c["pets"].has(str(body["pet"])):
				return _fail("You have not adopted that companion.")
			else:
				c["pet"] = str(body["pet"])
		return _ok(_cos_view(acc))
	if p == "/api/cosmetics/adopt":
		var def := DmOfflineCosmetics.pet_def(String(body["petId"]) if body.get("petId") != null else "")
		if def.is_empty():
			return _fail("There is no such companion.")
		if c["pets"].has(def["id"]):
			return _fail("The %s is already yours. Keep the charm for someone else, or sell it." % def["name"])
		if not _take_from_bag(acc, def["charm"], 1):
			return _fail("You have no %s Charm in your bag." % def["name"])
		c["pets"].append(def["id"])
		if c["pet"] == null:
			c["pet"] = def["id"]
		var out := _cos_view(acc)
		out["adopted"] = def["id"]
		return _ok(out)
	return _err("Offline backend: no route for POST %s" % p, 404)

# --- Sexton's Contracts ------------------------------------------------------------------------------------------------------------

func _contracts_state(acc: Dictionary) -> Dictionary:
	var day := DmContracts.day_key(_now())
	var cur: Variant = acc.get("contracts")
	if cur == null or cur["day"] != day:
		acc["contracts"] = {"day": day, "done": [], "bonus": false, "days": cur["days"] if cur != null else []}
	return acc["contracts"]

func _item_name(id: String) -> String:
	return String(DmGatherData.item_meta(id)["name"])

func _contract_view(acc: Dictionary) -> Dictionary:
	var st := _contracts_state(acc)
	var board: Array = DmContracts.generate_board(int(acc["character"]["id"]), st["day"], _levels(acc))
	var bonus := DmContracts.bonus_for(board)
	var contracts: Array = []
	for c in board:
		var e: Dictionary = c.duplicate()
		e["name"] = _item_name(c["itemId"])
		e["rarity"] = DmGatherData.item_meta(c["itemId"])["rarity"]
		e["done"] = st["done"].has(c["slot"])
		if c["rewardItem"] != null:
			var ri: Dictionary = c["rewardItem"].duplicate()
			ri["name"] = _item_name(ri["itemId"])
			e["rewardItem"] = ri
		contracts.append(e)
	var bi: Dictionary = bonus["item"].duplicate()
	bi["name"] = _item_name(bi["itemId"])
	return {"board": board, "view": {"day": st["day"], "resetsAt": _iso(DmContracts.next_reset_ms(_now())), "contracts": contracts,
		"bonus": {"gold": bonus["gold"], "item": bi, "claimed": st["bonus"]}, "streak": DmContracts.streak_of(st["days"], st["day"])}}

## Hand `qty` of an item into the bag for a contract reward: onto an existing bag stack, else the first free slot.
func _grant(acc: Dictionary, item_id: String, qty: int) -> bool:
	for s in acc["slots"]:
		if s["item_id"] == item_id and int(s["slot_index"]) < BAG and not _truthy(s.get("equipped")):
			s["quantity"] = int(s["quantity"]) + qty
			return true
	var free := _free_bag_slot(acc)
	if free < 0:
		return false
	acc["slots"].append({"slot_index": free, "item_id": item_id, "quantity": qty, "equipped": 0})
	return true

func _contracts_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	if p != "/api/contracts/deliver":
		return _err("Offline backend: no route for POST %s" % p, 404)
	var st := _contracts_state(acc)
	var board: Array = _contract_view(acc)["board"]
	var sf := _num(body, "slot")
	if not _is_int(sf) or sf < 0 or sf >= board.size():
		return _fail("unknown contract")
	var c: Dictionary = board[int(sf)]
	if st["done"].has(c["slot"]):
		return _fail("That order is already filled.")
	var have := 0
	for s in acc["slots"]:
		if s["item_id"] == c["itemId"] and not _truthy(s.get("equipped")) and int(s["slot_index"]) < BAG:
			have += int(s["quantity"])
	if have < int(c["qty"]):
		return _fail("You need %d of that in your bag." % int(c["qty"]))
	var before := _clone_slots(acc)
	var left := int(c["qty"])
	var mine: Array = acc["slots"].filter(func(x): return x["item_id"] == c["itemId"] and not _truthy(x.get("equipped")) and int(x["slot_index"]) < BAG)
	mine = DmStableSort.sorted(mine, func(a, b): return int(a["slot_index"]) < int(b["slot_index"]))
	for s in mine:
		var take := mini(left, int(s["quantity"]))
		s["quantity"] = int(s["quantity"]) - take
		left -= take
	acc["slots"] = acc["slots"].filter(func(s): return int(s["quantity"]) > 0)
	var items: Array = []
	if c["rewardItem"] != null:
		if not _grant(acc, c["rewardItem"]["itemId"], int(c["rewardItem"]["qty"])):
			acc["slots"] = before
			return _fail("Make room in your bag for the reward.")
		items.append(c["rewardItem"].duplicate())
	st["done"].append(c["slot"])
	if not st["days"].has(st["day"]):
		st["days"].append(st["day"])
	var gold := int(c["rewardGold"])
	var paid: Variant = null
	var all_done := true
	for o in board:
		if not st["done"].has(o["slot"]):
			all_done = false
	if not st["bonus"] and all_done:
		var b := DmContracts.bonus_for(board)
		_grant(acc, b["item"]["itemId"], int(b["item"]["qty"]))
		st["bonus"] = true
		gold += int(b["gold"])
		items.append(b["item"].duplicate())
		paid = {"gold": b["gold"], "item": b["item"].duplicate()}
	var out: Dictionary = _contract_view(acc)["view"]
	out["gold"] = gold
	out["items"] = items
	out["paidBonus"] = paid
	return _ok(out)

# --- necromancer progression -------------------------------------------------------------------------------------------------------

func _necro_post(acc: Dictionary, action: String, body: Dictionary) -> Dictionary:
	if not (action in ["save", "purchase", "summon-prelate", "summon-boss", "ascend", "vows", "unlock", "boon", "import"]):
		return _err("Offline backend: no route for POST /api/necro-progress/%s" % action, 404)
	var c: Dictionary = acc["character"]
	var state: Dictionary = DmNecroRules.normalise(acc.get("necro", DmNecroRules.blank_state()))
	var r: Dictionary
	match action:
		"save": r = DmNecroRules.apply_save(state, body)
		"purchase": r = DmNecroRules.purchase(state, _num_or(c.get("gold"), 0.0), body.get("upgrade"))
		"summon-prelate": r = DmNecroRules.summon_prelate(state)
		"summon-boss": r = DmNecroRules.summon_area_boss(state, body.get("boss"))
		"vows": r = DmNecroRules.swear_vows(state, body.get("vows"))
		"unlock": r = DmNecroRules.unlock_entry(state, body.get("key"))
		"ascend": r = DmNecroRules.ascend(state)
		"boon": r = DmNecroRules.buy_boon(state, body.get("boonId"))
		_: r = DmNecroRules.import_local(state, body.get("record"))
	if not r["ok"]:
		return _err(String(r["error"]), 400)
	acc["necro"] = r["state"]
	var out := {"progress": r["state"]}
	if r.has("gold"):
		c["gold"] = _tidy(float(r["gold"]))
		out["gold"] = c["gold"]
	if r.has("earned"):
		out["earned"] = r["earned"]
	if r.has("cost"):
		out["cost"] = r["cost"]
	return _ok(out)

# --- offline sync (port of offline-full-sync.cjs at the contract level) -------------------------------------------------------------

func _capture(acc: Dictionary) -> Dictionary:
	var slots: Array = []
	for s in acc["slots"]:
		var row := {"slot_index": int(s["slot_index"]), "item_id": s["item_id"], "quantity": int(s["quantity"]), "equipped": 1 if s.get("equipped", 0) else 0}
		# The portable save carries each roll inline (the online server mints fresh instances from it), not our local ids.
		var roll: Variant = acc.get("instances", {}).get(str(int(s["instance_id"]))) if s.get("instance_id") != null else null
		if roll != null:
			row["inst"] = {"ilvl": roll["ilvl"], "affixes": roll["affixes"].duplicate(true)}
		slots.append(row)
	slots.sort_custom(func(a, b): return a["slot_index"] < b["slot_index"])
	return {"username": acc["username"], "character": acc["character"].duplicate(true), "slots": slots, "professions": acc["professions"].duplicate(true),
		"necro": acc.get("necro", {}), "chronicle": _chron(acc).duplicate(true)}

func _fingerprint(snap: Dictionary) -> String:
	return JSON.stringify(snap, "", true).sha256_text()

func _summary(snap: Dictionary) -> Dictionary:
	var ch: Dictionary = snap["character"]
	return {"discipline": ch.get("class_name", ""), "level": int(ch.get("level", 1)), "experience": int(ch.get("experience", 0)), "gold": int(ch.get("gold", 0)),
		"items": snap["slots"].size(), "professions": snap["professions"].size(), "ascension": int(snap.get("necro", {}).get("ascension", 0))}

func _offline_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	if acc["character"] == null:
		return _err("Create an online character before syncing.", 404)
	if p == "/api/offline/sync-stats":
		var cls: Variant = body.get("classIndex")
		if not (cls is int) or cls != int(acc["character"]["class_index"]):
			return _err("The offline and online characters must use the same discipline.", 400)
		var lvl: Variant = body.get("level")
		var xp: Variant = body.get("experience")
		if not (lvl is int) or not (xp is int) or lvl < 1 or xp < 0:
			return _err("Invalid offline level or XP.", 400)
		var c: Dictionary = acc["character"]
		var better: bool = lvl > int(c["level"]) or (lvl == int(c["level"]) and xp > int(c["experience"]))
		if better:
			c["level"] = lvl
			c["experience"] = xp
		return {"status": 200, "body": {"level": c["level"], "experience": c["experience"], "improved": better}}
	var expected := String(body.get("expectedFingerprint", ""))
	if expected.length() != 64:
		return _err("Refresh the online save comparison before loading a version.", 400)
	var source := "offline"
	var incoming: Variant = body.get("snapshot")
	if p == "/api/offline/restore":
		source = "restored"
		incoming = null
		for v in acc["versions"]:
			if int(v["id"]) == int(body.get("versionId", -1)):
				incoming = v["snapshot"]
		if incoming == null:
			return _err("Saved version not found.", 404)
	elif p != "/api/offline/load":
		return _err("Offline backend: no route for POST %s" % p, 404)
	if not (incoming is Dictionary) or not (incoming.get("character") is Dictionary) or not (incoming.get("slots") is Array) or not (incoming.get("professions") is Array):
		return _err("Invalid online save.", 400)
	var before := _capture(acc)
	if _fingerprint(before) != expected:
		return {"status": 409, "body": {"error": "The online save changed. Compare the saves again before choosing.", "summary": _summary(before)}}
	acc["versions"].append({"id": int(acc["next_version"]), "source": "online", "createdAt": _iso(_now()), "snapshot": before})
	acc["versions"].append({"id": int(acc["next_version"]) + 1, "source": source, "createdAt": _iso(_now()), "snapshot": incoming.duplicate(true)})
	acc["next_version"] = int(acc["next_version"]) + 2
	while acc["versions"].size() > 20:
		acc["versions"].pop_front()
	var keep_id: int = int(acc["character"]["id"])
	acc["character"] = incoming["character"].duplicate(true)
	acc["character"]["id"] = keep_id
	acc["instances"] = {}
	acc["nextInstance"] = 1
	acc["slots"] = []
	for sl in incoming["slots"]:
		var row: Dictionary = sl.duplicate(true)
		var inst: Variant = row.get("inst")
		row.erase("inst")
		row.erase("instance_id")
		# Online rolls arrive inline; give each a local instance id.
		if inst is Dictionary and DmAffixRules.instance_problem(inst, _type_of(String(row["item_id"])) if _has_def(String(row["item_id"])) else "material") == "":
			row["instance_id"] = _mint_instance(acc, String(row["item_id"]), int(inst["ilvl"]), DmAffixRules.clean_instance(inst)["affixes"])
		acc["slots"].append(row)
	acc["professions"] = incoming["professions"].duplicate(true)
	if incoming.get("necro") is Dictionary:
		acc["necro"] = incoming["necro"].duplicate(true)
	if incoming.get("chronicle") is Dictionary:
		acc["chronicle"] = incoming["chronicle"].duplicate(true)
	var after := _capture(acc)
	return {"status": 200, "body": {"summary": _summary(after), "fingerprint": _fingerprint(after)}}

func _leaderboard() -> Dictionary:
	var rows: Array = []
	for name in db["accounts"]:
		var a: Dictionary = db["accounts"][name]
		if a["character"] == null:
			continue
		var c: Dictionary = a["character"]
		var ch: Dictionary = a.get("chronicle", {"life": {}, "runNo": 1})
		var necro: Dictionary = a.get("necro", {})
		rows.append({"username": name, "classIndex": int(c["class_index"]), "hasDiscipline": int(c["class_index"]) >= 1, "level": int(c["level"]), "ascension": int(necro.get("ascension", 0)),
			"bossKills": int(necro.get("bossKills", 0)), "totalKills": int(necro.get("totalKills", 0)), "playSeconds": int(ch["life"].get("playSeconds", 0)), "runs": int(ch.get("runNo", 1)) - 1, "bestDepth": int(ch["life"].get("peak.depth", 0))})
	rows.sort_custom(func(a, b): return [b["ascension"], b["bossKills"], b["totalKills"], b["level"]] < [a["ascension"], a["bossKills"], a["totalKills"], a["level"]])
	for i in rows.size():
		rows[i]["rank"] = i + 1
	return {"status": 200, "body": {"players": rows.slice(0, 25), "updatedAt": _iso(_now())}}
