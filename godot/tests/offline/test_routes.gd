extends RefCounted
## Offline backend: route sweep (every DmApi call the game makes must answer), persistence across a relaunch, atomic writes, and the
## refusals the web mock leaves half-done. Returns [passed, failed].

const DB := "user://test_offline_routes.json"
## Every DmApi method the game / panels call. The source scan below fails when game code calls one that is not listed here (add it to the sweep).
const SWEPT := ["register", "login", "load_or_create_character", "get_character", "change_discipline", "get_inventory", "save_inventory", "equip_item", "roll_loot",
	"belt_tool", "kit_move", "rune_socket", "list_loadouts", "save_loadout", "delete_loadout", "apply_loadout_preset", "get_professions", "get_recipes", "craft", "gather",
	"begin_afk_gather", "save_progress", "report_kills", "necro_get", "necro_save", "necro_purchase", "necro_summon_prelate", "necro_summon_boss", "necro_ascend",
	"necro_vows", "necro_unlock", "necro_boon", "necro_import_local", "get_chronicle", "add_chronicle", "ascend_chronicle", "get_contracts", "deliver_contract", "get_garden",
	"plant_garden", "harvest_garden", "get_labor", "assign_labor", "collect_labor", "get_cosmetics", "select_cosmetics", "adopt_pet", "get_vault", "vault_deposit",
	"vault_withdraw", "vault_deposit_all", "vault_sort", "salvage_gear", "reforge_quote", "reforge_affix", "boss_key_status", "boss_key_summon", "boss_key_refund",
	"boss_key_claim", "send_bug_report", "get_my_bug_reports", "get_account_prefs", "set_account_prefs", "claim_session", "probe_session", "get_leaderboard"]
## Called by game code but local to the client (no route).
## get_release / get_patch_notes fetch the web site's static files: offline they get a 404 and read as "unknown" (never an error, never a "new release").
const LOCAL_ONLY := ["set_token", "get_token", "notify_session_replaced", "is_session_replaced", "get_release", "get_patch_notes"]

var _p := 0
var _f := 0

func _ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		_p += 1
	else:
		_f += 1
		print("FAIL: offline ", label, " ", extra)

static func run(t: SceneTree) -> Array:
	var me = load("res://tests/offline/test_routes.gd").new()
	await me._run(t)
	return [me._p, me._f]

static func _routed(r: DmResult) -> bool:
	return r.status != 501 and not r.error.contains("no route") and not r.error.contains("not ported")

func _clean() -> void:
	for p in [DB, DB + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

func _run(_t: SceneTree) -> void:
	_clean()
	await _sweep()
	_scan_sources()
	await _persistence()
	await _no_loss_on_refusal()
	_grant_caps()
	_clean()

func _session(path: String = "") -> Array:
	var mock := DmOffline.make_mock(path)
	var clock := [1_790_000_000_000]
	mock.now_ms = func(): return clock[0]
	var api := DmOffline.make_api(mock)
	return [mock, api, clock]

func _sweep() -> void:
	var s := _session()
	var mock: DmMockBackend = s[0]
	var api: DmApi = s[1]
	var h := await api.health()
	_ok(h.ok, "health")
	var reg := await api.register("sweeper", "", "pw1234")
	_ok(reg.ok, "register")
	api.set_token(reg.data["token"])
	_ok((await api.login("sweeper", "pw1234")).ok, "login")
	var ch := await api.load_or_create_character(7)
	_ok(ch.ok, "character")
	var cid: int = ch.data["id"]
	var calls := {}
	calls["get_character"] = await api.get_character()
	calls["change_discipline"] = await api.change_discipline(cid, 8)
	calls["get_inventory"] = await api.get_inventory(cid)
	calls["save_inventory"] = await api.save_inventory(cid, [{"slot_index": 0, "item_id": "sword_copper", "quantity": 1, "equipped": 0}], 48)
	calls["equip_item"] = await api.equip_item(cid, 0, 1)
	calls["roll_loot"] = await api.roll_loot(cid, [{"item_id": "helm_copper", "level": 3, "source": "kill"}])
	calls["belt_tool"] = await api.belt_tool(cid, 0, 0)
	calls["kit_move"] = await api.kit_move(cid, 0, 0)
	calls["rune_socket"] = await api.rune_socket(cid, "bone_needle", "")
	calls["list_loadouts"] = await api.list_loadouts(cid)
	calls["save_loadout"] = await api.save_loadout(cid, 0, {"name": "x", "rites": {"primary": "bone_needle", "keys": ["a", "b", "c", "d", "e"]}})
	calls["apply_loadout_preset"] = await api.apply_loadout_preset(cid, 0)
	calls["delete_loadout"] = await api.delete_loadout(cid, 0)
	calls["get_professions"] = await api.get_professions(cid)
	calls["get_recipes"] = await api.get_recipes("")
	calls["craft"] = await api.craft(cid, "recipe_nope")
	calls["gather"] = await api.gather(cid, "no_node", 1)
	calls["begin_afk_gather"] = await api.begin_afk_gather(cid, "no_node")
	calls["save_progress"] = await api.save_progress({"characterId": cid, "level": 2, "xp": 1, "gold": 10, "stat_str": 5, "stat_agi": 5, "stat_int": 5, "stat_vit": 5})
	calls["report_kills"] = await api.report_kills(cid, [])
	calls["necro_get"] = await api.necro_get(cid)
	calls["necro_save"] = await api.necro_save(cid, {"areaKills": {"graves": 3}, "shards": 2})
	calls["necro_purchase"] = await api.necro_purchase(cid, "damage")
	calls["necro_summon_prelate"] = await api.necro_summon_prelate(cid)
	calls["necro_summon_boss"] = await api.necro_summon_boss(cid, "gravedigger")
	calls["necro_ascend"] = await api.necro_ascend(cid)
	calls["necro_vows"] = await api.necro_vows(cid, {})
	calls["necro_unlock"] = await api.necro_unlock(cid, "vow:nope")
	calls["necro_boon"] = await api.necro_boon(cid, "nope")
	calls["necro_import_local"] = await api.necro_import_local(cid, {})
	calls["get_chronicle"] = await api.get_chronicle(cid)
	calls["add_chronicle"] = await api.add_chronicle(cid, {"kills": 1}, {})
	calls["ascend_chronicle"] = await api.ascend_chronicle(cid, 1)
	calls["get_contracts"] = await api.get_contracts(cid)
	calls["deliver_contract"] = await api.deliver_contract(cid, 0)
	calls["get_garden"] = await api.get_garden(cid)
	calls["plant_garden"] = await api.plant_garden(cid, "h0", "seed_mourning_moss", false)
	calls["harvest_garden"] = await api.harvest_garden(cid, "h0")
	calls["get_labor"] = await api.get_labor(cid)
	calls["assign_labor"] = await api.assign_labor(cid, 0, "")
	calls["collect_labor"] = await api.collect_labor(cid, 0)
	calls["get_cosmetics"] = await api.get_cosmetics(cid)
	calls["select_cosmetics"] = await api.select_cosmetics(cid, {"cape": null})
	calls["adopt_pet"] = await api.adopt_pet(cid, "pet_tithe_bat")
	calls["get_vault"] = await api.get_vault(cid)
	calls["vault_deposit"] = await api.vault_deposit(cid, 0, 1)
	calls["vault_withdraw"] = await api.vault_withdraw(cid, 0, 1)
	calls["vault_deposit_all"] = await api.vault_deposit_all(cid, "materials", [])
	calls["vault_sort"] = await api.vault_sort(cid)
	calls["salvage_gear"] = await api.salvage_gear(cid, [0])
	calls["reforge_quote"] = await api.reforge_quote(cid)
	calls["reforge_affix"] = await api.reforge_affix(cid, 0, 0, 0)
	calls["boss_key_status"] = await api.boss_key_status(cid)
	calls["boss_key_summon"] = await api.boss_key_summon(cid, "gravedigger")
	calls["boss_key_refund"] = await api.boss_key_refund(cid, "gravedigger")
	calls["boss_key_claim"] = await api.boss_key_claim(cid, "gravedigger", "gravecaller", 10)
	calls["send_bug_report"] = await api.send_bug_report({"category": "bug", "message": "something is wrong here", "characterId": cid})
	calls["get_my_bug_reports"] = await api.get_my_bug_reports()
	calls["get_account_prefs"] = await api.get_account_prefs()
	calls["set_account_prefs"] = await api.set_account_prefs({"only_craftable": true})
	calls["get_leaderboard"] = await api.get_leaderboard()
	for k in calls:
		_ok(_routed(calls[k]), "route answers: " + k, "%d %s" % [calls[k].status, calls[k].error])
	# the ones that must plainly succeed on a fresh character
	for k in ["get_character", "change_discipline", "get_inventory", "save_inventory", "equip_item", "roll_loot", "list_loadouts", "save_loadout", "apply_loadout_preset",
			"delete_loadout", "get_professions", "get_recipes", "save_progress", "report_kills", "necro_get", "necro_save", "get_chronicle", "add_chronicle", "get_contracts",
			"get_garden", "get_labor", "assign_labor", "get_cosmetics", "select_cosmetics", "get_vault", "vault_sort", "reforge_quote", "boss_key_status", "send_bug_report",
			"get_my_bug_reports", "get_account_prefs", "set_account_prefs", "get_leaderboard"]:
		_ok(calls[k].ok, "succeeds: " + k, "%d %s" % [calls[k].status, calls[k].error])
	_ok(await api.get_release() == "", "release marker is unknown offline")
	_ok(not (await api.get_patch_notes()).ok, "patch notes are not served offline")
	var claim := await api.claim_session(api.get_token())
	_ok(claim == api.get_token(), "claim_session")
	await api.probe_session()
	_ok(not api.is_session_replaced(), "probe_session")
	_ok(not mock.catalog.is_empty(), "catalogue built from the game content")

## Every `api.<method>(` the game code calls must be in SWEPT or LOCAL_ONLY.
func _scan_sources() -> void:
	var re := RegEx.create_from_string("\\bapi\\.([a-z_0-9]+)\\(")
	var seen: Dictionary = {}
	for dir in ["res://game", "res://game_ui", "res://main", "res://front", "res://world", "res://net"]:
		_scan_dir(dir, re, seen)
	for m in seen:
		_ok(m in SWEPT or m in LOCAL_ONLY, "game calls api.%s: add it to the offline sweep" % m, str(seen[m]))
	_ok(seen.size() > 40, "source scan found the api calls", str(seen.size()))

func _scan_dir(dir: String, re: RegEx, seen: Dictionary) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		_scan_dir(dir + "/" + sub, re, seen)
	for f in da.get_files():
		if not f.ends_with(".gd"):
			continue
		var text := FileAccess.get_file_as_string(dir + "/" + f)
		for m in re.search_all(text):
			seen[m.get_string(1)] = dir + "/" + f

func _snapshot(api: DmApi, cid: int) -> Dictionary:
	var out := {}
	out["character"] = (await api.get_character()).data
	out["inventory"] = (await api.get_inventory(cid)).data
	out["professions"] = (await api.get_professions(cid)).data
	out["vault"] = (await api.get_vault(cid)).data
	out["labor"] = (await api.get_labor(cid)).data
	out["garden"] = (await api.get_garden(cid)).data
	out["necro"] = (await api.necro_get(cid)).data
	out["chronicle"] = (await api.get_chronicle(cid)).data
	out["cosmetics"] = (await api.get_cosmetics(cid)).data
	out["loadouts"] = (await api.list_loadouts(cid)).data
	out["contracts"] = (await api.get_contracts(cid)).data
	out["bugs"] = (await api.get_my_bug_reports()).data
	return out

func _persistence() -> void:
	var s := _session(DB)
	var api: DmApi = s[1]
	var clock: Array = s[2]
	var reg := await api.register("keeper", "", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(5)
	var cid: int = ch.data["id"]
	await api.save_progress({"characterId": cid, "level": 12, "xp": 77, "gold": 654321, "stat_str": 6, "stat_agi": 5, "stat_int": 8, "stat_vit": 5})
	await api.save_inventory(cid, [{"slot_index": 0, "item_id": "ingot_copper", "quantity": 50, "equipped": 0}, {"slot_index": 1, "item_id": "staff_oak", "quantity": 1, "equipped": 0},
		{"slot_index": 2, "item_id": "seed_mourning_moss", "quantity": 4, "equipped": 0}, {"slot_index": 3, "item_id": "charm_tithe_bat", "quantity": 1, "equipped": 0}], 48)
	await api.equip_item(cid, 1, 1)
	var rolled := await api.roll_loot(cid, [{"item_id": "helm_copper", "level": 20, "source": "boss"}])
	var inv: Array = (await api.get_inventory(cid)).data
	var rows: Array = []
	for r in inv:
		rows.append({"slot_index": r["slot_index"], "item_id": r["item_id"], "quantity": r["quantity"], "equipped": r["equipped"]})
	rows.append({"slot_index": 10, "item_id": "helm_copper", "quantity": 1, "equipped": 0, "instance_id": rolled.data[0]["instance_id"]})
	_ok((await api.save_inventory(cid, rows.filter(func(r): return int(r["slot_index"]) < 100), 48)).ok, "persist: save with a roll")
	await api.vault_deposit(cid, 0, 20)
	await api.vault_deposit(cid, 10)
	await api.add_chronicle(cid, {"kills": 9}, {"peak.depth": 3})
	await api.assign_labor(cid, 0, "oak_tree" if DmGathering.node_def("oak_tree").size() > 0 else _first_node("woodcutting"))
	await api.plant_garden(cid, "h0", "seed_mourning_moss", false)
	await api.adopt_pet(cid, "pet_tithe_bat")
	await api.necro_save(cid, {"areaKills": {"graves": 12}, "shards": 9})
	await api.save_loadout(cid, 1, {"name": "Kept", "rites": {"primary": "bone_needle", "keys": ["a", "b", "c", "d", "e"]}})
	await api.send_bug_report({"category": "bug", "message": "kept across relaunch", "characterId": cid})
	await api.get_contracts(cid)
	clock[0] += 60_000
	var before := await _snapshot(api, cid)
	_ok(not FileAccess.file_exists(DB + ".tmp"), "persist: no leftover tmp file after writes")
	_ok(FileAccess.file_exists(DB), "persist: the db file exists")
	# relaunch: a brand-new backend on the same file
	var mock2 := DmOffline.make_mock(DB)
	mock2.now_ms = func(): return clock[0]
	var api2 := DmOffline.make_api(mock2)
	api2.set_token("offline:keeper")
	var after := await _snapshot(api2, cid)
	for k in before:
		var d: String = load("res://tests/offline/run.gd").diff(after[k], before[k], k)
		_ok(d == "", "relaunch keeps " + k, d)
	_ok(int(after["character"]["gold"]) == 654321 and int(after["character"]["level"]) == 12, "relaunch keeps gold and level")
	_ok(after["vault"]["vault"].size() == 2, "relaunch keeps the vault", str(after["vault"]["vault"].size()))
	_ok(after["garden"]["plots"][0]["seedId"] == "seed_mourning_moss", "relaunch keeps the garden plot")
	_ok(after["cosmetics"]["selected"]["pet"] == "pet_tithe_bat", "relaunch keeps the pet")
	_ok(int(after["necro"]["progress"]["areaKills"]["graves"]) >= 12, "relaunch keeps necro progress")
	_ok(after["vault"]["vault"].filter(func(r): return r.has("instance_id") and r.has("affixes")).size() == 1, "relaunch keeps the rolled piece (now in the vault) with its affixes")
	var login := await api2.login("keeper", "pw1234")
	_ok(login.ok, "relaunch: the account still signs in")
	# a half-written tmp file (crash mid-save) never replaces the real db
	var f := FileAccess.open(DB + ".tmp", FileAccess.WRITE)
	f.store_string("{\"accounts\": {broken")
	f.close()
	var mock3 := DmOffline.make_mock(DB)
	var api3 := DmOffline.make_api(mock3)
	api3.set_token("offline:keeper")
	_ok((await api3.get_character()).ok, "a stale tmp file is ignored on load")
	# unknown / foreign tokens
	api3.set_token("offline:nobody")
	_ok((await api3.get_character()).status == 401, "unknown account token refused")

func _first_node(skill: String) -> String:
	for id in DmGatherData.nodes():
		var n: Dictionary = DmGatherData.nodes()[id]
		if n["skill"] == skill and int(n["level"]) == 1:
			return id
	return ""

## A craft, contract reward or labor collection that fails after taking items must leave the bag as it was (the server's transaction).
func _no_loss_on_refusal() -> void:
	var s := _session()
	var api: DmApi = s[1]
	var reg := await api.register("fullbag", "", "pw1234")
	api.set_token(reg.data["token"])
	var cid: int = (await api.load_or_create_character(5)).data["id"]
	var rec: Dictionary = {}
	for r in (await api.get_recipes("")).data:
		if int(r["skill_level_required"]) <= 1 and DmContent.items().has(r["result_item_id"]):
			rec = r
			break
	var rows: Array = []
	for i in rec["ingredients"].size():
		var ing: Dictionary = rec["ingredients"][i]
		rows.append({"slot_index": i, "item_id": ing["item_id"], "quantity": int(ing["quantity"]) * 2, "equipped": 0})
	# fill every other bag slot with gear so the result has nowhere to go
	for i in range(rows.size(), 48):
		rows.append({"slot_index": i, "item_id": "sword_copper", "quantity": 1, "equipped": 0})
	_ok((await api.save_inventory(cid, rows, 48)).ok, "fullbag: bag filled")
	var before: Array = (await api.get_inventory(cid)).data
	var r := await api.craft(cid, rec["id"])
	var after: Array = (await api.get_inventory(cid)).data
	if not r.ok:
		_ok(r.error == "Inventory is full", "fullbag: craft refused with the server's wording", r.error)
		_ok(str(before) == str(after), "fullbag: a refused craft keeps every ingredient")
	else:
		_ok(false, "fullbag: the craft should have been refused (no room)")


## A contract reward obeys the item's stack cap like contracts.cjs addToBag: a second Copper Ring opens its own slot (a 2-stack was refused by every later
## inventory save, so the bag never reached the server and a Workbench reforge found "nothing in that slot": next_acre_guide flaked on the reward roll).
func _grant_caps() -> void:
	var mock: DmMockBackend = _session()[0]
	var acc := {"slots": [{"slot_index": 0, "item_id": "ring_copper", "quantity": 1, "equipped": 0}, {"slot_index": 1, "item_id": "log_oak", "quantity": 95, "equipped": 0}]}
	_ok(mock._grant(acc, "ring_copper", 1), "grant: a second ring fits")
	var rings: Array = acc["slots"].filter(func(x): return x["item_id"] == "ring_copper")
	_ok(rings.size() == 2 and rings.all(func(x): return int(x["quantity"]) == 1), "grant: gear never stacks (each ring its own slot)", str(rings))
	var cap := int(mock._stack_cap("log_oak"))
	_ok(mock._grant(acc, "log_oak", 10), "grant: a stackable overflows into a new slot")
	var logs: Array = acc["slots"].filter(func(x): return x["item_id"] == "log_oak")
	var total := 0
	var over := false
	for x in logs:
		total += int(x["quantity"])
		over = over or int(x["quantity"]) > cap
	_ok(total == 105 and not over and (cap >= 105 or logs.size() == 2), "grant: stacks top up to the cap (%d) and spill the rest" % cap, str(logs))
