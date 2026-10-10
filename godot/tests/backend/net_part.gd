extends "res://tests/common/dm_suite_part.gd"
## Net track tests (a part of tests/backend/run.gd). Headless:  godot --headless --path godot --script res://tests/backend/run.gd
## Fixtures come from the TS client (the retired web game\'s fixtures-net exporter). Live smoke (opt-in, read-only, QA account only):
##   DM_LIVE_SMOKE=1 DM_QA_PASS_FILE=<file with the password> godot --headless --path godot --script res://tests/backend/run.gd

var pass_count := 0
var fail_count := 0
var fx: Dictionary

func _initialize() -> void:
	await _main()

func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		print("FAIL: ", label, " ", extra)

func deep_eq(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
		return absf(float(a) - float(b)) < 1e-9
	if ta != tb:
		return false
	if ta == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not deep_eq(a[k], b[k]):
				return false
		return true
	if ta == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not deep_eq(a[i], b[i]):
				return false
		return true
	return a == b

# --- fake transport -----------------------------------------------------------------------------------------------------------------

class Fake:
	extends RefCounted
	var reqs: Array = []
	var reply: Dictionary = {"status": 200, "text": "{\"success\":true,\"data\":[]}", "network_error": false}
	func send(req: Dictionary) -> Dictionary:
		reqs.append(req)
		return reply

func reply_of(status: int, body: Variant, net_err: bool = false) -> Dictionary:
	return {"status": status, "text": "" if body == null else JSON.stringify(body), "network_error": net_err}

func make_api(fake: Fake, token: String = "TESTJWT") -> DmApi:
	var api := DmApi.new(Callable(fake, "send"))
	api.base_url = ""
	if not token.is_empty():
		api.set_token(token)
	return api

## One entry per fixture name in net.json "requests" / scenario "call".
func call_by_name(api: DmApi, name: String) -> DmResult:
	match name:
		"login": return await api.login("qa_user", "pw")
		"register": return await api.register("qa_user", "a@b.co", "pw12345678")
		"health": return await api.health()
		"loadOrCreateCharacter_undefined": return await api.load_or_create_character()
		"loadOrCreateCharacter_3": return await api.load_or_create_character(3)
		"loadOrCreateCharacter_7": return await api.load_or_create_character(7)
		"getCharacter": return await api.get_character()
		"changeDiscipline": return await api.change_discipline(12, 6)
		"getInventory": return await api.get_inventory(12)
		"saveInventory": return await api.save_inventory(12, [{"slot_index": 0, "item_id": "x", "quantity": 1, "equipped": 0}], 48)
		"saveInventory_nobag": return await api.save_inventory(12, [])
		"equipItem": return await api.equip_item(12, 3, 1)
		"rollLoot": return await api.roll_loot(12, [{"item_id": "sword", "level": 5, "source": "enemy"}])
		"beltTool": return await api.belt_tool(12, 4, 0)
		"kitMove": return await api.kit_move(12, 4, 1)
		"runeSocket": return await api.rune_socket(12, "bone_spear", "rune_x")
		"runeSocket_null": return await api.rune_socket(12, "bone_spear", "")
		"listLoadouts": return await api.list_loadouts(12)
		"saveLoadout": return await api.save_loadout(12, 2, {"name": "p"})
		"deleteLoadout": return await api.delete_loadout(12, 2)
		"applyLoadoutPreset": return await api.apply_loadout_preset(12, 2)
		"getAccountPrefs": return await api.get_account_prefs()
		"setAccountPrefs": return await api.set_account_prefs({"only_craftable": true, "loot_common": "auto"})
		"getProfessions": return await api.get_professions(12)
		"getRecipes": return await api.get_recipes("black smith/x")
		"craft": return await api.craft(12, "recipe_copper_bar")
		"gather": return await api.gather(12, "copper_vein", 5)
		"gather_afk": return await api.gather(12, "copper_vein", 5, true)
		"beginAfkGather": return await api.begin_afk_gather(12, "copper_vein")
		"saveProgress": return await api.save_progress({"characterId": 12, "level": 5, "xp": 10, "gold": 3, "stat_str": 5, "stat_agi": 5, "stat_int": 5, "stat_vit": 5})
		"saveProgress_kills": return await api.save_progress({"characterId": 12, "level": 5, "xp": 10, "gold": 3, "stat_str": 5, "stat_agi": 5, "stat_int": 5, "stat_vit": 5, "killReports": [{"seq": 1, "groups": [], "bosses": [], "floors": []}]})
		"reportKills": return await api.report_kills(12, [{"seq": 1, "groups": [], "bosses": [], "floors": []}])
		"necro_get": return await api.necro_get(12)
		"necro_save": return await api.necro_save(12, {"kills": 3})
		"necro_purchase": return await api.necro_purchase(12, "damage")
		"necro_summonPrelate": return await api.necro_summon_prelate(12)
		"necro_summonBoss": return await api.necro_summon_boss(12, "warden")
		"necro_ascend": return await api.necro_ascend(12)
		"necro_vows": return await api.necro_vows(12, {"a": 1})
		"necro_unlock": return await api.necro_unlock(12, "k")
		"necro_boon": return await api.necro_boon(12, "b")
		"necro_importLocal": return await api.necro_import_local(12, {"r": 1})
		"getChronicle": return await api.get_chronicle(12)
		"addChronicle": return await api.add_chronicle(12, {"kills": 3}, {"peak.depth": 4})
		"ascendChronicle": return await api.ascend_chronicle(12, 2)
		"getContracts": return await api.get_contracts(12)
		"deliverContract": return await api.deliver_contract(12, 1)
		"getGarden": return await api.get_garden(12)
		"plantGarden": return await api.plant_garden(12, "herb1", "seed_x", true)
		"harvestGarden": return await api.harvest_garden(12, "herb1")
		"getLabor": return await api.get_labor(12)
		"assignLabor": return await api.assign_labor(12, 0, "copper_vein")
		"assignLabor_null": return await api.assign_labor(12, 0, "")
		"collectLabor": return await api.collect_labor(12, 0)
		"getCosmetics": return await api.get_cosmetics(12)
		"selectCosmetics": return await api.select_cosmetics(12, {"cape": null})
		"adoptPet": return await api.adopt_pet(12, "raven")
		"getVault": return await api.get_vault(12)
		"vaultDeposit": return await api.vault_deposit(12, 3, 2)
		"vaultDeposit_noqty": return await api.vault_deposit(12, 3)
		"vaultWithdraw": return await api.vault_withdraw(12, 3, 2)
		"vaultDepositAll": return await api.vault_deposit_all(12, "materials", [0, 1])
		"vaultSort": return await api.vault_sort(12)
		"salvageGear": return await api.salvage_gear(12, [1, 2])
		"reforgeQuote": return await api.reforge_quote(12)
		"reforgeAffix": return await api.reforge_affix(12, 3, 1, 500)
		"bossKeyStatus": return await api.boss_key_status(12)
		"bossKeySummon": return await api.boss_key_summon(12, "warden")
		"bossKeyRefund": return await api.boss_key_refund(12, "warden")
		"bossKeyClaim": return await api.boss_key_claim(12, "warden", "gravecaller", 30)
		"sendBugReport": return await api.send_bug_report({"category": "bug", "message": "it broke badly", "characterId": 12, "context": {"a": 1}})
		"getMyBugReports": return await api.get_my_bug_reports()
	push_error("no call mapping for " + name)
	return DmResult.failure("unmapped " + name, -1)

const NO_TOKEN := ["login", "register", "health", "getRecipes"]
const RAW_REPLY := {"login": {"token": "T"}, "register": {"token": "T"}, "loadOrCreateCharacter_undefined": {"id": 12}, "loadOrCreateCharacter_3": {"id": 12}, "loadOrCreateCharacter_7": {"id": 12}}

func test_requests() -> void:
	var reqs: Dictionary = fx["requests"]
	for name in reqs:
		var fake := Fake.new()
		fake.reply = reply_of(200, RAW_REPLY.get(name, {"success": true, "data": []}))
		var api := make_api(fake, "" if name in NO_TOKEN else "TESTJWT")
		await call_by_name(api, name)
		var want: Array = reqs[name]
		ok(fake.reqs.size() == want.size(), "%s: request count" % name, "%d vs %d" % [fake.reqs.size(), want.size()])
		for i in mini(fake.reqs.size(), want.size()):
			var got: Dictionary = fake.reqs[i]
			var w: Dictionary = want[i]
			ok(got["method"] == w["method"], "%s[%d] method" % [name, i], "%s vs %s" % [got["method"], w["method"]])
			ok(got["url"] == w["path"], "%s[%d] path" % [name, i], "%s vs %s" % [got["url"], w["path"]])
			ok(deep_eq(got["headers"], w["headers"]), "%s[%d] headers" % [name, i], str(got["headers"]) + " vs " + str(w["headers"]))
			var gb: Variant = DmJson.parse(String(got["body"])) if String(got["body"]) != "" else null
			ok(deep_eq(gb, w.get("body")), "%s[%d] body" % [name, i], str(gb) + " vs " + str(w.get("body")))

func test_scenarios() -> void:
	var fake := Fake.new()
	var api := make_api(fake, "TESTJWT")
	var notices: Array = []
	api.server_notice.connect(func(m): notices.append(m))
	for s in fx["scenarios"]:
		var tok_needed: bool = s["token"]
		api.set_token("TESTJWT" if tok_needed else "")
		fake.reqs.clear()
		var r: Dictionary = s["reply"]
		fake.reply = reply_of(int(r["status"]), r.get("body"), bool(r.get("throws", false)))
		notices.clear()
		var res := await call_by_name(api, s["call"])
		var out: Dictionary = s["outcome"]
		var id: String = s["id"]
		ok(res.ok == out["ok"], id + ": ok", "got ok=%s err=%s" % [res.ok, res.error])
		if out["ok"]:
			ok(deep_eq(res.data, DmJson.normalise(out["value"])), id + ": value", str(res.data) + " vs " + str(out["value"]))
		else:
			ok(res.error == out["message"], id + ": error verbatim", "'%s' vs '%s'" % [res.error, out["message"]])
			ok(res.status == int(out["status"]), id + ": status", str(res.status))
		ok(deep_eq(notices, s["notices"]), id + ": notices", str(notices))
		if id == "inv_unauth":
			ok(fake.reqs.is_empty(), id + ": no request sent without a token")
		if id == "after_replaced_write_blocked":
			ok(fake.reqs.is_empty(), id + ": no request sent after replaced")
	ok(api.is_session_replaced(), "session flagged replaced")

func test_misc() -> void:
	for c in fx["boolPref"]:
		var got := DmAccountPrefs.reconcile_bool(c["local"], c["remote"], c["key"])
		ok(deep_eq(got, c["out"]), "reconcile_bool", str(got) + " vs " + str(c["out"]))
	for c in fx["replacedCases"]:
		ok(DmApi.is_replaced_reply(int(c["status"]), c["body"]) == c["out"], "is_replaced_reply %s" % str(c))
	# claim / probe
	var fake := Fake.new()
	var api := make_api(fake, "OLDJWT")
	api.notify_session_replaced()
	fake.reply = reply_of(200, {"token": "NEW"})
	var t := await api.claim_session("OLDJWT")
	var cw: Dictionary = fx["claim"]["req"][0]
	ok(t == "NEW" and api.get_token() == "NEW" and not api.is_session_replaced(), "claim_session success", t)
	ok(fake.reqs[0]["method"] == cw["method"] and fake.reqs[0]["url"] == cw["path"] and deep_eq(fake.reqs[0]["headers"], cw["headers"]) and String(fake.reqs[0]["body"]) == "", "claim_session request shape")
	fake.reply = reply_of(401, {"error": "x"})
	ok(await api.claim_session("OLDJWT") == "", "claim_session refused")
	fake.reqs.clear()
	fake.reply = reply_of(200, {"success": true, "active": true})
	api.set_token("TOK")
	await api.probe_session()
	var pw: Dictionary = fx["probeReq"][0]
	ok(fake.reqs[0]["method"] == pw["method"] and fake.reqs[0]["url"] == pw["path"] and deep_eq(fake.reqs[0]["headers"], pw["headers"]), "probe request shape")
	ok(not api.is_session_replaced(), "probe active=true leaves session alone")
	fake.reply = reply_of(200, {"success": true, "active": false})
	await api.probe_session()
	ok(api.is_session_replaced(), "probe active=false flags replaced")

func test_kill_reporter() -> void:
	var t := [1000000]
	var r := DmKillReporter.new(func(): return t[0])
	var log: Array = fx["killReporter"]
	var k := func(o: Dictionary = {}) -> Dictionary:
		var d := {"area": "hollow", "def": "ghoul", "level": 3, "elite": false, "tier": 1, "diff": "medium", "rank": 0, "xpMult": 1.234, "goldMult": 1, "shardMult": 1}
		d.merge(o, true)
		return d
	ok(r.has_pending() == log[0]["hasPending"], "kr start")
	r.kill(k.call()); r.kill(k.call()); r.kill(k.call({"elite": true})); r.kill(k.call({"xpMult": 1.236}))
	r.boss({"boss": "warden", "tier": 1, "diff": "medium", "first": true, "summon": 4}); r.boss({"boss": "warden", "tier": 1, "diff": "medium", "first": true, "summon": 4})
	r.floor_clear({"depth": 2, "mult": 1.005})
	ok(r.has_pending() == log[1]["hasPending"], "kr open pending")
	var b := r.batches()
	ok(deep_eq(b, DmJson.normalise(log[2]["batches"])) and r.crowded() == log[2]["crowded"], "kr seal1", str(b))
	t[0] = 900000
	r.kill(k.call({"level": 9}))
	b = r.batches()
	ok(deep_eq(b, DmJson.normalise(log[3]["batches"])), "kr seal2 (clock back, seq still increases)", str(b))
	r.ack(1000000)
	b = r.batches()
	ok(deep_eq(b, DmJson.normalise(log[4]["batches"])), "kr after ack", str(b))
	for i in 6:
		t[0] += 1
		r.kill(k.call({"level": 20 + i}))
		r.batches()
	b = r.batches()
	ok(deep_eq(b, DmJson.normalise(log[5]["batches"])), "kr overflow drops oldest", str(b.size()))
	r.discard()
	ok(r.has_pending() == log[6]["hasPending"], "kr discard")
	var r2 := DmKillReporter.new(func(): return 5)
	for i in 119:
		r2.kill(k.call({"level": i}))
	var before := r2.crowded()
	r2.kill(k.call({"level": 500}))
	ok(before == log[7]["before"] and r2.crowded() == log[7]["after"], "kr crowded threshold")

func test_mock() -> void:
	var tm = load("res://tests/backend/test_mock.gd")
	if tm == null:
		return
	var res: Array = await tm.run(tree)
	pass_count += int(res[0])
	fail_count += int(res[1])

func live_smoke() -> void:
	var pass_file := OS.get_environment("DM_QA_PASS_FILE")
	if pass_file.is_empty() or not FileAccess.file_exists(pass_file):
		print("live smoke: DM_QA_PASS_FILE missing, skipped")
		return
	var pw := FileAccess.get_file_as_string(pass_file).strip_edges()
	var tr := DmHttpTransport.new()
	root.add_child(tr)
	await process_frame
	var api := DmApi.new(tr.request_callable())
	var h := await api.health()
	ok(h.ok and h.data.get("status") == "ok", "live health", h.error)
	var l := await api.login("qa_offline_sync", pw)
	ok(l.ok and l.data is Dictionary and l.data.get("token") is String, "live login", l.error)
	if not l.ok:
		return
	api.set_token(l.data["token"])
	var c := await api.get_character()
	ok(c.ok and c.data is Dictionary and c.data.has("id") and c.data.has("level"), "live get_character", c.error)
	if c.ok:
		print("live character: id=%s class=%s level=%s" % [c.data.get("id"), c.data.get("class_name"), c.data.get("level")])
	var s := await api.offline_snapshot()
	ok(s.ok and s.data is Dictionary and s.data.has("snapshot") and str(s.data.get("fingerprint", "")).length() == 64, "live offline_snapshot", s.error)
	if s.ok:
		print("live snapshot summary: ", s.data.get("summary"))
	var inv := await api.get_inventory(int(c.data["id"])) if c.ok else null
	if inv:
		ok(inv.ok and inv.data is Array, "live get_inventory", inv.error)
	var lb := await api.get_leaderboard()
	ok(lb.ok and lb.data is Dictionary and lb.data.has("players"), "live leaderboard", lb.error)
	var bad := await api.get_professions(0)
	ok(not bad.ok, "live error passthrough (expected failure): " + bad.error)

func _main() -> void:
	var f := FileAccess.open("res://tests/backend/fixtures/net.json", FileAccess.READ)
	if f == null:
		print("fixtures missing: they are committed in git (restore with git checkout)")
		quit(2)
		return
	fx = JSON.parse_string(f.get_as_text())
	await test_requests()
	await test_scenarios()
	await test_misc()
	test_kill_reporter()
	await test_mock()
	if OS.get_environment("DM_LIVE_SMOKE") == "1":
		await live_smoke()
	print("net tests: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
