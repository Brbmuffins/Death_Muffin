extends RefCounted
## A headless DmGame --offline session: the offline backend on a real file, a DmGame on top of it, then every system the release needs
## driven through game.api exactly as the panels do (craft, gather, salvage, reforge, vault, contract, garden, labor, vows, unlock, boon, ascend,
## loadout, cosmetics), then a relaunch (new backend + new DmNextGame on the same file) that must find everything where it was left. Returns [passed, failed].

const DB := "user://test_offline_session.json"

var _p := 0
var _f := 0
var _clock := [1_790_000_000_000]

func _ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		_p += 1
	else:
		_f += 1
		print("FAIL: session ", label, " ", extra)

static func run(t: SceneTree) -> Array:
	var me = load("res://tests/offline/test_session.gd").new()
	await me._run(t)
	return [me._p, me._f]

func _clean() -> void:
	for p in [DB, DB + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

func _make_api() -> DmApi:
	var mock := DmOffline.make_mock(DB)
	mock.now_ms = func(): return _clock[0]
	var rng := DmRng.new(424242)
	mock.rng = rng.as_callable()
	_keep.append(rng)
	_keep.append(mock)
	return DmOffline.make_api(mock)

var _keep: Array = []

func _bag(api: DmApi, cid: int) -> Array:
	return (await api.get_inventory(cid)).data

static func _count(rows: Array, item_id: String) -> int:
	var n := 0
	for r in rows:
		if r["item_id"] == item_id and int(r["slot_index"]) < 100:
			n += int(r["quantity"])
	return n

func _row(slot: int, id: String, qty: int, extra: Dictionary = {}) -> Dictionary:
	var r := {"slot_index": slot, "item_id": id, "quantity": qty, "equipped": 0}
	r.merge(extra, true)
	return r

func _gold(api: DmApi, cid: int, g: int) -> void:
	await api.save_progress({"characterId": cid, "level": 40, "xp": 0, "gold": g, "stat_str": 6, "stat_agi": 5, "stat_int": 5, "stat_vit": 5})

func _run(t: SceneTree) -> void:
	_clean()
	var api := _make_api()
	var reg := await api.register("sessionist", "", "pw1234")
	_ok(reg.ok, "register", reg.error)
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	var cid: int = ch.data["id"]
	var game: DmNextGame = load("res://next/next_game.tscn").instantiate()
	t.root.add_child(game)
	await game.start(ch.data, api, {"visual": false, "persist": false, "waves": false, "audio": false, "name": "sessionist"})
	var host := game.ui_host   # the DmGameUi contract the panels read (bag, progress, refreshes)
	_ok(game.ready_, "DmNextGame started on the offline backend")
	_ok(host.prog.mode == "server", "progress runs in server mode against the offline backend", host.prog.mode)
	_ok(host.slots.size() == 2, "starter kit loaded by the game", str(host.slots.size()))
	await _gold(api, cid, 5_000_000)

	# --- craft ---
	var rec: Dictionary = {}
	for r in (await api.get_recipes("")).data:
		if int(r["skill_level_required"]) <= 1 and DmContent.items().has(r["result_item_id"]):
			rec = r
			break
	var rows: Array = []
	for i in rec["ingredients"].size():
		rows.append(_row(i, rec["ingredients"][i]["item_id"], int(rec["ingredients"][i]["quantity"]) * 4))
	await api.save_inventory(cid, rows, 48)
	var cr := await api.craft(cid, rec["id"])
	_ok(cr.ok and _count(cr.data["updatedInventory"], rec["result_item_id"]) >= int(rec["result_quantity"]), "craft", cr.error)
	_ok(cr.ok and int(cr.data["updatedProfession"]["skill_xp"]) > 0, "craft pays skill xp")
	await host.refresh_inventory()
	_ok(_count(host.slots, rec["result_item_id"]) >= int(rec["result_quantity"]), "the game sees the crafted item after refresh_inventory")

	# --- gather ---
	var node := ""
	for id in DmGatherData.nodes():
		if DmGatherData.nodes()[id]["skill"] == "mining" and int(DmGatherData.nodes()[id]["level"]) == 1:
			node = id
			break
	var g := await api.gather(cid, node, 12)
	_ok(g.ok and int(g.data["accepted"]) > 0 and g.data["skill"] == "mining", "gather", g.error)
	_clock[0] += 60_000
	var afk := await api.begin_afk_gather(cid, node)
	_ok(afk.ok, "afk start", afk.error)
	_clock[0] += 60_000
	var g2 := await api.gather(cid, node, 20, true)
	_ok(g2.ok, "afk gather", g2.error)
	_ok(game.gather != null, "the game has its gatherer")

	# --- salvage ---
	var rolled := await api.roll_loot(cid, [{"item_id": "helm_copper", "level": 30, "source": "boss"}, {"item_id": "sword_copper", "level": 12, "source": "elite"}, {"item_id": "chest_iron", "level": 40, "source": "boss"}])
	_ok(rolled.ok and rolled.data.size() == 3, "loot roll", rolled.error)
	var bag: Array = await _bag(api, cid)
	var keep: Array = []
	for r in bag:
		if int(r["slot_index"]) < 100:
			keep.append(_row(int(r["slot_index"]), r["item_id"], int(r["quantity"]), {"equipped": int(r["equipped"])}))
	var free := 20
	for d in rolled.data:
		keep.append(_row(free, d["item_id"], 1, {"instance_id": d["instance_id"]}))
		free += 1
	var sv := await api.save_inventory(cid, keep, 48)
	_ok(sv.ok, "save inventory naming rolls", sv.error)
	var piece_slot := 21
	var sl := await api.salvage_gear(cid, [20])
	_ok(sl.ok and sl.data["gained"].size() > 0 and int(sl.data["xp"]) > 0, "salvage", sl.error)

	# --- reforge (+ quote) ---
	var q := await api.reforge_quote(cid)
	_ok(q.ok and q.data["pieces"].size() >= 2, "reforge quote lists rolled pieces", q.error)
	var reforged := false
	for pc in q.data["pieces"]:
		var inv_row: Dictionary = {}
		for r in await _bag(api, cid):
			if int(r["slot_index"]) == int(pc["slot_index"]):
				inv_row = r
		if inv_row.is_empty() or not inv_row.has("affixes"):
			continue
		for i in inv_row["affixes"].size():
			var cost := DmGoldSink.reforge_cost(float(inv_row["ilvl"]), String(inv_row["rarity"]), inv_row["affixes"].size(), int(pc["rerolls"]))
			var rf := await api.reforge_affix(cid, int(pc["slot_index"]), i, cost)
			if rf.ok:
				reforged = true
				_ok(int(rf.data["cost"]) == cost and int(rf.data["rerolls"]) == int(pc["rerolls"]) + 1, "reforge charges the quoted price")
				break
		if reforged:
			break
	_ok(reforged, "reforge")
	var stale := await api.reforge_affix(cid, piece_slot, 0, 1)
	_ok(not stale.ok and stale.error != "", "reforge refuses a wrong price or empty slot", stale.error)

	# --- vault ---
	await api.save_inventory(cid, [_row(0, "ingot_copper", 60), _row(1, "ore_copper", 30), _row(piece_slot, "chest_iron", 1, {"instance_id": rolled.data[2]["instance_id"]})], 48)
	var vd := await api.vault_deposit(cid, 0, 25)
	_ok(vd.ok and vd.data["vault"].size() == 1, "vault deposit", vd.error)
	var va := await api.vault_deposit_all(cid, "materials", [])
	_ok(va.ok, "vault deposit-all", va.error)
	var vp := await api.vault_deposit(cid, piece_slot)
	_ok(vp.ok, "vault keeps a rolled piece", vp.error)
	var vs := await api.vault_sort(cid)
	_ok(vs.ok, "vault sort", vs.error)
	var vw := await api.vault_withdraw(cid, 0, 5)
	_ok(vw.ok, "vault withdraw", vw.error)

	# --- contract ---
	var view: Dictionary = (await api.get_contracts(cid)).data
	var crows: Array = []
	for i in view["contracts"].size():
		var c: Dictionary = view["contracts"][i]
		crows.append(_row(i * 2, c["itemId"], mini(int(c["qty"]), 99)))
		if int(c["qty"]) > 99:
			crows.append(_row(i * 2 + 1, c["itemId"], int(c["qty"]) - 99))
	await api.save_inventory(cid, crows, 48)
	var d0 := await api.deliver_contract(cid, 0)
	_ok(d0.ok and int(d0.data["gold"]) > 0, "contract delivered", d0.error)
	for s in [1, 2]:
		await api.deliver_contract(cid, s)
	var vnow: Dictionary = (await api.get_contracts(cid)).data
	_ok(vnow["bonus"]["claimed"] == true and vnow["contracts"].all(func(c): return c["done"]), "all three orders filled, bonus claimed")
	_ok(int(vnow["streak"]) >= 1, "streak counts the day")

	# --- garden ---
	await api.save_inventory(cid, [_row(0, "seed_mourning_moss", 3), _row(1, "bone_meal", 2)], 48)
	var pl := await api.plant_garden(cid, "h0", "seed_mourning_moss", true)
	_ok(pl.ok and pl.data["plots"][0]["state"] == "growing", "plant", pl.error)
	var early := await api.harvest_garden(cid, "h0")
	_ok(not early.ok and early.error == "It is not ready yet.", "harvest too early")
	_clock[0] += 3600_000
	var hv := await api.harvest_garden(cid, "h0")
	_ok(hv.ok and hv.data["items"].size() >= 1 and hv.data["plots"][0]["state"] == "empty", "harvest", hv.error)

	# --- labor ---
	var lnode := ""
	for id in DmGatherData.nodes():
		if DmGatherData.nodes()[id]["skill"] == "woodcutting" and int(DmGatherData.nodes()[id]["level"]) == 1:
			lnode = id
			break
	var la := await api.assign_labor(cid, 0, lnode)
	_ok(la.ok and la.data["slots"][0]["nodeType"] == lnode, "labor assign", la.error)
	_clock[0] += 4 * 3600_000
	var lc := await api.collect_labor(cid, 0)
	_ok(lc.ok and int(lc.data["collected"]["actions"]) > 0, "labor collect", lc.error)

	# --- cosmetics ---
	await api.save_inventory(cid, [_row(0, "charm_tithe_bat", 1)], 48)
	var ad := await api.adopt_pet(cid, "pet_tithe_bat")
	_ok(ad.ok and ad.data["adopted"] == "pet_tithe_bat", "adopt a pet", ad.error)

	# --- loadouts ---
	await api.save_inventory(cid, [_row(0, "sword_copper", 1), _row(1, "rune_splinter", 1)], 48)
	var lo := await api.save_loadout(cid, 0, {"name": "Session", "rites": {"primary": "bone_needle", "keys": ["a", "b", "c", "d", "e"]}, "runes": {"bone_needle": "rune_splinter"}, "weapon": {"itemId": "sword_copper"}})
	_ok(lo.ok, "loadout save", lo.error)
	var ap := await api.apply_loadout_preset(cid, 0)
	_ok(ap.ok and ap.data["report"]["applied"].size() == 2, "loadout apply", ap.error)

	# --- necromancer: seals, shards, unlock, vows, boon, ascend (the Altar's calls) ---
	await host.refresh_progress()
	for i in 40:
		var open: Array = host.progress["unlocked"].filter(func(a): return not DmContent.area(a).get("safe", false))
		if host.progress["unlocked"].has("sanctum"):
			break
		await api.necro_save(cid, {"areaKills": {open[i % open.size()]: 900}, "shards": 30})
		await host.refresh_progress()
	_ok(host.progress["unlocked"].has("sanctum"), "the sanctum seal broke from saved kills", str(host.progress["unlocked"]))
	for i in 30:
		await api.necro_save(cid, {"shards": 30})
	var vow_id: String = DmProgContent.vow_order()[0]
	var un := await api.necro_unlock(cid, "vow:" + vow_id)
	_ok(un.ok or un.error == "Nothing to unlock." or un.error == "Already unlocked.", "unlock a vow", un.error)
	var sw := await api.necro_vows(cid, {vow_id: 1})
	_ok(sw.ok, "swear a vow", sw.error)
	await host.refresh_progress()
	_ok(int(host.progress["vows"].get(vow_id, 0)) == 1, "the game sees the sworn vow", str(host.progress["vows"]))
	var clr := await api.necro_vows(cid, {})
	_ok(clr.ok, "clear the vows", clr.error)
	var boon_bought := false
	var ascended := 0
	for run in 8:
		var sp := await api.necro_summon_prelate(cid)
		_ok(sp.ok, "summon the prelate (run %d)" % run, sp.error)
		await api.necro_save(cid, {"prelateKills": 1, "peakWaveTier": 2, "areaKills": {"graves": 20}})
		var asc := await api.necro_ascend(cid)
		if asc.ok:
			ascended += 1
		for b in DmProgContent.boon_order():
			var bb := await api.necro_boon(cid, b)
			boon_bought = boon_bought or bb.ok
		if boon_bought and ascended >= 2:
			break
	_ok(ascended >= 2, "ascended", str(ascended))
	_ok(boon_bought, "bought a boon with the Ashes")
	await host.refresh_progress()
	var pr: Dictionary = host.progress.duplicate(true)
	_ok(int(pr["ascension"]) >= 0 and not pr["boons"].is_empty() and int(pr["ashes"]) >= 0, "the game's progress carries ashes and boons", str(pr["boons"]))
	var bs := await api.necro_summon_boss(cid, "gravedigger")
	_ok(bs.ok or bs.error.contains("demands"), "area boss summon answers", bs.error)

	# --- chronicle + bug report ---
	await api.add_chronicle(cid, {"kills": 4}, {})
	await api.send_bug_report({"category": "bug", "message": "session test report", "characterId": cid})
	await game.flush_all()
	game.queue_free()
	await t.process_frame

	# --- relaunch ---
	var snap := await _snapshot(api, cid)
	var api2 := _make_api()
	_ok((await api2.login("sessionist", "pw1234")).ok, "relaunch: sign in again")
	api2.set_token("offline:sessionist")
	var ch2 := await api2.get_character()
	_ok(ch2.ok and ch2.data["id"] == cid, "relaunch: same character")
	var game2: DmNextGame = load("res://next/next_game.tscn").instantiate()
	t.root.add_child(game2)
	await game2.start(ch2.data, api2, {"visual": false, "persist": false, "waves": false, "audio": false, "name": "sessionist"})
	var host2 := game2.ui_host
	_ok(game2.ready_, "relaunch: the game starts on the saved file")
	var snap2 := await _snapshot(api2, cid)
	var diff = load("res://tests/offline/run.gd").diff
	for k in snap:
		var d: String = diff.call(snap2[k], snap[k], k)
		_ok(d == "", "relaunch keeps " + k, d)
	_ok(int(host2.progress["ascension"]) == int(pr["ascension"]) and host2.progress["boons"] == pr["boons"], "relaunch: the game's progress matches", str(host2.progress["boons"]))
	_ok(host2.slots.size() == snap["inventory"].size(), "relaunch: the game's bag matches the saved one")
	_ok(int(game2.character["gold"]) == int(snap["character"]["gold"]), "relaunch: gold")
	game2.queue_free()
	await t.process_frame
	_clean()

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
