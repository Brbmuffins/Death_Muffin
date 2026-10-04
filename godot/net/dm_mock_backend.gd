class_name DmMockBackend
extends RefCounted
## In-process stand-in for the Death Muffin server (port of src/net/mockBackend.ts) for development and the future offline edition.
## Plug it in as the transport:   var mock := DmMockBackend.new();  var api := DmApi.new(mock.transport_callable());  api.base_url = ""
## State lives in one JSON file (user://dm_offline_db.json by default; "" = memory only). Tokens are "offline:<username>".
##
## Ported: auth, character, inventory get/save/equip, professions, save-progress, kills/report, chronicle, necro get/import/save(raw),
## prefs, bug reports, loadouts list/save/delete, session probe/claim, offline snapshot/versions/load/restore/sync-stats, leaderboard, health.
## Stubbed (HTTP 501 "Offline edition: ... is not ported yet", waiting on the rules tracks they need): craft, gather, salvage, reforge,
## boss-key, vault, contracts, garden, labor, cosmetics, loot roll, belt/kit/rune, loadout apply, necro purchase/ascend/vows/unlock/boon/summons.
## Item definitions (name, rarity, item_type, equipment_slot, two_handed, sell_value, stat_bonus) come from `catalog`
## (item_id -> Dictionary), to be filled from godot/data; unknown items still work and read as common materials.

const BAG := 48
const CLASS_NAMES := ["Engineer", "Guardian", "Shadowblade", "Cleric", "Arcanist", "Necromancer"]
const DISCIPLINE_NAMES := {5: "Grave Warden", 6: "Bell Monk", 7: "Carrion Witch", 8: "Hollow Knight", 9: "Veilwalker"}
const MAX_DISCIPLINE_INDEX := 9
const RESERVED := {"head": 100, "chest": 101, "legs": 102, "feet": 103, "hands": 104, "main_hand": 105, "off_hand": 106, "ring": 107, "trinket": 108}
const TYPE_TO_SLOT := {"weapon": "main_hand", "armor_head": "head", "armor_chest": "chest", "armor_legs": "legs", "armor_feet": "feet", "armor_hands": "hands", "offhand": "off_hand", "ring": "ring", "trinket": "trinket"}
const MAX_PRESETS := 6
const STUBBED := ["craft", "gather", "gather/afk-start", "salvage", "reforge", "reforge/quote", "boss-key", "vault", "contracts", "garden", "labor", "cosmetics", "loot/roll-gear", "inventory/belt", "inventory/kit", "inventory/rune", "loadouts/apply", "necro-progress/purchase", "necro-progress/ascend", "necro-progress/vows", "necro-progress/unlock", "necro-progress/boon", "necro-progress/summon"]

var catalog: Dictionary = {}
var persist_path: String = "user://dm_offline_db.json"
var db: Dictionary = {"next_character_id": 1, "accounts": {}}
## Wall clock source (ms), injectable for tests.
var now_ms: Callable = Callable()

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

func _save() -> void:
	if persist_path.is_empty():
		return
	var f := FileAccess.open(persist_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(db))

func _now() -> int:
	return int(now_ms.call()) if now_ms.is_valid() else int(Time.get_unix_time_from_system() * 1000.0)

func _iso(ms: int) -> String:
	return Time.get_datetime_string_from_unix_time(ms / 1000, true) + "Z"

# --- reply helpers -----------------------------------------------------------------------------------------------------------------

static func _ok(data: Variant) -> Dictionary:
	return {"status": 200, "body": {"success": true, "data": data}}

static func _fail(msg: String) -> Dictionary:
	return {"status": 200, "body": {"success": false, "error": msg}}

static func _err(msg: String, status: int) -> Dictionary:
	return {"status": status, "body": {"success": false, "error": msg}}

# --- item catalogue ----------------------------------------------------------------------------------------------------------------

func _def(item_id: String) -> Dictionary:
	return catalog.get(item_id, {})

func _equip_slot(item_id: String) -> String:
	var d := _def(item_id)
	if d.get("equipment_slot", "") is String and RESERVED.has(d.get("equipment_slot", "")):
		return d["equipment_slot"]
	return TYPE_TO_SLOT.get(d.get("item_type", "material"), "")

func _join(acc: Dictionary, s: Dictionary, i: int) -> Dictionary:
	var d := _def(String(s["item_id"]))
	return {"id": i + 1, "slot_index": int(s["slot_index"]), "quantity": int(s["quantity"]), "equipped": 1 if s.get("equipped", 0) else 0,
		"item_id": s["item_id"], "name": d.get("name", s["item_id"]), "rarity": d.get("rarity", "common"), "item_type": d.get("item_type", "material"),
		"stat_bonus": d.get("stat_bonus"), "icon_id": null, "sell_value": int(d.get("sell_value", 0)), "crafted": 0}

func _rows(acc: Dictionary) -> Array:
	var out: Array = []
	for i in acc["slots"].size():
		out.append(_join(acc, acc["slots"][i], i))
	return out

# --- routing -----------------------------------------------------------------------------------------------------------------------

func handle(method: String, path: String, query: String, body: Dictionary, token: Variant) -> Dictionary:
	var res := _route(method, path, query, body, token)
	_save()
	return res

func _account_for(token: Variant) -> Variant:
	if not (token is String) or not String(token).begins_with("offline:"):
		return null
	return db["accounts"].get(String(token).substr(8))

func _own(acc: Dictionary, character_id: Variant) -> bool:
	return acc["character"] != null and int(character_id) == int(acc["character"]["id"])

func _stub_hit(path: String) -> bool:
	for s in STUBBED:
		if path.begins_with("/api/" + s):
			return true
	return false

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
		db["accounts"][username] = {"username": username, "character": null, "slots": [], "prefs": {}, "bug_reports": [], "versions": [], "loadouts": {}, "next_version": 1,
			"professions": [{"profession_id": "mining", "skill_level": 1, "skill_xp": 0}, {"profession_id": "fishing", "skill_level": 1, "skill_xp": 0}, {"profession_id": "woodcutting", "skill_level": 1, "skill_xp": 0}]}
		return {"status": 201, "body": {"token": "offline:" + username}}
	if p == "/leaderboard" and method == "GET":
		return _leaderboard()
	if p == "/api/recipes" and method == "GET":
		var want := ""
		for kv in query.split("&", false):
			if kv.begins_with("profession="):
				want = kv.substr(11).uri_decode()
		var recipes: Array = []
		for r in catalog.get("__recipes", []):
			if want.is_empty() or r.get("profession_id") == want:
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
			return {"status": 404, "body": {"error": "No character"}}
		return {"status": 200, "body": acc["character"]}
	if p == "/character/discipline" and method == "POST":
		var index: Variant = body.get("class_index")
		if not (index is int) or index < 1 or index > MAX_DISCIPLINE_INDEX:
			return {"status": 400, "body": {"error": "Choose one of the %d classes." % MAX_DISCIPLINE_INDEX}}
		if not _own(acc, body.get("characterId")):
			return {"status": 404, "body": {"error": "Character not found"}}
		acc["character"]["class_index"] = index
		acc["character"]["class_name"] = DISCIPLINE_NAMES.get(index, CLASS_NAMES[index] if index < CLASS_NAMES.size() else acc["character"]["class_name"])
		return {"status": 200, "body": acc["character"]}
	if p == "/character" and method == "POST":
		if acc["character"] != null:
			return {"status": 200, "body": acc["character"]}
		var idx: Variant = body.get("class_index")
		if not (idx is int) or idx < 0 or idx >= CLASS_NAMES.size():
			return {"status": 400, "body": {"error": "class_index must be 0-5"}}
		acc["character"] = {"id": int(db["next_character_id"]), "class_index": idx, "class_name": CLASS_NAMES[idx], "level": 1, "experience": 0, "gold": 0,
			"stat_str": 7 if idx == 1 else 5, "stat_agi": 7 if idx == 2 else 5, "stat_int": 7 if idx == 3 or idx == 4 else 5, "stat_vit": 7 if idx == 1 else 5}
		db["next_character_id"] = int(db["next_character_id"]) + 1
		acc["slots"] = [{"slot_index": 0, "item_id": "staff_oak", "quantity": 1, "equipped": 0}, {"slot_index": 1, "item_id": "flask_hp_minor", "quantity": 3, "equipped": 0}]
		return {"status": 200, "body": acc["character"]}

	var m := RegEx.create_from_string("^/api/(inventory|professions|chronicle|necro-progress|loadouts)/(\\d+)$").search(p)
	if m != null and method == "GET":
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
			"necro-progress": return _ok({"progress": acc.get("necro", {}), "gold": acc["character"]["gold"]})
			"loadouts": return _ok(_loadout_list(acc))

	if method == "GET":
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
		return _err("Offline backend: no route for %s %s" % [method, p], 404)

	if method == "POST":
		if p.begins_with("/api/offline/"):
			return _offline_post(acc, p, body)
		if _stub_hit(p):
			return {"status": 501, "body": {"success": false, "error": "Offline edition: %s is not ported yet." % p}}
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
		if p == "/api/kills/report":
			return _ok({"mode": "off"})
		# everything below needs the character id
		if not _own(acc, body.get("characterId")):
			return _err("Character not found", 404)
		return _character_post(acc, p, body)
	return _err("Offline backend: no route for %s %s" % [method, p], 404)

func _character_post(acc: Dictionary, p: String, body: Dictionary) -> Dictionary:
	var c: Dictionary = acc["character"]
	match p:
		"/api/character/save-progress":
			c["level"] = int(body.get("level", c["level"]))
			c["experience"] = int(body.get("xp", 0))
			c["gold"] = maxi(0, int(body.get("gold", 0)))
			for k in ["stat_str", "stat_agi", "stat_int", "stat_vit"]:
				if body.has(k):
					c[k] = int(body[k])
			return _ok({"saved": true})
		"/api/inventory/save":
			var bag_size := BAG if body.get("bagSize") == null else int(body["bagSize"])
			if bag_size < 1 or bag_size > BAG:
				return _fail("bagSize must be a whole number from 1 to %d" % BAG)
			var next: Array = []
			for s in body.get("slots", []):
				var idx := int(s.get("slot_index", -1))
				if idx >= 100:
					continue
				if idx < 0 or idx >= bag_size:
					return _fail("each slot_index must be between 0 and %d" % (bag_size - 1))
				var qty := int(s.get("quantity", 0))
				if qty <= 0:
					continue
				next.append({"slot_index": idx, "item_id": String(s["item_id"]), "quantity": qty, "equipped": 1 if s.get("equipped", 0) else 0})
			var kept: Array = acc["slots"].filter(func(x): return int(x["slot_index"]) >= 100 or int(x["slot_index"]) >= bag_size)
			acc["slots"] = kept + next
			return _ok(_rows(acc))
		"/api/inventory/equip":
			return _equip(acc, body)
		"/api/chronicle/add":
			var ch := _chron(acc)
			for k in body.get("deltas", {}):
				for t in [ch["life"], ch["run"]]:
					t[k] = int(t.get(k, 0)) + maxi(0, int(body["deltas"][k]))
			for k in body.get("maxes", {}):
				for t in [ch["life"], ch["run"]]:
					t[k] = maxi(int(t.get(k, 0)), int(body["maxes"][k]))
			return _ok({})
		"/api/chronicle/ascend":
			var ch := _chron(acc)
			if ch["run"].is_empty():
				return _ok({"archived": false})
			ch["runs"].append({"runNo": ch["runNo"], "startedAt": ch["runStartedAt"], "endedAt": _iso(_now()), "ascensionAfter": int(body.get("ascension", 0)), "stats": ch["run"]})
			ch["run"] = {}
			ch["runNo"] = int(ch["runNo"]) + 1
			ch["runStartedAt"] = _iso(_now())
			return _ok({"archived": true})
		"/api/necro-progress/save", "/api/necro-progress/import":
			# The real rules (necroRules.applySave / importLocal) belong to the rules track: until then the record is stored as given.
			var rec: Variant = body.get("record") if p.ends_with("import") else body.duplicate()
			if rec is Dictionary:
				rec.erase("characterId")
				acc["necro"] = rec
			return _ok({"progress": acc.get("necro", {}), "gold": c["gold"]})
		"/api/loadouts/save":
			var slot := int(body.get("slot", -1))
			if slot < 0 or slot >= MAX_PRESETS:
				return _err("slot must be 0 to %d" % (MAX_PRESETS - 1), 400)
			if not (body.get("preset") is Dictionary):
				return _fail("preset must be an object")
			acc["loadouts"][str(slot)] = body["preset"]
			return _ok(_loadout_list(acc))
		"/api/loadouts/delete":
			acc["loadouts"].erase(str(int(body.get("slot", -1))))
			return _ok(_loadout_list(acc))
	return _err("Offline backend: no route for POST %s" % p, 404)

func _chron(acc: Dictionary) -> Dictionary:
	if not acc.has("chronicle"):
		acc["chronicle"] = {"life": {}, "run": {}, "runNo": 1, "runStartedAt": _iso(_now()), "runs": []}
	return acc["chronicle"]

func _loadout_list(acc: Dictionary) -> Array:
	var out: Array = []
	for k in acc["loadouts"]:
		out.append({"slot": int(k), "preset": acc["loadouts"][k]})
	out.sort_custom(func(a, b): return a["slot"] < b["slot"])
	return out

## Same rules as the server: one item per gear slot, two-handers displace the off-hand and vice versa.
func _equip(acc: Dictionary, body: Dictionary) -> Dictionary:
	var slots: Array = acc["slots"]
	var slot: Variant = null
	for s in slots:
		if int(s["slot_index"]) == int(body.get("slot_index", -1)):
			slot = s
	if slot == null:
		return _fail("Slot is empty")
	var gear := _equip_slot(String(slot["item_id"]))
	if gear.is_empty():
		return _fail("That item cannot be equipped")
	var reserved: int = RESERVED[gear]
	var taken := func(i: int, ignore: Array) -> bool:
		for s in slots:
			if s != slot and not ignore.has(s) and int(s["slot_index"]) == i:
				return true
		return false
	if body.get("equipped", 0):
		var two := bool(_def(String(slot["item_id"])).get("two_handed", false))
		var displaced: Array = slots.filter(func(s): return s != slot and (int(s["slot_index"]) == reserved or (two and int(s["slot_index"]) == 106) or (gear == "off_hand" and int(s["slot_index"]) == 105 and bool(_def(String(s["item_id"])).get("two_handed", false)))))
		var free_bag: Array = []
		for i in BAG:
			if not taken.call(i, displaced):
				free_bag.append(i)
		if displaced.size() > free_bag.size() + 1:
			return _fail("Not enough inventory space to swap equipment")
		var bag_index := int(slot["slot_index"])
		slot["slot_index"] = reserved
		slot["equipped"] = 1
		for i in displaced.size():
			displaced[i]["slot_index"] = bag_index if i == 0 else free_bag[i - 1]
			displaced[i]["equipped"] = 0
	else:
		var free := -1
		for i in BAG:
			if not taken.call(i, []):
				free = i
				break
		if free < 0:
			return _fail("Inventory full")
		slot["slot_index"] = free
		slot["equipped"] = 0
	return _ok(_rows(acc))

# --- offline sync (port of offline-full-sync.cjs at the contract level) -------------------------------------------------------------

func _capture(acc: Dictionary) -> Dictionary:
	var slots: Array = []
	for s in acc["slots"]:
		slots.append({"slot_index": int(s["slot_index"]), "item_id": s["item_id"], "quantity": int(s["quantity"]), "equipped": 1 if s.get("equipped", 0) else 0})
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
	acc["slots"] = incoming["slots"].duplicate(true)
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
