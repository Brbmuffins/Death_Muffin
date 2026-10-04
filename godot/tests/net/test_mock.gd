extends RefCounted
## Mock backend tests, driven through DmApi exactly as the game would. Returns [passed, failed].

static func run(t: SceneTree) -> Array:
	var counts := [0, 0]  # lambdas capture ints by value: count through an Array
	var check := func(cond: bool, label: String) -> void:
		counts[0 if cond else 1] += 1
		if not cond:
			print("FAIL: mock ", label)
	var mock := DmMockBackend.new("")
	mock.catalog = {"axe": {"name": "Axe", "item_type": "weapon", "rarity": "rare", "two_handed": true}, "shield": {"name": "Shield", "item_type": "offhand"}, "cap": {"name": "Cap", "item_type": "armor_head"}}
	mock.now_ms = func(): return 1700000000000
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	var h := await api.health()
	check.call(h.ok and h.data["db"] == "offline", "health")
	var bad := await api.login("nobody", "x")
	check.call(not bad.ok and bad.status == 401 and bad.error == "Invalid username or password.", "login unknown")
	var short := await api.register("ab", "", "x")
	check.call(not short.ok and short.status == 400, "register validation")
	var reg := await api.register("tester", "", "pw1234")
	check.call(reg.ok and reg.data["token"] == "offline:tester", "register")
	var dup := await api.register("tester", "", "pw1234")
	check.call(not dup.ok and dup.status == 409, "register dup")
	api.set_token(reg.data["token"])
	var noch := await api.get_character()
	check.call(not noch.ok and noch.status == 404, "no character yet")
	var ch := await api.load_or_create_character(7)
	check.call(ch.ok and ch.data["class_index"] == 7 and ch.data["class_name"] == "Carrion Witch" and ch.data["level"] == 1, "create character + discipline")
	var cid: int = ch.data["id"]
	var inv := await api.get_inventory(cid)
	check.call(inv.ok and inv.data.size() == 2 and inv.data[0]["item_id"] == "staff_oak", "starter inventory")
	var other := await api.get_inventory(cid + 99)
	check.call(not other.ok and other.status == 404, "foreign character refused")
	var sv := await api.save_inventory(cid, [{"slot_index": 0, "item_id": "axe", "quantity": 1, "equipped": 0}, {"slot_index": 1, "item_id": "shield", "quantity": 1, "equipped": 0}, {"slot_index": 2, "item_id": "cap", "quantity": 1, "equipped": 0}], 48)
	check.call(sv.ok and sv.data.size() == 3, "save_inventory")
	var badsave := await api.save_inventory(cid, [{"slot_index": 60, "item_id": "axe", "quantity": 1}], 48)
	check.call(not badsave.ok and badsave.error.begins_with("each slot_index"), "save_inventory bounds")
	var eq := await api.equip_item(cid, 0, 1)
	check.call(eq.ok and eq.data.filter(func(r): return r["slot_index"] == 105 and r["equipped"] == 1).size() == 1, "equip two-hander to main_hand")
	var eq2 := await api.equip_item(cid, 1, 1)
	check.call(eq2.ok and eq2.data.filter(func(r): return r["slot_index"] == 106).size() == 1 and eq2.data.filter(func(r): return r["item_id"] == "axe" and r["equipped"] == 0).size() == 1, "off-hand displaces two-hander")
	var uneq := await api.equip_item(cid, 106, 0)
	check.call(uneq.ok and uneq.data.filter(func(r): return r["equipped"] == 1).size() == 0, "unequip")
	var prog := await api.save_progress({"characterId": cid, "level": 4, "xp": 55, "gold": 9, "stat_str": 6, "stat_agi": 5, "stat_int": 5, "stat_vit": 5})
	var ch2 := await api.get_character()
	check.call(prog.ok and ch2.data["level"] == 4 and ch2.data["gold"] == 9, "save_progress")
	var pf := await api.set_account_prefs({"only_craftable": true, "loot_common": "auto"})
	var pf2 := await api.get_account_prefs()
	check.call(pf.ok and pf2.data["only_craftable"] == true and pf2.data["loot_common"] == "auto", "prefs")
	await api.add_chronicle(cid, {"kills": 3}, {"peak.depth": 4})
	await api.add_chronicle(cid, {"kills": 2}, {"peak.depth": 2})
	var chr := await api.get_chronicle(cid)
	check.call(chr.ok and chr.data["life"]["kills"] == 5 and chr.data["life"]["peak.depth"] == 4, "chronicle add")
	var asc := await api.ascend_chronicle(cid, 1)
	var chr2 := await api.get_chronicle(cid)
	check.call(asc.data["archived"] == true and chr2.data["runNo"] == 2 and chr2.data["runs"].size() == 1 and chr2.data["run"].is_empty(), "chronicle ascend")
	var short_bug := await api.send_bug_report({"category": "bug", "message": "short"})
	var bug := await api.send_bug_report({"category": "ui", "message": "the button is far too small"})
	var mine := await api.get_my_bug_reports()
	check.call(not short_bug.ok and bug.ok and mine.data.size() == 1 and mine.data[0]["status"] == "Saved on this device", "bug reports")
	var sl := await api.save_loadout(cid, 2, {"name": "x"})
	var dl := await api.delete_loadout(cid, 2)
	var badslot := await api.save_loadout(cid, 9, {"name": "x"})
	check.call(sl.ok and sl.data.size() == 1 and dl.ok and dl.data.size() == 0 and not badslot.ok, "loadouts")
	var stub := await api.craft(cid, "recipe_x")
	check.call(not stub.ok and stub.status == 501 and stub.error.contains("not ported"), "stubbed route says so")
	# offline sync: snapshot -> load (changes) -> versions -> restore
	var snap := await api.offline_snapshot()
	check.call(snap.ok and str(snap.data["fingerprint"]).length() == 64 and snap.data["summary"]["level"] == 4, "offline snapshot")
	var edited: Dictionary = snap.data["snapshot"].duplicate(true)
	edited["character"]["level"] = 9
	var stale := await api.offline_load(edited, "0".repeat(64))
	check.call(not stale.ok and stale.status == 409, "offline load stale fingerprint")
	var ld := await api.offline_load(edited, snap.data["fingerprint"])
	check.call(ld.ok and ld.data["summary"]["level"] == 9, "offline load")
	var vers := await api.offline_versions()
	check.call(vers.ok and vers.data["versions"].size() == 2, "versions recorded")
	var snap2 := await api.offline_snapshot()
	var online_version: int = 0
	for v in vers.data["versions"]:
		if v["source"] == "online":
			online_version = v["id"]
	var rs := await api.offline_restore(online_version, snap2.data["fingerprint"])
	check.call(rs.ok and rs.data["summary"]["level"] == 4, "offline restore")
	var ss := await api.offline_sync_stats(7, 12, 5)
	check.call(ss.ok and ss.data["improved"] == true and ss.data["level"] == 12, "sync-stats improves")
	var lb := await api.get_leaderboard()
	check.call(lb.ok and lb.data["players"].size() == 1 and lb.data["players"][0]["rank"] == 1, "leaderboard")
	var unauth := DmApi.new(mock.transport_callable())
	unauth.base_url = ""
	unauth.set_token("offline:ghost")
	var gh := await unauth.get_character()
	check.call(not gh.ok and gh.status == 401, "unknown token refused")
	return counts
