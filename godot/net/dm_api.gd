class_name DmApi
extends RefCounted
## REST client for the Death Muffin backend (port of src/net/api.ts + session.ts). No UI, no nodes: inject a transport.
##
## Every call is `await`-able and returns a DmResult (ok / data / error / status). Server `error` strings are player-readable:
## show `result.error` verbatim. Numbers in `data` are int when integral (see DmJson).
##
##   var api := DmApi.new(transport.request_callable())
##   var r := await api.login("name", "password")
##   if r.ok: api.set_token(r.data["token"])
##
## Behaviour kept from the TS client: JSON content type on every request; `Authorization: Bearer <jwt>` on authenticated ones; no automatic
## retries and no client-side rate limiting (a 429 surfaces as the server's `error` or "Request failed: 429"); `{success,data}` envelopes
## unwrapped; a `success:false` reply becomes an error with status 200; `authority.message` on a save is emitted as `server_notice`;
## once a 409 `session_replaced` is seen, every authenticated non-GET call is refused locally until `claim_session()` succeeds.

signal server_notice(message: String)
signal session_replaced

const SESSION_REPLACED_MESSAGE := "This account was opened somewhere else. This window stopped saving."
const TOKEN_FILE := "user://dm_jwt.txt"

## Callable(req: Dictionary) -> Dictionary  (see DmHttpTransport)
var transport: Callable
var base_url: String = DmConfig.API_BASE
var site_base: String = DmConfig.SITE_BASE
## Keep the JWT in user://dm_jwt.txt (the desktop equivalent of the browser's localStorage). Off by default.
var persist_token: bool = false
## Applied to every inventory-row array the server returns (the TS client's decorateSlots: affix names, rarity, prices). Set by the loot rules.
var slot_decorator: Callable = Callable()

var _token: String = ""
var _replaced: bool = false
var _roll_busy: bool = false

func _init(transport_callable: Callable = Callable()) -> void:
	transport = transport_callable

# --- token / session ---------------------------------------------------------------------------------------------------------------

func set_token(token: String) -> void:
	_token = token
	if not persist_token:
		return
	if token.is_empty():
		if FileAccess.file_exists(TOKEN_FILE):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TOKEN_FILE))
		return
	var f := FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(token)

func get_token() -> String:
	if not _token.is_empty():
		return _token
	if persist_token and FileAccess.file_exists(TOKEN_FILE):
		_token = FileAccess.get_file_as_string(TOKEN_FILE).strip_edges()
	return _token

func is_session_replaced() -> bool:
	return _replaced

func notify_session_replaced() -> void:
	if _replaced:
		return
	_replaced = true
	session_replaced.emit()

## True for the 409 body the server sends when a write comes from a replaced session.
static func is_replaced_reply(status: int, body: Variant) -> bool:
	return status == 409 and body is Dictionary and body.get("code") == "session_replaced"

## "Play here": trade the current token for one on a new session. Returns the new token, or "" when refused/unreachable
## (an expired token means: log in again). Clears the replaced flag on success and stores the new token.
func claim_session(token: String) -> String:
	var resp := await _send("POST", base_url + "/api/session/claim", {"Authorization": "Bearer " + token}, "")
	if resp.get("network_error", false):
		return ""
	var body: Variant = DmJson.parse(String(resp.get("text", "")))
	var st := int(resp.get("status", 0))
	if st >= 200 and st < 300 and body is Dictionary and body.get("token") is String:
		_replaced = false
		set_token(body["token"])
		return body["token"]
	return ""

## One "am I still the active window?" check (GET /api/session); fires session_replaced when not. Server/network trouble is ignored.
func probe_session() -> void:
	var tok := get_token()
	if tok.is_empty() or _replaced:
		return
	var resp := await _send("GET", base_url + "/api/session", {"Authorization": "Bearer " + tok}, "")
	if resp.get("network_error", false):
		return
	var body: Variant = DmJson.parse(String(resp.get("text", "")))
	var st := int(resp.get("status", 0))
	if st >= 200 and st < 300 and body is Dictionary and body.get("active") == false:
		notify_session_replaced()

# --- plumbing ----------------------------------------------------------------------------------------------------------------------

func _send(method: String, url: String, headers: Dictionary, body: String) -> Dictionary:
	if not transport.is_valid():
		return {"status": 0, "text": "", "network_error": true}
	return await transport.call({"method": method, "url": url, "headers": headers, "body": body})

## Port of request<T>(): raw body on success, DmResult failure otherwise. `body` is a Dictionary/Array or null (none).
func _request(path: String, method: String = "GET", body: Variant = null, auth: bool = false) -> DmResult:
	var headers := {"Content-Type": "application/json"}
	if auth and _replaced and method != "GET":
		return DmResult.failure(SESSION_REPLACED_MESSAGE, 409)
	if auth:
		var tok := get_token()
		if tok.is_empty():
			return DmResult.failure("Not authenticated", 401)
		headers["Authorization"] = "Bearer " + tok
	var resp := await _send(method, base_url + path, headers, "" if body == null else JSON.stringify(body))
	if resp.get("network_error", false):
		return DmResult.failure("Cannot reach server — check your connection", 0)
	var status := int(resp.get("status", 0))
	var parsed: Variant = DmJson.parse(String(resp.get("text", "")))
	if status < 200 or status >= 300:
		if is_replaced_reply(status, parsed):
			notify_session_replaced()
		var msg := "Request failed: %d" % status
		if parsed is Dictionary and parsed.get("error") is String and not String(parsed["error"]).is_empty():
			msg = parsed["error"]
		return DmResult.failure(msg, status)
	return DmResult.success(parsed, status)

## Port of unwrap(): `{success, data}` envelope -> data; emits server_notice for `authority.message`.
func _unwrap(r: DmResult) -> DmResult:
	if not r.ok:
		return r
	var body: Variant = r.data
	if not (body is Dictionary) or not body.get("success", false):
		var msg := "Unknown server error"
		if body is Dictionary and body.get("error") is String and not String(body["error"]).is_empty():
			msg = body["error"]
		return DmResult.failure(msg, 200)
	var authority: Variant = body.get("authority")
	if authority is Dictionary and authority.get("message") is String and not String(authority["message"]).is_empty():
		server_notice.emit(authority["message"])
	return DmResult.success(body.get("data"), r.status)

func _rget(path: String, auth: bool = true) -> DmResult:
	return _unwrap(await _request(path, "GET", null, auth))

func _post(path: String, body: Variant, auth: bool = true) -> DmResult:
	return _unwrap(await _request(path, "POST", body, auth))

func _decorate(rows: Variant) -> Variant:
	if slot_decorator.is_valid() and rows is Array:
		return slot_decorator.call(rows)
	return rows

## Unwrapped call whose data is an inventory-row array.
func _slots(r: DmResult) -> DmResult:
	if r.ok:
		r.data = _decorate(r.data)
	return r

## Vault / salvage / reforge / boss-key replies carry bag (and vault) row arrays inside an object.
func _decorate_keys(r: DmResult, keys: Array) -> DmResult:
	if r.ok and r.data is Dictionary:
		for k in keys:
			if r.data.has(k):
				r.data[k] = _decorate(r.data[k])
	return r

# --- Auth (no JWT) -----------------------------------------------------------------------------------------------------------------

## data: {token}
func login(username: String, password: String) -> DmResult:
	return await _request("/login", "POST", {"username": username, "password": password})

## Returns a session token directly. data: {token}
func register(username: String, email: String, password: String) -> DmResult:
	return await _request("/register", "POST", {"username": username, "email": email, "password": password})

## data: {status, uptime, db}
func health() -> DmResult:
	return await _request("/api/health")

# --- Character ---------------------------------------------------------------------------------------------------------------------

## `class_index` < 0 = not given. Disciplines above 4 are created as legacy 5 then switched, exactly like the TS client.
func load_or_create_character(class_index: int = -1) -> DmResult:
	var body := {}
	if class_index >= 0:
		body["class_index"] = 5 if class_index > 4 else class_index
	var r := await _request("/character", "POST", body, true)
	if r.ok and class_index > 4 and r.data is Dictionary:
		return await change_discipline(int(r.data.get("id", 0)), class_index)
	return r

func get_character() -> DmResult:
	return await _request("/character", "GET", null, true)

func change_discipline(character_id: int, class_index: int) -> DmResult:
	return await _request("/character/discipline", "POST", {"characterId": character_id, "class_index": class_index}, true)

# --- Inventory ---------------------------------------------------------------------------------------------------------------------

func get_inventory(character_id: int) -> DmResult:
	return _slots(await _rget("/api/inventory/%d" % character_id))

## `bag_size` < 0 = omit (the server then assumes the old 24-slot bag).
func save_inventory(character_id: int, slots: Array, bag_size: int = -1) -> DmResult:
	var body := {"characterId": character_id, "slots": slots}
	if bag_size >= 0:
		body["bagSize"] = bag_size
	return _slots(await _post("/api/inventory/save", body))

func equip_item(character_id: int, slot_index: int, equipped: int) -> DmResult:
	return _slots(await _post("/api/inventory/equip", {"characterId": character_id, "slot_index": slot_index, "equipped": equipped}))

## data: Array of {item_id, instance_id (null for non-gear), ilvl, affixes}. drops: [{item_id, level, source}]
## One roll in flight per client: the route holds a DB connection while it checks ownership on the same pool, so a burst of concurrent rolls
## (one per kill) from a single player can occupy every connection and wedge the whole backend (seen live 2026-10-06 with 24 at once).
func roll_loot(character_id: int, drops: Array) -> DmResult:
	while _roll_busy:
		await Engine.get_main_loop().process_frame
	_roll_busy = true
	var r := await _post("/api/loot/roll-gear", {"characterId": character_id, "drops": drops})
	_roll_busy = false
	return r

func belt_tool(character_id: int, slot_index: int, equipped: int) -> DmResult:
	return _slots(await _post("/api/inventory/belt", {"characterId": character_id, "slot_index": slot_index, "equipped": equipped}))

func kit_move(character_id: int, slot_index: int, equipped: int) -> DmResult:
	return _slots(await _post("/api/inventory/kit", {"characterId": character_id, "slot_index": slot_index, "equipped": equipped}))

## `item_id` empty = take the socketed rune out (sent as JSON null).
func rune_socket(character_id: int, rite: String, item_id: String = "") -> DmResult:
	return _slots(await _post("/api/inventory/rune", {"characterId": character_id, "rite": rite, "itemId": null if item_id.is_empty() else item_id}))

# --- Loadouts ----------------------------------------------------------------------------------------------------------------------

func list_loadouts(character_id: int) -> DmResult:
	return await _rget("/api/loadouts/%d" % character_id)

func save_loadout(character_id: int, slot: int, preset: Dictionary) -> DmResult:
	return await _post("/api/loadouts/save", {"characterId": character_id, "slot": slot, "preset": preset})

func delete_loadout(character_id: int, slot: int) -> DmResult:
	return await _post("/api/loadouts/delete", {"characterId": character_id, "slot": slot})

## data: {slots: bag rows, report, preset}
func apply_loadout_preset(character_id: int, slot: int) -> DmResult:
	var r := await _request("/api/loadouts/apply", "POST", {"characterId": character_id, "slot": slot}, true)
	if not r.ok:
		return r
	var body: Variant = r.data
	if not (body is Dictionary) or not body.get("success", false):
		var msg := "Unknown server error"
		if body is Dictionary and body.get("error") is String and not String(body["error"]).is_empty():
			msg = body["error"]
		return DmResult.failure(msg, 200)
	return DmResult.success({"slots": _decorate(body.get("data")), "report": body.get("report"), "preset": body.get("preset")}, r.status)

# --- Account preferences -----------------------------------------------------------------------------------------------------------

func get_account_prefs() -> DmResult:
	return await _rget("/api/prefs")

## prefs: {key: bool|number|string}
func set_account_prefs(prefs: Dictionary) -> DmResult:
	return await _post("/api/prefs", {"prefs": prefs})

# --- Professions, crafting, gathering ----------------------------------------------------------------------------------------------

func get_professions(character_id: int) -> DmResult:
	return await _rget("/api/professions/%d" % character_id)

## Public (no JWT).
func get_recipes(profession: String) -> DmResult:
	return await _rget("/api/recipes?profession=" + profession.uri_encode(), false)

## data: {result_item_id, xp_gained, leveled_up, skill_level}; re-read the inventory afterwards.
func craft(character_id: int, recipe_id: String) -> DmResult:
	return await _post("/api/craft", {"characterId": character_id, "recipeId": recipe_id})

## Server-rolled finds. data: GatherReply {node, skill, accepted, successes, xp, gold, items, rejected, leveledUp, toolTier, skills}
func gather(character_id: int, node_type: String, actions: int, afk: bool = false) -> DmResult:
	return await _post("/api/gather", {"characterId": character_id, "nodeType": node_type, "actions": actions, "afk": afk})

func begin_afk_gather(character_id: int, node_type: String) -> DmResult:
	return await _post("/api/gather/afk-start", {"characterId": character_id, "nodeType": node_type})

# --- Progression -------------------------------------------------------------------------------------------------------------------

## payload: {characterId, level, xp, gold, stat_str, stat_agi, stat_int, stat_vit, killReports?}
func save_progress(payload: Dictionary) -> DmResult:
	return await _post("/api/character/save-progress", payload)

## Post kill batches on their own. data: {mode}
func report_kills(character_id: int, reports: Array) -> DmResult:
	return await _post("/api/kills/report", {"characterId": character_id, "reports": reports})

# Necromancer progression. All replies: {progress, gold?, earned?, cost?}. A 404 on necro_get = older server, keep local storage.
func necro_get(character_id: int) -> DmResult:
	return await _rget("/api/necro-progress/%d" % character_id)

## `input` is the SaveInput dictionary; characterId is merged in.
func necro_save(character_id: int, input: Dictionary) -> DmResult:
	var body := {"characterId": character_id}
	body.merge(input)
	return await _post("/api/necro-progress/save", body)

func necro_purchase(character_id: int, upgrade: String) -> DmResult:
	return await _post("/api/necro-progress/purchase", {"characterId": character_id, "upgrade": upgrade})

func necro_summon_prelate(character_id: int) -> DmResult:
	return await _post("/api/necro-progress/summon-prelate", {"characterId": character_id})

func necro_summon_boss(character_id: int, boss: String) -> DmResult:
	return await _post("/api/necro-progress/summon-boss", {"characterId": character_id, "boss": boss})

func necro_ascend(character_id: int) -> DmResult:
	return await _post("/api/necro-progress/ascend", {"characterId": character_id})

func necro_vows(character_id: int, vows: Dictionary) -> DmResult:
	return await _post("/api/necro-progress/vows", {"characterId": character_id, "vows": vows})

func necro_unlock(character_id: int, key: String) -> DmResult:
	return await _post("/api/necro-progress/unlock", {"characterId": character_id, "key": key})

func necro_boon(character_id: int, boon_id: String) -> DmResult:
	return await _post("/api/necro-progress/boon", {"characterId": character_id, "boonId": boon_id})

func necro_import_local(character_id: int, record: Dictionary) -> DmResult:
	return await _post("/api/necro-progress/import", {"characterId": character_id, "record": record})

# --- Chronicle ---------------------------------------------------------------------------------------------------------------------

## data: {life, run, runNo, runStartedAt, runs}
func get_chronicle(character_id: int) -> DmResult:
	return await _rget("/api/chronicle/%d" % character_id)

func add_chronicle(character_id: int, deltas: Dictionary, maxes: Dictionary) -> DmResult:
	return await _post("/api/chronicle/add", {"characterId": character_id, "deltas": deltas, "maxes": maxes})

## data: {archived}
func ascend_chronicle(character_id: int, ascension: int) -> DmResult:
	return await _post("/api/chronicle/ascend", {"characterId": character_id, "ascension": ascension})

# --- Sexton's Contracts, Gardening, Labor, Cosmetics ------------------------------------------------------------------------------

func get_contracts(character_id: int) -> DmResult:
	return await _rget("/api/contracts/%d" % character_id)

func deliver_contract(character_id: int, slot: int) -> DmResult:
	return await _post("/api/contracts/deliver", {"characterId": character_id, "slot": slot})

func get_garden(character_id: int) -> DmResult:
	return await _rget("/api/garden/%d" % character_id)

func plant_garden(character_id: int, plot: String, seed_id: String, compost: bool) -> DmResult:
	return await _post("/api/garden/plant", {"characterId": character_id, "plot": plot, "seedId": seed_id, "compost": compost})

func harvest_garden(character_id: int, plot: String) -> DmResult:
	return await _post("/api/garden/harvest", {"characterId": character_id, "plot": plot})

func get_labor(character_id: int) -> DmResult:
	return await _rget("/api/labor/%d" % character_id)

## `node_type` empty = clear the post (sent as JSON null).
func assign_labor(character_id: int, slot: int, node_type: String = "") -> DmResult:
	return await _post("/api/labor/assign", {"characterId": character_id, "slot": slot, "nodeType": null if node_type.is_empty() else node_type})

func collect_labor(character_id: int, slot: int) -> DmResult:
	return await _post("/api/labor/collect", {"characterId": character_id, "slot": slot})

func get_cosmetics(character_id: int) -> DmResult:
	return await _rget("/api/cosmetics/%d" % character_id)

## Only the keys present in `patch` change: {"cape": null} puts the cape away and leaves the pet as it was.
func select_cosmetics(character_id: int, patch: Dictionary) -> DmResult:
	var body := {"characterId": character_id}
	body.merge(patch)
	return await _post("/api/cosmetics/select", body)

func adopt_pet(character_id: int, pet_id: String) -> DmResult:
	return await _post("/api/cosmetics/adopt", {"characterId": character_id, "petId": pet_id})

# --- Ossuary Vault, salvage, gold sinks, boss keys ----------------------------------------------------------------------------------

## data: {bag, vault}
func get_vault(character_id: int) -> DmResult:
	return _decorate_keys(await _rget("/api/vault/%d" % character_id), ["bag", "vault"])

## `quantity` < 0 = the whole stack (omitted).
func vault_deposit(character_id: int, bag_slot: int, quantity: int = -1) -> DmResult:
	var body := {"characterId": character_id, "bagSlot": bag_slot}
	if quantity >= 0:
		body["quantity"] = quantity
	return _decorate_keys(await _post("/api/vault/deposit", body), ["bag", "vault"])

func vault_withdraw(character_id: int, vault_slot: int, quantity: int = -1) -> DmResult:
	var body := {"characterId": character_id, "vaultSlot": vault_slot}
	if quantity >= 0:
		body["quantity"] = quantity
	return _decorate_keys(await _post("/api/vault/withdraw", body), ["bag", "vault"])

## kind: "materials" | "all"
func vault_deposit_all(character_id: int, kind: String, except_slots: Array) -> DmResult:
	return _decorate_keys(await _post("/api/vault/deposit-all", {"characterId": character_id, "kind": kind, "exceptSlots": except_slots}), ["bag", "vault"])

func vault_sort(character_id: int) -> DmResult:
	return _decorate_keys(await _post("/api/vault/sort", {"characterId": character_id}), ["bag", "vault"])

## data: SalvageReply {bag, salvaged, gained, xp, level, leveledUp, skillXp, xpToNext}
func salvage_gear(character_id: int, slots: Array) -> DmResult:
	return _decorate_keys(await _post("/api/salvage", {"characterId": character_id, "slots": slots}), ["bag"])

## data: {gold, pieces: [{slot_index, instance_id, rerolls}]}
func reforge_quote(character_id: int) -> DmResult:
	return await _post("/api/reforge/quote", {"characterId": character_id})

## `expect_cost` is the price the player saw; the server refuses a stale one.
func reforge_affix(character_id: int, slot_index: int, affix_index: int, expect_cost: int) -> DmResult:
	return _decorate_keys(await _post("/api/reforge", {"characterId": character_id, "slot_index": slot_index, "affix_index": affix_index, "expect_cost": expect_cost}), ["bag"])

## data: {bound: [boss ids], summons: [{id, boss}]}
func boss_key_status(character_id: int) -> DmResult:
	return await _post("/api/boss-key/status", {"characterId": character_id})

func boss_key_summon(character_id: int, boss: String) -> DmResult:
	return _decorate_keys(await _post("/api/boss-key/summon", {"characterId": character_id, "boss": boss}), ["bag"])

func boss_key_refund(character_id: int, boss: String) -> DmResult:
	return _decorate_keys(await _post("/api/boss-key/refund", {"characterId": character_id, "boss": boss}), ["bag"])

## data: BossKeyPrize {item_id, instance_id, ilvl, affixes, legendary}
func boss_key_claim(character_id: int, boss: String, discipline: String, level: int) -> DmResult:
	return await _post("/api/boss-key/claim", {"characterId": character_id, "boss": boss, "discipline": discipline, "level": level})

# --- Bug reports -------------------------------------------------------------------------------------------------------------------

## report: {category, message, characterId?, context?}. data: {id}
func send_bug_report(report: Dictionary) -> DmResult:
	return await _post("/api/bug-reports", report)

func get_my_bug_reports() -> DmResult:
	return await _rget("/api/bug-reports/mine")

# --- Offline edition sync (server: /api/offline/*; these answer plain JSON, not the {success,data} envelope) ------------------------

## data: {snapshot, fingerprint, summary}
func offline_snapshot() -> DmResult:
	return await _request("/api/offline/snapshot", "GET", null, true)

## data: {versions: [{id, source, createdAt, summary}]}
func offline_versions() -> DmResult:
	return await _request("/api/offline/versions", "GET", null, true)

## Replace the online save with an offline one. `expected_fingerprint` is the one from offline_snapshot (409 when it moved).
## A 409 with data-less error + `implausible` means the player must confirm: call again with confirm_implausible = true.
func offline_load(snapshot: Dictionary, expected_fingerprint: String, confirm_implausible: bool = false) -> DmResult:
	var body := {"snapshot": snapshot, "expectedFingerprint": expected_fingerprint}
	if confirm_implausible:
		body["confirmImplausible"] = true
	return await _request("/api/offline/load", "POST", body, true)

func offline_restore(version_id: int, expected_fingerprint: String) -> DmResult:
	return await _request("/api/offline/restore", "POST", {"versionId": version_id, "expectedFingerprint": expected_fingerprint}, true)

## Merge offline level/XP into the online character. data: {level, experience, improved}
func offline_sync_stats(class_index: int, level: int, experience: int, confirm_implausible: bool = false) -> DmResult:
	var body := {"classIndex": class_index, "level": level, "experience": experience}
	if confirm_implausible:
		body["confirmImplausible"] = true
	return await _request("/api/offline/sync-stats", "POST", body, true)

# --- Public / site -----------------------------------------------------------------------------------------------------------------

## GET /leaderboard (no JWT, cached 30 s server-side). data: {players: [{rank, username, classIndex, hasDiscipline, level, ascension,
## bossKills, totalKills, playSeconds, runs, bestDepth}], updatedAt}
func get_leaderboard() -> DmResult:
	return await _request("/leaderboard")

## Patch notes JSON shipped with the web build (site/play/patch-notes.json). data: parsed JSON.
func get_patch_notes() -> DmResult:
	return await _fetch_site("play/patch-notes.json")

## The current release marker ("<sha> <iso-time>") parsed to the sha, or "" when unknown. Never an error (unknown != changed).
func get_release() -> String:
	var resp := await _send("GET", site_base + "play/release.txt?t=%d" % Time.get_unix_time_from_system(), {"Cache-Control": "no-store"}, "")
	var st := int(resp.get("status", 0))
	if resp.get("network_error", false) or st < 200 or st >= 300:
		return ""
	return DmReleaseWatch.parse_release(String(resp.get("text", "")))

func _fetch_site(rel: String) -> DmResult:
	var resp := await _send("GET", site_base + rel + "?t=%d" % Time.get_unix_time_from_system(), {"Cache-Control": "no-store"}, "")
	if resp.get("network_error", false):
		return DmResult.failure("Cannot reach server — check your connection", 0)
	var st := int(resp.get("status", 0))
	if st < 200 or st >= 300:
		return DmResult.failure("Request failed: %d" % st, st)
	return DmResult.success(DmJson.parse(String(resp.get("text", ""))), st)
